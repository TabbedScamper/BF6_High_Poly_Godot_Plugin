@tool
extends RefCounted
class_name HighpolyTheme
# Dock colour scheme, loaded from theme.json.
#
# The palette is DATA, not code: a new season is a JSON edit that ships with the
# map packages, so re-skinning never needs a plugin release. Colours are applied
# as per-control theme overrides on our own dock only — the editor's theme is
# never touched, so the rest of the SDK keeps its normal look.
#
# Restraint is deliberate: accent goes on section headings and progress fills,
# everything else inherits the editor. A dock that ignores the user's editor
# theme reads as broken, not branded.

const PALETTE_PATH := "res://addons/highpoly_toggle/theme.json"

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

# ---------- appliers ----------
static func heading(l: Label) -> Label:
	l.add_theme_color_override("font_color", col("heading"))
	return l

# Accent the filled part of a bar; leave the background to the editor theme so
# the bar still reads correctly in both light and dark editor themes.
static func bar(p: ProgressBar) -> ProgressBar:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col("accent")
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	p.add_theme_stylebox_override("fill", sb)
	return p

static func separator(s: HSeparator) -> HSeparator:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col("accent_dim")
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	s.add_theme_stylebox_override("separator", sb)
	return s
