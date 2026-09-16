extends SceneTree
# Native water surface checks with real/perturbed controls.
# godot --headless -s tools/test_native_water_surface.gd -- [--level=NAME] [--game=PATH]

var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func _script_dir() -> String:
	for base in ["res://addons/highpoly_toggle/", "res://"]:
		if ResourceLoader.exists(base + "highpoly_native_water.gd"): return base
	return ""

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func run() -> void:
	var level := "mp_granite_clubhouse_portal"
	var game := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--level="): level = arg.substr(8)
		if arg.begins_with("--game="): game = arg.substr(7)
	var dir := _script_dir()
	if dir.is_empty():
		push_error("highpoly_native_water.gd not found"); quit(1); return
	var Env: GDScript = load(dir + "bf6_environment.gd")
	var Water: GDScript = load(dir + "highpoly_native_water.gd")
	if Env == null or Water == null or not Env.can_instantiate() or not Water.can_instantiate():
		push_error("environment scripts failed to compile"); quit(1); return
	var shader: Shader = load(dir + "water_native.gdshader")
	check(shader != null and not shader.get_shader_uniform_list().is_empty(), "shader loads and exposes uniforms")
	var core: Object = ClassDB.instantiate("BF6Core")
	if core == null or not core.call("open", game):
		push_error("core open failed"); quit(1); return
	var env: Object = Env.new(core, level)
	var water: Dictionary = env.call("read_water")
	check(not water.is_empty(), "water metadata read")

	# Frame shape, determinism after rewind (real) and time perturbation (control).
	var f0: Dictionary = env.call("request", "water_frame", 0)
	var f1: Dictionary = env.call("request", "water_frame", 33)
	var f0b: Dictionary = env.call("request", "water_frame", 0)
	var count := int(f0.get("count", 0))
	var resolutions: Array = f0.get("resolutions", [])
	for i in range(count):
		var res := int(resolutions[i])
		var d: PackedByteArray = f0.get("displacement%d" % i, PackedByteArray())
		var n: PackedByteArray = f0.get("normal%d" % i, PackedByteArray())
		check(d.size() == res * res * 16 and n.size() == res * res * 16, "cascade %d byte sizes" % i)
		check(is_equal_approx(n.decode_float(12), 1.0), "cascade %d normal alpha is 1" % i)
		check(d == f0b.get("displacement%d" % i), "cascade %d rewind to t=0 reproduces bytes" % i)
		var next: PackedByteArray = f1.get("displacement%d" % i, PackedByteArray())
		var energy := 0.0
		for offset in range(0, d.size(), 4): energy = maxf(energy, absf(d.decode_float(offset)))
		if energy > 0.000000001:
			check(d != next, "cascade %d control: t=33ms differs" % i)
		else:
			var next_energy := 0.0
			for offset in range(0, next.size(), 4): next_energy = maxf(next_energy, absf(next.decode_float(offset)))
			check(next_energy <= 0.000000001, "cascade %d authored zero spectrum stays flat" % i)

	# Height decode: RG8 raw bytes equal decode_u16; byte-swapped control differs.
	var wh: Dictionary = env.get("water_height")
	var hb: Dictionary = Water.call("height_image", wh, true)
	if hb.has("image"):
		var image: Image = hb["image"]
		var heights: PackedByteArray = wh["heights"]
		var w := int(wh["width"])
		var probe := -1
		for k in range(0, heights.size() / 2, maxi(1, heights.size() / 2 / 4096)):
			if heights.decode_u16(k * 2) >> 8 != heights.decode_u16(k * 2) & 255: probe = k; break
		if probe >= 0 and w <= 16384:
			var c := image.get_pixel(probe % w, probe / w)
			var raw := roundi(c.r * 255.0) + 256 * roundi(c.g * 255.0)
			var swapped := roundi(c.g * 255.0) + 256 * roundi(c.r * 255.0)
			check(raw == heights.decode_u16(probe * 2), "water height RG8 decode matches uint16 LE")
			check(swapped != heights.decode_u16(probe * 2), "control: byte-swapped decode differs")
	else:
		print("INFO water height unavailable: %s" % str(hb.get("reason", "")))
	var zero_grid := {"present": 1, "width": 2, "height": 2, "world_min": [0, 0, 0], "world_max": [1, 1, 1],
		"height_scale": 100.0, "heights": PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])}
	check(not (Water.call("height_image", zero_grid, true) as Dictionary).has("image"), "all-zero water grid rejected")

	# Mask indirection: raw RGBA8 unpack equals the uint32 fields.
	var mask: Dictionary = env.get("mask")
	if int(mask.get("present", 0)) == 1:
		var ind: PackedByteArray = mask["indirection"]
		var inline_seen := 0
		for k in range(0, ind.size() / 4, maxi(1, ind.size() / 4 / 512)):
			var v := ind.decode_u32(k * 4)
			var lo := v & 0xffff
			if lo >= 0x8000: inline_seen += 1
			if ind[k * 4] != lo & 255 or (ind[k * 4 + 1] >= 128) != (lo >= 0x8000) or (ind[k * 4 + 2] & 31) != ((v >> 16) & 31):
				failures.append("mask cell %d unpack mismatch" % k)
		print("INFO mask inline cells sampled: %d" % inline_seen)
	else:
		print("INFO mask absent: %s" % str(mask.get("reason", "")))

	# Materials and driver.
	var parent := Node3D.new()
	root.add_child(parent)
	var materials: Array = []
	for surface_value in water.get("surfaces", []):
		var surface: Dictionary = (surface_value as Dictionary).duplicate()
		surface["native"] = true
		var mat: ShaderMaterial = Water.call("material", surface, env)
		check(mat.shader != null, "material has shader")
		print("INFO diagnostics: %s" % str(mat.get_meta(&"bf6_water_diagnostics", PackedStringArray())))
		materials.append(mat)
	var driver: Node = Water.call("attach", parent, env, materials)
	check(driver.get_parent() == parent and driver.owner == null, "driver attached without owner")
	var start := Time.get_ticks_msec()
	var simulated: Array = []
	for m in materials:
		var sm: ShaderMaterial = m
		if bool(sm.get_meta(&"bf6_water_simulated", false)): simulated.append(sm)
		else: check(float(sm.get_shader_parameter("fft_enabled")) == 0.0, "non-simulated surface keeps FFT disabled")
	while int(driver.get("published_frames")) < 3 and Time.get_ticks_msec() - start < 60000 and count > 0 and not simulated.is_empty():
		await process_frame
	if count > 0 and not simulated.is_empty():
		check(int(driver.get("published_frames")) >= 3, "driver published frames for authored simulated surfaces")
		var m0: ShaderMaterial = simulated[0]
		check(m0.get_shader_parameter("disp0") is ImageTexture, "cascade 0 texture bound")
		check(float(m0.get_shader_parameter("sim_time")) > 0.0, "simulation time advances")
		check(float(m0.get_shader_parameter("terrain_available")) == 1.0, "compact terrain height texture bound")
		var terrain_texture: Texture2D = m0.get_shader_parameter("terrain_heights")
		check(terrain_texture != null and terrain_texture.get_width() <= 1024, "terrain upload uses Unreal depth texture budget")
		print("INFO last job ms: %d" % int(driver.get("last_job_msec")))
		# Stale-map control: a level change while a job is in flight must be rejected.
		var before := int(driver.get("rejected_results"))
		var published := int(driver.get("published_frames"))
		env.set("level", "fake_level_control")
		for i in range(30): await process_frame
		check(int(driver.get("published_frames")) == published, "control: nothing published for a changed level")
		print("INFO rejected during control: %d" % (int(driver.get("rejected_results")) - before))
		env.set("level", level)
	parent.queue_free()
	await process_frame
	check(simulated.is_empty() or (simulated[0] as ShaderMaterial).get_shader_parameter("disp0") == null, "textures released on exit")
	print(JSON.stringify({"failures": failures}))
	quit(0 if failures.is_empty() else 1)
