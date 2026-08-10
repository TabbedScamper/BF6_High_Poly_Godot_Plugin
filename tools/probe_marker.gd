@tool
extends SceneTree
# WHAT IS ACTUALLY AT A MARKER, from the install.
#
# The marker report in the log answers this from placements.json, and when that
# file is absent it can only say "UNKNOWN, nothing to compare against" - which
# is what four real markers came back with. The walk has the same rows in
# memory, so ask it directly: every placement within a radius of a point, with
# its mesh, the subworld that placed it and the variant layer that gates it.
#
#   godot --headless --path C:/PortalSDK/GodotProject \
#     --script User_Created/tools/bf6-portal-highpoly-preview/tools/probe_marker.gd \
#     -- MP_Aftermath 12 -583.84 57.32 -79.28  -631.26 58.94 -31.00

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var radius := float(args[1]) if args.size() > 1 else 14.0
	var pts: Array = []
	var i := 2
	while i + 2 < args.size():
		pts.append(Vector3(float(args[i]), float(args[i + 1]), float(args[i + 2])))
		i += 3
	if pts.is_empty():
		print("no points given"); quit(1); return

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: ", gs.error); quit(1); return
	print("%d rows on %s\n" % [gs.walk.rows.size(), map])

	for p in pts:
		print("=".repeat(78))
		print("within %.0f m of (%.2f, %.2f, %.2f)" % [radius, p.x, p.y, p.z])
		var hits: Array = []
		for r in gs.walk.rows:
			var row: Dictionary = r
			var xf = row.get("xf")
			if not (xf is Array) or (xf as Array).size() < 4:
				continue
			var o: Vector3 = (xf as Array)[3]
			var d := o.distance_to(p)
			if d <= radius:
				hits.append([d, row])
		hits.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		print("%d placement(s)" % hits.size())
		print("%7s  %-46s %-26s %s" % ["dist", "mesh", "layer (gates it)", "scope"])
		var shown := 0
		for h in hits:
			var row: Dictionary = h[1]
			var mesh := str(row.get("mesh", "")).get_file()
			var scope := str(row.get("scope", ""))
			var layer: String = gs.layer_of_scope(scope)
			print("%7.2f  %-46s %-26s %s" % [float(h[0]), mesh.left(46),
				layer if layer != "" else "(always shown)", scope.get_file()])
			shown += 1
			if shown >= 30:
				print("        ... and %d more" % (hits.size() - shown))
				break
		print("")
	quit(0)
