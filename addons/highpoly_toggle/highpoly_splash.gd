@tool
extends Control
class_name HighpolySplash
# The boot animation: covers the whole tab, plays once, fades into the dock.
#
# Godot has no GIF importer, so the animation ships as a SPRITE SHEET - the same
# trick the FX overlay already uses for fire and smoke. tools/make_splash.py
# turns any .gif into splash.png + splash.json; drop those in beside this script
# and it plays. With no assets present this is a complete no-op, so the plugin
# behaves exactly as before until the artwork exists.
#
# Plays once per editor session by default. A splash on EVERY tab click is
# charming twice and irritating forever, and this tab gets clicked a lot.

# preload rather than the global class name: a brand-new class_name is not in
# the registry until the editor rescans, which breaks on a fresh install
const Pal = preload("highpoly_theme.gd")
const SHEET := "res://addons/highpoly_toggle/splash.png"
const META := "res://addons/highpoly_toggle/splash.json"
const FADE_SECS := 0.45

static var _played_this_session := false

var _tex: Texture2D = null
var _cols := 1
var _rows := 1
var _frames := 1
var _fps := 20.0
var _frame := 0.0
var _fading := false
var _fade_t := 0.0

static func available() -> bool:
	return FileAccess.file_exists(SHEET) and FileAccess.file_exists(META)

# Is there anything to play right now? The caller instantiates — a script cannot
# refer to its own class_name before the editor has registered it.
static func should_play(force := false) -> bool:
	if not available(): return false
	if _played_this_session and not force: return false
	_played_this_session = true
	return true

# Returns false when the artwork can't be decoded; caller should discard.
func setup() -> bool:
	# decoded directly rather than through the import system, so the sheet can be
	# dropped in and replaced without a reimport (same reason as the map tiles)
	var img := Image.load_from_file(ProjectSettings.globalize_path(SHEET))
	if img == null: return false
	_tex = ImageTexture.create_from_image(img)
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(META))
	if j is Dictionary:
		var d: Dictionary = j
		_cols = maxi(1, int(d.get("cols", 1)))
		_rows = maxi(1, int(d.get("rows", 1)))
		_frames = maxi(1, int(d.get("frames", _cols * _rows)))
		_fps = maxf(1.0, float(d.get("fps", 20.0)))
	return true

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP     # swallow clicks while playing
	z_index = 100
	set_process(true)

func _process(delta: float) -> void:
	if _tex == null:
		queue_free()
		return
	if not _fading:
		_frame += delta * _fps
		if _frame >= float(_frames):
			_fading = true
		queue_redraw()
		return
	_fade_t += delta
	modulate.a = clampf(1.0 - _fade_t / FADE_SECS, 0.0, 1.0)
	if modulate.a <= 0.0:
		queue_free()          # dock is fully revealed; stop costing anything
	else:
		queue_redraw()

func _draw() -> void:
	if _tex == null: return
	# solid backdrop so the dock doesn't show through mid-animation; it is the
	# palette's colour, which is what makes the fade land ON the theme
	draw_rect(Rect2(Vector2.ZERO, size), Pal.col("splash_bg"))
	var f := clampi(int(_frame), 0, _frames - 1)
	var fw := float(_tex.get_width()) / float(_cols)
	var fh := float(_tex.get_height()) / float(_rows)
	@warning_ignore("integer_division")
	var src := Rect2(float(f % _cols) * fw, float(f / _cols) * fh, fw, fh)
	# contain: keep the artwork's aspect, centred, never cropped or stretched
	var scale := minf(size.x / fw, size.y / fh)
	var dst_size := Vector2(fw, fh) * scale
	draw_texture_rect_region(_tex,
		Rect2((size - dst_size) * 0.5, dst_size), src)
