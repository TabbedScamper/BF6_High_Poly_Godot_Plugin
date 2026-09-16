extends SceneTree
# Material default and simulation-gate controls against a small fake environment.
# godot --headless -s tools/test_native_water_defaults.gd

class FakeEnv extends RefCounted:
	var core: Object = null
	var level := "fake_level"
	var water: Dictionary = {"cascades": [{"tile_dimension": 300.0, "resolution": 64, "choppiness": 0.5, "foam_enable": 1}], "surfaces": []}
	var water_height: Dictionary = {"present": 0}
	var terrain: Dictionary = {}
	var mask: Dictionary = {"present": 0, "reason": "fake"}
	var textures: Dictionary = {}

var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func near(a: Variant, b: float) -> bool:
	return (a is float or a is int) and absf(float(a) - b) < 1e-5

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var dir := "res://addons/highpoly_toggle/" if ResourceLoader.exists("res://addons/highpoly_toggle/highpoly_native_water.gd") else "res://"
	var Water: GDScript = load(dir + "highpoly_native_water.gd")
	if Water == null or not Water.can_instantiate():
		push_error("water script failed to compile"); quit(1); return
	var env := FakeEnv.new()
	var pool: ShaderMaterial = Water.call("material", {"native": true, "is_ocean": 0, "center": [10, 20], "height": 5.0}, env)
	var ocean: ShaderMaterial = Water.call("material", {"native": true, "is_ocean": 1, "center": [10, 20], "height": 5.0, "wave_amplitude_scale": 1.0}, env)
	var component: ShaderMaterial = Water.call("material", {"native": true, "is_ocean": 0, "ocean_component_version": 1, "foam_depth_ramp_m": 0.75}, env)

	# Gates: pool flat, ocean and ocean-component simulated.
	check(not bool(pool.get_meta(&"bf6_water_simulated")), "pool is not simulated")
	check(near(pool.get_shader_parameter("fft_enabled"), 0.0), "pool fft disabled")
	check((pool.get_shader_parameter("cascade0") as Vector4).x == 1.0 and (pool.get_shader_parameter("cascade0") as Vector4).z == 0.0, "pool cascade0 absent")
	check(near(pool.get_shader_parameter("interactive_enabled"), 0.0), "pool interactive bridge off")
	check(bool(ocean.get_meta(&"bf6_water_simulated")) and near(ocean.get_shader_parameter("fft_enabled"), 1.0), "ocean simulated")
	check(near((ocean.get_shader_parameter("cascade0") as Vector4).x, 300.0), "ocean cascade0 tile bound")
	check(near(ocean.get_shader_parameter("interactive_enabled"), 1.0) and near(ocean.get_shader_parameter("interactive_height"), 4.0), "ocean without broad graph uses Unreal interactive bridge")
	check(near(ocean.get_shader_parameter("foam_wave_height"), 0.0), "broad vertex bridge off without graph")
	check(bool(component.get_meta(&"bf6_water_simulated")), "ocean component alone gates simulation")
	check(near(component.get_shader_parameter("foam_depth_ramp"), 0.75), "authored foam depth ramp bound")

	# Unreal parent defaults survive absent (negative-sentinel) fields.
	var sentinel := {"native": true, "is_ocean": 1, "micro_sheet_uv_scale": -1.0, "contact_gain": -1.0, "smoothness_bias": -1.0}
	var d: ShaderMaterial = Water.call("material", sentinel, env)
	var expected := {"use_sheets": 0.0, "micro_uv_scale": 0.0464, "foam_uv_scale": 0.14, "micro_flow_speed": 0.9,
		"detail_strength": 1.0, "foam_sheet_strength": 0.35, "contact_divisor": 73718.0, "contact_gain": 0.916,
		"composite_low": 0.0427, "composite_high": 1.14, "water_roughness": 0.04, "foam_roughness": 0.3,
		"foam_depth_ramp": 0.5, "water_specular": 0.4, "shore_depth": 0.0}
	var shader_defaults := {}
	for u in RenderingServer.get_shader_parameter_list(d.shader.get_rid()):
		shader_defaults[str(u["name"])] = RenderingServer.shader_get_parameter_default(d.shader.get_rid(), StringName(u["name"]))
	for key in expected:
		var value: Variant = d.get_shader_parameter(key)
		if value == null: value = shader_defaults.get(key, null)
		check(near(value, float(expected[key])), "default %s = %s (got %s)" % [key, str(expected[key]), str(value)])
	# Control: an authored value replaces exactly that default.
	var authored: ShaderMaterial = Water.call("material", {"native": true, "is_ocean": 1, "contact_gain": 0.5}, env)
	check(near(authored.get_shader_parameter("contact_gain"), 0.5), "control: authored contact_gain replaces default")
	check(near(authored.get_shader_parameter("micro_uv_scale"), 0.0464), "control: unrelated default untouched")

	# Unreal surface tint: parent colour hue * 0.06 when neither colour is authored.
	var tint: Vector3 = d.get_shader_parameter("surface_tint")
	check(tint.is_equal_approx(Vector3(0.10, 0.45, 0.55) / 0.55 * 0.06), "Unreal fallback surface tint")
	var shallow: ShaderMaterial = Water.call("material", {"native": true, "shallow": [0.5, 1.0, 0.25]}, env)
	check((shallow.get_shader_parameter("surface_tint") as Vector3).is_equal_approx(Vector3(0.03, 0.06, 0.015)), "shallow hue tint")

	# Driver: no core means no jobs; pool-only materials never request frames.
	var parent := Node3D.new()
	root.add_child(parent)
	var driver: Node = Water.call("attach", parent, env, [pool])
	for i in range(10): await process_frame
	check(int(driver.get("published_frames")) == 0 and str(driver.get("last_error")).is_empty(), "pool-only driver stays idle without game reads")
	parent.queue_free()
	await process_frame
	print(JSON.stringify({"failures": failures}))
	quit(0 if failures.is_empty() else 1)
