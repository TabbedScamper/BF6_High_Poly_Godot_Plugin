@tool
extends RefCounted
class_name HighpolyTheme
# Dock colour scheme, loaded from theme.json.
#
# The palette is DATA, not code: a new season is a JSON edit that ships with the
# map packages, so re-skinning never needs a plugin release.
#
# The panel sits over a video backdrop, so it carries a full control theme
# rather than a few colour overrides: white text on translucent white masks,
# outlined in white, over a darkened loop. That theme is set on the panel root
# ONLY. Godot resolves theme items by walking up the tree, so anything not
# defined here still falls through to the editor's own theme, and the rest of
# the SDK is never touched.

const PALETTE_PATH := "res://addons/highpoly_toggle/theme.json"
const FONT_PATH := "res://addons/highpoly_toggle/ui_font.ttf"

static var _font: FontFile = null
static var _font_tried := false

# The season face, if one is installed. Loaded straight off disk rather than
# through the import system, so it can be swapped without a reimport.
static func ui_font() -> FontFile:
	if _font_tried: return _font
	_font_tried = true
	if not FileAccess.file_exists(FONT_PATH): return null
	var f := FontFile.new()
	if f.load_dynamic_font(ProjectSettings.globalize_path(FONT_PATH)) != OK: return null
	# A display face is drawn for headlines, not for a settings panel, so it is
	# missing characters this UI uses — the multiplication sign in "map data x2",
	# for one. Without a fallback those render as empty boxes.
	#
	# The editor's own font goes first: it is the widest coverage on hand, and
	# Godot's built-in fallback does not carry everything (it has no arrow), so
	# relying on that alone would leave real gaps.
	var fbs: Array[Font] = []
	if Engine.is_editor_hint():
		var et := EditorInterface.get_editor_theme()
		if et != null:
			for n in ["main", "bold", "source"]:
				if et.has_font(n, "EditorFonts"):
					fbs.append(et.get_font(n, "EditorFonts"))
					break
	fbs.append(ThemeDB.fallback_font)
	f.fallbacks = fbs
	_font = f
	return _font

# The SDK's own logo colour, so an install with no palette file still looks
# deliberate rather than defaulting to something invented.
const FALLBACK := {
	"accent": "#ff3d00",
	"accent_dim": "#a82800",
	"heading": "#ffb59e",
	"splash_bg": "#140a06",
}

static var _p: Dictionary = {}
static var _loaded := false

static func _load() -> void:
	if _loaded: return
	_loaded = true
	_p = FALLBACK.duplicate()
	if not FileAccess.file_exists(PALETTE_PATH): return
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(PALETTE_PATH))
	if not (j is Dictionary): return
	for k in (j as Dictionary):
		if k != "note" and k != "name":
			_p[k] = (j as Dictionary)[k]

static func reload() -> void:
	_loaded = false
	_load()

static func palette_name() -> String:
	if not FileAccess.file_exists(PALETTE_PATH): return "built-in"
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(PALETTE_PATH))
	return str((j as Dictionary).get("name", "custom")) if j is Dictionary else "custom"

static func col(key: String) -> Color:
	_load()
	var v := str(_p.get(key, FALLBACK.get(key, "#ffffff")))
	return Color.html(v) if Color.html_is_valid(v) else Color.WHITE

static func accent() -> Color: return col("accent")

# The panel runs larger than the editor's own text. Scaled off the editor's size
# rather than pinned to a number, so it still tracks a user who has already set
# their editor font larger or smaller.
const FONT_SCALE := 1.5

static func base_font_size() -> int:
	if Engine.is_editor_hint():
		var et := EditorInterface.get_editor_theme()
		if et != null and et.has_font_size("main_size", "EditorFonts"):
			return et.get_font_size("main_size", "EditorFonts")
	return 14

# Scale a font size that was picked relative to the old default (e.g. the 12px
# used for the storage readout), so those stay proportionally smaller.
static func fs(base: int) -> int:
	return int(round(float(base) * FONT_SCALE))

# Numeric palette entries (currently just the backdrop dim). Tunable from
# theme.json so brighter or darker footage can be balanced without a release.
static func num(key: String, def: float) -> float:
	_load()
	var v: Variant = _p.get(key, def)
	return float(v) if (v is float or v is int) else def

# ---------- individual appliers (used where a control needs to differ) ----------
static func heading(l: Label) -> Label:
	l.add_theme_color_override("font_color", col("accent"))
	return l

static func bar(p: ProgressBar) -> ProgressBar:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col("accent")
	sb.set_corner_radius_all(2)
	p.add_theme_stylebox_override("fill", sb)
	return p

static func separator(s: HSeparator) -> HSeparator:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.22)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	s.add_theme_stylebox_override("separator", sb)
	return s

# A toggle chip: off reads as an outlined mask like any other control, on fills
# with the accent. Replaces CheckBox everywhere in the panel — a chip states its
# own state at a glance, packs sideways into a wrapping row, and does not need a
# tick column reserved down the left of every setting.
static func chip(text: String, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.tooltip_text = tip
	b.theme_type_variation = "HighpolyChip"
	return b

# The hover-description box. Nearly opaque: it sits over the video, and a
# translucent panel with waves moving behind the text is unreadable.
static func tip_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col("splash_bg")
	sb.bg_color.a = 0.97
	sb.border_color = col("accent")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	return sb

# The panel's bright outline. draw_center off so the video shows through.
static func panel_border() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_color = col("accent")
	sb.set_border_width_all(2)
	return sb

# ---------- the panel theme ----------
# One translucent white mask, outlined in white, at four interaction strengths.
static func _mask(fill: float, border: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, fill)
	sb.border_color = Color(1, 1, 1, border)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

# Godot's slider grabber is an ICON, not a stylebox, so a pure-white grabber
# means generating one — there is no colour property to set.
static func _dot(radius: int, c: Color) -> ImageTexture:
	var d := radius * 2
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r2 := float(radius * radius)
	for y in range(d):
		for x in range(d):
			var dx := float(x - radius) + 0.5
			var dy := float(y - radius) + 0.5
			var dist2 := dx * dx + dy * dy
			if dist2 <= r2:
				# feather the last pixel so the dot is not visibly stair-stepped
				var a: float = clampf((r2 - dist2) / float(radius) * 0.6, 0.0, 1.0)
				img.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * a))
	return ImageTexture.create_from_image(img)

static func build_ui_theme() -> Theme:
	var t := Theme.new()
	var white := Color(1, 1, 1)
	var faded := Color(1, 1, 1, 0.38)

	# default_font covers every control resolving through this theme, so the
	# face lands on labels, buttons, dropdowns and tooltips in one assignment
	var f := ui_font()
	if f != null: t.default_font = f
	t.default_font_size = fs(base_font_size())

	# Buttons wear the mask. Checkboxes deliberately do NOT — a mask behind every
	# checkbox turns a settings list into a wall of boxes; they just go white.
	for ty in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", ty, _mask(0.10, 0.55))
		t.set_stylebox("hover", ty, _mask(0.20, 0.85))
		t.set_stylebox("pressed", ty, _mask(0.30, 1.0))
		t.set_stylebox("focus", ty, _mask(0.0, 0.9))
		t.set_stylebox("disabled", ty, _mask(0.04, 0.16))
	for ty in ["Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton", "LinkButton"]:
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			t.set_color(k, ty, white)
		t.set_color("font_disabled_color", ty, faded)
	t.set_color("font_color", "Label", white)
	t.set_color("font_color", "RichTextLabel", white)
	t.set_color("default_color", "RichTextLabel", white)

	# Chips: same mask when off, accent fill when on. Godot draws a toggle
	# button's "pressed" stylebox for as long as it is switched on, which is
	# exactly the "active" state we want to colour.
	var on := StyleBoxFlat.new()
	on.bg_color = col("accent")
	on.border_color = white
	on.set_border_width_all(1)
	on.set_corner_radius_all(3)
	on.content_margin_left = 8
	on.content_margin_right = 8
	on.content_margin_top = 4
	on.content_margin_bottom = 4
	var on_hover := on.duplicate() as StyleBoxFlat
	on_hover.bg_color = col("accent").lightened(0.15)
	t.set_type_variation("HighpolyChip", "Button")
	t.set_stylebox("normal", "HighpolyChip", _mask(0.08, 0.45))
	t.set_stylebox("hover", "HighpolyChip", _mask(0.18, 0.80))
	t.set_stylebox("pressed", "HighpolyChip", on)
	t.set_stylebox("hover_pressed", "HighpolyChip", on_hover)
	t.set_stylebox("disabled", "HighpolyChip", _mask(0.03, 0.14))
	t.set_stylebox("focus", "HighpolyChip", _mask(0.0, 0.90))
	for k in ["font_color", "font_hover_color", "font_pressed_color",
			"font_hover_pressed_color", "font_focus_color"]:
		t.set_color(k, "HighpolyChip", white)
	t.set_color("font_disabled_color", "HighpolyChip", faded)

	# Sliders: pure white.
	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(1, 1, 1, 0.22)
	groove.set_corner_radius_all(2)
	groove.content_margin_top = 2
	groove.content_margin_bottom = 2
	var filled := StyleBoxFlat.new()
	filled.bg_color = white
	filled.set_corner_radius_all(2)
	filled.content_margin_top = 2
	filled.content_margin_bottom = 2
	var dot := _dot(7, white)
	for ty in ["HSlider", "VSlider"]:
		t.set_stylebox("slider", ty, groove)
		t.set_stylebox("grabber_area", ty, filled)
		t.set_stylebox("grabber_area_highlight", ty, filled)
		t.set_icon("grabber", ty, dot)
		t.set_icon("grabber_highlight", ty, dot)
		t.set_icon("grabber_disabled", ty, _dot(7, faded))

	# Progress bars keep the accent so they read as activity, not chrome.
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = Color(1, 1, 1, 0.12)
	pb_bg.set_corner_radius_all(2)
	var pb_fill := StyleBoxFlat.new()
	pb_fill.bg_color = col("accent")
	pb_fill.set_corner_radius_all(2)
	t.set_stylebox("background", "ProgressBar", pb_bg)
	t.set_stylebox("fill", "ProgressBar", pb_fill)
	t.set_color("font_color", "ProgressBar", white)

	# The scroller must not paint a panel over the video.
	var clear := StyleBoxEmpty.new()
	t.set_stylebox("panel", "ScrollContainer", clear)
	t.set_stylebox("panel", "PanelContainer", clear)
	return t
