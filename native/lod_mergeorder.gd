extends SceneTree

# Does merging BEFORE generate_lods hurt the LOD chain, or help it?
#
# The claim to test: generate_lods runs per surface with SIMPLIFY_LOCK_BORDER
# always set, so a merged mesh with many surfaces is many separate
# simplification jobs whose open boundaries cannot be collapsed — and LODs
# should therefore be generated BEFORE merging.
#
# The reason to doubt it: an UNMERGED prop already has one surface per
# material. Merging by material does not split anything; if anything it
# concatenates like with like, making surfaces bigger and the locked border
# smaller relative to the area. That would make merging HELP.
#
# Whichever way it falls, guessing costs a pointless pipeline reorder, so
# measure both orders on the same props and compare the ladders.
#
#   godot --headless --path <proj> --script lod_mergeorder.gd -- <glb dir> [n]

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() > 0 else ""
	var want := int(str(args[1])) if args.size() > 1 else 60

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

	var a_src := 0     # merge first, then generate (what the plugin does)
	var a_lod := 0
	var b_src := 0     # generate per source mesh, then merge
	var b_lod := 0
	var multi := 0
	var done := 0
	# how ladder quality varies with surface size, which is the real question
	var by_size := {}

	for path in files:
		if done >= want:
			break
		var meshes := _load_meshes(path)
		if meshes.size() < 2:
			continue                      # single-mesh props cannot show a difference
		multi += 1
		done += 1

		# --- A: merge every surface into one mesh, then generate ---
		var im_a := ImporterMesh.new()
		for m in meshes:
			for s in range(m.get_surface_count()):
				im_a.add_surface(Mesh.PRIMITIVE_TRIANGLES,
						m.surface_get_arrays(s), [], {}, m.surface_get_material(s))
		im_a.generate_lods(25.0, 60.0, [])
		var ra := _ladder(im_a)
		a_src += int(ra[0]); a_lod += int(ra[1])

		# --- B: generate on each source mesh separately, then sum ---
		for m in meshes:
			var im_b := ImporterMesh.new()
			for s in range(m.get_surface_count()):
				im_b.add_surface(Mesh.PRIMITIVE_TRIANGLES,
						m.surface_get_arrays(s), [], {}, m.surface_get_material(s))
			im_b.generate_lods(25.0, 60.0, [])
			var rb := _ladder(im_b)
			b_src += int(rb[0]); b_lod += int(rb[1])

		# per-surface size vs first-rung ratio
		for s in range(im_a.get_surface_count()):
			var idx: PackedInt32Array = im_a.get_surface_arrays(s)[Mesh.ARRAY_INDEX]
			var tris := idx.size() / 3
			if im_a.get_surface_lod_count(s) == 0:
				_note(by_size, tris, -1.0)
			else:
				var l0: PackedInt32Array = im_a.get_surface_lod_indices(s, 0)
				_note(by_size, tris, float(l0.size() / 3) / maxf(1.0, float(tris)))

	print("\nmulti-mesh props compared: %d" % multi)
	print("  A  merge then generate (current):  source %d tris -> first rung %d  (%.1f%%)"
			% [a_src, a_lod, 100.0 * float(a_lod) / maxf(1.0, float(a_src))])
	print("  B  generate then merge:            source %d tris -> first rung %d  (%.1f%%)"
			% [b_src, b_lod, 100.0 * float(b_lod) / maxf(1.0, float(b_src))])
	if a_src > 0 and b_src > 0:
		var ra2 := float(a_lod) / float(a_src)
		var rb2 := float(b_lod) / float(b_src)
		if absf(ra2 - rb2) < 0.02:
			print("\n  The two orders agree. Merging does not hurt LOD generation,")
			print("  because an unmerged prop already has one surface per material.")
		elif ra2 < rb2:
			print("\n  Merging FIRST produces the better ladder (%.1f%% vs %.1f%%)."
					% [100.0 * ra2, 100.0 * rb2])
		else:
			print("\n  Merging first is WORSE (%.1f%% vs %.1f%%) — reorder the pipeline."
					% [100.0 * ra2, 100.0 * rb2])

	print("\n  first-rung ratio by surface size (the thing that actually drives it):")
	var keys := by_size.keys()
	keys.sort()
	for k in keys:
		var e: Array = by_size[k]
		var n: int = e[0]
		var nolod: int = e[2]
		print("     %-14s surfaces %-6d  no LOD %-5d  mean first rung %s"
				% [k, n, nolod,
				   ("%.1f%%" % (100.0 * e[1] / maxf(1.0, float(n - nolod))))
						if n > nolod else "-"])
	quit(0)


func _note(d: Dictionary, tris: int, ratio: float) -> void:
	var bucket := "0-99"
	if tris >= 10000: bucket = "10000+"
	elif tris >= 2000: bucket = "2000-9999"
	elif tris >= 500: bucket = "500-1999"
	elif tris >= 100: bucket = "100-499"
	if not d.has(bucket):
		d[bucket] = [0, 0.0, 0]
	d[bucket][0] += 1
	if ratio < 0.0:
		d[bucket][2] += 1
	else:
		d[bucket][1] += ratio


func _ladder(im: ImporterMesh) -> Array:
	var src := 0
	var first := 0
	for s in range(im.get_surface_count()):
		var idx: PackedInt32Array = im.get_surface_arrays(s)[Mesh.ARRAY_INDEX]
		src += idx.size() / 3
		if im.get_surface_lod_count(s) > 0:
			first += im.get_surface_lod_indices(s, 0).size() / 3
		else:
			first += idx.size() / 3        # no LOD: it renders at full detail
	return [src, first]


func _load_meshes(path: String) -> Array:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return []
	if doc.append_from_buffer(bytes, path.get_base_dir(), st) != OK:
		return []
	var node := doc.generate_scene(st)
	if node == null:
		return []
	var out: Array = []
	_collect(node, out)
	node.queue_free()
	return out


func _collect(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
		out.append((n as MeshInstance3D).mesh)
	for c in n.get_children():
		_collect(c, out)
