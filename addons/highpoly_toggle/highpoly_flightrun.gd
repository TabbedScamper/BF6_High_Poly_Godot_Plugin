@tool
extends RefCounted
class_name HighpolyFlightRun

# A SELF-DRIVING PERFORMANCE RUN in the real editor: boot, open the map,
# configure the dock, fly the recorded path, write the numbers, quit.
#
# WHY THIS CANNOT BE A HEADLESS SCENE RUN. The thing being measured is the
# editor with the DOCK in it. --headless installs RendererDummy, which draws
# nothing and reports every render counter as zero, so a headless number here
# is not a small approximation, it is a measurement of nothing. And a bare
# scene run has no dock at all, so the overhead being hunted is absent by
# construction. The only honest place to measure it is inside the editor the
# user actually uses, which is why this drives itself from inside the plugin
# rather than being a script somebody runs by hand.
#
#   BF6_PERFRUN=<path to a session json>   run that session
#   BF6_PERFRUN=<tag>                      run the defaults under that name
#
# Inert when the variable is unset. A plugin that can drive the editor and then
# quit it is not something to leave armed.
#
# Driven by tools/perfrun.py, which launches the editor, watches the heartbeat
# file this writes, and kills only the process it started.
#
# TWO HARD RULES ARE ENCODED HERE AND MUST NOT BE SOFTENED.
#
#  1. DISTANCE CULLING STAYS OFF. The range slider goes to its maximum, which
#     is the plugin's own "No Culling" position, and the value is read back and
#     asserted afterwards. A run that quietly reduced it would be measuring the
#     cost of NOT drawing things, which is the opposite of the question. If the
#     assert fails the run aborts rather than reporting a number that looks
#     good for the wrong reason.
#
#  2. THE HEADLINE IS FRAMES UNDER 60 AND THE 1% LOW, never the mean. A run
#     averaging 90 fps that stalls to 12 has failed, and the mean is exactly
#     the statistic that hides it.
#
# What it writes (all paths from the session json, defaults under user://):
#   <out>            the run report, json
#   <heartbeat>      one line of {phase, frame, sample, unix} every 0.5 s, so a
#                    hang can be located rather than merely noticed

const ENV := "BF6_PERFRUN"

# The plugin's own log, used only to mirror progress into the panel. Nothing
# else is preloaded on purpose: every preload is a file that another change can
# break, and this harness has to keep working on the day something else does not.
const Log = preload("highpoly_log.gd")

# The dock's Detail Mode ids. 2 is TEX, the full one. They are historical
# rather than ordered by cost (SDK=0, GREY=1, TEX=2, LIGHT=3), and defaulting to
# the highest number lands on the UNTEXTURED rung.
const MODE_TEX := 2
const MODE_SDK := 0

# The range slider's own top of scale. At or above this the plugin substitutes
# 1e9 for the radius, which is what "No Culling" means internally.
const NO_CULL_SLIDER := 3500.0

# Two samples closer together than this are the camera standing still.
const STILL_M := 0.05

# A frame slower than this missed 60 fps. Absolute, never derived from the
# run's own mean: a threshold that moves with the thing it measures reports a
# map that got twice as fast as 9900% worse, which has already happened here.
const MS_60 := 1000.0 / 60.0
const MS_30 := 1000.0 / 30.0

# Caps, so a per-frame error cannot turn the report into a gigabyte.
const MAX_SIGS := 2000
const MAX_HEAD := 200
const MAX_TAIL := 50
const MAX_FRAMES := 60000

static var _cfg: Dictionary = {}
static var _rep: Dictionary = {}
static var _phase := "boot"
static var _phase_t := 0
static var _spans: Dictionary = {}
static var _frame := 0
static var _sample := -1
static var _samples_total := 0
static var _hb_path := ""
static var _hb_next := 0
static var _t0 := 0

# ---- captured output ----
static var _log_path := ""
static var _log_pos := 0
static var _log_partial := ""
static var _sigs: Dictionary = {}
static var _head: Array = []
static var _tail: Array = []
static var _raw_seen := 0
static var _last_sig := ""
static var _dialogs_seen: Dictionary = {}


static func requested() -> bool:
	return OS.get_environment(ENV) != ""


static func config() -> Dictionary:
	var v := OS.get_environment(ENV)
	var cfg := {
		"map": "MP_Dumbo",
		"scene": "",                  # explicit res:// path wins over the map name
		"tag": "worstcase",
		"mode": MODE_TEX,
		# EVERYTHING ON EXCEPT FX. That is the configuration the 60 fps target
		# is stated against, so it is the default rather than something a
		# session has to remember to ask for.
		"map_context": true,
		"objects": true, "backdrop": true, "water": true,
		"lighting": true, "gi": true, "shadows": true, "map_lights": true,
		"fx": false,
		# RULE 1 HAS NO OFF SWITCH, so there is no key here to turn it off with.
		# The slider always goes to the top of its range; the only thing that is
		# configurable is how strict the read-back check on the radius behind it
		# is, and that only exists so a future slider with a different top of
		# scale can still be checked.
		"min_radius": 1.0e8,
		# A baseline pass has every layer off, so nothing builds and waiting for
		# a build that will never start would burn the whole budget before
		# reporting a timeout about a run that was working perfectly.
		"expect_build": true,
		"settle_frames": 30,
		"hold_ms": 50,                # each recorded sample is held its 50 ms
		"flight": "",
		"out": "",
		"heartbeat": "",
		"log": "",                    # the --log-file Godot was launched with
		"min_draws": 500,             # below this the map MAY not be on screen
		# ...but only together with min_prims. Merging geometry is supposed to
		# cut draw calls, so calls alone cannot tell "the merge worked" from
		# "the view is empty". Triangles can: a merge does not change how much
		# geometry is on screen, only how many calls it takes. Loose on purpose
		# - a floor for "is anything there", not a quality bar.
		"min_prims": 50000,
		# Early aborts, so a broken configuration costs seconds and not ten
		# minutes. Each span is separately budgeted because they fail for
		# completely different reasons.
		# There is deliberately no whole-run budget here. Only the driver can
		# enforce one, because the failure it exists for is this side stopping
		# entirely, and a timer that has to run to notice that the process
		# stopped running is not a timer that will fire. perfrun.py --timeout
		# owns it.
		"max_scan_s": 300, "max_open_s": 180, "max_dock_sync_s": 60,
		"max_build_s": 900, "max_settle_s": 120,
		"stall_s": 60,
	}
	if v != "" and FileAccess.file_exists(v):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(v))
		if j is Dictionary:
			for k in (j as Dictionary):
				cfg[k] = (j as Dictionary)[k]
	elif v != "":
		cfg["tag"] = v
	if str(cfg["flight"]) == "":
		cfg["flight"] = "user://bf6_flightpath_%s.json" % _base_map(str(cfg["map"]))
	if str(cfg["out"]) == "":
		cfg["out"] = "user://perfrun_%s_%s.json" % [str(cfg["map"]), str(cfg["tag"])]
	if str(cfg["heartbeat"]) == "":
		cfg["heartbeat"] = "user://perfrun_%s.progress" % str(cfg["tag"])
	if str(cfg["log"]) == "":
		cfg["log"] = ProjectSettings.globalize_path("user://logs/godot.log")
	return cfg


# The whole session. `dock` is the plugin's panel and `mapctx` its map-context
# node; both are driven exactly as the UI drives them.
static func run(host: Node, dock: Node, mapctx: Node) -> bool:
	# THE TREE, CAPTURED ONCE. The EditorPlugin gets freed part way through a
	# session when the editor reloads the addon after its import scan, and every
	# later host.get_tree() then dies on a freed instance. SceneTree outlives
	# the plugin.
	var tree := host.get_tree()
	if tree == null:
		return false
	_cfg = config()
	_t0 = Time.get_ticks_msec()
	_log_path = str(_cfg["log"])
	_hb_path = str(_cfg["heartbeat"])
	_rep = {
		"schema": 1,
		"tag": str(_cfg["tag"]),
		"map": str(_cfg["map"]),
		"when": Time.get_datetime_string_from_system(),
		"godot": Engine.get_version_info()["string"],
		"headless": DisplayServer.get_name() == "headless",
		"screen_size": [DisplayServer.window_get_size().x,
						DisplayServer.window_get_size().y],
		# Time since PROCESS START, not since this function: boot is a real part
		# of what a user waits for and it is spent before any plugin code runs.
		"boot_ms": _t0,
		"valid": false,
	}
	_say("perfrun: tag=%s map=%s  boot %d ms" % [_cfg["tag"], _cfg["map"], _t0])
	if bool(_rep["headless"]):
		# Refused rather than reported. A headless run produces a full set of
		# zeros that reads exactly like a spectacular result.
		_rep["error"] = ("headless: RendererDummy draws nothing and every frame "
				+ "number would be a zero pretending to be a win")
		await _finish(tree, 1)
		return false

	_phase_begin("scan")
	# WAIT FOR THE IMPORT SCAN BEFORE TOUCHING A SCENE. The level's assets
	# resolve only once EditorFileSystem has registered them; a scene opened
	# mid scan comes up as a 37 node shell with a stderr full of "the file
	# doesn't seem to exist", which reads as a corrupted project and is nothing
	# of the kind.
	var efs := EditorInterface.get_resource_filesystem()
	var t := Time.get_ticks_msec()
	while efs != null and Time.get_ticks_msec() - t < int(_cfg["max_scan_s"]) * 1000:
		await tree.process_frame
		_tick()
		if not efs.is_scanning() and Time.get_ticks_msec() - t > 2000:
			break
	if efs != null and efs.is_scanning():
		return await _abort(tree, "the filesystem scan never settled")
	_phase_end()

	# THE 3D VIEWPORT HAS TO BE THE VISIBLE SCREEN. The editor restores whatever
	# tab was last open, and on the Script screen the 3D viewport is not drawn
	# at all, so a flight there would time an editor that is rendering a text
	# editor and call it a fast map.
	if EditorInterface.has_method("set_main_screen_editor"):
		EditorInterface.set_main_screen_editor("3D")

	# ---- open the scene ---------------------------------------------------
	# BEFORE ANYTHING BUILDS. _cell_size is read when the context loads its
	# data, so setting this later would leave the props grouped at the old size
	# and the run would silently measure the default.
	# TEXTURE MEMORY MODE. Set before the build for the same reason as the cell
	# size: the sidecars are per mode - their pixels differ - so choosing later
	# would measure whichever mode's pixels were already on disk.
	if int(_cfg.get("vram_mode", -1)) >= 0:
		HighpolyMapContext.vram_mode = int(_cfg["vram_mode"])
		_say("perfrun: texture memory mode forced to %d"
			% int(_cfg["vram_mode"]))
	if int(_cfg.get("cell", 0)) > 0:
		HighpolyMapContext.cell_override = int(_cfg["cell"])
		_say("perfrun: streaming/merge cell size forced to %d m"
			% int(_cfg["cell"]))
	_phase_begin("open")
	var scene := str(_cfg["scene"])
	if scene == "" or not ResourceLoader.exists(scene):
		scene = _scene_for(str(_cfg["map"]))
	if scene == "":
		return await _abort(tree, "no scene found for %s" % str(_cfg["map"]))
	_rep["scene"] = scene

	# ALREADY OPEN IS THE COMMON CASE and re throws away a load that has already
	# happened, so the editor gets a moment to restore its own tab first.
	var pre: Node = null
	t = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < 30000:
		pre = EditorInterface.get_edited_scene_root()
		if pre != null and str(pre.name) != "":
			break
		await tree.process_frame
		_tick()
	var want := scene.get_file().get_basename()
	if pre != null and str(pre.name) == want:
		_rep["reused_open_scene"] = true
		_say("perfrun: %s was already open, reusing it" % want)
	else:
		_rep["reused_open_scene"] = false
		EditorInterface.open_scene_from_path(scene)
	# WAIT FOR THE ROOT, do not count frames: open_scene_from_path is deferred
	# and a big level takes far longer than any fixed handful.
	var root: Node = null
	t = Time.get_ticks_msec()
	var tick := 0
	while Time.get_ticks_msec() - t < int(_cfg["max_open_s"]) * 1000:
		await tree.process_frame
		_tick()
		tick += 1
		# Checked WHILE waiting: a modal dialog holds a grab, and a scene that
		# cannot finish opening behind one looks exactly like a slow scene.
		if tick % 30 == 0:
			_dismiss_dialogs()
		root = EditorInterface.get_edited_scene_root()
		if root != null and str(root.name) != "":
			break
	if root == null or str(root.name) == "":
		return await _abort(tree, "the scene did not open: %s" % scene)
	_rep["scene_root"] = str(root.name)
	_say("perfrun: opened %s in %d ms" % [scene.get_file(), Time.get_ticks_msec() - t])
	_phase_end()

	# ---- let the dock notice the scene, then drive it ----------------------
	#
	# The dock resets its own panel when it sees a new root (mode back to SDK,
	# tier back to Low) on its half second timer. Setting the controls before
	# that fires means the timer undoes every one of them a moment later, the
	# build never starts, and the run times out having placed nothing.
	_phase_begin("dock_sync")
	t = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(_cfg["max_dock_sync_s"]) * 1000:
		if not is_instance_valid(host):
			return await _abort(tree, "the EditorPlugin was freed mid session: "
					+ "the editor reloaded the addon, so the dock could not be driven")
		if not is_instance_valid(root):
			return await _abort(tree, "the edited scene root was freed mid session")
		if host.get("_edited_root") == root:
			break
		await tree.process_frame
		_tick()
	await tree.create_timer(1.0).timeout   # one tick past its reset
	_phase_end()

	_phase_begin("configure")
	var built := {"n": -1, "done": false}
	var prog := {"done": 0, "total": 0}
	# Last time any post-props pass reported. Separate from prog because it is
	# a liveness signal, not a count of anything comparable.
	var alive := {"at": 0}
	if mapctx != null and mapctx.has_signal("build_finished"):
		mapctx.build_finished.connect(func(n: int):
			built["n"] = n
			built["done"] = true, CONNECT_ONE_SHOT)
	# THE TERRAIN PIPELINE'S OWN END. build_finished is the props builder, so a
	# run measuring a layer that builds no props has nothing to wait for; this
	# is that run's completion. has_signal rather than a hard reference so an
	# older plugin without it still runs, falling back to the idle settle.
	var terrain_done := {"done": false}
	if mapctx != null and mapctx.has_signal("terrain_ready"):
		mapctx.terrain_ready.connect(func(_sharp: bool):
			terrain_done["done"] = true, CONNECT_ONE_SHOT)
	if mapctx != null and mapctx.has_signal("build_progress"):
		mapctx.build_progress.connect(func(d: int, tot: int):
			prog["done"] = d
			prog["total"] = tot)
	# THE PASSES THAT RUN AFTER THE LAST PROP. The decal projection and the cell
	# merge happen once the props are placed but before the build reports done,
	# and they report on their own signal so the dock can give them their own
	# job-bar lane. This watches that signal purely as a sign of life: without
	# it the counter above stops moving for a minute or more of real work and
	# the stall check below kills the run. It deliberately does NOT touch
	# `prog` - that stays the props counter, which build_done is reported from.
	if mapctx != null and mapctx.has_signal("decal_progress"):
		mapctx.decal_progress.connect(func(_phase: String, _d: int, _t: int):
			alive["at"] = Time.get_ticks_msec())

	var drove := _drive_dock(host, _cfg)
	_rep["dock_controls"] = drove
	if drove.is_empty():
		return await _abort(tree, "none of the dock's controls could be found, "
				+ "so nothing was configured and there is nothing to measure")
	_phase_end()

	# ---- build -------------------------------------------------------------
	_phase_begin("build")
	t = Time.get_ticks_msec()
	if not bool(_cfg["expect_build"]):
		# Nothing was switched on that builds anything, so there is nothing to
		# wait for. Said out loud rather than silently skipped: a run that
		# reports a zero second build is either this, or a build that never
		# started, and those are very different situations.
		_say("perfrun: no layers that build anything, so no build to wait for")
		built["done"] = true
	# A LAYER THAT BUILDS NO PROPS STILL FINISHES. build_finished comes from the
	# props builder, so a run with objects off - measuring the terrain button on
	# its own, say - waited out the entire max_build_s budget and then reported
	# it as the build time. The first button bench duly reported "terrain: 900.0
	# s", which is the cap and not a measurement.
	#
	# For those runs the completion signal is the breadcrumb going quiet and
	# STAYING quiet. That is only trustworthy because the near-window sharpening
	# now sets a crumb of its own; before that it ran for twenty seconds under
	# "idle, nothing building" and this would have called the build finished
	# while the ground was still being sharpened.
	var wait_props: bool = bool(_cfg.get("objects", true))
	var saw_busy := false
	var idle_since := 0
	# 20 s, not 3: the gap between the catalogue upgrade finishing and the
	# ground bake starting is a real idle window of several seconds, and a
	# short settle mistakes it for the end of the run.
	const IDLE_SETTLE_MS := 20000
	var limit: int = int(_cfg["max_build_s"]) * 1000
	var stall_ms: int = int(_cfg["stall_s"]) * 1000
	var last_seen := 0
	var last_change := Time.get_ticks_msec()
	var stalled := false
	tick = 0
	while not bool(built["done"]):
		await tree.process_frame
		_tick()
		tick += 1
		if tick % 60 == 0:
			_dismiss_dialogs()
		var now := Time.get_ticks_msec()
		if int(prog["done"]) != last_seen:
			last_seen = int(prog["done"])
			last_change = now
			_sample = last_seen
			_samples_total = int(prog["total"])
		# A STALL IS NOT A TIMEOUT. Waiting the whole budget to discover that
		# nothing moved for ten minutes wastes the run and reports the wrong
		# thing. The tail is legitimately quiet once every prop is placed, so
		# that window gets four times the patience.
		var placed_all: bool = int(prog["total"]) > 0 and last_seen >= int(prog["total"])
		var quiet: int = stall_ms * 4 if placed_all else stall_ms
		# Quiet means NOTHING is reporting, not merely that the props counter
		# has stopped. A post-props pass ticking is work in progress.
		var quiet_since: int = maxi(last_change, int(alive["at"]))
		if now - quiet_since > quiet and last_seen > 0:
			stalled = true
			break
		if not wait_props and bool(terrain_done["done"]):
			built["done"] = true
			_say("perfrun: terrain_ready - the ground reached full detail")
		elif not wait_props:
			# WAIT ON WHAT THE TOOLS WINDOW SHOWS, not on the breadcrumb.
			#
			# The plugin's panel lives in its own "High-Poly Tools" window, and
			# what it renders while a layer is building is two things: the read
			# model (non-empty for the whole read) and the job queue. The
			# breadcrumb is neither, and it is idle in the gap between the
			# catalogue upgrade and the ground bake - so a wait built on it
			# ended the run BEFORE the bake had started. Measured on a water
			# run: the harness declared the build finished at 120.5 s and
			# wrote its report, and the plugin logged "the ground: blending
			# layers, 112 of 245 (46%)" a minute afterwards. The layer was
			# less than half built when the camera pass began, and every
			# number taken from that run described an unfinished scene.
			#
			# So all three have to be quiet, and stay quiet: no read in
			# flight, no job running, and the breadcrumb idle.
			var reading := false
			var rm = host.get("_read_model")
			if rm is Dictionary:
				reading = not (rm as Dictionary).is_empty()
			var jobbing := false
			var jq = host.get("jobs")
			if jq != null and is_instance_valid(jq) and jq.has_method("busy"):
				jobbing = bool(jq.busy())
			var idle_now: bool = HighpolyVitals.crumb_is_idle() 				and not reading and not jobbing
			if not idle_now:
				saw_busy = true
				idle_since = 0
			elif saw_busy:
				if idle_since == 0:
					idle_since = now
				elif now - idle_since >= IDLE_SETTLE_MS:
					built["done"] = true
					_say("perfrun: no props layer, so the build is done when "
						+ "the plugin has been idle for %.1f s"
						% (IDLE_SETTLE_MS / 1000.0))
		if now - t >= limit:
			break
	_rep["build_ms"] = Time.get_ticks_msec() - t
	_rep["build_done"] = int(prog["done"])
	_rep["build_total"] = int(prog["total"])
	_rep["build_stalled"] = stalled
	_rep["build_timed_out"] = not bool(built["done"]) and not stalled
	_rep["props_built"] = int(built["n"])
	_sample = -1
	_samples_total = 0
	if stalled:
		return await _abort(tree, "the build stalled at %d of %d after %d s with "
				% [_rep["build_done"], _rep["build_total"], int(_cfg["stall_s"])]
				+ "no progress")
	if bool(_rep["build_timed_out"]):
		return await _abort(tree, "the build did not finish inside %d s (%d of %d)"
				% [int(_cfg["max_build_s"]), _rep["build_done"], _rep["build_total"]])
	_say("perfrun: built in %.1f s (%d props)"
			% [float(_rep["build_ms"]) / 1000.0, int(_rep["props_built"])])
	# THE BUILD JOURNAL, WHERE THE RUN CAN FIND IT. The journal is the only
	# per-phase account of where load time goes, and it was being written
	# only when the job queue drained - which a perfrun build never does,
	# so every run measured the load and then threw the breakdown away.
	# Loaded rather than preloaded, on purpose: see the note at the top.
	_save_journal()
	_phase_end()

	# ---- assert the configuration BEFORE flying ---------------------------
	#
	# Rule 1 is checked here rather than trusted. Driving a control and reading
	# it back are different things: a gated chip refuses silently, and the range
	# slider is reset by the per map state restore.
	_phase_begin("assert")
	var st := _assert_config(host, mapctx)
	_rep["config"] = st
	if not bool(st["ok"]):
		return await _abort(tree, "the configuration did not hold: %s"
				% ", ".join(st["problems"]))
	_phase_end()

	# ---- settle, then check the map is actually on screen ------------------
	#
	# SETTLE IS ALSO THE IDLE MEMORY TEST, and that is not a side effect - it is
	# the only stretch of a run where the plugin is loaded, the dock is up and
	# NOTHING is being asked of it. Users report the editor sitting at 3.3 GB
	# with only the menu open and climbing until the machine dies, and a total
	# taken once at the end cannot tell "it allocates a lot" from "it allocates
	# without stopping". A series can: flat means big, rising means leaking.
	#
	# Sampled every frame rather than every N, because the heartbeat that is the
	# prime suspect fires twice a second and a coarse series would alias it.
	# THE PROFILER GOES ON HERE, not at the top of the run.
	#
	# It is off by default and costs ~1.4 us per begin/end pair when on, which is
	# nothing against a 4 ms frame but is not free during a 126 s build, and the
	# build's own phase table already covers that stretch. Switched on for the
	# settle and the flight, which is where per-frame costs live.
	#
	# This existed and was never enabled by any run, so five runs were spent
	# inferring per-frame costs from the SHAPE of frame times while the
	# instrument that names them sat switched off.
	# THE PANEL'S BACKDROP VIDEO, optionally stopped for the run.
	#
	# waves.ogv is 480x800 at 24 fps and loops for as long as the panel is open,
	# so the editor decodes 24 Theora frames a second on the main thread for a
	# backdrop drawn at 28% brightness behind the UI. Worse for a stutter hunt,
	# video codecs decode keyframes far more expensively than the frames between
	# them and keyframes recur on a fixed interval - a rhythmic hitch by
	# construction. HighpolyProfile cannot see any of it: the decode is engine
	# C++, not a bucket we instrumented.
	#
	# So it gets an A/B rather than an assertion.
	if not bool(_cfg.get("panel_video", true)) and dock != null \
			and "video" in dock and dock.video != null:
		dock.video.paused = true
		_rep["panel_video"] = "paused for this run"
	else:
		_rep["panel_video"] = "playing"

	HighpolyProfile.reset()
	HighpolyProfile.set_enabled(true)

	_phase_begin("settle")
	t = Time.get_ticks_msec()
	var idle_mem: Array = []
	var idle_obj: Array = []
	var idle_orph: Array = []
	for i in range(int(_cfg["settle_frames"])):
		await tree.process_frame
		_tick()
		idle_mem.append(snappedf(
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1))
		idle_obj.append(int(Performance.get_monitor(Performance.OBJECT_COUNT)))
		idle_orph.append(int(Performance.get_monitor(
			Performance.OBJECT_ORPHAN_NODE_COUNT)))
		if Time.get_ticks_msec() - t > int(_cfg["max_settle_s"]) * 1000:
			break
	_rep["idle_mem_mb"] = idle_mem
	# VIDEO MEMORY, which is where textures actually live. Without it a texture
	# experiment can only report its CPU-side half: halving every texture
	# measured -459 MB of process memory and could say nothing at all about the
	# GPU, which is the side users run out of. The crash reports that started
	# the cache work quoted 7,513 MB of VRAM, so this is the number that matters
	# and it was not being recorded.
	_rep["vram_mb"] = float(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0
	_rep["vram_texture_mb"] = float(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)) / 1048576.0
	_rep["vram_buffer_mb"] = float(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)) / 1048576.0
	_rep["idle_objects"] = idle_obj
	_rep["idle_orphans"] = idle_orph
	if idle_mem.size() >= 2:
		# The number that matters: MB per second of doing nothing.
		var secs := maxf((Time.get_ticks_msec() - t) / 1000.0, 0.001)
		_rep["idle_mem_slope_mb_s"] = snappedf(
			(float(idle_mem[-1]) - float(idle_mem[0])) / secs, 0.01)
		_rep["idle_orphan_growth"] = int(idle_orph[-1]) - int(idle_orph[0])
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return await _abort(tree, "there is no 3D editor viewport to fly in")
	var draws := 0
	for i in range(5):
		await tree.process_frame
		draws = vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	_rep["probe_draws"] = draws
	_rep["first_drawn_ms"] = Time.get_ticks_msec()
	# EVERYTHING ABOVE CAN SUCCEED AND STILL LEAVE AN EMPTY VIEW. It has
	# happened: 40,581 prop surfaces in the tree, 44 draw calls on screen, 4.1 ms
	# a frame, and it looked like a spectacular improvement.
	var prims := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
			Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	_rep["probe_prims"] = prims
	# BOTH, or it fires on its own success. A cell merge cuts calls by design;
	# what it cannot do is cut the triangles being rasterised, so those are what
	# separate "nothing is on screen" from "the same scene in fewer calls".
	if draws < int(_cfg["min_draws"]) and prims < int(_cfg["min_prims"]):
		return await _abort(tree, ("the map built but the viewport is drawing "
				+ "only %d calls and %d primitive(s), so nothing worth "
				+ "measuring is on screen") % [draws, prims])
	_phase_end()

	# ---- fly ---------------------------------------------------------------
	_phase_begin("flight")
	var samples := _load_path(str(_cfg["flight"]))
	_rep["flight_path"] = str(_cfg["flight"])
	_rep["flight_samples"] = samples.size()
	if samples.is_empty():
		return await _abort(tree, "no recorded path at %s" % str(_cfg["flight"]))
	var fly: Dictionary = await _fly(tree, vp, samples)
	if fly.has("error"):
		return await _abort(tree, str(fly["error"]))
	_rep.merge(fly, true)
	_phase_end()

	# ---- census -------------------------------------------------------------
	# WHICH LAYER OWNS THE DRAW CALLS. The flight says the worst viewpoint costs
	# 59 ms at ~19,000 draws and that frame time tracks draws at +0.87, but it
	# cannot say WHOSE draws those are, and optimising before knowing that is
	# guessing. Taken after the flight so it cannot perturb the frames, and it
	# is structural (a tree walk, not a frustum query), so the camera position
	# does not matter: it counts everything built, which at the vista viewpoint
	# is very nearly what is on screen.
	# Stop before the census: a deep tree walk is not a per-frame cost and would
	# only add a bucket nobody asked about.
	HighpolyProfile.set_enabled(false)
	_rep["profile"] = HighpolyProfile.stats()

	_phase_begin("census")
	var croot := EditorInterface.get_edited_scene_root()
	if croot != null:
		_rep["census"] = HighpolyCensus.take(croot)
	# WHOSE MEMORY IS IT. A run with every layer off still measured 3,001 MB of
	# texture memory with nothing built, which matches what users report, but a
	# process total cannot separate our caches from the SDK scene's. This asks
	# our caches directly, so the split is attributed rather than inferred.
	if mapctx != null and "game_source" in mapctx and mapctx.game_source != null:
		var gs = mapctx.game_source
		if gs.has_method("cache_stats"):
			_rep["cache_stats"] = gs.cache_stats()
	# IS BAKING CELLS AFFORDABLE? Measured, not argued. Props have 7,053 distinct
	# meshes against a 5,266-draw budget, so nothing that regroups existing
	# meshes can reach 60 fps - the only way under the floor is merging vertex
	# data. This bakes a handful of the furthest cells and reports what it cost
	# and what it would have saved, WITHOUT changing the scene, so the pipeline
	# is sized before any of it is built.
	if mapctx != null and "_cells" in mapctx:
		var cam := vp.get_camera_3d() if vp != null else null
		if cam != null:
			_phase_begin("hlod probe")
			# Two weld sizes plus the full-detail control, because the whole
			# question is what the coarse step buys. 0.5 m and 1.0 m are the
			# range worth considering for something seen from hundreds of
			# metres; the control says what it was before welding.
			# TWO CELLS, TWO WELD SIZES. The previous version baked 4 cells at
			# three weld sizes and the run HUNG at 343 s - a dense cell holds
			# 18 M vertices and there are 12 of those passes. The question here
			# is the RATIO the weld buys, and two cells answer it; sizing the
			# whole map is arithmetic once the ratio is known.
			# ONE CELL PER WELD SIZE, and the run needs --hang-s raised past the
			# default 90 s to allow it. bake_cell blocks the main thread and
			# writes no heartbeat, and the DENSEST cell is far heavier than the
			# 18 M-vertex average across the top eight, so two cells at full
			# detail already ran past the budget and were killed as a hang
			# twice. The ratio a weld buys is what this is for, and one cell
			# gives it; the whole map is arithmetic afterwards.
			# NOT A PROBE ANY MORE: bake the three heaviest cells and PUT THEM
			# IN, so the draw count is measured rather than predicted. One cell
			# carries 9,744 of 18,766 draws and bakes to 1, so three should be
			# most of the frame. Cached to the map's own directory, so a second
			# run pays nothing.
			# MEASURED AT THE WORST VIEWPOINT, which is the flight's FIRST
			# sample - 106 m up facing the horizon with the whole map in
			# frustum. The install runs after the flight, so the camera is
			# sitting in the last quarter where frustum culling leaves 260
			# calls on screen; reading draws there would flatter any change
			# enormously and say nothing. Put the camera back first, take the
			# before, install, take the after.
			var hcam := vp.get_camera_3d()
			if hcam != null and not samples.is_empty():
				hcam.global_transform = samples[0]["t"]
				for _w in range(4):
					await tree.process_frame
				_rep["hlod_draws_before"] = vp.get_render_info(
					Viewport.RENDER_INFO_TYPE_VISIBLE,
					Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			# NATIVE vs GDSCRIPT ON THE SAME CELL. One cell, both paths, so the
			# speedup is measured rather than claimed - and the vertex counts
			# are compared too, because a merge that is fast and wrong is worse
			# than a slow one.
			_phase_begin("hlod native ab")
			var ranked := HighpolyHlod.by_weight_public(mapctx._cells)
			if not ranked.is_empty():
				var lst: Array = ranked[0]["list"]
				var ctr := HighpolyHlod.centre_public(lst)
				var t_n := Time.get_ticks_msec()
				var rn := HighpolyHlod.bake_cell_native(lst, ctr, 1.0)
				var n_ms := Time.get_ticks_msec() - t_n
				var t_g := Time.get_ticks_msec()
				var rg := HighpolyHlod.bake_cell(lst, ctr, 1.0)
				var g_ms := Time.get_ticks_msec() - t_g
				_rep["hlod_native_ab"] = {
					"native_ms": n_ms, "gdscript_ms": g_ms,
					"native_verts": rn.get("verts", -1),
					"gdscript_verts": rg.get("verts", -1),
					"native_tris": rn.get("tris", -1),
					"gdscript_tris": rg.get("tris", -1),
					"native_available": rn.has("native"),
				}
			_phase_end()

			# BANK THE MEASUREMENT BEFORE THE OPTIONAL EXPERIMENT.
			#
			# Everything below is extra: an HLOD bake that is not part of what a
			# user experiences and is not what this run was asked to measure. It
			# is also a long main-thread operation with no heartbeat, so the
			# harness sees silence, calls it a hang and kills the editor -
			# throwing away a completed flight because a bolt-on afterwards took
			# too long. That is exactly what happened on the run this comment was
			# written for: build 138 s, flight 57 s, both fine, and the report
			# came back with frames = 0 and outcome "hang".
			#
			# So the report is written HERE, with what has already been measured,
			# and written again at the end if the extra work finishes.
			_rep["valid"] = true
			_rep["partial"] = true
			_rep["engine"] = _engine()
			_bank_report()
			var mapname := str(_cfg["map"])
			_rep["hlod_install"] = HighpolyHlod.bake_and_install(
				mapctx._cells, 12, 1.0, "user://mapcontext/%s" % mapname,
				mapctx.hlod_cells)
			for _w2 in range(4):
				await tree.process_frame
			_rep["hlod_draws_after"] = vp.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
			_phase_end()
	_phase_end()

	_rep["valid"] = true
	_rep["engine"] = _engine()
	_rep["plugin_log"] = {"errors": Log.error_count(), "warnings": Log.warning_count()}
	await _finish(tree, 0)
	return true


# ---------------------------------------------------------------------------
# the flight
# ---------------------------------------------------------------------------

# Fly the recorded path and time every frame that is drawn along it.
#
# THE EDITOR'S OWN VIEWPORT, driven by writing its Camera3D transform. A private
# SubViewport sharing the World3D also works and is worse on two counts: the
# flight is invisible, so a run that silently measured nothing cannot be told
# from a good one, and it draws the whole scene a SECOND time every frame, so
# every number includes two renders of the map.
static func _fly(tree: SceneTree, vp: SubViewport, samples: Array) -> Dictionary:
	var cam: Camera3D = vp.get_camera_3d()
	if cam == null:
		return {"error": "the editor viewport has no camera"}

	# THE EDITOR THROTTLES ITSELF WHEN NOTHING HAS FOCUS, and an unattended run
	# never has focus. The default 100000 usec sleep produced a flight with a
	# mean of 100.0 ms and almost no variance, which is the signature of a cap
	# and not of a cost. Both sleeps go to zero and are put back afterwards.
	var es := EditorInterface.get_editor_settings()
	var k_un := "interface/editor/unfocused_low_processor_mode_sleep_usec"
	var k_fo := "interface/editor/low_processor_mode_sleep_usec"
	var was_un: Variant = es.get_setting(k_un) if es != null and es.has_setting(k_un) else null
	var was_fo: Variant = es.get_setting(k_fo) if es != null and es.has_setting(k_fo) else null
	if was_un != null:
		es.set_setting(k_un, 0)
	if was_fo != null:
		es.set_setting(k_fo, 0)

	var hold_us: int = int(_cfg["hold_ms"]) * 1000
	var ms: Array = []            # per drawn frame
	var dr: Array = []
	var sh: Array = []
	var of: Array = []            # which recorded sample each frame belongs to
	var still: Array = []         # was the camera standing still for that sample
	var stuck := 0
	_samples_total = samples.size()
	var t_fly := Time.get_ticks_msec()

	for i in range(samples.size()):
		var s: Dictionary = samples[i]
		var tf: Transform3D = s["t"]
		cam.global_transform = tf
		# REPLAY AT THE RECORDED SPEED, not one sample per frame. Advancing per
		# frame ties the camera's speed to the frame rate, and anything the
		# renderer does over TIME rather than per frame (shadow cascades, SDFGI
		# convergence, LOD hysteresis) then answers a different question in
		# every configuration. Each sample is held for its 50 ms and every frame
		# drawn inside that window is timed.
		var until := Time.get_ticks_usec() + hold_us
		var st: bool = bool(s["still"])
		while true:
			var f0 := Time.get_ticks_usec()
			await tree.process_frame
			var dt := float(Time.get_ticks_usec() - f0) / 1000.0
			if ms.size() < MAX_FRAMES:
				ms.append(dt)
				# BOTH PASSES. Shadow rendering is counted separately under
				# _TYPE_SHADOW, and reading only the visible pass made the draw
				# call total identical to the digit across a shadow cascade
				# change, which looks like a stuck instrument.
				dr.append(vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
						Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
				sh.append(vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW,
						Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
				of.append(i)
				still.append(st)
			_frame += 1
			_sample = i
			_tick()
			if Time.get_ticks_usec() >= until:
				break
		if cam.global_transform.origin.distance_to(tf.origin) < 0.5:
			stuck += 1

	if was_un != null:
		es.set_setting(k_un, was_un)
	if was_fo != null:
		es.set_setting(k_fo, was_fo)
	if ms.is_empty():
		return {"error": "no frames were recorded during the flight"}

	var out := _summarise(ms, dr, sh, of, still, samples)
	out["flight_ms"] = Time.get_ticks_msec() - t_fly
	out["camera_held"] = stuck
	out["camera_tried"] = samples.size()
	return out


# The numbers, and the ones that are easy to fool yourself with.
static func _summarise(ms: Array, dr: Array, sh: Array, of: Array,
		still: Array, samples: Array) -> Dictionary:
	var n := ms.size()
	var sorted := ms.duplicate()
	sorted.sort()
	var sum := 0.0
	var under60 := 0
	var under30 := 0
	for v in ms:
		sum += float(v)
		if float(v) > MS_60:
			under60 += 1
		if float(v) > MS_30:
			under30 += 1
	# THE 1% LOW IS THE AVERAGE OF THE WORST 1% OF FRAMES, not the 99th
	# percentile sample. It is the number that moves when a run stalls four
	# times, which is exactly the failure the mean hides.
	var worst_n: int = maxi(1, int(n * 0.01))
	var low1 := 0.0
	for i in range(n - worst_n, n):
		low1 += float(sorted[i])
	low1 /= float(worst_n)

	# ---- stutter, split by whether the camera was moving -------------------
	#
	# STATIONARY VARIANCE IS THE MOST DAMNING SIGNAL THERE IS. When nothing
	# moves the renderer is doing the same work every frame, so any spread is
	# work arriving from somewhere else: a build thread, a cache flush, a
	# per frame allocation, a shader still compiling. A mean over the whole
	# flight hides it completely, which is why it is reported on its own.
	#
	# Two flavours of stationary, and they are not the same claim. Frames inside
	# ONE held sample are stationary by construction, since the camera transform
	# is written once and held. Runs of consecutive samples at nearly the same
	# position are stationary because the recording says the user stopped there.
	var intra := _spread_within_samples(ms, of)
	var s_ms: Array = []
	var m_ms: Array = []
	for i in range(n):
		if bool(still[i]):
			s_ms.append(ms[i])
		else:
			m_ms.append(ms[i])

	# where the worst frame happened, so it can be gone and looked at
	var worst_i := 0
	for i in range(n):
		if float(ms[i]) > float(ms[worst_i]):
			worst_i = i
	var worst_s: int = int(of[worst_i])
	var wpos: Array = []
	if worst_s < samples.size():
		var tf: Transform3D = (samples[worst_s] as Dictionary)["t"]
		wpos = [snappedf(tf.origin.x, 0.1), snappedf(tf.origin.y, 0.1),
				snappedf(tf.origin.z, 0.1)]

	var dsum := 0
	var dmax := 0
	var ssum := 0
	var smax := 0
	for d in dr:
		dsum += int(d)
		dmax = maxi(dmax, int(d))
	for d in sh:
		ssum += int(d)
		smax = maxi(smax, int(d))

	return {
		"frames": n,
		# THE HEADLINE, in the order it should be read.
		"frames_under_60": under60,
		"pct_under_60": snappedf(100.0 * under60 / float(n), 0.01),
		"frames_under_30": under30,
		"fps_1pct_low": snappedf(1000.0 / maxf(low1, 0.001), 0.1),
		"low1_ms": snappedf(low1, 0.01),
		"worst_ms": snappedf(float(sorted[n - 1]), 0.01),
		"worst_at_sample": worst_s,
		"worst_at_pos": wpos,
		# reported, but never the headline
		"mean_ms": snappedf(sum / float(n), 0.01),
		"median_ms": snappedf(float(sorted[n / 2]), 0.01),
		"p95_ms": snappedf(float(sorted[mini(n - 1, int(n * 0.95))]), 0.01),
		"p99_ms": snappedf(float(sorted[mini(n - 1, int(n * 0.99))]), 0.01),
		"fps_mean": snappedf(1000.0 / maxf(sum / float(n), 0.001), 0.1),
		"stutter": {
			"stationary": _stats(s_ms),
			"moving": _stats(m_ms),
			"within_one_sample": intra,
		},
		"draws_mean": int(dsum / maxi(1, n)),
		"draws_peak": dmax,
		"shadow_draws_mean": int(ssum / maxi(1, n)),
		"shadow_draws_peak": smax,
		"frame_ms": ms,
		"frame_sample": of,
		# PER-FRAME DRAW CALLS, kept rather than only summarised.
		#
		# Only the mean and the peak used to survive, and with a 5,662 mean
		# against a 26,008 peak the summary cannot answer the one question that
		# matters: is a slow stretch slow because it is DRAWING MORE, or because
		# something else is happening in it. Four runs were spent hypothesising
		# about a first quarter that costs 60 ms a frame while the array that
		# settles it was being computed and thrown away.
		#
		# Costs one int per frame, alongside frame_ms which is already kept.
		"frame_draws": dr,
		"frame_shadow_draws": sh,
	}


# Frame time spread, with the two figures that describe a stutter: the jitter
# (how much consecutive frames differ) and the spikes (how many frames stood out
# against this group's own median rather than against the whole run's).
static func _stats(v: Array) -> Dictionary:
	var n := v.size()
	if n == 0:
		return {"frames": 0}
	var s := v.duplicate()
	s.sort()
	var med := float(s[n / 2])
	var sum := 0.0
	for x in v:
		sum += float(x)
	var jit := 0.0
	for i in range(1, n):
		jit += absf(float(v[i]) - float(v[i - 1]))
	jit = jit / maxf(1.0, float(n - 1))
	var spikes := 0
	for x in v:
		# BOTH CONDITIONS. A ratio alone calls 2 ms against 1 ms a spike; an
		# absolute alone never fires on a fast configuration at all.
		if float(x) > med * 1.5 and float(x) > med + 8.0:
			spikes += 1
	return {
		"frames": n,
		"mean_ms": snappedf(sum / float(n), 0.01),
		"median_ms": snappedf(med, 0.01),
		"p99_ms": snappedf(float(s[mini(n - 1, int(n * 0.99))]), 0.01),
		"max_ms": snappedf(float(s[n - 1]), 0.01),
		"jitter_ms": snappedf(jit, 0.01),
		"spikes": spikes,
		"pct_spikes": snappedf(100.0 * spikes / float(n), 0.01),
	}


# The spread INSIDE each held sample, where the camera provably did not move.
# Only samples that drew at least three frames can say anything.
static func _spread_within_samples(ms: Array, of: Array) -> Dictionary:
	var groups: Dictionary = {}
	for i in range(ms.size()):
		var k: int = int(of[i])
		if not groups.has(k):
			groups[k] = []
		(groups[k] as Array).append(ms[i])
	var spreads: Array = []
	var worst := {"sample": -1, "spread_ms": 0.0}
	var counted := 0
	for k in groups:
		var g: Array = groups[k]
		if g.size() < 3:
			continue
		counted += 1
		var s := g.duplicate()
		s.sort()
		var spread := float(s[s.size() - 1]) - float(s[s.size() / 2])
		spreads.append(spread)
		if spread > float(worst["spread_ms"]):
			worst = {"sample": int(k), "spread_ms": snappedf(spread, 0.01),
					"median_ms": snappedf(float(s[s.size() / 2]), 0.01),
					"max_ms": snappedf(float(s[s.size() - 1]), 0.01),
					"frames": g.size()}
	if spreads.is_empty():
		return {"samples": 0,
				"note": "no sample drew three frames, so nothing can be said "
						+ "about spread while standing still"}
	spreads.sort()
	var sum := 0.0
	for x in spreads:
		sum += float(x)
	return {
		"samples": counted,
		"median_spread_ms": snappedf(float(spreads[spreads.size() / 2]), 0.01),
		"p99_spread_ms": snappedf(float(spreads[mini(spreads.size() - 1,
				int(spreads.size() * 0.99))]), 0.01),
		"mean_spread_ms": snappedf(sum / float(spreads.size()), 0.01),
		"worst": worst,
	}


# ---------------------------------------------------------------------------
# driving and asserting the dock
# ---------------------------------------------------------------------------

# DRIVE THE DOCK, DO NOT REIMPLEMENT IT. Calling mapctx.apply() directly with
# the flags it wants is a different thing from what the panel does and produces
# a map that builds and then does not appear: the dock also sets the detail
# tier, the range slider, the placed object cull and the per map state.
#
# The controls are members of the EditorPlugin, not of the VBoxContainer it
# added them to, so this takes `plug` and not `dock`.
static func _drive_dock(plug: Node, cfg: Dictionary) -> Dictionary:
	var out := {}
	if plug == null:
		return out

	# Detail mode first: the layer switches read it when they build.
	var mb = plug.get("mode_btn")
	if mb != null and mb is OptionButton:
		var want := int(cfg["mode"])
		for i in range((mb as OptionButton).item_count):
			if (mb as OptionButton).get_item_id(i) == want:
				(mb as OptionButton).select(i)
				(mb as OptionButton).item_selected.emit(i)
				out["mode"] = want
				break

	# THE RANGE SLIDER BEFORE THE LAYERS, so nothing is built already culled,
	# and always to the TOP of its range. This is rule 1 and the harness only
	# ever moves this control upwards.
	var sl = plug.get("mapctx_range")
	if sl != null and sl is HSlider:
		var s := sl as HSlider
		s.value = s.max_value
		s.value_changed.emit(s.value)
		out["range"] = s.value

	# Then the layers. button_pressed fires `toggled`, which is the path a click
	# takes. mapctx_objects is "Original map objects" and lives on the Detail
	# Mode chip row rather than beside the other map context toggles, which is
	# how it came to be left out of an earlier driven run.
	for pair in [["mapctx_on", bool(cfg.get("map_context", true))],
				 ["mapctx_objects", bool(cfg.get("objects", true))],
				 ["mapctx_backdrop", bool(cfg.get("backdrop", true))],
				 ["mapctx_water", bool(cfg.get("water", true))],
				 ["mapctx_light", bool(cfg.get("lighting", true))],
				 ["mapctx_gi", bool(cfg.get("gi", true))],
				 ["mapctx_shadows", bool(cfg.get("shadows", true))],
				 ["mapctx_maplights", bool(cfg.get("map_lights", true))],
				 # ROADS, GRASS AND PROP LIGHTING WERE NEVER DRIVEN, so every
				 # "worst case" before this measured a map with three layers
				 # switched off and called it everything. The target is 60 fps
				 # with everything on except FX, so everything on except FX is
				 # what has to be driven.
				 ["mapctx_roads", bool(cfg.get("roads", true))],
				 ["mapctx_grass", bool(cfg.get("grass", true))],
				 ["prop_light_on", bool(cfg.get("prop_lighting", true))],
				 # FX IS OFF, deliberately and by default. The 60 fps target is
				 # stated for everything else, and FX is the one layer the
				 # target explicitly excludes.
				 ["mapctx_fx", bool(cfg.get("fx", false))]]:
		var nm := str(pair[0])
		var on := bool(pair[1])
		var b = plug.get(nm)
		if b == null or not (b is Button):
			continue
		var btn := b as Button
		if btn.button_pressed != on:
			btn.button_pressed = on           # emits toggled
		else:
			btn.toggled.emit(on)              # already there: still run it
		out[nm] = on
	return out


# Read the configuration back off the panel. Driving a control and having it
# hold are different things: a gated chip refuses silently when its data is not
# there, and the per map state restore can put the slider back.
static func _assert_config(plug: Node, mapctx: Node) -> Dictionary:
	var st := {"ok": true, "problems": []}
	if plug != null and plug.has_method("_perf_state"):
		st["panel"] = plug.call("_perf_state")
	var probs: Array = st["problems"]

	# RULE 1, CHECKED AND NEVER CORRECTED DOWNWARDS.
	var sl = plug.get("mapctx_range") if plug != null else null
	var sv := -1.0
	if sl != null and sl is HSlider:
		sv = (sl as HSlider).value
	st["range_value"] = sv
	if sv < NO_CULL_SLIDER:
		st["ok"] = false
		probs.append("the range slider read back %.0f, not its maximum %.0f, so "
				% [sv, NO_CULL_SLIDER]
				+ "distance culling is ON and the run would measure the cost of "
				+ "not drawing things")
	var rad := -1.0
	if mapctx != null:
		var r = mapctx.get("radius")
		if r != null:
			rad = float(r)
	st["radius"] = rad
	if rad >= 0.0 and rad < float(_cfg["min_radius"]):
		st["ok"] = false
		probs.append("the map context radius is %.0f m, below the %.0f m that "
				% [rad, float(_cfg["min_radius"])] + "means no culling")

	# Everything on except FX, and the mode that actually has textures on it.
	var panel: Dictionary = st.get("panel", {})
	if not panel.is_empty():
		var want := {
			"map_context": "on" if bool(_cfg["map_context"]) else "off",
			"objects": "on" if bool(_cfg["objects"]) else "off",
			"backdrop": "on" if bool(_cfg["backdrop"]) else "off",
			"water": "on" if bool(_cfg["water"]) else "off",
			"lighting": "on" if bool(_cfg["lighting"]) else "off",
			"contact_shading": "on" if bool(_cfg["gi"]) else "off",
			"shadows": "on" if bool(_cfg["shadows"]) else "off",
			"map_lights": "on" if bool(_cfg["map_lights"]) else "off",
			"fx": "on" if bool(_cfg["fx"]) else "off",
		}
		var wrong: Array = []
		for k in want:
			if str(panel.get(k, "-")) != str(want[k]):
				wrong.append("%s is %s and should be %s"
						% [k, str(panel.get(k, "-")), str(want[k])])
		if not wrong.is_empty():
			# NOT FATAL BY ITSELF, because a gated layer means the map's data is
			# not on this machine yet, which is a different problem from a
			# broken harness. Recorded loudly so no comparison is made against a
			# run that was quietly missing a layer.
			st["layers_wrong"] = wrong
		if int(panel.get("mode", -1)) != int(_cfg["mode"]):
			st["ok"] = false
			probs.append("detail mode is %d and should be %d"
					% [int(panel.get("mode", -1)), int(_cfg["mode"])])
	return st


# ---------------------------------------------------------------------------
# capturing and correlating everything the editor printed
# ---------------------------------------------------------------------------

# Godot writes its Output panel to the log file it was launched with, and our
# own push_error and push_warning land in the same place. Read incrementally
# WHILE the run happens rather than at the end, so every line can be stamped
# with the phase and the frame it happened in: "error" is nearly useless for
# perf work, "error during the skyline build, at frame 412" is a lead.
static func _drain_log() -> void:
	if _log_path == "":
		return
	var f := FileAccess.open(_log_path, FileAccess.READ)
	if f == null:
		return
	var end := int(f.get_length())
	if end <= _log_pos:
		f.close()
		return
	# capped per drain so one enormous burst cannot stall the frame being timed
	var take: int = mini(end - _log_pos, 1 << 20)
	f.seek(_log_pos)
	var chunk := f.get_buffer(take).get_string_from_utf8()
	_log_pos += take
	f.close()
	_log_partial += chunk
	var parts := _log_partial.split("\n")
	_log_partial = parts[parts.size() - 1]      # the tail may be half a line
	for i in range(parts.size() - 1):
		_ingest(String(parts[i]).strip_edges(false, true))


static func _ingest(line: String) -> void:
	if line.strip_edges() == "":
		return
	# OUR OWN LINES ARE SKIPPED, and this is not tidiness. Everything printed
	# goes into the same log being read, so echoing a captured line would feed
	# it straight back in and amplify one message into thousands.
	if line.begins_with("[perfrun]"):
		return
	_raw_seen += 1
	# AN ERROR IS SEVERAL LINES. Godot prints the message, then "   at:" naming
	# the C++ call site, then the GDScript backtrace:
	#
	#   ERROR: the message
	#      at: push_error (core/variant/variant_utility.cpp:1024)
	#      GDScript backtrace (most recent call first):
	#          [0] _build (res://addons/highpoly_toggle/highpoly_fx.gd:812)
	#
	# The frame naming OUR file is the only part worth reading, and it is the
	# third continuation, so they are all attached to the message above rather
	# than counted as three more distinct errors.
	var cont := line.begins_with(" ") or line.begins_with("\t")
	if cont and _last_sig != "" and _sigs.has(_last_sig):
		var e: Dictionary = _sigs[_last_sig]
		var trail: Array = e["at"]
		# Only the FIRST occurrence's backtrace is kept. The hundredth copy of
		# the same error has the same one, and letting repeats append turns a
		# useful trace into a smear of half traces from different occurrences.
		if int(e["n"]) <= 1 and trail.size() < 6:
			trail.append(line.strip_edges().left(300))
		return
	_last_sig = ""
	var sig := _signature(line)
	if not _sigs.has(sig):
		if _sigs.size() >= MAX_SIGS:
			sig = "(other)"
		if not _sigs.has(sig):
			_sigs[sig] = {"text": line.left(400), "n": 0, "at": [],
					"first_frame": _frame, "first_phase": _phase,
					"last_frame": _frame, "phases": {}}
	_last_sig = sig
	var ent: Dictionary = _sigs[sig]
	ent["n"] = int(ent["n"]) + 1
	ent["last_frame"] = _frame
	var ph: Dictionary = ent["phases"]
	ph[_phase] = int(ph.get(_phase, 0)) + 1

	var rec := {"phase": _phase, "frame": _frame, "sample": _sample,
			"t_ms": Time.get_ticks_msec(), "text": line.left(400), "sig": sig}
	if _head.size() < MAX_HEAD:
		_head.append(rec)
	_tail.append(rec)
	if _tail.size() > MAX_TAIL:
		_tail.pop_front()


# Two occurrences of the same bug differ in their numbers and their addresses,
# so the counting key drops those. Without it a per frame error looks like a
# thousand unrelated errors and never gets ranked.
static func _signature(line: String) -> String:
	var s := ""
	var prev_digit := false
	for i in range(mini(line.length(), 300)):
		var c := line[i]
		if c >= "0" and c <= "9":
			if not prev_digit:
				s += "#"
			prev_digit = true
		else:
			prev_digit = false
			s += c
	return s


# ---------------------------------------------------------------------------
# heartbeat, phases, and giving up early
# ---------------------------------------------------------------------------

# The heartbeat is the ONLY signal that survives a hang, and it is a file rather
# than a printed line on purpose: stdout through a pipe is block buffered, so a
# progress line can sit unflushed in a buffer for exactly as long as the thing
# it was meant to prove is still alive. A file that stops being written is
# unambiguous, and its last contents say where it stopped.
static func _tick() -> void:
	var now := Time.get_ticks_msec()
	if now < _hb_next:
		return
	_hb_next = now + 500
	_drain_log()
	if _hb_path == "":
		return
	var f := FileAccess.open(_hb_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"phase": _phase, "frame": _frame, "sample": _sample,
		"of": _samples_total, "t_ms": now,
		"unix": Time.get_unix_time_from_system(),
		"errors": _raw_seen,
	}))
	f.close()


static func _phase_begin(name: String) -> void:
	_phase = name
	_phase_t = Time.get_ticks_msec()
	_hb_next = 0
	_tick()
	_say("perfrun: phase %s" % name)


static func _phase_end() -> void:
	_spans[_phase] = Time.get_ticks_msec() - _phase_t
	_say("perfrun: phase %s took %.1f s" % [_phase, float(_spans[_phase]) / 1000.0])


# Stop now and say where. A configuration that is going to produce a useless
# number should cost seconds, not the ten minutes a full run takes.
static func _abort(tree: SceneTree, why: String) -> bool:
	_rep["aborted"] = {"phase": _phase, "why": why,
			"after_s": snappedf(float(Time.get_ticks_msec() - _phase_t) / 1000.0, 0.1)}
	_rep["valid"] = false
	_say("perfrun: ABORTED in %s: %s" % [_phase, why])
	await _finish(tree, 1)
	return false


# Write what has been measured so far, so a later hang cannot destroy it.
#
# Deliberately not _finish: that also drains the log, stamps totals and quits.
# This is the same file, written early, and _finish overwrites it with the
# complete version if the run gets that far.
static func _bank_report() -> void:
	var out := str(_cfg.get("out", "user://perfrun.json"))
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f != null:
		_rep["spans_ms"] = _spans
		f.store_string(JSON.stringify(_rep, " "))
		f.close()
		_say("perfrun: banked a partial report to %s"
			% ProjectSettings.globalize_path(out))


static func _finish(tree: SceneTree, code: int) -> void:
	_rep["partial"] = false
	_spans[_phase] = Time.get_ticks_msec() - _phase_t
	_drain_log()
	_rep["spans_ms"] = _spans
	_rep["total_ms"] = Time.get_ticks_msec()
	_rep["dialogs_seen"] = _dialogs_seen
	# The captured output, in the three shapes it is actually read in: the
	# ranked repeats (a message thrown every frame is a frame cost, not just a
	# bug), the first ones (what went wrong earliest usually explains the rest)
	# and the last fifty (the cause is in the artefact rather than only on
	# somebody's screen).
	var ranked: Array = []
	for k in _sigs:
		var e: Dictionary = _sigs[k]
		ranked.append({"text": e["text"], "at": e["at"], "n": e["n"],
				"first_frame": e["first_frame"], "first_phase": e["first_phase"],
				"last_frame": e["last_frame"], "phases": e["phases"]})
	ranked.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))
	_rep["log"] = {
		"source": _log_path,
		"lines_seen": _raw_seen,
		"distinct": _sigs.size(),
		"ranked": ranked,
		"head": _head,
		"tail": _tail,
	}
	# THE JOURNAL AGAIN, LAST. It is also written when the build phase ends, and
	# for a run with props that is the whole story. For a terrain-only run it is
	# not: the ground bake outlives the build phase, so the table captured there
	# stopped before the splat composite and the layer textures - the two phases
	# the run existed to measure. Written twice rather than moved, because the
	# build-phase copy is what survives a run that dies during the flight.
	_save_journal()
	var out := str(_cfg.get("out", "user://perfrun.json"))
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_rep, " "))
		f.close()
		_say("perfrun: wrote %s" % ProjectSettings.globalize_path(out))
	else:
		_say("perfrun: COULD NOT WRITE %s" % out)
	# A last heartbeat saying it finished on purpose, so the driver can tell a
	# clean exit from a process that simply stopped existing.
	_phase = "done"
	_hb_next = 0
	_tick()
	if tree != null:
		await tree.process_frame        # flush before quitting
		tree.quit(code)


# ---------------------------------------------------------------------------
# odds and ends
# ---------------------------------------------------------------------------

# The recorded path, as transforms, with the standing still flag worked out once
# here rather than in three places later.
#
# NOTE the path is keyed by BASE MAP: a flight recorded on
# MP_Aftermath_CapitalSupremacy is stored as bf6_flightpath_MP_Aftermath.json.
static func _load_path(p: String) -> Array:
	var txt := FileAccess.get_file_as_string(p)
	if txt == "":
		return []
	var d: Variant = JSON.parse_string(txt)
	if not (d is Dictionary) or not (d as Dictionary).has("samples"):
		return []
	var out: Array = []
	var prev := Vector3.ZERO
	var first := true
	for s in (d as Dictionary)["samples"]:
		var b: Array = s["b"]
		var pa: Array = s["p"]
		if b.size() < 9 or pa.size() < 3:
			continue
		var pos := Vector3(pa[0], pa[1], pa[2])
		var tf := Transform3D(
				Basis(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]),
					  Vector3(b[6], b[7], b[8])), pos)
		# The recorder DROPS samples that did not move, so a long pause is one
		# sample rather than a hundred. What survives is a pair of neighbours
		# that are nearly in the same place, which is what this looks for.
		var still := (not first) and pos.distance_to(prev) < STILL_M
		out.append({"t": tf, "still": still})
		prev = pos
		first = false
	return out


static func _base_map(name: String) -> String:
	for k in ["MP_Aftermath", "MP_Dumbo", "MP_Granite", "MP_Contaminated"]:
		if name.findn(k) == 0:
			return k
	return name


static func _scene_for(map: String) -> String:
	# Found rather than constructed: the layout has moved between SDK versions
	# and a constructed path fails silently as "the scene did not open".
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


# RECORDED, NOT BLINDLY CLOSED. The SDK asks before fetching a map's content, so
# dismissing everything that appears is how an unattended run silently cancels
# the thing it was measuring. Only dialogs known to be safe are closed; the rest
# are named, and a run that hangs behind one says which one.
static func _dismiss_dialogs() -> int:
	var base := EditorInterface.get_base_control()
	if base == null:
		return 0
	var n := 0
	for w in _windows(base.get_tree().root, 0):
		if not w.visible:
			continue
		if str(w.name).begins_with("Highpoly"):
			continue
		var title := ""
		if w is AcceptDialog:
			title = (w as AcceptDialog).title
		else:
			title = (w as Window).title
		_dialogs_seen[title] = int(_dialogs_seen.get(title, 0)) + 1
		var low := title.to_lower()
		if w is AcceptDialog and (low.contains("error") or low.contains("warning")
				or low.contains("debugger") or low.contains("output")):
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


# What the engine is doing that nobody asked it to. "The editor is slow" has
# more than once turned out to be orphaned nodes or video memory climbing until
# the driver started evicting, and none of that appears in a frame time.
static func _engine() -> Dictionary:
	return {
		"mem_static_mb": snappedf(Performance.get_monitor(
				Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"vram_mb": snappedf(Performance.get_monitor(
				Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"texture_mb": snappedf(Performance.get_monitor(
				Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(
				Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
	}


# Write the build journal next to this run's report, so the per-phase account
# of the load travels with the numbers instead of being overwritten by whoever
# builds next. Best effort in every direction: a run must not fail because the
# journal could not be written, and this harness does not preload the journal
# script (see the note at the top of the file) so a change over there cannot
# stop a run from starting.
static func _save_journal() -> void:
	var j = load("res://addons/highpoly_toggle/highpoly_journal.gd")
	if j == null:
		return
	# Backslashes normalised first: the session hands over a Windows path and
	# get_base_dir splits on forward slashes only, so the un-normalised form
	# yields the whole path back and the journal lands somewhere surprising.
	var out := str(_cfg.get("out", "")).replace("\\", "/")
	if out == "":
		return
	var path := out.get_base_dir() + "/build_journal.txt"
	j.save(path)
	_say("perfrun: build journal written to %s" % path)


static func _say(s: String) -> void:
	print(s)
	Log.info(s)
