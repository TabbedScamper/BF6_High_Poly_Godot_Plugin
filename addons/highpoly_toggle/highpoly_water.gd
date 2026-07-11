@tool
extends Object
class_name HighpolyWater
# Water-surface materials for the map-context overlay.
#
# Each map's placements.json can carry a "water" key: one {height, center, size}
# dict or a LIST of them (lakes/rivers/pools at different elevations). Entries
# may add:
#   "kind":  "ocean" | "river" | "lake" | "pool"  (tint/ripple preset; default lake)
#   "yaw":   rotation around Y in radians (rotated river/lake quads)
#   "color": [r, g, b] shallow-tint override (0..1), when the map's water is
#            visibly non-default (e.g. Contaminated's murk)
#
# The shader lives next to this script as water.gdshader; it is read as TEXT
# into a Shader resource (same spirit as TERRAIN_SHADER in highpoly_mapcontext:
# no dependency on Godot having imported the file, works headless).

const KIND_PRESETS := {
	# shallow_color / deep_color are the BF6-ish look per water type;
	# ripple_scale in metres (ocean swells big/calm, pools tiny/fast).
	"ocean": {
		"shallow_color": Color(0.10, 0.30, 0.35), "deep_color": Color(0.008, 0.055, 0.115),
		"depth_fade": 18.0, "ripple_scale": 34.0, "ripple_speed": 0.65, "ripple_strength": 0.55,
	},
	"river": {
		"shallow_color": Color(0.16, 0.34, 0.30), "deep_color": Color(0.030, 0.095, 0.105),
		"depth_fade": 8.0, "ripple_scale": 12.0, "ripple_speed": 1.25, "ripple_strength": 0.50,
	},
	"lake": {
		"shallow_color": Color(0.11, 0.34, 0.36), "deep_color": Color(0.012, 0.074, 0.135),
		"depth_fade": 14.0, "ripple_scale": 22.0, "ripple_speed": 0.80, "ripple_strength": 0.45,
	},
	"pool": {
		"shallow_color": Color(0.15, 0.42, 0.46), "deep_color": Color(0.045, 0.180, 0.260),
		"depth_fade": 3.0, "ripple_scale": 4.0, "ripple_speed": 1.60, "ripple_strength": 0.35,
	},
}

static var _shader: Shader = null

static func shader() -> Shader:
	if _shader == null:
		var p := (HighpolyWater as Script).resource_path.get_base_dir() + "/water.gdshader"
		var src := FileAccess.get_file_as_string(p)
		if src.is_empty():
			return null
		_shader = Shader.new()
		_shader.code = src
	return _shader

# ShaderMaterial for one extracted water plane config. Returns null only if the
# shader file is missing (caller should fall back to a flat translucent color).
static func material(cfg: Dictionary) -> ShaderMaterial:
	var sh := shader()
	if sh == null:
		return null
	var kind := str(cfg.get("kind", "lake"))
	var preset: Dictionary = KIND_PRESETS.get(kind, KIND_PRESETS["lake"])
	var m := ShaderMaterial.new()
	m.shader = sh
	for k in preset:
		m.set_shader_parameter(k, preset[k])
	var c: Variant = cfg.get("color", null)
	if c is Array and c.size() >= 3:
		m.set_shader_parameter("shallow_color", Color(float(c[0]), float(c[1]), float(c[2])))
		m.set_shader_parameter("deep_color", Color(float(c[0]) * 0.25, float(c[1]) * 0.25, float(c[2]) * 0.35))
	m.render_priority = 1   # draw after other transparents sitting at the same depth
	return m
