@tool
extends RefCounted
class_name HighpolyFlightPath

# Record the editor camera while you fly, so a benchmark can fly the SAME path
# afterwards.
#
# Every rendering number measured so far came from a static camera, which
# cannot tell you what flying feels like — and "feels smoother" cannot tell you
# whether a change helped. A recorded path makes the two comparable: identical
# route, identical frames, before and after.
#
# Sampled at 20 Hz. The editor camera moves under user input, so this is a
# recording of where you actually went, not a synthetic orbit — the point is to
# capture the places that are slow, which are the places you naturally fly to
# when looking for slowness.
#
#   HighpolyFlightPath.start(plugin_node)   begins sampling
#   HighpolyFlightPath.stop()               writes the json, returns its path
#
# Written to user://bf6_flightpath_<map>.json:
#   { "map": "MP_Dumbo", "hz": 20, "samples": [ {"p":[x,y,z], "b":[9 floats],
#     "fov": f}, ... ] }
#
# Basis is stored as nine floats rather than a quaternion because the replay
# has to reproduce the view EXACTLY; a quaternion round-trip introduces a small
# rotation error, and at 300 m viewing distance a fraction of a degree changes
# what is on screen and therefore what is drawn.

const HZ := 20.0
const MAX_SAMPLES := 20 * 60 * 10        # ten minutes, then it stops on its own

static var recording := false
static var _samples: Array = []
static var _timer: Timer = null
static var _map := ""


static func start(host: Node, map_name := "") -> bool:
	if recording:
		return false
	var cam := _cam()
	if cam == null:
		return false
	_map = map_name if map_name != "" else "unknown"
	_samples.clear()
	if _timer == null or not is_instance_valid(_timer):
		_timer = Timer.new()
		_timer.name = "HighpolyFlightRec"
		host.add_child(_timer)
		_timer.timeout.connect(_sample)
	_timer.wait_time = 1.0 / HZ
	_timer.start()
	recording = true
	return true


static func stop() -> String:
	if not recording:
		return ""
	recording = false
	if _timer != null and is_instance_valid(_timer):
		_timer.stop()
	if _samples.is_empty():
		return ""
	var out := "user://bf6_flightpath_%s.json" % _map
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify({
		"map": _map, "hz": HZ, "samples": _samples,
	}))
	f.close()
	return ProjectSettings.globalize_path(out)


static func sample_count() -> int:
	return _samples.size()


static func _cam() -> Camera3D:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	return vp.get_camera_3d() if vp != null else null


static func _sample() -> void:
	if not recording:
		return
	var cam := _cam()
	if cam == null:
		return
	var t := cam.global_transform
	var b := t.basis
	# Skip a sample identical to the last one: sitting still for a minute
	# otherwise contributes a minute of frames to the average and drowns the
	# parts of the route that actually cost something.
	if not _samples.is_empty():
		var prev: Dictionary = _samples[-1]
		var pp: Array = prev["p"]
		if absf(pp[0] - t.origin.x) < 0.01 and absf(pp[1] - t.origin.y) < 0.01 \
				and absf(pp[2] - t.origin.z) < 0.01:
			var pb: Array = prev["b"]
			if absf(pb[0] - b.x.x) < 0.001 and absf(pb[4] - b.y.y) < 0.001 \
					and absf(pb[8] - b.z.z) < 0.001:
				return
	_samples.append({
		"p": [t.origin.x, t.origin.y, t.origin.z],
		"b": [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z],
		"fov": cam.fov,
	})
	if _samples.size() >= MAX_SAMPLES:
		stop()
