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

# overlay meshes built while this is false stay shadow-off (the background
# builder consults it) — kept in sync by apply()/set_shadows()
static var cast_shadows := true

# Build + inject the lighting rig. Idempotent (clears any previous rig first).
# gi/shadows: the dock's sub-checkboxes (PhotoMatch renders keep full quality
# via the defaults).
static func apply(root: Node, map: String, gi := true, shadows := true) -> String:
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
	if e.has("pano"):
		var pp := "res://addons/highpoly_toggle/sky/" + str(e["pano"])
		if ResourceLoader.exists(pp):
			pano_tex = load(pp)
	if pano_tex != null:
		var pmat := PanoramaSkyMaterial.new()
		pmat.panorama = pano_tex
		pmat.filter = true
		# physical-HDR normalization (see the TABLE "pano_lum" note)
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
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
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
static func set_gi(root: Node, on: bool) -> String:
	var rig := root.get_node_or_null(NODE) if root != null else null
	var we := (rig.get_node_or_null("GameEnvironment") as WorldEnvironment) if rig != null else null
	if we == null or we.environment == null:
		return "Game lighting is off"
	we.environment.sdfgi_enabled = on
	we.environment.ssao_enabled = on
	return "Global illumination " + ("on" if on else "off")

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
	return "Shadows " + ("on" if on else "off")

static func _set_shadows(n: Node, on: bool) -> void:
	if n.name == "_SCATTER":
		return                 # grass never casts (cost >> visual gain)
	if n is MultiMeshInstance3D or n is MeshInstance3D:
		(n as GeometryInstance3D).cast_shadow = \
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
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
	return "Map lights: %d loaded (nearest %d m lit)" % [n, int(lights_range)]

# dock-timer culling: only lights near the editor camera render
static func tick_lights(root: Node, cam_pos: Vector3) -> void:
	if root == null: return
	var holder := root.get_node_or_null(LIGHTS_NODE)
	if holder == null: return
	var r2 := lights_range * lights_range
	for c in holder.get_children():
		if c is Light3D:
			var l := c as Light3D
			l.visible = l.position.distance_squared_to(cam_pos) <= r2
