extends SceneTree

# The sidecar path THROUGH THE SHIPPED LOADER, not around it.
#
# test_bctex proves the format round-trips. This proves _parse_prop_file itself
# handles a stripped prop: same meshes, same triangles, textures actually
# attached, and the old path untouched for props that still carry their images.
#
# The risk being covered is a silent regression in the fallback. Almost every
# prop in the wild still ships the old way, and a loader that quietly stops
# texturing THOSE while working perfectly on the new ones would look like a
# success in every measurement taken on the new set.
#
# Run with "-- <stripped dir> <original dir>".

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const BcTex = preload("res://addons/highpoly_toggle/highpoly_bctex.gd")
const SP := "C:/Users/mwalt/AppData/Local/Temp/claude/C--Users-mwalt/9b036b50-aae1-4310-8139-063d65d55375/scratchpad"

var fails := 0


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var stripped: String = str(args[0]) if args.size() > 0 else SP + "/bc_out"
	var original: String = str(args[1]) if args.size() > 1 else SP + "/props_sample"

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.mesh_cache_enabled = false
	mc.vram_mode = MC.VRAM_COMPRESSED

	var new_files := _glbs(stripped)
	var old_files := _glbs(original)
	if new_files.is_empty() or old_files.is_empty():
		print("need both directories"); quit(1); return
	new_files = new_files.slice(0, 12)
	old_files = old_files.slice(0, 12)
	print("%d stripped, %d original\n" % [new_files.size(), old_files.size()])

	# ---- the OLD path still works ----------------------------------------
	# it has to: nearly every published prop still ships its images inside
	mc._pf_release()
	var old_tex := 0
	var old_tris := 0
	for p in old_files:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		if not (r is Array): continue
		for m in r:
			old_tris += _tris(m)
			old_tex += _textured(m)
	_check("props that still carry their images are textured (%d)" % old_tex,
		old_tex > 0)
	_check("and still produce geometry (%d tris)" % old_tris, old_tris > 0)

	# ---- the NEW path, straight through _parse_prop_file -------------------
	mc._pf_release()
	var new_tex := 0
	var new_tris := 0
	for p in new_files:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		if not (r is Array): continue
		for m in r:
			new_tris += _tris(m)
			new_tex += _textured(m)
	_check("stripped props come out textured through the shipped loader (%d)"
		% new_tex, new_tex > 0)
	_check("and produce the same geometry as the originals (%d vs %d tris)"
		% [new_tris, old_tris], new_tris == old_tris)

	# ---- with the textures decoded on workers first ------------------------
	mc._pf_release()
	var t := Time.get_ticks_msec()
	await mc._bctex_prefetch(new_files)
	var pre_ms := Time.get_ticks_msec() - t
	var cached: int = mc._bc.size()
	_check("the worker prefetch filled the texture cache (%d of %d)"
		% [cached, new_files.size()], cached == new_files.size())
	var pf_tex := 0
	for p in new_files:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		if not (r is Array): continue
		for m in r:
			pf_tex += _textured(m)
	_check("prefetched or not, the same textures land (%d vs %d)"
		% [pf_tex, new_tex], pf_tex == new_tex)
	_check("and the cache is drained by the loader", mc._bc.is_empty())
	print("\n  worker texture prefetch took %d ms for %d prop(s)"
		% [pre_ms, new_files.size()])

	# ---- a prop with no sidecar must not be broken by any of this ----------
	mc._pf_release()
	var plain = await mc._parse_prop_file(str(old_files[0]))
	_check("a prop with no sidecar still loads", plain is Array and plain.size() > 0)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _glbs(dir: String) -> Array:
	var da := DirAccess.open(dir)
	if da == null: return []
	var out: Array = []
	for f in da.get_files():
		if f.ends_with(".glb"): out.append(dir + "/" + str(f))
	out.sort()
	return out


func _tris(m) -> int:
	var mesh := m as Mesh
	if mesh == null: return 0
	var t := 0
	for s in range(mesh.get_surface_count()):
		var a := mesh.surface_get_arrays(s)
		if a.is_empty(): continue
		if a[Mesh.ARRAY_INDEX] != null:
			t += (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	return t


func _textured(m) -> int:
	var mesh := m as Mesh
	if mesh == null: return 0
	var n := 0
	for s in range(mesh.get_surface_count()):
		var bm := mesh.surface_get_material(s) as BaseMaterial3D
		if bm == null: continue
		var tx := bm.get_texture(BaseMaterial3D.TEXTURE_ALBEDO)
		if tx != null and tx.get_width() > 0:
			n += 1
	return n


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
