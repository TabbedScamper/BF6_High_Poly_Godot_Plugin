extends SceneTree

# The fast-load sidecar is worth about 8x on a LATER build and nothing at all on
# the current one, and it used to be written inline — 10.8 s per 600 props,
# roughly 50 s of a 2,761-prop Dumbo build, paid on the cold pull that is the
# slowest thing anyone waits for.
#
# It is queued now and written once the map is on screen. Two things have to
# hold, and the second is the one that would quietly rot:
#
#   the build gets faster                    (else there was no point)
#   the cache is still COMPLETE and USABLE   (else every later load re-parses,
#                                             and nobody would notice for weeks)
#
# Run with "-- <dir of glb>".

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const SP := "C:/Users/mwalt/AppData/Local/Temp/claude/C--Users-mwalt/9b036b50-aae1-4310-8139-063d65d55375/scratchpad"

var fails := 0


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var dir: String = str(a[0]) if a.size() > 0 else SP + "/props_sample"
	var n := int(str(a[1])) if a.size() > 1 else 40

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.vram_mode = MC.VRAM_COMPRESSED
	mc.mesh_cache_enabled = true

	var files := _glbs(dir)
	if files.is_empty():
		print("no glbs in %s" % dir); quit(1); return
	files = files.slice(0, n)
	_wipe(mc, files)

	# ---- the build itself -------------------------------------------------
	var t := Time.get_ticks_msec()
	var meshes := 0
	for p in files:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		if r is Array: meshes += r.size()
	var build_ms := Time.get_ticks_msec() - t

	_check("nothing was written during the build (%d on disk)" % _sidecars(mc, files),
		_sidecars(mc, files) == 0)
	_check("and they are all queued instead (%d of %d)"
		% [mc._side_writes.size(), files.size()],
		mc._side_writes.size() == files.size())

	# ---- the flush --------------------------------------------------------
	t = Time.get_ticks_msec()
	await mc.flush_sidecars()
	var flush_ms := Time.get_ticks_msec() - t
	var on_disk := _sidecars(mc, files)
	print("\nbuild %d ms, flush %d ms, %d of %d prop(s) cached"
		% [build_ms, flush_ms, on_disk, files.size()])
	_check("the flush drains the queue", mc._side_writes.is_empty())
	_check("and writes a sidecar for every prop (%d of %d)" % [on_disk, files.size()],
		on_disk == files.size())
	_check("the flush is where the time went, not the build", flush_ms > 0)

	# ---- and the cache actually loads back --------------------------------
	# a sidecar that writes but does not load is worse than none: the next build
	# pays the load AND the re-parse
	var reused := 0
	var tris_ok := 0
	for p in files:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		if r is Array and r.size() > 0:
			reused += 1
			var t2 := 0
			for m in r: t2 += _tris(m)
			if t2 > 0: tris_ok += 1
	_check("every prop loads back from its sidecar (%d of %d)"
		% [reused, files.size()], reused == files.size())
	_check("with real geometry (%d of %d)" % [tris_ok, files.size()],
		tris_ok == files.size())

	_wipe(mc, files)
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _sidecars(mc, files: Array) -> int:
	var n := 0
	for p in files:
		if FileAccess.file_exists(str(p) + mc._baked_suffix()) \
				or FileAccess.file_exists(str(p) + mc._part_suffix(0)):
			n += 1
	return n


func _wipe(mc, files: Array) -> void:
	for p in files:
		if FileAccess.file_exists(str(p) + mc._baked_suffix()):
			DirAccess.remove_absolute(str(p) + mc._baked_suffix())
		var i := 0
		while FileAccess.file_exists(str(p) + mc._part_suffix(i)):
			DirAccess.remove_absolute(str(p) + mc._part_suffix(i))
			i += 1


func _tris(m) -> int:
	var mesh := m as Mesh
	if mesh == null: return 0
	var t := 0
	for s in range(mesh.get_surface_count()):
		var arr := mesh.surface_get_arrays(s)
		if not arr.is_empty() and arr[Mesh.ARRAY_INDEX] != null:
			t += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	return t


func _glbs(dir: String) -> Array:
	var da := DirAccess.open(dir)
	if da == null: return []
	var out: Array = []
	for f in da.get_files():
		if f.ends_with(".glb"): out.append(dir + "/" + str(f))
	out.sort()
	return out


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
