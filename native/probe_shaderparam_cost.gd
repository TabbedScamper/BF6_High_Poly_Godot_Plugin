extends SceneTree

# WHAT COSTS 250 SECONDS IN THE FX TEST?
#
# The build itself finishes in 6 s. The test then stops inside the block that
# reads shader parameters back off every emitter - about 10,000 calls, where the
# section before it made 263. No script error is printed, so it is not crashing;
# it is simply slow.
#
# Two candidates, and guessing between them is what I keep getting wrong:
#   1. get_shader_parameter() is expensive per call.
#   2. The first access to a ShaderMaterial forces a shader COMPILE, so the cost
#      is per distinct material rather than per call, and the real difference is
#      that the loop touches 2,434 materials instead of 263.
# Timing both separates them.

func _init() -> void:
	await process_frame
	var sh: Shader = load("res://addons/highpoly_toggle/fx_sixway.gdshader")
	if sh == null:
		print("FAIL: shader did not load"); quit(1); return

	# 1. MANY CALLS, ONE MATERIAL. Isolates per-call cost.
	var one := ShaderMaterial.new()
	one.shader = sh
	one.set_shader_parameter("flip_v_probability", 0.5)
	var t0 := Time.get_ticks_msec()
	var acc := 0.0
	for i in range(10000):
		acc += float(one.get_shader_parameter("flip_v_probability"))
	print("10,000 get_shader_parameter on ONE material: %d ms" % (Time.get_ticks_msec() - t0))

	# 2. MANY MATERIALS, FEW CALLS EACH. Isolates per-material cost.
	var mats: Array = []
	t0 = Time.get_ticks_msec()
	for i in range(2434):
		var m := ShaderMaterial.new()
		m.shader = sh
		m.set_shader_parameter("flip_v_probability", 0.5)
		mats.append(m)
	print("2,434 ShaderMaterial created + one set: %d ms" % (Time.get_ticks_msec() - t0))

	t0 = Time.get_ticks_msec()
	for m in mats:
		acc += float((m as ShaderMaterial).get_shader_parameter("flip_v_probability"))
		acc += float((m as ShaderMaterial).get_shader_parameter("inv_z_fade"))
	print("2,434 materials x 2 reads: %d ms" % (Time.get_ticks_msec() - t0))

	# 3. THE ONE I ACTUALLY SUSPECT: reading a parameter that was NEVER SET.
	# Godot has to fall back to the shader's DEFAULT, which means asking the
	# shader for its default value - and that can mean compiling it.
	var unset: Array = []
	for i in range(2434):
		var m2 := ShaderMaterial.new()
		m2.shader = sh
		unset.append(m2)
	t0 = Time.get_ticks_msec()
	var nulls := 0
	for m in unset:
		var v = (m as ShaderMaterial).get_shader_parameter("size_curve_on")
		if v == null: nulls += 1
	print("2,434 reads of an UNSET parameter: %d ms (%d returned null)"
		% [Time.get_ticks_msec() - t0, nulls])
	print("acc %f" % acc)
	quit(0)
