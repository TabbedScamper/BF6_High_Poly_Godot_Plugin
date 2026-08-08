extends SceneTree
# Two things in sky_sun.gdshader can be silently wrong, and both look like
# "the sun did not draw" rather than like an error:
#   1. the panorama mapping, if it disagrees with PanoramaSkyMaterial the sky is
#      rotated half a turn and nothing complains
#   2. the sign of LIGHT0_DIRECTION, which puts the disc at the ANTISOLAR point,
#      below the horizon on a daytime sky, i.e. invisible
# So: render both materials and compare, then look for the disc where the sun is
# and confirm it is absent where it is not.
var fails: Array = []
func ck(c: bool, w: String) -> void:
	print(("  ok   " if c else "  FAIL ") + w)
	if not c: fails.append(w)

var _vp: SubViewport
var _cam: Camera3D
var _env: Environment
var _sun: DirectionalLight3D

func shoot(dir: Vector3) -> Color:
	_cam.look_at_from_position(Vector3.ZERO, dir, Vector3.UP)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)

var _ran := false

func _process(_d: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false

func _run() -> void:
	# a recognisable panorama: a horizontal gradient so a half-turn shift shows
	var pano := Image.create_empty(256, 128, false, Image.FORMAT_RGBF)
	for y in range(128):
		for x in range(256):
			pano.set_pixel(x, y, Color(float(x) / 255.0, float(y) / 127.0, 0.25))
	var ptex := ImageTexture.create_from_image(pano)

	_vp = SubViewport.new()
	_vp.size = Vector2i(64, 64)
	_vp.transparent_bg = false
	get_root().add_child(_vp)
	_cam = Camera3D.new(); _vp.add_child(_cam); _cam.current = true
	var world := _vp.world_3d
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_env.tonemap_exposure = 1.0
	_cam.environment = _env
	_sun = DirectionalLight3D.new(); _vp.add_child(_sun)

	# --- 1. mapping matches PanoramaSkyMaterial ---
	var sky := Sky.new()
	var pm := PanoramaSkyMaterial.new()
	pm.panorama = ptex; pm.filter = true; pm.energy_multiplier = 1.0
	sky.sky_material = pm
	_env.sky = sky
	_sun.visible = false
	var dirs := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
	var ref: Array = []
	for d in dirs: ref.append(await shoot(d))

	var sm := ShaderMaterial.new()
	sm.shader = load("res://addons/highpoly_toggle/sky_sun.gdshader")
	sm.set_shader_parameter("panorama", ptex)
	sm.set_shader_parameter("energy_multiplier", 1.0)
	sm.set_shader_parameter("sun_intensity", 0.0)
	sm.set_shader_parameter("halo_intensity", 0.0)
	sky.sky_material = sm
	var mine: Array = []
	for d in dirs: mine.append(await shoot(d))

	print("\n--- panorama mapping vs PanoramaSkyMaterial ---")
	var worst := 0.0
	for i in range(dirs.size()):
		var a: Color = ref[i]; var b: Color = mine[i]
		var e: float = maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))
		worst = maxf(worst, e)
		print("   %s  panorama %s  ours %s  diff %.4f"
			% [str(dirs[i]), str(a).substr(0, 22), str(b).substr(0, 22), e])
	ck(worst < 0.02, "mapping matches on all four compass directions (worst %.4f)" % worst)

	# --- 2. the sun is where the light points FROM ---
	# Dim the sky for this half: a saturated disc cannot exceed a near-white sky
	# in an LDR readback, so the first version of this test failed on a correct
	# shader. Compare against a dark sky instead.
	sm.set_shader_parameter("energy_multiplier", 0.06)
	sm.set_shader_parameter("sun_intensity", 12.0)
	sm.set_shader_parameter("sun_size_deg", 6.0)   # generous, so a 64px shot lands on it
	sm.set_shader_parameter("halo_intensity", 0.0)
	_sun.visible = true
	_sun.light_energy = 1.0
	_sun.light_color = Color(1, 1, 1)
	# put the sun toward +X: the light TRAVELS toward -X
	var toward_sun := Vector3(1, 0.35, 0).normalized()
	_sun.look_at_from_position(Vector3.ZERO, -toward_sun, Vector3.UP)
	var at_sun := await shoot(toward_sun)
	var away := await shoot(-toward_sun)
	print("\n--- sun disc ---")
	print("   looking AT the sun:   ", at_sun)
	print("   looking AWAY:         ", away)
	ck(at_sun.r > away.r + 0.5, "the disc is where the sun is, not at the antisolar point")
	ck(at_sun.r > 0.9, "and it is actually bright")
	ck(away.r < 0.5, "the sky away from it is the panorama, not disc spill")

	print("\n%s  (%d failure(s))" % ["PASS" if fails.is_empty() else "FAILED", fails.size()])
	quit(0 if fails.is_empty() else 1)
