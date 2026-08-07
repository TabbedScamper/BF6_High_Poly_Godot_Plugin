extends SceneTree

# Fly a recorded path over the real map and report what the frames did.
#
# The static-camera benchmarks answered "which strategy submits geometry more
# cheaply from this one viewpoint". They cannot answer "is it smoother to fly",
# because the cost of a viewpoint varies enormously across a map and an average
# over one spot is not an average over a flight.
#
# So: load the same props the plugin loads, replay the camera transforms the
# user actually recorded, and report the DISTRIBUTION. The mean is close to
# useless here — a flight that is beautiful for 90% of its length and hitches
# twice is a flight people call broken. The 1% low is the number that matches
# what a person reports.
#
#   godot --path <proj> --script bench_flight.gd --
#         <flightpath.json> <placements.json> <props dir> [strategy] [groups]
#
# strategy: multimesh (default) | meshinstance | rs

const CELL := 64.0

var _mesh_cache := {}


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var fp := str(a[0]) if a.size() > 0 else ""
	var pj := str(a[1]) if a.size() > 1 else ""
	var pdir := str(a[2]) if a.size() > 2 else ""
	var strategy := str(a[3]) if a.size() > 3 else "multimesh"
	var cap := int(str(a[4])) if a.size() > 4 else 1200

	var path := _load_path(fp)
	if path.is_empty():
		print("no flight path in %s" % fp); quit(1); return
	print("flight path: %d samples" % path.size())

	var groups := _load_groups(pj, pdir, cap)
	if groups.is_empty():
		print("no props loaded"); quit(1); return

	var root := Node3D.new()
	get_root().add_child(root)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.far = 4000.0

	var built := _build(root, groups, strategy)
	print("strategy %s: %d node(s)/instance(s) built in %d ms"
			% [strategy, built[0], built[1]])

	# settle before timing: the first frames after a build are not typical
	for _i in range(20):
		await process_frame

	var vp := get_root()
	var times: Array[float] = []
	var draws: Array[int] = []
	for i in range(path.size()):
		var e: Dictionary = path[i]
		cam.global_transform = e["xf"]
		if e.has("fov"):
			cam.fov = float(e["fov"])
		var t0 := Time.get_ticks_usec()
		await process_frame
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		draws.append(vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME))

	times.sort()
	var n := times.size()
	var mean := 0.0
	for t in times:
		mean += t
	mean /= float(n)
	# "1% low" in the sense people use it: the mean of the worst 1% of frames,
	# not the 1st percentile sample. It is what a hitch feels like.
	var worst_n := maxi(1, int(n * 0.01))
	var low1 := 0.0
	for i in range(n - worst_n, n):
		low1 += times[i]
	low1 /= float(worst_n)
	var dmax := 0
	var dsum := 0
	for d in draws:
		dsum += d
		dmax = maxi(dmax, d)

	print("\nframes over the recorded flight (%d)" % n)
	print("   mean      %8.2f ms   (%6.1f fps)" % [mean, 1000.0 / maxf(mean, 0.001)])
	print("   median    %8.2f ms   (%6.1f fps)" % [times[n / 2], 1000.0 / maxf(times[n / 2], 0.001)])
	print("   95th      %8.2f ms" % times[mini(n - 1, int(n * 0.95))])
	print("   99th      %8.2f ms" % times[mini(n - 1, int(n * 0.99))])
	print("   1%% low    %8.2f ms   (%6.1f fps)  <- what a hitch feels like"
			% [low1, 1000.0 / maxf(low1, 0.001)])
	print("   worst     %8.2f ms" % times[n - 1])
	print("   draw calls: mean %d, peak %d" % [dsum / maxi(n, 1), dmax])
	quit(0)


func _load_path(p: String) -> Array:
	var txt := FileAccess.get_file_as_string(p)
	if txt == "":
		return []
	var d = JSON.parse_string(txt)
	if d == null or not d.has("samples"):
		return []
	var out: Array = []
	for s in d["samples"]:
		var b: Array = s["b"]
		var pos: Array = s["p"]
		var e := {"xf": Transform3D(
				Basis(Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]),
					  Vector3(b[6], b[7], b[8])),
				Vector3(pos[0], pos[1], pos[2]))}
		if s.has("fov"):
			e["fov"] = s["fov"]
		out.append(e)
	return out


func _load_groups(pj: String, pdir: String, cap: int) -> Array:
	var txt := FileAccess.get_file_as_string(pj)
	if txt == "":
		return []
	var data = JSON.parse_string(txt)
	if data == null or not data.has("props"):
		return []
	var groups: Array = []
	var tris := 0
	for e in data["props"]:
		if groups.size() >= cap or tris >= 12_000_000:
			break
		if not (e is Dictionary) or not e.has("glb") or not e.has("xf"):
			continue
		var m := _load_mesh(pdir.path_join(str(e["glb"]).get_file()))
		if m == null:
			continue
		var xf: Array = e["xf"]
		var xs: Array[Transform3D] = []
		for i in range(int(xf.size() / 12)):
			var o := i * 12
			xs.append(Transform3D(
					Basis(Vector3(xf[o], xf[o+4], xf[o+8]),
						  Vector3(xf[o+1], xf[o+5], xf[o+9]),
						  Vector3(xf[o+2], xf[o+6], xf[o+10])),
					Vector3(xf[o+3], xf[o+7], xf[o+11])))
		if xs.is_empty():
			continue
		groups.append({"mesh": m, "xf": xs})
		for s in range(m.get_surface_count()):
			tris += m.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3
	return groups


func _build(root: Node3D, groups: Array, strategy: String) -> Array:
	var t0 := Time.get_ticks_msec()
	var made := 0
	if strategy == "rs":
		var rs := RenderingServer
		var scen := root.get_world_3d().scenario
		for g in groups:
			var mr: RID = (g["mesh"] as Mesh).get_rid()
			for t in g["xf"]:
				var inst := rs.instance_create2(mr, scen)
				rs.instance_set_transform(inst, t)
				made += 1
	elif strategy == "meshinstance":
		for g in groups:
			for t in g["xf"]:
				var mi := MeshInstance3D.new()
				mi.mesh = g["mesh"]
				mi.transform = t
				root.add_child(mi)
				made += 1
	else:
		for g in groups:
			var cells := {}
			for t in g["xf"]:
				var k := "%d,%d" % [int(floor(t.origin.x / CELL)),
						int(floor(t.origin.z / CELL))]
				if not cells.has(k):
					cells[k] = []
				cells[k].append(t)
			for k in cells:
				var xs: Array = cells[k]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = g["mesh"]
				mm.instance_count = xs.size()
				var buf := PackedFloat32Array()
				buf.resize(xs.size() * 12)
				var w := 0
				for t in xs:
					buf[w] = t.basis.x.x; buf[w+1] = t.basis.y.x; buf[w+2] = t.basis.z.x; buf[w+3] = t.origin.x
					buf[w+4] = t.basis.x.y; buf[w+5] = t.basis.y.y; buf[w+6] = t.basis.z.y; buf[w+7] = t.origin.y
					buf[w+8] = t.basis.x.z; buf[w+9] = t.basis.y.z; buf[w+10] = t.basis.z.z; buf[w+11] = t.origin.z
					w += 12
				mm.buffer = buf
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				root.add_child(mmi)
				made += 1
	return [made, Time.get_ticks_msec() - t0]


func _load_mesh(path: String) -> Mesh:
	if _mesh_cache.has(path):
		return _mesh_cache[path]
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		_mesh_cache[path] = null
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(bytes, path.get_base_dir(), st) != OK:
		_mesh_cache[path] = null
		return null
	# ImporterMesh straight out of GLTFState: no generate_scene, so no GPU
	# upload of the source meshes and no readback. The scene path exhausts the
	# RenderingDevice's buffer pool at ~2,000 props and crashes.
	var im := ImporterMesh.new()
	var added := 0
	for gm in st.get_meshes():
		var src: ImporterMesh = gm.get_mesh()
		if src == null:
			continue
		for s in range(src.get_surface_count()):
			var arr: Array = src.get_surface_arrays(s)
			if arr.size() <= Mesh.ARRAY_INDEX or arr[Mesh.ARRAY_INDEX] == null:
				continue
			if (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() < 3:
				continue
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
					src.get_surface_material(s))
			added += 1
	var out: Mesh = null
	if added > 0:
		im.generate_lods(25.0, 60.0, [])
		out = im.get_mesh()
	_mesh_cache[path] = out
	return out
