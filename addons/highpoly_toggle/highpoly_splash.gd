@tool
extends Control
class_name HighpolySplash
# The boot sequence, played over the panel's looping video backdrop.
#
#   1. waves fill the panel, alone
#   2. the Portal logo flashes in, holds, fades out
#   3. the backdrop settles to a dark tint - the video KEEPS LOOPING under it
#   4. the controls fade in on top
#
# This node owns only the logo and the timeline. The video and the tint belong
# to the panel and outlive the sequence, which is what lets the loop carry on
# once this frees itself: it animates other people's properties and then gets
# out of the way, rather than being a curtain that has to stay resident.
#
# Every asset is optional. No logo skips stage 2, no video skips stage 1, and
# with neither the panel simply appears - so the plugin still works exactly as
# before on an install with no artwork.
#
# Plays once per editor session and once more after a plugin update: the two
# moments where a boot animation is information rather than decoration. A click
# anywhere skips straight to the end, because the fourth time you open the panel
# in a session you want the buttons, not the show.

# preload rather than the global class name: a brand-new class_name is not in
# the registry until the editor rescans, which breaks on a fresh install
const Pal = preload("highpoly_theme.gd")
const LOGO := "res://addons/highpoly_toggle/logo.png"
const PLUGIN_CFG := "res://addons/highpoly_toggle/plugin.cfg"
# outside res:// so it survives the plugin update that triggers it
const SEEN_PATH := "user://highpoly_splash_seen.txt"

const WAVES_SECS := 1.30       # backdrop alone before the logo arrives
const LOGO_IN := 0.30
const LOGO_HOLD := 1.50        # "flash it, then fade it out after a few seconds"
const LOGO_OUT := 0.70
const SETTLE_SECS := 1.20      # backdrop dimming: slow, it is the mood change
const UI_DELAY := 0.30         # controls start arriving before the dim finishes
const UI_SECS := 0.85
const LOGO_MAX_FILL := 0.62    # the logo never touches the panel edges

enum { S_WAVES, S_LOGO, S_SETTLE }

static var _played_this_session := false

# set by the panel before setup(); this node animates them and then frees itself
var tint: ColorRect = null
var ui: Control = null
var tint_max := 0.72

var _logo: Texture2D = null
var _has_video := false
var _stage := S_WAVES
var _t := 0.0

static func available() -> bool:
	return FileAccess.file_exists(LOGO)

static func _version() -> String:
	var cf := ConfigFile.new()
	if cf.load(PLUGIN_CFG) != OK: return ""
	return str(cf.get_value("plugin", "version", ""))

# Is there anything to play right now? The caller instantiates — a script cannot
# refer to its own class_name before the editor has registered it.
static func should_play(force := false) -> bool:
	var v := _version()
	var seen := ""
	if FileAccess.file_exists(SEEN_PATH):
		seen = FileAccess.get_file_as_string(SEEN_PATH).strip_edges()
	var updated := v != "" and v != seen
	if _played_this_session and not updated and not force: return false
	_played_this_session = true
	if updated:
		var f := FileAccess.open(SEEN_PATH, FileAccess.WRITE)
		if f: f.store_string(v)
	return true

# has_video tells the sequence whether stage 1 has anything to show.
# Returns false when there is nothing to play at all; caller should discard.
func setup(has_video: bool) -> bool:
	_has_video = has_video
	if FileAccess.file_exists(LOGO):
		# decoded directly rather than through the import system, so artwork can
		# be dropped in and replaced without a reimport (as with the map tiles)
		var li := Image.load_from_file(ProjectSettings.globalize_path(LOGO))
		if li != null: _logo = ImageTexture.create_from_image(li)
	if not _has_video and _logo == null: return false
	if tint: tint.color.a = 0.0
	if ui: ui.modulate.a = 0.0
	_stage = S_WAVES
	_skip_empty()
	return true

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP     # swallow clicks, and catch the skip
	set_process(true)

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		_finish()

# Land on the end state directly. Whatever stage we were in, the panel must be
# left exactly as a completed sequence would leave it.
func _finish() -> void:
	if tint: tint.color.a = tint_max
	if ui: ui.modulate.a = 1.0
	queue_free()

func _skip_empty() -> void:
	if _stage == S_WAVES and not _has_video: _stage = S_LOGO
	if _stage == S_LOGO and _logo == null: _stage = S_SETTLE

func _advance() -> void:
	_stage += 1
	_t = 0.0
	_skip_empty()

func _process(delta: float) -> void:
	_t += delta
	match _stage:
		S_WAVES:
			if _t >= WAVES_SECS: _advance()
		S_LOGO:
			if _t >= LOGO_IN + LOGO_HOLD + LOGO_OUT: _advance()
			queue_redraw()
		S_SETTLE:
			if tint:
				tint.color.a = tint_max * clampf(_t / SETTLE_SECS, 0.0, 1.0)
			if ui:
				ui.modulate.a = clampf((_t - UI_DELAY) / UI_SECS, 0.0, 1.0)
			if _t >= maxf(SETTLE_SECS, UI_DELAY + UI_SECS):
				_finish()

func _logo_alpha() -> float:
	if _t < LOGO_IN: return _t / LOGO_IN
	if _t < LOGO_IN + LOGO_HOLD: return 1.0
	return clampf(1.0 - (_t - LOGO_IN - LOGO_HOLD) / LOGO_OUT, 0.0, 1.0)

func _draw() -> void:
	if _stage != S_LOGO or _logo == null: return
	# contain: keep the artwork's aspect, centred, never cropped or stretched
	var w := float(_logo.get_width())
	var h := float(_logo.get_height())
	var s := minf(size.x * LOGO_MAX_FILL / w, size.y * LOGO_MAX_FILL / h)
	var d := Vector2(w, h) * s
	draw_texture_rect(_logo, Rect2((size - d) * 0.5, d), false,
		Color(1, 1, 1, _logo_alpha()))
