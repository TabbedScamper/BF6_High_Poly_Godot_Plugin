extends SceneTree

# The road network on the ground, as a picture.
#
# The numbers already say the decal container parses byte-exactly and that the
# draped mesh has a 34 m vertical span on a 256 m map, i.e. it follows the
# terrain rather than floating. None of that can tell you whether the UVs are
# right — a stamp decal drawn with tiled UVs, or a fill drawn with stamp UVs,
# produces a smear that is geometrically perfect and looks like wet paint. Nor
# can it tell you the markings are being masked: without the coverage texture
# every crosswalk paints as a solid white slab, which is exactly the failure
# this layer exists to avoid.
#
# Two views: straight down, where the street layout is legible and a smear is
# obvious, and low and oblique, where the drape and the depth bias show.
#
#   godot --path <proj> --script vis_roads.gd -- <out.png> [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")

const STEP := 8


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var out_png := "roads.png"
	var level := "mp_dumbo"
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			out_png = s; seen = 1
		else:
			level = s

	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error); quit(1); return
	var hm: Dictionary = gs.terrain("user://vis_roads")
	if hm.is_empty():
		print("FAIL no terrain"); quit(1); return
	var roads: Mesh = gs.roads()
	if roads == null:
		print("FAIL no roads"); quit(1); return
	var water: Array = gs.water()

	var root := Node3D.new()
	get_root().add_child(root)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.18, 0.22)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.64, 0.70)
	# Bright, deliberately. Road surfaces are dark asphalt and the markings are
	# the thing being checked; lit realistically the whole panel reads as black
	# and the picture answers nothing.
	env.ambient_light_energy = 3.0
	var we := WorldEnvironment.new(); we.environment = env
	root.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -35, 0)
	key.light_energy = 1.6
	root.add_child(key)

	var g: Dictionary = gs._hm
	var wmin: float = float(g["min"])
	var wmax: float = float(g["max"])
	var span := wmax - wmin
	var ground := MeshInstance3D.new()
	ground.mesh = _terrain_mesh(g["data"], int(g["res"]), STEP,
		float(g["scale"]), wmin, wmax)
	var gmat := StandardMaterial3D.new()
	# A dull green-brown so the grey road surface reads against it; the point of
	# the picture is the contrast between the two, not either one's colour.
	gmat.albedo_color = Color(0.30, 0.31, 0.24)
	gmat.roughness = 0.98
	gmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground.material_override = gmat
	root.add_child(ground)

	var rmi := MeshInstance3D.new()
	rmi.mesh = roads
	root.add_child(rmi)

	for w in water:
		var wd: Dictionary = w
		var pm := PlaneMesh.new()
		var sz: Array = wd["size"]
		pm.size = Vector2(float(sz[0]), float(sz[1]))
		var wmi := MeshInstance3D.new()
		wmi.mesh = pm
		var c: Array = wd["center"]
		wmi.position = Vector3(float(c[0]), float(wd["height"]), float(c[1]))
		var wmat := StandardMaterial3D.new()
		wmat.albedo_color = Color(0.10, 0.22, 0.32, 0.75)
		wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wmi.material_override = wmat
		root.add_child(wmi)

	var aabb := roads.get_aabb()
	var mid := aabb.position + aabb.size * 0.5
	var reach: float = maxf(aabb.size.x, aabb.size.z)
	# WHERE THE ROADS ACTUALLY ARE, not where their bounding box is. Dumbo's
	# decals include a pier running 2.4 km down one edge, so the AABB centre sits
	# in open water and a shot framed on it shows nothing but terrain. The
	# triangle-weighted centroid of the surfaces lands on the street grid.
	var acc := Vector3.ZERO
	var wsum := 0.0
	for i in range(roads.get_surface_count()):
		var sa := roads.surface_get_arrays(i)
		var v: PackedVector3Array = sa[Mesh.ARRAY_VERTEX]
		if v.is_empty():
			continue
		var c := Vector3.ZERO
		for k in range(0, v.size(), maxi(1, v.size() / 64)):
			c += v[k]
		c /= float(maxi(1, int(ceil(v.size() / float(maxi(1, v.size() / 64))))))
		acc += c * float(v.size())
		wsum += float(v.size())
	var focus := acc / maxf(wsum, 1.0) if wsum > 0.0 else mid
	var shots: Array = [
		["top", mid + Vector3(0, reach * 0.95, 0.01), mid],
		["closeup", focus + Vector3(0, 420, 0.01), focus],
		["oblique", focus + Vector3(120, 90, 260), focus + Vector3(0, 5, 0)],
	]
	var cam := Camera3D.new()
	root.add_child(cam)
	# NEAR MATTERS AS MUCH AS FAR: a default 0.05 near against a 40 km far is a
	# depth ratio the buffer cannot resolve, and the render comes back as
	# speckles that read as broken geometry rather than as a broken camera.
	cam.near = 5.0
	cam.far = 40000.0
	cam.current = true

	var panels: Array = []
	for s in shots:
		var sh: Array = s
		cam.position = sh[1]
		cam.look_at(sh[2], Vector3.UP)
		for i in range(8):
			await process_frame
		panels.append(get_root().get_texture().get_image())
		print("shot: %s" % sh[0])

	var w0: int = (panels[0] as Image).get_width()
	var h0: int = (panels[0] as Image).get_height()
	var out := Image.create(w0, h0 * panels.size() + 8 * (panels.size() - 1),
		false, (panels[0] as Image).get_format())
	out.fill(Color(0.05, 0.05, 0.06))
	var y := 0
	for p in panels:
		out.blit_rect(p as Image, Rect2i(0, 0, w0, h0), Vector2i(0, y))
		y += h0 + 8
	var err := out.save_png(out_png)
	print("%s %s  (%d road surfaces, %d water)"
		% ["wrote" if err == OK else "FAILED", out_png,
		   roads.get_surface_count(), water.size()])
	quit(0 if err == OK else 1)


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
