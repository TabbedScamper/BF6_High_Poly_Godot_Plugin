@tool
extends SceneTree
# Placements matching a name, with their FULL transform.
#
# "The doors are off their hinges" is a claim about rotation and position, so
# print those rather than a distance. A vehicle in this data is a body mesh plus
# separate door/hood/trunk meshes, each with its own placement - if the parts
# arrive at the body's origin, or with the body's rotation instead of their own,
# that is exactly what a door off its hinge looks like.
#
#   ... probe_parts.gd -- MP_Aftermath com_vancargo_01 -583.84 57.32 -79.28 30

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var want := str(args[1]).to_lower() if args.size() > 1 else ""
	var at := Vector3.ZERO
	var radius := INF
	if args.size() >= 6:
		at = Vector3(float(args[2]), float(args[3]), float(args[4]))
		radius = float(args[5])

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: ", gs.error); quit(1); return

	var hits: Array = []
	for r in gs.walk.rows:
		var row: Dictionary = r
		var mesh := str(row.get("mesh", "")).get_file().to_lower()
		if want != "" and mesh.findn(want) < 0:
			continue
		var xf = row.get("xf")
		if not (xf is Array) or (xf as Array).size() < 4:
			continue
		var o: Vector3 = (xf as Array)[3]
		if radius < INF and o.distance_to(at) > radius:
			continue
		hits.append(row)
	print("%d placement(s) of *%s*\n" % [hits.size(), want])
	for row in hits:
		var xf: Array = row["xf"]
		var r0: Vector3 = xf[0]
		var u: Vector3 = xf[1]
		var f: Vector3 = xf[2]
		var o: Vector3 = xf[3]
		print("%-46s  scope %s" % [str(row.get("mesh", "")).get_file(),
			str(row.get("scope", "")).get_file()])
		print("    origin (%9.3f, %9.3f, %9.3f)   |r|=%.3f |u|=%.3f |f|=%.3f  det=%.3f"
			% [o.x, o.y, o.z, r0.length(), u.length(), f.length(),
			   r0.cross(u).dot(f)])
		print("    right  (%9.3f, %9.3f, %9.3f)" % [r0.x, r0.y, r0.z])
		print("    up     (%9.3f, %9.3f, %9.3f)" % [u.x, u.y, u.z])
		print("    fwd    (%9.3f, %9.3f, %9.3f)" % [f.x, f.y, f.z])
		print("    src    %s   kind %s" % [str(row.get("src", "")).get_file(),
			str(row.get("kind", ""))])
	quit(0)
