extends SceneTree
# Parity: textures decoded from the up-front cache's read-ahead (header and chunk
# from bf6_precache_texture_chunks) against the live source, for every texture the
# map's cached meshes name. Image bytes, size, format and chunk choice must match.
#   -- <install> <level> [max_textures]
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var install := str(args[0])
	var level := str(args[1])
	var limit := int(args[2]) if args.size() > 2 else 0
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed")
		quit(3)
		return
	gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
	var core: Object = Source.precache_core(install)
	if core == null or not core.precache_map_ready(level):
		push_error("no up-front cache for " + level)
		quit(4)
		return
	var meshes := {}
	for m in gs._group_meta.values():
		meshes[str((m as Array)[0])] = true
	var names: PackedStringArray = str(core.precache_mesh_texture_names(level, "\n".join(PackedStringArray(meshes.keys())))).split("\n", false)
	if limit > 0 and names.size() > limit:
		names = names.slice(0, limit)
	var cap: int = gs.texture_max_dim
	var tex := BF6Texture.new()
	var checked := 0
	var used_chunk := 0
	var mismatches := 0
	var live_us := 0
	var pre_us := 0
	var fetch_us := 0
	var header_differs := 0
	var reported := 0
	for start in range(0, names.size(), 64):
		var window := names.slice(start, mini(start + 64, names.size()))
		var t0 := Time.get_ticks_usec()
		var b: PackedByteArray = core.precache_texture_chunks("\n".join(window), cap, 0)
		pre_us += Time.get_ticks_usec() - t0
		fetch_us += Time.get_ticks_usec() - t0
		var at := 8
		for _i in range(int(b.decode_u32(4))):
			var parts: Array = []
			for _k in range(4):
				var n := int(b.decode_u32(at))
				parts.append(b.slice(at + 4, at + 4 + n))
				at += 4 + ((n + 3) & ~3)
			var name := (parts[0] as PackedByteArray).get_string_from_utf8()
			var header: PackedByteArray = parts[1]
			var guid := (parts[2] as PackedByteArray).get_string_from_ascii()
			var chunk: PackedByteArray = parts[3]
			var an := name.to_lower()
			if an.ends_with(".ebx"):
				an = an.substr(0, an.length() - 4)
			var t1 := Time.get_ticks_usec()
			var live_raw: PackedByteArray = gs.src.get_res(an)
			var live := tex.decode(live_raw, func(form): return gs.src.get_chunk(str(form)), cap)
			live_us += Time.get_ticks_usec() - t1
			var t2 := Time.get_ticks_usec()
			var hit := [false]
			# The live header decides; a read-ahead chunk is only used when it agrees.
			var usable := header == live_raw
			if not usable:
				header_differs += 1
			var pre := tex.decode(live_raw, func(form):
				if usable and not guid.is_empty() and str(form) == guid:
					hit[0] = true
					return chunk
				return gs.src.get_chunk(str(form)), cap)
			pre_us += Time.get_ticks_usec() - t2
			checked += 1
			if hit[0]:
				used_chunk += 1
			var bad := ""
			if live.is_empty() != pre.is_empty():
				bad = "one decode empty"
			elif not live.is_empty():
				var li: Image = live.image
				var pi: Image = pre.image
				if li.get_width() != pi.get_width() or li.get_height() != pi.get_height() or li.get_format() != pi.get_format():
					bad = "dims/format"
				elif str(live.chunk) != str(pre.chunk):
					bad = "chunk %s != %s" % [pre.chunk, live.chunk]
				elif li.get_data() != pi.get_data():
					bad = "pixels differ"
			if not bad.is_empty():
				mismatches += 1
				if reported < 20:
					reported += 1
					print("MISMATCH %s: %s" % [an, bad])
	print("textures %d, read-ahead chunk used %d, mismatches %d" % [checked, used_chunk, mismatches])
	print("headers differing (read live) %d" % header_differs)
	print("live %.2f s, read-ahead (fetch + decode) %.2f s, of which native fetch %.2f s" % [live_us / 1e6, pre_us / 1e6, fetch_us / 1e6])
	var ok := checked > 0 and mismatches == 0 and used_chunk > 0
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
