@tool
extends RefCounted
class_name HighpolyAutorun

# An unattended session in the REAL editor: boot, open the map, build it, fly a
# recorded path, write the numbers down, quit.
#
# WHY THIS AND NOT A BENCH. native/bench_flight.gd loads the same prop meshes
# into a bare SceneTree and measures that. It is useful for comparing two
# submission strategies against each other and it is NOT the plugin's scene: no
# terrain, no skyline, no water, no lighting, no .bctex textures, none of the
# material passes, and only as many props as its cap allows. Numbers from it
# describe a synthetic world that happens to share some meshes, and quoting them
# as "how Dumbo runs" is wrong — the shading is flat, the normal maps are absent
# and the aspect ratio does not even match the editor.
#
# This runs the actual plugin, through the actual dock code path, over the
# actual scene. What it measures is what a user sees.
#
# OFF UNLESS ASKED FOR. Activated by the BF6_AUTORUN environment variable and
# inert otherwise, because a plugin that can drive the editor and quit it is not
# something to leave armed.
#
#   BF6_AUTORUN=<path to a session json>   run that session
#   BF6_AUTORUN=1                          run the default session
#
# Session json (every key optional):
#   {"map": "MP_Dumbo", "mode": 3, "objects": true, "backdrop": true,
#    "water": true, "flight": "<path>.json", "out": "<path>.json",
#    "settle_frames": 30, "build_timeout_s": 900}
#
# NOT HEADLESS FOR THE FLIGHT. --headless installs RendererDummy: it draws
# nothing and reports every render counter as zero, which looks exactly like
# "the frame cost nothing". Boot and build timings are honest headless; frame
# times and draw calls are not, and this says so in the report rather than
# letting a zero be read as a win.

const ENV := "BF6_AUTORUN"

# Dialog titles seen during a run, and how often. Reported so a cancelled
# prompt is visible instead of being mistaken for a broken project.
static var _dialogs_seen := {}

const Log = preload("highpoly_log.gd")
const FlightPath = preload("highpoly_flightpath.gd")
const LightingScript = preload("highpoly_lighting.gd")


static func requested() -> bool:
	return OS.get_environment(ENV) != ""


static func config() -> Dictionary:
	var v := OS.get_environment(ENV)
	# MODE 2 IS "TEX", THE FULL ONE. The ids are historical, not ordered by
	# cost: SDK=0, GREY=1, TEX=2, LIGHT=3, because LIGHT was added last and took
	# the next free number. Defaulting to 3 looked like "the highest rung" and
	# is actually the UNTEXTURED one, so the first sessions measured a map with
	# no textures on it and called that the baseline.
	#
	# radius 1e9 = the slider's "no cull" position. A pass meant to find what is
	# expensive must not start by hiding most of it.
	var cfg := {
		"map": "MP_Dumbo", "mode": 2, "objects": true, "backdrop": true,
		"water": true, "flight": "", "out": "", "settle_frames": 30,
		"build_timeout_s": 900, "radius": 1.0e9,
		"lighting": true, "gi": true, "shadows": true, "map_lights": true,
		"vram_mode": -1, "cell": 0,
	}
	if v != "" and v != "1" and FileAccess.file_exists(v):
		var j = JSON.parse_string(FileAccess.get_file_as_string(v))
		if j is Dictionary:
			for k in j:
				cfg[k] = j[k]
	if str(cfg["flight"]) == "":
		cfg["flight"] = "user://bf6_flightpath_%s.json" % str(cfg["map"])
	if str(cfg["out"]) == "":
		cfg["out"] = "user://bf6_autorun_%s.json" % str(cfg["map"])
	return cfg


# The whole session. `dock` is the plugin's dock (highpoly_toggle.gd) and
# `mapctx` its map-context node; both are driven exactly as the UI drives them.
static func run(host: Node, dock: Node, mapctx: Node) -> void:
	# THE TREE, CAPTURED ONCE. The EditorPlugin gets freed part-way through a
	# session — the editor reloads the addon after its import scan finishes — and
	# every later `host.get_tree()` then dies with "Cannot call method on a
	# previously freed instance", losing a run that was otherwise fine. SceneTree
	# outlives the plugin, so hold that instead of reaching through the node.
	var _tree := host.get_tree()
	if _tree == null:
		return
	var cfg := config()
	var rep := {
		"map": str(cfg["map"]),
		"headless": DisplayServer.get_name() == "headless",
		"godot": Engine.get_version_info()["string"],
		"started_unix": Time.get_unix_time_from_system(),
	}
	# TIME SINCE PROCESS START, not since this function. Boot is a third of what
	# a user waits for and it is spent before any plugin code runs.
	rep["boot_ms"] = Time.get_ticks_msec()
	_say("autorun: boot to plugin ready in %d ms" % rep["boot_ms"])

	if bool(rep["headless"]):
		_say("autorun: HEADLESS — boot and build timings are real, frame times "
				+ "and draw calls are NOT (RendererDummy draws nothing)")

	# ---- open the map -----------------------------------------------------
	var scene := _scene_for(str(cfg["map"]))
	if scene == "":
		rep["error"] = "no scene found for %s" % str(cfg["map"])
		_finish(_tree, cfg, rep)
		return
	# WAIT FOR THE IMPORT SCAN BEFORE TOUCHING A SCENE.
	#
	# The level's assets are not on disk as .glb at all — raw/models/ holds only
	# .import files, and the real data is Godot's cached .scn. Those resolve only
	# once EditorFileSystem has registered them, so a scene opened mid-scan comes
	# up as a shell: MP_Dumbo in 607 ms with 37 nodes and a stderr full of
	# "res://raw/models/MP_Dumbo_Assets.glb - the file doesn't seem to exist".
	#
	# That reads as a corrupted project and is nothing of the kind. The runs that
	# worked took ~30 s to open because the scan had finished by then; the run
	# that "opened instantly" had simply beaten it.
	var efs := EditorInterface.get_resource_filesystem()
	var st0 := Time.get_ticks_msec()
	if efs != null:
		# A scan can start slightly after boot, so this waits for one to appear
		# and then for it to end, rather than sampling once and finding a false.
		while Time.get_ticks_msec() - st0 < 300000:
			await _tree.process_frame
			if not efs.is_scanning() and Time.get_ticks_msec() - st0 > 2000:
				break
	rep["import_scan_ms"] = Time.get_ticks_msec() - st0
	_say("autorun: filesystem scan settled after %.1f s"
			% (rep["import_scan_ms"] / 1000.0))

	# HOW LONG the editor stays expensive after it boots. The blame pass found
	# every group cheap once it had been running a while, which says the cost is
	# a startup window rather than a per-frame worker - so this samples frames
	# from boot until they settle and writes the curve down.
	if cfg.has("frame_timeline"):
		rep["frame_timeline"] = await _frame_timeline(_tree, cfg["frame_timeline"])
		_finish(_tree, cfg, rep)
		return
	# WHICH per-frame worker is eating the frame. Same question as frame_probe,
	# one level down: it switches off each script's processing in turn and times
	# the frames without it. Nothing is disabled permanently and no setting is
	# written - set_process is in-memory, and every group is put back.
	if cfg.has("frame_blame"):
		rep["frame_blame"] = await _frame_blame(_tree, cfg["frame_blame"])
		_finish(_tree, cfg, rep)
		return
	# The same probe with NO scene open, so "the map is expensive to draw" and
	# "this editor's frames are slow whatever is open" can be told apart.
	if cfg.has("frame_probe") and bool((cfg["frame_probe"] as Dictionary).get("skip_open", false)):
		rep["frame_probe"] = await _frame_probe(_tree, null, cfg["frame_probe"])
		_finish(_tree, cfg, rep)
		return

	var t0 := Time.get_ticks_msec()
	# ALREADY OPEN IS THE COMMON CASE. The editor restores the last scene, which
	# on this machine is usually the map being measured, and re-opening it throws
	# away a load that has already happened.
	# GIVE THE EDITOR TIME TO RESTORE ITS OWN SCENE FIRST.
	#
	# It reopens whatever was last edited, which here is the map being measured,
	# but that restore lands AFTER the import scan settles. Checking once and
	# finding nothing meant opening a second copy — two Dumbo tabs, two loads,
	# and the measurements taken against whichever one happened to be current.
	var pre: Node = null
	var wait0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wait0 < 30000:
		pre = EditorInterface.get_edited_scene_root()
		if pre != null and str(pre.name) != "":
			break
		await _tree.process_frame
	if pre != null and str(pre.name) == str(cfg["map"]):
		_say("autorun: %s was already open (restored by the editor); reusing it"
				% str(cfg["map"]))
		rep["reused_open_scene"] = true
	else:
		_say("autorun: opening %s (editor restored %s)"
				% [str(cfg["map"]), str(pre.name) if pre != null else "nothing"])
		EditorInterface.open_scene_from_path(scene)
	# WAIT FOR THE ROOT, do not count frames. open_scene_from_path is deferred
	# and a big level takes far longer than a fixed handful of frames — ten was
	# enough to report "scene did not open" about a scene that opens perfectly
	# well, which sends you looking for the wrong bug entirely.
	var root: Node = null
	var dismissed := 0
	var tick := 0
	while Time.get_ticks_msec() - t0 < 120000:
		await _tree.process_frame
		# Checked WHILE waiting, not after: a modal dialog holds a grab, and a
		# scene that cannot finish opening behind one looks exactly like a scene
		# that takes two minutes to open.
		tick += 1
		if tick % 30 == 0:
			dismissed += _dismiss_dialogs()
		root = EditorInterface.get_edited_scene_root()
		if root != null and str(root.name) != "":
			break
	rep["dialogs_dismissed"] = dismissed

	# A FEW DOZEN NODES IS NORMAL HERE, and treating it as failure was wrong.
	#
	# res://raw/models/ holds .import files whose .glb sources are not on disk,
	# so the SDK's own level content does not load in this project at all — the
	# level scene IS a ~50-node shell, and the plugin's overlay is what fills it.
	# The 14,089 nodes an earlier run reported were 13,439 props plus 290
	# backdrop plus 257 terrain, all of them ours, sitting on top of that shell.
	#
	# Recorded rather than judged: a sudden change in this number is worth
	# seeing, but a small one is the resting state and not a broken project.
	if root != null:
		rep["scene_nodes_at_open"] = _count_nodes(root)
	rep["open_ms"] = Time.get_ticks_msec() - t0
	rep["scene"] = scene
	if root == null:
		rep["error"] = "scene did not open: %s" % scene
		_finish(_tree, cfg, rep)
		return
	_say("autorun: opened %s in %d ms" % [scene.get_file(), rep["open_ms"]])
	# Only the game reader, placements included, for each map in "source_maps":
	# does the install still resolve the level (the 1.4.3.0 game update moved the
	# Portal levels under levels/gr/ and levels/mp/). No build.
	if cfg.has("source_maps"):
		var results := {}
		for m in cfg["source_maps"]:
			var gs = HighpolyGameSource.new()
			gs.log_fn = func(s: String) -> void: pass
			var t_open := Time.get_ticks_msec()
			var ok: bool = await gs.open_async(host, str(m), str(cfg.get("source_game", "")), {"placements": true})
			var stats: Dictionary = gs.walk.stats if gs.walk != null else {}
			# The level's water as the preview draws it (core bf6_level_water*):
			# every array in the environment's water record, by size.
			var water_summary := {}
			if bool(cfg.get("source_water", false)) and ok:
				var env = gs.native_environment()
				var water_value: Variant = env.read_water() if env != null else null
				if water_value is Dictionary:
					for key in water_value:
						var v: Variant = water_value[key]
						water_summary[str(key)] = (v as Array).size() if v is Array else (v if (v is float or v is int or v is bool or v is String) else typeof(v))
				else:
					water_summary["water"] = "none"
			results[str(m)] = {"ok": ok, "error": str(gs.error), "level": str(gs.level), "game": str(gs.src.game) if gs.src != null else "",
				"root": str(stats.get("root", "")), "rows": int(stats.get("rows", -1)), "ms": Time.get_ticks_msec() - t_open, "water": water_summary}
			_say("autorun: source %s -> %s" % [str(m), JSON.stringify(results[str(m)])])
		rep["sources"] = results
		_finish(_tree, cfg, rep)
		return
	# WHY A YIELDED FRAME COSTS SECONDS, asked without the reader in the picture.
	#
	# A build slice creates MultiMeshInstance3Ds and then awaits a frame; that
	# frame was measured at 1.5 s with 40 draw calls and the layer hidden, so it
	# is not our drawing. This grows the scene with trivial nodes instead of real
	# props and times the same await, first with the parent IN the edited scene
	# and then with it OUT of the tree. Same node creation either way, so a gap
	# between the two halves is the editor reacting to the tree, not the cost of
	# making nodes.
	if cfg.has("frame_probe"):
		rep["frame_probe"] = await _frame_probe(_tree, root, cfg["frame_probe"])
		_finish(_tree, cfg, rep)
		return
	# Only the soldier spawners: the game reader is opened for this map the way
	# the dock opens it, with no build.
	if bool(cfg.get("soldier_only", false)):
		var opened: bool = await host._ensure_game_source(str(cfg["map"]))
		rep["game_source_opened"] = opened
		_say("autorun: game reader for %s opened: %s" % [str(cfg["map"]), opened])
		rep["soldier"] = await _soldier_checks(_tree, root)
		_finish(_tree, cfg, rep)
		return
	# Only the BF6 UI and BF6 Script screens: does each shared page load in its
	# offline browser.
	if bool(cfg.get("pages_only", false)):
		for i in range(120):
			await _tree.process_frame
		var pages := {}
		for spec in [["BF6 UI", "res://addons/bf6_ui_editor/ui_panel.gd"], ["BF6 Script", "res://addons/bf6_typescript_editor/script_panel.gd"]]:
			EditorInterface.set_main_screen_editor(spec[0])
			var panel: Node = null
			var found := {}
			var page_t0 := Time.get_ticks_msec()
			var loads: Array = []
			var errors: Array = []
			var hooked := false
			while Time.get_ticks_msec() - page_t0 < 30000:
				await _tree.process_frame
				if panel == null:
					for n in EditorInterface.get_editor_main_screen().find_children("*", "", true, false):
						if n.get_script() != null and (n.get_script() as Script).resource_path == spec[1]:
							panel = n
				if panel != null and not hooked and is_instance_valid(panel.get("web")):
					var web: Object = panel.get("web")
					web.connect("page_load_finished", func(url): loads.append(str(url)))
					web.connect("host_error", func(m): errors.append(str(m)))
					hooked = true
				if hooked and not loads.is_empty():
					break
			for i in 60:
				await _tree.process_frame
			found["panel"] = panel != null
			if panel != null:
				var web: Object = panel.get("web")
				found["web"] = is_instance_valid(web)
				found["status"] = str((panel.get("status") as Label).text) if panel.get("status") is Label else ""
				if panel.has_method("_capabilities"): found["enabled"] = (panel.call("_capabilities") as Dictionary).keys().filter(func(k): return (panel.call("_capabilities") as Dictionary)[k] is Dictionary and bool((panel.call("_capabilities") as Dictionary)[k].get("enabled", false)))
				if is_instance_valid(web):
					found["diagnostics"] = str(web.call("diagnostics"))
					found["web_visible"] = (web as Control).is_visible_in_tree()
					found["web_rect"] = str((web as Control).get_global_rect())
			found["loads"] = loads
			found["errors"] = errors
			pages[spec[0]] = found
		EditorInterface.set_main_screen_editor("3D")
		rep["pages"] = pages
		_finish(_tree, cfg, rep)
		return
	# Only the editor's top bar: which main screen buttons are there.
	if bool(cfg.get("screens_only", false)):
		for i in range(120):
			await _tree.process_frame
		var bar: Node = null
		for n in EditorInterface.get_base_control().find_children("*", "EditorTitleBar", true, false):
			bar = n
		var names: Array = []
		if bar != null:
			for b in bar.find_children("*", "Button", true, false):
				if (b as Button).toggle_mode and str((b as Button).text) != "":
					names.append("%s%s" % [(b as Button).text, "" if (b as Button).is_visible_in_tree() else " (hidden)"])
		rep["main_screens"] = names
		# BF6 PORTAL: a click opens the site once and hands the editor back.
		var portal: Object = null
		var pstack: Array = [_tree.root]
		while not pstack.is_empty() and portal == null:
			var n: Node = pstack.pop_back()
			if n.has_method("open_portal"):
				portal = n
			pstack.append_array(n.get_children(true))
		if portal != null and bar != null:
			var urls: Array = []
			portal.set("open_url", func(url: String) -> Error:
				urls.append(url)
				return OK)
			var check := {"opened_at_startup": (portal.get("opened") as Array).size()}
			while Time.get_ticks_msec() < int(portal.get("_ready_at")):
				await _tree.process_frame
			EditorInterface.set_main_screen_editor("Script")
			for i in 10:
				await _tree.process_frame
			var button: Button = null
			for b in bar.find_children("*", "Button", true, false):
				if (b as Button).toggle_mode and str((b as Button).text) == "BF6 Portal":
					button = b
			check["button"] = button != null
			if button != null:
				button.pressed.emit()
			for i in 20:
				await _tree.process_frame
			check["urls"] = urls
			var pressed := ""
			for b in bar.find_children("*", "Button", true, false):
				if (b as Button).toggle_mode and (b as Button).button_pressed and str((b as Button).text) in ["2D", "3D", "Script", "Game", "AssetLib"] + names.map(func(x): return str(x).trim_suffix(" (hidden)")):
					pressed = str((b as Button).text)
			check["screen_after"] = pressed
			rep["portal"] = check
		_finish(_tree, cfg, rep)
		return
	# Only the SDK Object Library, patched to show the edited map's collection.
	if bool(cfg.get("library_only", false)):
		rep["library"] = await _library_checks(_tree, str(cfg.get("second_map", "MP_Aftermath_Portal")))
		_finish(_tree, cfg, rep)
		return
	# Only the Player Controller's walk, on the level as the SDK draws it.
	if bool(cfg.get("walk_only", false)):
		for i in range(60):
			await _tree.process_frame
		rep["walk"] = await _walk_checks(_tree, root)
		_finish(_tree, cfg, rep)
		return
	# Only the BF6 menu and radial, with no map build.
	if bool(cfg.get("radial_only", false)):
		for i in range(60):
			await _tree.process_frame
		rep["parity_shots"] = await _parity_shots(_tree, cfg)
		_finish(_tree, cfg, rep)
		return

	# ---- build the map context, through the dock's own call ---------------
	#
	# THE BAR DOES NOT HAVE TO FINISH. What is being measured is the RATE, and a
	# rate is known long before a build is: on Contaminated the props layer holds
	# a flat ~50/s from the first slice to the last, so the first fifteen seconds
	# say as much as the full forty-three. `build_sample_s` stops the build once
	# it has enough to divide by, which turns a build-speed iteration from
	# minutes into seconds.
	#
	# Stopping early costs the flight — a partial map is not worth flying — so
	# the two are exclusive and the report says which it did.
	var built := {"props": -1}
	var done := [false]
	var prog := {"done": 0, "total": 0, "at": 0, "samples": []}
	if mapctx.has_signal("build_finished"):
		mapctx.build_finished.connect(func(n):
			built["props"] = n
			done[0] = true, CONNECT_ONE_SHOT)
	if mapctx.has_signal("build_progress"):
		mapctx.build_progress.connect(func(d, t):
			prog["done"] = d
			prog["total"] = t
			prog["at"] = Time.get_ticks_msec()
			(prog["samples"] as Array).append([prog["at"], d]))
	# THE SKYLINE IS A SECOND BUILD WITH ITS OWN LANE, and waiting only for the
	# props one meant every flight began while the backdrop was still building —
	# main-thread work landing in the middle of the frames being timed. On a map
	# where the skyline IS 61% of the cost that is not a small error, and it is
	# why the flight numbers drifted between otherwise identical runs.
	#
	# _build_backdrop_async emits backdrop_progress and no "finished" signal, so
	# the end condition is done reaching total rather than an event.
	var bd := {"done": 0, "total": 0, "at": Time.get_ticks_msec()}
	if mapctx.has_signal("backdrop_progress"):
		mapctx.backdrop_progress.connect(func(d, t):
			bd["done"] = d
			bd["total"] = t
			bd["at"] = Time.get_ticks_msec())

	# VIDEO MEMORY IS THE SETTING MOST LIKELY TO DECIDE THE FRAME RATE on this
	# map, so it has to be sweepable rather than whatever the dock last saved.
	#
	# Measured on a 16 GB RTX 4080: the scene asks for 18.4 GB, 17.3 GB of it
	# textures. Past the card's limit the driver spills to system memory over
	# PCIe and every frame that touches an evicted texture stalls - a far better
	# explanation of 130 ms frames than 49,277 draw calls, which a 4080 does not
	# struggle with.
	# THE MULTIMESH CELL IS THE BATCHING GRAIN and the plugin says outright that
	# it is "a setting to measure rather than a constant to guess" - 64 m builds
	# 13,407 MultiMeshes for 44,925 instances, 48% of them holding ONE instance.
	# Coarsening it trades draw calls against showing more geometry, and nothing
	# had ever measured which way that trade falls.
	if int(cfg.get("cell", 0)) > 0:
		mapctx.cell_override = int(cfg["cell"])
	rep["cell"] = mapctx.cell_override
	if int(cfg.get("vram_mode", -1)) >= 0:
		mapctx.vram_mode = int(cfg["vram_mode"])
	rep["vram_mode"] = mapctx.vram_mode


	# DRIVE THE DOCK, DO NOT REIMPLEMENT IT.
	#
	# This used to call mapctx.apply() directly with the flags it wanted, which
	# is a different thing from what the panel does and produced a map that
	# built and then did not appear: 40,581 prop surfaces in the tree and 44
	# draw calls on screen. Opening the editor by hand and switching the same
	# layers on works perfectly, which is the whole tell — the dock also sets
	# the detail tier, the range slider, the placed-object cull and the per-map
	# state, and apply() alone does none of that.
	#
	# Setting `button_pressed` fires the same `toggled` handler a click does, so
	# this is the panel being operated rather than imitated.
	t0 = Time.get_ticks_msec()
	var status := "driven through the dock"
	# LET THE DOCK NOTICE THE SCENE FIRST.
	#
	# _check_scene_change() runs on the dock's own half-second timer, and when it
	# sees a new root it deliberately RESETS the panel — mode back to SDK, tier
	# back to Low — so that switching scene tabs stays cheap. Setting the
	# controls before that fires means the timer undoes every one of them a
	# moment later, which is precisely "it doesn't keep the settings": the build
	# never starts, and 900 s later the run times out having placed no props.
	#
	# So wait until the dock's cached root IS this scene, then drive it.
	var sync0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - sync0 < 30000:
		# THE PLUGIN CAN BE FREED UNDER US. The editor re-instantiates the addon
		# after its import scan settles — which is exactly when this runs — and
		# any reach through the old instance then dies with "Cannot call method
		# on a previously freed instance", ending the run with no indication of
		# WHICH object went. Named, rather than crashed on.
		if not is_instance_valid(host):
			rep["error"] = ("the EditorPlugin was freed mid-session: the editor "
					+ "reloaded the addon, so the dock could not be driven")
			_say("autorun: %s" % rep["error"])
			_finish(_tree, cfg, rep)
			return
		if not is_instance_valid(root):
			rep["error"] = "the edited scene root was freed mid-session"
			_say("autorun: %s" % rep["error"])
			_finish(_tree, cfg, rep)
			return
		if host.get("_edited_root") == root:
			break
		await _tree.process_frame
	rep["dock_sync_ms"] = Time.get_ticks_msec() - sync0
	# One more tick past it, so the reset it performs on noticing has finished
	# before anything is set.
	await _tree.create_timer(1.0).timeout

	# `host`, NOT `dock`. mode_btn / mapctx_on / mapctx_range and the rest are
	# members of the EditorPlugin; `dock` is only the VBoxContainer they were
	# added to. Looking them up on the container found nothing and fell straight
	# back to apply() — the path that builds a map and never shows it.
	# ATTRIBUTE THE BUILD, not just time it.
	#
	# The build has been reported as one number — "42.0 s, 2761 props" — for
	# every run so far, which says that it is slow and nothing about WHY. The
	# profiler already carries a phase table (HighpolyProfiler.span) with a call
	# count and a per-call cost, and _build_props_async is instrumented
	# throughout; the table was simply never captured, because span() is a no-op
	# unless a recording is running and the autorun never started one.
	#
	# The scene-walking attribution pass is stopped for the duration. It runs
	# every 2 s and walks the whole tree — during a build, a tree growing by
	# thousands of nodes — so leaving it on would add its own cost to the very
	# thing being measured.
	var prof: Node = host.get("profiler")
	if prof != null:
		prof.start()
		if prof.get("_scan") != null:
			prof._scan.stop()

	var drove := _drive_dock(host, cfg)
	rep["dock_controls"] = drove
	if drove.is_empty():
		# No controls found: fall back to the direct call rather than measure
		# nothing, and say so, because the two are not equivalent.
		status = mapctx.apply(root, true, bool(cfg["objects"]),
				int(cfg["mode"]), bool(cfg["backdrop"]), bool(cfg["water"]))
		rep["dock_fallback"] = true
		_say("autorun: could not find the dock's controls — fell back to "
				+ "apply(), which is NOT what the panel does")
	# apply() launches the props build fire-and-forget, so the wait is on the
	# signal rather than on apply() returning.
	var limit: int = int(cfg["build_timeout_s"]) * 1000
	var sample_ms: int = int(cfg.get("build_sample_s", 0)) * 1000
	var stall_ms: int = int(cfg.get("stall_s", 60)) * 1000
	var last_seen := 0
	var last_change := Time.get_ticks_msec()
	var stopped_early := false
	var stalled := false

	var btick := 0
	while not done[0]:
		await _tree.process_frame
		btick += 1
		if btick % 60 == 0:
			rep["dialogs_dismissed"] = int(rep.get("dialogs_dismissed", 0)) \
					+ _dismiss_dialogs()
		var now := Time.get_ticks_msec()
		if int(prog["done"]) != last_seen:
			last_seen = int(prog["done"])
			last_change = now
		# A STALL IS NOT A TIMEOUT. Waiting the full build budget to discover
		# that nothing moved for ten minutes wastes the run and reports the
		# wrong thing; a build that stops advancing is a hang, and it is worth
		# saying so at the slice it died on.
		# NOT A STALL ONCE EVERY PROP IS PLACED. The build emits no progress
		# while it finishes — flushing the fast-load cache, applying the final
		# cull — so the tail is legitimately silent for a while, and calling
		# that a hang reported build_stalled at 2759 of 2761 on a build that
		# completed perfectly well.
		var placed_all: bool = prog["total"] > 0 and last_seen >= int(prog["total"])
		var quiet_limit: int = stall_ms * 4 if placed_all else stall_ms
		if now - last_change > quiet_limit and last_seen > 0:
			stalled = true
			break
		if sample_ms > 0 and now - t0 >= sample_ms and last_seen > 0:
			stopped_early = true
			break
		if now - t0 >= limit:
			break

	rep["build_ms"] = Time.get_ticks_msec() - t0
	rep["build_done"] = int(prog["done"])
	rep["build_total"] = int(prog["total"])
	rep["build_stalled"] = stalled
	rep["build_sampled"] = stopped_early
	rep["build_timed_out"] = not done[0] and not stopped_early and not stalled
	rep["props_built"] = int(built["props"])
	rep["apply_status"] = status
	rep["props_per_s"] = _rate(prog["samples"])

	if stalled:
		_say("autorun: BUILD STALLED at %d/%d after %.1f s with no progress"
				% [rep["build_done"], rep["build_total"], stall_ms / 1000.0])
	elif stopped_early:
		_say("autorun: sampled the build rate — %.1f props/s at %d/%d after "
				% [rep["props_per_s"], rep["build_done"], rep["build_total"]]
				+ "%.1f s (stopped early, so no flight)" % (rep["build_ms"] / 1000.0))
		# Tear the partial build down rather than leave it half-built: anything
		# measured after this would be measuring an arbitrary fraction of a map.
		mapctx.apply(root, false, false, false)
	else:
		_say("autorun: built in %.1f s (%d props, %.1f/s)%s"
				% [rep["build_ms"] / 1000.0, rep["props_built"],
				   rep["props_per_s"],
				   "  TIMED OUT" if rep["build_timed_out"] else ""])

	# WHAT AN "OPEN IT INSTANTLY" CACHE WOULD HAVE TO HOLD, measured on the
	# finished scene rather than estimated: every distinct mesh, every distinct
	# image, and the per-instance transforms. Distinct is the whole point - the
	# overlay shares one mesh across thousands of placements, so counting per
	# node would report a number many times the truth.
	if bool(cfg.get("cache_size", false)):
		rep["cache_size"] = _cache_size(root)
		_finish(_tree, cfg, rep)
		return

	# ---- fly ---------------------------------------------------------------
	# LIGHTING IS A SEPARATE SWITCH, and leaving it off invalidated a whole
	# round of measurements. apply() takes backdrop and water but NOT lighting,
	# so every run so far had no sun, no shadows and no map lights — which is
	# why changing the shadow cascades moved the draw-call count by exactly
	# zero, three times running. An unlit map is also nothing like the game.
	if bool(cfg.get("lighting", true)) and LightingScript.has_data(str(cfg["map"])):
		var lit: String = LightingScript.apply(root, str(cfg["map"]),
				bool(cfg.get("gi", true)), bool(cfg.get("shadows", true)))
		rep["lighting"] = lit
		if bool(cfg.get("map_lights", true)):
			rep["map_lights"] = await LightingScript.set_map_lights(
					root, true, str(cfg["map"]), Callable())
		_say("autorun: lighting — %s" % lit)
	else:
		rep["lighting"] = "off (no data)" \
				if not LightingScript.has_data(str(cfg["map"])) else "off"

	# NOTHING CULLED. The range slider defaults well below the map, so a flight
	# over a culled map measures the cost of not drawing things — which is not
	# the cost being hunted. 1e9 is the slider's own "no cull" value.
	var radius := float(cfg.get("radius", 1.0e9))
	if mapctx.has_method("set_radius"):
		mapctx.set_radius(radius)
		await _tree.process_frame
	rep["radius"] = radius

	# WAIT FOR THE SKYLINE TOO. The props build signalling "finished" says
	# nothing about the backdrop, which runs alongside it and finishes later on
	# this map: 155 pieces, and the heaviest geometry in the scene.
	# WAIT ON THE SCENE, NOT ON A SIGNAL.
	#
	# Two attempts at this were wrong in ways that both reported success. The
	# first waited only for the props build, so flights began while the skyline
	# was still going. The second watched backdrop_progress but timed its
	# quiet-check from when it CONNECTED — after a 40 s props build that clock
	# was already expired, so it bailed on the first iteration and announced
	# "skyline 155/155 after 0.0 s" about a layer that was not in the tree at all.
	#
	# The census is ground truth: it counts what is actually under _MAP_CONTEXT.
	# A layer that was asked for and has no surfaces is not finished, whatever
	# any signal says.
	if bool(cfg["backdrop"]):
		var bt0 := Time.get_ticks_msec()
		var settled := 0
		var last_surf := -1
		while Time.get_ticks_msec() - bt0 < limit:
			await _tree.process_frame
			# Same guard as the dock sync: a freed root here would take the run
			# down between the build finishing and the flight starting, which is
			# the most expensive place to lose one.
			if not is_instance_valid(root):
				rep["error"] = "the scene root was freed while waiting for the skyline"
				_say("autorun: %s" % rep["error"])
				_finish(_tree, cfg, rep)
				return
			var c := _surface_census(root)
			var s := 0
			if c.has("Backdrop"):
				s = int((c["Backdrop"] as Dictionary)["surfaces"])
			if s > 0 and s == last_surf:
				# Unchanged across checks: it has stopped growing, so it is done
				# rather than merely partway.
				settled += 1
				if settled >= 3:
					break
			else:
				settled = 0
			last_surf = s
			await _tree.create_timer(0.5).timeout
		rep["backdrop_ms"] = Time.get_ticks_msec() - bt0
		rep["backdrop_surfaces"] = last_surf
		rep["backdrop_done"] = int(bd["done"])
		rep["backdrop_total"] = int(bd["total"])
		_say("autorun: skyline settled at %d surfaces (%d/%d) after a further "
				% [last_surf, bd["done"], bd["total"]]
				+ "%.1f s" % (rep["backdrop_ms"] / 1000.0))

	# THE PHASE TABLE, taken here rather than at the end of the run: everything
	# above is the startup being measured, and the flight that follows would mix
	# its own spans into the same totals.
	#
	# Read straight off the static dictionary rather than through the profiler's
	# text summary, so the report carries numbers a script can sort rather than a
	# rendered table a human has to re-parse.
	if prof != null:
		var spans := {}
		for k in HighpolyProfiler._spans:
			var e: Dictionary = HighpolyProfiler._spans[k]
			spans[k] = {"s": round(float(e["ms"])) / 1000.0, "n": int(e["n"]),
					"each_ms": round(float(e["ms"]) / maxf(1.0, float(e["n"])) * 100.0) / 100.0}
		rep["phases"] = spans
		prof.stop()
		var ranked: Array = spans.keys()
		ranked.sort_custom(func(a, b): return float(spans[a]["s"]) > float(spans[b]["s"]))
		for k in ranked.slice(0, 8):
			_say("autorun: phase  %-36s %6.1fs  %6d calls  %7.2f ms each"
					% [str(k).left(36), spans[k]["s"], spans[k]["n"],
					   spans[k]["each_ms"]])

	# IS THE MAP ACTUALLY ON SCREEN? Everything above can succeed and still leave
	# a view with nothing in it — the layers build into the tree while hidden,
	# and if anything leaves them that way the flight measures an empty frame and
	# reports it as a fast one. A run has already done exactly that: 40,581 prop
	# surfaces present in the scene, 44 draw calls during the flight, 4.1 ms a
	# frame, and it looked like a spectacular improvement.
	#
	# So the frame numbers are only published if the camera can see the map.
	if bool(cfg.get("parity_shots", false)):
		rep["parity_shots"] = await _parity_shots(_tree, cfg)
		if bool(cfg.get("parity_only", false)):
			_finish(_tree, cfg, rep)
			return

	var probe_vp := EditorInterface.get_editor_viewport_3d(0)
	var probe_draws := 0
	if probe_vp != null:
		for i in range(5):
			await _tree.process_frame
		probe_draws = probe_vp.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	rep["probe_draws"] = probe_draws
	var have_surfaces := 0
	for k in _surface_census(root).values():
		have_surfaces += int((k as Dictionary)["surfaces"])
	rep["census_surfaces"] = have_surfaces
	if have_surfaces > 1000 and probe_draws < 500:
		rep["flight_error"] = ("the scene holds %d surfaces but the viewport is "
				+ "drawing %d calls — the map is built and NOT VISIBLE, so no "
				+ "frame times are reported") % [have_surfaces, probe_draws]
		_say("autorun: %s" % rep["flight_error"])
		rep["scene_nodes"] = _count_nodes(root)
		rep["engine"] = _engine()
		rep["census"] = _surface_census(root)
		_finish(_tree, cfg, rep)
		return

	# THE MAP'S OWN OCCLUDERS, if it shipped any and the session asked for them.
	#
	# 867 authored quads and boxes on Dumbo. Off by default in the config so that
	# a run measures the same thing as every earlier run unless it says
	# otherwise — a layer that silently switched itself on would make every
	# comparison in the history meaningless.
	if bool(cfg.get("occluders", false)):
		var pj := "%s/%s/placements.json" % [mapctx.CACHE, str(cfg["map"])]
		var occ: Array = []
		var raw := FileAccess.get_file_as_string(pj)
		if raw != "":
			var d = JSON.parse_string(raw)
			if d is Dictionary and (d as Dictionary).has("occluders"):
				occ = (d as Dictionary)["occluders"]
		rep["occluder_records"] = occ.size()
		rep["occluders"] = HighpolyOccluders.apply(root, true, occ)
		_say("autorun: %s" % rep["occluders"])
		for i in range(30):
			await _tree.process_frame

	var samples := _load_path(str(cfg["flight"]))
	rep["flight_samples"] = samples.size()
	if samples.is_empty():
		rep["flight_error"] = "no flight path at %s" % str(cfg["flight"])
		_say("autorun: %s" % rep["flight_error"])
	else:
		# Settle first: the frames straight after a build are not typical, and
		# averaging them in makes every run look worse than it is.
		for i in range(int(cfg["settle_frames"])):
			await _tree.process_frame
		# A PICTURE, before the flight moves the camera.
		#
		# Every number this harness collects is about cost, and a change can be
		# free and still look completely wrong — a ground blown out to white
		# costs exactly what a correct one costs, and a whole session reports it
		# as a 2% frame-time regression. One frame on disk is the only part of
		# this report that can catch that.
		var shot := _shoot("user://bf6_autorun_%s.png" % str(cfg["map"]))
		if shot != "":
			rep["screenshot"] = shot
			_say("autorun: wrote %s" % shot)
		# AND A CLOSE-UP OF ACTUAL FOLIAGE, because the flyover cannot answer a
		# question about leaf cutouts. Six plants in one wide frame puts each at
		# about 40 pixels, and at that size any leafy silhouette reads as speckle
		# whether the cutout is right or wrong - a previous investigation drew a
		# conclusion from exactly that frame and got it wrong. One plant filling
		# the view is the instrument this question needs.
		var fshot: String = await _shoot_foliage(_tree,
			"user://bf6_autorun_%s_foliage.png" % str(cfg["map"]))
		if fshot != "":
			rep["foliage_shot"] = fshot
			_say("autorun: wrote %s" % fshot)
		rep.merge(await _fly(_tree, samples))

		# ---- what is each layer costing? ---------------------------------
		#
		# ONE BUILD, MANY FLIGHTS. Rebooting per layer costs a boot, a scan and a
		# 66 s build each time, and compares runs that were built separately. The
		# scene is already here: switch a layer off, fly the same path, switch it
		# back, and the difference is that layer's cost with everything else held
		# identical.
		#
		# A shorter path for these — every Nth sample of the recorded flight, so
		# it still covers the whole route rather than a corner of it.
		if bool(cfg.get("sweep", false)) and is_instance_valid(host):
			var stride: int = maxi(1, int(cfg.get("sweep_stride", 4)))
			var short: Array = []
			for i in range(0, samples.size(), stride):
				short.append(samples[i])
			var sweep := {}
			# mapctx_gi is SDFGI + SSAO. Those are screen-space and volumetric
			# passes whose cost does NOT scale with our draw calls, so they can
			# hide inside a fixed per-frame figure and never show up in a
			# geometry sweep.
			for layer in ["mapctx_backdrop", "mapctx_objects", "mapctx_water",
						  "mapctx_light", "mapctx_gi", "mapctx_shadows",
						  "mapctx_maplights", "mapctx_fx"]:
				var b = host.get(layer)
				if b == null or not (b is Button) or not (b as Button).button_pressed:
					continue
				var btn: Button = b
				btn.button_pressed = false          # emits toggled
				# Let the teardown finish: some layers free thousands of nodes.
				for i in range(30):
					await _tree.process_frame
				var off := await _fly(_tree, short)
				btn.button_pressed = true
				for i in range(30):
					await _tree.process_frame
				sweep[layer] = {
					"median_ms": off.get("median_ms", 0.0),
					"median_pos_ms": off.get("median_pos_ms", 0.0),
					"engine_ms": off.get("engine_ms", 0.0),
					"draws_mean": off.get("draws_mean", 0),
					"frames": off.get("frames", 0),
				}
				_say("autorun: without %-18s median %6.1f ms (per-pos %6.1f), %6d draws"
						% [layer.replace("mapctx_", ""),
						   off.get("median_ms", 0.0),
						   off.get("median_pos_ms", 0.0),
						   off.get("draws_mean", 0)])
			# BOTH HEAVY LAYERS OFF AT ONCE: the floor. Single-toggle rows each
			# leave the other layer on, so they say what a layer costs but not
			# what is left when neither is there — and that is the ceiling on
			# anything this optimisation can reach.
			var heavy: Array = []
			for layer in ["mapctx_backdrop", "mapctx_objects"]:
				var hb = host.get(layer)
				if hb != null and hb is Button and (hb as Button).button_pressed:
					(hb as Button).button_pressed = false
					heavy.append(hb)
			if not heavy.is_empty():
				for i in range(30):
					await _tree.process_frame
				var floor_r := await _fly(_tree, short)
				sweep["_floor_no_backdrop_no_objects"] = {
					"median_ms": floor_r.get("median_ms", 0.0),
						"median_pos_ms": floor_r.get("median_pos_ms", 0.0),
					"draws_mean": floor_r.get("draws_mean", 0),
					"frames": floor_r.get("frames", 0)}
				_say("autorun: neither backdrop nor objects  median %6.1f ms, %6d draws"
						% [floor_r.get("median_ms", 0.0),
						   floor_r.get("draws_mean", 0)])
				for hb2 in heavy:
					(hb2 as Button).button_pressed = true
				for i in range(30):
					await _tree.process_frame

			# THE ENGINE FLOOR: the whole scene hidden, nothing of ours or the
			# SDK's in the world at all.
			#
			# The "neither layer" row still draws the level's own terrain and
			# combined asset mesh, so it is not the true floor — and the ~11.5 ms
			# it leaves behind is the single biggest term in the 60 fps budget.
			# Whatever remains HERE is the editor drawing itself: viewport
			# gizmos, the grid, the dock, SDFGI and SSAO if they are on. That is
			# either a fixed tax to design around or something to switch off, and
			# the two need telling apart.
			var was_vis: bool = (root as Node3D).visible if root is Node3D else true
			if root is Node3D:
				(root as Node3D).visible = false
				for i in range(30):
					await _tree.process_frame
				var eng_before := _engine()
				var bare := await _fly(_tree, short)
				sweep["_engine_floor_scene_hidden"] = {
					"median_ms": bare.get("median_ms", 0.0),
						"median_pos_ms": bare.get("median_pos_ms", 0.0),
					"draws_mean": bare.get("draws_mean", 0),
					"frames": bare.get("frames", 0),
					"process_ms": snappedf(Performance.get_monitor(
							Performance.TIME_PROCESS) * 1000.0, 0.01),
					"physics_ms": snappedf(Performance.get_monitor(
							Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
					"objects_in_frame": int(Performance.get_monitor(
							Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
					"prims_in_frame": int(Performance.get_monitor(
							Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
					"engine": eng_before,
				}
				_say("autorun: SCENE HIDDEN (engine floor)   median %6.1f ms, "
						% bare.get("median_ms", 0.0)
						+ "%6d draws, process %.2f ms"
						% [bare.get("draws_mean", 0),
						   Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
				(root as Node3D).visible = was_vis
				for i in range(30):
					await _tree.process_frame

			# The same short path with EVERYTHING on, so the comparisons are
			# against a like-for-like reference rather than the full-length run.
			var ref := await _fly(_tree, short)
			# GUARD THE WHOLE SWEEP. If the reference flight looks like a cap
			# rather than a cost, every row beside it is the same cap and the
			# table is worthless. Said loudly and recorded, because a capped
			# sweep has twice been reasoned about as though it were data.
			var capped := HighpolyFlightRun.looks_capped(
					float(ref.get("median_ms", 0.0)),
					float(ref.get("p95_ms", 0.0)))
			if capped != "":
				sweep["_INVALID"] = capped
				_say("autorun: SWEEP INVALID - %s" % capped)
			sweep["_all_on"] = {"median_ms": ref.get("median_ms", 0.0),
								"median_pos_ms": ref.get("median_pos_ms", 0.0),
								"draws_mean": ref.get("draws_mean", 0),
								"frames": ref.get("frames", 0)}
			_say("autorun: with    everything        median %6.1f ms "
					% ref.get("median_ms", 0.0)
					+ "(per-pos %6.1f, engine says %.1f), %6d draws"
					% [ref.get("median_pos_ms", 0.0),
					   ref.get("engine_ms", 0.0), ref.get("draws_mean", 0)])

			# THE SAME FULL CONFIGURATION, CAMERA STANDING STILL. Same
			# viewpoint repeated, so route, duration and sample count are
			# identical to the reference and movement is the only difference.
			# The gap between the two is the answer to "is this a per-frame
			# cost or a per-move cost", and those have opposite fixes: fewer
			# draws for the first, fewer instances to re-cull for the second.
			var still_all: Array = []
			for i in range(short.size()):
				still_all.append(short[0])
			var ref_still := await _fly(_tree, still_all)
			sweep["_all_on_CAMERA_STILL"] = {
				"median_ms": ref_still.get("median_ms", 0.0),
				"median_pos_ms": ref_still.get("median_pos_ms", 0.0),
				"draws_mean": ref_still.get("draws_mean", 0),
				"frames": ref_still.get("frames", 0),
			}
			_say("autorun: everything, CAMERA STILL  median %6.1f ms, %6d draws"
					% [ref_still.get("median_ms", 0.0),
					   ref_still.get("draws_mean", 0)]
					+ "  (movement costs %.1f ms)"
					% (float(ref.get("median_ms", 0.0))
					   - float(ref_still.get("median_ms", 0.0))))

			# HIDDEN VERSUS FREED. The scene is hidden in BOTH this row and the
			# one above, so the only difference between them is whether OUR
			# overlay is still in the tree.
			#
			# Why it is worth a row of its own: hidden-with-overlay costs about
			# 17 ms with FIFTEEN draw calls, while the same scene with no
			# overlay at all measures 2.3 ms and an empty editor 0.04 ms. If the
			# cost tracks what is PRESENT rather than what is drawn, then every
			# hide-based mechanism here rests on a false premise - the HLOD bake
			# hides the originals instead of freeing them, the placed cull works
			# on-hidden, and the layer chips hide. One measurement decides that,
			# and it is cheaper than another nine bench runs on merging.
			#
			# Destructive on purpose: this tears the overlay down, so it runs
			# last and the reference row below is taken before it.
			var mo = host.get("mapctx_on")
			if mo != null and mo is Button and (mo as Button).button_pressed \
					and root is Node3D and mapctx != null:
				var vis2: bool = (root as Node3D).visible
				var before_nodes := int(_engine().get("nodes", 0))
				# NOT the chip. Its handler calls set_context_shown(), which
				# the code itself calls a "fast show/hide of the built
				# terrain/backdrop/water layers" - it hides and frees nothing.
				# Toggling it measured 67,784 nodes before AND after, so the
				# first version of this row compared the hidden state against
				# itself and read a 0.1 ms difference as a result.
				#
				# apply(root, false, ...) is the real teardown: it bumps the
				# build generation, stops the in-flight builder and frees
				# _MAP_CONTEXT.
				mapctx.apply(root, false, false, true, false, false)
				# Freeing tens of thousands of nodes is not instant, and the
				# node counter is the only honest signal that it happened. Wait
				# for the count to actually fall rather than for a frame budget
				# that was enough once; the row reports what it saw either way.
				for i in range(600):
					await _tree.process_frame
					if int(_engine().get("nodes", 0)) < before_nodes - 1000:
						break
				(root as Node3D).visible = false
				for i in range(30):
					await _tree.process_frame
				var freed_eng := _engine()
				var freed := await _fly(_tree, short)
				sweep["_floor_overlay_FREED_scene_hidden"] = {
					"median_ms": freed.get("median_ms", 0.0),
					"median_pos_ms": freed.get("median_pos_ms", 0.0),
					"draws_mean": freed.get("draws_mean", 0),
					"frames": freed.get("frames", 0),
					"nodes_before": before_nodes,
					"engine": freed_eng,
				}
				_say("autorun: OVERLAY FREED + scene hidden  median %6.1f ms "
						% freed.get("median_ms", 0.0)
						+ "(engine says %.1f), " % freed.get("engine_ms", 0.0)
						+ "%6d draws, nodes %d (was %d)"
						% [freed.get("draws_mean", 0),
						   int(freed_eng.get("nodes", 0)), before_nodes])

				# ...AND THE SAME STATE WITH THE CAMERA STANDING STILL.
				#
				# 11.7 ms with the scene hidden, our props freed and FOURTEEN
				# draw calls is not rendering, and the per-position medians say
				# why to look here: the heavy configuration costs 61.6 ms per
				# viewpoint against a 36.1 ms per-frame median, so the expense
				# is concentrated in the frame AFTER the camera moves. This
				# feeds _fly the same viewpoint over and over, so the route,
				# the duration and the sample count are identical and the only
				# thing removed is movement.
				#
				# If still is cheap, the floor is movement-driven work (culling
				# churn, streaming, whatever the plugin does on camera change)
				# and not a fixed per-frame tax, which are opposite problems
				# with opposite fixes.
				var still: Array = []
				for i in range(short.size()):
					still.append(short[0])
				var freed_still := await _fly(_tree, still)
				sweep["_floor_FREED_hidden_CAMERA_STILL"] = {
					"median_ms": freed_still.get("median_ms", 0.0),
					"median_pos_ms": freed_still.get("median_pos_ms", 0.0),
					"draws_mean": freed_still.get("draws_mean", 0),
					"frames": freed_still.get("frames", 0),
				}
				_say("autorun: ...same, CAMERA STILL         median %6.1f ms "
						% freed_still.get("median_ms", 0.0)
						+ "(engine says %.1f), " % freed_still.get("engine_ms", 0.0)
						+ "%6d draws  (movement costs %.1f ms)"
						% [freed_still.get("draws_mean", 0),
						   float(freed.get("median_ms", 0.0))
						   - float(freed_still.get("median_ms", 0.0))])
				(root as Node3D).visible = vis2

			# THE WHOLE-SWEEP CHECK, once every row exists. A capped run gives
			# itself away by the CONFIGURATIONS NOT DIFFERING, which is only
			# visible across rows: an empty scene and a full one cannot cost
			# the same. Two capped sweeps have been read as data in this
			# session alone, and the per-flight check missed both.
			var sweep_bad := HighpolyFlightRun.sweep_looks_capped(sweep)
			if sweep_bad != "":
				sweep["_INVALID"] = sweep_bad
				_say("autorun: SWEEP INVALID - %s" % sweep_bad)
			rep["sweep"] = sweep
	rep["scene_nodes"] = _count_nodes(root)
	rep["engine"] = _engine()
	rep["census"] = _surface_census(root)
	rep["dialogs_seen"] = _dialogs_seen
	# The crumb trail, which is the only record that survives a crash. If the
	# editor dies mid-run there is no report at all, and this is what the next
	# session reads to find out where it died.
	rep["last_crumb"] = HighpolyProfiler.last_session_end()

	# PUT THE RANGE SLIDER BACK. The bench drives it to No Culling so nothing
	# is measured already culled, and the dock PERSISTS it into project
	# metadata per map - so without this, one unattended run leaves the user's
	# editor in its slowest configuration for every future session. That is
	# exactly what happened: a user reporting 30 fps was found at the top
	# notch with 15,719 draw calls, and pulling it to 600 took them from 51 to
	# 65-70 fps. Same failure as the editor sleeps earlier: a harness changing
	# the user's settings and not changing them back.
	var nc_was = drove.get("nocull_was")
	if nc_was != null and host.get("mapctx_nocull") != null:
		var ncb: Button = host.mapctx_nocull
		if ncb.button_pressed != bool(nc_was):
			ncb.button_pressed = bool(nc_was)     # emits, re-applies the radius
			rep["nocull_restored_to"] = nc_was
			_say("autorun: No Cull put back to %s" % ("on" if nc_was else "off"))
	var restore_to = drove.get("range_was")
	if restore_to != null and host.get("mapctx_range") != null:
		var sl2: HSlider = host.mapctx_range
		if not is_equal_approx(float(sl2.value), float(restore_to)):
			sl2.value = float(restore_to)
			sl2.value_changed.emit(sl2.value)
			_say("autorun: range slider put back to %s" % _range_of(restore_to))
			rep["range_restored_to"] = restore_to
	_finish(_tree, cfg, rep)


static func _range_of(v) -> String:
	return "No Culling" if float(v) >= 3500.0 else "%d m" % int(v)


# Props per second, from the second half of the samples.
#
# The FIRST slices are not representative: the prefetch pool is still filling
# and the first batch of textures is being decoded, so including them reports a
# build as slower than it runs. Measured on Contaminated the rate is flat
# (~50/s across all ten deciles) once past that, which is what makes sampling a
# window legitimate at all.
static func _rate(samples: Array) -> float:
	if samples.size() < 4:
		return 0.0
	var half: int = int(samples.size() / 2)
	var a: Array = samples[half]
	var b: Array = samples[samples.size() - 1]
	var dt := (float(b[0]) - float(a[0])) / 1000.0
	if dt <= 0.0:
		return 0.0
	return snappedf((float(b[1]) - float(a[1])) / dt, 0.1)


# What the engine is doing that the plugin did not ask for.
#
# "The editor is slow" has more than once turned out to be orphaned nodes, a
# resource count that only grows, or video memory climbing until the driver
# starts evicting. None of that appears in a frame-time average, and all of it
# is free to read.
static func _engine() -> Dictionary:
	return {
		"mem_static_mb": snappedf(Performance.get_monitor(
				Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"vram_mb": snappedf(Performance.get_monitor(
				Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"texture_mb": snappedf(Performance.get_monitor(
				Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"buffer_mb": snappedf(Performance.get_monitor(
				Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, 0.1),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(
				Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"resources": int(Performance.get_monitor(
				Performance.OBJECT_RESOURCE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"prims": int(Performance.get_monitor(
				Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
	}


# Close anything modal that opened while nobody was watching.
#
# The SDK project loads several other plugins, and they put dialogs up: an
# import prompt, a "scene has unsaved changes", a plugin's own error box. In an
# interactive session someone clicks them. In an unattended one they sit there
# holding a modal grab, and everything after that point either stalls or is
# measured with a dialog on top of it.
#
# Ours are left ALONE. The migration wizard and the scope prompt are skipped
# before this ever runs (see _startup), so any dialog appearing here belongs to
# something else, and closing our own would hide a real problem.
#
# -> how many were dismissed, which is worth recording: a run that had to close
# four dialogs is not the same run as one that closed none.
# Operate the panel's own controls, in the order a person would.
#
# -> which controls were actually found and set, so a run that quietly missed
# one is visible in the report rather than showing up as a mysteriously empty
# map twenty minutes later.
static func _drive_dock(plug: Node, cfg: Dictionary) -> Dictionary:
	var out := {}
	if plug == null:
		return out

	# Detail mode first: everything else is gated on it, and the layer switches
	# read it when they build.
	if plug.get("mode_btn") != null:
		var mb: OptionButton = plug.mode_btn
		var want := int(cfg["mode"])
		for i in range(mb.item_count):
			if mb.get_item_id(i) == want:
				mb.select(i)
				mb.item_selected.emit(i)
				out["mode"] = want
				break

	# The range slider BEFORE the layers, so nothing is built already culled.
	# Its own "no culling" position is the top of its range.
	if plug.get("mapctx_range") != null:
		var sl: HSlider = plug.mapctx_range
		# WHAT IT WAS, so it can be PUT BACK. This slider does not just drive
		# the run: the dock persists it into project metadata per map, so the
		# value the bench leaves behind is restored in every future editor
		# session for that map.
		#
		# That is not theoretical. A user reported the editor "struggling to
		# be stable at 30 fps" and was found working at the top notch, which
		# is No Culling, with 15,719 draw calls. Pulling it to 600 took the
		# frame from 25-28 ms of CPU to 13-14 and 51 fps to 65-70. One bench
		# run had silently pinned their editor in its worst configuration, and
		# there have been about 130 runs on that machine.
		out["range_was"] = sl.value
		# NO CULLING IS THE BUTTON NOW, not the top of the slider. RULE 1 means
		# a radius of 1e9; the slider's maximum is 1000 m, which would quietly
		# turn the bench's headline condition into "a kilometre" and make every
		# figure incomparable with the ones before it.
		var nc = plug.get("mapctx_nocull")
		if nc != null and nc is Button:
			out["nocull_was"] = (nc as Button).button_pressed
			(nc as Button).button_pressed = true      # emits, re-applies radius
		else:
			sl.value = sl.max_value
			sl.value_changed.emit(sl.value)
		out["range"] = sl.value

	# Then the layers themselves. button_pressed fires `toggled`, which is the
	# same path a click takes.
	# mapctx_objects IS "Original map objects" and it has its OWN switch, living
	# on the Detail Mode chip row rather than beside the other map-context
	# toggles. Leaving it out of this list is why every driven run came up with
	# the whole overlay present EXCEPT the level's own objects.
	for pair in [["mapctx_on", true],
				 ["mapctx_objects", bool(cfg.get("objects", true))],
				 ["mapctx_backdrop", bool(cfg["backdrop"])],
				 ["mapctx_water", bool(cfg["water"])],
				 ["mapctx_light", bool(cfg.get("lighting", true))],
				 ["mapctx_gi", bool(cfg.get("gi", true))],
				 ["mapctx_shadows", bool(cfg.get("shadows", true))],
				 ["mapctx_maplights", bool(cfg.get("map_lights", true))]]:
		var name := str(pair[0])
		var want_on := bool(pair[1])
		var b = plug.get(name)
		if b == null or not (b is Button):
			continue
		var btn: Button = b
		if btn.button_pressed != want_on:
			btn.button_pressed = want_on          # emits toggled
		else:
			btn.toggled.emit(want_on)             # already there: still run it
		out[name] = want_on
	return out


static func _dismiss_dialogs() -> int:
	var base := EditorInterface.get_base_control()
	if base == null:
		return 0
	var n := 0
	for w in _windows(base.get_tree().root, 0):
		if not w.visible:
			continue
		var nm := str(w.name)
		if nm.begins_with("Highpoly"):
			continue
		# RECORDED, NOT BLINDLY CLOSED. Hiding whatever appears is how an
		# unattended run silently cancels something it needed: the SDK fetches a
		# map's content on demand and ASKS FIRST, so dismissing its prompt
		# leaves the level an empty shell whose assets "do not exist" — which
		# then reads as a corrupted project rather than a cancelled download.
		#
		# So the title goes in the report and only dialogs known to be safe to
		# close are closed. Anything else is left alone and named, and a run
		# that hangs behind one says which one.
		var title := ""
		if w is AcceptDialog:
			title = (w as AcceptDialog).title
		elif w is Window:
			title = (w as Window).title
		_dialogs_seen[title] = int(_dialogs_seen.get(title, 0)) + 1
		var low := title.to_lower()
		var safe := low.contains("error") or low.contains("warning") \
				or low.contains("debugger") or low.contains("output")
		if safe and w is AcceptDialog:
			(w as AcceptDialog).hide()
			n += 1
	return n


static func _windows(n: Node, depth: int) -> Array:
	var out: Array = []
	if depth > 6:
		return out
	for c in n.get_children():
		if c is Window:
			out.append(c)
		out.append_array(_windows(c, depth + 1))
	return out


# Where the draw calls come from, by layer.
#
# A total is not actionable: 49,277 says the map is expensive and nothing about
# what to change. A draw call is issued per SURFACE per visible instance, so
# counting surfaces under each layer of _MAP_CONTEXT points straight at whatever
# is worth attacking — and it is cheap enough to record on every run.
#
# Counts what is THERE, not what is on screen. A frustum-accurate count would
# vary along the flight and could not be compared between runs.
static func _surface_census(root: Node) -> Dictionary:
	var out := {}
	var ctx := root.get_node_or_null("_MAP_CONTEXT") if root != null else null
	if ctx == null:
		return out
	for layer in ctx.get_children():
		var acc := {"nodes": 0, "instances": 0, "surfaces": 0}
		_census_walk(layer, acc)
		# VISIBILITY IS PART OF THE CENSUS. A layer builds while hidden and is
		# restored at the end, so "40,581 surfaces present, 44 draw calls" is
		# the signature of a layer left invisible — and without this it looks
		# like the renderer ignoring geometry that is right there.
		if layer is Node3D:
			acc["visible"] = (layer as Node3D).visible
			acc["visible_in_tree"] = (layer as Node3D).is_visible_in_tree()
		if int(acc["surfaces"]) > 0:
			out[str(layer.name)] = acc
	if ctx is Node3D:
		out["_MAP_CONTEXT"] = {"visible": (ctx as Node3D).visible,
				"visible_in_tree": (ctx as Node3D).is_visible_in_tree(),
				"nodes": 0, "instances": 0, "surfaces": 0}
	return out


static func _census_walk(n: Node, acc: Dictionary) -> void:
	acc["nodes"] = int(acc["nodes"]) + 1
	if n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh != null and mmi.multimesh.mesh != null:
			# A MultiMesh batches its INSTANCES but not its surfaces: the draw
			# cost is one call per surface, however many copies it holds.
			acc["instances"] = int(acc["instances"]) + mmi.multimesh.instance_count
			acc["surfaces"] = int(acc["surfaces"]) \
					+ mmi.multimesh.mesh.get_surface_count()
	elif n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			acc["instances"] = int(acc["instances"]) + 1
			acc["surfaces"] = int(acc["surfaces"]) + mi.mesh.get_surface_count()
	for c in n.get_children():
		_census_walk(c, acc)


static func _fly(_tree: SceneTree, samples: Array) -> Dictionary:
	# OUR OWN VIEWPORT ONTO THE EDITOR'S WORLD, rather than driving the editor
	# camera.
	#
	# The obvious route does not exist. EditorInterface.get_editor_viewport_3d()
	# returns a plain SubViewport, not the spatial-editor control, so
	# `set_camera_transform` is simply not there — "Nonexistent function
	# 'set_camera_transform' in base 'SubViewport'". (addons/godot_mcp calls
	# exactly that and must fail the same way; taking its existence as proof the
	# call worked is what cost this a run.) Setting the returned viewport's
	# Camera3D transform directly does not work either: the spatial editor
	# recomputes it from its own cursor every frame and overwrites whatever was
	# written.
	#
	# Sharing the World3D sidesteps all of it. Same scene, same geometry, same
	# lights, same materials — a camera we own and can put exactly where the
	# recording says. What this measures is the cost of DRAWING THE SCENE, which
	# is the thing being optimised.
	#
	# It is honest about one difference: the editor viewport keeps rendering
	# alongside this one, so the absolute numbers include both. That is stable
	# across runs, so before/after comparisons hold; treat the values as a
	# baseline to beat rather than as an fps the user would see.
	# THE EDITOR'S OWN VIEWPORT, driven by writing its Camera3D transform.
	#
	# This was written the long way round first — a private SubViewport sharing
	# the scene's World3D — on the assumption that the spatial editor recomputes
	# its camera from an internal cursor every frame and would overwrite
	# anything written to it. Measured instead of assumed: 455 of 455 samples
	# held. It does not fight back.
	#
	# Using it directly is better on both counts. The flight is VISIBLE, so a
	# run that silently measured nothing cannot be mistaken for a good one. And
	# the private viewport was drawing the whole scene a SECOND time every
	# frame, so every number it produced included two renders of Dumbo.
	var evp := EditorInterface.get_editor_viewport_3d(0)
	if evp == null:
		return {"flight_error": "no 3D editor viewport"}
	var cam: Camera3D = evp.get_camera_3d()
	if cam == null:
		return {"flight_error": "the editor viewport has no camera"}
	var sub := evp

	# THE EDITOR THROTTLES ITSELF WHEN NOTHING HAS FOCUS, and an unattended run
	# never has focus. `unfocused_low_processor_mode_sleep_usec` defaults to
	# 100000, so every frame slept 100 ms and the first flight reported mean
	# 100.0, median 100.0, worst 105.5 — a flat 10 fps with almost no variance,
	# which is the signature of a cap rather than a cost. It even looked
	# plausible for a heavy map.
	#
	# Both sleeps go to zero for the flight and are put back afterwards; leaving
	# a user's editor spinning at full tilt would be a real cost to them.
	# UNCONDITIONALLY, via the shared helper. Reading the current value first
	# and only zeroing when one existed meant a machine whose settings had
	# never been written (every fresh install) skipped the zeroing silently
	# and measured the 100 ms unfocused cap. The helper also parks the old
	# values on disk so a killed run cannot leave them at zero.
	var saved_sleeps := HighpolyFlightRun.zero_sleeps()

	# The camera being written IS the editor's, so the stick check is now a
	# self-check rather than an experiment: it confirms the write held for the
	# frame that was timed. Measured at 455 of 455 when this was still a
	# separate probe, which is what allowed the private viewport to be dropped.
	var stuck := 0
	var times: Array[float] = []
	var draws: Array[int] = []
	var shadow_draws: Array[int] = []
	# REPLAY AT THE RECORDED SPEED, not one sample per frame.
	#
	# Advancing a sample every frame ties the camera's SPEED to the frame rate:
	# at 134 ms a frame the route takes 61 s, and with the scene hidden at 10 ms
	# a frame the same route takes 4.5 s — a thirteen times faster fly-through.
	# Anything the renderer does over TIME rather than per frame (shadow cascade
	# updates, SDFGI convergence, LOD hysteresis, culling coherence) is then
	# answering a different question in each configuration.
	#
	# The recorder samples at 20 Hz, so each sample is held for its 50 ms of wall
	# clock and every frame drawn in that window is timed. A slow config gets one
	# frame per sample exactly as before; a fast one gets several, which is more
	# data rather than a different route.
	# ...AND THE SECOND-ORDER VERSION OF THE SAME TRAP, which holding the
	# route at a fixed speed does NOT fix.
	#
	# `times` is per FRAME, not per POSITION. A slow config draws one frame at
	# each viewpoint; a fast one draws five or six. The FIRST frame after the
	# camera moves is the expensive one - it pays for whatever the move
	# triggered in culling, streaming and newly visible geometry - and the
	# repeats behind it are cheap. So a fast configuration contributes far
	# more cheap repeat frames and its median comes out flattered, which
	# biases exactly the comparison the sweep exists to make: a heavy layer
	# looks heavier than it is.
	#
	# So the first frame of each sample is kept separately too. One frame per
	# viewpoint, every configuration weighted identically. Both are reported:
	# if they agree the bias is negligible and that is worth knowing, and if
	# they diverge the per-position figure is the honest one for comparing
	# configurations.
	var first_times: Array[float] = []
	var fps_samples: Array[float] = []
	var hold_us := 50000
	for s in samples:
		cam.global_transform = s
		var until := Time.get_ticks_usec() + hold_us
		var first := true
		while true:
			var t0 := Time.get_ticks_usec()
			await _tree.process_frame
			var dt := (Time.get_ticks_usec() - t0) / 1000.0
			times.append(dt)
			# THE ENGINE'S OWN FRAME RATE, beside our stopwatch.
			#
			# `times` is wall clock around `await process_frame`, so it
			# includes everything this loop itself does between frames - the
			# counter reads, the transform write, the awaits. The engine's fps
			# counter does not. When the two disagree, the gap IS the observer
			# effect, and it matters: a floor of 11 ms with FIFTEEN draw calls
			# is either something real in the editor or it is this harness
			# measuring itself, and those need telling apart before anyone
			# optimises anything.
			fps_samples.append(Engine.get_frames_per_second())
			if first:
				first_times.append(dt)
				first = false
			# BOTH PASSES. RENDER_INFO_TYPE_VISIBLE counts only the camera pass;
			# shadow rendering is counted separately under _TYPE_SHADOW. Reading
			# just the first made the draw-call total identical to the digit
			# across a shadow-cascade change, a blend-splits change and turning
			# lighting on — which looked like the measurement was stuck rather
			# than like it was measuring the wrong half.
			draws.append(sub.get_render_info(
					Viewport.RENDER_INFO_TYPE_VISIBLE,
					Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
			shadow_draws.append(sub.get_render_info(
					Viewport.RENDER_INFO_TYPE_SHADOW,
					Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
			# At least one frame per sample, then keep drawing until this
			# sample's slice of wall clock is spent.
			if Time.get_ticks_usec() >= until:
				break
		if cam.global_transform.origin.distance_to(s.origin) < 0.5:
			stuck += 1
	var tried := samples.size()

	HighpolyFlightRun.restore_sleeps(saved_sleeps)
	# NOTHING TO FREE. `sub` is the editor's OWN viewport now, not a private one
	# — an earlier version created its own and freed it here, and leaving that
	# free() behind after the switch would have destroyed the editor's 3D view.
	if times.is_empty():
		return {"flight_error": "no frames recorded"}

	# HITCHES ARE THE POINT, so they are counted before anything is averaged.
	# A flight that is smooth for 90% of its length and stalls twice is one
	# people call broken, and a mean hides exactly that.
	var mean := 0.0
	for t in times:
		mean += t
	mean /= float(times.size())
	# FIXED THRESHOLDS, because the old one moved with the thing it measured.
	#
	# It was `t > max(50, mean * 3)`. At the recorded baseline's 32.1 ms mean the
	# bar sat at 96.3 ms; once the map reached an 18.3 ms mean the bar fell to
	# 54.9 ms — so the same flight was judged against a threshold 41 ms lower,
	# the count went 1 -> 100, and the table dutifully printed "9900% WORSE" for
	# a map that had just got twice as fast. Every hitch figure in this project's
	# history is scaled to its own run's mean and none of them are comparable.
	#
	# Absolute now, and two of them, because they answer different questions:
	# 33.3 ms is a frame that missed 30 fps and is FELT as a stutter; 50 ms is a
	# visible lurch. Neither depends on how good the rest of the run was.
	var hitches := 0
	var stutters := 0
	for t in times:
		if t > 50.0:
			hitches += 1
		if t > 33.3:
			stutters += 1

	var sorted := times.duplicate()
	sorted.sort()
	var n := sorted.size()
	var worst_n: int = maxi(1, int(n * 0.01))
	var low1 := 0.0
	for i in range(n - worst_n, n):
		low1 += sorted[i]
	low1 /= float(worst_n)
	var dsum := 0
	var ssum := 0
	var smax := 0
	var dmax := 0
	for d in draws:
		dsum += d
		dmax = maxi(dmax, d)
	for s in shadow_draws:
		ssum += s
		smax = maxi(smax, s)

	# ONE FRAME PER VIEWPOINT. See the note at the sample loop: the per-frame
	# median under-weights expensive viewpoints, and does so more in a fast
	# configuration, which is precisely the comparison the sweep makes.
	var pos_sorted := first_times.duplicate()
	pos_sorted.sort()
	var pn := pos_sorted.size()
	var pos_median := 0.0
	var pos_mean := 0.0
	if pn > 0:
		pos_median = pos_sorted[pn / 2]
		for t in pos_sorted:
			pos_mean += t
		pos_mean /= float(pn)

	# The engine's own frame time, for comparison with our stopwatch above.
	var eng_ms := 0.0
	if not fps_samples.is_empty():
		var f := fps_samples.duplicate()
		f.sort()
		var mid: float = f[f.size() / 2]
		eng_ms = (1000.0 / mid) if mid > 0.0 else 0.0

	return {
		"frames": n,
		"positions": pn,
		"engine_ms": snappedf(eng_ms, 0.01),
		"editor_cam_stuck": stuck,
		"editor_cam_tried": tried,
		"mean_ms": snappedf(mean, 0.01),
		"median_ms": snappedf(sorted[n / 2], 0.01),
		# The per-POSITION figures, weighted identically across configs.
		"median_pos_ms": snappedf(pos_median, 0.01),
		"mean_pos_ms": snappedf(pos_mean, 0.01),
		"p95_pos_ms": snappedf(pos_sorted[mini(pn - 1, int(pn * 0.95))], 0.01) \
			if pn > 0 else 0.0,
		"p95_ms": snappedf(sorted[mini(n - 1, int(n * 0.95))], 0.01),
		"p99_ms": snappedf(sorted[mini(n - 1, int(n * 0.99))], 0.01),
		"low1_ms": snappedf(low1, 0.01),
		"worst_ms": snappedf(sorted[n - 1], 0.01),
		"hitches50": hitches,
		"hitches33": stutters,
		"draws_mean": int(dsum / maxi(1, n)),
		"draws_peak": dmax,
		"shadow_draws_mean": int(ssum / maxi(1, n)),
		"shadow_draws_peak": smax,
	}


# The recorded path as editor-camera transforms.
#
# The basis is stored as nine floats rather than a quaternion precisely so the
# replay can reproduce the view EXACTLY; going through euler angles here — which
# is what a naive set_editor_camera call would do — reintroduces the rounding
# the recorder went out of its way to avoid.
# One frame of the 3D viewport to a png, or "" if there is nothing to shoot.
#
# The editor viewport rather than the SceneTree's root: this runs inside the
# editor, and the tree's own viewport is the editor's UI, which would produce a
# screenshot of a dock.
static func _shoot(path: String) -> String:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return ""
	var tex := vp.get_texture()
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null or img.get_width() < 8:
		return ""
	if img.save_png(path) != OK:
		return ""
	return path


# Park the editor camera on the biggest piece of vegetation and photograph it.
#
# Foliage is found by MATERIAL, not by name: a mesh counts as vegetation when a
# surface carries the foliage_wind shader, which the game path only assigns when
# the depot bound the vegetation basecolor slot. Name matching was tried in an
# earlier probe and duly picked a street lamp, because "street" contains "tree".
static func _shoot_foliage(_tree: SceneTree, path: String) -> String:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	var ctx := root.get_node_or_null("_MAP_CONTEXT")
	if ctx == null:
		return ""
	# PLANT-SIZED AND WELL-INSTANCED, not "biggest".
	#
	# "Biggest foliage mesh" picked a BACKDROP ATLAS CARD - those carry the same
	# vegetation material and are hundreds of metres across - so the camera was
	# parked `size * 1.3` away and photographed the whole city. Bound the size to
	# something that can be a plant and then prefer the mesh with the most
	# instances, which is the one there is most of to look at.
	var best_score := -1
	var best_size := 0.0
	var best_at := Vector3.ZERO
	var found := false
	var stack: Array = [ctx]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MultiMeshInstance3D):
			continue
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		var mesh := mmi.multimesh.mesh
		var leafy := false
		for i in range(mesh.get_surface_count()):
			var m = mesh.surface_get_material(i)
			if m is ShaderMaterial and (m as ShaderMaterial).shader != null 					and str((m as ShaderMaterial).shader.resource_path).ends_with(
						"/foliage_wind.gdshader"):
				leafy = true
				break
		if not leafy:
			continue
		var sz := mesh.get_aabb().get_longest_axis_size()
		var count := mmi.multimesh.instance_count
		if count == 0 or sz < 1.0 or sz > 25.0:
			continue
		if count <= best_score:
			continue
		var gx: Transform3D = mmi.global_transform if mmi.is_inside_tree() 			else mmi.transform
		best_score = count
		best_size = sz
		best_at = (gx * mmi.multimesh.get_instance_transform(0)).origin 			+ Vector3(0.0, mesh.get_aabb().size.y * 0.5, 0.0)
		found = true
	if not found:
		_say("autorun: no foliage material in the scene to photograph")
		return ""
	var evp := EditorInterface.get_editor_viewport_3d(0)
	if evp == null:
		return ""
	var cam: Camera3D = evp.get_camera_3d()
	if cam == null:
		return ""
	# Far enough to hold the whole plant, close enough that leaves are hundreds
	# of pixels rather than tens.
	var dist: float = clampf(best_size * 1.4, 2.5, 30.0)
	var eye := best_at + Vector3(dist * 0.7, dist * 0.35, dist * 0.7)
	cam.global_transform = Transform3D().looking_at(best_at - eye, Vector3.UP)
	cam.global_transform.origin = eye
	# The editor throttles itself when unfocused; without this the frames after
	# the move are the pre-move image.
	var es := EditorInterface.get_editor_settings()
	var k := "interface/editor/unfocused_low_processor_mode_sleep_usec"
	var was = es.get_setting(k) if es.has_setting(k) else null
	if was != null:
		es.set_setting(k, 0)
	for i in range(20):
		await _tree.process_frame
	var out := _shoot(path)
	if was != null:
		es.set_setting(k, was)
	_say(("autorun: foliage close-up - %d instances of a %.1f m plant at %s, "
		+ "camera %.1f m away, ended at %s")
		% [best_score, best_size, str(best_at), dist,
		   str(cam.global_transform.origin)])
	return out


# PICTURES OF THE PARITY LAYERS, framed from what the build produced rather than
# from recorded coordinates: the sea from its shore, a road marking from above,
# the terrain's rim, and a loot spawner holding a configured weapon. Each view
# is written as user://bf6_parity_<map>_<name>.png; the water is shot twice,
# half a second apart, so its motion can be compared.
static func _parity_shots(tree: SceneTree, cfg: Dictionary) -> Dictionary:
	var out := {}
	# The 3D viewport only draws while it is the main screen; the SDK's Home
	# screen may be in front after a map opens.
	EditorInterface.set_main_screen_editor("3D")
	for i in range(10):
		await tree.process_frame
	var root := EditorInterface.get_edited_scene_root()
	var evp := EditorInterface.get_editor_viewport_3d(0)
	if root == null or evp == null or evp.get_camera_3d() == null:
		return {"error": "no scene or editor camera"}
	var cam: Camera3D = evp.get_camera_3d()
	var ctx := root.get_node_or_null("_MAP_CONTEXT")
	var map := str(cfg["map"])
	var views: Array = []
	if ctx != null and not bool(cfg.get("radial_only", false)):
		var water := ctx.get_node_or_null("Water")
		if water != null:
			for c in water.get_children():
				if c is MultiMeshInstance3D and c.has_meta("bf6_water_tiled"):
					var b: PackedFloat32Array = c.get_meta("bf6_water_tiled")
					var centre := Vector3((b[0] + b[2]) * 0.5, b[4], (b[1] + b[3]) * 0.5)
					views.append(["water_near", centre + Vector3(0, 4, 0), centre + Vector3(60, 0, 40)])
					views.append(["water_far", centre + Vector3(0, 40, 0), centre + Vector3(400, 0, 300)])
					break
		var roads := ctx.get_node_or_null("Roads")
		if roads != null:
			# The Roads chip may be off in this project; the shots compare them.
			(roads as Node3D).visible = true
			out["road_draw_nodes"] = roads.get_child_count()
			var best: GeometryInstance3D = null
			for c in roads.get_children():
				if c is MeshInstance3D and (c as MeshInstance3D).material_override is ShaderMaterial:
					if ((c as MeshInstance3D).material_override as ShaderMaterial).render_priority == -97:
						best = c
						break
			if best == null and roads.get_child_count() > 0: best = roads.get_child(roads.get_child_count() / 2) as GeometryInstance3D
			if best != null:
				var box: AABB = best.global_transform * best.get_aabb()
				var c := box.get_center()
				views.append(["roads", c + Vector3(-18, 22, -18), c])
				views.append(["roads_low", c + Vector3(-30, 3, -30), c])
		var terrain := ctx.get_node_or_null("Terrain")
		if terrain != null:
			var tb := AABB()
			var first := true
			for c in terrain.get_children():
				if c is GeometryInstance3D:
					var ab: AABB = (c as GeometryInstance3D).global_transform * (c as GeometryInstance3D).get_aabb()
					if first: tb = ab; first = false
					else: tb = tb.merge(ab)
			if not first:
				var mid := tb.get_center()
				views.append(["terrain", Vector3(mid.x, tb.end.y + 150, tb.position.z + tb.size.z * 0.25), mid])
				views.append(["terrain_edge", Vector3(tb.position.x + 40, tb.end.y + 60, mid.z), Vector3(tb.position.x - 200, tb.position.y, mid.z)])
	# A loot spawner with a scope, placed for the picture and never saved.
	var loot_scene := load("res://objects/gameplay/common/LootSpawner.tscn") as PackedScene
	if loot_scene != null and bool(cfg.get("loot", true)) and not bool(cfg.get("radial_only", false)):
		var spawner := loot_scene.instantiate() as Node3D
		root.add_child(spawner)
		spawner.owner = null
		var anchor := cam.global_position
		if not views.is_empty(): anchor = (views[0][2] as Vector3)
		spawner.global_position = Vector3(anchor.x + 3, anchor.y + 1.2, anchor.z + 3)
		var loadout := {"item": "carbine/m4a1"}
		var core = HighpolyLib.LoadoutScript.core_for(HighpolyLib.game_source)
		if core != null:
			var scopes: Array = HighpolyLib.LoadoutScript.slot_choices(core, "carbine/m4a1", "scp")
			if not scopes.is_empty(): loadout["attachment_scp"] = str((scopes[0] as Dictionary).id)
		spawner.set_meta(HighpolyLib.LoadoutScript.LOADOUT_META, loadout)
		var applied := HighpolyLib.apply_one(spawner, "LootSpawner", HighpolyLib.Tier.HIGH, true)
		out["loot_applied"] = applied
		out["loot_loadout"] = loadout
		var p := spawner.global_position
		views.append(["loot", p + Vector3(-0.9, 0.35, 0.0), p])
	for v in views:
		cam.global_transform = Transform3D(Basis(), v[1]).looking_at(v[2], Vector3.UP)
		for i in range(45):
			await tree.process_frame
			cam.global_transform = Transform3D(Basis(), v[1]).looking_at(v[2], Vector3.UP)
		out[v[0]] = _shoot("user://bf6_parity_%s_%s.png" % [map, v[0]])
		out[str(v[0]) + "_view"] = [[v[1].x, v[1].y, v[1].z], [v[2].x, v[2].y, v[2].z]]
		if str(v[0]) == "water_near":
			var t0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - t0 < 500:
				await tree.process_frame
				cam.global_transform = Transform3D(Basis(), v[1]).looking_at(v[2], Vector3.UP)
			out["water_near_later"] = _shoot("user://bf6_parity_%s_water_near_later.png" % map)
	# THE BF6 MENU AND THE RADIAL, photographed as the editor draws them.
	var menu_host: Node = null
	for n in tree.get_nodes_in_group("bf6_plugin_menu_v1"):
		menu_host = n
	if menu_host != null:
		out["menu_sections"] = menu_host.plugins().map(func(p): return "%s:%d:%s" % [p.id, p.order, p.radial])
	var radial: Node = EditorInterface.get_base_control().find_child("BF6Radial", true, false)
	out["radial_present"] = radial != null
	if radial != null:
		var spawners: Array = []
		for c in root.get_children():
			if c is Node3D and (c as Node3D).scene_file_path.get_file() == "LootSpawner.tscn":
				spawners.append(c)
		if not spawners.is_empty():
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(spawners[spawners.size() - 1])
			for i in range(5):
				await tree.process_frame
		radial.open_front()
		for i in range(20):
			await tree.process_frame
		out["radial_front"] = radial._items.map(func(i): return "%s|%s" % [i.label, i.get("sub", "")])
		out["radial_describe"] = radial.describe() if radial.has_method("describe") else {}
		var vp3 := EditorInterface.get_editor_viewport_3d(0)
		var chain: Array = []
		var n: Node = vp3
		while n != null and chain.size() < 8:
			chain.append("%s:%s:%s" % [n.get_class(), n.name, str((n as Control).get_global_rect()) if n is Control else ""])
			n = n.get_parent()
		out["rects"] = {"main": str(EditorInterface.get_editor_main_screen().get_global_rect()),
			"base": str(EditorInterface.get_base_control().get_global_rect()), "chain": chain,
			"vp_size": str(vp3.size)}
		var tall: Array = []
		var stack: Array = [EditorInterface.get_base_control()]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			if node is Control and (node as Control).is_visible_in_tree():
				var ms := (node as Control).get_combined_minimum_size()
				if ms.y > 1400.0:
					tall.append("%s:%s:%s:%s" % [node.get_class(), node.name, str(ms), str(node.get_path()).right(120)])
			for c in node.get_children():
				stack.append(c)
		out["tall_controls"] = tall.slice(0, 60)
		out["radial_shot"] = _shoot_editor("user://bf6_parity_%s_radial.png" % map)
		for i in range(radial._items.size()):
			if str(radial._items[i].label) == "COLLISION":
				radial._highlight = i
				radial.confirm()
				break
		for i in range(20):
			await tree.process_frame
		out["radial_sub"] = radial._items.map(func(i): return "%s|%s" % [i.label, i.get("sub", "")])
		out["radial_sub_shot"] = _shoot_editor("user://bf6_parity_%s_radial_sub.png" % map)
		radial.close()
		# MULTIPLY and ATTACH through their own entry points, on a scene node.
		var seed: Node3D = null
		for c in root.get_children():
			if c is Node3D and c.owner == root and c.scene_file_path != "":
				seed = c
				break
		if seed != null:
			var tools_script: Script = load("res://addons/bf6_extended_workspace/workspace_object_tools.gd")
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(seed)
			await tree.process_frame
			radial.open_front()
			out["radial_selected"] = radial._items.map(func(i): return str(i.label))
			radial.close()
			var before := root.get_child_count()
			var made: int = tools_script.multiply_grid(3, 2, 1.0)
			out["multiply_grid"] = {"made": made, "children_added": root.get_child_count() - before}
			var ring_before := root.get_child_count()
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(seed)
			var ringed: int = tools_script.multiply_circle(6, 8.0)
			out["multiply_circle"] = {"made": ringed, "children_added": root.get_child_count() - ring_before}
			var popup: Window = tools_script.open_multiply(EditorInterface.get_base_control(), EditorInterface.get_base_control().get_global_rect().get_center(), EditorInterface.get_editor_scale(), Callable())
			for i in range(10):
				await tree.process_frame
			out["multiply_panel_shot"] = _shoot_editor("user://bf6_parity_%s_multiply.png" % map)
			# Popups are their own OS window when the editor does not embed them.
			out["multiply_panel_visible"] = popup.visible
			out["multiply_panel_size"] = str(popup.size)
			var pimg: Image = popup.get_texture().get_image() if popup.visible else null
			out["multiply_panel_window_shot"] = pimg != null and pimg.save_png("user://bf6_parity_%s_multiply_panel.png" % map) == OK
			popup.hide()
			# Put the scene back: both multiplies are single undo steps.
			var eur := EditorInterface.get_editor_undo_redo()
			var history := eur.get_history_undo_redo(eur.get_object_history_id(root))
			for i in range(2):
				history.undo()
			out["undo_restores"] = root.get_child_count() == before
			# COLORIZE: metadata on the object, one undo step.
			var view_script: Script = load("res://addons/bf6_extended_workspace/workspace_view_tools.gd")
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(seed)
			var painted: int = view_script.recolor_selection(Color(0.9, 0.2, 0.2))
			var mesh_rid_ok := false
			for g in view_script._meshes(seed):
				mesh_rid_ok = mesh_rid_ok or (g as GeometryInstance3D).get_instance().is_valid()
			out["colorize"] = {"painted": painted, "meta": seed.has_meta(&"bf6_color"), "meshes": view_script._meshes(seed).size(), "rendered": mesh_rid_ok}
			var cpop: Window = view_script.open_colorize(EditorInterface.get_base_control(), EditorInterface.get_base_control().get_global_rect().get_center(), EditorInterface.get_editor_scale(), Callable())
			for i in range(10):
				await tree.process_frame
			var cimg: Image = cpop.get_texture().get_image()
			out["colorize_panel_shot"] = cimg != null and cimg.save_png("user://bf6_parity_%s_colorize_panel.png" % map) == OK
			cpop.hide()
			history.undo()
			out["colorize_undo"] = not seed.has_meta(&"bf6_color")
			# DISPLAY/SUN: turns the sun, draws unlit, pins exposure; reset puts it back.
			EditorInterface.get_selection().clear()
			await tree.process_frame
			radial.open_front()
			out["radial_front_view_aids"] = radial._items.map(func(i): return str(i.label))
			radial.close()
			view_script.set_time(8.0)
			var sun: DirectionalLight3D = view_script.sun_light(false)
			out["display_sun"] = {"sun": str(sun.get_path()) if sun != null else "", "owned": sun != null and sun.owner != null,
				"travel": str(-sun.global_basis.z) if sun != null else ""}
			view_script.set_view_mode(1)
			view_script.set_exposure(1.0)
			var vp0 := EditorInterface.get_editor_viewport_3d(0)
			out["display_sun"]["unlit"] = vp0.debug_draw == Viewport.DEBUG_DRAW_UNSHADED
			out["display_sun"]["exposure"] = vp0.get_camera_3d().attributes != null
			var dpop: Window = view_script.open_display_sun(EditorInterface.get_base_control(), EditorInterface.get_base_control().get_global_rect().get_center(), EditorInterface.get_editor_scale(), Callable())
			for i in range(10):
				await tree.process_frame
			out["display_shot"] = _shoot_editor("user://bf6_parity_%s_display.png" % map)
			var dimg: Image = dpop.get_texture().get_image()
			out["display_panel_shot"] = dimg != null and dimg.save_png("user://bf6_parity_%s_display_panel.png" % map) == OK
			dpop.hide()
			view_script.reset_display_sun()
			await tree.process_frame
			# VALIDATE: the shared core's checks over this scene.
			var validate_script: Script = load("res://addons/bf6_extended_workspace/workspace_validate.gd")
			out["validate_available"] = validate_script.available()
			var scene_desc: Dictionary = validate_script.describe(root)
			out["validate_objects"] = (scene_desc.objects as Array).size()
			out["validate_catalogue"] = scene_desc.has("all_types")
			out["validate_items"] = (validate_script.run(root) as Array).map(func(i): return "%d|%s|%s" % [int(i.severity), str(i.id), str(i.message).left(90)])
			var vpop: Window = validate_script.open(EditorInterface.get_base_control(), EditorInterface.get_base_control().get_global_rect().get_center(), EditorInterface.get_editor_scale(), Callable())
			for i in range(10):
				await tree.process_frame
			var vimg: Image = vpop.get_texture().get_image()
			out["validate_panel_shot"] = vimg != null and vimg.save_png("user://bf6_parity_%s_validate_panel.png" % map) == OK
			vpop.hide()
			out["display_sun"]["reset"] =vp0.debug_draw == Viewport.DEBUG_DRAW_DISABLED and vp0.get_camera_3d().attributes == null and not view_script.touched
			out["modes"] = await _mode_checks(tree, root, seed, map, history)
			out["top_row"] = await _top_row_checks(tree, map)
			out["blocks_budget"] = await _blocks_budget_checks(tree, root, seed, map, history)
			out["spatial"] = _spatial_checks(root, seed, history)
			out["upload"] = _upload_checks(root)
	_say("autorun: parity shots %s" % JSON.stringify(out))
	return out


# OBJECT LIBRARY: the SDK's Scene Library, patched (Tools/patches) so only the
# edited map's collection is on show. Read off its tab bar for the open map, then
# for a second map opened in another tab (never saved).
static func _library_checks(tree: SceneTree, second_map: String) -> Dictionary:
	var res := {}
	var lib: Node = EditorInterface.get_base_control().find_child("ObjectLibrary", true, false)
	res["found"] = lib != null
	if lib == null:
		return res
	res["patched"] = lib.has_method("_bf6_map_only")
	if not res["patched"]:
		return res
	if bool(lib.get("_library_pending")):
		lib.load_library(str(lib.get("_curr_lib_path")))
	for i in 10:
		await tree.process_frame
	res["levels_known"] = (lib._bf6_level_names() as Dictionary).size()
	res["first"] = _library_state(lib)
	# ON THE WORKSPACE'S BOTTOM EDGE, as the Unreal library slides up.
	var host: Control = null
	for n in tree.get_nodes_in_group("bf6_workspace_panels_v1"):
		if n is Control and n.has_method("register_panel"):
			host = n
	var adapter: Node = null
	var stack: Array = [tree.root]
	while not stack.is_empty() and adapter == null:
		var n: Node = stack.pop_back()
		if n.has_method("set_minimize_docks"):
			adapter = n
		stack.append_array(n.get_children(true))
	if host != null and adapter != null:
		for i in 40:
			await tree.process_frame
		var edge := {"hosted": host.has_panel("native.object_library"), "inside_host": host.is_ancestor_of(lib),
			"edge": host.get_panel_edge("native.object_library"), "open_at_rest": host.is_edge_open("bottom")}
		var be: Dictionary = host._edges["bottom"]
		edge["tab_rect"] = str((be["strip"] as Control).get_global_rect())
		edge["tab_visible"] = (be["strip"] as Control).is_visible_in_tree()
		edge["tab_visible_self"] = (be["strip"] as Control).visible
		edge["host_visible"] = host.visible
		edge["host_in_tree_visible"] = host.is_visible_in_tree()
		edge["suppressors"] = (host.get("_visibility_owners") as Dictionary).size()
		var follow: Control = host.get("_follow")
		edge["follow_visible"] = follow.is_visible_in_tree() if follow != null else null
		edge["slide_at_rest"] = float(be["slide"])
		var holders: Array = []
		for w in (host.get("_visibility_owners") as Dictionary).values():
			var o: Object = (w as WeakRef).get_ref()
			if o != null:
				holders.append(o)
		edge["suppressed_by"] = holders.map(func(o): return "%s %s %s" % [o.get_class(), str(o.get("name")), str(o.get_script().resource_path) if o.get_script() != null else ""])
		# lifted for this check only, and put back after it
		for o in holders:
			host.set_visibility_suppressed(o, false)
		for i in 20:
			await tree.process_frame
		edge["tab_visible_unsuppressed"] = (be["strip"] as Control).is_visible_in_tree()
		edge["tab_rect_unsuppressed"] = str((be["strip"] as Control).get_global_rect())
		host._peek("bottom")
		for i in 40:
			await tree.process_frame
		var drawer: Control = be["drawer"]
		edge["after_hover_open"] = host.is_edge_open("bottom")
		edge["slide_after_hover"] = float(be["slide"])
		edge["drawer_visible_self"] = drawer.visible
		edge["drawer_rect"] = str(drawer.get_global_rect())
		edge["host_rect"] = str(host.get_global_rect())
		edge["library_visible"] = lib.is_visible_in_tree()
		var dock: Node = adapter.get("_library_dock")
		edge["dock_closed_while_hosted"] = dock != null and not dock.is_visible_in_tree()
		adapter.set_minimize_docks(false)
		for i in 10:
			await tree.process_frame
		edge["off_back_in_dock"] = lib.get_parent() == dock and not host.has_panel("native.object_library")
		edge["off_dock_parent"] = str(dock.get_parent().name) if dock != null and dock.get_parent() != null else ""
		adapter.set_minimize_docks(true)
		for i in 10:
			await tree.process_frame
		edge["on_again_hosted"] = host.has_panel("native.object_library") and host.is_ancestor_of(lib)
		for o in holders:
			if is_instance_valid(o):
				host.set_visibility_suppressed(o, true)
		res["bottom_edge"] = edge
	var path := ""
	for candidate in ["res://levels/%s.tscn" % second_map, "res://Levels/%s.tscn" % second_map]:
		if ResourceLoader.exists(candidate):
			path = candidate
	res["second_path"] = path
	if path != "":
		EditorInterface.open_scene_from_path(path)
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 120000:
			await tree.process_frame
			var root := EditorInterface.get_edited_scene_root()
			if root != null and str(root.name) == second_map:
				break
		for i in 10:
			await tree.process_frame
		res["second"] = _library_state(lib)
	return res


static func _library_state(lib: Node) -> Dictionary:
	lib._bf6_follow_map()
	var bar: TabBar = lib.get("_collec_tab_bar")
	var visible: Array = []
	var hidden := 0
	for i in bar.get_tab_count():
		if bar.is_tab_hidden(i):
			hidden += 1
		else:
			visible.append(bar.get_tab_title(i))
	var popup: PopupMenu = (lib.get("_all_tabs_list") as MenuButton).get_popup()
	var listed: Array = []
	for i in popup.item_count:
		listed.append("%s#%d" % [popup.get_item_text(i), popup.get_item_id(i)])
	var current := bar.get_current_tab()
	var collection: Dictionary = lib.get_current_collection()
	return {"map": str(lib.get("_bf6_map")), "tabs": bar.get_tab_count(), "hidden": hidden, "visible": visible,
		"current": bar.get_tab_title(current) if current >= 0 else "", "menu": listed,
		"assets_shown": (collection.get(&"assets", []) as Array).size()}


# WALK: the Player Controller's walkthrough on the open level with no collider
# anywhere, standing on and bumping into the drawn terrain and assets through the
# shared core. Dropped in above the middle of the terrain, it has to fall, land at
# eye height on the surface a ray finds below, and walk. A camera of its own is
# used (never the editor's) and freed after.
static func _walk_checks(tree: SceneTree, root: Node) -> Dictionary:
	var res := {}
	var session_script: Script = load("res://addons/bf6_player_controller/preview_session.gd")
	if session_script == null:
		return {"error": "no player controller"}
	var terrain := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		if str(n.get_path()).contains("Terrain"):
			var box: AABB = (n as MeshInstance3D).global_transform * (n as MeshInstance3D).get_aabb()
			terrain = box if first else terrain.merge(box)
			first = false
	res["terrain"] = str(terrain)
	res["physics_bodies"] = root.find_children("*", "CollisionObject3D", true, false).size()
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.owner = null
	var mid := terrain.get_center() if not first else Vector3.ZERO
	cam.global_position = Vector3(mid.x + 7.0, (terrain.end.y if not first else 0.0) + 20.0, mid.z + 11.0)
	var session = session_script.new()
	EditorInterface.get_base_control().add_child(session)
	var t0 := Time.get_ticks_usec()
	res["started"] = session.start(cam, root, 0.0, false)
	res["start_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	if not res["started"]:
		res["status"] = str(session.status.text)
		session.free()
		cam.free()
		return res
	session.set_physics_process(false)
	res["eye"] = session.model.eye
	res["meshes_seen"] = session.model.rays._entries.size()
	res["surfaces_near"] = session.model.rays.instances
	var below: Dictionary = session.model.rays.trace(cam.global_position, cam.global_position - Vector3(0, 5000, 0))
	res["ground_below"] = below.position.y if not below.is_empty() else null
	var t1 := Time.get_ticks_usec()
	var frames := 0
	for i in 600:   # a 60 m drop takes about 3.5 s
		session._physics_process(1.0 / 60.0)
		frames += 1
	res["step_ms"] = (Time.get_ticks_usec() - t1) / 1000.0 / frames
	res["grounded_after_fall"] = session.model.grounded
	res["eye_above_ground"] = (session.model.position.y - float(below.position.y)) if not below.is_empty() else null
	var start_xz := Vector2(session.model.position.x, session.model.position.z)
	session._held = {KEY_W: true}
	for i in 300:
		session._physics_process(1.0 / 60.0)
	res["walked_m"] = Vector2(session.model.position.x, session.model.position.z).distance_to(start_xz)
	res["grounded_after_walk"] = session.model.grounded
	res["surfaces_near_after_walk"] = session.model.rays.instances
	session._held = {}
	session.stop_session()
	session.free()
	root.remove_child(cam)
	cam.free()
	return res


# WHAT A BUILT MAP WOULD COST ON DISK.
#
# The question behind it is whether a second open could be a load instead of a
# build. So this walks the finished overlay and adds up the three things such a
# cache would have to keep: the geometry of every DISTINCT mesh, the pixels of
# every DISTINCT image, and the transforms of every instance.
#
# Sizes come from the resources themselves - a surface's format says which
# attributes exist and how wide they are - rather than from saving files, so it
# costs seconds instead of gigabytes of writing. A real cache would add its own
# headers and would compress; treat this as the floor.
static func _mesh_bytes(mesh: Mesh) -> int:
	var total := 0
	for s in range(mesh.get_surface_count()):
		var format: int = mesh.surface_get_format(s) if mesh is ArrayMesh else Mesh.ARRAY_FORMAT_VERTEX
		var verts: int = mesh.surface_get_array_len(s)
		var per_vertex := 12                                  # position
		if format & Mesh.ARRAY_FORMAT_NORMAL: per_vertex += 12
		if format & Mesh.ARRAY_FORMAT_TANGENT: per_vertex += 16
		if format & Mesh.ARRAY_FORMAT_COLOR: per_vertex += 16
		if format & Mesh.ARRAY_FORMAT_TEX_UV: per_vertex += 8
		if format & Mesh.ARRAY_FORMAT_TEX_UV2: per_vertex += 8
		# Godot narrows the index to 16 bits when the surface fits, and a map's
		# meshes mostly do, so assuming 32 would overstate this by a lot.
		var index_width := 2 if verts <= 65535 else 4
		total += verts * per_vertex + mesh.surface_get_array_index_len(s) * index_width
	return total


static func _cache_size(root: Node) -> Dictionary:
	var meshes := {}
	var images := {}
	var instances := 0
	var nodes := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		nodes += 1
		var mesh: Mesh = null
		if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			var mm := (n as MultiMeshInstance3D).multimesh
			instances += mm.instance_count
			mesh = mm.mesh
		elif n is MeshInstance3D:
			instances += 1
			mesh = (n as MeshInstance3D).mesh
		if mesh == null:
			continue
		var mesh_id := mesh.get_instance_id()
		if not meshes.has(mesh_id):
			meshes[mesh_id] = _mesh_bytes(mesh)
		for s in range(mesh.get_surface_count()):
			var mat: Material = mesh.surface_get_material(s)
			if mat == null:
				continue
			for property in mat.get_property_list():
				var value: Variant = mat.get(str(property.get("name", "")))
				if value is Texture2D:
					var texture: Texture2D = value
					var tid := texture.get_instance_id()
					if images.has(tid):
						continue
					var image: Image = texture.get_image()
					images[tid] = image.get_data().size() if image != null else 0
	var mesh_bytes := 0
	for v in meshes.values():
		mesh_bytes += int(v)
	var image_bytes := 0
	for v in images.values():
		image_bytes += int(v)
	# A MultiMesh transform is 12 floats, and a cache has to keep one per
	# placement or the map comes back with everything at the origin.
	var instance_bytes := instances * 48
	var total := mesh_bytes + image_bytes + instance_bytes
	var out := {"nodes": nodes, "distinct_meshes": meshes.size(), "mesh_mb": mesh_bytes / 1048576.0,
		"distinct_images": images.size(), "image_mb": image_bytes / 1048576.0,
		"instances": instances, "instance_mb": instance_bytes / 1048576.0,
		"total_mb": total / 1048576.0}
	_say("autorun: an instant-open cache for this map would hold %.0f MB: %.0f MB of geometry (%d mesh(es)), %.0f MB of pixels (%d image(s)), %.1f MB of placements (%d)"
		% [out["total_mb"], out["mesh_mb"], meshes.size(), out["image_mb"], images.size(),
		   out["instance_mb"], instances])
	return out


# THE COST OF A FRAME AGAINST TIME SINCE BOOT.
#
# Nothing is built and nothing is opened: it just times frames and writes down
# what the editor was doing. The point is the shape - if the seconds-long frames
# stop on their own at a certain age, they are startup work and the fix is to
# stop a build from starting inside that window (or to find what the window is);
# if they never stop, the blame pass was measuring something else.
static func _frame_timeline(tree: SceneTree, spec: Variant) -> Dictionary:
	var cfg: Dictionary = spec if spec is Dictionary else {}
	var seconds := int(cfg.get("seconds", 240))
	var efs := EditorInterface.get_resource_filesystem()
	var rows: Array = []
	var t0 := Time.get_ticks_msec()
	var settled_at := -1
	var cheap_run := 0
	while Time.get_ticks_msec() - t0 < seconds * 1000:
		var t := Time.get_ticks_msec()
		await tree.process_frame
		var ms := Time.get_ticks_msec() - t
		rows.append({"at_ms": t - t0, "frame_ms": ms,
			"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			"scanning": efs != null and efs.is_scanning()})
		# SETTLED means a run of cheap frames, not one: a single fast frame
		# happens all through the slow window and would date the settle far too
		# early.
		cheap_run = cheap_run + 1 if ms <= 50 else 0
		if settled_at < 0 and cheap_run >= 30:
			settled_at = int(Time.get_ticks_msec() - t0)
			_say("autorun: frames settled under 50 ms at %.1f s after the plugin started"
				% (settled_at / 1000.0))
			if bool(cfg.get("stop_when_settled", true)):
				break
	var slow := 0
	for r in rows:
		if int((r as Dictionary)["frame_ms"]) > 100:
			slow += 1
	_say("autorun: frame timeline: %d frames in %.0f s, %d over 100 ms, settled at %s"
		% [rows.size(), (Time.get_ticks_msec() - t0) / 1000.0, slow,
		   "%.1f s" % (settled_at / 1000.0) if settled_at >= 0 else "never"])
	return {"settled_at_ms": settled_at, "frames": rows.size(), "over_100ms": slow,
		"rows": rows}


# WHOSE per-frame work the editor's seconds-long frames are.
#
# Every node in the editor that processes is grouped by the script it runs.
# Each group's processing is switched off, the frames are timed without it, and
# it is switched back on. A group whose absence makes the frames cheap is the
# answer; one that changes nothing is cleared, which is just as useful.
#
# Frame times here swing by 10x round to round, so each group is timed over
# several frames and compared by MEDIAN, and the baseline is re-measured
# between groups rather than taken once at the start: the editor gets slower and
# faster on its own, and a single baseline would credit that drift to whichever
# group happened to run next.
static func _frame_blame(tree: SceneTree, spec: Variant) -> Dictionary:
	var cfg: Dictionary = spec if spec is Dictionary else {}
	var frames := int(cfg.get("frames", 10))
	var groups := {}
	var stack: Array = [tree.root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n.is_processing() or n.is_physics_processing()):
			continue
		var s: Script = n.get_script() as Script
		var key := s.resource_path if s != null and s.resource_path != "" else "(no script: %s)" % n.get_class()
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(n)
	var measure := func() -> Array:
		var got: Array = []
		for i in range(frames):
			var t := Time.get_ticks_msec()
			await tree.process_frame
			got.append(Time.get_ticks_msec() - t)
		got.sort()
		return got
	var median := func(a: Array) -> float:
		return float(a[a.size() / 2]) if not a.is_empty() else 0.0
	var rows: Array = []
	var names: Array = groups.keys()
	names.sort_custom(func(a, b): return (groups[a] as Array).size() > (groups[b] as Array).size())
	_say("autorun: frame blame: %d processing group(s)" % names.size())
	for key in names:
		var nodes: Array = groups[key]
		var before: Array = await measure.call()
		var was: Array = []
		for n in nodes:
			var node := n as Node
			was.append([node.is_processing(), node.is_physics_processing()])
			node.set_process(false)
			node.set_physics_process(false)
		var without: Array = await measure.call()
		for i in range(nodes.size()):
			var node := nodes[i] as Node
			node.set_process(bool((was[i] as Array)[0]))
			node.set_physics_process(bool((was[i] as Array)[1]))
		var m_before: float = median.call(before)
		var m_without: float = median.call(without)
		rows.append({"script": key, "nodes": nodes.size(),
			"median_ms_with": m_before, "median_ms_without": m_without,
			"saved_ms": m_before - m_without})
		_say("autorun: frame blame  %-64s %3d node(s)  %6.0f -> %6.0f ms"
			% [key, nodes.size(), m_before, m_without])
	rows.sort_custom(func(a, b): return float(a["saved_ms"]) > float(b["saved_ms"]))
	return {"frames_per_measure": frames, "groups": rows}


# WHAT A YIELDED FRAME IS ACTUALLY PAYING FOR.
#
# Two halves, identical work in each: create `batch` MultiMeshInstance3Ds, await
# one frame, record what that frame cost, repeat `rounds` times. In the first
# half the parent is a child of the edited scene; in the second it is held out
# of the tree and attached only at the end. The nodes, the meshes and the
# MultiMeshes are the same, so the difference between the halves is what the
# EDITOR does about a growing scene, not what the engine does about geometry.
#
# Deliberately trivial geometry (one box, four instances): a probe that also
# parsed real props would measure the reader again, which is not the question.
# Everything created here is freed before returning, and nothing is saved.
static func _frame_probe(tree: SceneTree, root: Node, spec: Variant) -> Dictionary:
	var cfg: Dictionary = spec if spec is Dictionary else {}
	var rounds := int(cfg.get("rounds", 12))
	var batch := int(cfg.get("batch", 250))
	var mesh := BoxMesh.new()
	var out := {"rounds": rounds, "batch": batch, "attached": [], "detached": [],
		"baseline_ms": 0.0, "node_count_at_start": 0}
	# WHAT ELSE THE FRAME COULD BE DOING, sampled rather than assumed: the
	# engine's own view of the frame, and whether the editor is still importing.
	# A frame that is slow while process time is near zero is waiting on
	# something outside the main thread's own script work.
	var efs := EditorInterface.get_resource_filesystem()
	var sample := func() -> Dictionary:
		return {"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"frame_monitor_ms": Performance.get_monitor(Performance.TIME_FPS),
			"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			"objects_drawn": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
			"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			"scanning": efs != null and efs.is_scanning()}
	# The resting cost of a frame in this editor, before anything is added.
	for i in 5:
		await tree.process_frame
	var base_rows: Array = []
	var t_base := Time.get_ticks_msec()
	for i in 10:
		var t_one := Time.get_ticks_msec()
		await tree.process_frame
		var row: Dictionary = sample.call()
		row["frame_ms"] = Time.get_ticks_msec() - t_one
		base_rows.append(row)
	out["baseline_ms"] = float(Time.get_ticks_msec() - t_base) / 10.0
	out["baseline_rows"] = base_rows
	out["node_count_at_start"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_say("autorun: frame probe baseline: %.0f ms per frame with nothing added"
		% out["baseline_ms"])
	if root == null:
		return out
	for pass_name in ["attached", "detached"]:
		var parent := Node3D.new()
		parent.name = "BF6FrameProbe_" + pass_name
		parent.visible = false
		root.add_child(parent)
		if pass_name == "detached":
			root.remove_child(parent)
		var rows: Array = []
		for r in range(rounds):
			var t_make := Time.get_ticks_msec()
			for i in range(batch):
				var mmi := MultiMeshInstance3D.new()
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = mesh
				mm.instance_count = 4
				for k in 4:
					mm.set_instance_transform(k, Transform3D(Basis(), Vector3(k * 2.0, 0.0, r * 2.0)))
				mmi.multimesh = mm
				parent.add_child(mmi)
			var make_ms := Time.get_ticks_msec() - t_make
			var t_frame := Time.get_ticks_msec()
			await tree.process_frame
			var frame_ms := Time.get_ticks_msec() - t_frame
			# The frame AFTER, with nothing created in between: the same paired
			# probe the build uses, so the two can be compared directly.
			var t_idle := Time.get_ticks_msec()
			await tree.process_frame
			var row: Dictionary = sample.call()
			row.merge({"round": r, "nodes_in_parent": parent.get_child_count(),
				"make_ms": make_ms, "frame_ms": frame_ms,
				"idle_frame_ms": Time.get_ticks_msec() - t_idle,
				"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))})
			rows.append(row)
		if pass_name == "detached":
			var t_attach := Time.get_ticks_msec()
			root.add_child(parent)
			await tree.process_frame
			out["attach_at_end_ms"] = Time.get_ticks_msec() - t_attach
		out[pass_name] = rows
		var total := 0.0
		for row in rows:
			total += float((row as Dictionary)["frame_ms"])
		_say("autorun: frame probe %s: %d nodes added in %d rounds, %.0f ms of yielded frames (%.1f ms each)"
			% [pass_name, rounds * batch, rounds, total, total / maxf(1.0, float(rounds))])
		if parent.get_parent() != null:
			parent.get_parent().remove_child(parent)
		parent.queue_free()
		for i in 5:
			await tree.process_frame
	return out


# SOLDIERS: each soldier spawner draws the core's posed, armed soldier from its
# own choices, placed unsaved. Measured by properties: the mesh and its height,
# the badge per side, the eye blend, a changed choice rebuilding the overlay, and
# the Inspector's pickers.
static func _soldier_checks(tree: SceneTree, root: Node) -> Dictionary:
	var res := {}
	var L = HighpolyLib.LoadoutScript
	var gs = HighpolyLib.game_source
	var core = L.core_for(gs)
	res["core"] = core != null
	res["binding"] = core != null and core.has_method("loadout_soldier")
	if core == null:
		return res
	res["characters"] = L.catalogue_list(core, "characters").size()
	res["outfits_wisp"] = L.outfits_for(core, "cha0001wisp").size()
	var paths := {"PlayerSpawner": "res://objects/gameplay/common/PlayerSpawner.tscn",
		"HQ_PlayerSpawner": "res://objects/gameplay/common/HQ_PlayerSpawner.tscn",
		"AI_Spawner": "res://objects/gameplay/ai/AI_Spawner.tscn",
		"SpawnPoint": "res://objects/entities/SpawnPoint.tscn"}
	var placed: Array = []
	for type in paths:
		var ps := load(paths[type]) as PackedScene
		if ps == null:
			res[type] = {"error": "no scene"}
			continue
		var n := ps.instantiate() as Node3D
		root.add_child(n)
		n.owner = null
		placed.append(n)
		var t0 := Time.get_ticks_msec()
		var applied := HighpolyLib.apply_one(n, L.type_of(n), HighpolyLib.Tier.HIGH, true)
		var r := {"applied": applied, "ms": Time.get_ticks_msec() - t0}
		r.merge(_soldier_facts(n))
		res[type] = r
	# a changed choice rebuilds: PAX recon on the player spawner
	if not placed.is_empty():
		var n: Node3D = placed[0]
		var before_id := str((n.get_node_or_null(HighpolyLib.HP_NODE) as Node).get_meta("hp_asset", "")) if n.get_node_or_null(HighpolyLib.HP_NODE) != null else ""
		n.set_meta(L.LOADOUT_META, {"faction": "pax", "role": "recon", "character": "cha0002know"})
		HighpolyLib.apply_one(n, L.type_of(n), HighpolyLib.Tier.HIGH, true)
		var after := _soldier_facts(n)
		after["rebuilt"] = str(after.get("asset", "")) != before_id
		res["changed"] = after
		# the Inspector's panel for a soldier spawner
		var insp = load("res://addons/highpoly_toggle/highpoly_loadout_inspector.gd").new()
		res["inspector_handles"] = insp._can_handle(n)
		var panel = insp.LoadoutPanel.new()
		EditorInterface.get_base_control().add_child(panel)
		panel.setup(n, insp)
		var w0 := Time.get_ticks_msec()
		while panel.loading and Time.get_ticks_msec() - w0 < 60000:
			await tree.process_frame
		await tree.process_frame
		var labels: Array = []
		for c in panel.fields.get_children():
			if c is Label and not c.is_queued_for_deletion():
				labels.append(str((c as Label).text))
		res["inspector_fields"] = labels
		res["inspector_status"] = str(panel.status.text)
		panel.queue_free()
	for n in placed:
		n.queue_free()
	return res


static func _soldier_facts(n: Node3D) -> Dictionary:
	var hp := n.get_node_or_null(HighpolyLib.HP_NODE)
	if hp == null:
		return {"overlay": false}
	var out := {"overlay": true, "asset": str(hp.get_meta("hp_asset", "")).left(160)}
	var mi := hp.get_node_or_null("Soldier") as MeshInstance3D
	out["core_mesh"] = mi != null
	if mi == null:
		return out
	var ab := mi.get_aabb()
	out["surfaces"] = mi.mesh.get_surface_count()
	out["height"] = snappedf(ab.size.y, 0.001)
	out["min_y"] = snappedf(ab.position.y, 0.001)
	var badge := ""
	var eye := false
	var untextured := 0
	for i in range(mi.mesh.get_surface_count()):
		var m := mi.mesh.surface_get_material(i)
		if m is ShaderMaterial:
			eye = eye or (m as ShaderMaterial).get_shader_parameter("iris") != null
		elif m is StandardMaterial3D:
			var sm := m as StandardMaterial3D
			if sm.albedo_texture == null:
				untextured += 1
			if sm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR and sm.albedo_texture != null:
				badge = "%dx%d#%d" % [sm.albedo_texture.get_width(), sm.albedo_texture.get_height(), sm.albedo_texture.get_instance_id()]
	out["badge_texture"] = badge
	out["eye_blend"] = eye
	out["untextured_surfaces"] = untextured
	return out


# EXPORT: the upload file written through the core for this level (readable and
# minified) and for another level read from disk, into the user folder rather
# than the SDK's export folder; the SDK panel's added button; a scene that is
# not a level refused. The files are compared with the SDK exporter's outside.
static func _upload_checks(root: Node) -> Dictionary:
	var res := {}
	var upload: Script = load("res://addons/bf6_extended_workspace/workspace_upload.gd")
	var dir := OS.get_user_data_dir().path_join("bf6_upload")
	res["why_not"] = upload.why_not(root)
	res["export_dir"] = upload.export_dir()
	var readable: Dictionary = upload.export_scene(root, false, dir.path_join("readable"))
	var small: Dictionary = upload.export_scene(root, true, dir.path_join("minified"))
	res["readable"] = {"ok": readable.ok, "path": readable.get("path", ""), "bytes": readable.get("bytes", 0), "error": readable.get("error", "")}
	res["minified"] = {"ok": small.ok, "bytes": small.get("bytes", 0)}
	var other := load("res://levels/MP_Aftermath_Portal.tscn") as PackedScene
	if other != null:
		var inst := other.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
		var r: Dictionary = upload.export_scene(inst, false, dir.path_join("readable"))
		res["aftermath"] = {"ok": r.ok, "bytes": r.get("bytes", 0), "error": r.get("error", "")}
		inst.free()
	var loose := Node3D.new()
	loose.name = "NotALevel"
	res["not_a_level"] = str(upload.export_scene(loose, false, dir).get("error", ""))
	loose.free()
	var button: Node = EditorInterface.get_base_control().find_child("BF6ExportThroughCore", true, false)
	res["dock_button"] = {"found": button != null, "disabled": (button as Button).disabled if button is Button else true,
		"next_to_export_level": button != null and button.get_index() > 0 and str(button.get_parent().get_child(button.get_index() - 1).name) == "ExportLevel_Button"}
	return res


# THE UPLOAD FILE: the shared core's writer given this scene, another level read
# from disk, and this scene with a piece placed (saved beside the request so the
# SDK's own exporter can be run on the same thing). The comparison runs outside.
static func _spatial_checks(root: Node, seed: Node3D, history: UndoRedo) -> Dictionary:
	var res := {}
	var spatial: Script = load("res://addons/bf6_extended_workspace/workspace_spatial.gd")
	var mode: Script = load("res://addons/bf6_extended_workspace/workspace_mode_setup.gd")
	res["available"] = spatial.available()
	if not spatial.available():
		return res
	var dir := OS.get_user_data_dir().path_join("bf6_spatial")
	DirAccess.make_dir_recursive_absolute(dir)
	var save := func(name: String, scene: Node) -> Dictionary:
		var req: Dictionary = spatial.describe(scene)
		var f := FileAccess.open(dir.path_join(name + ".request.json"), FileAccess.WRITE)
		f.store_string(JSON.stringify(req))
		f.close()
		var t0 := Time.get_ticks_msec()
		var ex: Dictionary = spatial.export_scene(scene)
		var small: Dictionary = spatial.export_scene(scene, false, true)
		return {"objects": (req.objects as Array).size(), "ms": Time.get_ticks_msec() - t0, "bytes": (ex.text as String).length(),
			"min_bytes": (small.text as String).length(), "report": ex.report}
	res["open"] = save.call("MP_Isolated", root)
	var other := load("res://levels/MP_Aftermath_Portal.tscn") as PackedScene
	if other != null:
		var inst := other.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
		res["aftermath"] = save.call("MP_Aftermath_Portal", inst)
		inst.free()
	var flag: Node = mode.place_bundle("FLAG", seed.global_position + Vector3(30, 0, 30))
	var packed := PackedScene.new()
	if flag != null and packed.pack(root) == OK:
		ResourceSaver.save(packed, dir.path_join("MP_Isolated_flag.tscn"))
		res["flag"] = save.call("MP_Isolated_flag", root)
	if flag != null:
		history.undo()
	res["dir"] = dir
	return res


# PORTAL BUDGET and BLOCKS: the bar in the 3D toolbar counts a placed piece; a
# block the Unreal SDK saved places here; one saved here places again. The
# block "_parity_godot" stays in the shared library for the Unreal SDK to place.
static func _blocks_budget_checks(tree: SceneTree, root: Node, seed: Node3D, map: String, history: UndoRedo) -> Dictionary:
	var res := {}
	var base := "res://addons/bf6_extended_workspace/"
	var place: Script = load(base + "workspace_place.gd")
	var mode: Script = load(base + "workspace_mode_setup.gd")
	var blocks: Script = load(base + "workspace_blocks.gd")
	var at: Vector3 = seed.global_position + Vector3(30, 0, 30)
	var gy: Variant = place.ground_at(at.x, at.z, at.y + 50.0, false)
	if gy != null:
		at.y = float(gy)
	var before := root.get_child_count()
	var bar: Node = EditorInterface.get_base_control().find_child("BF6Budget", true, false)
	res["bar"] = bar != null
	if bar != null:
		res["budget_before"] = str((bar.refresh() as Dictionary).get("text", ""))
		mode.place_bundle("FLAG", at)
		res["budget_with"] = str((bar.refresh() as Dictionary).get("text", ""))
		for i in range(4):
			await tree.process_frame
		res["budget_shot"] = _shoot_editor("user://bf6_parity_%s_budget.png" % map)
		history.undo()
		res["budget_after"] = str((bar.refresh() as Dictionary).get("text", ""))
		# The upload share, from a dry-run export as in Unreal.
		var t0 := Time.get_ticks_msec()
		res["estimate_started"] = bar.start_estimate(root, 0, true)
		res["estimate_ms"] = Time.get_ticks_msec() - t0
		res["budget_estimated"] = str((bar.refresh() as Dictionary).get("text", ""))
	res["available"] = blocks.available()
	res["library"] = blocks.library()
	res["listed"] = blocks.list().map(func(b): return "%s|%s|%d|%s" % [b.name, b.level, int(b.count), b.format])
	# Saved in the Unreal SDK.
	var g: Node3D = blocks.place("_parity_flag", at)
	res["unreal_block"] = _describe_block(blocks, g)
	if g != null:
		history.undo()
	res["unreal_block_undo"] = root.get_child_count() == before
	# Saved here, then placed again 100 m along.
	var flag: Node = mode.place_bundle("FLAG", at)
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(flag)
	var saved: Dictionary = blocks.save_selection("_parity_godot")
	res["godot_save"] = saved
	res["godot_source"] = _describe_block(blocks, flag.get_parent() as Node3D)
	var copy: Node3D = blocks.place("_parity_godot", at + Vector3(100, 0, 0))
	res["godot_copy"] = _describe_block(blocks, copy)
	# Pictures: drawn here for this block; the Unreal one read from the library.
	var drawn: String = await blocks.render_thumb("_parity_godot")
	res["thumb_drawn"] = drawn
	for blk in blocks.list():
		res["thumb_" + str(blk.name)] = {"fresh": blk.thumb_fresh, "texture": blocks.thumb_texture(blk) != null}
	if drawn != "":
		DirAccess.copy_absolute(drawn, ProjectSettings.globalize_path("user://bf6_parity_%s_block_thumb_godot.png" % map))
	# Dragging out: the drop target covers the 3D view while the drag lasts.
	blocks.begin_drag("_parity_godot", null)
	await tree.process_frame
	var base_control := EditorInterface.get_base_control()
	res["drag"] = {"dragging": base_control.get_viewport().gui_is_dragging(), "target": base_control.find_child("BF6BlockDrop", false, false) != null}
	base_control.get_viewport().gui_cancel_drag()
	for i in range(3):
		await tree.process_frame
	res["drag"]["target_gone"] = base_control.find_child("BF6BlockDrop", false, false) == null
	var pop: Window = blocks.open(EditorInterface.get_base_control(), EditorInterface.get_base_control().get_global_rect().get_center(), EditorInterface.get_editor_scale(), Callable())
	for i in range(10):
		await tree.process_frame
	var img: Image = pop.get_texture().get_image()
	res["panel_shot"] = img != null and img.save_png("user://bf6_parity_%s_blocks_panel.png" % map) == OK
	pop.hide()
	for i in range(3):
		history.undo()
	res["godot_undo"] = root.get_child_count() == before
	return res


static func _describe_block(blocks: Script, g: Node3D) -> Dictionary:
	if g == null:
		return {}
	var inv := g.global_transform.affine_inverse()
	var members: Array = []
	var cp: Node = null
	for n in blocks.members_of([g]):
		var l: Vector3 = inv * (n as Node3D).global_position
		members.append("%s|%s|%.2f,%.2f,%.2f|%.0f" % [n.name, blocks.type_of(n), l.x, l.y, l.z, rad_to_deg((n as Node3D).global_rotation.y)])
		if blocks.type_of(n) == "CapturePoint":
			cp = n
	var out := {"group": str(g.name), "block": str(g.get_meta(&"bf6_block", "")), "members": members}
	if cp != null:
		var area: Node = cp.get("CaptureArea")
		out["obj_id"] = cp.get("ObjId")
		out["area"] = str(area.name) if area != null else ""
		out["area_points"] = (area.get("points") as PackedVector2Array).size() if area != null else 0
		out["area_world_first"] = str((area as Node3D).global_transform * Vector3((area.get("points") as PackedVector2Array)[0].x, 0, (area.get("points") as PackedVector2Array)[0].y)) if area != null else ""
		out["area_height"] = area.get("height") if area != null else null
		out["team1"] = (cp.get("InfantrySpawnPoints_Team1") as Array).map(func(s): return str(s.name))
		out["team2"] = (cp.get("InfantrySpawnPoints_Team2") as Array).size()
	return out


# LOG, CHANGES and EXPERIENCE: each opens as a main screen, reads through the
# bundled core runtime, and is photographed. Nothing here writes to the scene.
static func _top_row_checks(tree: SceneTree, map: String) -> Dictionary:
	var res := {"runtime": ClassDB.class_exists("BF6CoreRuntime")}
	var main := EditorInterface.get_editor_main_screen()
	var place: Script = load("res://addons/bf6_extended_workspace/workspace_place.gd")
	res["workspace_core"] = place.core().get_class() if place.core() != null else ""
	for s in [["BF6 Log", "BF6GameLog"], ["BF6 Changes", "BF6Changes"], ["BF6 Experience", "BF6Experience"]]:
		var panel: Node = main.find_child(s[1], true, false)
		var key: String = str(s[1]).to_lower()
		if panel == null:
			res[key] = "missing"
			continue
		EditorInterface.set_main_screen_editor(s[0])
		for i in range(4):
			await tree.process_frame
		var info := {"visible": (panel as Control).is_visible_in_tree()}
		if s[1] == "BF6GameLog":
			panel.pull()
			info["lines"] = panel._lines.size()
			info["where"] = str(panel._where.text).left(120)
		elif s[1] == "BF6Changes":
			panel.scan()
			panel.scan()
			info["report"] = str(panel._out.text).left(160).replace("\n", " / ")
			info["status"] = str(panel._status.text)
		else:
			panel.refresh()
			var fixture := OS.get_user_data_dir().path_join("bf6_exp_fixture/saves/experiences/Night Raid/maps/MP_Test")
			DirAccess.make_dir_recursive_absolute(fixture)
			var f := FileAccess.open(fixture.path_join("MP_Test.json"), FileAccess.WRITE)
			f.store_string(JSON.stringify({"portalExperience": "https://portal.battlefield.com/bf6/experience/rules?playgroundId=0a1b2c3d-1111-2222-3333-444455556666", "portalMapIdx": 1}))
			f.close()
			var fake := Node3D.new()
			fake.scene_file_path = fixture.path_join("MP_Test.tscn")
			var d: Dictionary = panel.detect(fake)
			fake.free()
			info["open_map_why"] = str(panel.detect(EditorInterface.get_edited_scene_root()).why).left(90)
			info["fixture"] = {"linked": d.linked, "id": d.id, "name": d.name, "level": d.level, "map_idx": d.map_idx}
		await tree.process_frame
		info["shot"] = _shoot_editor("user://bf6_parity_%s_%s.png" % [map, key])
		res[key] = info
	EditorInterface.set_main_screen_editor("3D")
	return res


# MODE SETUP, SCATTER, PICK PLACE, GROUPING and EDIT POINTS in the real editor.
# Everything made is undone again.
static func _mode_checks(tree: SceneTree, root: Node, seed: Node3D, map: String, history: UndoRedo) -> Dictionary:
	var res := {}
	var base := "res://addons/bf6_extended_workspace/"
	var place: Script = load(base + "workspace_place.gd")
	var mode: Script = load(base + "workspace_mode_setup.gd")
	var scatter: Script = load(base + "workspace_scatter.gd")
	var pick: Script = load(base + "workspace_pick_place.gd")
	var grouping: Script = load(base + "workspace_grouping.gd")
	var zone: Script = load(base + "workspace_zone_edit.gd")
	var at: Vector3 = seed.global_position + Vector3(30, 0, 30)
	var gy: Variant = place.ground_at(at.x, at.z, at.y + 50.0, false)
	res["ground"] = gy
	if gy != null:
		at.y = float(gy)
	var before := root.get_child_count()
	# One finished piece.
	var flag: Node = mode.place_bundle("FLAG", at)
	res["bundle"] = {"root": str(flag.name) if flag != null else "", "children": flag.get_child_count() if flag != null else 0,
		"area": str(flag.get("CaptureArea").name) if flag != null and flag.get("CaptureArea") != null else "",
		"team1": (flag.get("InfantrySpawnPoints_Team1") as Array).size() if flag != null else 0,
		"obj_id": flag.get("ObjId") if flag != null else null,
		"area_points": (flag.get("CaptureArea").get("points") as PackedVector2Array).size() if flag != null and flag.get("CaptureArea") != null else 0}
	history.undo()
	res["bundle_undo"] = root.get_child_count() == before
	# The wizard, Conquest with one flag: HQ, HQ, flag, then the sector.
	var hud: Control = EditorInterface.get_base_control().find_child("BF6ModeHud", false, false)
	mode.hud = hud
	mode.start("Conquest", 1)
	res["wizard_total"] = mode.total
	await tree.process_frame
	await tree.process_frame
	res["wizard_shot"] = _shoot_editor("user://bf6_parity_%s_mode_setup.png" % map)
	for i in range(3):
		mode.place_at(at + Vector3(i * 40.0, 0, 0))
	res["wizard_done"] = not mode.active
	var sector: Node = root.find_child("Sector_1", false, false)
	res["wizard_sector_flags"] = (sector.get("CapturePoints") as Array).size() if sector != null else -1
	res["wizard_hq_spawns"] = (root.find_child("Team1_HQ", false, false).get("InfantrySpawns") as Array).size() if root.find_child("Team1_HQ", false, false) != null else -1
	for i in range(3):
		history.undo()
	res["wizard_undo"] = root.get_child_count() == before
	# SCATTER from the library, around a spot.
	var prop := ""
	for p in ["res://objects/nature", "res://objects/props"]:
		var stack: Array = [p]
		while prop == "" and not stack.is_empty():
			var d: String = stack.pop_back()
			for f in DirAccess.get_files_at(d):
				if f.ends_with(".tscn"):
					prop = d.path_join(f)
					break
			for sub in DirAccess.get_directories_at(d):
				stack.append(d.path_join(sub))
		if prop != "":
			break
	res["scatter_prop"] = prop
	EditorInterface.get_selection().clear()
	scatter.hud = hud
	var vr := func(): return (EditorInterface.get_editor_viewport_3d(0).get_parent() as Control).get_global_rect()
	scatter.begin_from_library(EditorInterface.get_base_control(), vr, EditorInterface.get_editor_scale())
	scatter.add_objects([prop])
	scatter.params.count = 20.0
	scatter.set_center(at)
	res["scatter_at"] = [at.x, at.y, at.z]
	res["scatter_xyz"] = scatter.targets.map(func(t): return [snappedf(t.at[0], 0.01), snappedf(t.at[1], 0.01), snappedf(t.at[2], 0.01)])
	for i in range(6):
		await tree.process_frame
	res["scatter_targets"] = scatter.targets.size()
	res["scatter_preview"] = scatter._nodes.size()
	res["scatter_shot"] = _shoot_editor("user://bf6_parity_%s_scatter.png" % map)
	var made: int = scatter.apply()
	res["scatter_applied"] = made
	res["scatter_added"] = root.get_child_count() - before
	history.undo()
	res["scatter_undo"] = root.get_child_count() == before
	# The outline after drawing: corners delete (three stay), undo and redo step
	# through its history; painting fills new ground while the stroke runs.
	scatter.begin_from_library(EditorInterface.get_base_control(), vr, EditorInterface.get_editor_scale())
	scatter.add_objects([prop])
	scatter.begin_draw()
	for c in [Vector3(-10, 0, -10), Vector3(10, 0, -10), Vector3(10, 0, 10), Vector3(-10, 0, 10)]:
		scatter.draw_add(at + c)
	scatter.finish_draw()
	var outline := {"corners": scatter.poly.size(), "targets": scatter.targets.size()}
	scatter.delete_corner(0)
	outline["after_delete"] = scatter.poly.size()
	scatter.delete_corner(0)
	outline["min_three"] = scatter.poly.size()
	scatter.undo_outline()
	outline["undo"] = scatter.poly.size()
	scatter.redo_outline()
	outline["redo"] = scatter.poly.size()
	res["scatter_outline"] = outline
	scatter.set_shape(4)
	scatter.params.radius = 6.0
	scatter.params.count = 30.0
	scatter.begin_paint()
	var grew: Array = []
	for i in range(6):
		scatter.paint_to(at + Vector3(i * 5.0, 0, 0))
		grew.append(scatter.targets.size())
	scatter.end_paint()
	res["scatter_paint"] = {"during_stroke": grew, "after": scatter.targets.size()}
	scatter.cancel()
	res["scatter_cancel_clean"] = root.get_child_count() == before
	# PICK PLACE: pick up, turn, put back.
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(seed)
	var start := seed.global_transform
	pick.hud = hud
	res["pick_begin"] = pick.begin()
	pick.rotate(45.0, false)
	pick.cancel()
	res["pick_restores"] = seed.global_transform.is_equal_approx(start)
	# GROUPING: group two, ungroup, undo both.
	var second: Node3D = null
	for c in root.get_children():
		if c is Node3D and c != seed and c.owner == root and c.scene_file_path != "":
			second = c
			break
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(seed)
	if second != null:
		EditorInterface.get_selection().add_node(second)
	var g: Node3D = grouping.group_selection()
	res["group"] = {"made": g != null, "members": g.get_child_count() if g != null else 0, "seed_kept": seed.global_transform.is_equal_approx(start)}
	EditorInterface.get_selection().clear()
	if g != null:
		EditorInterface.get_selection().add_node(g)
	var blocks: Script = load(base + "workspace_blocks.gd")
	var saved: Dictionary = blocks.save_selection("parity check block")
	res["block"] = {"name": str(saved.get("name", saved.get("error", ""))), "count": int(saved.get("count", 0)), "tagged": g != null and g.has_meta(&"bf6_block")}
	blocks.delete("parity check block")
	res["ungroup"] = grouping.ungroup_selection()
	res["ungroup_parent"] = seed.get_parent() == root
	history.undo()
	history.undo()
	res["group_undo"] = seed.get_parent() == root and root.get_child_count() == before and seed.global_transform.is_equal_approx(start)
	# EDIT POINTS on the first zone.
	var vol: Node = null
	for n in root.find_children("*", "", true, false):
		if n.get("points") is PackedVector2Array and n.owner == root:
			vol = n
			break
	zone.hud = hud
	zone.begin(vol)
	res["zone"] = {"active": zone.active, "banner": hud != null and hud.is_showing()}
	zone.finish()
	return res


# The whole editor window, UI included.
static func _shoot_editor(path: String) -> String:
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	if img == null or img.save_png(path) != OK:
		return ""
	return path


static func _load_path(p: String) -> Array:
	var txt := FileAccess.get_file_as_string(p)
	if txt == "" and not p.begins_with("user://"):
		return []
	var d = JSON.parse_string(txt)
	if d == null or not d.has("samples"):
		return []
	var out: Array = []
	for s in d["samples"]:
		var b: Array = s["b"]
		var pos: Array = s["p"]
		out.append(Transform3D(
				Basis(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]),
					  Vector3(b[6], b[7], b[8])),
				Vector3(pos[0], pos[1], pos[2])))
	return out


static func _scene_for(map: String) -> String:
	# The level scenes live under the SDK's own map folders; found rather than
	# constructed, because the layout has moved between SDK versions and a
	# constructed path fails silently as "the scene did not open".
	for base in ["res://Levels", "res://User_Created", "res://"]:
		var hit := _find_scene(base, map, 0)
		if hit != "":
			return hit
	return ""


static func _find_scene(dir: String, map: String, depth: int) -> String:
	if depth > 4:
		return ""
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	d.list_dir_begin()
	var f := d.get_next()
	var subs: Array = []
	while f != "":
		var p := dir.path_join(f)
		if d.current_is_dir():
			if not f.begins_with("."):
				subs.append(p)
		elif f == map + ".tscn" or f == map + ".scn":
			d.list_dir_end()
			return p
		f = d.get_next()
	d.list_dir_end()
	for s in subs:
		var hit := _find_scene(s, map, depth + 1)
		if hit != "":
			return hit
	return ""


static func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


static func _finish(_tree: SceneTree, cfg: Dictionary, rep: Dictionary) -> void:
	rep["total_ms"] = Time.get_ticks_msec()
	var out := str(cfg["out"])
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(rep, " "))
		f.close()
		_say("autorun: wrote %s" % ProjectSettings.globalize_path(out))
	else:
		_say("autorun: COULD NOT WRITE %s" % out)
	# Flush before quitting: a report that exists only in a buffer is a run
	# that has to be repeated.
	await _tree.process_frame
	_say("autorun: done in %.1f s" % (rep["total_ms"] / 1000.0))
	_tree.quit(0)


static func _say(s: String) -> void:
	print(s)
	Log.info(s)
