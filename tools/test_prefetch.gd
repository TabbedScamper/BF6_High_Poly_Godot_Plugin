extends SceneTree

# A prefetch that is fast but produces different geometry is worse than no
# prefetch, and the difference would show up as subtly wrong props rather than
# as an error. So: parse the same files BOTH ways and compare what comes out.
#
# Also proves the worker half does not hang, which is the failure mode that
# stopped the first attempt (compress_scene_textures off-thread).
#
# AND that it is actually faster, which for a long time it was not. The worker
# used to pack its result, the consumer instantiated it, compressed it, packed
# it AGAIN, and the caller instantiated a third time; that round trip cost about
# what the parse cost, so prefetching every prop came out the same speed as
# prefetching none (35.0 ms vs 34.8 ms per prop over 60 props). Nothing failed —
# the feature simply did nothing, silently, for as long as no test timed it.
# The speed assertion below is what stops that happening again.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const N := 24

var fails := 0


func _init() -> void:
	await process_frame
	var files := _props()
	if files.is_empty():
		print("no props cached locally - nothing to compare"); quit(1); return
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
	# _pf holds live Nodes, so it is released, never cleared: a bare clear()
	# would leak every scene still sitting in it
	mc._pf_release()
	t = Time.get_ticks_msec()
	await mc._prefetch(files)
	var t_pf := Time.get_ticks_msec() - t
	var claimed: int = mc._pf.size()
	var pre: Array = []
	for p in files:
		mc._mesh_cache.clear()
		pre.append(await mc._parse_prop_file(str(p)))
	var t_total := Time.get_ticks_msec() - t

	print("direct (main thread)      : %6d ms   (%.1f ms each)"
		% [t_direct, float(t_direct) / files.size()])
	print("prefetch on workers       : %6d ms" % t_pf)
	print("prefetch + consume        : %6d ms   (%.1f ms each)  speedup %.2fx"
		% [t_total, float(t_total) / files.size(),
			float(t_direct) / maxf(1.0, float(t_total))])
	print("")

	_check("prefetched every file (%d)" % files.size(), pre.size() == files.size())
	_check("every file was waiting in the cache (%d of %d)" % [claimed, files.size()],
		claimed == files.size())
	_check("the placement loop drains the cache", mc._pf.is_empty())
	# the whole point of the feature: if this ever goes green-but-equal again,
	# the hand-off has regressed back into a serialise/deserialise round trip
	_check("prefetching beats not prefetching (%.1f vs %.1f ms each)"
		% [float(t_total) / files.size(), float(t_direct) / files.size()],
		t_total * 4 <= t_direct * 3)

	var same_count := 0
	var same_tris := 0
	var same_surf := 0
	var textured := 0
	var tangents := 0
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
			if _tangents(mb):
				tangents += 1
	_check("same number of meshes per prop", same_count == files.size())
	_check("same surface counts (%d)" % same_surf, same_surf >= files.size())
	_check("same triangle counts (%d)" % same_tris, same_tris >= files.size())
	_check("prefetched props still have COMPRESSED textures (%d)" % textured, textured > 0)
	# the WORKER generates the tangents now; losing them would not error, it
	# would just light normal-mapped props wrong
	_check("prefetched props still have tangents (%d)" % tangents, tangents > 0)

	mc._pf_release()
	_check("_pf_release empties the cache", mc._pf.is_empty())

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _props() -> Array:
	var base := OS.get_environment("APPDATA") + "/Godot/app_userdata/Battlefield™ Portal Project"
	var dirs: Array = []
	# "-- <dir>" runs this against a fixed sample instead: the live prop cache is
	# whatever the last session happened to download, and a purge empties it
	for a in OS.get_cmdline_user_args():
		dirs.append(str(a))
	dirs.append_array([base + "/mapcontext/_props", base + "/mapcontext/MP_Dumbo/props"])
	for d in dirs:
		var da := DirAccess.open(str(d))
		if da == null:
			continue
		var out: Array = []
		for f in da.get_files():
			if f.ends_with(".glb"):
				out.append(str(d) + "/" + f)
		if not out.is_empty():
			out.sort()
			return out
	return []


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


func _tangents(m: Mesh) -> bool:
	for s in range(m.get_surface_count()):
		var a := m.surface_get_arrays(s)
		if a.is_empty(): continue
		return a[Mesh.ARRAY_TANGENT] != null
	return false


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
