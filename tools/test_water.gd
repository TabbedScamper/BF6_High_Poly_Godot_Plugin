@tool
extends SceneTree
# The block-2 river surface (MAP-TUNGSTEN.md §U), against the real install.
#
# terrain_water() must find block 2, slice the second payload past the pages,
# and mesh the wet cells. The agent's measured truth: water level 66.05..76.52,
# wet area ~0.82 km². Wide tolerances - the mesh clip is mode-based while the
# probe's was ground-relative - but teal-grade failures (empty mesh, level at
# 0, area off by 10x) cannot pass.

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Tungsten"):
		print("no source"); quit(1); return
	var t0 := Time.get_ticks_msec()
	gs.terrain("user://hmcache_test")   # ground grid for the wet clip (cached: ~0.1 s)
	var hf: Dictionary = gs.terrain_water("user://hmcache_test")
	var ms := Time.get_ticks_msec() - t0
	var fails := 0
	if hf.is_empty():
		print("FAIL terrain_water returned {} on the one map it was built for")
		quit(1); return
	var y0 := float(hf["y0"])
	var y1 := float(hf["y1"])
	var km2 := float(hf["wet_km2"])
	print("water mesh in %d ms: level %.2f..%.2f m, %.2f km2  [probe: 66.05..76.52, 0.82 km2]"
		% [ms, y0, y1, km2])
	if y0 < 64.0 or y0 > 70.0: print("FAIL y0 out of band"); fails += 1
	if y1 < 72.0 or y1 > 80.0: print("FAIL y1 out of band"); fails += 1
	if km2 < 0.5 or km2 > 1.2: print("FAIL wet area out of band"); fails += 1
	if not (hf["mesh"] is ArrayMesh): print("FAIL no mesh"); fails += 1
	# and the water() wrapper must carry it with the entity's look attached
	var bodies: Array = gs.water("user://hmcache_test")
	var have_mesh := false
	var have_look := false
	for b in bodies:
		if (b as Dictionary).has("mesh"):
			have_mesh = true
			have_look = (b as Dictionary).has("look")
	print("water(): %d bodies, river mesh %s, look %s"
		% [bodies.size(), str(have_mesh), str(have_look)])
	if not have_mesh: print("FAIL water() dropped the river"); fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
