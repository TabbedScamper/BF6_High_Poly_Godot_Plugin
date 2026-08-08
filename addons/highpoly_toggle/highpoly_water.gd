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
#
# `gs` is an open HighpolyGameSource, or null. The mined COLOURS ride in the
# config and survive a round trip through placements.json, so they apply with or
# without it; the mined TEXTURES are decoded from the install on demand and need
# the game source, so a cached-only load keeps the procedural foam. That split
# is deliberate: colour is what makes one map's water look like that map's
# water, and it is the part that costs nothing to carry.
static func material(cfg: Dictionary, gs = null) -> ShaderMaterial:
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
	_apply_game_look(m, cfg.get("look", null), gs)
	m.render_priority = 1   # draw after other transparents sitting at the same depth
	return m


# What the map's own WaterSurfaceEntityData -> ShaderBlockDepot record says.
# See highpoly_gamesource._water_look for how it is resolved and water.gdshader
# for which parts of the look this drives and which are still ours.
static func _apply_game_look(m: ShaderMaterial, look_v: Variant, gs) -> void:
	if not (look_v is Dictionary):
		return
	var look: Dictionary = look_v

	# COLOUR. These are LINEAR floats straight out of the depot, and the shader
	# takes them through uniforms with no source_color hint for exactly that
	# reason — handing them to a source_color uniform would sRGB->linear them a
	# second time and turn the water to mud.
	var sh_a: Array = look.get("shallow", [])
	var dp_a: Array = look.get("deep", [])
	if sh_a.size() >= 3:
		# WHICH OF THE FOAM VARIANT'S TWO FLOAT3s IS SHALLOW IS NOT SETTLED.
		# The pair reads (0.0219 grey, 0.0684 grey) on mp_dumbo and
		# ((0, 0.056, 0.044), (0, 0.076, 0.082)) on mp_aftermath. The brighter is
		# taken as shallow because that is the physical convention, but on
		# aftermath the darker one is the greener and the brighter the bluer,
		# which argues the other way. Two samples cannot decide it; swapping the
		# two lines below is the whole change if a measurement ever does.
		m.set_shader_parameter("use_game_color", true)
		m.set_shader_parameter("game_shallow",
			Vector3(float(sh_a[0]), float(sh_a[1]), float(sh_a[2])))
		var dp: Array = dp_a if dp_a.size() >= 3 else sh_a
		# The ocean variant ships ONE colour, so its deep end is still ours: the
		# same colour taken down, not a second mined value.
		var k: float = 1.0 if dp_a.size() >= 3 else 0.28
		m.set_shader_parameter("game_deep",
			Vector3(float(dp[0]) * k, float(dp[1]) * k, float(dp[2]) * k))

	if str(look.get("variant", "")) == "ocean":
		# An open-water map: bigger swell, slower, and the ripple normal carries
		# the small scale so the sine field does not have to.
		m.set_shader_parameter("ripple_scale", 34.0)
		m.set_shader_parameter("ripple_speed", 0.6)
		m.set_shader_parameter("ripple_strength", 0.35)

	if gs == null:
		return
	var tex: Dictionary = look.get("tex", {})

	# THE RIPPLE NORMAL, tagged as a normal map on the way in. It is RG-encoded
	# (B is smoothness, A is height), and block-compressing an RG normal as DXT
	# colour puts visible banding on every wave.
	if tex.has("detail_nsh"):
		var dn = gs.water_texture(tex["detail_nsh"], true)
		if dn != null:
			m.set_shader_parameter("detail_tex", dn)
			m.set_shader_parameter("has_detail", true)

	# FOAM. The two variants pack it differently, so the mode travels with the
	# texture rather than being inferred in the shader from the pixels.
	if tex.has("foam_nsh"):
		var fn = gs.water_texture(tex["foam_nsh"], true)
		if fn != null:
			m.set_shader_parameter("foam_tex", fn)
			m.set_shader_parameter("foam_mode", 2)
	elif tex.has("foam_rgb"):
		var fr = gs.water_texture(tex["foam_rgb"], false)
		if fr != null:
			m.set_shader_parameter("foam_tex", fr)
			m.set_shader_parameter("foam_mode", 1)
