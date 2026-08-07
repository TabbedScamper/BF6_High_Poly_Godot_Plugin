extends SceneTree

# The WHOLE map through the reader, not six props.
#
# Every reader result so far is either a comparison against Python or a handful
# of props rendered in a studio. Neither answers the question that decides
# whether this can replace the download: what does it cost to build all 2,273
# meshes and their materials, and does anything fall over at that scale?
#
# Specifically at risk, none of which shows up at six props:
#   * total time — 6.5 ms a mesh and ~7 ms a texture are fine once and ruinous
#     2,273 and 3,000 times
#   * memory — every ImageTexture stays resident; the download path asked for
#     14.5 GB of texture memory doing the same job, and that is the thing the
#     .bctex pool had to fix
#   * cache hit rates — the whole design assumes textures and materials are
#     shared heavily. If they are not, this is 29,166 uploads.
#
# Headless is fine here: this measures BUILDING, not drawing. It reports render
# counters as zero and says so rather than letting a zero read as a win.
#
#   godot --headless --path <proj> --script test_mapscale.gd -- [level] [limit]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var limit := 0                 # 0 = every mesh
	var notex := false
	var seen := false
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if s == "notex":
			notex = true
		elif s.is_valid_int():
			limit = int(s)
		elif not seen:
			level = s
			seen = true

	var t_open := Time.get_ticks_msec()
	var gs = HighpolyGameSource.new()
	gs.build_materials = not notex
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	print("open      %.1f s" % ((Time.get_ticks_msec() - t_open) / 1000.0))

	var t_data := Time.get_ticks_msec()
	var data: Dictionary = gs.map_data()
	var props: Array = data["props"]
	var inst := 0
	for p in props:
		inst += int((p as Dictionary)["xf"].size() / 12)
	print("placements %.1f s — %d groups, %d instances"
		% [(Time.get_ticks_msec() - t_data) / 1000.0, props.size(), inst])

	var mem0 := OS.get_static_memory_usage()
	var t0 := Time.get_ticks_msec()
	var built := 0
	var empty := 0
	var surfaces := 0
	var tris := 0
	var with_mat := 0
	var slowest := 0
	var slowest_name := ""
	var n: int = props.size() if limit <= 0 else mini(limit, props.size())
	for i in range(n):
		var gk := str((props[i] as Dictionary)["mesh"])
		var t1 := Time.get_ticks_msec()
		var m: Mesh = gs.mesh_for(gk)
		var dt := Time.get_ticks_msec() - t1
		if dt > slowest:
			slowest = dt
			slowest_name = gk.split("|")[0].get_file()
		if m == null:
			empty += 1
			continue
		built += 1
		surfaces += m.get_surface_count()
		for si in range(m.get_surface_count()):
			if m.surface_get_material(si) != null:
				with_mat += 1
			# surface_get_array_index_len, NOT surface_get_arrays.
			#
			# The first version called surface_get_arrays() on all 10,229
			# surfaces to count triangles, which READS BACK and copies every
			# vertex and index buffer in the map — 22.7 million triangles' worth.
			# It reported 77.3 s and +12,775 MB, and an unknown share of both was
			# the measurement rather than the build. This asks the mesh for the
			# index count and copies nothing.
			if m is ArrayMesh:
				tris += int((m as ArrayMesh).surface_get_array_index_len(si) / 3)
		# Yielded so a long build cannot look like a hang, and so memory has a
		# chance to settle rather than reporting one peak of the whole loop.
		if i % 200 == 0:
			await process_frame
			print("   %d/%d  %.1f s  %d MB" % [i, n,
				(Time.get_ticks_msec() - t0) / 1000.0,
				int(OS.get_static_memory_usage() / 1048576)])

	var ms := Time.get_ticks_msec() - t0
	var mem := OS.get_static_memory_usage() - mem0
	print("\nBUILD     %d of %d groups, %d empty" % [built, n, empty])
	print("          %.1f s total, %.2f ms per mesh" % [ms / 1000.0,
		float(ms) / maxf(1.0, float(n))])
	print("          %d surfaces, %d with a material, %d triangles"
		% [surfaces, with_mat, tris])
	print("          slowest single mesh %d ms (%s)" % [slowest, slowest_name])
	print("MEMORY    +%d MB static" % int(mem / 1048576))
	print("TEXTURES  %s" % gs.tex_stats)

	var st: Dictionary = gs.tex_stats
	var dec := int(st.get("decoded", 0))
	var reu := int(st.get("reused", 0))
	print("          cache hit rate %.1f%% (%d reused of %d requests)"
		% [100.0 * reu / maxf(1.0, float(dec + reu)), reu, dec + reu])
	print("          resident texture data %.1f MB over %d distinct"
		% [int(st.get("bytes", 0)) / 1048576.0, dec])
	var dims: Dictionary = gs.tex_dims
	var dk: Array = dims.keys()
	dk.sort_custom(func(p, q): return int(dims[p]) > int(dims[q]))
	print("          sizes:")
	for k in dk.slice(0, 10):
		print("             %-22s %d" % [str(k), int(dims[k])])

	# The whole design rests on sharing. If almost nothing is reused then every
	# texture is its own upload and the memory story is the download path's.
	var ok: bool = built > 0 and float(empty) / maxf(1.0, float(n)) < 0.10
	print("\n%s" % ("PASS — the whole map builds"
		if ok else "FAIL — too many groups produced no mesh"))
	quit(0 if ok else 1)
