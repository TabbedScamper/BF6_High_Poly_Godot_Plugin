@tool
class_name HighpolyNativeWater
extends Node

# Native ocean surface for the High Poly preview. Port of the Unreal add-on's
# water material (BF6HighPoly.cpp FFT WPO/normal/foam nodes and the MID binding)
# and BF6HighPolyWaterFFT.cpp Bind. Displacement and normal/foam cascades come
# from the native CPU replay (environment product "water_frame"); nothing here
# reads exported intermediates.
#
# Threading contract:
#   * at most one WorkerThreadPool task at a time, never a backlog;
#   * every native read and all Image decoding happens on that worker;
#   * the main thread only uploads finished Images into reused ImageTextures;
#   * results are rejected when the level changed, the driver was re-armed or
#     the node left the tree.

const SHADER_FILE := "water_native.gdshader"
const SHARED_META := &"highpoly_native_water_shared"
const DIAGNOSTICS_META := &"bf6_water_diagnostics"
const MAX_CASCADES := 4
# Broad crest sheet scroll rate. 0 = still. See where it is applied for why it
# is a tuned constant rather than a value read from the level.
const BROAD_TIME_SCALE := 0.0
const FRAME_INTERVAL_MSEC := 33
const TEXTURE_LIMIT := 16384
const MAX_FAILURES := 8
const RETRY_BASE_MSEC := 500
const RETRY_CAP_MSEC := 30000
const SIMULATED_META := &"bf6_water_simulated"
# Unreal preview constants (BF6HighPoly.cpp 6007, 8331-8339). Not game reads.
const UNREAL_FOAM_WAVE_HEIGHT_M := 4.0
const UNREAL_INTERACTIVE_LENGTH_M := 120.0
const UNREAL_INTERACTIVE_RATE := 0.35
# Unreal SurfaceAlbedo fallback and SurfaceTint source colour (8153, 8558).
const UNREAL_SURFACE_ALBEDO := 0.06
# Bind parent defaults explicitly so inspection and fallback work identically
# with a real renderer and a headless validation renderer.
const PARENT_DEFAULTS := {"micro_uv_scale": 0.0464, "foam_uv_scale": 0.14, "micro_flow_speed": 0.9,
	"detail_strength": 1.0, "foam_sheet_strength": 0.35, "contact_divisor": 73718.0,
	"contact_gain": 0.916, "composite_low": 0.0427, "composite_high": 1.14,
	"water_roughness": 0.04, "foam_roughness": 0.3, "foam_depth_ramp": 0.5}
# Unreal ShoreFadeDistance parent default; only reachable for attenuation
# types >= 2 without a bound utility raster (BF6HighPoly.cpp ~8450).
const SHORE_FADE_DEFAULT_M := 6.0
# Water F0 literal 0.0256 as a Godot SPECULAR (f0 = 0.16 * specular^2).
const WATER_SPECULAR := 0.4
# Unreal's WaterOverlap console default; see _bind overlap.
const OVERLAP_OVERRIDE := 0
# Unreal FWaterFFT::Tick clamps each frame's advance to 0.1 s, so a hitch never
# makes the sea jump; the simulation clock here does the same.
const MAX_STEP_MSEC := 100
# THE WATER DRAW TREE (bf6_water_draw_tree, shared with Unreal). The patch is
# the executable's 16x16 quads; Unreal rebuilds the tree at most 5 times a
# second, and only after the camera moves 16 m (one finest tile), turns a
# degree or the view changes size (BF6HighPoly.cpp UpdateWaterClipmaps).
const PATCH_QUADS := 16
const TREE_TILE_CAP := 12288
const TREE_OFF_VIEW_DEPTH := 6
const TREE_MAX_HZ := 5.0
const TREE_MOVE_M := 16.0
const TREE_TURN_DEG := 1.0
const TREE_ROOT_M := 65536.0
const TILED_META := &"bf6_water_tiled"
const KIND_FRAME := 0
const KIND_TERRAIN := 1

static var _shader_cache: Shader = null
static var _patch_cache: ArrayMesh = null

@export var auto_read_terrain := true

var published_frames := 0
var rejected_results := 0
var last_job_msec := 0
var last_error := ""

var _env: Object = null
var _level := ""
var _materials: Array[ShaderMaterial] = []
var _cascade_count := 0
var _disp_textures: Array[ImageTexture] = []
var _normal_textures: Array[ImageTexture] = []
var _resolutions := PackedInt32Array()
var _bound_count := 0
var _job: WaterJob = null
var _task_id := -1
var _generation := 0
var _origin_msec := -1
var _sim_msec := 0          # simulation clock: sum of clamped frame advances
var _last_tick_msec := -1
var _last_request_msec := -1000000
var _failures := 0
var _terrain_state := 0   # 0 wanted, 1 in flight or done, 2 unavailable
var _hidden_since := -1
var _retry_at_msec := 0
var _tree_last_msec := -1000000
var _tree_camera := Transform3D()
var _tree_fov := 0.0
var _tree_width := 0
var _tree_count := 0
var last_tree_tiles := PackedFloat32Array()   # centre x, centre z, width, level per tile
var _tree_version := -1


class WaterJob extends RefCounted:
	var core: Object
	var level := ""
	var kind := 0
	var generation := 0
	var time_ms := 0
	var terrain_input: Dictionary = {}
	var ok := false
	var error := ""
	var elapsed_msec := 0
	var displacement: Array[Image] = []
	var normal: Array[Image] = []
	var terrain: Dictionary = {}
	var terrain_binding: Dictionary = {}

	func run() -> void:
		var start := Time.get_ticks_msec()
		if kind == HighpolyNativeWater.KIND_TERRAIN:
			_run_terrain()
		else:
			_run_frame()
		elapsed_msec = Time.get_ticks_msec() - start

	# Native read with the level frozen at scheduling time; env.level is never
	# read on this thread. The binding's own mutex serialises core access.
	func _read(kind_name: String, detail: int) -> Dictionary:
		if core == null or not core.has_method("environment"):
			error = "native environment binding is unavailable"
			return {}
		var packet: Variant = core.call("environment", level, kind_name, detail)
		if not packet is PackedByteArray:
			error = "%s returned no packet" % kind_name
			return {}
		var result := HighpolyNativeWater.unpack_packet(packet)
		if not bool(result.get("ok", 0)):
			error = "%s failed: %s" % [kind_name, str(result.get("error", "unknown"))]
			return {}
		return result

	func _run_terrain() -> void:
		var data: Dictionary = terrain_input
		if data.is_empty(): data = _read("terrain_depth", 1024)
		if data.is_empty(): return
		terrain = data
		terrain_binding = HighpolyNativeWater.height_image(data, false)
		ok = terrain_binding.has("image")
		if not ok: error = "terrain heights unusable: %s" % str(terrain_binding.get("reason", "unknown"))

	func _run_frame() -> void:
		var frame := _read("water_frame", time_ms)
		if frame.is_empty(): return
		var count := int(frame.get("count", 0))
		var list_value: Variant = frame.get("resolutions", [])
		var resolutions: Array = list_value if list_value is Array else []
		if count < 0 or count > HighpolyNativeWater.MAX_CASCADES or resolutions.size() < count:
			error = "water_frame cascade metadata is inconsistent"
			return
		for i in range(count):
			var res := int(resolutions[i])
			var disp_value: Variant = frame.get("displacement%d" % i, null)
			var normal_value: Variant = frame.get("normal%d" % i, null)
			if res < 1 or res > 4096 or not disp_value is PackedByteArray or not normal_value is PackedByteArray:
				error = "water_frame cascade %d is missing" % i
				return
			var disp_bytes: PackedByteArray = disp_value
			var normal_bytes: PackedByteArray = normal_value
			if disp_bytes.size() != res * res * 16 or normal_bytes.size() != res * res * 16:
				error = "water_frame cascade %d has the wrong byte size" % i
				return
			var disp_image := Image.create_from_data(res, res, false, Image.FORMAT_RGBAF, disp_bytes)
			var normal_image := Image.create_from_data(res, res, false, Image.FORMAT_RGBAF, normal_bytes)
			# Unreal keeps a full wrap-filtered mip chain for both (WaterFFT.cpp ~759).
			disp_image.generate_mipmaps()
			normal_image.generate_mipmaps()
			displacement.append(disp_image)
			normal.append(normal_image)
		ok = true


# ------------------------------------------------------------------ material

static func material(surface: Dictionary, env) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	var notes := PackedStringArray()
	var shader := _shader()
	if shader == null:
		push_error("High Poly water: %s could not be loaded" % SHADER_FILE)
		return mat
	mat.shader = shader
	for key in PARENT_DEFAULTS: mat.set_shader_parameter(key, PARENT_DEFAULTS[key])
	var env_obj: Object = env as Object
	if env_obj == null:
		notes.append("no environment: surface is flat and untextured")
		_finish_notes(mat, notes)
		return mat
	if not bool(surface.get("native", false)):
		notes.append("surface dictionary lacks the native marker")
	var shared := _shared(env_obj)
	var water_value: Variant = env_obj.get("water")
	var water: Dictionary = water_value if water_value is Dictionary else {}
	var cascades_value: Variant = water.get("cascades", [])
	var cascades: Array = cascades_value if cascades_value is Array else []

	var variant := int(_num(surface, "variant", -1.0))
	if variant == 2:
		notes.append("variant 2 (region-banded) is undecoded: colours absent, FFT displacement only")
	elif variant != 0 and variant != 1:
		notes.append("unknown water variant %d" % variant)
	if int(_num(surface, "is_river", 0.0)) != 0:
		notes.append("river flow sampler (Serac:WaterRiverFlowSampler) is not ported")

	# Placement and cascades. Cascade UVs are relative to the surface centre
	# (Serac:WaterCascadeParams.WaterOrigin, TileOffset measured 0).
	mat.set_shader_parameter("water_origin", Vector2(_num_at(surface, "center", 0, 0.0), _num_at(surface, "center", 1, 0.0)))
	mat.set_shader_parameter("surface_height", _num(surface, "height", 0.0))
	# Unreal binds the FFT only when bSimulatedSurface = bOcean || OceanComponentVersion == 1
	# (BF6HighPoly.cpp 8240); other surfaces keep BF6FFTEnabled = 0 and stay flat.
	var simulated := int(_num(surface, "is_ocean", 0.0)) != 0 or int(_num(surface, "ocean_component_version", 0.0)) == 1
	if not surface.has("is_ocean"): notes.append("descriptor lacks is_ocean: simulation gated by ocean component only")
	mat.set_meta(SIMULATED_META, simulated)
	var texel := Vector4(1e6, 1e6, 1e6, 1e6)
	var valid_cascades := 0
	for i in range(MAX_CASCADES):
		var meta := Vector4(1.0, 0.0, 0.0, 0.0)
		if simulated and i < cascades.size() and cascades[i] is Dictionary:
			var row: Dictionary = cascades[i]
			var tile := _num(row, "tile_dimension", 0.0)
			var res := int(_num(row, "resolution", 0.0))
			if tile > 0.0 and res > 0:
				# Enabled (z) is raised by the driver once a real frame is bound.
				meta = Vector4(tile, _num(row, "choppiness", 0.0), 0.0, 1.0 if int(_num(row, "foam_enable", 0.0)) != 0 else 0.0)
				texel[i] = tile / float(res)
				valid_cascades += 1
		mat.set_shader_parameter("cascade%d" % i, meta)
	mat.set_shader_parameter("cascade_texel_m", texel)
	# The mesh's own subdivision, so the vertex shader can refuse to sample
	# displacement finer than the geometry can carry. Passed rather than
	# duplicated as a shader constant: a second copy stops matching the day the
	# patch changes, and the symptom is water that boils again.
	mat.set_shader_parameter("patch_quads", float(PATCH_QUADS))
	# CASCADE BISECTION, driven by an environment variable so it needs no UI and
	# no rebuild: BF6_WATER_CASCADES=1,1,0,0 turns the two fine cascades off.
	# Unset means all four on, which is the shipping behaviour. This exists
	# because three source-reasoned diagnoses of the boiling water were wrong and
	# the only instrument that has been reliable is looking at it.
	var mask := Vector4(1.0, 1.0, 1.0, 1.0)
	var spec := OS.get_environment("BF6_WATER_CASCADES")
	if not spec.is_empty():
		var parts := spec.split(",")
		for i in range(mini(parts.size(), 4)):
			mask[i] = 1.0 if parts[i].strip_edges() == "1" else 0.0
		notes.append("cascade mask %s from BF6_WATER_CASCADES" % str(mask))
	mat.set_shader_parameter("cascade_mask", mask)
	# A fifth entry, when given, silences the interactive Gerstner sum as well:
	# BF6_WATER_CASCADES=0,0,0,0,0 is then genuinely "no wave simulation".
	var inter := 1.0
	if not spec.is_empty():
		var p5 := spec.split(",")
		if p5.size() >= 5:
			inter = 1.0 if p5[4].strip_edges() == "1" else 0.0
	mat.set_shader_parameter("interactive_mask", inter)
	mat.set_shader_parameter("fft_enabled", 1.0 if valid_cascades > 0 else 0.0)
	if not simulated:
		notes.append("not a simulated surface (Unreal bSimulatedSurface false): flat")
	elif valid_cascades == 0:
		notes.append("level authors no ocean simulation cascades: flat surface")
	var amplitude := _num(surface, "wave_amplitude_scale", -1.0)
	if amplitude < 0.0:
		notes.append("wave_amplitude_scale absent: using 1")
		amplitude = 1.0
	mat.set_shader_parameter("amplitude", amplitude)

	# Selected-VS cascade-0 overlap.
	# OFF BY DEFAULT, as in Unreal (GWaterOverlapOverride = 0, BF6HighPoly.cpp
	# ~6080): the params2 transform samples cascade 0 with an 11.5:1 stretch,
	# which dominates the surface. OVERLAP_OVERRIDE -1 restores the authored flag.
	var overlap_on := int(_num(surface, "cascade_overlap_version", 0.0)) == 1 and int(_num(surface, "cascade_overlap_enabled", 0.0)) != 0
	if OVERLAP_OVERRIDE >= 0: overlap_on = OVERLAP_OVERRIDE == 1
	if overlap_on:
		mat.set_shader_parameter("overlap_params", _vec4(surface, "cascade_overlap_params", Vector4(0, 1, 0, 0)))
		mat.set_shader_parameter("overlap_params2", _vec4(surface, "cascade_overlap_params2", Vector4(1, 1, 1, 1)))
		mat.set_shader_parameter("overlap_height", _num(surface, "cascade_overlap_height_scale", 1.0))
	mat.set_shader_parameter("overlap_enabled", 1.0 if overlap_on else 0.0)

	# Shore attenuation, binding exactly as the Unreal MID does.
	var attenuation := int(_num(surface, "attenuation_type", 0.0))
	var shore_depth := _num(surface, "shore_depth_m", -1.0)
	if int(_num(surface, "shore_fade_valid", 0.0)) != 0 and shore_depth > 0.0:
		mat.set_shader_parameter("use_authored_shore", 1.0)
		mat.set_shader_parameter("shore_depth", shore_depth)
		mat.set_shader_parameter("additional_depth", maxf(_num(surface, "additional_water_depth_m", 0.0), -1e6))
		mat.set_shader_parameter("shore_blend", _vec4(surface, "shore_blend", Vector4(0, 0, 0, 1)))
	else:
		mat.set_shader_parameter("use_authored_shore", 0.0)
		mat.set_shader_parameter("additional_depth", 0.0)
		# Authored zero ShoreDepth (and None) is the game's own OFF gate.
		mat.set_shader_parameter("shore_depth", 0.0 if attenuation <= 1 else SHORE_FADE_DEFAULT_M)
	var mask_binding: Dictionary = shared["mask"]
	var use_mask := attenuation == 2 and mask_binding.has("atlas")
	if use_mask:
		mat.set_shader_parameter("mask_atlas", mask_binding["atlas"])
		mat.set_shader_parameter("mask_indirection", mask_binding["indirection"])
		mat.set_shader_parameter("mask_min", mask_binding["min"])
		mat.set_shader_parameter("mask_span", mask_binding["span"])
		mat.set_shader_parameter("mask_meta", mask_binding["meta"])
	elif attenuation == 2:
		notes.append("CoarseMask selected but utility raster unavailable (%s): terrain smoothstep fallback" % str(mask_binding.get("reason", "absent")))
	elif attenuation >= 3:
		notes.append("attenuation type %d (CoarseAndDetailMask) unsupported: terrain smoothstep fallback" % attenuation)
	mat.set_shader_parameter("mask_available", 1.0 if use_mask else 0.0)

	var level_binding: Dictionary = shared["level_height"]
	bind_height(mat, "level", level_binding)
	var terrain_binding: Dictionary = shared["terrain"]
	bind_height(mat, "terrain", terrain_binding)

	# Detail fade and the pixel sheets.
	var fade_start := _num(surface, "detail_fade_start_m", -1.0)
	var fade_end := _num(surface, "detail_fade_end_m", -1.0)
	if fade_start >= 0.0 and fade_end > fade_start:
		mat.set_shader_parameter("detail_fade_start", fade_start)
		mat.set_shader_parameter("detail_fade_end", fade_end)
	var micro := _surface_texture(env_obj, shared, int(_num(surface, "detail_normal", -1.0)))
	var foam_sheet := _surface_texture(env_obj, shared, int(_num(surface, "foam_normal", -1.0)))
	var contact := _surface_texture(env_obj, shared, int(_num(surface, "contact_foam", -1.0)))
	var broad := _surface_texture(env_obj, shared, int(_num(surface, "foam_rgb2", -1.0)))
	var noise := _surface_texture(env_obj, shared, int(_num(surface, "noise", -1.0)))
	if micro != null: mat.set_shader_parameter("micro_sheet", micro)
	if foam_sheet != null: mat.set_shader_parameter("foam_sheet", foam_sheet)
	if contact != null: mat.set_shader_parameter("contact_foam", contact)
	if broad != null: mat.set_shader_parameter("broad_pattern", broad)
	if noise != null: mat.set_shader_parameter("noise_tex", noise)
	# UseDetailSheets = sheets && GWaterUseFastSheetDetail, which is false in
	# current Unreal (6053, 8319). Authored scales are still bound.
	mat.set_shader_parameter("use_sheets", 0.0)
	_set_if(mat, "micro_uv_scale", _num(surface, "micro_sheet_uv_scale", -1.0), 0.0)
	_set_if(mat, "foam_uv_scale", _num(surface, "foam_sheet_uv_scale", -1.0), 0.0)
	_set_if(mat, "micro_flow_speed", _num(surface, "micro_sheet_flow_speed", -1.0), 0.0)
	_set_if(mat, "detail_strength", _num(surface, "micro_sheet_normal_strength", -1.0), 0.0)
	_set_if(mat, "foam_sheet_strength", _num(surface, "foam_sheet_normal_strength", -1.0), 0.0)
	mat.set_shader_parameter("use_contact", 1.0 if contact != null else 0.0)
	var contact_divisor := _num(surface, "contact_world_divisor_m", -1.0)
	if contact_divisor > 0.0: mat.set_shader_parameter("contact_divisor", contact_divisor)
	var contact_low := _num(surface, "contact_remap_low", -1.0)
	if contact_low >= 0.0: mat.set_shader_parameter("contact_remap_low", contact_low)
	var contact_gain := _num(surface, "contact_gain", -1.0)
	if contact_gain >= 0.0: mat.set_shader_parameter("contact_gain", contact_gain)
	var composite_low := _num(surface, "foam_composite_low", -1.0)
	if composite_low >= 0.0: mat.set_shader_parameter("composite_low", composite_low)
	var composite_high := _num(surface, "foam_composite_high", -1.0)
	if composite_high >= 0.0: mat.set_shader_parameter("composite_high", composite_high)

	# Ocean-family cascade foam chain.
	var weights := _vec4(surface, "cascade_foam_weight", Vector4(-1, -1, -1, -1))
	var chain := weights.x >= 0.0 and weights.y >= 0.0 and weights.z >= 0.0 and weights.w >= 0.0
	mat.set_shader_parameter("foam_chain", 1.0 if chain else 0.0)
	if chain: mat.set_shader_parameter("foam_weights", weights)
	var suppression := _num(surface, "shore_foam_suppression", -1.0)
	if suppression >= 0.0: mat.set_shader_parameter("shore_suppression", suppression)
	var draw_threshold := _num(surface, "foam_threshold", -1.0)
	if draw_threshold >= 0.0: mat.set_shader_parameter("draw_threshold", draw_threshold)
	var contrast := _num(surface, "foam_contrast_divisor", -1.0)
	if contrast > 0.0: mat.set_shader_parameter("foam_contrast", contrast)

	# MP_Isolated extended draw graph (live depot cbuffer, version gated).
	var graph_version := int(_num(surface, "extended_graph_version", 0.0))
	var use_broad := broad != null and noise != null and graph_version == 1
	mat.set_shader_parameter("use_broad", 1.0 if use_broad else 0.0)
	# THE BROAD PATTERN DOES NOT SCROLL, and this is the value that says so.
	#
	# The shader carried a placeholder `broad_time_scale = 1.0` that nothing ever
	# set, so the broad crest sheet slid across the surface every frame. That is
	# what "the water is boiling - tiny waves inside the swells moving really
	# fast" was, and it survived three wrong diagnoses aimed at the FFT cascades
	# and the mesh because the culprit was a hardcoded constant in an unrelated
	# part of the shader that no data feeds.
	#
	# NOT READ FROM THE GAME, and there is nowhere to read it from: the core's
	# header says the broad sheet's three motion coefficients "are literals in
	# the current shipped permutation", i.e. baked into the game's compiled pixel
	# shader rather than stored as depot constants. So this is tuned by eye and
	# says so. The pattern is a SPATIAL modulation - where crests form - and
	# holding it still is what reads correctly; recovering the real coefficient
	# means decoding that permutation, which has not been done.
	mat.set_shader_parameter("broad_time_scale", BROAD_TIME_SCALE)
	mat.set_shader_parameter("graph_version", 1.0 if graph_version == 1 else 0.0)
	mat.set_shader_parameter("foam_wave_height", UNREAL_FOAM_WAVE_HEIGHT_M if use_broad else 0.0)
	# Provisional Unreal eWave stand-in: simulated surfaces without the broad field.
	var interactive := simulated and not use_broad
	mat.set_shader_parameter("interactive_enabled", 1.0 if interactive else 0.0)
	mat.set_shader_parameter("interactive_height", UNREAL_FOAM_WAVE_HEIGHT_M if interactive else 0.0)
	mat.set_shader_parameter("interactive_length", UNREAL_INTERACTIVE_LENGTH_M)
	mat.set_shader_parameter("interactive_rate", UNREAL_INTERACTIVE_RATE)
	if true:
		var cb := PackedColorArray()
		var rows_value: Variant = surface.get("extended_cb1", [])
		var rows: Array = rows_value if rows_value is Array else []
		for r in range(22):
			var c := Color(0, 0, 0, 0)
			if r < rows.size() and rows[r] is Array:
				var entry: Array = rows[r]
				if entry.size() >= 4:
					c = Color(_float(entry[0], 0.0), _float(entry[1], 0.0), _float(entry[2], 0.0), _float(entry[3], 0.0))
			cb.append(c)
		mat.set_shader_parameter("graph_cb", cb)
	if graph_version == 1 and not use_broad:
		notes.append("extended draw graph selected but broad pattern/noise texture missing: broad foam off")
	# Gerstner crest: every current Unreal WaterMaterialFor call passes Waves=nullptr
	# (10728, 10893, 12982, 17305), so WaveGain keeps its 0 default and the crest
	# term is exactly 0. The shader keeps crest = 0; DeriveWaves is dead code.

	# Absorption / extinction (Unreal 8623: decoded extinction only).
	var extinction := _vec3(surface, "extinction", Vector3(-1, -1, -1))
	var absorption := extinction.is_finite() and extinction.x >= 0.0 and extinction.y >= 0.0 and extinction.z >= 0.0 \
		and _num(surface, "absorption_distance_m", -1.0) > 0.01
	if not absorption:
		notes.append("no decoded extinction: using Unreal's hue/brightness preview model")
		var c := _vec3(surface, "shallow", Vector3(0.10, 0.45, 0.55))
		if c.x < 0.0: c = Vector3(0.10, 0.45, 0.55)
		var peak := maxf(c.x, maxf(c.y, c.z))
		var hue := c / peak if peak > 1e-4 else Vector3(0.2, 0.9, 1.0)
		# Same preview calibration as Unreal, kept per metre in Godot.
		var scatter := hue * hue * sqrt(clampf(peak, 0.0, 1.0)) * 0.22
		extinction = scatter + (Vector3.ONE - hue) * 0.50 + Vector3.ONE * 0.02
		mat.set_shader_parameter("extinction", extinction)
		mat.set_shader_parameter("scatter_albedo", scatter / extinction)
	mat.set_shader_parameter("absorption_available", 1.0)
	if absorption:
		# Unreal's stated scatter/absorb MODEL: flat scatter = min(extinction) x WaterAlbedo(1).
		var flat := maxf(minf(extinction.x, minf(extinction.y, extinction.z)), 0.0)
		var albedo := Vector3(
			minf(flat, extinction.x) / extinction.x if extinction.x > 0.0 else 0.0,
			minf(flat, extinction.y) / extinction.y if extinction.y > 0.0 else 0.0,
			minf(flat, extinction.z) / extinction.z if extinction.z > 0.0 else 0.0)
		mat.set_shader_parameter("extinction", extinction)
		mat.set_shader_parameter("scatter_albedo", albedo)
	mat.set_shader_parameter("surface_tint", unreal_surface_tint(surface))

	# Roughness and composite foam (live VisualEnvironment OceanComponentData).
	var bias := _num(surface, "smoothness_bias", -1.0)
	if bias >= 0.0: mat.set_shader_parameter("water_roughness", clampf(1.0 - bias, 0.01, 0.99))
	var full_foam := _num(surface, "smoothness_full_foam", -1.0)
	if full_foam >= 0.0:
		mat.set_shader_parameter("foam_roughness", clampf(1.0 - full_foam, 0.01, 0.99))
	elif bias >= 0.0:
		mat.set_shader_parameter("foam_roughness", clampf(1.0 - bias, 0.01, 0.99))
	mat.set_shader_parameter("water_specular", WATER_SPECULAR)
	if int(_num(surface, "ocean_component_version", 0.0)) == 1:
		var composite_rough := _num(surface, "foam_roughness", -1.0)
		if composite_rough >= 0.0: mat.set_shader_parameter("foam_roughness", clampf(composite_rough, 0.0, 1.0))
		var foam_tint := _vec3(surface, "foam_tint", Vector3(-1, -1, -1))
		if foam_tint.x >= 0.0: mat.set_shader_parameter("foam_tint", foam_tint)
		var ramp := _num(surface, "foam_depth_ramp_m", -1.0)
		if ramp >= 0.0: mat.set_shader_parameter("foam_depth_ramp", ramp)
	else:
		notes.append("no active OceanComponentData: Unreal default foam tint and 0.5 m foam depth ramp")
	_finish_notes(mat, notes)
	return mat


# Unreal SurfaceTint (8558-8573): SurfaceColour when authored, else the
# normalised hue of Shallow (or the parent default colour) times SurfaceAlbedo.
static func unreal_surface_tint(surface: Dictionary) -> Vector3:
	var colour := _vec3(surface, "surface_colour", Vector3(-1, -1, -1))
	if colour.x >= 0.0: return colour
	var c := _vec3(surface, "shallow", Vector3(-1, -1, -1))
	if c.x < 0.0: c = Vector3(0.10, 0.45, 0.55)
	var peak := maxf(c.x, maxf(maxf(c.y, 0.0), maxf(c.z, 0.0)))
	var hue := c / peak if peak > 1e-4 else Vector3(0.2, 0.9, 1.0)
	return hue * UNREAL_SURFACE_ALBEDO


static func _set_if(mat: ShaderMaterial, uniform_name: String, value: float, minimum: float) -> void:
	if value >= minimum: mat.set_shader_parameter(uniform_name, value)


# Same protocol as BF6Environment.unpack, kept here so worker jobs need no env.
static func unpack_packet(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 4: return {"ok": 0, "error": "short environment packet"}
	var count := bytes.decode_u32(0)
	if count > bytes.size() - 4: return {"ok": 0, "error": "truncated environment metadata"}
	var parsed: Variant = JSON.parse_string(bytes.slice(4, 4 + count).get_string_from_utf8())
	if not parsed is Dictionary: return {"ok": 0, "error": "invalid environment metadata"}
	var result: Dictionary = parsed
	if int(result.get("version", 0)) != 1: return {"ok": 0, "error": "unsupported environment protocol"}
	var start := 4 + count
	for key in result.keys():
		var field: Variant = result[key]
		if field is Dictionary and (field as Dictionary).has("offset") and (field as Dictionary).has("bytes"):
			var info: Dictionary = field
			var offset := int(info["offset"])
			var size := int(info["bytes"])
			if offset < 0 or size < 0 or offset > bytes.size() - start or size > bytes.size() - start - offset:
				return {"ok": 0, "error": "environment block exceeds packet"}
			result[key] = bytes.slice(start + offset, start + offset + size)
	return result


# One unit square of PATCH_QUADS x PATCH_QUADS quads in XZ, centred, facing up.
static func patch_mesh() -> ArrayMesh:
	if _patch_cache != null: return _patch_cache
	var n := PATCH_QUADS
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for gz in range(n + 1):
		for gx in range(n + 1):
			verts.append(Vector3(float(gx) / n - 0.5, 0.0, float(gz) / n - 0.5))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(gx) / n, float(gz) / n))
	var idx := PackedInt32Array()
	for gz in range(n):
		for gx in range(n):
			var i0 := gz * (n + 1) + gx
			idx.append_array([i0, i0 + 1, i0 + n + 1, i0 + 1, i0 + n + 2, i0 + n + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	_patch_cache = ArrayMesh.new()
	_patch_cache.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return _patch_cache


# A water surface drawn as draw-tree tiles. Empty until the driver's first
# tree; the tiles are world-space XZ at the surface height. Bounds are the
# axis-aligned box of the (possibly rotated) authored rectangle, which is what
# Unreal hands its tree.
static func tiled_surface(center: Vector2, size: Vector2, yaw: float, height: float, material: Material) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = patch_mesh()
	mm.instance_count = 0
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.position = Vector3(0.0, height, 0.0)
	var c := absf(cos(yaw))
	var s := absf(sin(yaw))
	var half := Vector2(size.x * c + size.y * s, size.x * s + size.y * c) * 0.5
	mmi.set_meta(TILED_META, PackedFloat32Array([center.x - half.x, center.y - half.y, center.x + half.x, center.y + half.y, height]))
	# Tiles reach past the rectangle (the tree clips by intersection) and the
	# vertex shader lifts them, so cull against the whole tree root.
	mmi.custom_aabb = AABB(Vector3(center.x - TREE_ROOT_M, -64.0, center.y - TREE_ROOT_M), Vector3(TREE_ROOT_M * 2.0, 128.0, TREE_ROOT_M * 2.0))
	mm.custom_aabb = mmi.custom_aabb
	return mmi


static func attach(parent: Node, env, materials: Array) -> Node:
	var driver := HighpolyNativeWater.new()
	driver.name = "NativeWaterSimulation"
	driver.setup(env as Object, materials)
	if parent != null: parent.add_child(driver)
	return driver


# ------------------------------------------------------------------ driver

func setup(env_obj: Object, materials: Array) -> void:
	_shutdown_job()
	_release_textures()
	_generation += 1
	_env = env_obj
	_level = str(env_obj.get("level")) if env_obj != null else ""
	_materials.clear()
	for item in materials:
		if item is ShaderMaterial: _materials.append(item)
	_cascade_count = 0
	if env_obj != null:
		var water_value: Variant = env_obj.get("water")
		if water_value is Dictionary:
			var cascades_value: Variant = (water_value as Dictionary).get("cascades", [])
			if cascades_value is Array: _cascade_count = mini((cascades_value as Array).size(), MAX_CASCADES)
	_origin_msec = -1
	_sim_msec = 0
	_last_tick_msec = -1
	_failures = 0
	_hidden_since = -1
	_retry_at_msec = 0
	_last_request_msec = -1000000
	last_error = ""
	published_frames = 0
	_terrain_state = 0 if auto_read_terrain else 2


func _process(_delta: float) -> void:
	_collect()
	_update_tree(false)
	var now := Time.get_ticks_msec()
	if _env == null or _materials.is_empty() or not _may_simulate():
		if _hidden_since < 0: _hidden_since = now
		return
	if _hidden_since >= 0:
		# Pause the simulation clock while hidden so foam history sees no jump.
		if _origin_msec >= 0: _origin_msec += now - _hidden_since
		_hidden_since = -1
		_last_tick_msec = now
	if _origin_msec < 0: _origin_msec = now
	if _last_tick_msec >= 0: _sim_msec += clampi(now - _last_tick_msec, 0, MAX_STEP_MSEC)
	_last_tick_msec = now
	# The material clock runs every frame, like Unreal's Time expression; only
	# the FFT textures arrive in steps.
	var seconds := float(_sim_msec) * 0.001
	for mat in _materials: mat.set_shader_parameter("sim_time", seconds)
	if _task_id >= 0 or now < _retry_at_msec: return
	var core_value: Variant = _env.get("core")
	if not core_value is Object: return
	if not _any_simulated(): _cascade_count = 0
	if _terrain_state == 0 and (published_frames > 0 or _cascade_count == 0):
		if _terrain_bound(): _terrain_state = 1
		else:
			_start_job(KIND_TERRAIN, 0)
			return
	if now - _last_request_msec < FRAME_INTERVAL_MSEC: return
	if _cascade_count == 0:
		_last_request_msec = now
		return
	_start_job(KIND_FRAME, _sim_msec)


func _view_camera() -> Camera3D:
	if Engine.is_editor_hint():
		var vp := EditorInterface.get_editor_viewport_3d(0)
		if vp != null: return vp.get_camera_3d()
		return null
	return get_viewport().get_camera_3d() if get_viewport() != null else null


func _tiled_surfaces() -> Array:
	var out: Array = []
	var parent := get_parent()
	if parent == null: return out
	for child in parent.get_children():
		if child is MultiMeshInstance3D and (child as Node).has_meta(TILED_META):
			out.append(child)
	return out


# Rebuild every tiled surface's instances from the core's draw tree, on
# Unreal's cadence. Returns the tile count of the last surface built.
func _update_tree(force: bool) -> int:
	var parent := get_parent()
	if parent is Node3D and not (parent as Node3D).is_visible_in_tree(): return _tree_count
	var surfaces := _tiled_surfaces()
	if surfaces.is_empty(): return 0
	var cam := _view_camera()
	if cam == null: return _tree_count
	var now := Time.get_ticks_msec()
	var vp_size := cam.get_viewport().get_visible_rect().size
	var width := maxi(int(vp_size.x), 1)
	var aspect := vp_size.x / maxf(vp_size.y, 1.0)
	var hfov := cam.fov
	if cam.keep_aspect == Camera3D.KEEP_HEIGHT:
		hfov = rad_to_deg(2.0 * atan(tan(deg_to_rad(cam.fov) * 0.5) * aspect))
	var xf := cam.global_transform
	var version := 0
	for s in surfaces: version = hash([version, s.get_instance_id()])
	if not force and version == _tree_version:
		if float(now - _tree_last_msec) < 1000.0 / TREE_MAX_HZ: return _tree_count
		var moved := xf.origin.distance_to(_tree_camera.origin) >= TREE_MOVE_M
		var turned := rad_to_deg((-xf.basis.z).angle_to(-_tree_camera.basis.z)) >= TREE_TURN_DEG
		if not moved and not turned and absf(hfov - _tree_fov) < 0.1 and width == _tree_width:
			return _tree_count
	_tree_last_msec = now
	_tree_camera = xf
	_tree_fov = hfov
	_tree_width = width
	_tree_version = version
	var core_value: Variant = _env.get("core") if _env != null else null
	var forward := -xf.basis.z
	for s in surfaces:
		var mmi := s as MultiMeshInstance3D
		var b: PackedFloat32Array = mmi.get_meta(TILED_META)
		var tiles := PackedFloat32Array()
		if core_value is Object and (core_value as Object).has_method("water_draw_tree"):
			# The core's frame is (x, y) plane, z up: Godot passes (x, z, y).
			tiles = (core_value as Object).call("water_draw_tree", PackedFloat32Array([
				xf.origin.x, xf.origin.z, xf.origin.y, forward.x, forward.z, hfov, width,
				b[0], b[1], b[2], b[3], b[4], PATCH_QUADS, TREE_TILE_CAP, TREE_OFF_VIEW_DEPTH]))
		else:
			# An older binding: one tile over the whole rectangle, still drawn.
			tiles = PackedFloat32Array([(b[0] + b[2]) * 0.5, (b[1] + b[3]) * 0.5, maxf(b[2] - b[0], b[3] - b[1]), 0.0])
		last_tree_tiles = tiles
		var count := tiles.size() / 4
		var buf := PackedFloat32Array()
		buf.resize(count * 12)
		for i in range(count):
			var w := tiles[i * 4 + 2]
			var o := i * 12
			# Basis (w, 1, w) and origin (cx, 0, cz) relative to the node at height h.
			buf[o] = w; buf[o + 1] = 0.0; buf[o + 2] = 0.0; buf[o + 3] = tiles[i * 4]
			buf[o + 4] = 0.0; buf[o + 5] = 1.0; buf[o + 6] = 0.0; buf[o + 7] = 0.0
			buf[o + 8] = 0.0; buf[o + 9] = 0.0; buf[o + 10] = w; buf[o + 11] = tiles[i * 4 + 1]
		var mm := mmi.multimesh
		if mm.instance_count != count: mm.instance_count = count
		if count > 0: mm.buffer = buf
		_tree_count = count
	return _tree_count


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_PREDELETE:
		_shutdown_job()
		_generation += 1
		_release_textures()
		if what == NOTIFICATION_PREDELETE:
			_materials.clear()
			_env = null


func _may_simulate() -> bool:
	if not is_inside_tree(): return false
	if str(_env.get("level")) != _level: return false
	var parent := get_parent()
	if parent is Node3D and not (parent as Node3D).is_visible_in_tree(): return false
	return true


func _start_job(kind: int, time_ms: int) -> void:
	var job := WaterJob.new()
	job.core = _env.get("core")
	job.level = _level
	job.kind = kind
	job.generation = _generation
	job.time_ms = time_ms
	if kind == KIND_TERRAIN:
		_terrain_state = 1
		var terrain_value: Variant = _env.get("terrain")
		if terrain_value is Dictionary: job.terrain_input = terrain_value
	_job = job
	_last_request_msec = Time.get_ticks_msec()
	_task_id = WorkerThreadPool.add_task(job.run, false, "BF6 native water")


func _collect() -> void:
	if _task_id < 0 or not WorkerThreadPool.is_task_completed(_task_id): return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	var job := _job
	_job = null
	if job == null: return
	last_job_msec = job.elapsed_msec
	if _env == null or job.generation != _generation or job.level != _level or str(_env.get("level")) != _level:
		rejected_results += 1
		return
	if not job.ok:
		last_error = job.error
		push_warning("High Poly water: " + job.error)
		if job.kind == KIND_TERRAIN: _terrain_state = 2
		else:
			_failures = mini(_failures + 1, MAX_FAILURES)
			_retry_at_msec = Time.get_ticks_msec() + mini(RETRY_BASE_MSEC << mini(_failures, 10), RETRY_CAP_MSEC)
		return
	_failures = 0
	_retry_at_msec = 0
	if job.kind == KIND_TERRAIN: _publish_terrain(job)
	else: _publish_frame(job)


func _publish_frame(job: WaterJob) -> void:
	var count := mini(mini(job.displacement.size(), job.normal.size()), MAX_CASCADES)
	if _resolutions.size() != count: _resolutions.resize(count)
	var rebind := count != _bound_count
	for i in range(count):
		var disp := job.displacement[i]
		var normal := job.normal[i]
		if i >= _disp_textures.size():
			_disp_textures.append(ImageTexture.create_from_image(disp))
			_normal_textures.append(ImageTexture.create_from_image(normal))
			rebind = true
		elif _resolutions[i] == disp.get_width():
			_disp_textures[i].update(disp)
			_normal_textures[i].update(normal)
		else:
			_disp_textures[i].set_image(disp)
			_normal_textures[i].set_image(normal)
		_resolutions[i] = disp.get_width()
	for mat in _materials:
		if not bool(mat.get_meta(SIMULATED_META, false)): continue
		if rebind:
			for i in range(MAX_CASCADES):
				var meta_value: Variant = mat.get_shader_parameter("cascade%d" % i)
				var meta: Vector4 = meta_value if meta_value is Vector4 else Vector4(1, 0, 0, 0)
				if i < count and meta.x > 0.0:
					mat.set_shader_parameter("disp%d" % i, _disp_textures[i])
					mat.set_shader_parameter("nf%d" % i, _normal_textures[i])
					meta.z = 1.0
				else:
					meta.z = 0.0
				mat.set_shader_parameter("cascade%d" % i, meta)
	_bound_count = count
	published_frames += 1


func _publish_terrain(job: WaterJob) -> void:
	# The compact depth read is never published as env.terrain.
	var binding := job.terrain_binding
	binding["texture"] = ImageTexture.create_from_image(binding["image"])
	binding.erase("image")
	var shared := _shared(_env)
	shared["terrain"] = binding
	for mat in _materials: bind_height(mat, "terrain", binding)


func _any_simulated() -> bool:
	for mat in _materials:
		if bool(mat.get_meta(SIMULATED_META, false)): return true
	return false


func _terrain_bound() -> bool:
	if _env == null or not _env.has_meta(SHARED_META): return false
	var shared := _shared(_env)
	var binding: Dictionary = shared["terrain"]
	return binding.has("texture")


func _shutdown_job() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	if _job != null: rejected_results += 1
	_job = null


func _release_textures() -> void:
	for mat in _materials:
		for i in range(MAX_CASCADES):
			mat.set_shader_parameter("disp%d" % i, null)
			mat.set_shader_parameter("nf%d" % i, null)
			var meta_value: Variant = mat.get_shader_parameter("cascade%d" % i)
			if meta_value is Vector4:
				var meta: Vector4 = meta_value
				meta.z = 0.0
				mat.set_shader_parameter("cascade%d" % i, meta)
	_disp_textures.clear()
	_normal_textures.clear()
	_resolutions.resize(0)
	_bound_count = 0
	_origin_msec = -1
	_sim_msec = 0
	_last_tick_msec = -1


# ------------------------------------------------------------------ shared data

static func _shader() -> Shader:
	if _shader_cache == null:
		var own: Script = HighpolyNativeWater
		var path := own.resource_path.get_base_dir().path_join(SHADER_FILE)
		var loaded: Variant = load(path)
		if loaded is Shader: _shader_cache = loaded
	return _shader_cache


# One set of height/mask/texture uploads per environment, shared by every
# surface. Built from data BF6Environment.read_water already holds.
static func _shared(env_obj: Object) -> Dictionary:
	if env_obj.has_meta(SHARED_META):
		var existing: Variant = env_obj.get_meta(SHARED_META)
		if existing is Dictionary: return existing
	var shared := {"textures": {}}
	var level_value: Variant = env_obj.get("water_height")
	var level_image := height_image(level_value if level_value is Dictionary else {}, true)
	shared["level_height"] = _upload_height(level_image)
	var terrain_value: Variant = env_obj.get("terrain")
	var terrain_image := height_image(terrain_value if terrain_value is Dictionary else {}, false)
	shared["terrain"] = _upload_height(terrain_image)
	var mask_value: Variant = env_obj.get("mask")
	shared["mask"] = _mask_binding(mask_value if mask_value is Dictionary else {})
	env_obj.set_meta(SHARED_META, shared)
	return shared


static func _upload_height(binding: Dictionary) -> Dictionary:
	if not binding.has("image"): return binding
	binding["texture"] = ImageTexture.create_from_image(binding["image"])
	binding.erase("image")
	return binding


# Thread-safe: builds an RG8 Image whose bytes are the raw little-endian
# uint16 heights (R low, G high). Metres = raw * height_scale / 65536; the
# world_min.y bound is not a bias (BF6HighPoly.cpp MakeHeightTexture).
static func height_image(data: Dictionary, reject_all_zero: bool) -> Dictionary:
	if data.is_empty() or int(_num(data, "present", 0.0)) != 1: return {"reason": "absent"}
	var width := int(_num(data, "width", 0.0))
	var height := int(_num(data, "height", 0.0))
	var heights_value: Variant = data.get("preview_heights", data.get("heights", null))
	if data.has("preview_heights"):
		width = int(data.get("preview_width", 0))
		height = int(data.get("preview_height", 0))
	if not heights_value is PackedByteArray: return {"reason": "heights block missing"}
	var heights: PackedByteArray = heights_value
	if width < 1 or height < 1 or heights.size() != width * height * 2: return {"reason": "heights size mismatch"}
	if width > TEXTURE_LIMIT or height > TEXTURE_LIMIT:
		return {"reason": "height grid exceeds texture limit; compact native read required"}
	if reject_all_zero and heights.count(0) == heights.size(): return {"reason": "all-zero grid"}
	var min_x := _num_at(data, "world_min", 0, NAN)
	var min_y := _num_at(data, "world_min", 1, 0.0)
	var min_z := _num_at(data, "world_min", 2, NAN)
	var max_x := _num_at(data, "world_max", 0, NAN)
	var max_y := _num_at(data, "world_max", 1, 0.0)
	var max_z := _num_at(data, "world_max", 2, NAN)
	if is_nan(min_x) or is_nan(min_z) or is_nan(max_x) or is_nan(max_z): return {"reason": "bounds missing"}
	var scale := _num(data, "height_scale", 0.0)
	var metres_per_raw := scale / 65536.0 if scale > 0.0 else maxf(0.001, max_y - min_y) / 65535.0
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RG8, heights)
	if image.is_empty(): return {"reason": "height image creation failed"}
	var span := Vector2(maxf(1.0, max_x - min_x), maxf(1.0, max_z - min_z))
	var size := Vector2(image.get_width(), image.get_height())
	return {"image": image, "min": Vector2(min_x, min_z), "span": span, "size": size,
		"metres_per_raw": metres_per_raw, "texel_m": span / size}


static func bind_height(mat: ShaderMaterial, prefix: String, binding: Dictionary) -> void:
	var ok := binding.has("texture")
	mat.set_shader_parameter(prefix + "_available", 1.0 if ok else 0.0)
	if not ok: return
	mat.set_shader_parameter(prefix + "_heights", binding["texture"])
	mat.set_shader_parameter(prefix + "_min", binding["min"])
	mat.set_shader_parameter(prefix + "_span", binding["span"])
	mat.set_shader_parameter(prefix + "_size", binding["size"])
	mat.set_shader_parameter(prefix + "_metres_per_raw", binding["metres_per_raw"])
	mat.set_shader_parameter(prefix + "_texel_m", binding["texel_m"])


# CoarseMask: R8 pages as a Texture2DArray (layer-major bytes sliced per page),
# indirection uint32 LE uploaded unchanged as RGBA8 and unpacked in the shader.
static func _mask_binding(data: Dictionary) -> Dictionary:
	if data.is_empty() or int(_num(data, "present", 0.0)) != 1:
		return {"reason": str(data.get("reason", "absent"))}
	var meta_value: Variant = data.get("mask", {})
	var meta: Dictionary = meta_value if meta_value is Dictionary else {}
	var tile := int(_num(meta, "tile_side", 0.0))
	var pages := int(_num(meta, "page_count", 0.0))
	var side := int(_num(meta, "indirection_side", 0.0))
	var atlas_value: Variant = data.get("atlas", null)
	var indirection_value: Variant = data.get("indirection", null)
	if tile < 1 or pages < 1 or side < 1 or not atlas_value is PackedByteArray or not indirection_value is PackedByteArray:
		return {"reason": "mask metadata incomplete"}
	var atlas: PackedByteArray = atlas_value
	var indirection: PackedByteArray = indirection_value
	if atlas.size() != tile * tile * pages or indirection.size() != side * side * 4:
		return {"reason": "mask block size mismatch"}
	if side > TEXTURE_LIMIT or tile > TEXTURE_LIMIT: return {"reason": "mask exceeds texture limit"}
	var images: Array[Image] = []
	var page_bytes := tile * tile
	for p in range(pages):
		images.append(Image.create_from_data(tile, tile, false, Image.FORMAT_R8, atlas.slice(p * page_bytes, (p + 1) * page_bytes)))
	var array := Texture2DArray.new()
	if array.create_from_images(images) != OK: return {"reason": "mask atlas upload failed"}
	var indirection_texture := ImageTexture.create_from_image(Image.create_from_data(side, side, false, Image.FORMAT_RGBA8, indirection))
	var min_v := Vector2(_num_at(meta, "bounds_min", 0, 0.0), _num_at(meta, "bounds_min", 1, 0.0))
	var max_v := Vector2(_num_at(meta, "bounds_max", 0, 0.0), _num_at(meta, "bounds_max", 1, 0.0))
	return {"atlas": array, "indirection": indirection_texture, "min": min_v, "span": max_v - min_v,
		"meta": Vector4(_num(meta, "interior_side", 0.0), _num(meta, "border", 0.0), float(tile), float(side))}


static func _surface_texture(env_obj: Object, shared: Dictionary, id: int) -> Texture2D:
	if id < 0: return null
	var cache: Dictionary = shared["textures"]
	if cache.has(id): return cache[id]
	var textures_value: Variant = env_obj.get("textures")
	if not textures_value is Dictionary: return null
	var image_value: Variant = (textures_value as Dictionary).get(id, null)
	if not image_value is Image: return null
	# Uploaded in its decoded or BCn format; no conversion, normal packing intact.
	var texture := ImageTexture.create_from_image(image_value)
	cache[id] = texture
	return texture


static func _finish_notes(mat: ShaderMaterial, notes: PackedStringArray) -> void:
	mat.set_meta(DIAGNOSTICS_META, notes)
	if not notes.is_empty(): push_warning("High Poly water: " + "; ".join(notes))


static func _float(value: Variant, fallback: float) -> float:
	if value is float or value is int: return float(value)
	return fallback


static func _num(d: Dictionary, key: String, fallback: float) -> float:
	return _float(d.get(key, null), fallback)


static func _num_at(d: Dictionary, key: String, index: int, fallback: float) -> float:
	var value: Variant = d.get(key, null)
	if not value is Array: return fallback
	var items: Array = value
	return _float(items[index], fallback) if index < items.size() else fallback


static func _vec3(d: Dictionary, key: String, fallback: Vector3) -> Vector3:
	return Vector3(_num_at(d, key, 0, fallback.x), _num_at(d, key, 1, fallback.y), _num_at(d, key, 2, fallback.z))


static func _vec4(d: Dictionary, key: String, fallback: Vector4) -> Vector4:
	return Vector4(_num_at(d, key, 0, fallback.x), _num_at(d, key, 1, fallback.y),
		_num_at(d, key, 2, fallback.z), _num_at(d, key, 3, fallback.w))
