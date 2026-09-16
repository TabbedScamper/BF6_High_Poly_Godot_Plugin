@tool
extends Object
class_name HighpolyLightingZones

# Consumer-side geometry for installed-game local VisualEnvironment zones.
# Kept independent of the scene builder so oriented-box and polygon controls can
# run headlessly without loading the full editor plugin.


# Winding-independent XZ polygon test. Shapes ship in both directions, so the
# Portal combat-volume clockwise rule does not apply here.
static func point_in_polygon(p: Vector3, points: Array) -> bool:
	var inside := false
	var j := points.size() - 1
	for i in range(points.size()):
		var a: Vector3 = points[i]
		var b: Vector3 = points[j]
		if (a.z > p.z) != (b.z > p.z):
			var cross_x := (b.x - a.x) * (p.z - a.z) / (b.z - a.z) + a.x
			if p.x < cross_x:
				inside = not inside
		j = i
	return inside


# Exact authored-shape membership. Polygon shapes that are non-planar or have
# zero height stay inactive: the corpus explicitly records their semantics as
# unresolved, so treating them as infinite/flat volumes would be a guess.
static func contains(z: Dictionary, world_point: Vector3) -> bool:
	var xf: Transform3D = z["transform"]
	var p := xf.affine_inverse() * world_point
	if int(z["kind"]) == 0:
		var h: Vector3 = z["half_extents"]
		return absf(p.x) <= h.x and absf(p.y) <= h.y and absf(p.z) <= h.z
	if not bool(z.get("planar", false)):
		return false
	var height := float(z.get("height", 0.0))
	if is_zero_approx(height):
		return false
	var y0 := float(z.get("base_y", 0.0))
	var y1 := y0 + height
	if p.y < minf(y0, y1) or p.y > maxf(y0, y1):
		return false
	return point_in_polygon(p, z["points"])
