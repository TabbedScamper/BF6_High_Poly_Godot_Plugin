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

const Log = preload("highpoly_log.gd")
const FlightPath = preload("highpoly_flightpath.gd")


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
		_finish(host, cfg, rep)
		return
	var t0 := Time.get_ticks_msec()
	EditorInterface.open_scene_from_path(scene)
	# WAIT FOR THE ROOT, do not count frames. open_scene_from_path is deferred
	# and a big level takes far longer than a fixed handful of frames — ten was
	# enough to report "scene did not open" about a scene that opens perfectly
	# well, which sends you looking for the wrong bug entirely.
	var root: Node = null
	var dismissed := 0
	var tick := 0
	while Time.get_ticks_msec() - t0 < 120000:
		await host.get_tree().process_frame
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
	rep["open_ms"] = Time.get_ticks_msec() - t0
	rep["scene"] = scene
	if root == null:
		rep["error"] = "scene did not open: %s" % scene
		_finish(host, cfg, rep)
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

	t0 = Time.get_ticks_msec()
	var status: String = mapctx.apply(root, true, bool(cfg["objects"]),
			int(cfg["mode"]), bool(cfg["backdrop"]), bool(cfg["water"]))
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
		await host.get_tree().process_frame
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
		if now - last_change > stall_ms and last_seen > 0:
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
	# NOTHING CULLED. The range slider defaults well below the map, so a flight
	# over a culled map measures the cost of not drawing things — which is not
	# the cost being hunted. 1e9 is the slider's own "no cull" value.
	var radius := float(cfg.get("radius", 1.0e9))
	if mapctx.has_method("set_radius"):
		mapctx.set_radius(radius)
		await host.get_tree().process_frame
	rep["radius"] = radius

	var samples := _load_path(str(cfg["flight"]))
	rep["flight_samples"] = samples.size()
	if samples.is_empty():
		rep["flight_error"] = "no flight path at %s" % str(cfg["flight"])
		_say("autorun: %s" % rep["flight_error"])
	else:
		# Settle first: the frames straight after a build are not typical, and
		# averaging them in makes every run look worse than it is.
		for i in range(int(cfg["settle_frames"])):
			await host.get_tree().process_frame
		rep.merge(await _fly(host, samples))
	rep["scene_nodes"] = _count_nodes(root)
	rep["engine"] = _engine()
	# The crumb trail, which is the only record that survives a crash. If the
	# editor dies mid-run there is no report at all, and this is what the next
	# session reads to find out where it died.
	rep["last_crumb"] = HighpolyProfiler.last_session_end()
	_finish(host, cfg, rep)


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
		if w is AcceptDialog:
			# hide() rather than pressing OK: OK on an unknown dialog can mean
			# "overwrite", "delete" or "reimport", and guessing on a project
			# that is not ours is not worth the convenience.
			(w as AcceptDialog).hide()
			n += 1
		elif w is FileDialog:
			(w as FileDialog).hide()
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


static func _fly(host: Node, samples: Array) -> Dictionary:
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
	var es := EditorInterface.get_editor_settings()
	var k_unfocused := "interface/editor/unfocused_low_processor_mode_sleep_usec"
	var k_focused := "interface/editor/low_processor_mode_sleep_usec"
	var was_unfocused = es.get_setting(k_unfocused) if es.has_setting(k_unfocused) else null
	var was_focused = es.get_setting(k_focused) if es.has_setting(k_focused) else null
	if was_unfocused != null:
		es.set_setting(k_unfocused, 0)
	if was_focused != null:
		es.set_setting(k_focused, 0)

	# ALSO MOVE THE EDITOR'S OWN CAMERA, so the flight is visible on screen.
	#
	# Measuring through our own viewport is correct but invisible: the editor
	# sits still while the numbers are taken, which looks exactly like a flight
	# that never ran. Writing the spatial editor's Camera3D directly MAY be
	# overwritten — Node3DEditorViewport recomputes it from its own cursor — so
	# rather than assume either way this writes it and checks whether it held,
	# and the report says how often. A stick rate near zero means the view is
	# decorative; near one means it is the same flight the numbers came from.
	var evp := EditorInterface.get_editor_viewport_3d(0)
	var ecam: Camera3D = evp.get_camera_3d() if evp != null else null
	var stuck := 0
	var tried := 0

	var times: Array[float] = []
	var draws: Array[int] = []
	for s in samples:
		cam.global_transform = s
		if ecam != null:
			ecam.global_transform = s
			tried += 1
		var t0 := Time.get_ticks_usec()
		await host.get_tree().process_frame
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		draws.append(sub.get_render_info(
				Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))
		if ecam != null and ecam.global_transform.origin.distance_to(
				s.origin) < 0.5:
			stuck += 1

	if was_unfocused != null:
		es.set_setting(k_unfocused, was_unfocused)
	if was_focused != null:
		es.set_setting(k_focused, was_focused)
	# free(), not queue_free(): the report is written and the tree torn down in
	# the same frame, and a deferred free would never run.
	sub.free()
	if times.is_empty():
		return {"flight_error": "no frames recorded"}

	# HITCHES ARE THE POINT, so they are counted before anything is averaged.
	# A flight that is smooth for 90% of its length and stalls twice is one
	# people call broken, and a mean hides exactly that.
	var mean := 0.0
	for t in times:
		mean += t
	mean /= float(times.size())
	var hitches := 0
	for t in times:
		if t > maxf(50.0, mean * 3.0):
			hitches += 1

	var sorted := times.duplicate()
	sorted.sort()
	var n := sorted.size()
	var worst_n: int = maxi(1, int(n * 0.01))
	var low1 := 0.0
	for i in range(n - worst_n, n):
		low1 += sorted[i]
	low1 /= float(worst_n)
	var dsum := 0
	var dmax := 0
	for d in draws:
		dsum += d
		dmax = maxi(dmax, d)

	return {
		"frames": n,
		"editor_cam_stuck": stuck,
		"editor_cam_tried": tried,
		"mean_ms": snappedf(mean, 0.01),
		"median_ms": snappedf(sorted[n / 2], 0.01),
		"p95_ms": snappedf(sorted[mini(n - 1, int(n * 0.95))], 0.01),
		"p99_ms": snappedf(sorted[mini(n - 1, int(n * 0.99))], 0.01),
		"low1_ms": snappedf(low1, 0.01),
		"worst_ms": snappedf(sorted[n - 1], 0.01),
		"hitches": hitches,
		"draws_mean": int(dsum / maxi(1, n)),
		"draws_peak": dmax,
	}


# The recorded path as editor-camera transforms.
#
# The basis is stored as nine floats rather than a quaternion precisely so the
# replay can reproduce the view EXACTLY; going through euler angles here — which
# is what a naive set_editor_camera call would do — reintroduces the rounding
# the recorder went out of its way to avoid.
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


static func _finish(host: Node, cfg: Dictionary, rep: Dictionary) -> void:
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
	await host.get_tree().process_frame
	_say("autorun: done in %.1f s" % (rep["total_ms"] / 1000.0))
	host.get_tree().quit(0)


static func _say(s: String) -> void:
	print(s)
	Log.info(s)
