extends SceneTree

const MeshReader = preload("res://bf6_meshset.gd")

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var source := BF6Source.new()
	var game := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	var level := "mp_granite_clubhouse_portal"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--game="): game = argument.substr(7)
		if argument.begins_with("--level="): level = argument.substr(8)
	if not source.open(game) or not source.mount(level, Callable(), true, 0, false):
		push_error(source.error)
		quit(1)
		return
	var chosen: Array[String] = []
	var names: Array = source.res.keys()
	names.sort()
	for family in ["carsuv_01", "carsedan_01", "billboard", "curb", "manzanita", "umbrelladwarf", "firetruck", "retailsign"]:
		var found := 0
		for name in names:
			if str(name).contains(family) and str(name).ends_with("_mesh"):
				chosen.append(str(name))
				found += 1
				if found == 3: break
	var fast = MeshReader.new()
	var slow = MeshReader.new()
	slow.use_native_attributes = false
	var results: Array = []
	var failures: Array = []
	var vertices := 0
	var fast_total := 0
	var slow_total := 0
	for name in chosen:
		var resource := source.get_res(name)
		var info: Dictionary = slow.parse(resource)
		if info.is_empty() or info["lods"].is_empty():
			failures.append("missing metadata: " + name)
			continue
		var chunk := PackedByteArray()
		var id: PackedByteArray = info["lods"][0].get("chunk_id", PackedByteArray())
		for form in MeshReader.chunk_forms(id):
			chunk = source.get_chunk(str(form))
			if not chunk.is_empty(): break
		var fast_times: Array = []
		var slow_times: Array = []
		var sections := 0
		for repetition in range(5):
			var a: Array = []
			var b: Array = []
			for native in ([false, true] if repetition % 2 == 0 else [true, false]):
				var start := Time.get_ticks_usec()
				var decoded: Array = (fast if native else slow).read_lod(resource, 0, chunk, false, true)
				var elapsed := Time.get_ticks_usec() - start
				if native:
					b = decoded
					if repetition > 0: fast_times.append(elapsed)
				else:
					a = decoded
					if repetition > 0: slow_times.append(elapsed)
			if var_to_bytes(a) != var_to_bytes(b):
				failures.append("full section mismatch: " + name)
			if repetition == 0:
				sections = a.size()
				for section in a: vertices += section["verts"].size()
		if sections == 0:
			failures.append("no decoded sections: " + name)
		fast_times.sort()
		slow_times.sort()
		fast_total += int(fast_times[2])
		slow_total += int(slow_times[2])
		results.append({"mesh": name, "sections": sections,
			"script_us": slow_times[2], "native_us": fast_times[2]})
	if fast.native_attribute_reads == 0 or fast.script_attribute_reads != 0:
		failures.append("native decode was not used exclusively")
	if results.size() < 8:
		failures.append("insufficient mesh coverage")
	var report := {"level": level, "game": game, "meshes": results, "vertices": vertices,
		"script_total_us": slow_total, "native_total_us": fast_total,
		"speedup": float(slow_total) / maxf(1.0, float(fast_total)), "failures": failures,
		"native_attributes": fast.native_attribute_reads, "fallback_attributes": fast.script_attribute_reads,
		"scope": "full LOD decode, same installed-game bytes; excludes IO/material assembly/rendering"}
	FileAccess.open("user://native-mesh-corpus.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
