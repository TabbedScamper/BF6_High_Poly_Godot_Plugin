extends SceneTree

# Pure consumer-side controls for the exact native zone schema. No game files
# are needed here: the live reader's real-vs-rotated join is tested separately;
# this catches a consumer that turns a correct OBB back into an AABB or assumes
# one polygon winding.

const LightingZones = preload("res://addons/highpoly_toggle/highpoly_lighting_zones.gd")


func _init() -> void:
	var xf := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(10.0, 2.0, -5.0))
	var obb := {
		"kind": 0,
		"transform": xf,
		"half_extents": Vector3(2.0, 1.0, 4.0),
	}
	var inside := xf * Vector3(0.0, 0.0, 3.0)
	var outside := xf * Vector3(2.1, 0.0, 0.0)
	var wrong_pair := obb.duplicate()
	wrong_pair["transform"] = Transform3D(Basis.IDENTITY, xf.origin)

	var ccw: Array[Vector3] = [
		Vector3(-2.0, -1.0, -3.0), Vector3(2.0, -1.0, -3.0),
		Vector3(2.0, -1.0, 3.0), Vector3(-2.0, -1.0, 3.0)]
	var poly := {
		"kind": 1,
		"transform": xf,
		"points": ccw,
		"height": 3.0,
		"base_y": -1.0,
		"planar": true,
	}
	var poly_cw := poly.duplicate()
	var cw := ccw.duplicate()
	cw.reverse()
	poly_cw["points"] = cw
	var poly_inside := xf * Vector3(0.0, 0.0, 0.0)
	var poly_above := xf * Vector3(0.0, 2.1, 0.0)
	var zero_height := poly.duplicate()
	zero_height["height"] = 0.0
	var nonplanar := poly.duplicate()
	nonplanar["planar"] = false

	var checks := {
		"obb_inside": LightingZones.contains(obb, inside),
		"obb_outside": not LightingZones.contains(obb, outside),
		"rotated_control": not LightingZones.contains(wrong_pair, inside),
		"polygon_ccw": LightingZones.contains(poly, poly_inside),
		"polygon_cw": LightingZones.contains(poly_cw, poly_inside),
		"polygon_vertical": not LightingZones.contains(poly, poly_above),
		"zero_height_rejected": not LightingZones.contains(zero_height, poly_inside),
		"nonplanar_rejected": not LightingZones.contains(nonplanar, poly_inside),
	}
	var failed: Array[String] = []
	for key in checks:
		if not bool(checks[key]):
			failed.append(str(key))
	print("REAL shape controls: %d/%d" % [checks.size() - failed.size(), checks.size()])
	print("CONTROL rotated OBB pairing: %s" %
		("rejected" if bool(checks["rotated_control"]) else "FAILED"))
	if not failed.is_empty():
		print("FAIL: %s" % ", ".join(failed))
		quit(1)
		return
	print("PASS")
	quit(0)
