extends SceneTree

# The texture decode is supposed to happen on worker threads while the main
# thread is busy placing the previous prop. It has not since v1.35.0.
#
# _prefetch_job decodes the sidecar — but that line sat AFTER the prefetch_stage
# early returns, and the default stage is 0, which returns immediately. So the
# decode never ran, and every texture in every map went through the main thread
# instead. A recorded Dumbo load spent 43.1 s there across 4,732 props, under a
# phase literally named "textures: decoded on the MAIN thread (no prefetch)".
#
# Nothing failed. It was 43 seconds slower and correct.
#
# So this asserts the OUTCOME rather than the wiring: after a prefetch, the
# texture cache is populated, and the loader finds it there instead of decoding
# inline. And it does it at the DEFAULT stage, because pinning the stage is what
# hid the bug — the earlier test passed only because it never used stage 0.
#
# Run with "-- <dir of stripped glbs with .bctex> <count>".

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
# Where this test looks when no directory is given on the command line. It used
# to be one machine's absolute temp path, which made every default run fail for
# anybody else. Set HIGHPOLY_TEST_DIR to point it somewhere, or pass the folder
# as the first argument after "--".
static func _sp() -> String:
	var e := OS.get_environment("HIGHPOLY_TEST_DIR")
	return e if e != "" else OS.get_user_data_dir().path_join("test")

var fails := 0


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var dir: String = str(a[0]) if a.size() > 0 else _sp() + "/real_bc"
	var n := int(str(a[1])) if a.size() > 1 else 40

	var files := _glbs(dir)
	files = files.slice(0, n)
	if files.is_empty():
		print("no glbs in %s" % dir); quit(1); return

	var sided: Array = []
	for p in files:
		if FileAccess.file_exists(str(p).get_basename() + ".bctex"):
			sided.append(p)
	if sided.is_empty():
		print("no .bctex sidecars in %s — nothing to prefetch" % dir)
		quit(1); return
	print("%d prop(s), %d with a texture sidecar\n" % [files.size(), sided.size()])

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.vram_mode = MC.VRAM_COMPRESSED
	mc.mesh_cache_enabled = false

	# THE DEFAULT, deliberately not pinned. Stage 0 is what ships, and it is the
	# one stage under which this was broken.
	_check("the shipped prefetch stage is the one under test (stage %d)"
		% MC.prefetch_stage, MC.prefetch_stage == 0)

	# ---- the prefetch has to leave the textures somewhere ----------------
	await mc._prefetch(sided)
	var cached := 0
	for p in sided:
		if mc._bc.has(str(p)):
			cached += 1
	_check("prefetching fills the texture cache (%d of %d)"
		% [cached, sided.size()], cached == sided.size())

	# ---- and the loader has to actually take it from there ---------------
	# Draining the cache is the proof it was used: if the loader decoded inline
	# instead, these entries would still be sitting here afterwards.
	var before: int = mc._bc.size()
	for p in sided:
		mc._mesh_cache.clear()
		await mc._parse_prop_file(str(p))
	_check("and the loader consumes it rather than decoding again (%d -> %d)"
		% [before, mc._bc.size()], mc._bc.size() < before)

	# ---- textures still land, which is the point of all of it ------------
	var textured := 0
	for p in sided:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		if r is Array:
			for m in r:
				var am := m as ArrayMesh
				if am == null: continue
				for s in range(am.get_surface_count()):
					var bm := am.surface_get_material(s) as BaseMaterial3D
					if bm != null and bm.albedo_texture != null:
						textured += 1
						break
				break
	_check("props still come back textured (%d of %d)"
		% [textured, sided.size()], textured == sided.size())

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _glbs(dir: String) -> Array:
	var da := DirAccess.open(dir)
	if da == null: return []
	var out: Array = []
	for f in da.get_files():
		if str(f).ends_with(".glb"): out.append(dir + "/" + str(f))
	out.sort()
	return out


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
