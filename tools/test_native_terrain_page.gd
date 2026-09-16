extends SceneTree

var task := -1
var result: Dictionary = {}
var started := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var level := "mp_isolated"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--level="): level = arg.substr(8)
	var Terrain: GDScript = load("res://highpoly_native_terrain.gd")
	if not Terrain.can_instantiate(): quit(1); return
	var invalid: Dictionary = Terrain.exact_page("", "", Vector2(INF, 0))
	if not invalid.has("error"): quit(1); return
	started = Time.get_ticks_msec()
	task = WorkerThreadPool.add_task(func():
		result = Terrain.exact_page("C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6",
			level, Vector2(0, 0), 64.0, 64))
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	var summary := {"elapsed_ms": Time.get_ticks_msec() - started, "error": result.get("error", ""),
		"native_exact": result.get("native_exact", false), "size": result.get("size", 0), "invalid_bounds_rejected": true}
	for channel in ["albedo", "material", "normal"]:
		if result.has(channel):
			var im: Image = result[channel]
			summary[channel + "_bytes"] = im.get_data().size()
	print(JSON.stringify(summary))
	quit(1 if result.has("error") else 0)
