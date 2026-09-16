extends SceneTree
# Parity: the core's bf6_meshset_sections against the GDScript reader it ports,
# over every mesh a real map places. Every LOD, with and without shadow sections
# and all UV sets, compared value for value (bitwise, so NaN payloads count).
#   godot --headless --path <project> --script res://tools/test_meshset_native.gd -- <install> <level> [max_meshes]
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")

func _init() -> void:
	call_deferred("_run")

func _same(a, b) -> bool:
	return var_to_bytes(a) == var_to_bytes(b)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <install> <level> [max_meshes]")
		quit(2)
		return
	var install := str(args[0])
	var level := str(args[1])
	var limit := int(args[2]) if args.size() > 2 else 0
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	gs.prepare_geometry_only = true
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed: " + str(gs.error))
		quit(3)
		return
	var data: Dictionary = gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
	var props: Array = data.get("props", []).duplicate()
	props.append_array(data.get("backdrop", []))
	var names := {}
	for p in props:
		var key := str(p.get("mesh", ""))
		var res_name := key.get_slice("|", 0)
		if gs._group_meta.has(key):
			res_name = str(gs._group_meta[key][0])
		if not res_name.is_empty():
			names[res_name] = true
	var ms := BF6MeshSet.new()
	var checked := 0
	var calls := 0
	var sections := 0
	var mismatches := 0
	var native_us := 0
	var script_us := 0
	var reported := 0
	var sorted: Array = names.keys()
	sorted.sort()
	for res_name in sorted:
		if limit > 0 and checked >= limit:
			break
		var d: PackedByteArray = gs.src.get_res(str(res_name))
		if d.is_empty():
			continue
		var info := ms.parse(d)
		var lods: Array = info.get("lods", [])
		checked += 1
		for li in range(lods.size()):
			var chunk := PackedByteArray()
			var cid: PackedByteArray = lods[li].get("chunk_id", PackedByteArray())
			if not cid.is_empty():
				for form in BF6MeshSet.chunk_forms(cid):
					chunk = gs.src.get_chunk(str(form))
					if not chunk.is_empty():
						break
			# LOD0 in every mode; coarser LODs in the build's own mode.
			var modes := [[false, false], [true, true], [false, true]] if li == 0 else [[false, false]]
			for mode in modes:
				ms.use_native_sections = false
				var t0 := Time.get_ticks_usec()
				var want: Array = ms.read_lod(d, li, chunk, mode[0], mode[1])
				var want_error := ms.error
				script_us += Time.get_ticks_usec() - t0
				ms.use_native_sections = true
				var t1 := Time.get_ticks_usec()
				var got: Array = ms.read_lod(d, li, chunk, mode[0], mode[1])
				native_us += Time.get_ticks_usec() - t1
				calls += 1
				sections += want.size()
				var bad := ""
				if ms.native_section_reads <= 0:
					bad = "native path not taken"
				elif got.size() != want.size():
					bad = "section count %d != %d" % [got.size(), want.size()]
				elif ms.error != want_error:
					bad = "error '%s' != '%s'" % [ms.error, want_error]
				else:
					for si in range(want.size()):
						var w: Dictionary = want[si]
						var g: Dictionary = got[si]
						if w.keys() != g.keys():
							bad = "section %d keys %s != %s" % [si, str(g.keys()), str(w.keys())]
							break
						for k in w.keys():
							if not _same(w[k], g[k]):
								bad = "section %d field %s differs" % [si, k]
								break
						if not bad.is_empty():
							break
				if not bad.is_empty():
					mismatches += 1
					if reported < 25:
						reported += 1
						print("MISMATCH %s lod %d mode %s: %s" % [res_name, li, str(mode), bad])
	print("meshes %d, reads %d, sections %d, mismatches %d" % [checked, calls, sections, mismatches])
	print("script %.2f s, native (incl. unpack) %.2f s, x%.1f" % [script_us / 1e6, native_us / 1e6, float(script_us) / maxf(1.0, native_us)])
	print("RESULT ", "PASS" if mismatches == 0 and checked > 0 else "FAIL")
	quit(0 if mismatches == 0 and checked > 0 else 1)
