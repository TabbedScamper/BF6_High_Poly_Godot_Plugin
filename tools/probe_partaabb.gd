@tool
extends SceneTree
# WHERE A PART MESH'S OWN GEOMETRY SITS.
#
# The placement rows for a cargo van are clean - every part carries the body's
# rotation, orthonormal and det +1, at its own sensible origin. So "the doors
# are off their hinges" is not a walk error, and there is exactly one other
# place it can be: whether the part's MESH is authored around its own pivot or
# around the VEHICLE's origin.
#
#   part-local     the mesh sits around (0,0,0) and the placement origin puts
#                  it on the van. Correct as built.
#   vehicle-local  the mesh already contains the offset from the van's origin
#                  to the hinge, so placing it at the hinge applies that offset
#                  TWICE and the door lands about double the distance out.
#
# The AABB centre says which, and the number to compare it against is the
# placement's own offset from the body.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var want := str(args[1]).to_lower() if args.size() > 1 else "com_vancargo_01"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: ", gs.error); quit(1); return
	gs.map_data(gs.cache_dir if "cache_dir" in gs else "", {})

	# the body, to measure the parts against
	var body := Vector3.ZERO
	var seen := {}
	for r in gs.walk.rows:
		var row: Dictionary = r
		var mesh := str(row.get("mesh", "")).get_file().to_lower()
		if mesh.findn(want) < 0:
			continue
		var xf = row.get("xf")
		if not (xf is Array) or (xf as Array).size() < 4:
			continue
		var base := mesh.trim_suffix(".ebx")
		if seen.has(base):
			continue
		seen[base] = [(xf as Array)[3], str(row.get("scope", "")),
			str(row.get("mesh", ""))]
		if base == want:
			body = (xf as Array)[3]

	print("body origin (%.3f, %.3f, %.3f)\n" % [body.x, body.y, body.z])
	print("%-42s %-24s %-24s %s" % ["part", "placed at (rel. body)",
		"mesh AABB centre", "verdict"])
	var keys: Array = seen.keys()
	keys.sort()
	for k in keys:
		var e: Array = seen[k]
		var o: Vector3 = e[0]
		var rel := o - body
		var gkey := "%s|%s|0" % [gs.resolve_mesh(str(e[2])), str(e[1])]
		var m: Mesh = gs.mesh_for(gkey)
		if m == null:
			print("%-42s (%6.2f,%6.2f,%6.2f)   (no mesh built)" % [k, rel.x, rel.y, rel.z])
			continue
		var ab := m.get_aabb()
		var c := ab.get_center()
		# vehicle-local would put the mesh centre near the SAME offset the
		# placement already applies; part-local puts it near zero
		var v := "part-local (correct)"
		if c.length() > 0.35 and rel.length() > 0.35 \
				and c.distance_to(rel) < rel.length() * 0.6:
			v = "VEHICLE-LOCAL -> double offset"
		elif c.length() > 1.0:
			v = "offset mesh (%.2f m from its own origin)" % c.length()
		print("%-42s (%6.2f,%6.2f,%6.2f)   (%6.2f,%6.2f,%6.2f)   %s" % [
			k, rel.x, rel.y, rel.z, c.x, c.y, c.z, v])
		print("%-42s size (%.2f, %.2f, %.2f)" % ["", ab.size.x, ab.size.y, ab.size.z])
	quit(0)
