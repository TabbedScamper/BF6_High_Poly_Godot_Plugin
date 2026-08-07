extends SceneTree

# Does merging equal surfaces preserve the geometry EXACTLY?
#
# The merge is invisible only if it changes nothing but the surface count. A
# rebased index array is easy to get subtly wrong — an off-by-one in the vertex
# base produces a mesh that still loads, still has the right triangle count, and
# renders as noise. So this checks the things that would catch that:
#
#   triangle count   identical, per mesh
#   vertex count     identical, per mesh
#   bounding box     identical to 1e-4
#   vertex sum       identical, which no index error can survive
#
#   godot --headless --path <proj> --script test_surfmerge.gd -- <glb dir> [n]

const MapCtx := preload("res://highpoly_mapcontext_merge.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var dir := str(a[0]) if a.size() > 0 else ""
	var want := int(str(a[1])) if a.size() > 1 else 40

	var files := _glbs(dir)
	if files.is_empty():
		print("no .glb under %s" % dir); quit(1); return
	var step: int = maxi(1, files.size() / want)
	var picked: Array = []
	for i in range(0, files.size(), step):
		picked.append(files[i])
		if picked.size() >= want:
			break

	var before := 0
	var after := 0
	var bad := 0
	var checked := 0
	for f in picked:
		var m := _load(str(f))
		if m == null or m.get_surface_count() == 0:
			continue
		var a0 := _stats(m)
		var merged: Mesh = MapCtx._merge_equal_surfaces(m)
		var a1 := _stats(merged)
		before += int(a0["surfaces"])
		after += int(a1["surfaces"])
		checked += 1
		var why := ""
		if int(a0["tris"]) != int(a1["tris"]):
			why = "triangles %d -> %d" % [a0["tris"], a1["tris"]]
		elif int(a0["verts"]) != int(a1["verts"]):
			why = "vertices %d -> %d" % [a0["verts"], a1["verts"]]
		elif absf(float(a0["vsum"]) - float(a1["vsum"])) > 0.5:
			why = "vertex sum %.2f -> %.2f" % [a0["vsum"], a1["vsum"]]
		elif (a0["aabb"] as AABB).position.distance_to(
				(a1["aabb"] as AABB).position) > 1e-3 \
				or (a0["aabb"] as AABB).size.distance_to(
				(a1["aabb"] as AABB).size) > 1e-3:
			why = "bounds %s -> %s" % [a0["aabb"], a1["aabb"]]
		if why != "":
			bad += 1
			if bad <= 8:
				print("  MISMATCH %-44s %s" % [str(f).get_file().left(44), why])

	print("\nchecked %d mesh(es)" % checked)
	print("surfaces %d -> %d  (%.1f%% kept)"
			% [before, after, 100.0 * float(after) / maxf(1.0, float(before))])
	print("geometry mismatches: %d" % bad)
	quit(1 if bad > 0 else 0)


func _stats(m: Mesh) -> Dictionary:
	var tris := 0
	var verts := 0
	var vsum := 0.0
	var aabb := AABB()
	var first := true
	for s in range(m.get_surface_count()):
		var arr: Array = m.surface_get_arrays(s)
		var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var I = arr[Mesh.ARRAY_INDEX]
		verts += V.size()
		tris += (I as PackedInt32Array).size() / 3 if I != null else V.size() / 3
		for v in V:
			vsum += v.x + v.y + v.z
			if first:
				aabb = AABB(v, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(v)
	return {"surfaces": m.get_surface_count(), "tris": tris, "verts": verts,
			"vsum": snappedf(vsum, 0.01), "aabb": aabb}


func _load(path: String) -> Mesh:
	var b := FileAccess.get_file_as_bytes(path)
	if b.is_empty():
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(b, path.get_base_dir(), st) != OK:
		return null
	var out := ArrayMesh.new()
	for gm in st.get_meshes():
		var src: ImporterMesh = gm.get_mesh()
		if src == null:
			continue
		for s in range(src.get_surface_count()):
			var arr: Array = src.get_surface_arrays(s)
			if arr.size() <= Mesh.ARRAY_INDEX or arr[Mesh.ARRAY_INDEX] == null:
				continue
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			out.surface_set_material(out.get_surface_count() - 1,
					src.get_surface_material(s))
	return out if out.get_surface_count() > 0 else null


func _glbs(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir():
			if not f.begins_with("."):
				out.append_array(_glbs(dir.path_join(f)))
		elif f.ends_with(".glb"):
			out.append(dir.path_join(f))
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out
