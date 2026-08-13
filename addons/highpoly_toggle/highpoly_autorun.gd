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
			_say("autorun: with    everything        median %6.1f ms (per-pos %6.1f), %6d draws"
					% [ref.get("median_ms", 0.0), ref.get("median_pos_ms", 0.0),
					   ref.get("draws_mean", 0)])

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
				_say("autorun: OVERLAY FREED + scene hidden  median %6.1f ms, "
						% freed.get("median_ms", 0.0)
						+ "%6d draws, nodes %d (was %d)"
						% [freed.get("draws_mean", 0),
						   int(freed_eng.get("nodes", 0)), before_nodes])
				(root as Node3D).visible = vis2
			rep["sweep"] = sweep
	rep["scene_nodes"] = _count_nodes(root)
	rep["engine"] = _engine()
	rep["census"] = _surface_census(root)
	rep["dialogs_seen"] = _dialogs_seen
	# The crumb trail, which is the only record that survives a crash. If the
	# editor dies mid-run there is no report at all, and this is what the next
	# session reads to find out where it died.
	rep["last_crumb"] = HighpolyProfiler.last_session_end()
	_finish(_tree, cfg, rep)


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

	return {
		"frames": n,
		"positions": pn,
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
