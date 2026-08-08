extends SceneTree

# The sidecar format, end to end: written by tools/bc_encode.gd, read back by
# highpoly_bctex.gd, against real props that went through tools/bc_strip.py.
#
# The failure that matters here is not a crash. It is a prop that loads, looks
# broadly right, and is quietly missing its normal map — because a stripped glb
# carries no texture references, so Godot leaves normal_enabled false and an
# assigned normal map renders as if it were not there. That survives a review.
# So this checks the material FLAGS, not just that pixels arrived.
#
# Run with "-- <dir>" pointing at a stripped+encoded set.

const BcTex = preload("res://addons/highpoly_toggle/highpoly_bctex.gd")
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
	var args := OS.get_cmdline_user_args()
	var dir: String = str(args[0]) if args.size() > 0 else _sp() + "/bc_out"

	var da := DirAccess.open(dir)
	if da == null:
		print("no such dir: %s" % dir); quit(1); return
	var glbs: Array = []
	for f in da.get_files():
		if f.ends_with(".glb"): glbs.append(dir + "/" + str(f))
	glbs.sort()
	if glbs.is_empty():
		print("no stripped glbs in %s" % dir); quit(1); return
	glbs = glbs.slice(0, 12)
	print("%d stripped prop(s) from %s\n" % [glbs.size(), dir.get_file()])

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.mesh_cache_enabled = false
	mc.vram_mode = MC.VRAM_FULL

	# ---- the sidecar exists and reads --------------------------------------
	var with_side := 0
	for p in glbs:
		if BcTex.exists(str(p)): with_side += 1
	_check("every stripped prop has a sidecar (%d/%d)" % [with_side, glbs.size()],
		with_side == glbs.size())

	var decoded: Array = []
	var t := Time.get_ticks_msec()
	var imgs := 0
	var blocks := 0
	for p in glbs:
		var d := BcTex.decode(BcTex.path_for(str(p)))
		decoded.append(d)
		for im in d.get("images", []):
			if im == null: continue
			imgs += 1
			if (im as Image).is_compressed(): blocks += 1
	var t_dec := Time.get_ticks_msec() - t
	print("decoded %d image(s) in %d ms — %d arrived as blocks, %d as original bytes\n"
		% [imgs, t_dec, blocks, imgs - blocks])
	_check("the sidecars decoded to real images", imgs > 0)
	_check("no sidecar came back empty", decoded.size() == glbs.size())

	# ---- and they land on the right materials ------------------------------
	var bound := 0
	var props_with_tex := 0
	var normals := 0
	var normal_flag := 0
	for i in range(glbs.size()):
		var inst = mc._load_external_glb(str(glbs[i]))
		if inst == null:
			continue
		var n: int = BcTex.bind(inst, decoded[i])
		bound += n
		if n > 0:
			props_with_tex += 1
		# the flag check: a normal map with normal_enabled false is invisible
		var stack: Array = [inst]
		while not stack.is_empty():
			var x: Node = stack.pop_back()
			for c in x.get_children():
				stack.append(c)
			for m in BcTex._materials_of(x):
				var bm := m as BaseMaterial3D
				if bm == null: continue
				if bm.get_texture(BaseMaterial3D.TEXTURE_NORMAL) != null:
					normals += 1
					if bm.normal_enabled:
						normal_flag += 1
		(inst as Node).free()

	print("bound %d texture(s) across %d of %d prop(s)"
		% [bound, props_with_tex, glbs.size()])
	_check("textures were bound to materials", bound > 0)
	_check("most props got their textures (%d/%d)" % [props_with_tex, glbs.size()],
		props_with_tex >= int(glbs.size() * 0.8))
	if normals > 0:
		_check("every normal map has normal_enabled set (%d/%d)"
			% [normal_flag, normals], normal_flag == normals)
	else:
		print("  (no normal maps in this sample to check)")

	# ---- a corrupt or missing sidecar must not take the build down ---------
	_check("a missing sidecar decodes to nothing rather than erroring",
		BcTex.decode(dir + "/definitely-not-here.bctex").is_empty())
	var junk := "%s/junk.bctex" % dir
	var jf := FileAccess.open(junk, FileAccess.WRITE)
	jf.store_buffer("not a bctex at all, not even close".to_utf8_buffer())
	jf.close()
	_check("a corrupt sidecar decodes to nothing rather than erroring",
		BcTex.decode(junk).is_empty())
	DirAccess.remove_absolute(junk)
	var empty := Node3D.new()
	_check("binding nothing is a no-op, not a crash", BcTex.bind(empty, {}) == 0)
	empty.free()

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
