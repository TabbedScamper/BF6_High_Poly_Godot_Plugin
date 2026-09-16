@tool
extends Window
# Full-screen caching view. It covers the editor window, consumes a supervisor
# snapshot and emits requests; it has no dependency on the map selector or editors.
const Theme_ = preload("highpoly_theme.gd")
const Menu = preload("highpoly_menu.gd")
const Backdrop = preload("highpoly_backdrop.gd")
signal pause_requested
signal resume_requested
signal return_requested
var _copy: Dictionary = {}
var _summary: Label
var _install: Label
var _overall: ProgressBar
var _overall_text: Label
var _stage_rows: Dictionary = {}
var _activity: Label
var _rows: VBoxContainer
var _map_scroll: ScrollContainer
var _map_count: Label
var _map_rows: Dictionary = {}
var _followed_map := ""
var _pause: Button
var _return: Button
var _state: Dictionary = {}
var _backdrop: Control
var _video: VideoStreamPlayer
var _video_size := Vector2(480, 800)
var _host: Window

const STAGES := [
	["core", "Game cache", "Map placements, mesh and texture references, terrain and water for every map. Shared with the Unreal plugin."],
	["geometry", "Map index", "Each map's placements and archive index, so maps open without scanning the game."],
	["previews", "Object previews", "Icons for every object in the library."],
]

# Worker phases (preparation.json) still describe the per-map mesh report.
static func phase_fraction(status: Dictionary, phases: Array) -> float:
	if str(status.get("state", "")) == "prepared":
		return 1.0
	if str(status.get("state", "")) in ["partial", "failed", "stale"]:
		return 0.0
	var stage := str(status.get("stage", ""))
	var before := 0.0
	for phase in phases:
		var id := str(phase.get("id", ""))
		var weight := float(phase.get("weight", 0.0))
		if id == "discovery":
			if stage != "Preparing geometry" and stage != "Verifying game files":
				return 0.0 # reading stages have changing totals, so don't fake a ratio
		elif id == "geometry" and stage == "Preparing geometry":
			var total := int(status.get("total", 0))
			return before + weight * clampf(float(status.get("done", 0)) / total, 0.0, 1.0) if total > 0 else before
		elif id == "verification" and stage == "Verifying game files":
			return before
		before += weight
	return 0.0

static func suspend_viewports(viewports: Array) -> Array:
	var saved: Array = []
	for viewport in viewports:
		if is_instance_valid(viewport) and viewport is SubViewport and viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
			saved.append({"viewport": viewport, "mode": viewport.render_target_update_mode})
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return saved

static func restore_viewports(saved: Array) -> void:
	for entry in saved:
		var viewport = entry.get("viewport")
		if is_instance_valid(viewport) and viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED:
			viewport.render_target_update_mode = int(entry.mode)
	saved.clear()

func _label(text: String, size := 14) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", Theme_.fs(size))
	return label

func _bar(height := 20) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.max_value = 100.0
	bar.custom_minimum_size.y = height
	Theme_.bar(bar)
	return bar

func _ready() -> void:
	Menu.configure(get_script().resource_path.get_base_dir())
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(Menu.file("preparation.json")))
	_copy = parsed if parsed is Dictionary and int(parsed.get("schema", 0)) == 1 else {}
	title = "Caching High Poly"
	borderless = true
	transient = true
	exclusive = true
	unresizable = true
	close_requested.connect(func(): return_requested.emit())
	_build_backdrop()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	add_child(margin)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_child(center)
	var column := VBoxContainer.new()
	column.theme = Theme_.build_ui_theme()
	column.add_theme_constant_override("separation", 10)
	column.custom_minimum_size = Vector2(860, 0)
	center.add_child(column)
	column.add_child(_label("Caching High Poly", 26))
	column.add_child(_label("Everything is cached once, up front, so every map opens with High Poly straight away. High Poly unlocks when caching finishes.", 13))
	_install = _label("", 11)
	column.add_child(_install)
	_overall_text = _label("Overall", 14)
	column.add_child(_overall_text)
	_overall = _bar(30)
	column.add_child(_overall)
	for spec in STAGES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var name_label := _label(spec[1], 13)
		name_label.custom_minimum_size.x = 170
		name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		name_label.tooltip_text = spec[2]
		row.add_child(name_label)
		var bar := _bar(18)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.tooltip_text = spec[2]
		row.add_child(bar)
		var state := _label("Waiting", 12)
		state.custom_minimum_size.x = 150
		state.autowrap_mode = TextServer.AUTOWRAP_OFF
		row.add_child(state)
		column.add_child(row)
		_stage_rows[spec[0]] = {"bar": bar, "state": state}
	_activity = _label("", 12)
	_activity.custom_minimum_size.y = 40
	column.add_child(_activity)
	_summary = _label("", 12)
	column.add_child(_summary)
	_map_count = _label("Maps", 12)
	column.add_child(_map_count)
	var scroll := ScrollContainer.new()
	_map_scroll = scroll
	scroll.custom_minimum_size.y = 320
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	column.add_child(scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	column.add_child(actions)
	_pause = Button.new()
	_pause.pressed.connect(func():
		if bool(_state.get("running", false)):
			pause_requested.emit()
		else:
			resume_requested.emit())
	actions.add_child(_pause)
	_return = Button.new()
	_return.text = "Return to editor"
	_return.tooltip_text = "Hide this screen. Caching continues, and High Poly stays locked until it finishes."
	_return.pressed.connect(func(): return_requested.emit())
	actions.add_child(_return)
	refresh(_state)

# Cover the whole editor window and follow it when it moves or resizes.
func cover() -> void:
	var parent_window := get_parent().get_window() if get_parent() != null else null
	if parent_window != null and parent_window != _host:
		_host = parent_window
		_host.size_changed.connect(_fit_host)
	_fit_host()
	show()
	grab_focus()

func _fit_host() -> void:
	if not is_instance_valid(_host):
		popup_centered_ratio(0.9)
		return
	position = _host.position
	size = _host.size

func _follow_map(level: String) -> void:
	await get_tree().process_frame
	if is_instance_valid(_map_scroll) and _map_rows.has(level):
		_map_scroll.ensure_control_visible(_map_rows[level].root)

func _build_backdrop() -> void:
	_backdrop = Control.new()
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.clip_contents = true
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_backdrop)
	var background := ColorRect.new()
	background.color = Theme_.col("splash_bg")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.add_child(background)
	if FileAccess.file_exists(Menu.file("waves.ogv")):
		var stream := VideoStreamTheora.new()
		stream.file = Menu.file("waves.ogv")
		_video = VideoStreamPlayer.new()
		_video.stream = stream
		_video.expand = true
		_video.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if "loop" in _video:
			_video.loop = true
		else:
			_video.finished.connect(func(): _sync_backdrop.call_deferred())
		_backdrop.add_child(_video)
		if FileAccess.file_exists(Menu.file("waves.json")):
			var metadata: Variant = JSON.parse_string(FileAccess.get_file_as_string(Menu.file("waves.json")))
			if metadata is Dictionary:
				_video_size = Vector2(maxf(1.0, float(metadata.get("width", 480))), maxf(1.0, float(metadata.get("height", 800))))
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, Theme_.num("tint", 0.72))
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.add_child(shade)
	_backdrop.resized.connect(_fit_backdrop)
	visibility_changed.connect(func(): _sync_backdrop.call_deferred())
	_fit_backdrop.call_deferred()
	_sync_backdrop.call_deferred()

func _fit_backdrop() -> void:
	if not is_instance_valid(_video):
		return
	var scale := maxf(_backdrop.size.x / _video_size.x, _backdrop.size.y / _video_size.y)
	_video.size = _video_size * scale
	_video.position = (_backdrop.size - _video.size) * 0.5

func _sync_backdrop() -> void:
	Backdrop.sync(_video, _backdrop)

static func _percent(value: float) -> String:
	return "%d%%" % int(floor(clampf(value, 0.0, 1.0) * 100.0))

func refresh(snapshot: Dictionary) -> void:
	_state = snapshot
	if not is_node_ready() or snapshot.is_empty():
		return
	var running := bool(snapshot.get("running", false))
	var stopping := bool(snapshot.get("stopping", false))
	var stage := str(snapshot.get("stage_name", ""))
	_install.text = "%s   →   %s" % [str(snapshot.get("install", "")), str(snapshot.get("cache_root", ""))]
	var overall := float(snapshot.get("overall", 0.0))
	_overall.value = overall * 100.0
	_overall_text.text = "Overall  ·  %s" % _percent(overall)
	var core: Dictionary = snapshot.get("core", {})
	var core_done := bool(snapshot.get("core_done", false))
	var core_value := 1.0 if core_done else float(core.get("overall", 0.0))
	_set_stage("core", core_value, "Done" if core_done else ("%d / %d maps" % [int(core.get("maps_done", 0)), int(core.get("map_count", 0))] if stage == "CORE" else "Waiting"))
	var geometry_done := bool(snapshot.get("geometry_done", false))
	var geometry := float(snapshot.get("geometry", 0.0))
	_set_stage("geometry", geometry, "Done" if geometry_done else (_percent(geometry) if stage == "GEOMETRY" or geometry > 0.0 else "Waiting"))
	var previews_total := int(snapshot.get("previews_total", 0))
	var previews_done := int(snapshot.get("previews_done", 0))
	var previews_value := 1.0 if bool(snapshot.get("ready", false)) else (float(previews_done) / previews_total if previews_total > 0 else 0.0)
	_set_stage("previews", previews_value, "Done" if bool(snapshot.get("ready", false)) else ("%d / %d" % [previews_done, previews_total] if stage == "PREVIEWS" else "Waiting"))
	var line := str(snapshot.get("core_line", ""))
	_activity.text = line if not line.is_empty() else str(snapshot.get("message", ""))
	_summary.text = str(snapshot.get("error", "")) if stage in ["FAILED"] else ("Paused. High Poly stays locked until caching finishes." if stage == "PAUSED" else "")
	_pause.text = "Pause" if running else "Resume"
	_pause.disabled = stopping or not (running or stage in ["PAUSED", "FAILED"])
	_return.disabled = stopping
	var maps: Array = snapshot.get("maps", [])
	var core_ready := 0
	var meshes_ready := 0
	var levels: Array = []
	for m in maps:
		levels.append(str(m.get("level", "")))
		if float(m.get("core", 0.0)) >= 1.0: core_ready += 1
		if str(m.get("mesh_state", "")) != "": meshes_ready += 1
	_map_count.text = "Maps: %d   ·   game cache %d   ·   indexed %d" % [maps.size(), core_ready, meshes_ready]
	for key in _map_rows.keys():
		if key not in levels:
			_map_rows[key].root.queue_free()
			_map_rows.erase(key)
	var index := 0
	var follow := ""
	for m in maps:
		var level := str(m.get("level", ""))
		if not _map_rows.has(level):
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			var name_label := _label(level, 12)
			name_label.custom_minimum_size.x = 230
			name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			var bar := _bar(14)
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var state_label := _label("", 11)
			state_label.custom_minimum_size.x = 330
			state_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			row.add_child(name_label)
			row.add_child(bar)
			row.add_child(state_label)
			_rows.add_child(row)
			_map_rows[level] = {"root": row, "label": name_label, "bar": bar, "state": state_label}
		var r: Dictionary = _map_rows[level]
		_rows.move_child(r.root, index)
		index += 1
		var core_p := float(m.get("core", 0.0))
		var mesh_p := float(m.get("meshes", 0.0))
		r.bar.value = (core_p * WEIGHT_CORE + mesh_p * (1.0 - WEIGHT_CORE)) * 100.0
		var parts: Array = []
		if core_p >= 1.0:
			parts.append("game cache ✓")
		elif core_p > 0.0:
			var layer := ""
			for l in m.get("layers", []):
				if float(l.get("progress", 0.0)) < 1.0:
					layer = str(l.get("name", ""))
					break
			parts.append("game cache %s%s" % [_percent(core_p), (" · " + layer) if not layer.is_empty() else ""])
		else:
			parts.append("game cache waiting")
		match str(m.get("mesh_state", "")):
			"prepared": parts.append("index ✓")
			"failed": parts.append("index: built when opened")
			_: parts.append("index %s" % _percent(mesh_p) if mesh_p > 0.0 else "index waiting")
		r.state.text = "   ".join(parts)
		r.state.tooltip_text = str(m.get("error", ""))
		if bool(m.get("active", false)) and follow.is_empty():
			follow = level
	if not follow.is_empty() and follow != _followed_map and _map_rows.has(follow):
		_followed_map = follow
		_follow_map.call_deferred(follow)

const WEIGHT_CORE := 0.4

func _set_stage(id: String, value: float, text: String) -> void:
	var row: Dictionary = _stage_rows.get(id, {})
	if row.is_empty():
		return
	row.bar.value = clampf(value, 0.0, 1.0) * 100.0
	row.state.text = text
