@tool
extends Object
class_name HighpolyLighting
# Game lighting for the map-context overlay: mimics each BF6 map's real sun +
# sky + fog inside the editor, from data extracted out of the game's per-level
# VisualEnvironment EBX (ve_mp_<map>_base*: OutdoorLight component) and its
# sky-gradient texture (t_*_gradientsky_*, BC6H HDR — zenith/horizon/ground
# colours sampled offline).
#
# Injected as one owner=null "_GAME_LIGHTING" node under the level root:
#   DirectionalLight3D  — real sun azimuth/elevation/colour/relative intensity
#   WorldEnvironment    — gradient-derived sky (ambient from it), depth fog
#                         tinted with the map's horizon colour, ACES tonemap,
#                         soft glow
# Nothing is saved or exported; removing the node restores the editor's own
# preview sun/environment (Godot re-enables them when the scene stops carrying
# a DirectionalLight3D / WorldEnvironment).
#
# Sun-angle convention (photo-verified on MP_Badlands, shadow/sun-glow azimuth
# from the Rust Blackwell Fields reference stills within ~3°):
#   SunRotationX = azimuth in degrees, world XZ direction TOWARD the sun
#                  = (cos az, sin az); SunRotationY = elevation in degrees.
#   "lux" = the VE's SunIntensity (real illuminance) — mapped to a relative
#   DirectionalLight energy below (the editor has no physical light units).
#
# MP_Capstone is absent: its toc was never EBX-extracted (no VE data on disk).

const NODE := "_GAME_LIGHTING"

# per-map lighting extracted from A:\bf6dump / A:\x\<map> EBX (see
# _DevTools/photomatch + agent notes; "src" = the VisualEnvironment asset).
# sun  = SunColor (linear, gamma-lifted for display)
# top/hor/gnd = sky gradient colours (zenith / horizon / below-horizon)
const TABLE := {
	"MP_Abbasid": {"az": 225.00, "el": 44.00, "lux": 120000,
		"sun": Color(1, 0.878, 0.759), "top": Color(0.5728, 0.737, 1), "hor": Color(0.7936, 0.903, 1), "gnd": Color(0.6265, 0.7848, 1)},
	# Aftermath: the level's active VE preset is ve_mp_aftermath_sunsetovercast_03
	# (sun az/el/lux/colour below are ITS values). The sky the game shows is the
	# preset's PanoramicTexture import t_mp_aftermath_panoramicsky_sunsetovercast_07
	# (BC6H 8192x2048 equirect, GUID-verified) — "pano" swaps the gradient
	# ProceduralSky for that real panorama. "fog" 0.0 = photo-verified (the 21
	# PhotoMatch references show no atmospheric fog; the el<16 haze formula below
	# is a fallback heuristic, not Aftermath data).
	# "pano_lum" = the panorama's MEASURED mean luminance (BC6H decode, 65k
	# samples): the game's sky is authored in physical HDR units (~8,900 —
	# real overcast-sky cd/m²) and auto-exposed in-game; the editor renders it
	# raw, which read as a PURE WHITE screen. Normalizing by the measured mean
	# puts the sky on the same ~1.0 scale the exp calibration was built on.
	"MP_Aftermath": {"az": 237.90, "el": 12.90, "lux": 24000, "exp": 0.45,
		"pano": "mp_aftermath_panoramicsky.dds", "pano_lum": 8923.0, "fog": 0.0,
		"sun": Color(1, 0.5033, 0.2633), "top": Color(0.9995, 1, 0.9522), "hor": Color(1, 0.8774, 0.8688), "gnd": Color(0.7943, 0.797, 1)},
	"MP_Aftermath_Portal": {"az": 237.90, "el": 12.90, "lux": 24000, "exp": 0.45,
		"pano": "mp_aftermath_panoramicsky.dds", "pano_lum": 8923.0, "fog": 0.0,
		"sun": Color(1, 0.5033, 0.2633), "top": Color(0.9995, 1, 0.9522), "hor": Color(1, 0.8774, 0.8688), "gnd": Color(0.7943, 0.797, 1)},
	"MP_Badlands": {"az": 354.00, "el": 10.00, "lux": 45860,
		"sun": Color(1, 0.21, 0), "top": Color(0.6117, 0.6912, 1), "hor": Color(1, 0.7093, 0.5486), "gnd": Color(0.9184, 0.8495, 1)},
	"MP_Battery": {"az": 315.00, "el": 47.00, "lux": 46000,
		"sun": Color(1, 0.9665, 0.9238), "top": Color(0.8426, 0.9509, 1), "hor": Color(0.8345, 0.9571, 1), "gnd": Color(0.8322, 0.9527, 1)},
	"MP_Contaminated": {"az": 14.17, "el": 45.00, "lux": 125000,
		"sun": Color(1, 0.8336, 0.7054), "top": Color(0.7397, 0.8187, 1), "hor": Color(0.6164, 0.7385, 1), "gnd": Color(0.5678, 0.7365, 1)},
	"MP_Dumbo": {"az": 124.80, "el": 28.50, "lux": 120000,
		"sun": Color(1, 0.7759, 0.6167), "top": Color(0.5348, 0.683, 1), "hor": Color(0.9472, 0.9749, 1), "gnd": Color(0.8302, 0.8814, 1)},
	"MP_Eastwood": {"az": 199.00, "el": 38.00, "lux": 125000,
		"sun": Color(1, 0.7759, 0.6167), "top": Color(0.4071, 0.6019, 1), "hor": Color(0.6922, 0.8592, 1), "gnd": Color(0.4959, 0.6796, 1)},
	"MP_FireStorm": {"az": 302.55, "el": 35.00, "lux": 100000,
		"sun": Color(1, 0.8796, 0.8228), "top": Color(0.6494, 0.7417, 1), "hor": Color(0.7609, 0.8303, 1), "gnd": Color(0.6237, 0.7324, 1)},
	"MP_GolmudRailway": {"az": 145.00, "el": 35.00, "lux": 100000,
		"sun": Color(1, 0.971, 0.914), "top": Color(0.8523, 0.9138, 1), "hor": Color(0.3506, 0.6785, 1), "gnd": Color(0.5356, 0.7508, 1)},
	"MP_Granite_ClubHouse_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Granite_MainStreet_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Granite_Marina_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Granite_MilitaryRnD_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Granite_MilitaryStorage_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Granite_TechCampus_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Granite_Underground_Portal": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Limestone": {"az": 245.00, "el": 66.00, "lux": 125000,
		"sun": Color(1, 0.9527, 0.893), "top": Color(0.4814, 0.7267, 1), "hor": Color(0.7018, 0.8992, 1), "gnd": Color(0.5279, 0.7705, 1)},
	"MP_Outskirts": {"az": 143.00, "el": 30.00, "lux": 100000,
		"sun": Color(1, 0.9871, 0.9114), "top": Color(1, 0.8371, 0.6804), "hor": Color(1, 0.8371, 0.6804), "gnd": Color(1, 0.8371, 0.6804)},
	"MP_Plaza": {"az": 300.00, "el": 26.00, "lux": 145000,
		"sun": Color(1, 0.5249, 0.1534), "top": Color(1, 0.9368, 0.8488), "hor": Color(1, 0.9454, 0.9101), "gnd": Color(0.42, 0.36, 0.32)},
	"MP_Portal_Sand": {"az": 280.00, "el": 27.50, "lux": 135000,
		"sun": Color(1, 0.8848, 0.7375), "top": Color(0.3261, 0.5097, 1), "hor": Color(0.3313, 0.5188, 1), "gnd": Color(0.45, 0.42, 0.38)},
	"MP_Subsurface": {"az": 200.36, "el": 43.96, "lux": 0.001,
		"sun": Color(1, 0.8796, 0.8228), "top": Color(0.35, 0.37, 0.4), "hor": Color(0.45, 0.44, 0.42), "gnd": Color(0.3, 0.29, 0.28)},
	"MP_Tungsten": {"az": 350.00, "el": 20.00, "lux": 50000,
		"sun": Color(1, 0.8796, 0.8228), "top": Color(0.5771, 0.8458, 1), "hor": Color(0.5532, 0.835, 1), "gnd": Color(0.59, 0.8558, 1)},
}

static func has_data(map: String) -> bool:
	return TABLE.has(map) or not mined(map).is_empty()

# ---------------------------------------------------------------------------
# THE MINED VisualEnvironment
#
# TABLE above is 7 hand-maintained values per map. The map package now carries
# 56, read straight out of the level's VisualEnvironment preset — sun, sky, fog,
# exposure, colour grading, white balance, ambient occlusion, GI and shadow
# cascades. Where a map has them, they win; TABLE stays as the fallback for
# anyone whose map data predates this, and for the handful of fields the mine
# does not cover (the sky gradient colours).
#
# Verified before being trusted: mining all 22 maps reproduced every one of the
# 21 rows TABLE already had, exactly, and supplied MP_Capstone which it lacked.
# So this is not a new set of numbers, it is the same numbers plus 49 more.
const CACHE := "user://mapcontext"

static var _mined: Dictionary = {}          # map -> {} (absent) or the fields

static func mined(map: String) -> Dictionary:
	if map == "":
		return {}
	if _mined.has(map):
		return _mined[map]
	var out: Dictionary = {}
	var p := "%s/%s/placements.json" % [CACHE, map]
	if FileAccess.file_exists(p):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if j is Dictionary:
			var lit: Variant = (j as Dictionary).get("lighting")
			if lit is Dictionary and (lit as Dictionary).get("fields") is Dictionary:
				out = (lit as Dictionary)["fields"]
	_mined[map] = out
	return out

# Local lighting zones (interiors, alleys, dark spots) with a world extent.
static func zones(map: String) -> Array:
	if map == "":
		return []
	var p := "%s/%s/placements.json" % [CACHE, map]
	if not FileAccess.file_exists(p):
		return []
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (j is Dictionary):
		return []
	var z: Variant = (j as Dictionary).get("light_zones")
	return z if z is Array else []

static func forget(map := "") -> void:
	if map == "":
		_mined.clear()
	else:
		_mined.erase(map)

# A vec4/vec3 field arrives as an Array. Colour without the magnitude.
static func _col(v: Variant, fallback: Color) -> Color:
	if not (v is Array) or (v as Array).size() < 3:
		return fallback
	var a: Array = v
	return Color(float(a[0]), float(a[1]), float(a[2]))

# The same array, normalised, plus how bright it was. BF6 stores fog colour and
# similar as HDR radiance — `(1385, 2132, 3072)` is a sky blue at ~3072 — so hue
# and magnitude have to be separated rather than clamped.
static func _col_hdr(v: Variant, fallback: Color) -> Array:
	if not (v is Array) or (v as Array).size() < 3:
		return [fallback, 1.0]
	var a: Array = v
	var m: float = maxf(maxf(float(a[0]), float(a[1])), float(a[2]))
	if m <= 0.0001:
		return [fallback, 0.0]
	return [Color(float(a[0]) / m, float(a[1]) / m, float(a[2]) / m), m]

# world-space unit vector TOWARD the sun (photo-verified convention, see header)
static func sun_dir(az_deg: float, el_deg: float) -> Vector3:
	var az := deg_to_rad(az_deg)
	var el := deg_to_rad(el_deg)
	return Vector3(cos(az) * cos(el), sin(el), sin(az) * cos(el)).normalized()

# SunIntensity (lux) -> relative DirectionalLight energy. Perceptual-ish curve
# anchored so full midday (~120k lux) reads as a strong editor sun and a low
# golden-hour sun (~45k) stays clearly dimmer/warmer. The game auto-exposes;
# the editor doesn't, so absolute lux can't be used directly.
static func sun_energy(lux: float) -> float:
	if lux < 10.0:
		return 0.0        # indoor maps (Subsurface): no meaningful sun
	return clampf(1.7 * pow(lux / 120000.0, 0.45), 0.15, 2.2)

# overlay meshes built while this is false stay shadow-off (the background
# builder consults it) — kept in sync by apply()/set_shadows()
static var cast_shadows := true

# Fraction of ambient held back from sky visibility so enclosed spaces keep a
# floor of light. See the block in apply() for why interiors were black without
# it. 0.0 restores the strictly sky-driven (PhotoMatch-calibrated) behaviour;
# raise it if rooms are still too dark to work in.
static var interior_fill := 0.22

# Build + inject the lighting rig. Idempotent (clears any previous rig first).
# gi/shadows: the dock's sub-checkboxes (PhotoMatch renders keep full quality
# via the defaults).
static func apply(root: Node, map: String, gi := true, shadows := true) -> String:
	if root == null:
		return "No scene open"
	clear(root)
	var m: Dictionary = mined(map)
	if not TABLE.has(map) and m.is_empty():
		return "No lighting data for %s" % map
	# TABLE is the base; every field the map package supplies overrides it. The
	# gradient colours (top/hor/gnd) are not in the VE mine, so they still come
	# from TABLE and are what the procedural fallback sky uses when a map has no
	# panorama yet.
	var e: Dictionary = (TABLE[map] as Dictionary).duplicate(true) if TABLE.has(map) else {}
	if not m.is_empty():
		if m.has("sun_az"): e["az"] = float(m["sun_az"])
		if m.has("sun_el"): e["el"] = float(m["sun_el"])
		if m.has("sun_lux"): e["lux"] = float(m["sun_lux"])
		if m.has("sun_color"): e["sun"] = _col(m["sun_color"], e.get("sun", Color.WHITE))
		for k in ["top", "hor", "gnd"]:
			if not e.has(k):
				e[k] = Color(0.6, 0.75, 1.0)

	var rig := Node3D.new()
	rig.name = NODE

	# --- sun ---
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	var dir: Vector3 = sun_dir(float(e["az"]), float(e["el"]))
	# a DirectionalLight3D shines along its local -Z: aim -Z opposite the sun
	sun.transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), Vector3(0, 200, 0))
	sun.light_color = e["sun"]
	sun.light_energy = sun_energy(float(e["lux"]))
	sun.visible = sun.light_energy > 0.0
	sun.shadow_enabled = shadows
	# 1500 m: shadows previously cut off 600 m out — on city-scale maps whole
	# blocks past the street you were on rendered shadowless ("shadows don't
	# show very well"). Note the Aftermath preset is a 24,000-lux overcast sun
	# vs a full-sky ambient: its shadows ARE soft/shallow in the game photos
	# too — depth here should match the references, not a clear-noon look.
	sun.directional_shadow_max_distance = 1500.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.5      # soft-edged sun shadows (sun disc size)
	rig.add_child(sun)

	# --- sky + environment ---
	# Maps with a "pano" entry use the REAL sky: the VE preset's PanoramicTexture
	# (equirect BC6H HDR, extracted from the dump into addons/highpoly_toggle/sky/).
	# That texture IS what the game renders behind the level — clouds, glow and
	# horizon come from data, not from gradient-colour approximation.
	var sky := Sky.new()
	var pano_tex: Texture2D = null
	var pano_scale := 0.0
	# The map package's own sky, converted from the level's PanoramicTexture.
	# EXR because Godot cannot load .dds at runtime — that limitation is why the
	# one sky this plugin used to have was welded into its own zip, and why only
	# one map ever had a real sky.
	var sp := "%s/%s/sky.exr" % [CACHE, map]
	if FileAccess.file_exists(sp):
		var img := Image.new()
		if img.load_exr_from_buffer(FileAccess.get_file_as_bytes(sp)) == OK:
			pano_tex = ImageTexture.create_from_image(img)
			# The panorama ships NORMALISED (measured mean 0.057-1.345 across all
			# 22) and the VE's LuminanceScale carries the magnitude, 500-80000.
			# Read it; do not measure the texture and normalise to its own
			# average, which throws the authored brightness away.
			pano_scale = float(m.get("sky_luminance_scale", 0.0))
	if pano_tex == null and e.has("pano"):
		# legacy: the one sky bundled inside the plugin. Already multiplied
		# through, so it is normalised by its MEASURED luminance, not by
		# LuminanceScale — the two disagree for exactly this reason.
		var pp := "res://addons/highpoly_toggle/sky/" + str(e["pano"])
		if ResourceLoader.exists(pp):
			pano_tex = load(pp)
	if pano_tex != null:
		var pmat := PanoramaSkyMaterial.new()
		pmat.panorama = pano_tex
		pmat.filter = true
		if pano_scale > 0.0:
			# Bring the authored magnitude onto the ~1.0 scale the rest of the
			# rig is calibrated against: texture x LuminanceScale is the real
			# luminance, and SKY_REF is what we call "1".
			const SKY_REF := 7000.0        # median of texture-mean x scale, fleet-wide
			pmat.energy_multiplier = clampf(pano_scale / SKY_REF, 0.05, 20.0)
		else:
			pmat.energy_multiplier = 1.0 / maxf(float(e.get("pano_lum", 1.0)), 0.001)
		sky.sky_material = pmat
	else:
		var mat := ProceduralSkyMaterial.new()
		mat.sky_top_color = e["top"]
		mat.sky_horizon_color = e["hor"]
		mat.ground_horizon_color = e["hor"]
		mat.ground_bottom_color = e["gnd"]
		mat.sun_angle_max = 20.0          # generous halo — reads like the game's glow
		mat.sun_curve = 0.12
		sky.sky_material = mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# INTERIOR FILL. With sky_contribution at 1.0 every scrap of ambient came
	# from how much SKY a surface can see, so anything enclosed got none —
	# and with sdfgi_use_occlusion and SSAO on top, interiors resolved to
	# black. That is defensible physically: the 11,640 authored lights that
	# actually light those rooms in-game are not instantiated here, so there
	# is nothing left to see by.
	#
	# Holding a fraction back from the sky gives a floor that occlusion cannot
	# take away. Tinted with the map's own horizon colour (the same mined value
	# that drives the sky gradient) rather than grey, so rooms lift toward the
	# light the exterior sits in instead of going flat and blue.
	#
	# This is a WORKING-COMFORT fudge, not a fidelity improvement: it adds light
	# the PhotoMatch reference photos do not have, and it softens outdoor contact
	# shadows by the same fraction. Turn it to 0.0 for a calibrated render.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = clampf(1.0 - interior_fill, 0.0, 1.0)
	if interior_fill > 0.0:
		env.ambient_light_color = e["hor"]
	env.ambient_light_energy = 1.0 if sun.visible else 1.6   # indoor maps live off ambient
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	# PhotoMatch-calibrated exposure. The sky-gradient extraction loses the
	# game's absolute HDR scale (BC6H values normalised; the game auto-exposes,
	# the editor doesn't), so maps with near-white gradients render 2-3x hot.
	# "exp" per map = tonemap exposure calibrated against paired in-game
	# reference photos (median-luminance match, _DevTools/photomatch) — game
	# data, not taste. Maps without a calibrated value keep 1.0.
	env.tonemap_exposure = float(e.get("exp", 1.0))
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = 1.1
	# GI: the game's VE runs full GI + GTAO (both components present in the
	# preset dumps). Editor equivalents that work on the runtime-injected
	# overlay (no baking, no saved scenes): SDFGI for bounce light + sky
	# occlusion, SSAO for the contact darkening GTAO gives in-game. Both are
	# part of the same PhotoMatch exposure calibration.
	env.sdfgi_enabled = gi
	env.sdfgi_use_occlusion = true
	env.sdfgi_min_cell_size = 0.4      # coarser voxels: ~same diffuse bounce,
	                                   # roughly half the SDFGI cost + more reach
	env.ssao_enabled = gi
	if gi:
		# half-resolution GI buffers — near-identical look for diffuse GI,
		# large GPU savings. Runtime call: doesn't touch project settings.
		RenderingServer.gi_set_use_half_resolution(true)

	# ---- everything the map's VisualEnvironment authored --------------------
	# Systems the editor did not reproduce at all until now. Every value here is
	# a field the level states; none of it is tuned by eye.
	if not m.is_empty():
		_apply_mined(env, sun, m)

	# the exposure a zone blends AWAY from, and the zones themselves
	_base_exposure = env.tonemap_exposure
	load_zones(map)
	# depth fog: per-map "fog" density when photo/VE-verified (0.0 = the map has
	# none — e.g. Aftermath, confirmed against all 21 PhotoMatch references).
	# Maps without a mined value keep the old horizon-haze heuristic until they
	# get their own PhotoMatch pass.
	var fog_density: float = float(e["fog"]) if e.has("fog") \
		else (0.0009 if float(e["el"]) < 16.0 else 0.0003)
	env.fog_enabled = fog_density > 0.0
	if env.fog_enabled:
		env.fog_light_color = e["hor"]
		env.fog_density = fog_density
		env.fog_sky_affect = 0.12
		env.fog_aerial_perspective = 0.5
	var wenv := WorldEnvironment.new()
	wenv.name = "GameEnvironment"
	wenv.environment = env
	rig.add_child(wenv)

	root.add_child(rig)
	rig.owner = null           # editor-only: never saved, never exported
	for c in rig.get_children():
		c.owner = null
	# sync the overlay's shadow casting with the checkbox — flips the built
	# meshes live, no rebuild (grass scatter stays shadow-off: GPU cost)
	cast_shadows = shadows
	var ctx := root.get_node_or_null("_MAP_CONTEXT")
	if ctx != null:
		_set_shadows(ctx, shadows)
	return "%s game lighting: sun az %.0f° el %.0f°, %s lux" % [
		map, float(e["az"]), float(e["el"]), String.num_uint64(int(e["lux"]))]

# live sub-toggles (dock checkboxes under "Game lighting") — operate on the
# existing rig/overlay, nothing rebuilds
# Apply the authored VE systems onto a Godot Environment + sun.
#
# Kelvin -> linear RGB, a Tanner Helland style black-body approximation. BF6
# authors a white balance (5600 K on mp_dumbo) and Godot has no white-balance
# stage, so it becomes a multiplier on the sun and ambient rather than being
# dropped. 6500 K is the neutral point: it returns white and changes nothing.
static func _kelvin(k: float) -> Color:
	var t: float = clampf(k, 1000.0, 40000.0) / 100.0
	var r := 255.0
	var g := 255.0
	var b := 255.0
	if t <= 66.0:
		g = 99.4708025861 * log(t) - 161.1195681661
		b = 0.0 if t <= 19.0 else 138.5177312231 * log(t - 10.0) - 305.0447927307
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	return Color(clampf(r, 0.0, 255.0) / 255.0,
		clampf(g, 0.0, 255.0) / 255.0,
		clampf(b, 0.0, 255.0) / 255.0)


static func _apply_mined(env: Environment, sun: DirectionalLight3D, m: Dictionary) -> void:
	# --- sky orientation -----------------------------------------------------
	# PanoramicRotation is a fraction of a turn (0.869 on dumbo, 0.159 on
	# aftermath), so the painted sun lines up with the one casting shadows.
	if m.has("sky_rotation"):
		env.sky_rotation = Vector3(0.0, float(m["sky_rotation"]) * TAU, 0.0)

	# --- sun disc ------------------------------------------------------------
	# DrawSunDisc is true on every map read, so the engine paints a disc over the
	# panorama rather than relying on one baked into it. SunSize units are NOT
	# established (0.005 / 0.002), so it is not converted to degrees — the
	# existing angular distance stands and only the on/off is honoured.
	if m.has("sun_disc") and not bool(m["sun_disc"]):
		sun.light_angular_distance = 0.0

	# --- sun shadow distance -------------------------------------------------
	# The level states this. We used to guess it (30 m, arrived at by eye);
	# mp_dumbo authors 45.
	var ssd: Variant = m.get("sun_shadow_distance")
	if ssd is Array and (ssd as Array).size() > 0:
		var d := float((ssd as Array)[0])
		if d > 1.0:
			sun.directional_shadow_max_distance = clampf(d * 8.0, 60.0, 2000.0)

	# --- fog -----------------------------------------------------------------
	# The most map-distinguishing system in the whole VE: FogColor alone takes 14
	# distinct values across 22 maps, and HeightFogEnable is genuinely false on
	# some. Colour is HDR radiance, so hue and magnitude are separated.
	if m.has("fog_enabled") and bool(m["fog_enabled"]):
		env.fog_enabled = true
		var fc := _col_hdr(m.get("fog_color"), Color(0.5, 0.6, 0.7))
		env.fog_light_color = fc[0]
		env.fog_light_energy = 1.0
		if m.has("sun_scatter"):
			env.fog_sun_scatter = clampf(float(m["sun_scatter"]), 0.0, 1.0)
		if m.has("aerial_perspective"):
			env.fog_aerial_perspective = clampf(float(m["aerial_perspective"]) / 50.0, 0.0, 1.0)
		env.fog_mode = Environment.FOG_MODE_DEPTH
		var fs := float(m.get("fog_dist_start", 0.0))
		var fe := float(m.get("fog_dist_end", 0.0))
		if fe > fs and fe > 1.0:
			env.fog_depth_begin = fs
			env.fog_depth_end = fe
		# height falloff: Altitude is where the layer sits, Depth how thick
		if m.has("fog_altitude"):
			env.fog_height = float(m["fog_altitude"])
		var fd := float(m.get("fog_depth", 0.0))
		if fd > 0.0:
			env.fog_height_density = clampf(1.0 / fd, 0.0, 1.0)
		if m.has("volumetrics") and bool(m["volumetrics"]):
			env.volumetric_fog_enabled = true
			env.volumetric_fog_density = 0.01
	else:
		env.fog_enabled = false

	# --- colour grading ------------------------------------------------------
	# Subtle and whole-frame: dumbo runs saturation 0.966, contrast 1.093,
	# brightness 1.023. An editor applying none of it cannot match the game
	# however right the lighting is.
	if m.has("grading_enabled") and bool(m["grading_enabled"]):
		env.adjustment_enabled = true
		var br := _col(m.get("grade_brightness"), Color(1, 1, 1))
		var ct := _col(m.get("grade_contrast"), Color(1, 1, 1))
		var st := _col(m.get("grade_saturation"), Color(1, 1, 1))
		env.adjustment_brightness = clampf(br.r, 0.1, 4.0)
		env.adjustment_contrast = clampf(ct.r, 0.1, 4.0)
		env.adjustment_saturation = clampf(st.r, 0.0, 4.0)

	# --- white balance -------------------------------------------------------
	if m.has("white_temperature"):
		var k := float(m["white_temperature"])
		if k > 1000.0 and absf(k - 6500.0) > 50.0:
			var w := _kelvin(k)
			sun.light_color = Color(sun.light_color.r * w.r,
				sun.light_color.g * w.g, sun.light_color.b * w.b)

	# --- ambient occlusion ---------------------------------------------------
	# AffectOutdoorLight is FALSE in BF6: ambient occlusion does not darken
	# sun-lit surfaces. Godot's ssao_light_affect is exactly that control and
	# defaults to affecting direct light, so leaving it alone systematically
	# over-darkens every exterior.
	if m.has("ao_affects_sun"):
		env.ssao_light_affect = 1.0 if bool(m["ao_affects_sun"]) else 0.0
	if m.has("hbao_radius"):
		env.ssao_radius = clampf(float(m["hbao_radius"]) * 2.0, 0.2, 8.0)
	if m.has("hbao_contrast"):
		env.ssao_intensity = clampf(float(m["hbao_contrast"]), 0.1, 8.0)

	# --- bloom ---------------------------------------------------------------
	var bs: Variant = m.get("bloom_scale")
	if bs is Array and (bs as Array).size() > 0:
		env.glow_intensity = clampf(float((bs as Array)[0]) * 8.0, 0.05, 2.0)

	# --- GI ambient ----------------------------------------------------------
	# SkyBoxSkyColor / SkyBoxGroundColor are the authored ambient hemisphere.
	if m.has("gi_sky_color"):
		var gc := _col(m["gi_sky_color"], Color(0.2, 0.2, 0.2))
		if gc.r + gc.g + gc.b > 0.01 and interior_fill > 0.0:
			env.ambient_light_color = gc


static func set_gi(root: Node, on: bool) -> String:
	var rig := root.get_node_or_null(NODE) if root != null else null
	var we := (rig.get_node_or_null("GameEnvironment") as WorldEnvironment) if rig != null else null
	if we == null or we.environment == null:
		return "Game lighting is off"
	we.environment.sdfgi_enabled = on
	we.environment.ssao_enabled = on
	return "Global illumination " + ("on" if on else "off")

# Interior fill, live. Holding a fraction of ambient back from sky visibility
# keeps enclosed spaces from going black — see interior_fill and the block in
# apply(). No rebuild needed: the ambient split is a plain Environment property.
static func set_interior_fill(root: Node, amount: float) -> String:
	interior_fill = clampf(amount, 0.0, 1.0)
	var rig := root.get_node_or_null(NODE) if root != null else null
	var we := (rig.get_node_or_null("GameEnvironment") as WorldEnvironment) if rig != null else null
	if we == null or we.environment == null:
		return "Game lighting is off"
	we.environment.ambient_light_sky_contribution = 1.0 - interior_fill
	return "Interior light %d%%" % int(round(interior_fill * 100.0))


static func set_shadows(root: Node, on: bool) -> String:
	cast_shadows = on
	var rig := root.get_node_or_null(NODE) if root != null else null
	if rig == null:
		return "Game lighting is off"
	var sun := rig.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = on
	var ctx := root.get_node_or_null("_MAP_CONTEXT")
	if ctx != null:
		_set_shadows(ctx, on)
	# ...and the high-poly overlays on the user's own placed objects, which live
	# scattered through the scene rather than under one root. They were missed
	# entirely, so turning shadows off left every overlay still casting.
	#
	# ONLY the overlay subtrees. Sweeping the whole scene would rewrite
	# cast_shadow on the user's OWN meshes, and that property is serialized into
	# their .tscn: a debug toggle would quietly edit their map.
	_set_shadows_in_overlays(root, on)
	return "Shadows " + ("on" if on else "off")

# "_HIPOLY_PREVIEW" spelled out rather than taken from HighpolyLib.HP_NODE:
# HighpolyLib references this class for cast_shadows, and pointing back at it
# from here would make the two class_names mutually dependent.
static func _set_shadows_in_overlays(n: Node, on: bool) -> void:
	if String(n.name) == "_HIPOLY_PREVIEW":
		_set_shadows(n, on)
		return                          # everything below belongs to this overlay
	for c in n.get_children():
		_set_shadows_in_overlays(c, on)

static func _set_shadows(n: Node, on: bool) -> void:
	if n.name == "_SCATTER":
		return                 # grass never casts (cost >> visual gain)
	if n is MultiMeshInstance3D or n is MeshInstance3D:
		# Turning shadows ON must not re-enable them on the small props the
		# builder deliberately left off. Without this the toggle would undo the
		# size rule and put ~87,000 draw calls straight back.
		#
		# The builder stamps each group with its extent as "lod_sz"; a node
		# without it is not ours to second-guess, so it follows the plain toggle.
		var allow := on
		# "no_shadow" is an absolute opt-out set by the builder (skyline,
		# terrain, roads) and it must win over everything below it. The size
		# rule alone could not express it: a backdrop cluster is 500+ m across,
		# so it clears any extent threshold and this walk switched 6,627 skyline
		# surfaces back on — 26,508 draw calls — every time Shadows was toggled.
		if n.has_meta("no_shadow"):
			allow = false
		elif on and n.has_meta("lod_sz"):
			allow = float(n.get_meta("lod_sz")) >= HighpolyMapContext.SHADOW_MIN_EXTENT
		(n as GeometryInstance3D).cast_shadow = \
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if allow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_set_shadows(c, on)

static func clear(root: Node) -> void:
	if root == null:
		return
	for c in root.get_children():
		if String(c.name).contains(NODE):   # orphan-proof (see HighpolyFx.clear)
			root.remove_child(c)
			c.queue_free()
	clear_map_lights(root)     # the map-lights sub-option rides Game Lighting

# ---------- local lighting zones: interiors, alleys, dark spots -------------
#
# HOW THE GAME DOES IT. A level's local presets are not alternative environments
# — they are thin overrides carrying only the components they change, and on
# every map read that is the EXPOSURE component alone. The game blends one in by
# proximity: a proximity node drives a gate, the gate writes the VE reference
# object's `Visibility`, which is a 0..1 blend weight (traced edge by edge in
# bf6-research formats/VISUAL_ENVIRONMENT.md §1b).
#
# So an interior in BF6 is the camera's exposure changing, NOT the ambient being
# lifted. The "Interior light" slider raises ambient, which is a different thing
# that happens to look similar — it is kept as a comfort control, but this is the
# game's own behaviour and it runs off the map's own numbers.
#
# A preset carries no volume, so the zone comes from where it was placed: the
# world bounds of the prefab that imports it (interior_zones_mine.py). Only zones
# with a real extent ship; presets whose placement could not be recovered are
# absent rather than guessed at.
static var zones_enabled := true
static var _zones: Array = []              # for the open map
static var _zone_map := ""
static var _zone_blend := 0.0              # current blend weight, eased per tick
static var _base_exposure := 1.0

# The base preset's EV, which a zone's own EV is measured against. 0 when the
# open map has no mined lighting, which disables zone blending rather than
# comparing against a made-up number.
static func base_ev() -> float:
	var m := mined(_zone_map)
	if m.has("ev_max") and float(m["ev_max"]) > 0.0:
		return float(m["ev_max"])
	return float(m.get("ev", 0.0))


static func load_zones(map: String) -> int:
	_zones = []
	_zone_map = map
	_zone_blend = 0.0
	for z in zones(map):
		if not (z is Dictionary):
			continue
		var zz: Variant = (z as Dictionary).get("zone")
		var ov: Variant = (z as Dictionary).get("overrides")
		if not (zz is Dictionary) or not (ov is Dictionary):
			continue
		var mn: Variant = (zz as Dictionary).get("min")
		var mx: Variant = (zz as Dictionary).get("max")
		if not (mn is Array) or not (mx is Array):
			continue
		_zones.append({
			"aabb": AABB(Vector3(mn[0], mn[1], mn[2]),
				Vector3(mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2])),
			"ev": float((ov as Dictionary).get("ev", 0.0)),
			"ev_max": float((ov as Dictionary).get("ev_max", 0.0)),
			"name": str((z as Dictionary).get("preset", "")),
		})
	return _zones.size()

# Exposure difference a zone asks for, as a multiplier. EV is a log2 stop scale,
# so one stop darker is half the light: 2^(base - zone).
static func _zone_exposure(z: Dictionary, base_ev: float) -> float:
	var ev := float(z.get("ev_max", 0.0))
	if ev <= 0.0:
		ev = float(z.get("ev", 0.0))
	if ev <= 0.0 or base_ev <= 0.0:
		return 1.0
	return clampf(pow(2.0, base_ev - ev), 0.25, 4.0)

# Camera-driven blend, called from the dock tick. Returns the zone entered, or "".
static func tick_zones(root: Node, cam_pos: Vector3, base_ev: float) -> String:
	if root == null or _zones.is_empty() or not zones_enabled:
		return ""
	var env := _env_of(root)
	if env == null:
		return ""
	var want := 1.0
	var inside := ""
	for z in _zones:
		var box: AABB = z["aabb"]
		# grow slightly so the transition starts at the threshold rather than
		# snapping exactly on the wall
		if box.grow(2.0).has_point(cam_pos):
			want = _zone_exposure(z, base_ev)
			inside = str(z["name"])
			break
	# ease rather than snap: the game runs adaptation times of about a second
	# (DarkAdaptationTime 1.1, LightAdaptationTime 0.8), and an instant jump as
	# you cross a doorway reads as a bug.
	_zone_blend = lerpf(_zone_blend, want, 0.15)
	env.tonemap_exposure = _base_exposure * _zone_blend if _zone_blend > 0.01 else _base_exposure
	return inside

static func _env_of(root: Node) -> Environment:
	for c in root.get_children():
		if String(c.name).contains(NODE):
			for g in (c as Node).get_children():
				if g is WorldEnvironment:
					return (g as WorldEnvironment).environment
	return null

# ---------- map lights (mined placements: user://mapcontext/<map>/lights.json) ----------
# 3,716 real light entities on Aftermath (PbrSpot/Sphere/Rect/Tube, positions +
# colour + intensity + radius + cones decoded from the level EBX). Too many to
# run at once — the dock timer culls to the nearest `lights_range` metres.
const LIGHTS_NODE := "_MAP_LIGHTS"
static var lights_range := 150.0

static func clear_map_lights(root: Node) -> void:
	if root == null: return
	for c in root.get_children():
		if String(c.name).contains(LIGHTS_NODE):   # orphan-proof
			root.remove_child(c)
			c.queue_free()

static func set_map_lights(root: Node, on: bool, map: String) -> String:
	clear_map_lights(root)
	if root == null: return "No scene open"
	if not on: return "Map lights off"
	var p := "user://mapcontext/%s/lights.json" % map
	if not FileAccess.file_exists(p):
		return "No light data for %s" % map
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return "lights.json unreadable"
	var holder := Node3D.new()
	holder.name = LIGHTS_NODE
	root.add_child(holder)
	holder.owner = null
	var n := 0
	for L in d.get("lights", []):
		if not (L is Dictionary): continue
		if str(L.get("layer", "base")) != "base":
			continue                    # winter/gauntlet-only lights stay off
		var pos: Array = L.get("pos", [0, 0, 0])
		var lt: Light3D
		if bool(L.get("spot", false)):
			var sp := SpotLight3D.new()
			sp.spot_range = maxf(float(L.get("radius", 10.0)), 1.0)
			# mined OuterAngle = FULL cone in degrees; Godot spot_angle = half
			sp.spot_angle = clampf(float(L.get("angle", 60.0)) * 0.5, 1.0, 89.0)
			lt = sp
		else:
			var om := OmniLight3D.new()
			om.omni_range = maxf(float(L.get("radius", 8.0)), 1.0)
			lt = om
		var c: Array = L.get("color", [1, 1, 1])
		var cmax: float = maxf(maxf(float(c[0]), float(c[1])), maxf(float(c[2]), 1.0))
		lt.light_color = Color(float(c[0]) / cmax, float(c[1]) / cmax, float(c[2]) / cmax)
		# raw Frostbite photometric intensity -> relative energy (empirical
		# divisors from the mining report; PhotoMatch refines later). Cap at
		# 2.2: a handful of outlier fixtures carry huge raw values the game's
		# auto-exposure absorbs — uncapped they out-shone the sun.
		var unit := int(L.get("unit", 0))
		lt.light_energy = clampf(float(L.get("intensity", 1000.0))
				/ (20000.0 if unit == 0 else 4000.0) * cmax, 0.02, 2.2)
		lt.shadow_enabled = false
		# GPU-side fade: shaded pixels skip faded lights entirely and the
		# 150 m culling boundary stops popping
		lt.distance_fade_enabled = true
		lt.distance_fade_begin = 90.0
		lt.distance_fade_length = 40.0
		lt.position = Vector3(pos[0], pos[1], pos[2])
		if lt is SpotLight3D and L.get("dir") is Array:
			var dva: Array = L["dir"]
			var dv := Vector3(dva[0], dva[1], dva[2])
			if dv.length() > 0.01:
				var up := Vector3.UP
				if absf(dv.normalized().dot(up)) > 0.99:
					up = Vector3.FORWARD
				lt.basis = Basis.looking_at(dv.normalized(), up)
		lt.visible = false              # tick_lights enables the near ones
		holder.add_child(lt)
		lt.owner = null
		n += 1
	invalidate_light_cull()      # everything starts hidden: the next tick must run
	return "Map lights: %d loaded (nearest %d m lit)" % [n, int(lights_range)]

# dock-timer culling: only lights near the editor camera render.
#
# This runs on the panel's half-second timer and is O(EVERY light in the map) —
# 11,640 of them on Dumbo. It used to run on every tick regardless of whether
# anything had changed, so standing perfectly still cost ~11,640 distance tests
# twice a second, forever, to arrive at the same answer each time. That is the
# shape of a periodic hitch reported while stationary.
#
# The lights already carry GPU distance fade (see set_map_lights); this pass is
# the coarser one that keeps them out of the clustered-element budget entirely,
# so it is worth keeping — it just is not worth REPEATING for a camera that has
# not moved.
static var _last_cull_pos := Vector3(1e20, 1e20, 1e20)   # forces the first pass
static var _cull_dirty := true

# call when the light set or the range changes: the next tick must run even if
# the camera is exactly where it was
static func invalidate_light_cull() -> void:
	_cull_dirty = true

static func tick_lights(root: Node, cam_pos: Vector3) -> void:
	if root == null: return
	var holder := root.get_node_or_null(LIGHTS_NODE)
	if holder == null: return
	# 1 m of slack: below that, no light can cross the boundary in a way anyone
	# could see, and the editor camera jitters slightly even when "still"
	if not _cull_dirty and cam_pos.distance_squared_to(_last_cull_pos) < 1.0:
		return
	_last_cull_pos = cam_pos
	_cull_dirty = false
	var r2 := lights_range * lights_range
	for c in holder.get_children():
		if c is Light3D:
			var l := c as Light3D
			l.visible = l.position.distance_squared_to(cam_pos) <= r2
