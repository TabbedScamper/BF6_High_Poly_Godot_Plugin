extends SceneTree

# The MultiMesh question, at real scale, with real map geometry.
#
# The synthetic test (8,000 boxes) showed 125 draw calls against 2 and identical
# frame times, which proves the merging behaviour and settles nothing about
# whether the change is worth making. The open question from the engine research
# is specifically about SCALE: the render list holds one element per visible
# surface per instance and is sorted every frame, so moving 44,925 props off
# MultiMesh could win on draw calls and lose on list construction. Eight
# thousand boxes cannot answer that. Dumbo can.
#
# Uses the pipeline's own placements.json — the same file the plugin consumes —
# so the geometry, the instance counts and the spatial distribution are the real
# ones, not a model of them.
#
# LODs ARE GENERATED for every strategy. Leaving them out would bias the result
# toward MultiMesh: a MultiMesh gets one LOD for the whole cell while individual
# instances get one each, and that per-instance LOD is part of what is being
# compared. Same meshes, same LOD chains, three ways of submitting them.
#
#   godot --path <proj> --script bench_real.gd -- <placements.json> <props dir> [groups] [cell_m]

var _mesh_cache := {}


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var pj := str(args[0]) if args.size() > 0 else ""
	var pdir := str(args[1]) if args.size() > 1 else ""
	var cap := int(str(args[2])) if args.size() > 2 else 900
	var cell_m := float(str(args[3])) if args.size() > 3 else 64.0

	var txt := FileAccess.get_file_as_string(pj)
	if txt == "":
		print("cannot read %s" % pj); quit(1); return
	var data = JSON.parse_string(txt)
	if data == null or not data.has("props"):
		print("no props in %s" % pj); quit(1); return

	# --- load real meshes and real transforms -------------------------------
	var groups: Array = []          # {mesh, xforms}
	var total := 0
	var tris := 0
	var t0 := Time.get_ticks_msec()
	# A TRIANGLE BUDGET, not just a group cap.
	#
	# The full-scale run died at roughly 2,000 meshes: surface_get_arrays()
	# itself returned "Buffer is either invalid or this type of buffer can't be
	# retrieved", and the next line segfaulted. GDScript cannot guard that — the
	# CALL is what fails — so the only defence is not to reach the ceiling.
	#
	# Worth noticing rather than just working around: the plugin loads every
	# prop and generates LOD chains exactly like this, so the same ceiling is
	# somewhere in its path too.
	var budget := 12_000_000
	for e in data["props"]:
		if groups.size() >= cap:
			break
		if tris >= budget:
			print("  stopping at the %d-triangle budget after %d group(s)"
					% [budget, groups.size()])
			break
		if not (e is Dictionary) or not e.has("glb") or not e.has("xf"):
			continue
		var m := _load_mesh(pdir.path_join(str(e["glb"]).get_file()))
		if m == null:
			continue
		var xf: Array = e["xf"]
		var n := int(xf.size() / 12)
		if n <= 0:
			continue
		var xs: Array[Transform3D] = []
		for i in range(n):
			var o := i * 12
			# stored row-major 3x4: three basis ROWS each followed by a
			# translation component
			xs.append(Transform3D(
					Basis(Vector3(xf[o], xf[o+4], xf[o+8]),
						  Vector3(xf[o+1], xf[o+5], xf[o+9]),
						  Vector3(xf[o+2], xf[o+6], xf[o+10])),
					Vector3(xf[o+3], xf[o+7], xf[o+11])))
		groups.append({"mesh": m, "xf": xs})
		total += n
		for s in range(m.get_surface_count()):
			tris += m.surface_get_arrays(s)[Mesh.ARRAY_INDEX].size() / 3
	print("loaded %d group(s), %d instance(s), %d unique tris in %.1fs"
			% [groups.size(), total, tris, (Time.get_ticks_msec() - t0) / 1000.0])
	if groups.is_empty():
		print("nothing to render"); quit(1); return

	# --- a camera that sees the map, placed from the real bounds ------------
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for g in groups:
		for t in g["xf"]:
			lo = lo.min(t.origin)
			hi = hi.max(t.origin)
	var mid := (lo + hi) * 0.5
	var span: float = maxf(hi.x - lo.x, hi.z - lo.z)
	print("world span %.0f m, centre (%.0f, %.0f, %.0f)" % [span, mid.x, mid.y, mid.z])

	var root := Node3D.new()
	get_root().add_child(root)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.far = maxf(4000.0, span * 2.0)
	# An oblique view from one corner: a top-down shot sees everything and is
	# the one view a user never uses, and a ground shot sees almost nothing.
	cam.position = Vector3(mid.x - span * 0.45, mid.y + span * 0.35,
			mid.z - span * 0.45)
	cam.look_at(mid)

	var rows: Array = []
	rows.append(await _multimesh_cells(root, groups, cell_m))
	rows.append(await _mesh_instances(root, groups))
	rows.append(await _rs_direct(root, groups))

	print("\n%-22s %10s %10s %12s %10s %10s"
			% ["strategy", "draw", "objects", "primitives", "frame ms", "build ms"])
	for r in rows:
		print("%-22s %10d %10d %12d %10.2f %10d"
				% [r["name"], r["draw_calls"], r["objects"], r["primitives"],
				   r["frame_us"] / 1000.0, r["build_ms"]])

	var mm: Dictionary = rows[0]
	var mi: Dictionary = rows[1]
	print("\ndraw calls: MultiMesh %d vs MeshInstance %d  (%.1fx)"
			% [mm["draw_calls"], mi["draw_calls"],
			   float(mm["draw_calls"]) / maxf(1.0, float(mi["draw_calls"]))])
	print("frame time: MultiMesh %.2f ms vs MeshInstance %.2f ms  (%+.1f%%)"
			% [mm["frame_us"] / 1000.0, mi["frame_us"] / 1000.0,
			   100.0 * (float(mi["frame_us"]) - float(mm["frame_us"]))
					/ maxf(1.0, float(mm["frame_us"]))])
	print("\nthe frame time is the answer, not the draw-call count: fewer draw")
	print("calls that cost more render-list work is not a win.")
	quit(0)


func _multimesh_cells(root: Node3D, groups: Array, cell_m: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var host := Node3D.new()
	root.add_child(host)
	var made := 0
	for g in groups:
		# bucket this group's instances into cells, exactly like the plugin
		var cells := {}
		for t in g["xf"]:
			var key := "%d,%d" % [int(floor(t.origin.x / cell_m)),
					int(floor(t.origin.z / cell_m))]
			if not cells.has(key):
				cells[key] = []
			cells[key].append(t)
		for key in cells:
			var xs: Array = cells[key]
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
			host.add_child(mmi)
			made += 1
	var build := Time.get_ticks_msec() - t0
	var r := await _measure("multimesh_cells", build)
	r["nodes"] = made
	host.queue_free()
	await _settle()
	return r


func _mesh_instances(root: Node3D, groups: Array) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var host := Node3D.new()
	root.add_child(host)
	var made := 0
	for g in groups:
		for t in g["xf"]:
			var mi := MeshInstance3D.new()
			mi.mesh = g["mesh"]
			mi.transform = t
			host.add_child(mi)
			made += 1
	var build := Time.get_ticks_msec() - t0
	var r := await _measure("meshinstance_nodes", build)
	r["nodes"] = made
	host.queue_free()
	await _settle()
	return r


func _rs_direct(root: Node3D, groups: Array) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var rs := RenderingServer
	var scenario := root.get_world_3d().scenario
	var rids: Array[RID] = []
	for g in groups:
		var mrid: RID = (g["mesh"] as Mesh).get_rid()
		for t in g["xf"]:
			var inst := rs.instance_create2(mrid, scenario)
			rs.instance_set_transform(inst, t)
			rids.append(inst)
	var build := Time.get_ticks_msec() - t0
	var r := await _measure("rs_instances", build)
	r["nodes"] = 0
	for rid in rids:
		rs.free_rid(rid)
	await _settle()
	return r


func _measure(name: String, build_ms: int) -> Dictionary:
	await _settle()
	var vp := get_root()
	var t0 := Time.get_ticks_usec()
	var frames := 30
	for _i in range(frames):
		await process_frame
	var per := (Time.get_ticks_usec() - t0) / float(frames)
	return {
		"name": name,
		"build_ms": build_ms,
		"frame_us": int(per),
		"draw_calls": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"objects": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_OBJECTS_IN_FRAME),
		"primitives": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
	}


func _settle() -> void:
	for _i in range(8):
		await process_frame


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
	var node := doc.generate_scene(st)
	if node == null:
		_mesh_cache[path] = null
		return null
	var found: Array = []
	_collect(node, found)
	var out: Mesh = null
	if not found.is_empty():
		# merge every surface into one ImporterMesh and generate LODs, which is
		# what the plugin ships
		var im := ImporterMesh.new()
		var added := 0
		for m in found:
			for s in range(m.get_surface_count()):
				var arr: Array = m.surface_get_arrays(s)
				# GUARD. A full-scale run crashed inside add_surface at ~2,000
				# meshes. GDScript cannot catch that, so the preconditions are
				# checked instead: a surface with no vertices or no indices is
				# nothing to simplify and is what add_surface chokes on.
				if arr.size() <= Mesh.ARRAY_INDEX:
					continue
				var vtx = arr[Mesh.ARRAY_VERTEX]
				var idx = arr[Mesh.ARRAY_INDEX]
				if vtx == null or idx == null:
					continue
				if (vtx as PackedVector3Array).is_empty():
					continue
				if (idx as PackedInt32Array).size() < 3:
					continue
				im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
						m.surface_get_material(s))
				added += 1
		if added > 0:
			im.generate_lods(25.0, 60.0, [])
			out = im.get_mesh()
	node.queue_free()
	_mesh_cache[path] = out
	return out


func _collect(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
		out.append((n as MeshInstance3D).mesh)
	for c in n.get_children():
		_collect(c, out)
