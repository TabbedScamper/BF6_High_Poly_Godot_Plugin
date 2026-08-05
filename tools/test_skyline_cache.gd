extends SceneTree

# The heaviest backdrops split into several meshes, and a split prop used to get
# NO sidecar at all — so the whole skyline re-parsed on every single build, warm
# or cold. This checks the numbered-part cache actually takes effect, and that
# what comes back is the same geometry rather than a fragment.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const N := 8

var fails := 0


func _init() -> void:
	await process_frame
	var mc = MC.new()
	root.add_child(mc)
	await process_frame
	mc.mesh_cache_enabled = true
	mc.vram_mode = MC.VRAM_COMPRESSED

	var base := OS.get_environment("APPDATA") + "/Godot/app_userdata/Battlefield™ Portal Project"
	var dir := base + "/mapcontext/MP_Dumbo/backdrop"
	var da := DirAccess.open(dir)
	if da == null:
		print("no backdrop dir"); quit(1); return
	var all: Array = []
	for f in da.get_files():
		if f.ends_with(".glb"): all.append(dir + "/" + f)
	all.sort_custom(func(a, b): return _sz(str(a)) > _sz(str(b)))
	var files: Array = all.slice(0, N)

	# start from nothing cached
	for p in files:
		var i := 0
		while FileAccess.file_exists(str(p) + mc._part_suffix(i)):
			DirAccess.remove_absolute(str(p) + mc._part_suffix(i))
			i += 1
		if FileAccess.file_exists(str(p) + mc._baked_suffix()):
			DirAccess.remove_absolute(str(p) + mc._baked_suffix())

	# --- first build ---------------------------------------------------------
	var t := Time.get_ticks_msec()
	var first: Array = []
	var split := 0
	for p in files:
		mc._mesh_cache.clear()
		var r = await mc._parse_prop_file(str(p))
		first.append(r)
		if r is Array and r.size() > 1: split += 1
	var cold := Time.get_ticks_msec() - t

	var cached := 0
	for p in files:
		if FileAccess.file_exists(str(p) + mc._part_suffix(0)) \
				or FileAccess.file_exists(str(p) + mc._baked_suffix()):
			cached += 1

	# --- second build --------------------------------------------------------
	t = Time.get_ticks_msec()
	var second: Array = []
	for p in files:
		mc._mesh_cache.clear()
		second.append(await mc._parse_prop_file(str(p)))
	var warm := Time.get_ticks_msec() - t

	print("%d heaviest backdrops, %d of them split into several meshes\n" % [files.size(), split])
	print("  first build  %7.2fs  (%5.0f ms each)" % [cold / 1000.0, float(cold) / files.size()])
	print("  second build %7.2fs  (%5.0f ms each)" % [warm / 1000.0, float(warm) / files.size()])
	print("  cached: %d of %d files\n" % [cached, files.size()])

	_check("every file now caches (split ones included)", cached == files.size())
	_check("the second build is at least 2x faster", warm * 2 <= cold)

	var same := 0
	var tris_ok := 0
	for i in range(files.size()):
		var a = first[i]
		var b = second[i]
		if a is Array and b is Array and a.size() == b.size():
			same += 1
			var ta := 0
			var tb := 0
			for m in a: ta += _tris(m)
			for m in b: tb += _tris(m)
			if ta == tb: tris_ok += 1
	_check("same mesh count back from the cache (%d)" % same, same == files.size())
	_check("same triangle count back from the cache (%d)" % tris_ok, tris_ok == files.size())

	if warm > 0:
		print("\n  scaled to a 155-file skyline: %.0f s first, %.0f s after"
			% [float(cold) / files.size() * 155 / 1000.0,
				float(warm) / files.size() * 155 / 1000.0])
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _tris(m) -> int:
	var mesh := m as Mesh
	if mesh == null: return 0
	var t := 0
	for s in range(mesh.get_surface_count()):
		var a := mesh.surface_get_arrays(s)
		if a.is_empty(): continue
		if a[Mesh.ARRAY_INDEX] != null:
			t += (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		elif a[Mesh.ARRAY_VERTEX] != null:
			t += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


func _sz(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null: return 0
	var n := f.get_length(); f.close(); return n


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
