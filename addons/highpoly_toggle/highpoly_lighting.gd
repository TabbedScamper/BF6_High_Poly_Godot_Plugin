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
	"MP_Aftermath": {"az": 237.90, "el": 12.90, "lux": 24000,
		"sun": Color(1, 0.5033, 0.2633), "top": Color(0.9995, 1, 0.9522), "hor": Color(1, 0.8774, 0.8688), "gnd": Color(0.7943, 0.797, 1)},
	"MP_Aftermath_Portal": {"az": 237.90, "el": 12.90, "lux": 24000,
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
	return TABLE.has(map)

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

# Build + inject the lighting rig. Idempotent (clears any previous rig first).
static func apply(root: Node, map: String) -> String:
	if root == null:
		return "No scene open"
	clear(root)
	if not TABLE.has(map):
		return "No lighting data for %s" % map
	var e: Dictionary = TABLE[map]

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
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.5      # soft-edged sun shadows (sun disc size)
	rig.add_child(sun)

	# --- sky + environment ---
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = e["top"]
	mat.sky_horizon_color = e["hor"]
	mat.ground_horizon_color = e["hor"]
	mat.ground_bottom_color = e["gnd"]
	mat.sun_angle_max = 20.0              # generous halo — reads like the game's glow
	mat.sun_curve = 0.12
	var sky := Sky.new()
	sky.sky_material = mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.0 if sun.visible else 1.6   # indoor maps live off ambient
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = 1.1
	# depth fog tinted with the map's horizon colour: this is what carries the
	# "golden haze" reading on sunset maps (the sky panorama itself is blue away
	# from the sun; the warmth in-game comes from scattering/fog)
	env.fog_enabled = true
	env.fog_light_color = e["hor"]
	env.fog_density = 0.0009 if float(e["el"]) < 16.0 else 0.0003
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
	return "%s game lighting: sun az %.0f° el %.0f°, %s lux" % [
		map, float(e["az"]), float(e["el"]), String.num_uint64(int(e["lux"]))]

static func clear(root: Node) -> void:
	if root == null:
		return
	var old := root.get_node_or_null(NODE)
	if old:
		root.remove_child(old)
		old.queue_free()
