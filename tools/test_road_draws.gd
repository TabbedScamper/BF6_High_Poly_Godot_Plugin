extends SceneTree
# The Godot roads from the shared core against the core's own numbers.
# godot --headless -s tools/test_road_draws.gd -- [--level=NAME] [--game=PATH]
# decal_draws_test prints the same stats for the same level; the draw count,
# triangle count and order here must agree with them.

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
	var core: Object = ClassDB.instantiate("BF6Core")
	if core == null or not core.call("open", game):
		push_error("core open failed"); quit(1); return
	var env := BF6Environment.new(core, level)
	var t0 := Time.get_ticks_msec()
	var prepared := HighpolyRoadDraws.prepare(env)
	var prepare_ms := Time.get_ticks_msec() - t0
	var draws: Array = prepared.get("draws", [])
	var stats: Dictionary = prepared.get("stats", {})
	print("stats: %s" % JSON.stringify(stats))
	print("prepared %d draws in %d ms" % [draws.size(), prepare_ms])
	check(draws.size() > 0 and draws.size() == int(stats.get("drawn", -1)), "every drawn record became a mesh")
	var tris := 0
	var textured := 0
	var last_key := -1
	var ordered := true
	for d in draws:
		var mesh: Mesh = d.mesh
		tris += int(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3)
		var mat: ShaderMaterial = d.material
		if mat.get_shader_parameter("has_albedo") == true or mat.get_shader_parameter("has_opacity") == true: textured += 1
		ordered = ordered and int(d.draw_index) > last_key
		last_key = int(d.draw_index)
		var band := int(d.band)
		ordered = ordered and mat.render_priority == -100 + band / 2000
	check(tris == int(stats.get("triangles", -1)), "triangles match the core (%d)" % tris)
	check(textured > draws.size() / 2, "sheets bound (%d of %d draws)" % [textured, draws.size()])
	check(ordered, "draw index order and band priorities")
	var root := HighpolyRoadDraws.build(prepared)
	get_root().add_child(root)
	var later_on_top := true
	var prev: GeometryInstance3D = null
	for c in root.get_children():
		var g := c as GeometryInstance3D
		if prev != null: later_on_top = later_on_top and g.sorting_offset > prev.sorting_offset
		prev = g
	check(root.get_child_count() == draws.size() and later_on_top, "one node per draw, later draws sort in front")
	root.queue_free()
	print("ROAD DRAWS %s (%d failures)" % ["PASSED" if failures.is_empty() else "FAILED", failures.size()])
	quit(0 if failures.is_empty() else 1)
