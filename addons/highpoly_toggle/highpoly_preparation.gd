@tool
extends VBoxContainer

# Up-front cache supervisor. Once a verified installation is selected, every
# stage runs in order behind a screen that covers the editor, and High Poly
# stays locked until all of them have finished:
#
#   1. game cache   - the shared C++ cache (BF6_High_Poly_Core, bf6_precache_*):
#                     placements, mesh and texture references, terrain and water,
#                     for every map. Shared with the Unreal plugin.
#   2. map index    - each map's mount index, partition index and placement walk
#                     (headless worker processes, a few at a time). Geometry is
#                     read from the game cache, so no meshes are written.
#   3. previews     - object library icons (rendered by the editor).
#
# Invalidation: the game cache is keyed by the installation identity and the core
# recipe; stale keys are swept on open. Map indexes are keyed by identity plus the
# reader scripts (Cache.reader_recipe), so an add-on update that does not touch
# the reader keeps them; superseded index files are deleted. Previews follow the
# full add-on recipe. Finished work is verified, not redone.
const Cache = preload("highpoly_install_cache.gd")
const Priority = preload("highpoly_preparation_order.gd")
const Screen = preload("highpoly_preparation_screen.gd")
const API_VERSION := 2
const SERVICE_GROUP := "bf6_highpoly_preparation_v1"
const RECORD := "user://highpoly/preparation.json"
const JOBS := "user://highpoly/preparation_jobs"
const FORMAT := 3
const POLL_SECONDS := 0.25
# Stage weights for the overall bar. Measured: the game cache is ~8 minutes for a
# full install; mesh preparation is the longest; previews are comparatively quick.
const WEIGHTS := {"core": 0.35, "geometry": 0.50, "previews": 0.15}
const INDEX_SECONDS_GUESS := 12.0   # a map's first index, until one has been measured
enum Stage { IDLE, CHECKING, CORE, GEOMETRY, PREVIEWS, READY, PAUSED, FAILED }

signal editing_lock_changed(locked: bool)
signal ready_changed(is_ready: bool)

var foreground_owner := Callable()
# Unused since the screen stopped waiting behind BF6 Home; kept so an older host
# that still assigns it keeps working.
var popup_deferred := Callable()
var current_level := Callable()
# Set by the plugin: previews_missing() -> int, previews_run(progress: Callable) -> Dictionary
# (awaitable), previews_cancel() -> void. Unset means there is nothing to render.
var previews_missing := Callable()
var previews_run := Callable()
var previews_cancel := Callable()

var install := ""
var identity := ""
var recipe := ""
var cache_ready := false
var stage := Stage.IDLE
var _levels: Array = []
var _preferred: Dictionary = {}
var _order: Array = []   # levels in build order, fixed when a run begins
var _record: Dictionary = {}
var _message := ""
var _error := ""

var _core: RefCounted
var _core_status: Dictionary = {}
var _core_done := false
var _geometry_done := false
var _cache_root := ""
var _scan: Thread
var _scan_install := ""

var reader := ""
var _geometry_queue: Array = []
var _jobs: Array = []           # running index workers: {pid, level, status, cancel, report, started}
var _progress_phases: Array = []

var _previews_done := 0
var _previews_total := 0
var _previews_running := false

var _pause_requested := false
var _worker_pause_reason := ""
var _retries := {}                      # level -> interrupted index jobs retried this session
const NO_RESULT := "The map index worker exited without a result; the map indexes itself when opened."
var _overall_floor := 0.0
var _screen: Window
var _screen_waiting := false
var _foreground := false
var _timer: Timer
var _label: Label
var _bar: ProgressBar
var _resume: Button
var _show: Button

func _enter_tree() -> void:
	# Runtime discovery only; never write service membership into a map scene.
	add_to_group(SERVICE_GROUP, false)

func _ready() -> void:
	Screen.Menu.configure(get_script().resource_path.get_base_dir())
	var definition: Variant = JSON.parse_string(FileAccess.get_file_as_string(Screen.Menu.file("preparation.json")))
	_progress_phases = definition.get("phases", []) if definition is Dictionary else []
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.max_lines_visible = 3
	add_child(_label)
	_bar = Screen.Theme_.bar(ProgressBar.new())
	_bar.show_percentage = false
	add_child(_bar)
	_resume = Button.new()
	_resume.text = "Resume caching"
	_resume.tooltip_text = "High Poly unlocks once every map, its meshes and the object previews are cached."
	_resume.pressed.connect(func(): resume())
	add_child(_resume)
	_show = Button.new()
	_show.text = "Show caching progress"
	_show.tooltip_text = "Open the caching screen: every map's game cache and index, object previews and overall progress."
	_show.pressed.connect(func(): show_progress())
	add_child(_show)
	_record = Cache.read_record(RECORD)
	if int(_record.get("format", 0)) != FORMAT:
		_record = {"format": FORMAT}
	_timer = Timer.new()
	_timer.wait_time = POLL_SECONDS
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_timer.start()
	if not install.is_empty():
		_start_check()
	_refresh()

# ---- installation -----------------------------------------------------------
func set_install(path: String) -> void:
	if install == path:
		return
	_stop_all()
	install = path
	identity = ""
	_levels.clear()
	_set_ready(false)
	stage = Stage.IDLE
	if path.is_empty():
		_message = "Waiting for a verified game installation."
	elif is_node_ready():
		_start_check()
	_refresh()

static func cache_root() -> String:
	# One cache for both editors: the Unreal plugin reads the same folder.
	var base := OS.get_environment("LOCALAPPDATA")
	if base.is_empty():
		base = OS.get_user_data_dir()
	return base.replace("\\", "/").path_join("BF6HighPoly")

func _start_check() -> void:
	if install.is_empty() or _scan != null:
		return
	stage = Stage.CHECKING
	_message = "Checking Battlefield 6..."
	_scan_install = install
	_scan = Thread.new()
	var captured := install
	var root := cache_root()
	# Identity, recipe and opening the cache all hash files; keep them off the editor thread.
	if _scan.start(func():
		var checked: Dictionary = Cache.inspect(captured)
		checked["recipe"] = Cache.recipe(true)
		checked["reader"] = Cache.reader_recipe()
		checked["preferred_levels"] = Priority.saved_levels(checked.get("levels", []))
		if checked.get("ok", false) and ClassDB.class_exists("BF6Core"):
			var core = ClassDB.instantiate("BF6Core")
			if core != null and core.has_method("precache_open"):
				DirAccess.make_dir_recursive_absolute(root)
				if core.precache_open(captured, root):
					core.precache_sweep()
					checked["core"] = core
				else:
					checked["core_error"] = str(core.last_error())
			else:
				checked["core_error"] = "Restart Godot after updating the High Poly native reader."
		return checked) != OK:
		_scan = null
		_fail("Could not start the game-file check.")

func _finish_check(result: Dictionary) -> void:
	Cache.accept(install, result)
	if not result.get("ok", false):
		_fail("Game files could not be verified: %s" % str(result.get("error", "")))
		return
	if str(result.get("recipe", "")).is_empty():
		_fail("The add-on files could not be read. Reinstall the add-on, then check again.")
		return
	if not result.has("core"):
		_fail("The game cache could not be opened: %s" % str(result.get("core_error", "unknown error")))
		return
	identity = str(result["identity"])
	recipe = str(result["recipe"])
	reader = str(result.get("reader", ""))
	_levels = result.get("levels", []).duplicate()
	_preferred = result.get("preferred_levels", {}).duplicate()
	_core = result["core"]
	if str(_record.get("identity", "")) != identity:
		_record = {"format": FORMAT, "identity": identity}
	if str(_record.get("reader", "")) != reader:
		_record["reader"] = reader
		_record["maps"] = {}          # map indexes follow the reader scripts
	if str(_record.get("recipe", "")) != recipe:
		_record["recipe"] = recipe
		_record.erase("previews")     # previews follow the whole add-on
	_save()
	_overall_floor = 0.0
	_begin()

func _ordered_levels() -> Array:
	var level := ""
	if current_level.is_valid():
		level = str(current_level.call()).to_lower()
	return Priority.ordered(_levels.duplicate(), level, _preferred)

# ---- stages -------------------------------------------------------------------
func _begin() -> void:
	_pause_requested = false
	_error = ""
	_core_done = false
	_geometry_done = false
	_start_core()

func _start_core() -> void:
	stage = Stage.CORE
	_order = _ordered_levels()
	var rc: int = _core.precache_start(",".join(_order), 0)
	if rc != 0:
		_fail("The game cache could not start (code %d)." % rc)
		return
	_message = "Verifying the game cache..."
	_core_status = JSON.parse_string(_core.precache_status())
	_refresh()

func _poll_core() -> void:
	var parsed: Variant = JSON.parse_string(_core.precache_status())
	if not parsed is Dictionary:
		return
	_core_status = parsed
	var state := int(_core_status.get("state", 0))
	if state == 1 or state == 2:
		# Only take over the editor when there is real work; a complete cache verifies in milliseconds.
		if float(_core_status.get("overall", 0.0)) < 0.999:
			_show_screen()
		_message = _core_line()
		return
	if _pause_requested:
		_paused()
		return
	if state == 4:
		_fail("Game cache failed: %s" % str(_core_status.get("error", "")))
		return
	if state == 3 and bool(_core_status.get("ready", false)):
		_core_done = true
		_record["core_key"] = str(_core_status.get("key", ""))
		_save()
		_start_geometry()

func _core_line() -> String:
	var map := str(_core_status.get("current_map", ""))
	if map.is_empty():
		return "Game cache: finishing shared data..."
	var line := "Game cache: %s  ·  %s  ·  %s" % [map, str(_core_status.get("current_layer", "")), str(_core_status.get("current_item", ""))]
	var quiet := float(_core_status.get("since_update", 0.0))
	if quiet >= 3.0:
		line += "  (working, %d s)" % int(quiet)
	return line

func _map_entry(level: String) -> Dictionary:
	var maps: Dictionary = _record.get("maps", {})
	var entry = maps.get(level, {})
	return entry if entry is Dictionary else {}

func _index_workers() -> int:
	# Each worker is a headless editor holding one map's mount; bound them by memory.
	var physical := int(OS.get_memory_info().get("physical", 0))
	return clampi(physical / (16 * 1024 * 1024 * 1024), 1, 3)

func _start_geometry() -> void:
	stage = Stage.GEOMETRY
	_geometry_queue.clear()
	_retries.clear()
	for level in _order:
		var entry := _map_entry(level)
		# A map recorded as failed only because its worker was interrupted is
		# retried; a map that reported its own failure is not.
		var interrupted := str(entry.get("state", "")) == "failed" and str(entry.get("error", "")) == NO_RESULT
		if interrupted or not str(entry.get("state", "")) in ["prepared", "failed"]:
			_geometry_queue.append(level)
	# Meshes now come from the game cache; the old per-map mesh files are dead weight.
	if DirAccess.dir_exists_absolute("user://bf6_geom"):
		_remove_tree("user://bf6_geom")
	if _geometry_queue.is_empty():
		_start_previews()
		return
	_show_screen()
	_next_geometry()

# A map's texture order (what the read-ahead reads) is no longer recorded here.
# Recording it meant building every material of the map against placeholders,
# 30 to 50 s per map, which was most of an index job. A map's first real open
# records the order it actually asks for (highpoly_gamesource.gd, _learn_texture)
# and later opens read ahead from it. A missing or stale order only means no
# read-ahead; it never changes what is drawn.

static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_tree(path.path_join(sub))
	for f in dir.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)

func _next_geometry() -> void:
	if _pause_requested:
		if _jobs.is_empty():
			_paused()
		return
	if _geometry_queue.is_empty() and _jobs.is_empty():
		_start_previews()
		return
	while not _geometry_queue.is_empty() and _jobs.size() < _index_workers():
		if int(OS.get_memory_info().get("free", 0)) < 4 * 1024 * 1024 * 1024:
			if _jobs.is_empty():
				_paused("Caching paused: free at least 4 GB of memory, then resume.")
			return
		var level := str(_geometry_queue.pop_front())
		var id := "%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
		var job_path := "%s/%s.json" % [JOBS, id]
		var job := {"level": level, "status": "%s/%s.status.json" % [JOBS, id],
			"cancel": "%s/%s.cancel" % [JOBS, id], "report": {}, "started": Time.get_ticks_msec(), "pid": -1}
		var data := {"install": install, "identity": identity, "recipe": reader, "level": level, "force": false,
			"index_only": true, "record_textures": false, "foreground": true, "memory_reserve_bytes": 4 * 1024 * 1024 * 1024,
			"parent_pid": OS.get_process_id(),
			"status": ProjectSettings.globalize_path(job.status),
			"cancel": ProjectSettings.globalize_path(job.cancel)}
		if not Cache.write_record(job_path, data):
			_geometry_queue.push_front(level)
			_fail("Could not write the map index job. Check cache-folder permissions.")
			return
		var script: String = get_script().resource_path.get_base_dir().path_join("highpoly_prepare_worker.gd")
		job.pid = OS.create_process(OS.get_executable_path(), PackedStringArray([
			"--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--log-file", ProjectSettings.globalize_path(str(job.status) + ".engine.log"),
			"--script", ProjectSettings.globalize_path(script), "--", ProjectSettings.globalize_path(job_path)]), false)
		if int(job.pid) < 0:
			_geometry_queue.push_front(level)
			_fail("Could not start the map index worker.")
			return
		_jobs.append(job)
	_message = _index_line()

func _index_line() -> String:
	if _jobs.is_empty():
		return "Map index: waiting"
	var parts := PackedStringArray()
	for job in _jobs:
		var report: Dictionary = job.report
		parts.append("%s (%s, %d s)" % [job.level, str(report.get("stage", "starting")),
			int((Time.get_ticks_msec() - int(job.started)) / 1000)])
	return "Map index: " + ",  ".join(parts)

func _index_seconds() -> float:
	var total := 0.0
	var n := 0
	for entry in _record.get("maps", {}).values():
		if entry is Dictionary and float(entry.get("seconds", 0.0)) > 0.0:
			total += float(entry.seconds)
			n += 1
	return total / n if n > 0 else INDEX_SECONDS_GUESS

# A running map's share, from elapsed time against measured maps: open_map's own
# stages have no totals to count, and a steadily moving bar is the honest estimate.
func _job_fraction(job: Dictionary) -> float:
	return minf(0.95, (Time.get_ticks_msec() - int(job.started)) / 1000.0 / maxf(1.0, _index_seconds()))

func _poll_geometry() -> void:
	var finished: Array = []
	for job in _jobs:
		if OS.is_process_running(int(job.pid)):
			var status := Cache.read_record(str(job.status))
			if not status.is_empty():
				job.report = status
		else:
			finished.append(job)
	for job in finished:
		_jobs.erase(job)
		# Read after exit so the report is final rather than a mid-run snapshot.
		var status := Cache.read_record(str(job.status))
		var level := str(job.level)
		var state := str(status.get("state", ""))
		var why := str(status.get("error", ""))
		if state in ["paused", "stale"] or _pause_requested:
			_geometry_queue.push_front(level)
			if state == "stale":
				_stop_all()
				set_install_force_recheck()
				return
			# A WORKER THAT PAUSED ITSELF (another editor on this map, low memory)
			# pauses the stage with its reason. Relaunching it straight away just
			# pauses it again, as fast as processes can start.
			if state == "paused" and not _pause_requested:
				_pause_requested = true
				_worker_pause_reason = why
			continue
		var complete: bool = state == "prepared" and status.get("identity", "") == identity \
			and status.get("recipe", "") == reader and status.get("level", "") == level
		# INTERRUPTED IS NOT FAILED. A worker that ends without a final state was
		# stopped (the editor closed, the process was killed) rather than refused
		# by the map. It runs once more before the map is recorded as failed.
		if not complete and not state in ["failed", "prepared"] and int(_retries.get(level, 0)) < 1:
			_retries[level] = int(_retries.get(level, 0)) + 1
			_geometry_queue.push_back(level)
			continue
		if not complete:
			state = "failed"
			if why.is_empty():
				why = NO_RESULT
		var maps: Dictionary = _record.get("maps", {})
		maps[level] = {"state": state, "error": why, "placements": int(status.get("placements", 0)),
			"seconds": (Time.get_ticks_msec() - int(job.started)) / 1000.0}
		_record["maps"] = maps
		_save()
		if complete:
			_sweep_index_files(level, str(status.get("signature", "")))
	if not _jobs.is_empty() or not finished.is_empty():
		_message = _index_line()
	if _pause_requested and _jobs.is_empty():
		var reason := _worker_pause_reason
		_worker_pause_reason = ""
		if reason.is_empty():
			_paused()
		else:
			_paused(reason)
		return
	if not finished.is_empty():
		_next_geometry()

# Superseded index files for one map: every bf6_index/pidx/walk file of that map
# whose signature is not the one its worker just built or verified.
static func _sweep_index_files(level: String, signature: String) -> int:
	if signature.is_empty():
		return 0
	var removed := 0
	var dir := DirAccess.open("user://")
	if dir == null:
		return 0
	for f in dir.get_files():
		var n := str(f)
		if not n.ends_with(".idx") or n.ends_with("_%s.idx" % signature):
			continue
		for kind in ["bf6_index_", "bf6_pidx_", "bf6_walk_"]:
			if n.begins_with(kind + level + "_v"):
				if DirAccess.remove_absolute("user://" + n) == OK:
					removed += 1
				break
	return removed

func set_install_force_recheck() -> void:
	var path := install
	install = ""
	set_install(path)

func _start_previews() -> void:
	_geometry_done = true
	stage = Stage.PREVIEWS
	# High Poly unlocks here: previews are pictures for the object library and
	# keep rendering on the screen (or behind it, after Return to editor).
	_set_ready(true)
	var generation := identity + ":" + recipe
	if str(_record.get("previews", "")) == generation or not previews_run.is_valid():
		_finish()
		return
	var missing := int(previews_missing.call()) if previews_missing.is_valid() else 0
	if missing <= 0:
		# Not recorded: the library may not be loaded yet, so check again next start.
		_finish()
		return
	_show_screen()
	_previews_done = 0
	_previews_total = missing
	_previews_running = true
	_message = "Object previews: starting"
	_run_previews(generation)

func _run_previews(generation: String) -> void:
	var result: Dictionary = await previews_run.call(func(done: int, total: int):
		_previews_done = done
		_previews_total = maxi(1, total)
		_message = "Object previews: %d / %d" % [done, total])
	_previews_running = false
	if not is_inside_tree() or identity + ":" + recipe != generation:
		return
	if _pause_requested or bool(result.get("cancelled", false)):
		_paused()
		return
	# Previews are a convenience; the SDK's own icons remain, so High Poly is not
	# locked over them. Only a run that could draw is recorded as done; otherwise
	# the next start tries again (for example once a map scene is open).
	if result.has("error"):
		_record["previews_error"] = str(result["error"])
	elif int(result.get("no_source", 0)) < int(result.get("total", 0)):
		_record["previews"] = generation
		_record.erase("previews_error")
	_save()
	_finish()

func _finish() -> void:
	stage = Stage.READY
	_message = _summary()
	_set_ready(true)
	_close_screen()
	_refresh()

func _summary() -> String:
	var failed := 0
	for level in _levels:
		if str(_map_entry(level).get("state", "")) == "failed":
			failed += 1
	var text := "High Poly cache ready: %d maps" % _levels.size()
	if failed > 0:
		text += " (%d index themselves when first opened)" % failed
	return text + "."

# ---- pause, resume, failure ----------------------------------------------------
func pause() -> void:
	_pause_requested = true
	match stage:
		Stage.CORE:
			if _core != null: _core.precache_cancel()
		Stage.GEOMETRY:
			if not _jobs.is_empty():
				for job in _jobs:
					var file := FileAccess.open(str(job.cancel), FileAccess.WRITE)
					if file != null:
						file.store_string("pause")
						file.close()
			else:
				_paused()
		Stage.PREVIEWS:
			if previews_cancel.is_valid(): previews_cancel.call()
		_:
			_paused()
	_message = "Pausing after the current step..."
	_refresh()

func resume() -> void:
	if stage in [Stage.PAUSED, Stage.FAILED]:
		if _core == null or identity.is_empty():
			set_install_force_recheck()
		else:
			_show_screen(true)
			_begin()
	elif is_instance_valid(_screen) and not _screen.visible:
		_show_screen(true)
	_refresh()

func _paused(why := "") -> void:
	_pause_requested = false
	stage = Stage.PAUSED
	_message = why if not why.is_empty() else "Caching paused. High Poly unlocks when caching finishes; resume when ready."
	_refresh()

func _fail(why: String) -> void:
	stage = Stage.FAILED
	_error = why
	_message = why
	_show_screen()
	_refresh()

func _set_ready(value: bool) -> void:
	if cache_ready == value:
		return
	cache_ready = value
	ready_changed.emit(value)

func _stop_all() -> void:
	if _core != null and _core.has_method("precache_cancel"):
		_core.precache_cancel()
	for job in _jobs:
		if OS.is_process_running(int(job.pid)):
			var file := FileAccess.open(str(job.cancel), FileAccess.WRITE)
			if file != null:
				file.store_string("cancel")
				file.close()
	if _previews_running and previews_cancel.is_valid():
		previews_cancel.call()

func _save() -> void:
	Cache.write_record(RECORD, _record)

# ---- progress ------------------------------------------------------------------
func _geometry_fraction() -> float:
	if _levels.is_empty():
		return 0.0
	var done := 0.0
	for level in _levels:
		if str(_map_entry(level).get("state", "")) in ["prepared", "failed"]:
			done += 1.0
	for job in _jobs:
		done += _job_fraction(job)
	return clampf(done / _levels.size(), 0.0, 1.0)

func overall_fraction() -> float:
	var core := 1.0 if _core_done else float(_core_status.get("overall", 0.0))
	var geometry := 1.0 if _geometry_done else _geometry_fraction()
	var previews := 1.0 if stage == Stage.READY else (float(_previews_done) / _previews_total if _previews_total > 0 else 0.0)
	var value: float = WEIGHTS.core * core + WEIGHTS.geometry * geometry + WEIGHTS.previews * previews
	# Never run backwards within a generation, whatever a stage's own estimate does.
	_overall_floor = maxf(_overall_floor, value)
	return _overall_floor

func snapshot() -> Dictionary:
	var maps: Array = []
	var core_maps: Dictionary = {}
	for row in _core_status.get("maps", []):
		core_maps[str(row.get("level", ""))] = row
	var layer_names: Array = _core_status.get("layers", [])
	for level in _order:
		var core_row: Dictionary = core_maps.get(level, {})
		var core_progress := 1.0 if _core_done else float(core_row.get("progress", 0.0))
		var entry := _map_entry(level)
		var mesh_state := str(entry.get("state", ""))
		var mesh_progress := 1.0 if mesh_state in ["prepared", "failed"] else 0.0
		var indexing := false
		for job in _jobs:
			if str(job.level) == level:
				mesh_progress = _job_fraction(job)
				indexing = true
		var layers: Array = []
		var values: Array = core_row.get("layers", [])
		for k in range(mini(values.size(), layer_names.size())):
			layers.append({"name": str(layer_names[k]), "progress": float(values[k])})
		maps.append({"level": level, "core": core_progress, "core_state": int(core_row.get("state", 2 if _core_done else 0)),
			"layers": layers, "meshes": mesh_progress, "mesh_state": mesh_state,
			"active": indexing or level == str(_core_status.get("current_map", "")),
			"error": str(entry.get("error", ""))})
	return {"stage": stage, "stage_name": Stage.keys()[stage], "install": install, "message": _message, "error": _error,
		"overall": overall_fraction(), "core": _core_status, "core_line": _core_line() if stage == Stage.CORE else "",
		"geometry": 1.0 if _geometry_done else _geometry_fraction(), "core_done": _core_done, "geometry_done": _geometry_done, "index_jobs": _jobs.size(),
		"previews_done": _previews_done, "previews_total": _previews_total, "maps": maps,
		"ready": cache_ready, "running": stage in [Stage.CHECKING, Stage.CORE, Stage.GEOMETRY, Stage.PREVIEWS],
		"stopping": _pause_requested, "cache_root": cache_root()}

func _refresh() -> void:
	if not is_node_ready():
		return
	var snap := snapshot()
	if is_instance_valid(_screen):
		_screen.refresh(snap)
	_label.text = _message
	_label.tooltip_text = _message
	_bar.value = float(snap.overall) * 100.0
	_bar.visible = not cache_ready
	_resume.visible = stage in [Stage.PAUSED, Stage.FAILED]
	# Offered once an installation is known, finished or not, and hidden only
	# while the screen is already up.
	_show.visible = stage != Stage.IDLE and not (is_instance_valid(_screen) and _screen.visible)

func _tick() -> void:
	if _scan != null and not _scan.is_alive():
		var result: Dictionary = _scan.wait_to_finish()
		_scan = null
		if _scan_install != install:
			_start_check()
			return
		_finish_check(result)
	match stage:
		Stage.CORE: _poll_core()
		Stage.GEOMETRY: _poll_geometry()
	_refresh()

# ---- cover screen ------------------------------------------------------------------
func _show_screen(_explicit := false) -> void:
	if not is_instance_valid(_screen):
		_screen = Screen.new()
		# CREATED HIDDEN. A Window is visible by default, so adding this one
		# showed an exclusive, unsized window before cover() ever ran. BF6 Home
		# hides its browser under any exclusive window, and the result was a
		# grey editor with caching running behind it and nothing drawn.
		_screen.visible = false
		_screen.pause_requested.connect(pause)
		_screen.resume_requested.connect(resume)
		_screen.return_requested.connect(func():
			if stage in [Stage.PAUSED, Stage.FAILED, Stage.READY] or (stage == Stage.PREVIEWS and cache_ready):
				_close_screen()
			else:
				_screen.hide()
				_refresh())
		var owner_node: Node = foreground_owner.call() if foreground_owner.is_valid() else get_tree().root
		owner_node.add_child(_screen)
	if not _foreground:
		_foreground = true
		editing_lock_changed.emit(true)
	if _screen.visible:
		return
	# Not held back behind BF6 Home any more: holding it back left Home locked
	# with no visible progress. The screen covers the editor, Home steps aside
	# under it, and Home returns when caching finishes or on Return to editor.
	_screen_waiting = false
	_screen.cover()
	_screen.refresh(snapshot())

func _close_screen() -> void:
	# Never unlock editing while a worker is still alive; some reader calls cannot be interrupted.
	if not _jobs.is_empty():
		return
	_screen_waiting = false
	if is_instance_valid(_screen):
		_screen.hide()
		_screen.queue_free()
		_screen = null
	if _foreground:
		_foreground = false
		editing_lock_changed.emit(false)

# Kept for callers from before the screen stopped waiting behind Home.
func show_deferred_screen() -> void:
	if _screen_waiting and is_instance_valid(_screen) and not _screen.visible:
		_show_screen(true)

# The caching screen, without resuming anything: a paused run stays paused and
# offers Resume on the screen. Called from the High Poly panel and from BF6
# Home's High Poly card.
func show_progress() -> void:
	if stage == Stage.IDLE:
		return
	_show_screen(true)
	_refresh()

func open_preparation() -> void:
	resume()
	_show_screen(true)

# Map selector entry point (API 1 compatible): every map is cached up front, so a
# request is accepted when the cache is ready or already working towards it.
func prepare_levels(levels: Array, _force := false) -> bool:
	if levels.is_empty():
		return false
	for item in levels:
		if not (item is String or item is StringName) or str(item).strip_edges().to_lower() not in _levels:
			return false
	if cache_ready:
		return true
	if stage in [Stage.PAUSED, Stage.FAILED]:
		resume()
	return stage in [Stage.CHECKING, Stage.CORE, Stage.GEOMETRY, Stage.PREVIEWS]

func _exit_tree() -> void:
	remove_from_group(SERVICE_GROUP)
	_stop_all()
	if is_instance_valid(_screen):
		_screen.hide()
		_screen.queue_free()
		_screen = null
	if _foreground:
		_foreground = false
		editing_lock_changed.emit(false)
	if _scan != null:
		_scan.wait_to_finish()
		_scan = null
	if _core != null:
		# Joins the build thread; completed maps are kept and verified next time.
		_core = null
