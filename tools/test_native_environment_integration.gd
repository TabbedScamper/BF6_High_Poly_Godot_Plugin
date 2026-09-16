extends SceneTree

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var failures: Array[String] = []
	for name in ["bf6_environment", "highpoly_native_terrain", "highpoly_native_water",
		"highpoly_gamesource", "highpoly_mapcontext", "highpoly_scatter", "highpoly_toggle"]:
		var script: GDScript = load("res://addons/highpoly_toggle/" + name + ".gd")
		if script == null or not script.can_instantiate(): failures.append("script compile: " + name)
	if not failures.is_empty():
		print(JSON.stringify({"failures": failures})); quit(1); return
	var context = load("res://addons/highpoly_toggle/highpoly_mapcontext.gd").new()
	var source = load("res://addons/highpoly_toggle/highpoly_gamesource.gd").new()
	var raw := PackedByteArray()
	raw.resize(3 * 3 * 2)
	for z in range(3):
		for x in range(3): raw.encode_u16((z * 3 + x) * 2, 100 + x * 10 + z * 20)
	var meta := {"world_min": 10.0, "world_max": 14.0, "world_min_z": 30.0,
		"world_max_z": 38.0, "base": 0.0, "scale": 65535.0}
	var mesh: ArrayMesh = context._heightmap_mesh(raw, 3, 1, meta)
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vertices[0] != Vector3(10, 100, 30) or vertices[8] != Vector3(14, 160, 38):
		failures.append("rectangular heightfield bounds or axis mapping")
	source._hm = {"data": raw, "res": 3, "min": 10.0, "max": 14.0,
		"min_z": 30.0, "max_z": 38.0, "base": 0.0, "scale": 65535.0}
	source.drape_step = 1
	var actual: float = source._height_at(12.0, 34.0)
	if not is_equal_approx(actual, 130.0): failures.append("road height differs from mesh")
	# Wrong square bounds produce another height: the fixture detects the old mapping.
	source._hm.erase("min_z"); source._hm.erase("max_z")
	var control: float = source._height_at(12.0, 34.0)
	if absf(control - actual) < 1.0: failures.append("square-bound control not discriminating")
	# The main-thread terrain re-ask reuses the worker result without a game
	# mount or heightfield write. This fake path cannot satisfy a native read.
	source.src = load("res://addons/highpoly_toggle/bf6_source.gd").new()
	source.src.game = "missing-game-control"
	source._native_core_game = source.src.game
	var env = load("res://addons/highpoly_toggle/bf6_environment.gd").new(null, source.level)
	source._native_environment = env
	var cache_dir := "user://native-terrain-no-io-control"
	source._native_terrain_directory = cache_dir
	source._native_terrain_meta = {"native": true, "res": 3}
	var cached: Dictionary = source.terrain(cache_dir)
	if cached.get("res", 0) != 3 or FileAccess.file_exists(cache_dir + "/height_game.r16"):
		failures.append("prepared terrain re-ask performed I/O or lost metadata")
	source.src.game = "different-missing-game-control"
	if source.native_environment() != null or not source._native_terrain_meta.is_empty():
		failures.append("changing game install retained an old environment")
	context.free()
	print(JSON.stringify({"failures": failures, "height": actual, "square_control_height": control}))
	quit(0 if failures.is_empty() else 1)
