extends SceneTree

# Render the terrain from the install and save a picture.
#
# The heightfield correlates with the packaged r16 at r = 0.9964, which says the
# numbers describe the same ground. It does not say the ground is the right way
# up, the right way round, or the right scale: a transposed grid, a flipped Z,
# or a quadrant swap all preserve correlation almost perfectly when the terrain
# is broadly symmetric, and every one of them renders as a plausible landscape.
#
# So this builds a mesh from the grid and looks at it, next to the packaged r16
# built the same way, so the two can be compared as images rather than as
# statistics.
#
#   godot --path <proj> --script vis_terrain.gd -- <out.png> [level] [ref.r16]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")

const STEP := 8                  # vertex stride through the grid


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var out_png := "terrain.png"
	var level := "mp_dumbo"
	var ref_r16 := ""
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			out_png = s; seen = 1
		elif seen == 1:
			level = s; seen = 2
		else:
			ref_r16 = s

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount"); quit(1); return
	var pick := ""
	for rn in src.res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains(level):
			pick = n
			break
	if pick == "":
		print("FAIL no streaming tree"); quit(1); return

	var t := BF6Terrain.new()
	var res := src.get_res(pick)
	var blk := t.find_block(res, BF6Terrain.BLOCK_HEIGHTS)
	if blk.is_empty() or not t.read_block_header(blk) or not t.walk_nodes(blk):
		print("FAIL parse: %s" % t.error); quit(1); return
	var dir := t.read_chunk_directory(res)
	t.resolve_external(dir, func(form): return src.get_chunk(str(form)))
	var g := t.composite(4097)
	if g.is_empty():
		print("FAIL composite: %s" % t.error); quit(1); return
	print("grid %dx%d, y %.0f..%.0f m" % [g["size"], g["size"],
		(g["min"] as Vector3).y, (g["max"] as Vector3).y])

	var root := Node3D.new()
	get_root().add_child(root)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.20, 0.22, 0.26)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.47, 0.52)
	env.ambient_light_energy = 0.5
	var we := WorldEnvironment.new(); we.environment = env
	root.add_child(we)
	# Low sun: relief is what is being judged, and a high sun flattens it.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25, -40, 0)
	key.light_energy = 2.2
	root.add_child(key)

	var built := _terrain_mesh(g["data"], int(g["size"]), STEP,
		float(g["world_size_y"]), (g["min"] as Vector3).x, (g["max"] as Vector3).x)
	var mi := MeshInstance3D.new(); mi.mesh = built
	# A plain matte surface, and DOUBLE SIDED: if the winding is inverted the
	# terrain would otherwise vanish entirely, which looks identical to no mesh
	# at all and is a different bug.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.62, 0.60, 0.55)
	mat.roughness = 0.95
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	root.add_child(mi)
	var span: float = (g["max"] as Vector3).x - (g["min"] as Vector3).x

	# The packaged grid beside it, built by the same code, so any difference in
	# the picture is a difference in the DATA rather than in how it was drawn.
	if ref_r16 != "" and FileAccess.file_exists(ref_r16):
		var rb := FileAccess.get_file_as_bytes(ref_r16)
		var rn2 := int(round(sqrt(float(rb.size() / 2))))
		var rm := _terrain_mesh(rb, rn2, STEP, float(g["world_size_y"]),
			(g["min"] as Vector3).x, (g["max"] as Vector3).x)
		var rmi := MeshInstance3D.new(); rmi.mesh = rm
		rmi.material_override = mat
		rmi.position = Vector3(span * 1.10, 0, 0)
		root.add_child(rmi)
		print("packaged grid %dx%d placed alongside" % [rn2, rn2])
		span *= 2.2

	var cam := Camera3D.new()
	root.add_child(cam)
	var mid := Vector3(span * 0.30, 60, 0)
	cam.position = mid + Vector3(0, span * 0.42, span * 0.52)
	cam.look_at(Vector3(span * 0.30, 40, 0), Vector3.UP)
	# NEAR MATTERS AS MUCH AS FAR. far = 40000 with the default near of 0.05 is a
	# depth ratio of 800,000:1, and the buffer cannot resolve it — the first
	# render came back as bare background with a scatter of speckles, which
	# reads as "the mesh is broken" rather than "the depth range is absurd".
	cam.near = 10.0
	cam.far = 40000.0
	cam.current = true

	for i in range(12):
		await process_frame
	var img := get_root().get_texture().get_image()
	var err := img.save_png(out_png)
	print("%s %s" % ["wrote" if err == OK else "FAILED", out_png])
	quit(0 if err == OK else 1)


# A plain grid mesh: world_y = raw * scale / 65535, which is the encoding the
# map context's own builder uses and the one the game's heights are already in.
func _terrain_mesh(raw: PackedByteArray, res: int, step: int, scale: float,
		wmin: float, wmax: float) -> ArrayMesh:
	var n := int((res - 1) / step) + 1
	var span := wmax - wmin
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(n * n)
	norms.resize(n * n)
	for z in range(n):
		for x in range(n):
			var px: int = mini(x * step, res - 1)
			var pz: int = mini(z * step, res - 1)
			var h := float(raw.decode_u16((pz * res + px) * 2)) * scale / 65535.0
			verts[z * n + x] = Vector3(wmin + float(px) / float(res - 1) * span,
				h, wmin + float(pz) / float(res - 1) * span)
			norms[z * n + x] = Vector3.UP
	# Normals from the height field itself, so relief actually shades — a flat
	# UP normal renders a landscape as a uniform slab and hides every error.
	var cell := span / float(res - 1) * float(step)
	for z in range(n):
		for x in range(n):
			var hl: float = verts[z * n + maxi(0, x - 1)].y
			var hr: float = verts[z * n + mini(n - 1, x + 1)].y
			var hd: float = verts[maxi(0, z - 1) * n + x].y
			var hu: float = verts[mini(n - 1, z + 1) * n + x].y
			norms[z * n + x] = Vector3(hl - hr, 2.0 * cell, hd - hu).normalized()
	var idx := PackedInt32Array()
	for z in range(n - 1):
		for x in range(n - 1):
			var a := z * n + x
			idx.append_array([a, a + n, a + 1, a + 1, a + n, a + n + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am
