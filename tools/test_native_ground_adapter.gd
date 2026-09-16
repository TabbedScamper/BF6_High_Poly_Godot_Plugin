extends SceneTree
const Env = preload("res://bf6_environment.gd")
const Terrain = preload("res://highpoly_native_terrain.gd")
func _init() -> void:
	call_deferred("run")
func run() -> void:
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open("C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"):
		quit(1); return
	var env = Env.new(core, "mp_granite_clubhouse_portal")
	if not env.prepare_ground(Callable(), 64, 64):
		push_error(env.error); quit(1); return
	var material: ShaderMaterial = Terrain.material(env)
	var failures: Array = []
	if material == null:
		failures.append("ground material not created")
	else:
		for name in ["CovIdx", "CovW", "CovIdx2", "CovW2", "Params", "Sheets", "Heights", "Masks", "Bake", "FarBake", "GroundNormal"]:
			if material.get_shader_parameter(name) == null: failures.append("unbound " + name)
		if material.get_shader_parameter("ExactBaseColorEnabled") != 0.0:
			failures.append("experimental colour enabled")
	if not Terrain.parse_page("BF6_PAGE_AOVS_RGBA8_V3 512 0 0 512 AAAA AAAA AAAA").has("error"):
		failures.append("corrupt page accepted")
	print(JSON.stringify({"failures": failures, "materials": env.ground.materials.size(),
		"scope": "real-game texture adapter and shader parser, not GPU/visual parity"}))
	quit(0 if failures.is_empty() else 1)
