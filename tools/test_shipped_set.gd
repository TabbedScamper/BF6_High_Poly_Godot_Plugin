extends SceneTree

# test_geom_tier bakes its own files and then loads them, which proves the
# LOADER works and says nothing about the pipeline. This one is pointed at a set
# bc_pipeline.py actually produced, and compares it against the original props it
# was made from — the two directories are the two ends of the whole thing.
#
# What would go wrong quietly:
#   a prop whose geometry differs from the original users have been seeing
#   a prop that comes back untextured because the sidecar and the bake disagree
#     about material names
#   an intermediate file still in the set, doubling the download for nothing
#
# Run with "-- <original props dir> <shipped props_bc dir> [count]".

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.size() < 2:
		print("need both directories"); quit(1); return
	var orig: String = str(a[0])
	var ship: String = str(a[1])
	var n := int(str(a[2])) if a.size() > 2 else 40

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.vram_mode = MC.VRAM_COMPRESSED
	mc.mesh_cache_enabled = false

	# Only props present in BOTH, so a partial sample cannot pass by comparing
	# nothing against nothing.
	var names: Array = []
	for f in _glbs(ship):
		if FileAccess.file_exists(orig + "/" + str(f)):
			names.append(str(f))
	names.sort()
	names = names.slice(0, n)
	if names.is_empty():
		print("no props common to both directories"); quit(1); return
	print("%d prop(s) in both\n" % names.size())

	var has_geom := 0
	var has_side := 0
	var same_tris := 0
	var textured := 0
	var tri_o := 0
	var tri_s := 0

	for nm in names:
		var op := orig + "/" + str(nm)
		var sp := ship + "/" + str(nm)
		if FileAccess.file_exists(sp + ".geom.res") \
				or FileAccess.file_exists(sp + ".geom.p0.res"):
			has_geom += 1
		if FileAccess.file_exists(sp.get_basename() + ".bctex"):
			has_side += 1

		mc._mesh_cache.clear()
		var o = await mc._parse_prop_file(op)
		mc._mesh_cache.clear()
		var s = await mc._parse_prop_file(sp)
		var a1 := _stats(o)
		var a2 := _stats(s)
		tri_o += int(a1["tris"])
		tri_s += int(a2["tris"])
		if int(a1["tris"]) == int(a2["tris"]) and int(a1["tris"]) > 0:
			same_tris += 1
		if int(a2["tex"]) > 0:
			textured += 1

	var t := names.size()
	_check("every shipped prop has a geometry bake (%d of %d)" % [has_geom, t],
		has_geom == t)
	_check("every shipped prop has a texture sidecar (%d of %d)" % [has_side, t],
		has_side == t)
	_check("the shipped prop is the same geometry as the original (%d of %d, %d vs %d tris)"
		% [same_tris, t, tri_o, tri_s], same_tris == t)
	_check("and it comes back textured (%d of %d)" % [textured, t],
		textured == t)

	# bc_encode's inputs must not ship: they are the same pixels a second time.
	var junk := 0
	var da := DirAccess.open(ship)
	if da != null:
		for f in da.get_files():
			if str(f).ends_with(".map.json") or str(f).contains(".tex"):
				junk += 1
	_check("no intermediate files left in the shipped set (%d)" % junk, junk == 0)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _stats(meshes) -> Dictionary:
	var out := {"tris": 0, "tex": 0}
	if not (meshes is Array):
		return out
	for m in meshes:
		var am := m as ArrayMesh
		if am == null:
			continue
		for s in range(am.get_surface_count()):
			var arr := am.surface_get_arrays(s)
			if not arr.is_empty() and arr[Mesh.ARRAY_INDEX] != null:
				out["tris"] = int(out["tris"]) \
					+ (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
			var bm := am.surface_get_material(s) as BaseMaterial3D
			if bm != null and bm.albedo_texture != null:
				out["tex"] = int(out["tex"]) + 1
	return out


func _glbs(dir: String) -> Array:
	var da := DirAccess.open(dir)
	if da == null: return []
	var out: Array = []
	for f in da.get_files():
		if str(f).ends_with(".glb"): out.append(str(f))
	return out


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok: fails += 1
