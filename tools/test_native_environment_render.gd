extends SceneTree
# Bounded GPU smoke/regression render of the native environment adapters
# (bf6_environment.gd, highpoly_native_terrain.gd, highpoly_native_water.gd and
# their shaders) against the installed game. Real renders are compared with
# deliberately perturbed controls on the same GPU, same camera and same frame
# state. This proves the adapters draw and respond on a real Forward+ Vulkan
# device; it makes no claim of visual parity with Unreal or the game.
#
# Needs a windowed (non --headless) run in a project whose GDExtension provides
# BF6Core, with the adapter files at res:// or res://addons/highpoly_toggle/:
#   godot --path <project> --rendering-driver vulkan --rendering-method forward_plus \
#     -s res://test_native_environment_render.gd -- [--level=NAME] [--game=PATH]
#     [--surface=INDEX] [--timeout=SECONDS] [--frames=N]
# The runner must also fail the run on "SHADER ERROR" between the
# ENVIRONMENT_RENDER_BEGIN/END markers; the in-script log scan is best effort.
#
# Exit codes: 0 pass, 1 fail, 2 not a GPU run (headless/dummy/CPU adapter),
# 3 soft time limit exceeded. The watchdog aborts the process at timeout+30 s.

const DEFAULT_LEVEL := "mp_granite_clubhouse_portal"
const DEFAULT_GAME := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
const VIEW_SIZE := Vector2i(640, 360)
const GROUND_HALF_EXTENT_M := 400.0
const GROUND_GRID := 160
const CAMERA_BACK_M := 160.0
const CAMERA_UP_M := 55.0
const SETTLE_MIN_FRAMES := 30
const SETTLE_LIMIT_FRAMES := 360
const SETTLE_STEP_FRAMES := 4
const SETTLE_STABLE_STEPS := 3
const STRIDE := 2
# A pixel "changed" when any 8-bit channel moves by more than this.
const CHANGE_TOLERANCE := 10
const SHARED_META := &"highpoly_native_water_shared"
const LOG_PATTERNS := ["shader error", "shader compilation failed", "failed parsing shader", "error compiling"]
const PIPELINE_INFOS := ["RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS", "RENDERING_INFO_PIPELINE_COMPILATIONS_MESH",
	"RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE", "RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW",
	"RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION"]

var level := DEFAULT_LEVEL
var game := DEFAULT_GAME
var surface_index := -1
var timeout_sec := 300
var timing_frames := 90
var production := false

var _checks: Array = []
var _report: Dictionary = {}
var _images: Dictionary = {}
var _settle: Dictionary = {}
var _start_msec := 0
var _timed_out := false
var _watch_thread: Thread = null
var _watch_mutex := Mutex.new()
var _watch_stop := false
var _hard_deadline_msec := 0
var _log_path := ""
var _log_offset := -1

var _Env: GDScript = null
var _Terrain: GDScript = null
var _Water: GDScript = null
var _core: Object = null
var _env: Object = null
var _job: PrepJob = null
var _task_id := -1

var _viewport: SubViewport = null
var _scene: Node3D = null
var _world_env: WorldEnvironment = null
var _env_real: Environment = null
var _env_mask: Environment = null
var _env_green: Environment = null
var _ground_node: MeshInstance3D = null
var _water_node: MeshInstance3D = null
var _driver: Node = null
var _ground_actual: ShaderMaterial = null
var _water_actual: ShaderMaterial = null
var _ground_magenta: StandardMaterial3D = null
var _mask_ground: StandardMaterial3D = null
var _mask_water: ShaderMaterial = null
var _all_mask := PackedByteArray()


# All native reads and CPU decoding run in one WorkerThreadPool task.
class PrepJob extends RefCounted:
	var coverage_size := 64
	var sheet_size := 64
	var core: Object
	var env: Object
	var water_script: GDScript
	var game := ""
	var surface_index := -1
	var half_extent := 400.0
	var grid := 160
	var stage := "queued"
	var ok := false
	var error := ""
	var timings: Dictionary = {}
	var water: Dictionary = {}
	var surface: Dictionary = {}
	var surface_selected := -1
	var ground_ok := false
	var ground_error := ""
	var terrain_depth: Dictionary = {}
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var window_lo := Vector2.ZERO
	var window_hi := Vector2.ZERO
	var center := Vector2.ZERO
	var water_y := 0.0
	var target := Vector3.ZERO
	var toward_water := Vector3(0, 0, 1)
	var shore_found := false
	var _heights := PackedByteArray()
	var _hw := 0
	var _hh := 0
	var _min := Vector2.ZERO
	var _span := Vector2.ONE
	var _mpr := 0.0

	func run() -> void:
		var t := Time.get_ticks_msec()
		stage = "open"
		if not bool(core.call("open", game)):
			error = "BF6Core.open failed for %s" % game
			return
		t = _mark("open", t)
		stage = "water"
		var water_value: Variant = env.call("read_water")
		water = water_value if water_value is Dictionary else {}
		t = _mark("water_metadata_height_mask_textures", t)
		if water.is_empty():
			error = "water read failed: %s" % str(env.get("error"))
			return
		var surfaces_value: Variant = water.get("surfaces", [])
		var surfaces: Array = surfaces_value if surfaces_value is Array else []
		if surfaces.is_empty():
			error = "level has no water surfaces"
			return
		if surface_index >= 0:
			if surface_index >= surfaces.size():
				error = "--surface=%d out of range (%d surfaces)" % [surface_index, surfaces.size()]
				return
			surface_selected = surface_index
		else:
			var best := -1.0
			for i in range(surfaces.size()):
				var row: Dictionary = surfaces[i] if surfaces[i] is Dictionary else {}
				var size: Array = row.get("size", []) if row.get("size", []) is Array else []
				var area := float(size[0]) * float(size[1]) if size.size() >= 2 else 0.0
				if area > best:
					best = area
					surface_selected = i
		surface = (surfaces[surface_selected] as Dictionary).duplicate()
		surface["native"] = true
		var c: Array = surface.get("center", []) if surface.get("center", []) is Array else []
		if c.size() < 2 or not surface.has("height"):
			error = "surface %d lacks center/height" % surface_selected
			return
		center = Vector2(float(c[0]), float(c[1]))
		water_y = float(surface.height)
		stage = "ground"
		ground_ok = bool(env.call("prepare_ground", Callable(), coverage_size, sheet_size))
		if not ground_ok: ground_error = str(env.get("error"))
		t = _mark("ground_coverage%d_sheet%d" % [coverage_size, sheet_size], t)
		stage = "terrain_depth"
		var depth_value: Variant = env.call("request", "terrain_depth", 1024)
		terrain_depth = depth_value if depth_value is Dictionary else {}
		t = _mark("terrain_depth1024", t)
		if terrain_depth.is_empty():
			error = "terrain_depth read failed: %s" % str(env.get("error"))
			return
		var binding: Dictionary = water_script.call("height_image", terrain_depth, false)
		if not binding.has("image"):
			error = "terrain_depth unusable: %s" % str(binding.get("reason", "unknown"))
			return
		var heights_value: Variant = terrain_depth.get("preview_heights", terrain_depth.get("heights", null))
		_heights = heights_value
		var size_v: Vector2 = binding["size"]
		_hw = int(size_v.x)
		_hh = int(size_v.y)
		_min = binding["min"]
		_span = binding["span"]
		_mpr = float(binding["metres_per_raw"])
		stage = "ground_mesh"
		window_lo = Vector2(maxf(center.x - half_extent, _min.x), maxf(center.y - half_extent, _min.y))
		window_hi = Vector2(minf(center.x + half_extent, _min.x + _span.x), minf(center.y + half_extent, _min.y + _span.y))
		if window_hi.x - window_lo.x < 50.0 or window_hi.y - window_lo.y < 50.0:
			error = "surface centre %s lies outside terrain_depth bounds" % str(center)
			return
		_find_shore()
		if shore_found:
			var focus := Vector2(target.x, target.z)
			window_lo = focus - Vector2.ONE * half_extent
			window_hi = focus + Vector2.ONE * half_extent
		_build_ground()
		_mark("mesh_and_framing", t)
		stage = "done"
		ok = true

	func _mark(name: String, since: int) -> int:
		var now := Time.get_ticks_msec()
		timings[name] = now - since
		return now

	# Same texel-centre bilinear as terrain_y() in water_native.gdshader.
	func sample(x: float, z: float) -> float:
		var gx := (x - _min.x) / _span.x * _hw - 0.5
		var gz := (z - _min.y) / _span.y * _hh - 0.5
		var x0 := floori(gx)
		var z0 := floori(gz)
		var fx := gx - x0
		var fz := gz - z0
		var top := lerpf(_raw(x0, z0), _raw(x0 + 1, z0), fx)
		var bottom := lerpf(_raw(x0, z0 + 1), _raw(x0 + 1, z0 + 1), fx)
		return lerpf(top, bottom, fz)

	func _raw(ix: int, iz: int) -> float:
		ix = clampi(ix, 0, _hw - 1)
		iz = clampi(iz, 0, _hh - 1)
		return float(_heights.decode_u16((iz * _hw + ix) * 2)) * _mpr

	func _build_ground() -> void:
		var n := grid + 1
		var step := (window_hi - window_lo) / float(grid)
		for j in range(n):
			for i in range(n):
				var x := window_lo.x + step.x * i
				var z := window_lo.y + step.y * j
				vertices.append(Vector3(x, sample(x, z), z))
				var dx := (sample(x + step.x, z) - sample(x - step.x, z)) / (2.0 * step.x)
				var dz := (sample(x, z + step.y) - sample(x, z - step.y)) / (2.0 * step.y)
				normals.append(Vector3(-dx, 1.0, -dz).normalized())
		# Clockwise seen from +Y (Godot front faces).
		for j in range(grid):
			for i in range(grid):
				var a := j * n + i
				indices.append_array([a, a + 1, a + n + 1, a, a + n + 1, a + n])

	# Nearest shoreline to the surface centre, viewed from the water side.
	func surface_y(x: float, z: float) -> float:
		var h: Dictionary = env.get("water_height")
		if not bool(h.get("present", false)): return water_y
		var w := int(h.width)
		var n := int(h.height)
		var u := clampf((x - float(h.world_min[0])) / (float(h.world_max[0]) - float(h.world_min[0])), 0.0, 0.999999)
		var v := clampf((z - float(h.world_min[2])) / (float(h.world_max[2]) - float(h.world_min[2])), 0.0, 0.999999)
		var bytes: PackedByteArray = h.heights
		return maxf(water_y, bytes.decode_u16((int(v * n) * w + int(u * w)) * 2) * float(h.height_scale) / 65536.0)

	func _find_shore() -> void:
		target = Vector3(center.x, surface_y(center.x, center.y), center.y)
		var samples := 192
		var extent := Vector2(float(surface.size[0]), float(surface.size[1])) * 0.5
		var search_lo := _min.max(center - extent)
		var search_hi := (_min + _span).min(center + extent)
		var step := (search_hi - search_lo) / float(samples)
		var best := INF
		for j in range(1, samples):
			for i in range(1, samples):
				var x := search_lo.x + step.x * i
				var z := search_lo.y + step.y * j
				var local_water := surface_y(x, z)
				if absf(sample(x, z) - local_water) > 3.0: continue
				var down := Vector2(sample(x - step.x, z) - sample(x + step.x, z), sample(x, z - step.y) - sample(x, z + step.y))
				if down.length() < 1e-3: continue
				down = down.normalized()
				if sample(x + down.x * 20.0, z + down.y * 20.0) > surface_y(x + down.x * 20.0, z + down.y * 20.0) - 0.5: continue
				var d := Vector2(x, z).distance_to(center)
				if d < best:
					best = d
					target = Vector3(x, local_water, z)
					toward_water = Vector3(down.x, 0.0, down.y)
					shore_found = true


func _init() -> void:
	call_deferred("run")


func run() -> void:
	_start_msec = Time.get_ticks_msec()
	var arg_error := _parse_args()
	_hard_deadline_msec = _start_msec + (timeout_sec + 30) * 1000
	_watch_thread = Thread.new()
	_watch_thread.start(_watchdog_loop)
	print("ENVIRONMENT_RENDER_BEGIN level=%s" % level)
	_log_begin()
	_report = {"level": level, "game": game, "scope": "GPU render smoke/regression of the Godot environment adapters with perturbed controls; not visual parity with Unreal or the game",
		"engine": Engine.get_version_info().get("string", "")}
	if not arg_error.is_empty():
		check("arguments", false, arg_error)
		_finish(1); return

	var gpu := _gpu_info()
	_report["gpu"] = gpu
	if not bool(gpu.real_gpu):
		print("SKIP gpu-render: %s; no GPU render claim is made" % str(gpu.reason))
		_report["status"] = "not_gpu"
		_write_report()
		_finish(2); return
	check("renderer is Forward+ on Vulkan", gpu.driver == "vulkan" and gpu.method == "forward_plus",
		"driver=%s method=%s adapter=%s" % [gpu.driver, gpu.method, gpu.adapter])
	if gpu.driver != "vulkan" or gpu.method != "forward_plus":
		_finish_with_report(1); return

	if not _load_scripts():
		_finish_with_report(1); return
	if not ClassDB.class_exists("BF6Core"):
		check("BF6Core extension class", false, "BF6Core is not registered; the project GDExtension did not load")
		_finish_with_report(1); return
	_core = ClassDB.instantiate("BF6Core")
	_env = _Env.new(_core, level) if _core != null else null
	if _core == null or _env == null:
		check("instantiate BF6Core and BF6Environment", false, "instantiation returned null")
		_finish_with_report(1); return

	var prepared: bool = await _prepare()
	if not prepared:
		await _cleanup()
		_finish_with_report(3 if _timed_out else 1); return
	if not _build_scene():
		await _cleanup()
		_finish_with_report(1); return
	var rendered: bool = await _run_passes()
	if rendered: _evaluate()
	_save_images()
	_scan_log()
	await _cleanup()
	_finish_with_report(3 if _timed_out else (0 if _all_passed() else 1))


# ------------------------------------------------------------------ setup

func _parse_args() -> String:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var arg: String = args[i]
		var key := arg
		var value := ""
		if arg.contains("="):
			key = arg.get_slice("=", 0)
			value = arg.substr(key.length() + 1)
		elif i + 1 < args.size() and not args[i + 1].begins_with("--"):
			value = args[i + 1]
			i += 1
		match key:
			"--production": production = true
			"--level": level = value
			"--game": game = value
			"--surface":
				if not value.is_valid_int(): return "--surface needs an integer"
				surface_index = value.to_int()
			"--timeout":
				if not value.is_valid_int() or value.to_int() < 30: return "--timeout needs an integer >= 30"
				timeout_sec = value.to_int()
			"--frames":
				if not value.is_valid_int() or value.to_int() < 10 or value.to_int() > 2000: return "--frames needs 10..2000"
				timing_frames = value.to_int()
			_: return "unknown argument %s" % arg
		i += 1
	if level.is_empty(): return "--level is empty"
	return ""


func _gpu_info() -> Dictionary:
	var driver := ""
	var method := ""
	if RenderingServer.has_method("get_current_rendering_driver_name"):
		driver = str(RenderingServer.call("get_current_rendering_driver_name"))
		method = str(RenderingServer.call("get_current_rendering_method"))
	else:
		driver = str(OS.call("get_current_rendering_driver_name"))
		method = str(OS.call("get_current_rendering_method"))
	var adapter := RenderingServer.get_video_adapter_name()
	var kind := int(RenderingServer.get_video_adapter_type())
	var display := DisplayServer.get_name()
	var info := {"display": display, "driver": driver, "method": method, "adapter": adapter,
		"vendor": RenderingServer.get_video_adapter_vendor(), "adapter_type": kind,
		"api_version": RenderingServer.get_video_adapter_api_version(), "real_gpu": true, "reason": ""}
	var lower := adapter.to_lower()
	if display == "headless" or driver == "dummy" or driver.is_empty():
		info.real_gpu = false; info.reason = "headless/dummy renderer (display=%s driver=%s)" % [display, driver]
	elif adapter.is_empty():
		info.real_gpu = false; info.reason = "no video adapter reported"
	elif kind == RenderingDevice.DEVICE_TYPE_CPU or lower.contains("llvmpipe") or lower.contains("swiftshader") or lower.contains("basic render"):
		info.real_gpu = false; info.reason = "CPU rasteriser adapter %s" % adapter
	return info


func _script_dir() -> String:
	for base in ["res://addons/highpoly_toggle/", "res://"]:
		if FileAccess.file_exists(base + "highpoly_native_water.gd") or ResourceLoader.exists(base + "highpoly_native_water.gd"):
			return base
	return ""


func _load_scripts() -> bool:
	var dir := _script_dir()
	if dir.is_empty():
		check("adapter files present", false, "highpoly_native_water.gd not found at res:// or res://addons/highpoly_toggle/")
		return false
	_report["adapter_dir"] = dir
	for shader_file in ["terrain_native.gdshader", "water_native.gdshader"]:
		if not FileAccess.file_exists(dir + shader_file):
			check("adapter files present", false, "%s missing beside the adapters" % shader_file)
			return false
	var loaded: Array[GDScript] = []
	for file in ["bf6_environment.gd", "highpoly_native_terrain.gd", "highpoly_native_water.gd"]:
		var value: Variant = load(dir + file)
		var script: GDScript = value as GDScript
		# A parse error or unresolved class_name leaves a script that cannot instantiate.
		if script == null or not script.can_instantiate():
			check("load %s" % file, false, "script is null or cannot instantiate (parse error or missing global class cache; import the project first)")
			return false
		loaded.append(script)
	_Env = loaded[0]
	_Terrain = loaded[1]
	_Water = loaded[2]
	return true


func _prepare() -> bool:
	_job = PrepJob.new()
	_job.core = _core
	_job.env = _env
	_job.water_script = _Water
	_job.game = game
	_job.surface_index = surface_index
	_job.half_extent = GROUND_HALF_EXTENT_M
	_job.grid = GROUND_GRID
	_job.coverage_size = 4096 if production else 64
	_job.sheet_size = 512 if production else 64
	var started := Time.get_ticks_msec()
	_task_id = WorkerThreadPool.add_task(_job.run, false, "BF6 environment render harness reads")
	var last_note := started
	# Never abandon a running native read: past the soft limit keep waiting and
	# leave a hung read to the watchdog.
	while not WorkerThreadPool.is_task_completed(_task_id):
		await process_frame
		var now := Time.get_ticks_msec()
		if now - last_note >= 5000:
			last_note = now
			print("INFO native reads in progress: stage=%s %.0f s" % [_job.stage, (now - started) * 0.001])
		if _expired() and not _timed_out:
			_timed_out = true
			check("native reads within time limit", false, "still in stage %s at %d s" % [_job.stage, timeout_sec])
			_write_report()
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_report["read_ms"] = _job.timings
	_report["read_total_ms"] = Time.get_ticks_msec() - started
	if not _job.ok:
		var why := _job.error if not _job.error.is_empty() else "worker aborted in stage %s (script error, see log)" % _job.stage
		check("native reads", false, why)
		return false
	check("ground coverage%d/sheet%d read" % [_job.coverage_size, _job.sheet_size], _job.ground_ok, _job.ground_error)
	_report["surface"] = {"index": _job.surface_selected, "count": (_job.water.get("surfaces", []) as Array).size(),
		"center": [_job.center.x, _job.center.y], "height": _job.water_y, "size": _job.surface.get("size", []),
		"variant": _job.surface.get("variant", -1), "cascades": (_job.water.get("cascades", []) as Array).size()}
	_report["terrain_depth"] = {"width": _job._hw, "height": _job._hh, "source_width": _job.terrain_depth.get("source_width", 0),
		"source_height": _job.terrain_depth.get("source_height", 0)}
	_report["framing"] = {"shore_found": _job.shore_found, "target": [_job.target.x, _job.target.y, _job.target.z]}
	if not _job.shore_found: print("INFO no shoreline near the surface centre; framing the centre")
	return _job.ground_ok and not _timed_out


func _build_scene() -> bool:
	# Test scene only: the compact shore heightfield stands in as env.terrain so
	# the water material binds terrain depth without a full terrain read.
	_env.set("terrain", _job.terrain_depth)
	_ground_actual = _Terrain.call("material", _env)
	check("ground ShaderMaterial created", _ground_actual != null, "HighpolyNativeTerrain.material returned null")
	var water_value: Variant = _Water.call("material", _job.surface, _env)
	_water_actual = water_value as ShaderMaterial
	check("water ShaderMaterial has shader", _water_actual != null and _water_actual.shader != null, "HighpolyNativeWater.material returned no shader")
	if _ground_actual == null or _water_actual == null or _water_actual.shader == null: return false
	_report["water_notes"] = Array(_water_actual.get_meta(&"bf6_water_diagnostics", PackedStringArray()))

	_viewport = SubViewport.new()
	_viewport.name = "EnvironmentRenderViewport"
	_viewport.size = VIEW_SIZE
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_viewport.use_taa = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	RenderingServer.viewport_set_measure_render_time(_viewport.get_viewport_rid(), true)
	_scene = Node3D.new()
	_scene.name = "EnvironmentRenderScene"
	_viewport.add_child(_scene)

	_env_real = Environment.new()
	_env_real.background_mode = Environment.BG_SKY
	_env_real.sky = Sky.new()
	_env_real.sky.sky_material = ProceduralSkyMaterial.new()
	_env_real.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env_real.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_env_real.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_env_mask = Environment.new()
	_env_mask.background_mode = Environment.BG_COLOR
	_env_mask.background_color = Color.BLACK
	_env_mask.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	_env_mask.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_env_green = _env_mask.duplicate() as Environment
	_env_green.background_color = Color(0, 1, 0)
	_world_env = WorldEnvironment.new()
	_world_env.environment = _env_real
	_scene.add_child(_world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.shadow_enabled = true
	_scene.add_child(sun)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _job.vertices
	arrays[Mesh.ARRAY_NORMAL] = _job.normals
	arrays[Mesh.ARRAY_INDEX] = _job.indices
	var ground_mesh := ArrayMesh.new()
	ground_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_ground_node = MeshInstance3D.new()
	_ground_node.name = "Ground"
	_ground_node.mesh = ground_mesh
	_scene.add_child(_ground_node)

	var window := _job.window_hi - _job.window_lo
	var size_value: Variant = _job.surface.get("size", [])
	var size_list: Array = size_value if size_value is Array else []
	var plane_size := window
	if size_list.size() >= 2 and float(size_list[0]) > 0.0 and float(size_list[1]) > 0.0:
		plane_size = Vector2(minf(float(size_list[0]), window.x), minf(float(size_list[1]), window.y))
	var plane := PlaneMesh.new()
	plane.size = plane_size
	plane.subdivide_width = clampi(int(plane_size.x / 3.0), 64, 255)
	plane.subdivide_depth = clampi(int(plane_size.y / 3.0), 64, 255)
	_water_node = MeshInstance3D.new()
	_water_node.name = "Water"
	_water_node.mesh = plane
	var focus := (_job.window_lo + _job.window_hi) * 0.5
	_water_node.position = Vector3(focus.x, _job.water_y, focus.y)
	_water_node.extra_cull_margin = 1000.0  # includes native height-grid vertex lift
	_scene.add_child(_water_node)
	_report["scene"] = {"ground_window_lo": [_job.window_lo.x, _job.window_lo.y], "ground_window_hi": [_job.window_hi.x, _job.window_hi.y],
		"water_plane_size": [plane_size.x, plane_size.y], "view": [VIEW_SIZE.x, VIEW_SIZE.y]}

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.near = 0.5
	camera.far = 6000.0
	camera.fov = 60.0
	_scene.add_child(camera)
	var eye := _job.target + _job.toward_water * CAMERA_BACK_M
	eye.y = maxf(_job.surface_y(eye.x, eye.z), _job.sample(eye.x, eye.z)) + CAMERA_UP_M
	camera.position = eye
	camera.look_at(_job.target, Vector3.UP)
	camera.current = true
	_report["scene"]["camera"] = [eye.x, eye.y, eye.z]

	_ground_magenta = StandardMaterial3D.new()
	_ground_magenta.albedo_color = Color(1, 0, 1)
	_ground_magenta.roughness = 0.9
	_mask_ground = StandardMaterial3D.new()
	_mask_ground.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mask_ground.albedo_color = Color(1, 0, 0)
	# Keep the real vertex lift and displacement in the coverage mask. A flat
	# mask sits underground on river maps and falsely reports no visible water.
	_mask_water = _water_actual.duplicate() as ShaderMaterial
	var mask_shader := Shader.new()
	var original := _water_actual.shader.code
	mask_shader.code = original.substr(0, original.find("void fragment()")) + "void fragment() { ALBEDO=vec3(0.0); EMISSION=vec3(0.0,0.0,1.0); ROUGHNESS=1.0; SPECULAR=0.0; }"
	_mask_water.shader = mask_shader

	var driver_value: Variant = _Water.call("attach", _scene, _env, [_water_actual])
	_driver = driver_value as Node
	check("water driver attached", _driver != null and _driver.get_parent() == _scene, "HighpolyNativeWater.attach did not parent a driver")
	_all_mask.resize(VIEW_SIZE.x * VIEW_SIZE.y)
	_all_mask.fill(1)
	return _driver != null


# ------------------------------------------------------------------ rendering

func _set_state(ground: String, water: String, environment: Environment) -> void:
	_ground_node.visible = ground != "hidden"
	match ground:
		"actual": _ground_node.material_override = _ground_actual
		"magenta": _ground_node.material_override = _ground_magenta
		"mask": _ground_node.material_override = _mask_ground
	_water_node.visible = water != "hidden"
	match water:
		"actual": _water_node.material_override = _water_actual
		"mask": _water_node.material_override = _mask_water
	_world_env.environment = environment


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	if image == null or image.is_empty(): return null
	if image.get_format() != Image.FORMAT_RGBA8: image.convert(Image.FORMAT_RGBA8)
	return image


func _pipeline_compilations() -> int:
	var total := 0
	for name in PIPELINE_INFOS:
		if ClassDB.class_has_integer_constant("RenderingServer", name):
			total += RenderingServer.get_rendering_info(ClassDB.class_get_integer_constant("RenderingServer", name))
	return total


# Renders until consecutive captures are identical and no pipelines compiled,
# so a pass is never captured while its shaders are still being built.
func _settled(label: String) -> Image:
	var started := Time.get_ticks_msec()
	var previous: Image = null
	var stable := 0
	var frames := 0
	var pipelines := _pipeline_compilations()
	while frames < SETTLE_LIMIT_FRAMES:
		if _expired():
			_timed_out = true
			check("pass %s within time limit" % label, false, "soft time limit reached")
			return null
		for i in range(SETTLE_STEP_FRAMES): await process_frame
		frames += SETTLE_STEP_FRAMES
		var image: Image = await _grab()
		if image == null:
			check("pass %s captured" % label, false, "viewport returned no image")
			return null
		var now_pipelines := _pipeline_compilations()
		if previous != null and frames >= SETTLE_MIN_FRAMES:
			var change: Dictionary = measure_pixel_change(previous, image, _all_mask)
			if float(change.changed_fraction) <= 0.0005 and now_pipelines == pipelines: stable += 1
			else: stable = 0
			if stable >= SETTLE_STABLE_STEPS:
				_settle[label] = {"frames": frames, "ms": Time.get_ticks_msec() - started}
				_images[label] = image
				return image
		pipelines = now_pipelines
		previous = image
	check("pass %s stabilised" % label, false, "image still changing after %d frames" % SETTLE_LIMIT_FRAMES)
	return null


func _freeze_water(frozen: bool) -> void:
	_driver.process_mode = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT


func _pass(label: String) -> bool:
	var image: Image = await _settled(label)
	return image != null


func _run_passes() -> bool:
	_freeze_water(true)
	var ok := false
	_set_state("mask", "mask", _env_mask)
	ok = await _pass("mask")
	if not ok: return false
	_set_state("hidden", "hidden", _env_green)
	ok = await _pass("empty_green")
	if not ok: return false
	_set_state("actual", "hidden", _env_real)
	ok = await _pass("ground_actual")
	if not ok: return false
	for i in range(10): await process_frame
	ok = await _pass("ground_actual_repeat")
	if not ok: return false
	_set_state("magenta", "hidden", _env_real)
	ok = await _pass("ground_magenta")
	if not ok: return false

	_set_state("actual", "actual", _env_real)
	_freeze_water(false)
	var cascades := int((_report["surface"] as Dictionary).get("cascades", 0))
	var wait_start := Time.get_ticks_msec()
	while cascades > 0 and int(_driver.get("published_frames")) < 3:
		if _expired() or Time.get_ticks_msec() - wait_start > 60000: break
		await process_frame
	var published := int(_driver.get("published_frames"))
	if cascades > 0:
		check("water driver published FFT frames", published >= 3,
			"published=%d last_error=%s" % [published, str(_driver.get("last_error"))])
		if published < 3: return false

	# Frame timings of the full scene with the live simulation running.
	var rid := _viewport.get_viewport_rid()
	var interval_ms: Array = []
	var gpu_ms: Array = []
	var cpu_ms: Array = []
	var last := Time.get_ticks_usec()
	for i in range(timing_frames):
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		interval_ms.append((now - last) * 0.001)
		last = now
		gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
	_report["frame_timing"] = {"frame_interval_ms": _stats(interval_ms), "viewport_gpu_ms": _stats(gpu_ms),
		"viewport_cpu_ms": _stats(cpu_ms), "vsync_mode": DisplayServer.window_get_vsync_mode(),
		"water_job_ms": int(_driver.get("last_job_msec"))}

	# Same material, same published textures and sim_time: only the FFT gate moves.
	_freeze_water(true)
	var frozen_frames := int(_driver.get("published_frames"))
	ok = await _pass("full_actual")
	if not ok: return false
	if cascades > 0:
		_water_actual.set_shader_parameter("fft_enabled", 0.0)
		ok = await _pass("water_fft_off")
		_water_actual.set_shader_parameter("fft_enabled", 1.0)
		if not ok: return false
		ok = await _pass("full_actual_repeat")
		if not ok: return false
		var authored_amplitude := float(_water_actual.get_shader_parameter("amplitude"))
		_water_actual.set_shader_parameter("amplitude", authored_amplitude * 100.0)
		ok = await _pass("water_fft_amplified_control")
		_water_actual.set_shader_parameter("amplitude", authored_amplitude)
		if not ok: return false
		check("water frozen during A/B captures", int(_driver.get("published_frames")) == frozen_frames, "driver published while paused")
		_freeze_water(false)
		var resume := Time.get_ticks_msec()
		while int(_driver.get("published_frames")) < frozen_frames + 3 or Time.get_ticks_msec() - resume < 300:
			if _expired() or Time.get_ticks_msec() - resume > 30000: break
			await process_frame
		_freeze_water(true)
		check("water driver resumed", int(_driver.get("published_frames")) >= frozen_frames + 3,
			"published %d after resume" % (int(_driver.get("published_frames")) - frozen_frames))
		ok = await _pass("full_actual_later")
		if not ok: return false
	_report["water_driver"] = {"published_frames": int(_driver.get("published_frames")),
		"rejected_results": int(_driver.get("rejected_results")), "last_error": str(_driver.get("last_error"))}
	return true


# ------------------------------------------------------------------ evaluation

func _evaluate() -> void:
	var mask: Image = _images["mask"]
	var ground_mask := _colour_mask(mask, 0)
	var water_mask := _colour_mask(mask, 2)
	var total := float((VIEW_SIZE.x / STRIDE) * (VIEW_SIZE.y / STRIDE))
	var ground_cover := _count(ground_mask) / total
	var water_cover := _count(water_mask) / total
	var metrics := {"ground_coverage": ground_cover, "water_coverage": water_cover}
	check("framing shows ground", ground_cover >= 0.05, "ground covers %.3f of frame" % ground_cover)
	check("framing shows water", water_cover >= 0.02, "water covers %.3f of frame" % water_cover)

	if ground_cover >= 0.05:
		var actual: Image = _images["ground_actual"]
		var floor_change := measure_pixel_change(actual, _images["ground_actual_repeat"], ground_mask)
		var vs_empty := measure_pixel_change(actual, _images["empty_green"], ground_mask)
		var vs_magenta := measure_pixel_change(actual, _images["ground_magenta"], ground_mask)
		var magenta_actual := _magenta_fraction(actual, ground_mask)
		var magenta_control := _magenta_fraction(_images["ground_magenta"], ground_mask)
		metrics["ground"] = {"repeat": floor_change, "vs_hidden": vs_empty, "vs_magenta": vs_magenta,
			"magenta_fraction_actual": magenta_actual, "magenta_fraction_control": magenta_control}
		check("static ground render repeats", float(floor_change.changed_fraction) <= 0.01, str(floor_change))
		check("ground material draws (vs hidden-ground green control)", float(vs_empty.changed_fraction) >= 0.8, str(vs_empty))
		check("magenta detector sees magenta control", magenta_control >= 0.5, "%.3f" % magenta_control)
		check("actual ground is not magenta", magenta_actual <= 0.02, "%.3f" % magenta_actual)
		check("actual ground differs from magenta control", float(vs_magenta.changed_fraction) >= 0.5, str(vs_magenta))

	if water_cover >= 0.02:
		var full: Image = _images["full_actual"]
		var vs_no_water := measure_pixel_change(full, _images["ground_actual"], water_mask)
		metrics["water"] = {"vs_hidden": vs_no_water}
		check("water material draws (vs hidden-water control)", float(vs_no_water.changed_fraction) >= 0.2, str(vs_no_water))
		if _images.has("water_fft_off"):
			var noise := measure_pixel_change(full, _images["full_actual_repeat"], water_mask)
			var fft := measure_pixel_change(full, _images["water_fft_off"], water_mask)
			var later := measure_pixel_change(full, _images["full_actual_later"], water_mask)
			var amplified := measure_pixel_change(full, _images["water_fft_amplified_control"], water_mask)
			var floor_value := float(noise.changed_fraction)
			metrics["water"]["repeat"] = noise
			metrics["water"]["vs_fft_off"] = fft
			metrics["water"]["vs_later_frame"] = later
			metrics["water"]["amplified_control"] = amplified
			check("frozen water render repeats", floor_value <= 0.01, str(noise))
			# Authored FFT displacement can be millimetres. Measure against the
			# actual repeat noise floor, not a required percentage of big waves.
			# Require 64 aggregate 8-bit channel steps beyond 5x repeat noise.
			var signal_floor := 5.0 * float(noise.mean_abs) + 64.0 / (765.0 * maxf(1.0, float(noise.pixels)))
			check("FFT changes water pixels above repeat noise (vs disabled control)", float(fft.mean_abs) > signal_floor, str(fft))
			check("simulation advance changes water pixels above repeat noise", float(later.mean_abs) > signal_floor, str(later))
			check("amplified FFT control is observable", float(amplified.mean_abs) > signal_floor, str(amplified))
		else:
			print("INFO water FFT/animation controls not applicable: level authors no ocean cascades")
			metrics["water"]["fft_controls"] = "not_applicable_no_cascades"
	_report["pixels"] = metrics
	_report["settle"] = _settle


static func measure_pixel_change(a: Image, b: Image, mask: PackedByteArray) -> Dictionary:
	if a == null or b == null or a.get_size() != b.get_size():
		return {"pixels": 0, "changed_fraction": 0.0, "mean_abs": 0.0, "error": "image sizes differ"}
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var n := 0
	var changed := 0
	var sum := 0
	for y in range(0, h, STRIDE):
		var row := y * w
		for x in range(0, w, STRIDE):
			var p := row + x
			if mask[p] == 0: continue
			var o := p * 4
			var dr := absi(da[o] - db[o])
			var dg := absi(da[o + 1] - db[o + 1])
			var dbl := absi(da[o + 2] - db[o + 2])
			if maxi(dr, maxi(dg, dbl)) > CHANGE_TOLERANCE: changed += 1
			sum += dr + dg + dbl
			n += 1
	if n == 0: return {"pixels": 0, "changed_fraction": 0.0, "mean_abs": 0.0}
	return {"pixels": n, "changed_fraction": float(changed) / n, "mean_abs": float(sum) / (765.0 * n)}


# channel 0 = red ground mask, 2 = blue water mask (unshaded, linear tonemap).
func _colour_mask(image: Image, channel: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(VIEW_SIZE.x * VIEW_SIZE.y)
	var data := image.get_data()
	for y in range(0, VIEW_SIZE.y, STRIDE):
		for x in range(0, VIEW_SIZE.x, STRIDE):
			var p := y * VIEW_SIZE.x + x
			var o := p * 4
			var hit := true
			for c in range(3):
				hit = hit and (data[o + c] > 200 if c == channel else data[o + c] < 60)
			out[p] = 1 if hit else 0
	return out


func _count(mask: PackedByteArray) -> int:
	return mask.count(1)


func _magenta_fraction(image: Image, mask: PackedByteArray) -> float:
	var data := image.get_data()
	var n := 0
	var hits := 0
	for y in range(0, VIEW_SIZE.y, STRIDE):
		for x in range(0, VIEW_SIZE.x, STRIDE):
			var p := y * VIEW_SIZE.x + x
			if mask[p] == 0: continue
			var o := p * 4
			n += 1
			var low := mini(data[o], data[o + 2])
			if low > 110 and data[o + 1] * 2 < low: hits += 1
	return float(hits) / n if n > 0 else 0.0


static func _stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"count": 0}
	var sorted := values.duplicate()
	sorted.sort()
	var n := sorted.size()
	return {"count": n, "min": sorted[0], "median": sorted[n / 2],
		"p95": sorted[clampi(int(ceil(n * 0.95)) - 1, 0, n - 1)], "max": sorted[n - 1]}


# ------------------------------------------------------------------ output

func _save_images() -> void:
	var safe := level.validate_filename()
	var saved := {}
	for label in _images:
		var path := "user://environment-render-%s.png" % safe if label == "full_actual" else "user://environment-render-%s-%s.png" % [safe, label]
		var image: Image = _images[label]
		if image.save_png(path) == OK: saved[label] = ProjectSettings.globalize_path(path)
		else: check("save %s" % path, false, "save_png failed")
	_report["screenshots"] = saved
	if saved.has("full_actual"): print("INFO screenshot %s" % saved["full_actual"])


func _log_begin() -> void:
	var enabled: Variant = ProjectSettings.get_setting_with_override("debug/file_logging/enable_file_logging")
	if not (enabled is bool and enabled): return
	_log_path = str(ProjectSettings.get_setting_with_override("debug/file_logging/log_path"))
	var file := FileAccess.open(_log_path, FileAccess.READ)
	if file != null: _log_offset = file.get_length()


# Best effort only: the external runner's captured stderr is authoritative.
func _scan_log() -> void:
	print("LOG_SCAN_REQUIRED: runner must fail if its captured output contains 'SHADER ERROR' between ENVIRONMENT_RENDER_BEGIN and ENVIRONMENT_RENDER_END")
	var file: FileAccess = null
	if not _log_path.is_empty(): file = FileAccess.open(_log_path, FileAccess.READ)
	if file == null or _log_offset < 0 or file.get_length() < _log_offset:
		_report["log_scan"] = "unavailable: file logging disabled, log unreadable or rotated; external scan required"
		return
	file.seek(_log_offset)
	var text := file.get_buffer(file.get_length() - _log_offset).get_string_from_utf8()
	var hits: Array = []
	for line in text.split("\n"):
		if line.begins_with("LOG_SCAN_REQUIRED:"): continue
		var lower := line.to_lower()
		for pattern in LOG_PATTERNS:
			if lower.contains(pattern):
				hits.append(line.strip_edges().left(300))
				break
	_report["log_scan"] = {"path": ProjectSettings.globalize_path(_log_path), "hits": hits.slice(0, 20)}
	check("no shader errors in this run's log (best effort)", hits.is_empty(), "%d matching lines" % hits.size())


func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ("" if ok or detail.is_empty() else ": " + detail))
	_checks.append({"name": name, "ok": ok, "detail": detail})


func _all_passed() -> bool:
	if _checks.is_empty(): return false
	for item in _checks:
		if not bool(item.ok): return false
	return true


func _write_report() -> void:
	_report["checks"] = _checks
	_report["elapsed_ms"] = Time.get_ticks_msec() - _start_msec
	_report["timed_out"] = _timed_out
	var path := "user://environment-render-%s.json" % level.validate_filename()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("could not write %s" % path)
		return
	file.store_string(JSON.stringify(_report, "\t"))
	print("INFO report %s" % ProjectSettings.globalize_path(path))


func _finish_with_report(code: int) -> void:
	_report["status"] = ["pass", "fail", "not_gpu", "timeout"][code]
	_report["gpu_render_claim"] = code == 0
	_write_report()
	_finish(code)


func _finish(code: int) -> void:
	_watch_mutex.lock()
	_watch_stop = true
	_watch_mutex.unlock()
	if _watch_thread != null and _watch_thread.is_started(): _watch_thread.wait_to_finish()
	_watch_thread = null
	var failed := 0
	for item in _checks:
		if not bool(item.ok): failed += 1
	print(JSON.stringify({"status": ["pass", "fail", "not_gpu", "timeout"][code], "checks": _checks.size(), "failed": failed}))
	print("ENVIRONMENT_RENDER_END exit=%d" % code)
	quit(code)


# ------------------------------------------------------------------ lifetime

func _expired() -> bool:
	return Time.get_ticks_msec() - _start_msec > timeout_sec * 1000


func _watchdog_loop() -> void:
	while true:
		_watch_mutex.lock()
		var stop := _watch_stop
		_watch_mutex.unlock()
		if stop: return
		if Time.get_ticks_msec() > _hard_deadline_msec:
			printerr("FAIL watchdog: environment render harness exceeded %d s hard limit" % (timeout_sec + 30))
			printerr("ENVIRONMENT_RENDER_END exit=watchdog")
			OS.crash("environment render harness watchdog")
		OS.delay_msec(100)


func _cleanup() -> void:
	# The prep task is always complete here; _prepare never returns before it is.
	if _task_id >= 0:
		while not WorkerThreadPool.is_task_completed(_task_id): await process_frame
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	var driver_ref: WeakRef = weakref(_driver) if _driver != null else null
	# Leaving the tree makes the driver wait for its in-flight job and release textures.
	if _viewport != null: _viewport.queue_free()
	for i in range(4): await process_frame
	if driver_ref != null:
		check("water driver freed with the scene", driver_ref.get_ref() == null, "driver still alive after scene free")
		if _water_actual != null:
			check("water cascade textures released", _water_actual.get_shader_parameter("disp0") == null, "disp0 still bound")
	_driver = null
	_viewport = null
	_scene = null
	_world_env = null
	_ground_node = null
	_water_node = null
	_ground_actual = null
	_water_actual = null
	_images.clear()
	if _env != null and _env.has_meta(SHARED_META): _env.remove_meta(SHARED_META)
	_job = null
	_env = null
	if _core != null and not (_core is RefCounted): _core.free()
	_core = null
