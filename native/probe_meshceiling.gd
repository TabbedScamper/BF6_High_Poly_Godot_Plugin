extends SceneTree

# Where does loading real props stop working, and why?
#
# A full-scale render benchmark died at roughly 2,000 meshes with
# "Buffer is either invalid or this type of buffer can't be retrieved" from
# surface_get_arrays(), then segfaulted. GDScript cannot catch that — the CALL
# is what fails — so the failure has to be characterised from outside.
#
# This matters beyond the benchmark: the plugin loads every prop on a map and
# runs surface_get_arrays over each in _merge_meshes, _bake_mesh and _with_lods.
# If there is a hard ceiling around 2,000, dense maps are near it.
#
# Reports the count reached and the memory at each step so the shape of the
# limit is visible — a clean linear climb to a wall is a different problem from
# a curve that flattens.
#
#   godot --headless --path <proj> --script probe_meshceiling.gd -- <glb dir> [n] [mode]
#
# mode: "keep" (default) holds every mesh, like the plugin's cache
#       "drop" releases each after reading, to separate residency from churn

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() > 0 else ""
	var want := int(str(args[1])) if args.size() > 1 else 4000
	var mode := str(args[2]) if args.size() > 2 else "keep"

	var da := DirAccess.open(dir)
	if da == null:
		print("cannot open %s" % dir); quit(1); return
	var files: Array[String] = []
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if f.ends_with(".glb"):
			files.append(dir.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	files.sort()
	print("mode: %s, %d glb(s) available, trying %d" % [mode, files.size(), want])

	var kept: Array = []
	var n := 0
	var surfaces := 0
	var tris := 0
	for path in files:
		if n >= want:
			break
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			continue
		if doc.append_from_buffer(bytes, path.get_base_dir(), st) != OK:
			continue
		var node := doc.generate_scene(st)
		if node == null:
			continue
		var meshes: Array = []
		_collect(node, meshes)
		for m in meshes:
			for s in range((m as ArrayMesh).get_surface_count()):
				# THE CALL THAT FAILS. Reading a surface back is a readback of
				# data the engine may have already handed to the GPU.
				var arr: Array = (m as ArrayMesh).surface_get_arrays(s)
				surfaces += 1
				if arr.size() > Mesh.ARRAY_INDEX and arr[Mesh.ARRAY_INDEX] != null:
					tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
			if mode == "keep":
				kept.append(m)
		if mode == "lods":
			# THE PLUGIN'S ACTUAL PATH: merge every surface into an
			# ImporterMesh and generate a LOD chain. Plain loading of all 2,871
			# files completes; the earlier crash happened with this step in, so
			# this is the difference worth isolating.
			var im := ImporterMesh.new()
			for m in meshes:
				for s in range((m as ArrayMesh).get_surface_count()):
					im.add_surface(Mesh.PRIMITIVE_TRIANGLES,
							(m as ArrayMesh).surface_get_arrays(s), [], {},
							(m as ArrayMesh).surface_get_material(s))
			if im.get_surface_count() > 0:
				im.generate_lods(25.0, 60.0, [])
				kept.append(im.get_mesh())
		node.queue_free()
		n += 1
		if n % 250 == 0:
			print("  %5d files  %6d surfaces  %9d tris  static %6.1f MB  video %6.1f MB"
					% [n, surfaces, tris,
					   OS.get_static_memory_usage() / 1048576.0,
					   Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	print("\nreached %d file(s), %d surface(s), %d tris without failing"
			% [n, surfaces, tris])
	print("static memory %.1f MB, video memory %.1f MB"
			% [OS.get_static_memory_usage() / 1048576.0,
			   Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	print("held %d mesh(es)" % kept.size())
	quit(0)


func _collect(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
		out.append((n as MeshInstance3D).mesh)
	for c in n.get_children():
		_collect(c, out)
