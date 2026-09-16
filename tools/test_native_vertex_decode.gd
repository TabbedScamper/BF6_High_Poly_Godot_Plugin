extends SceneTree

const MeshReader = preload("res://bf6_meshset.gd")
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error(label)

func bytes_for(fmt: int, count: int, first: int, stride: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(first + count * stride)
	var components: int = MeshReader.new()._components(fmt)
	for i in range(count):
		for c in range(components):
			var at := first + i * stride
			if fmt <= 4:
				b.encode_float(at + c * 4, float((i * 13 + c * 17) % 991 - 495) / 7.0)
			elif fmt <= 8:
				b.encode_half(at + c * 2, float((i * 13 + c * 17) % 991 - 495) / 7.0)
			elif fmt <= 13:
				b[at + c] = (i * 13 + c * 17) % 256
			else:
				b.encode_u16(at + c * 2, (i * 271 + c * 997) % 65536)
	return b

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var fast = MeshReader.new()
	var reference = MeshReader.new()
	reference.use_native_attributes = false
	check(ClassDB.class_exists("BF6Core"), "BF6Core registered")
	if not ClassDB.class_exists("BF6Core"):
		quit(1)
		return
	var core: Object = ClassDB.instantiate("BF6Core")
	check(core.has_method("decode_vertex_attribute"), "native attribute method registered")
	if not core.has_method("decode_vertex_attribute"):
		quit(1)
		return
	var cases := 0
	for fmt in MeshReader.FMT_SIZE:
		if fmt == 50:
			continue
		for padding in [0, 7]:
			var count := 4096
			var stride: int = MeshReader.FMT_SIZE[fmt] + padding
			var first := 5
			var data := bytes_for(fmt, count, first, stride)
			var original := data.duplicate()
			var element := [33, fmt, 0, 0]
			var streams := [[stride, 0]]
			var a: Array = reference._read_attr(data, first, count, element, streams)
			var b: Array = fast._read_attr(data, first, count, element, streams)
			check(a.size() == 2 and b.size() == 2, "decode format %d" % fmt)
			if a.size() == 2 and b.size() == 2:
				check(a[1] == b[1] and a[0].to_byte_array() == b[0].to_byte_array(),
					"bit parity fmt=%d padding=%d" % [fmt, padding])
			check(data == original, "input retained fmt=%d" % fmt)
			cases += 1
	# Every half-float bit pattern, including signed zero/subnormals/Inf/NaN.
	var halves := PackedByteArray()
	halves.resize(65536 * 2)
	for i in range(65536):
		halves.encode_u16(i * 2, i)
	var ha: Array = reference._read_attr(halves, 0, 65536, [33, 5, 0, 0], [[2, 0]])
	var hb: Array = fast._read_attr(halves, 0, 65536, [33, 5, 0, 0], [[2, 0]])
	check(ha.size() == 2 and hb.size() == 2, "half-float decoders returned arrays")
	if ha.size() != 2 or hb.size() != 2:
		quit(1)
		return
	var half_a: PackedByteArray = ha[0].to_byte_array()
	var half_b: PackedByteArray = hb[0].to_byte_array()
	var half_mismatches: Array = []
	var nan_payload_differences := 0
	for i in range(65536):
		if half_a.decode_u32(i * 4) != half_b.decode_u32(i * 4):
			if is_nan(ha[0][i]) and is_nan(hb[0][i]):
				nan_payload_differences += 1
			elif half_mismatches.size() < 8:
				half_mismatches.append([i, ha[0][i], hb[0][i]])
	# The script converts through Variant's double and quiets signaling NaNs;
	# packed native output preserves the original payload. Both remain NaN.
	check(half_mismatches.is_empty(), "half-float value/finite-bit parity: %s" % str(half_mismatches))
	var data := bytes_for(3, 32, 0, 12)
	for bad in [[-1, 12, 32, 3], [0, 0, 32, 3], [0, -12, 32, 3],
		[0, 12, -1, 3], [0, 12, 0, 3], [0, 12, 33, 3], [0, 12, 32, 999],
		[0, 12, 32, 50], [9223372036854775807, 12, 32, 3],
		[0, 9223372036854775807, 32, 3]]:
		var result: PackedFloat32Array = core.call("decode_vertex_attribute", data, bad[0], bad[1], bad[2], bad[3])
		check(result.is_empty(), "invalid span rejected: %s" % str(bad))
	# SoA stream prefix + element offset must survive the binding boundary.
	var soa := bytes_for(6, 99, 3 + 99 * 12 + 2, 8)
	var sa: Array = reference._read_attr(soa, 3, 99, [33, 6, 2, 1], [[12, 0], [8, 0]])
	var sb: Array = fast._read_attr(soa, 3, 99, [33, 6, 2, 1], [[12, 0], [8, 0]])
	check(sa.size() == 2 and sb.size() == 2, "SoA decoders returned arrays")
	if sa.size() == 2 and sb.size() == 2:
		check(sa[0].to_byte_array() == sb[0].to_byte_array(), "SoA stream prefix and element offset")
	var short_data := data.slice(0, data.size() - 1)
	check(core.call("decode_vertex_attribute", short_data, 0, 12, 32, 3).is_empty(), "one byte short rejected")
	for bad_element in [[], [33, 3, 0, -1], [33, 3, -1, 0], [33, 3, 0, 99]]:
		check(fast._read_attr(data, 0, 32, bad_element, [[12, 0]]).is_empty(), "malformed element rejected")
	check(fast._read_attr(data, 0, 32, [33, 3, 0, 1], [[9223372036854775807, 0], [12, 0]]).is_empty(), "overflowing stream prefix rejected")
	check(fast.native_attribute_reads == cases + 2, "all supported cases used native path")
	check(fast.script_attribute_reads == 0, "no silent fallback in parity cases")
	var timings: Array = []
	for fmt in [3, 6, 8, 21, 13]:
		var count := 200000
		var stride: int = MeshReader.FMT_SIZE[fmt]
		var input := bytes_for(fmt, count, 0, stride)
		var slow_us: Array = []
		var fast_us: Array = []
		for rep in range(7):
			# Alternate order to reduce order/warmup bias; drop first pair.
			for mode in ([false, true] if rep % 2 == 0 else [true, false]):
				var reader = fast if mode else reference
				var start := Time.get_ticks_usec()
				var values: Array = reader._read_attr(input, 0, count, [33, fmt, 0, 0], [[stride, 0]])
				var elapsed := Time.get_ticks_usec() - start
				check(values.size() == 2, "benchmark output")
				if rep > 0:
					if mode: fast_us.append(elapsed)
					else: slow_us.append(elapsed)
		fast_us.sort()
		slow_us.sort()
		timings.append({"format": fmt, "vertices": count, "script_us": slow_us[3],
			"native_us": fast_us[3], "speedup": float(slow_us[3]) / maxf(1.0, float(fast_us[3]))})
	var report := {"test": "native vertex decoding", "format_stride_cases": cases,
		"half_patterns": 65536, "nan_payload_differences": nan_payload_differences,
		"failures": failures, "timings": timings,
		"scope": "CPU decode including Godot/native transfer; no map-load or FPS claim"}
	FileAccess.open("user://native-vertex-result.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
