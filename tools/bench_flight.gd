@tool
extends EditorScript

# FLY THE RECORDED PATH AND RECORD EVERY FRAME.
#
# The bench project measures the READER in isolation - a bare project with no
# addon in it at all - which answers "how fast do we parse the game" and says
# nothing about what a user feels while building. This is the other half: the
# real editor, the real scene, flying the path that was actually recorded, with
# a number per frame.
#
# It is deliberately an EditorScript rather than a headless run: the thing being
# measured is the editor viewport with the dock's settings applied, and headless
# has no renderer, so a headless number here would be measuring nothing.
#
# HOW TO GET A BASELINE. Run this once with the plugin DISABLED (Project >
# Project Settings > Plugins > Highpoly Toggle off, reload the project) and once
# with it enabled and everything on except FX. The disabled run is the target -
# it is the SDK alone, which is the fastest the editor can be on this scene.
#
#   Project > Tools > Run EditorScript... > bench_flight.gd
#
# Writes user://bench_flight_<map>_<tag>.json.

const PATH_FMT := "user://bf6_flightpath_%s.json"
# The recorded path is keyed by BASE MAP, not by scene: a path flown on
# MP_Aftermath_CapitalSupremacy is stored as MP_Aftermath. So the scene name is
# trimmed back to the base before looking it up, and a second path recorded on
# another Aftermath variant OVERWRITES this one - worth knowing before blaming
# the harness for playing the wrong route.
const KNOWN_BASES := ["MP_Aftermath", "MP_Dumbo", "MP_Granite", "MP_Contaminated"]

# Tag the run so a baseline and a plugin run cannot be confused for each other
# in the same folder. Set this before running.
@export var tag := "run"


func _run() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_error("[flightbench] no scene open")
		return
	var base := _base_map(String(root.name))
	if base == "":
		push_error("[flightbench] scene '%s' does not look like a known map" % root.name)
		return
	var p := PATH_FMT % base
	if not FileAccess.file_exists(p):
		push_error("[flightbench] no recorded path at %s" % p)
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary) or not (d as Dictionary).has("samples"):
		push_error("[flightbench] %s is not a recorded path" % p)
		return
	var samples: Array = (d as Dictionary)["samples"]
	var hz := float((d as Dictionary).get("hz", 20.0))
	if samples.is_empty():
		push_error("[flightbench] the path has no samples")
		return

	var cam := _viewport_camera()
	if cam == null:
		push_error("[flightbench] could not find the 3D viewport camera")
		return

	print("[flightbench] %s: %d samples at %.0f Hz (%.1f s), tag=%s"
		% [base, samples.size(), hz, samples.size() / hz, tag])
	print("[flightbench] plugin is %s"
		% ("ENABLED" if _plugin_on() else "DISABLED (this is the baseline)"))

	var frames: Array = []
	var t_start := Time.get_ticks_usec()
	for i in range(samples.size()):
		var s: Dictionary = samples[i]
		_place(cam, s)
		# one real frame, drawn, before anything is read back
		await EditorInterface.get_base_control().get_tree().process_frame
		var fps := Performance.get_monitor(Performance.TIME_FPS)
		frames.append({
			"i": i,
			"frame_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"fps": fps,
			"draw_calls": Performance.get_monitor(
				Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"prims": Performance.get_monitor(
				Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
			"mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		})

	var wall := (Time.get_ticks_usec() - t_start) / 1e6
	_report(base, frames, wall)


func _base_map(scene_name: String) -> String:
	for k in KNOWN_BASES:
		if scene_name.findn(k) == 0:
			return k
	return ""


func _plugin_on() -> bool:
	return EditorInterface.is_plugin_enabled("highpoly_toggle")


func _viewport_camera() -> Camera3D:
	# the editor's 3D viewport camera, reached without assuming a dock layout
	var vp := EditorInterface.get_editor_viewport_3d(0)
	return vp.get_camera_3d() if vp != null else null


func _place(cam: Camera3D, s: Dictionary) -> void:
	var pos: Array = s.get("p", [0, 0, 0])
	var b: Array = s.get("b", [])
	var t := cam.global_transform
	t.origin = Vector3(pos[0], pos[1], pos[2])
	if b.size() >= 9:
		t.basis = Basis(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]),
						Vector3(b[6], b[7], b[8]))
	cam.global_transform = t
	if s.has("fov"):
		cam.fov = float(s["fov"])


# The numbers that matter, and the ones that are easy to fool yourself with.
#
# A MEAN fps hides exactly the thing being hunted: a build that runs at 90 and
# stalls to 12 four times averages fine and feels terrible. So the headline is
# the 1% low and the count of frames under the target, not the average.
func _report(base: String, frames: Array, wall: float) -> void:
	var fps: Array = []
	for f in frames:
		fps.append(float(f["fps"]))
	fps.sort()
	var n := fps.size()
	var mean := 0.0
	for v in fps:
		mean += v
	mean /= maxf(float(n), 1.0)
	var under60 := 0
	for v in fps:
		if v < 60.0:
			under60 += 1
	var out := {
		"map": base, "tag": tag, "plugin": _plugin_on(),
		"when": Time.get_datetime_string_from_system(),
		"frames": n, "wall_s": wall,
		"fps_mean": mean,
		"fps_1pct_low": fps[int(n * 0.01)] if n > 100 else fps[0],
		"fps_5pct_low": fps[int(n * 0.05)] if n > 20 else fps[0],
		"fps_min": fps[0], "fps_max": fps[n - 1],
		"frames_under_60": under60,
		"pct_under_60": 100.0 * under60 / maxf(float(n), 1.0),
		"samples": frames,
	}
	var p := "user://bench_flight_%s_%s.json" % [base, tag]
	var fh := FileAccess.open(p, FileAccess.WRITE)
	if fh != null:
		fh.store_string(JSON.stringify(out))
		fh.close()
	print("[flightbench] %d frames in %.1f s" % [n, wall])
	print("[flightbench] fps mean %.1f | 1%% low %.1f | min %.1f | max %.1f"
		% [mean, out["fps_1pct_low"], fps[0], fps[n - 1]])
	print("[flightbench] frames under 60: %d (%.1f%%)  <- the number to drive to zero"
		% [under60, out["pct_under_60"]])
	print("[flightbench] wrote %s" % p)
