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
# Plays on every open. The panel is opened deliberately from a toolbar button
# rather than sitting there as a dock, so each open is a fresh entrance and
# worth the five seconds. A click anywhere skips straight to the end for the
# times you just want the buttons.

# preload rather than the global class name: a brand-new class_name is not in
# the registry until the editor rescans, which breaks on a fresh install
const Pal = preload("highpoly_theme.gd")
const LOGO := "res://addons/highpoly_toggle/logo.png"

const WAVES_SECS := 1.30       # backdrop alone before the logo arrives
const LOGO_IN := 0.30
const LOGO_HOLD := 1.50        # "flash it, then fade it out after a few seconds"
const LOGO_OUT := 0.70
const SETTLE_SECS := 1.20      # backdrop dimming: slow, it is the mood change
const UI_DELAY := 0.30         # controls start arriving before the dim finishes
const UI_SECS := 0.85
const LOGO_MAX_FILL := 0.62    # the logo never touches the panel edges

enum { S_WAVES, S_LOGO, S_SETTLE }

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
