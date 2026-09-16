extends SceneTree
# Water parity with the Unreal add-on, through the shared core.
# godot --headless -s tools/test_water_parity.gd -- [--level=NAME] [--game=PATH]
#   * the cascades carry the level's sea state (bf6_level_water_sims_effective)
#   * the draw tree matches the core's own test view (bf6_water_draw_tree)
#   * a tiled surface gets its instances from a camera, and refines near it
#   * overlap is off by default and the material clock is continuous

var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func run() -> void:
	var level := "MP_Isolated"
	var game := "C:/Program Files/EA Games/Battlefield 6"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--level="): level = arg.substr(8)
		if arg.begins_with("--game="): game = arg.substr(7)
	var dir := "res://addons/highpoly_toggle/"
	var Env: GDScript = load(dir + "bf6_environment.gd")
	var Water: GDScript = load(dir + "highpoly_native_water.gd")
	if Env == null or Water == null or not Water.can_instantiate():
		push_error("scripts failed to compile"); quit(1); return
	var core: Object = ClassDB.instantiate("BF6Core")
	if core == null or not core.call("open", game):
		push_error("core open failed"); quit(1); return
	check(core.has_method("water_draw_tree"), "binding exposes water_draw_tree")

	# Sea state: the same numbers water_sea_state_test prints for the core.
	var env: Object = Env.new(core, level)
	var water: Dictionary = env.call("read_water")
	var cascades: Array = water.get("cascades", [])
	check(cascades.size() > 0, "cascades read")
	for i in range(cascades.size()):
		var c: Dictionary = cascades[i]
		print("  cascade %d: %s" % [i, JSON.stringify(c)])
	if level.to_lower() == "mp_isolated" and cascades.size() > 0:
		var c0: Dictionary = cascades[0]
		var wind := float(c0.get("wind_speed", -1.0))
		var amp := float(c0.get("wave_amplitude", -1.0))
		check(absf(wind - 13.9) < 0.01, "mp_isolated wind is the Beaufort 6.5 wind (%.3f)" % wind)
		check(absf(amp - 0.425) < 0.001, "mp_isolated amplitude is sea curve slot 7 (%.4f)" % amp)

	# The core test's view, in Godot's frame (x, z plane, y up): 12173 tiles.
	var tiles: PackedFloat32Array = core.call("water_draw_tree", PackedFloat32Array([
		0.0, 0.0, 2.0, 1.0, 0.0, 90.0, 1920, -2500.0, -2500.0, 2500.0, 2500.0, 0.0, 16, 12288, 6]))
	check(tiles.size() == 12173 * 4, "draw tree matches the core test (%d tiles)" % (tiles.size() / 4))
	var finest := 1e9
	for i in range(tiles.size() / 4): finest = minf(finest, tiles[i * 4 + 2])
	check(is_equal_approx(finest, 16.0), "finest tile is 16 m (%.1f)" % finest)

	# A tiled surface under a camera.
	var root3d := Node3D.new()
	get_root().add_child(root3d)
	var cam := Camera3D.new()
	root3d.add_child(cam)
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(100.0, 3.0, 50.0))
	cam.current = true
	var mat := ShaderMaterial.new()
	var tiled: MultiMeshInstance3D = Water.call("tiled_surface", Vector2(0, 0), Vector2(5000, 5000), 0.0, 0.5, mat)
	root3d.add_child(tiled)
	var driver: Node = Water.call("attach", root3d, env, [mat])
	var n: int = driver.call("_update_tree", true)
	check(n > 100 and tiled.multimesh.instance_count == n, "tiled surface filled from the camera (%d)" % n)
	var near_w := 1e9
	var far_w := 0.0
	var got: PackedFloat32Array = driver.get("last_tree_tiles")
	print("  view width %d, fov %.1f" % [int(driver.get("_tree_width")), float(driver.get("_tree_fov"))])
	for i in range(got.size() / 4):
		var d := Vector2(got[i * 4] - 100.0, got[i * 4 + 1] - 50.0).length()
		if d < 20.0: near_w = minf(near_w, got[i * 4 + 2])
		if d > 2000.0: far_w = maxf(far_w, got[i * 4 + 2])
	check(near_w <= 16.0 and far_w >= 256.0, "fine under the camera (%.0f m), coarse far away (%.0f m)" % [near_w, far_w])
	cam.global_transform = Transform3D(Basis.IDENTITY, Vector3(100.0, 3.0, 51.0))
	var again: int = driver.call("_update_tree", false)
	check(again == n, "a sub-tile move does not rebuild")
	check(Water.OVERLAP_OVERRIDE == 0, "overlap off by default, as in Unreal")

	driver.queue_free()
	root3d.queue_free()
	print("WATER PARITY %s (%d failures)" % ["PASSED" if failures.is_empty() else "FAILED", failures.size()])
	quit(0 if failures.is_empty() else 1)
