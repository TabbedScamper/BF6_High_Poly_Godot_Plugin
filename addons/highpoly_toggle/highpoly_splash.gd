@tool
extends Control
class_name HighpolySplash
# The boot animation: covers the whole tab, plays once, fades into the dock.
#
#   1. the animation fills the panel                     (splash.png + splash.json)
#   2. the High-Poly Portal logo flashes over it         (logo.png)
#   3. it settles to black
#   4. black fades out, revealing the dock beneath
#
# Step 4 is why nothing here touches the dock's own alpha: a black overlay fading
# out over live controls IS the controls fading in from black, and doing it that
# way means the dock is never left in a half-transparent state if this node dies
# early for any reason.
#
# Godot has no GIF importer, so the animation ships as a SPRITE SHEET - the same
# trick the FX overlay already uses for fire and smoke. tools/make_splash.py
# turns any .gif into splash.png + splash.json, tools/make_logo.py trims and
# sizes logo.png. Every asset is optional: missing stages are skipped, and with
# none present this is a complete no-op, so the plugin behaves exactly as before
# until the artwork exists.
#
# Plays once per editor session, and once more after a plugin update - the two
# moments where a boot animation is information rather than decoration. A splash
# on EVERY tab click is charming twice and irritating forever, and this tab gets
# clicked a lot.

# preload rather than the global class name: a brand-new class_name is not in
# the registry until the editor rescans, which breaks on a fresh install
const Pal = preload("highpoly_theme.gd")
const SHEET := "res://addons/highpoly_toggle/splash.png"
const META := "res://addons/highpoly_toggle/splash.json"
const LOGO := "res://addons/highpoly_toggle/logo.png"
const PLUGIN_CFG := "res://addons/highpoly_toggle/plugin.cfg"
# outside res:// so it survives plugin updates - the updater overwrites the addon
const SEEN_PATH := "user://highpoly_splash_seen.txt"

const LOGO_IN := 0.12          # snap in - it is a flash, not a title card
const LOGO_HOLD := 0.60
const LOGO_OUT := 0.35
const BLACK_HOLD := 0.18
const FADE_SECS := 0.45
const LOGO_MAX_FILL := 0.7     # logo never touches the panel edges

enum { S_GIF, S_LOGO, S_BLACK, S_REVEAL }

static var _played_this_session := false

var _tex: Texture2D = null
var _logo: Texture2D = null
var _cols := 1
var _rows := 1
var _frames := 1
var _fps := 20.0
var _gif_dur := 0.0
var _stage := S_GIF
var _t := 0.0

static func available() -> bool:
	# either asset alone is a valid show
	return (FileAccess.file_exists(SHEET) and FileAccess.file_exists(META)) \
		or FileAccess.file_exists(LOGO)

static func _version() -> String:
	var cf := ConfigFile.new()
	if cf.load(PLUGIN_CFG) != OK: return ""
	return str(cf.get_value("plugin", "version", ""))

# Is there anything to play right now? The caller instantiates — a script cannot
# refer to its own class_name before the editor has registered it.
static func should_play(force := false) -> bool:
	if not available(): return false
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

# Returns false when no artwork could be decoded; caller should discard.
func setup() -> bool:
	# decoded directly rather than through the import system, so assets can be
	# dropped in and replaced without a reimport (same reason as the map tiles)
	if FileAccess.file_exists(SHEET) and FileAccess.file_exists(META):
		var img := Image.load_from_file(ProjectSettings.globalize_path(SHEET))
		if img != null:
			_tex = ImageTexture.create_from_image(img)
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(META))
			if j is Dictionary:
				var d: Dictionary = j
				_cols = maxi(1, int(d.get("cols", 1)))
				_rows = maxi(1, int(d.get("rows", 1)))
				_frames = maxi(1, int(d.get("frames", _cols * _rows)))
				_fps = maxf(1.0, float(d.get("fps", 20.0)))
			_gif_dur = float(_frames) / _fps
	if FileAccess.file_exists(LOGO):
		var li := Image.load_from_file(ProjectSettings.globalize_path(LOGO))
		if li != null: _logo = ImageTexture.create_from_image(li)
	if _tex == null and _logo == null: return false
	_stage = S_GIF
	_skip_empty()
	return true

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP     # swallow clicks while playing
	z_index = 100
	set_process(true)

# Step past any stage whose artwork is missing, so a logo-only or animation-only
# install still gets a clean sequence rather than dead air.
func _skip_empty() -> void:
	if _stage == S_GIF and _tex == null: _stage = S_LOGO
	if _stage == S_LOGO and _logo == null: _stage = S_BLACK

func _advance() -> void:
	_stage += 1
	_t = 0.0
	_skip_empty()

func _process(delta: float) -> void:
	_t += delta
	match _stage:
		S_GIF:
			if _t >= _gif_dur: _advance()
			queue_redraw()
		S_LOGO:
			if _t >= LOGO_IN + LOGO_HOLD + LOGO_OUT: _advance()
			queue_redraw()
		S_BLACK:
			if _t >= BLACK_HOLD: _advance()
		S_REVEAL:
			modulate.a = clampf(1.0 - _t / FADE_SECS, 0.0, 1.0)
			if modulate.a <= 0.0:
				queue_free()      # dock is fully revealed; stop costing anything
			else:
				queue_redraw()

func _logo_alpha() -> float:
	if _t < LOGO_IN: return _t / LOGO_IN
	if _t < LOGO_IN + LOGO_HOLD: return 1.0
	return clampf(1.0 - (_t - LOGO_IN - LOGO_HOLD) / LOGO_OUT, 0.0, 1.0)

# How far we are into settling on black. The backdrop starts as the palette's own
# deep tone and darkens as the logo leaves, so "fade to black" is one continuous
# move rather than a cut.
func _black_mix() -> float:
	match _stage:
		S_GIF: return 0.0
		S_LOGO: return clampf((_t - LOGO_IN - LOGO_HOLD) / LOGO_OUT, 0.0, 1.0)
		_: return 1.0

# contain: keep the artwork's aspect, centred, never cropped or stretched
func _fit(w: float, h: float, fill: float) -> Rect2:
	var s := minf(size.x * fill / w, size.y * fill / h)
	var d := Vector2(w, h) * s
	return Rect2((size - d) * 0.5, d)

func _draw() -> void:
	# solid backdrop so the dock never shows through mid-animation
	draw_rect(Rect2(Vector2.ZERO, size),
		Pal.col("splash_bg").lerp(Color.BLACK, _black_mix()))
	if _stage == S_GIF and _tex != null:
		var f := clampi(int(_t * _fps), 0, _frames - 1)
		var fw := float(_tex.get_width()) / float(_cols)
		var fh := float(_tex.get_height()) / float(_rows)
		@warning_ignore("integer_division")
		var src := Rect2(float(f % _cols) * fw, float(f / _cols) * fh, fw, fh)
		draw_texture_rect_region(_tex, _fit(fw, fh, 1.0), src)
	elif _stage == S_LOGO and _logo != null:
		draw_texture_rect(_logo,
			_fit(float(_logo.get_width()), float(_logo.get_height()), LOGO_MAX_FILL),
			false, Color(1, 1, 1, _logo_alpha()))
