extends SceneTree

# A prefetch that is fast but produces different geometry is worse than no
# prefetch, and the difference would show up as subtly wrong props rather than
# as an error. So: parse the same files BOTH ways and compare what comes out.
#
# Also proves the worker half does not hang, which is the failure mode that
# stopped the first attempt (compress_scene_textures off-thread).

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const N := 24

var fails := 0


func _init() -> void:
	await process_frame
	var base := OS.get_environment("APPDATA") + "/Godot/app_userdata/Battlefield™ Portal Project"
	var dir := base + "/mapcontext/_props"
	var da := DirAccess.open(dir)
	if da == null:
		print("no props"); quit(1); return
	var files: Array = []
	for f in da.get_files():
		if f.ends_with(".glb"): files.append(dir + "/" + f)
	files.sort()
	files = files.slice(0, N)

	var mc = MC.new()
	root.add_child(mc)
	await process_frame
	mc.mesh_cache_enabled = false          # force the parse, not the sidecar

	# --- direct, one at a time, on the main thread --------------------------
	var t := Time.get_ticks_msec()
	var direct: Array = []
	for p in files:
		mc._mesh_cache.clear()
		direct.append(await mc._parse_prop_file(str(p)))
	var t_direct := Time.get_ticks_msec() - t

	# --- via the worker prefetch --------------------------------------------
	mc._pf.clear()
	t = Time.get_ticks_msec()
	await mc._prefetch(files)
	var t_pf := Time.get_ticks_msec() - t
	var pre: Array = []
	for p in files:
		mc._mesh_cache.clear()
		pre.append(await mc._parse_prop_file(str(p)))
	var t_total := Time.get_ticks_msec() - t

	print("direct (main thread)      : %6d ms" % t_direct)
	print("prefetch on workers       : %6d ms" % t_pf)
	print("prefetch + consume        : %6d ms   speedup %.2fx"
		% [t_total, float(t_direct) / maxf(1.0, float(t_total))])
	print("")

	_check("prefetched every file (%d)" % files.size(), pre.size() == files.size())
	var same_count := 0
	var same_tris := 0
	var same_surf := 0
	var textured := 0
	for i in range(files.size()):
		var a: Array = direct[i]
		var b: Array = pre[i]
		if a.size() != b.size():
			continue
		same_count += 1
		for k in range(a.size()):
			var ma := a[k] as Mesh
			var mb := b[k] as Mesh
			if ma == null or mb == null: continue
			if ma.get_surface_count() == mb.get_surface_count():
				same_surf += 1
			if _tris(ma) == _tris(mb):
				same_tris += 1
			for s in range(mb.get_surface_count()):
				var bm := mb.surface_get_material(s) as BaseMaterial3D
				if bm == null: continue
				var tx := bm.albedo_texture
				if tx != null and tx.get_image() != null and tx.get_image().is_compressed():
					textured += 1
					break
	_check("same number of meshes per prop", same_count == files.size())
	_check("same surface counts (%d)" % same_surf, same_surf >= files.size())
	_check("same triangle counts (%d)" % same_tris, same_tris >= files.size())
	_check("prefetched props still have COMPRESSED textures (%d)" % textured, textured > 0)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _tris(m: Mesh) -> int:
	var t := 0
	for s in range(m.get_surface_count()):
		var a := m.surface_get_arrays(s)
		if a.is_empty(): continue
		if a[Mesh.ARRAY_INDEX] != null:
			t += (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		elif a[Mesh.ARRAY_VERTEX] != null:
			t += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
