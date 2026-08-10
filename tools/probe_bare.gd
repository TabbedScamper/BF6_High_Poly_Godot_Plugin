@tool
extends SceneTree
# HOW MANY SURFACES END UP WITH NO MATERIAL AT ALL, across the map.
#
# _dress only calls surface_set_material when the lookup returned something, so
# a key no depot holds leaves the surface bare - it draws in Godot's default
# white/grey. One of those is com_billboard_sign's face. This counts them, and
# counts which fallback tier rescued the rest, so the level-wide sweep can be
# judged on what it actually buys rather than on the one prop that prompted it.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var limit := int(args[1]) if args.size() > 1 else 600

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: ", gs.error); quit(1); return
	var md: Dictionary = gs.map_data("", {})
	var props: Array = md.get("props", [])
	print("%d prop group(s); building the first %d\n" % [props.size(), limit])

	var t := Time.get_ticks_msec()
	var bare := {}
	var surfaces := 0
	var built := 0
	for i in range(mini(props.size(), limit)):
		var gkey := str((props[i] as Dictionary)["mesh"])
		var m: Mesh = gs.mesh_for(gkey)
		if m == null:
			continue
		built += 1
		for s in range(m.get_surface_count()):
			surfaces += 1
			if m.surface_get_material(s) == null:
				var nm := gkey.get_slice("|", 0).get_file()
				bare[nm] = int(bare.get(nm, 0)) + 1
	print("built %d mesh(es), %d surface(s) in %.1f s"
		% [built, surfaces, (Time.get_ticks_msec() - t) / 1000.0])

	var n := 0
	for k in bare:
		n += int(bare[k])
	print("%d surface(s) with NO material, across %d mesh(es)  (%.2f%%)"
		% [n, bare.size(), 100.0 * float(n) / maxf(float(surfaces), 1.0)])

	var st: Dictionary = gs.tex_stats
	print("")
	print("which tier resolved a key its own scope did not hold:")
	for k in ["scope_shipping", "scope_sibling", "scope_level"]:
		print("   %-16s %d" % [k, int(st.get(k, 0))])

	if not bare.is_empty():
		print("")
		print("bare surfaces by mesh, worst first:")
		var keys: Array = bare.keys()
		keys.sort_custom(func(a, b): return int(bare[a]) > int(bare[b]))
		for k in keys.slice(0, 20):
			print("   %4d  %s" % [int(bare[k]), str(k)])
	quit(0)
