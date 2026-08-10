@tool
extends SceneTree
# The high-definition ground bake, end to end on the real install:
#   1. the inline terrain shader (with the new bilinear splat path) PARSES
#   2. terrain_surface on an 8 km map bakes a 4096 splat raster at v4
#   3. layer slices come out at 1024 px
#   4. the loader's compress-then-array path builds a real Texture2DArray

func _init() -> void:
	var fails := 0
	# 1. shader parse - the terrain shader is an inline string, so the shader
	# gate never sees it; a typo here would only appear in a user's editor.
	var consts: Dictionary = (load("res://addons/highpoly_toggle/highpoly_mapcontext.gd") as GDScript).get_script_constant_map()
	var sh := Shader.new()
	sh.code = str(consts["TERRAIN_SHADER"])
	var uniforms := sh.get_shader_uniform_list()
	print("terrain shader: %d uniforms after parse" % uniforms.size())
	if uniforms.size() < 10:
		print("FAIL the terrain shader did not parse (uniform list empty)")
		fails += 1

	# 2+3. the bake, forced, on the 8 km specimen
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath"):
		print("no source: ", gs.error)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var meta: Dictionary = gs.terrain_surface("user://hdtest", true)
	print("terrain_surface in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if meta.is_empty():
		print("FAIL surface bake returned {}")
		quit(1)
		return
	if int(meta.get("splat_v", 0)) != 4:
		print("FAIL splat_v is %s, wanted 4" % str(meta.get("splat_v")))
		fails += 1
	var idx := Image.load_from_file(ProjectSettings.globalize_path("user://hdtest/splat/idx.png"))
	print("idx.png: %dx%d  [8 km map at 2 m/texel = 4096]" % [idx.get_width(), idx.get_height()])
	if idx.get_width() != 4096:
		print("FAIL splat raster is not 4096 on an 8 km map")
		fails += 1
	var alb := Image.load_from_file(ProjectSettings.globalize_path("user://hdtest/splat/l00_alb.png"))
	print("l00_alb.png: %dx%d  [wanted 1024]" % [alb.get_width(), alb.get_height()])
	if alb.get_width() != 1024:
		print("FAIL layer slice is not 1024")
		fails += 1

	# 4. the loader's compression path: mipmap + S3TC + array build
	var slices := int(meta.get("slices", 0))
	var imgs: Array[Image] = []
	for i in range(slices):
		var im := Image.load_from_file(ProjectSettings.globalize_path("user://hdtest/splat/l%02d_alb.png" % i))
		if im == null:
			continue
		im.convert(Image.FORMAT_RGB8)
		if im.get_width() != 1024 or im.get_height() != 1024:
			im.resize(1024, 1024, Image.INTERPOLATE_LANCZOS)
		im.generate_mipmaps()
		im.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
		imgs.append(im)
	var ta := Texture2DArray.new()
	var e := ta.create_from_images(imgs)
	print("compressed array: %d slices, err %d, layers %d, format %d"
		% [imgs.size(), e, ta.get_layers(), imgs[0].get_format() if imgs.size() > 0 else -1])
	if e != OK or ta.get_layers() != imgs.size() or imgs.is_empty():
		print("FAIL compressed Texture2DArray did not build")
		fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
