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
	_apply_wave_sim(m, cfg.get("sim", null))
	m.render_priority = 1   # draw after other transparents sitting at the same depth
	return m


# ---------------------------------------------------------------------------
# THE WAVE MOTION, from the level's WaterOceanSimulationEntityData.
#
# This is the half of the water the depot record does not describe. The game
# runs an FFT ocean at runtime and nothing on disk holds the wave field, but the
# simulation's INPUTS are on disk, and four sharpened sines pointed the way the
# map says the wind blows read far more like that map than one fixed direction
# does. See highpoly_gamesource.water_sim for what each value was measured to be
# and water.gdshader for the line between the game's numbers and ours.
#
# THE GAME'S:  WindAngle, WindDistribution, WindSpeed, Choppiness,
#              FoamThreshold, EnableFoam.
# OURS:        the four wavelength ratios, the count of four, the axis
#              convention for WindAngle, and every normalisation constant below
#              (the game's scalars are not in physical units).

# HOW MANY COMPONENTS, AND HOW LONG EACH ONE IS. Both ours; the FFT band
# lengths are a property of a simulation that is not written down.
#
# This was four components at 1 / 0.63 / 0.41 / 0.27 and it read as corduroy.
# A sum of sines repeats on the least common multiple of its wavelengths, and
# those ratios are close enough to 1 : 2/3 : 2/5 : 1/4 that the whole field
# repeated within a few tens of metres.
#
# The ladder is now powers of 1/phi. phi's continued fraction is all ones, which
# makes it the hardest number to approximate with a rational, so the sum's
# repeat period is pushed far past anything a level holds. Eight components
# rather than four because four is simply too few to read as a sea however they
# are spaced - real water has a continuous spectrum and we are sampling it.
const WAVE_COUNT := 8
const WAVE_LENGTH_RATIO := [1.0, 0.618, 0.382, 0.236, 0.146, 0.090, 0.056, 0.034]
# WindSpeed is 0.01 on every calm multiplayer water and 0.07 on the windy ones,
# so 0.07 is taken as neutral and the D-Day sea (0.30-0.75) comes out rough.
const WIND_SPEED_NEUTRAL := 0.07
# FoamThreshold spans 0..290 game-wide with no anchor; the multiplayer maps sit
# in 0..75, so that is the range normalised over.
const FOAM_THRESHOLD_SPAN := 80.0
# With no simulation to read: a neutral four-way spread, roughly what the shader
# did before any of this was mined.
const DEFAULT_WAVE_DIR_DEG := [0.0, 40.0, -65.0, 110.0]
const DEFAULT_WAVE_AMP := [1.0, 0.62, 0.42, 0.28]
# How wide a lobe's fan opens, in degrees, total. Ours. Wide enough that the
# components cannot beat against each other into a regular pattern, narrow
# enough that a map which authored a tight directional sea still looks
# directional rather than like chop from everywhere at once.
const SPREAD_DEG := 46.0


static func _apply_wave_sim(m: ShaderMaterial, sim_v: Variant) -> void:
	if not (sim_v is Dictionary) or (sim_v as Dictionary).is_empty():
		m.set_shader_parameter("waves", _default_waves())
		return
	var sim: Dictionary = sim_v
	m.set_shader_parameter("waves", _waves_from(sim))
	# WindSpeed -> amplitude. sqrt because the visible difference between 0.01
	# and 0.07 should not be a factor of seven in wave height.
	var speed := maxf(float(sim.get("speed", 0.0)), 0.0)
	m.set_shader_parameter("wave_gain",
		clampf(sqrt(speed / WIND_SPEED_NEUTRAL), 0.40, 2.20))
	# Choppiness -> crest sharpening. Clamped below 1 because the phase warp
	# folds back on itself past that and the crests start to self-intersect.
	m.set_shader_parameter("wave_chop",
		clampf(float(sim.get("chop", 0.0)), 0.0, 1.2) * 0.7)
	# FoamThreshold -> where a crest goes white. Low threshold, foam on any
	# crest; high, only on the sharpest.
	# The 0.58 floor is not slack: crest_h is a four-component sine sum
	# normalised over its own amplitude, so it clusters around the middle and a
	# cutoff below about half puts foam on most of the surface.
	var thr := clampf(float(sim.get("foam_threshold", 0.0)) / FOAM_THRESHOLD_SPAN, 0.0, 1.0)
	m.set_shader_parameter("foam_cut", lerpf(0.58, 0.95, thr))
	m.set_shader_parameter("foam_crest", bool(sim.get("foam", true)))


# WindAngle + WindDistribution -> up to four (direction, amplitude, wavelength).
#
# The curve's control points ARE the lobes: an author put them there. They are
# taken strongest first, dropping any that lands on top of one already taken
# (circularly - x = 0 and x = 1 are the same bearing), and the strongest is
# normalised to 1.
static func _waves_from(sim: Dictionary) -> Array:
	var angle := float(sim.get("angle", 0.0))
	var pts: Variant = sim.get("dist", [])
	var lobes: Array = []
	if pts is Array:
		for p in pts:
			if not (p is Array) or (p as Array).size() < 2:
				continue
			if float(p[1]) <= 0.001:
				continue
			lobes.append([float(p[0]), float(p[1])])
	lobes.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var picked: Array = []
	for l in lobes:
		var clash := false
		for q in picked:
			var d: float = absf(float(q[0]) - float(l[0]))
			if minf(d, 1.0 - d) < 0.06:
				clash = true
				break
		if not clash:
			picked.append(l)
		if picked.size() >= 4:
			break
	if picked.is_empty():
		return _default_waves()

	# A LOBE IS A SPREAD, NOT A RAY. This used to emit one component per lobe and
	# then pad from the dominant one, and on any map whose curve is a mirrored
	# pair that produced two trains half a turn apart at similar amplitude. Two
	# opposed trains of the same wavelength are a STANDING wave: it does not
	# travel, and it draws a regular egg-crate lattice. mp_dumbo is exactly that
	# case (lobes at x = 0.25 and x = 0.75), and the lattice was plainly visible.
	#
	# Handing every lobe a fan of components fixes it without reinterpreting the
	# curve, which matters because the direction reading is marked probable
	# rather than verified. Opposed lobes stay opposed, they simply stop being
	# single rays that can cancel into a grid. The spread and the count are ours
	# and were always ours; the bearings and the relative amplitudes are still
	# the map's.
	var top := float(picked[0][1])
	var out: Array = []
	var per := maxi(1, int(WAVE_COUNT / picked.size()))
	for li in range(picked.size()):
		var base: float = angle + (float(picked[li][0]) - 0.5) * TAU
		var amp: float = float(picked[li][1]) / top
		for j in range(per):
			if out.size() >= WAVE_COUNT:
				break
			# Fanned by an irrational multiple of a turn so no two components of
			# any lobe are parallel, and none of one lobe is exactly opposed to
			# one of another. A round step (say 15 degrees) reintroduces the same
			# coincidences one level down.
			var k := float(out.size())
			var off: float = SPREAD_DEG * (fmod(k * 0.61803399, 1.0) - 0.5)
			out.append(Vector4(cos(base + deg_to_rad(off)),
				sin(base + deg_to_rad(off)),
				amp * pow(0.72, float(j)),
				float(WAVE_LENGTH_RATIO[out.size()])))
	# Any slots the division left over go to the dominant lobe, weakest first.
	var tail: float = float((out[out.size() - 1] as Vector4).z)
	while out.size() < WAVE_COUNT:
		var k2 := float(out.size())
		var off2: float = SPREAD_DEG * (fmod(k2 * 0.61803399, 1.0) - 0.5)
		var a2: float = angle + (float(picked[0][0]) - 0.5) * TAU + deg_to_rad(off2)
		tail *= 0.72
		out.append(Vector4(cos(a2), sin(a2), tail,
			float(WAVE_LENGTH_RATIO[out.size()])))
	return out


static func _default_waves() -> Array:
	var out: Array = []
	for i in range(WAVE_COUNT):
		# The authored four, then a continuing fan for the rest.
		var deg: float = float(DEFAULT_WAVE_DIR_DEG[i]) if i < DEFAULT_WAVE_DIR_DEG.size() \
			else float(DEFAULT_WAVE_DIR_DEG[0]) + SPREAD_DEG * (fmod(float(i) * 0.61803399, 1.0) - 0.5)
		var amp: float = float(DEFAULT_WAVE_AMP[i]) if i < DEFAULT_WAVE_AMP.size() \
			else float(DEFAULT_WAVE_AMP[DEFAULT_WAVE_AMP.size() - 1]) * pow(0.72, float(i - DEFAULT_WAVE_AMP.size() + 1))
		var a := deg_to_rad(deg)
		out.append(Vector4(cos(a), sin(a), amp, float(WAVE_LENGTH_RATIO[i])))
	return out


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
