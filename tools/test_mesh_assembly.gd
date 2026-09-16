extends SceneTree
# Parity: native surface assembly (bf6_meshset_surfaces) against the script
# merge it ports, for every mesh group a real map places, in its own scope and
# variation. Surface names and every array are compared bitwise.
#   godot --headless --path <project> --script res://tools/test_mesh_assembly.gd -- <install> <level> [max_groups]
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var install := str(args[0])
	var level := str(args[1])
	var limit := int(args[2]) if args.size() > 2 else 0
	var use_precache := args.size() > 3 and args[3] == "precache"
	var not_cached := 0
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed: " + str(gs.error))
		quit(3)
		return
	if gs._native_assembler() == null:
		push_error("native assembler missing")
		quit(4)
		return
	var data: Dictionary = gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
	var props: Array = data.get("props", []).duplicate()
	props.append_array(data.get("backdrop", []))
	var groups := {}
	for p in props:
		groups[str(p.get("mesh", ""))] = true
	var checked := 0
	var mismatches := 0
	var splits := 0
	var surfaces := 0
	var script_us := 0
	var native_us := 0
	var reported := 0
	var natives_before: int = gs.n_native_assembled
	var keys: Array = groups.keys()
	keys.sort()
	for group_key in keys:
		if limit > 0 and checked >= limit:
			break
		var res_name := str(group_key)
		var scope := ""
		var var_hash := 0
		if gs._group_meta.has(group_key):
			var m: Array = gs._group_meta[group_key]
			res_name = str(m[0])
			scope = str(m[1])
			if m.size() > 3:
				var_hash = int(m[3])
		elif res_name.contains("|"):
			var parts := res_name.split("|")
			res_name = str(parts[0])
			scope = str(parts[1])
			if parts.size() > 2:
				var_hash = int(str(parts[2]))
		if res_name.is_empty():
			continue
		var d: PackedByteArray = gs.src.get_res(res_name)
		if d.is_empty():
			continue
		var info: Dictionary = gs._ms.parse(d)
		var lods: Array = info.get("lods", [])
		if lods.is_empty():
			continue
		var li: int = clampi(Source.PROP_LOD, 0, lods.size() - 1)
		var chunk := PackedByteArray()
		var cid: PackedByteArray = lods[li].get("chunk_id", PackedByteArray())
		if not cid.is_empty():
			for form in BF6MeshSet.chunk_forms(cid):
				chunk = gs.src.get_chunk(str(form))
				if not chunk.is_empty():
					break
		checked += 1
		var t0 := Time.get_ticks_usec()
		var want: Array = gs._assemble_script(d, info, li, chunk, res_name, scope, var_hash)
		script_us += Time.get_ticks_usec() - t0
		var t1 := Time.get_ticks_usec()
		var got: Array = gs._assemble_native(d, info, li, chunk, res_name, scope, var_hash)
		if use_precache:
			got = gs._assemble_precached(res_name, scope, var_hash)
			if got.is_empty() and not want.is_empty():
				not_cached += 1
				continue
		native_us += Time.get_ticks_usec() - t1
		var bad := ""
		if want.is_empty() != got.is_empty():
			bad = "one side empty (script %s, native %s)" % [want.is_empty(), got.is_empty()]
		elif not want.is_empty():
			var wm: ArrayMesh = want[0]
			var gm: ArrayMesh = got[0]
			if want[1] != got[1]:
				bad = "names %s != %s" % [str(got[1]), str(want[1])]
			elif int(want[2]) != int(got[2]) or bool(want[3]) != bool(got[3]):
				bad = "counts/split %s,%s != %s,%s" % [got[2], got[3], want[2], want[3]]
			elif wm.get_surface_count() != gm.get_surface_count():
				bad = "surface count"
			else:
				if bool(want[3]):
					splits += 1
				for si in range(wm.get_surface_count()):
					surfaces += 1
					var wa: Array = wm.surface_get_arrays(si)
					var ga: Array = gm.surface_get_arrays(si)
					for k in range(Mesh.ARRAY_MAX):
						if var_to_bytes(wa[k]) != var_to_bytes(ga[k]):
							bad = "surface %d array %d differs" % [si, k]
							break
					if not bad.is_empty():
						break
		if not bad.is_empty():
			mismatches += 1
			if reported < 25:
				reported += 1
				print("MISMATCH %s scope=%s var=%d: %s" % [res_name, scope, var_hash, bad])
	var native_taken: int = gs.n_native_assembled - natives_before
	if use_precache:
		print("precache: active %s, served %d, not cached %d, batch time %.2f s" % [gs._precache_active(), gs.n_precache_meshes, not_cached, gs.t_precache / 1e6])
	print("groups %d (native taken %d), surfaces %d, palette splits %d, mismatches %d" % [checked, native_taken, surfaces, splits, mismatches])
	print("script %.2f s, native %.2f s, x%.1f" % [script_us / 1e6, native_us / 1e6, float(script_us) / maxf(1.0, native_us)])
	var ok := mismatches == 0 and checked > 0 and native_taken > 0
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
