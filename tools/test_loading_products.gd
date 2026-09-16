extends SceneTree
const Env = preload("res://bf6_environment.gd")

func digest(value: Variant) -> Variant:
	if value is PackedByteArray:
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(value)
		return {"bytes": value.size(), "sha256": hash.finish().hex_encode()}
	if value is Dictionary:
		var result := {}
		for key in value: result[key] = digest(value[key])
		return result
	if value is Array:
		var result := []
		for item in value: result.append(digest(item))
		return result
	return value

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3:
		push_error("Expected game_dir level report_path"); quit(2); return
	var core = ClassDB.instantiate("BF6Core")
	var started := Time.get_ticks_msec()
	if core == null or not core.open(args[0]):
		push_error("Could not open game"); quit(1); return
	var report := {"level": args[1], "open_ms": Time.get_ticks_msec() - started, "products": {}, "timings": {}}
	var env = Env.new(core, args[1])
	for pair in [["water",0],["water_height",2048],["terrain_depth",1024],["ground",64],["far_ground",64],["water_frame",1000]]:
		var t := Time.get_ticks_msec()
		var result: Dictionary = env.request(pair[0],pair[1])
		report.timings[pair[0]] = Time.get_ticks_msec() - t
		if result.is_empty(): push_error("Missing product: " + str(pair[0])); quit(1); return
		report.products[pair[0]] = digest(result)
		print("PRODUCT ",pair[0]," ms=", report.timings[pair[0]])
	report["total_ms"] = Time.get_ticks_msec() - started
	var bad_env = Env.new(core,"not_a_real_level_control")
	if not bad_env.request("water").is_empty(): push_error("Fake level accepted"); quit(1); return
	var file := FileAccess.open(args[2],FileAccess.WRITE)
	if file == null: push_error("Cannot write report"); quit(1); return
	file.store_string(JSON.stringify(report,"\t",true))
	print("PASS loading products and missing-level control ", report.total_ms," ms")
	quit(0)
