extends SceneTree

# WHAT WOULD A CARRIER LAYOUT OBJECT ACTUALLY CONTAIN?
#
#   python tools/run_addon_script.py native/probe_carrier_layouts.gd --args <steam> [level]
#
# The plan is to generate Carrier_Layout_Portal.tscn, Carrier_Layout_Conquest.tscn
# and so on from the user's own install, with the map's own orange material. That
# is only worth designing once the size is known: how many distinct meshes each
# layout needs, how many instances, and how many triangles. A layout that is four
# hundred thousand triangles is a different object from one that is four million.
#
# It also confirms the LAYER KEYS the builder will group by, which the core's
# scope mapper produces and which no amount of reading the mapper will pin down
# as reliably as printing them.

const HighpolyGameSource := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: probe_carrier_layouts.gd -- <steam root> [level]"); quit(2); return
	var level := str(a[1]) if a.size() > 1 else "mp_isolated"

	var gs = HighpolyGameSource.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(level, str(a[0]), func(_s, _d, _t): pass):
		print("FAIL open_map: %s" % gs.error); quit(1); return
	var data: Dictionary = gs.map_data()
	var props: Array = data.get("props", [])
	print("%s opened in %.1f s, %d prop group(s)\n"
		% [level, (Time.get_ticks_msec() - t0) / 1000.0, props.size()])

	# Group the CARRIER meshes by the layer the walk assigned them. The name
	# test is deliberately broad - carrier hull, bridge, tower, elevator, doors
	# and the granite-borrowed fire/audio prefabs all matter to a layout.
	var by_layer := {}
	for p in props:
		var rec: Dictionary = p
		var mesh_name := str(rec.get("mesh", ""))
		if not mesh_name.to_lower().contains("carrier"):
			continue
		var layer := str(rec.get("layer", ""))
		if not by_layer.has(layer):
			by_layer[layer] = {"meshes": {}, "instances": 0}
		var xf: Array = rec.get("xf", [])
		var n := int(xf.size() / 12)
		(by_layer[layer] as Dictionary)["instances"] = \
			int((by_layer[layer] as Dictionary)["instances"]) + n
		((by_layer[layer] as Dictionary)["meshes"] as Dictionary)[mesh_name] = n

	if by_layer.is_empty():
		print("no carrier meshes on %s" % level); quit(0); return

	var keys := by_layer.keys()
	keys.sort()
	print("%-46s %9s %9s %12s" % ["layer key (as the walk reports it)", "meshes", "instances", "triangles"])
	for k in keys:
		var rec: Dictionary = by_layer[k]
		var meshes: Dictionary = rec["meshes"]
		# Triangles are the number that decides whether this is shippable as one
		# scene, so they are counted from the REAL mesh rather than estimated.
		var tris := 0
		var built := 0
		for m in meshes.keys():
			var mesh: Mesh = gs.mesh_for(str(m))
			if mesh == null: continue
			built += 1
			var per := 0
			for si in range(mesh.get_surface_count()):
				per += mesh.surface_get_array_index_len(si) / 3
			tris += per * int(meshes[m])
		print("%-46s %9d %9d %12s   (%d of %d meshes resolved)"
			% [k if k != "" else "<always visible>", meshes.size(),
			   int(rec["instances"]), _commas(tris), built, meshes.size()])
	quit(0)


func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0: out = "," + out
	return out
