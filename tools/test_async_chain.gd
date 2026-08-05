extends SceneTree

# Making _compress_textures yield turned _parse_prop_file and _prop_mesh into
# coroutines. A caller that forgets `await` gets a GDScriptFunctionState instead
# of an Array of meshes — no error, no crash, just props that silently never
# appear. A parse check cannot see that, so check the real return value.
#
# Builds its own GLB rather than relying on downloaded assets: the store is
# wiped before every performance test, and a test that quietly skips itself is
# worse than no test. Two mesh nodes, so the MERGE path is the one exercised.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var path := _make_glb()
	if path == "":
		print("could not build the test GLB"); quit(1); return
	print("test asset: %s (%d bytes)" % [path, FileAccess.get_file_as_bytes(path).size()])

	var mc = MC.new()
	root.add_child(mc)
	await process_frame
	mc.vram_mode = MC.VRAM_COMPRESSED
	mc.mesh_cache_enabled = false          # exercise the parse, not the sidecar

	var t0 := Time.get_ticks_msec()
	var r = await mc._parse_prop_file(ProjectSettings.globalize_path(path))
	var ms := Time.get_ticks_msec() - t0

	_check("_parse_prop_file returns an Array when awaited (got %s)"
		% type_string(typeof(r)), r is Array)
	var got_mesh: bool = r is Array and r.size() > 0 and r[0] is Mesh
	_check("and it contains a real Mesh, not a coroutine", got_mesh)
	if got_mesh:
		var m: Mesh = r[0]
		_check("the merged mesh has surfaces (%d)" % m.get_surface_count(),
			m.get_surface_count() > 0)
		var compressed := 0
		for s in range(m.get_surface_count()):
			var bm := m.surface_get_material(s) as BaseMaterial3D
			if bm == null: continue
			var t := bm.get_texture(BaseMaterial3D.TEXTURE_ALBEDO)
			if t != null and t.get_image() != null and t.get_image().is_compressed():
				compressed += 1
		_check("its textures came back COMPRESSED (%d surface(s))" % compressed,
			compressed > 0)

	var n = await mc._compress_textures(r[0] if got_mesh else null)
	_check("_compress_textures returns an int when awaited (%s)" % str(n),
		typeof(n) == TYPE_INT)
	print("   parse took %d ms" % ms)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


# two textured boxes at different transforms -> forces the multi-node merge
func _make_glb() -> String:
	var rootn := Node3D.new()
	for i in range(2):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var mat := StandardMaterial3D.new()
		var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.2 + 0.3 * i, 0.5, 0.8))
		mat.albedo_texture = ImageTexture.create_from_image(img)
		bm.material = mat
		mi.mesh = bm
		mi.position = Vector3(i * 3.0, 0, 0)
		mi.name = "part%d" % i
		rootn.add_child(mi)
		mi.owner = rootn
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_scene(rootn, st) != OK:
		return ""
	var buf := doc.generate_buffer(st)
	rootn.free()
	if buf.is_empty():
		return ""
	var p := "user://asynctest.glb"
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(buf)
	f.close()
	return p


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
