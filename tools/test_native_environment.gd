extends SceneTree
const Env = preload("res://bf6_environment.gd")
func _init() -> void:
	call_deferred("run")
func run() -> void:
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open("C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"):
		push_error("core open failed"); quit(1); return
	var env = Env.new(core, "mp_granite_clubhouse_portal")
	var failures: Array = []
	var report: Dictionary = {}
	for kind in ["terrain", "water", "water_height", "water_mask", "ground", "water_frame"]:
		var start := Time.get_ticks_msec()
		var result: Dictionary = env.request(kind, 64 if kind == "ground" else 0)
		if result.is_empty(): failures.append(kind + ": " + env.error)
		if kind == "terrain" and result.has("preview_heights"):
			var raw: PackedByteArray = result.heights
			var preview: PackedByteArray = result.preview_heights
			var pw := int(result.preview_width)
			var ph := int(result.preview_height)
			var width := int(result.width)
			var height := int(result.height)
			var different := 0
			for y in range(0, ph, 37):
				for x in range(0, pw, 29):
					var sx := x * width / pw
					var sy := y * height / ph
					var expected := raw.decode_u16((sy * width + sx) * 2)
					if preview.decode_u16((y * pw + x) * 2) != expected:
						failures.append("Unreal depth sampling differs"); break
					if raw.decode_u16((sx * width + sy) * 2) != expected: different += 1
			if different == 0: failures.append("transposed height control not discriminating")
			print("depth sampling transpose control differs at %d probes" % different)
		if kind == "water":
			for row in result.get("surfaces", []):
				if row.get("surface_join_valid", 0) != 1 or not row.has("is_ocean"):
					failures.append("water optics/geometry join rejected")
		var summary: Dictionary = {}
		for key in result:
			var value: Variant = result[key]
			summary[key] = value.size() if value is PackedByteArray or value is Array else value
		summary["ms"] = Time.get_ticks_msec() - start
		report[kind] = summary
		print(kind + " " + JSON.stringify(summary))
	if not Env.unpack(PackedByteArray([255,255,255,255])).get("ok", 1) == 0:
		failures.append("truncated packet accepted")
	var bad := env.request("not_a_product")
	if not bad.is_empty(): failures.append("unknown product accepted")
	report["failures"] = failures
	FileAccess.open("user://native-environment.json", FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print(JSON.stringify({"failures": failures}))
	quit(0 if failures.is_empty() else 1)
