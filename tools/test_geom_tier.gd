extends SceneTree

# The pipeline now bakes the geometry the client used to bake itself, and the
# client loads it instead of parsing a glb. That is a real speedup and a real
# risk: if the shipped file is not EQUIVALENT to what parsing would have
# produced, maps look different depending on which files a user happens to have,
# and nobody would trace that back to here.
#
# So the important test is not "is it faster" — it is:
#
#   same surfaces, same vertices, same materials
#   textures still land on it (the .bctex binds to MESHES now, not to a scene)
#   a missing or corrupt bake falls back to the glb instead of showing a
#   fragment, because a bad file must cost a parse and never a broken prop
#
# Run with "-- <dir of stripped glbs with .bctex> <count>".

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const SP := "C:/Users/mwalt/AppData/Local/Temp/claude/C--Users-mwalt/9b036b50-aae1-4310-8139-063d65d55375/scratchpad"

const _SLOTS := [
	BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
	BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC,
	BaseMaterial3D.TEXTURE_EMISSION, BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION,
]

var fails := 0


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var dir: String = str(a[0]) if a.size() > 0 else SP + "/bc_out"
	var n := int(str(a[1])) if a.size() > 1 else 40

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.vram_mode = MC.VRAM_COMPRESSED
	mc.mesh_cache_enabled = false

	var files := _glbs(dir)
	files = files.slice(0, n)
	if files.is_empty():
		print("no glbs in %s" % dir); quit(1); return
	for p in files:
		_wipe(str(p))
	print("%d prop(s) from %s\n" % [files.size(), dir.get_file()])

	# ---- 1. what parsing the glb produces, which is the reference ---------
	var ref := {}
	var t := Time.get_ticks_msec()
	for p in files:
		mc._mesh_cache.clear()
		ref[str(p)] = _shape(await mc._parse_prop_file(str(p)))
	var glb_ms := Time.get_ticks_msec() - t

	# ---- 2. bake, the way the pipeline does ------------------------------
	MC.bake_geometry_only = true
	var baked := 0
	for p in files:
		mc._mesh_cache.clear()
		var meshes = await mc._parse_prop_file(str(p))
		if not (meshes is Array) or (meshes as Array).is_empty():
			continue
		var live: Array = []
		for m in meshes:
			if m is ArrayMesh:
				for s in range((m as ArrayMesh).get_surface_count()):
					var bm := (m as ArrayMesh).surface_get_material(s) as BaseMaterial3D
					if bm != null:
						for slot in _SLOTS:
							bm.set_texture(slot, null)
				live.append(m)
		if live.is_empty():
			continue
		if live.size() > 1:
			for k in range(live.size()):
				ResourceSaver.save(live[k], str(p) + ".geom.p%d.res" % k,
					ResourceSaver.FLAG_COMPRESS)
		else:
			ResourceSaver.save(live[0], str(p) + ".geom.res",
				ResourceSaver.FLAG_COMPRESS)
		baked += 1
	MC.bake_geometry_only = false
	_check("the bake writes a file for every prop (%d of %d)"
		% [baked, files.size()], baked == files.size())

	# ---- 3. what the client now loads -------------------------------------
	var got := {}
	t = Time.get_ticks_msec()
	for p in files:
		mc._mesh_cache.clear()
		got[str(p)] = _shape(await mc._parse_prop_file(str(p)))
	var geom_ms := Time.get_ticks_msec() - t

	# ---- 4. and it has to be the SAME PROP --------------------------------
	var surf := 0
	var verts := 0
	var mats := 0
	var tex := 0
	var tex_any := 0
	for p in files:
		var r: Dictionary = ref[str(p)]
		var g: Dictionary = got[str(p)]
		if int(r["surfaces"]) == int(g["surfaces"]): surf += 1
		if int(r["verts"]) == int(g["verts"]): verts += 1
		if int(r["mats"]) == int(g["mats"]): mats += 1
		if int(r["tex"]) == int(g["tex"]): tex += 1
		if int(g["tex"]) > 0: tex_any += 1

	var nf := files.size()
	_check("same surface count (%d of %d)" % [surf, nf], surf == nf)
	_check("same vertex count (%d of %d)" % [verts, nf], verts == nf)
	_check("same material count (%d of %d)" % [mats, nf], mats == nf)
	_check("same textures bound (%d of %d)" % [tex, nf], tex == nf)
	# If NOTHING is textured the comparison above passes trivially — 0 == 0 for
	# every prop — and would keep passing if bind_meshes silently did nothing.
	_check("and textures actually landed on the meshes (%d of %d props)"
		% [tex_any, nf], tex_any > 0)

	print("\n  parse glb    %6.2f s" % (glb_ms / 1000.0))
	print("  load  geom   %6.2f s   -> %.1fx"
		% [geom_ms / 1000.0, float(glb_ms) / maxf(1.0, float(geom_ms))])
	# NOT "strictly faster". On a corpus of small props the two are a coin toss
	# — 0.98 s against 0.99 s on props_sample — and a test that fails on noise
	# teaches everyone to ignore it. The speedup is real and is measured where
	# it can be measured honestly, on full-size props with the prefetch running
	# (1.94x). What matters here is that the bake never costs MORE, which is
	# what a broken bake path would look like.
	_check("and the shipped bake is not slower than parsing (%.2fx)"
		% (float(glb_ms) / maxf(1.0, float(geom_ms))),
		geom_ms <= glb_ms * 1.15)

	# ---- 5. a bad file must cost a parse, never a broken prop -------------
	var victim := str(files[0])
	_wipe(victim)
	var f := FileAccess.open(victim + ".geom.res", FileAccess.WRITE)
	f.store_string("this is not a Godot resource")
	f.close()
	mc._mesh_cache.clear()
	var rec = await mc._parse_prop_file(victim)
	var r0: Dictionary = ref[victim]
	_check("a corrupt bake falls back to the glb and the prop is whole",
		rec is Array and _shape(rec)["verts"] == int(r0["verts"]))

	_wipe(victim)
	mc._mesh_cache.clear()
	var miss = await mc._parse_prop_file(victim)
	_check("and so does a missing one",
		miss is Array and _shape(miss)["verts"] == int(r0["verts"]))

	for p in files:
		_wipe(str(p))
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _shape(meshes) -> Dictionary:
	var out := {"surfaces": 0, "verts": 0, "mats": 0, "tex": 0}
	if not (meshes is Array):
		return out
	for m in meshes:
		var am := m as ArrayMesh
		if am == null:
			continue
		out["surfaces"] = int(out["surfaces"]) + am.get_surface_count()
		for s in range(am.get_surface_count()):
			var arr := am.surface_get_arrays(s)
			if not arr.is_empty() and arr[Mesh.ARRAY_VERTEX] != null:
				out["verts"] = int(out["verts"]) \
					+ (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var bm := am.surface_get_material(s) as BaseMaterial3D
			if bm == null:
				continue
			out["mats"] = int(out["mats"]) + 1
			for slot in _SLOTS:
				if bm.get_texture(slot) != null:
					out["tex"] = int(out["tex"]) + 1
	return out


func _wipe(gp: String) -> void:
	if FileAccess.file_exists(gp + ".geom.res"):
		DirAccess.remove_absolute(gp + ".geom.res")
	var i := 0
	while FileAccess.file_exists(gp + ".geom.p%d.res" % i):
		DirAccess.remove_absolute(gp + ".geom.p%d.res" % i)
		i += 1


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
	if not ok: fails += 1
