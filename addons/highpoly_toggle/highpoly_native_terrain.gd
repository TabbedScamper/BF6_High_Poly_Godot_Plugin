@tool
extends RefCounted
class_name HighpolyNativeTerrain

# Adapter for the active Unreal ground evaluator, preserving its coverage
# union, layer order, stochastic sampling, grass and exact-page validity rules.
static func _texture(bytes: PackedByteArray, width: int, height: int, format: Image.Format) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_from_data(width, height, false, format, bytes))

static func _solid(color: Color) -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

static func _grass(row: Dictionary) -> float:
	var name := str(row.get("albedo_res", "")).to_lower()
	if name.contains("seaweed"): return 0.0
	for word in ["grass", "weed", "groundcover", "clover", "meadow", "lawn", "turf"]:
		if name.contains(word): return 1.0
	return 0.0

static func material(env) -> ShaderMaterial:
	if env == null or env.ground.is_empty(): return null
	var data: Dictionary = env.ground
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string((HighpolyNativeTerrain as Script).resource_path.get_base_dir() + "/terrain_native.gdshader")
	if shader.get_shader_uniform_list().is_empty(): return null
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_meta("bf6_native_terrain", true)
	var size := int(data.size)
	for entry in [["CovIdx", "idx0"], ["CovW", "weight0"], ["CovIdx2", "idx1"], ["CovW2", "weight1"]]:
		m.set_shader_parameter(entry[0], _texture(data[entry[1]], size, size, Image.FORMAT_RGBA8))
	for entry in [["Sheets", "albedo_images"], ["Heights", "normal_images"], ["Masks", "mask_images"]]:
		var array := Texture2DArray.new()
		if array.create_from_images(data[entry[1]]) != OK: return null
		m.set_shader_parameter(entry[0], array)
	var layers: Array = data.materials
	var count := layers.size()
	var params := PackedFloat32Array()
	params.resize(count * 16)
	for i in range(count):
		var row: Dictionary = layers[i]
		var tint: Array = row.tint
		var scale: Array = row.coord_scale
		var offset: Array = row.uv_offset
		var rows := [
			[maxf(0.05, float(row.metres_per_repeat)), deg_to_rad(float(row.uv_rotation_deg)), float(row.overlay), maxf(0.01, float(row.mask_ramp_exp))],
			[float(tint[0]), float(tint[1]), float(tint[2]), float(row.height_blend)],
			[float(row.base_height), float(row.displace_range), float(scale[0]), float(scale[1])],
			[float(offset[0]), float(offset[1]), _grass(row), _grass(layers[(i + maxi(1, count / 2)) % count])]]
		for y in range(4):
			for x in range(4): params[(y * count + i) * 4 + x] = rows[y][x]
	m.set_shader_parameter("Params", _texture(params.to_byte_array(), count, 4, Image.FORMAT_RGBAF))
	var lo := Vector3(float(data.lo[0]), float(data.lo[1]), 0)
	var hi := Vector3(float(data.hi[0]), float(data.hi[1]), 0)
	var span := hi - lo
	m.set_shader_parameter("Lo", lo)
	m.set_shader_parameter("Span", span)
	m.set_shader_parameter("GroundLo", lo)
	m.set_shader_parameter("GroundSpan", span)
	m.set_shader_parameter("CovSize", float(size))
	m.set_shader_parameter("MatCount", float(count))
	m.set_shader_parameter("PhotoMix", 0.0)
	m.set_shader_parameter("MapDetailStrength", 0.75)
	m.set_shader_parameter("ExactPageEnabled", 0.0)
	m.set_shader_parameter("ExactBaseColorEnabled", 0.0)
	var aerial: ImageTexture = _solid(Color(0.5, 0.5, 0.5))
	if not (data.colour as PackedByteArray).is_empty():
		aerial = _texture(data.colour, size, size, Image.FORMAT_RGB8)
	m.set_shader_parameter("Aerial", aerial)
	m.set_shader_parameter("Reference", _solid(Color.WHITE))
	var bake: Texture2D = aerial
	var bake_size := int(data.get("bake_size", 0))
	if bake_size > 0:
		bake = _texture(data.baked_albedo, bake_size, bake_size, Image.FORMAT_RGBA8)
		var normals: PackedByteArray = data.get("baked_normal", PackedByteArray())
		if not normals.is_empty():
			m.set_shader_parameter("GroundNormal", _texture(normals, bake_size, bake_size, Image.FORMAT_RGBA8))
			m.set_shader_parameter("GroundNormalEnabled", 1.0)
	m.set_shader_parameter("Bake", bake)
	var far: Dictionary = data.get("far", {})
	if not far.is_empty():
		m.set_shader_parameter("FarBake", _texture(far.albedo, int(far.size), int(far.size), Image.FORMAT_RGBA8))
		m.set_shader_parameter("FarLo", Vector3(float(far.lo[0]), float(far.lo[1]), 0))
		m.set_shader_parameter("FarSpan", Vector3(float(far.hi[0]) - float(far.lo[0]), float(far.hi[1]) - float(far.lo[1]), 1))
		m.set_shader_parameter("BoxCentre", (lo + hi) * 0.5)
		m.set_shader_parameter("BoxHalf", span * 0.5)
	else:
		m.set_shader_parameter("FarBake", bake)
		m.set_shader_parameter("BoxHalf", Vector3(1e9, 1e9, 1))
	for name in ["ExactPage", "ExactMaterialPage", "ExactNormalPage"]:
		m.set_shader_parameter(name, _solid(Color.WHITE))
	return m

static func exact_page(game_dir: String, level: String, center: Vector2, span := 512.0, side := 512) -> Dictionary:
	var executable := (HighpolyNativeTerrain as Script).resource_path.get_base_dir() + "/bin/bf6_terrain_evaluator.exe"
	executable = ProjectSettings.globalize_path(executable)
	if not FileAccess.file_exists(executable):
		return {"native_exact": true, "error": "Terrain evaluator is not installed"}
	if not center.is_finite() or not is_finite(span) or span <= 0 or side < 64 or side > 2048 or side % 8 != 0:
		return {"native_exact": true, "error": "Invalid terrain page bounds"}
	var args := PackedStringArray([game_dir, level, "--page-dispatch", str(center.x), str(center.y), "ignored.ppm",
		"--page-size-m", str(span), "--page-resolution", str(side), "--texture-max-dim", "0",
		"--raw-evaluator-coverage", "--game-culling", "--stdout-aovs-rgba8", "--no-files"])
	# Drain BOTH pipes while the worker runs. A filled stderr pipe can otherwise
	# deadlock a process even while its stdout appears idle. Never wait on UI.
	var process := OS.execute_with_pipe(executable, args, false)
	if process.is_empty(): return {"native_exact": true, "error": "Could not start terrain evaluator"}
	var pid := int(process.pid)
	var chunks: Array[PackedByteArray] = []
	var total := 0
	var error_tail := ""
	var deadline := Time.get_ticks_msec() + 120000
	while true:
		var received := false
		for name in ["stdio", "stderr"]:
			var pipe: FileAccess = process[name]
			var bytes := pipe.get_buffer(65536)
			if not bytes.is_empty():
				if name == "stdio": chunks.append(bytes)
				else: error_tail = bytes.get_string_from_utf8().right(1000)
				total += bytes.size(); received = true
		if total > 128 * 1024 * 1024 or Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			return {"native_exact": true, "error": "Terrain evaluator exceeded time/output budget"}
		if not OS.is_process_running(pid) and not received: break
		if not received: OS.delay_msec(10)
	var code := OS.get_process_exit_code(pid)
	if code != 0: return {"native_exact": true, "error": "Terrain evaluator exited %d: %s" % [code, error_tail]}
	var output := PackedByteArray()
	for chunk in chunks: output.append_array(chunk)
	return parse_page(output.get_string_from_utf8())

static func parse_page(output: String) -> Dictionary:
	for line in output.split("\n"):
		if not line.begins_with("BF6_PAGE_AOVS_RGBA8_V3 "): continue
		var fields := line.strip_edges().split(" ", false)
		if fields.size() != 8: break
		if not fields[1].is_valid_int() or not fields[2].is_valid_float() or not fields[3].is_valid_float() or not fields[4].is_valid_float(): break
		var side := fields[1].to_int()
		var lo := Vector2(fields[2].to_float(), fields[3].to_float())
		var span := fields[4].to_float()
		if side < 1 or side > 4096 or not lo.is_finite() or not is_finite(span) or span <= 0: break
		var result := {"native_exact": true, "size": side, "lo": lo, "span": span}
		for i in range(3):
			var bytes := Marshalls.base64_to_raw(fields[5 + i])
			if bytes.size() != side * side * 4:
				return {"native_exact": true, "error": "Truncated terrain page"}
			result[["albedo", "material", "normal"][i]] = Image.create_from_data(side, side, false, Image.FORMAT_RGBA8, bytes)
		return result
	return {"native_exact": true, "error": "Terrain evaluator returned no valid V3 page"}

static func apply_page(m: ShaderMaterial, page: Dictionary) -> bool:
	if page.has("error"):
		push_warning(str(page.error)); return false
	for entry in [["ExactPage", "albedo"], ["ExactMaterialPage", "material"], ["ExactNormalPage", "normal"]]:
		m.set_shader_parameter(entry[0], ImageTexture.create_from_image(page[entry[1]]))
	var lo: Vector2 = page.lo
	m.set_shader_parameter("ExactPageLo", Vector3(lo.x, lo.y, 0))
	m.set_shader_parameter("ExactPageSpan", Vector3(float(page.span), float(page.span), 1))
	m.set_shader_parameter("ExactPageEnabled", 1.0)
	# Matches Unreal: U1 is a validity mask until evaluator layer order is closed.
	m.set_shader_parameter("ExactBaseColorEnabled", 0.0)
	return true
