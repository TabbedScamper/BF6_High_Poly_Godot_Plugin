extends SceneTree

# Does the geometry cache hand back the same map it was given?
#
# The cache saves a merged, material-less ArrayMesh per (MeshSet, LOD) and
# recovers the merge keys from the surface NAMES, so a round trip has three ways
# to go quietly wrong: a surface could come back with different geometry, the
# surface order could change, or a name could fail to survive ResourceSaver and
# take the material assignment with it. All three produce a map that renders —
# just not the right one.
#
# Two passes over the same map in one process is not the test, because the
# in-memory share table would answer most of it. So this runs the cold pass,
# forgets everything in memory, and runs the warm pass against a fresh reader.
#
#   godot --headless --path <proj> --script test_geomcache.gd -- [level] [limit]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var limit := 400
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			limit = int(s)

	# A directory of its own, wiped first, so a previous run cannot make a broken
	# save look like a working load.
	var cold := _run(level, limit, true)
	if cold.is_empty():
		quit(1); return
	var warm := _run(level, limit, false)
	if warm.is_empty():
		quit(1); return

	print("\n            %12s %12s" % ["cold", "warm"])
	for k in ["groups", "surfaces", "vertices", "indices", "parsed", "shared",
			"loaded", "saved"]:
		print("   %-9s %12s %12s" % [k, cold[k], warm[k]])
	print("   %-9s %11.1fs %11.1fs" % ["parse", cold["parse_s"], warm["parse_s"]])
	print("   %-9s %11.1fs %11.1fs" % ["cache i/o", cold["io_s"], warm["io_s"]])
	print("   %-9s %11.1fs %11.1fs" % ["total", cold["total_s"], warm["total_s"]])

	var fail := 0
	for k in ["groups", "surfaces", "vertices", "indices"]:
		if int(cold[k]) != int(warm[k]):
			print("\nFAIL: %s differs — cold %d, warm %d" % [k, cold[k], warm[k]])
			fail += 1
	if int(warm["loaded"]) == 0:
		print("\nFAIL: the warm pass loaded nothing from the cache")
		fail += 1
	if int(warm["parsed"]) > int(cold["parsed"]) * 0.2:
		print("\nFAIL: the warm pass still parsed %d of the cold pass's %d"
			% [warm["parsed"], cold["parsed"]])
		fail += 1
	# The materials have to survive too: a surface whose name did not round trip
	# resolves to the wrong merge key and takes someone else's textures.
	if int(warm["dressed"]) != int(cold["dressed"]):
		print("\nFAIL: surfaces with a material differ — cold %d, warm %d"
			% [cold["dressed"], warm["dressed"]])
		fail += 1

	if fail == 0:
		var sp: float = cold["total_s"] / maxf(0.001, float(warm["total_s"]))
		print("\nPASS — warm is %.1fx the cold build" % sp)
	quit(0 if fail == 0 else 1)


func _run(level: String, limit: int, wipe: bool) -> Dictionary:
	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		return {}
	if wipe:
		_wipe(gs._geom_dir)
	var data: Dictionary = gs.map_data("")
	var groups: Array = data["props"]
	if limit > 0 and groups.size() > limit:
		groups = groups.slice(0, limit)
	var t0 := Time.get_ticks_msec()
	var surfaces := 0
	var verts := 0
	var idxs := 0
	var dressed := 0
	var built := 0
	for g in groups:
		var m: Mesh = gs.mesh_for(str((g as Dictionary)["mesh"]))
		if m == null:
			continue
		built += 1
		surfaces += m.get_surface_count()
		for i in range(m.get_surface_count()):
			var arr := m.surface_get_arrays(i)
			verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			idxs += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
			if m.surface_get_material(i) != null:
				dressed += 1
	return {
		"groups": built, "surfaces": surfaces, "vertices": verts,
		"indices": idxs, "dressed": dressed,
		"parsed": int(gs.n_meshes), "shared": int(gs.n_mesh_shared),
		"loaded": int(gs.n_geom_loaded), "saved": int(gs.n_geom_saved),
		"parse_s": gs.t_parse / 1e6,
		"io_s": (gs.t_geom_load + gs.t_geom_save) / 1e6,
		"total_s": (Time.get_ticks_msec() - t0) / 1000.0,
	}


func _wipe(d: String) -> void:
	if d == "":
		return
	var dir := DirAccess.open(d)
	if dir == null:
		return
	var n := 0
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir():
			dir.remove(f)
			n += 1
		f = dir.get_next()
	dir.list_dir_end()
	print("wiped %d cached mesh file(s) from %s" % [n, d])
