@tool
extends Object
class_name HighpolyLighting
# Game lighting for the map-context overlay: mimics each BF6 map's real sun +
# sky + fog inside the editor, from data extracted out of the game's per-level
# VisualEnvironment EBX (ve_mp_<map>_base*: OutdoorLight component) and its
# sky-gradient texture (t_*_gradientsky_*, BC6H HDR â€” zenith/horizon/ground
# colours sampled offline).
#
# Injected as one owner=null "_GAME_LIGHTING" node under the level root:
#   DirectionalLight3D  â€” real sun azimuth/elevation/colour/relative intensity
#   WorldEnvironment    â€” gradient-derived sky (ambient from it), depth fog
#                         tinted with the map's horizon colour, ACES tonemap,
#                         soft glow
# Nothing is saved or exported; removing the node restores the editor's own
# preview sun/environment (Godot re-enables them when the scene stops carrying
# a DirectionalLight3D / WorldEnvironment).
#
const SUN_SKY := preload("res://addons/highpoly_toggle/sky_sun.gdshader")

# The level's own PanoramicRotation, in turns, set by apply() when the sky is read
# from the install and consumed by _apply_mined(), which is where the Environment
# is configured. Negative means the level did not give us one and the mined value
# stands. A member rather than a parameter because those two are far apart and
# every caller of _apply_mined would otherwise have to carry a value it has no
# opinion about.
static var _pano_rot := -1.0

# Sun-angle convention: SunRotationX is a COMPASS BEARING (0 = +Z, turning
# toward +X) and SunRotationY is elevation above the horizon. See sun_dir() for
# the derivation and the evidence.
#   RETRACTED: this block used to read "= (cos az, sin az)" and claim the
#   convention was photo-verified on MP_Badlands within ~3 degrees. It was not.
#   That reading is mirrored and 90 degrees out, and Badlands is precisely the
#   map where a hand check is least reliable â€” open terrain with a 10-degree
#   red sun, no vertical edges to read a shadow against. A claim of verification
#   is worth nothing without saying what it was checked AGAINST.
#   "lux" = the VE's SunIntensity (real illuminance) â€” mapped to a relative
#   DirectionalLight energy below (the editor has no physical light units).
#
# MP_Capstone is absent FROM TABLE ONLY â€” its toc was never EBX-extracted when
# that table was built. It has since been mined like every other map and its
# lighting arrives in the map package (54 fields, sun 157.03/31.0, with a sky),
# so the map is fully supported. It is the only map with no TABLE fallback,
# which is what made the mined-cache bug grey its Lighting chip out entirely
# while every other map merely degraded in silence â€” see mined().

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
	# (BC6H 8192x2048 equirect, GUID-verified) â€” "pano" swaps the gradient
	# ProceduralSky for that real panorama. "fog" 0.0 = photo-verified (the 21
	# PhotoMatch references show no atmospheric fog; the el<16 haze formula below
	# is a fallback heuristic, not Aftermath data).
	# "pano_lum" = the panorama's MEASURED mean luminance (BC6H decode, 65k
	# samples): the game's sky is authored in physical HDR units (~8,900 â€”
	# real overcast-sky cd/mÂ²) and auto-exposed in-game; the editor renders it
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
# 56, read straight out of the level's VisualEnvironment preset â€” sun, sky, fog,
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
static var _mined_stamp: Dictionary = {}    # map -> mtime the entry was read from

# CACHING THE MISS WAS THE BUG. The dock's half-second timer calls has_data() ->
# mined() as soon as a level scene opens, which is seconds BEFORE its map package
# finishes downloading. The empty answer was then cached, and since nothing in
# the plugin ever called forget(), it stuck for the whole session:
#   - MP_Capstone is the only map absent from TABLE, so has_data() went false and
#     the Lighting chip greyed out permanently, even once its data had arrived.
#   - Everywhere else the chip stayed enabled but apply() silently fell back to
#     TABLE's 7 values: no sky, no fog, no colour grading, no AO, none of it,
#     with nothing said about why.
#
# Re-reading every call is not the answer either â€” placements.json runs to tens
# of MB on a big map and this is called twice a second. So key the cache on the
# file's modification time: one stat instead of a parse, and it also picks up a
# REPUBLISHED package, which the old code could not do at all.
static func mined(map: String) -> Dictionary:
	if map == "":
		return {}
	var p := "%s/%s/placements.json" % [CACHE, map]
	var stamp: int = FileAccess.get_modified_time(p) if FileAccess.file_exists(p) else 0
	if _mined.has(map) and int(_mined_stamp.get(map, -1)) == stamp:
		return _mined[map]
	var out: Dictionary = {}
	if stamp != 0:
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if j is Dictionary:
			var lit: Variant = (j as Dictionary).get("lighting")
			if lit is Dictionary and (lit as Dictionary).get("fields") is Dictionary:
				out = (lit as Dictionary)["fields"]
	_mined[map] = out
	_mined_stamp[map] = stamp
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
		_mined_stamp.clear()
	else:
		_mined.erase(map)
		_mined_stamp.erase(map)

# A vec4/vec3 field arrives as an Array. Colour without the magnitude.
static func _col(v: Variant, fallback: Color) -> Color:
	if not (v is Array) or (v as Array).size() < 3:
		return fallback
	var a: Array = v
	return Color(float(a[0]), float(a[1]), float(a[2]))

# The same array, normalised, plus how bright it was. BF6 stores fog colour and
# similar as HDR radiance â€” `(1385, 2132, 3072)` is a sky blue at ~3072 â€” so hue
# and magnitude have to be separated rather than clamped.
static func _col_hdr(v: Variant, fallback: Color) -> Array:
	if not (v is Array) or (v as Array).size() < 3:
		return [fallback, 1.0]
	var a: Array = v
	var m: float = maxf(maxf(float(a[0]), float(a[1])), float(a[2]))
	if m <= 0.0001:
		return [fallback, 0.0]
	return [Color(float(a[0]) / m, float(a[1]) / m, float(a[2]) / m), m]

# World-space unit vector TOWARD the sun.
#
# az is BF6's SunRotationX, which is a COMPASS BEARING: 0 points along +Z and
# turns toward +X. This used to be read as a maths-convention angle (0 along +X,
# turning toward +Z), which is both mirrored AND 90 degrees out â€” the two errors
# together are why fitting either one alone never explained the result.
#
#     compass A -> (sin A, 0, cos A)        our old az -> (cos az, 0, sin az)
#     cos(az) = sin(A), sin(az) = cos(A)  =>  az = 90 - A
#
# Note what was NOT wrong: the arithmetic. Rebuilding the sun and reading the
# direction back off the finished DirectionalLight3D matched the authored angles
# to 0.000 on all 22 maps. The bug was the convention, which no amount of
# checking our own maths could ever have surfaced.
#
# EVIDENCE. Nothing shipped can settle a sun angle: the sky panoramas contain no
# sun disc (verified by rendering all 22 and crushing exposure until only real
# highlights survive â€” every one goes black; the engine draws the disc itself,
# DrawSunDisc = 1 everywhere), the maptiles are flat-lit with no cast shadows,
# and the SDK ships no DirectionalLight. So this was settled against the running
# game, by hand, through the dock's sun sliders:
#     MP_Dumbo      predicted 325.2   set 325.5   off by 0.3 deg
#     MP_Aftermath  predicted 212.1   set 211.0   off by 1.1 deg
#     MP_Capstone   predicted 293.0   set 284.5   off by 8.5 deg
#     MP_Badlands   predicted  96.0   set  71.5   off by 24.5 deg
# The constant is 90 exactly, DERIVED, with no free parameter â€” and Dumbo was
# calibrated twice, independently, moving 327.5 -> 325.5, i.e. converging on a
# number nobody fitted. The two tight maps are dense city grids where a shadow
# can be read against a street; the two loose ones are open terrain where it
# cannot, so they are treated as the weaker measurements rather than evidence
# against. If a later calibration on buildable ground disagrees, revisit this.
#
# Ruled out as the cause of the per-map spread: map origin (a directional light
# has no position), map-context rotation (none is applied), and a per-map level
# root yaw (the walker bakes world transforms, and an arbitrary per-map yaw
# could not put two maps within a degree of the SAME derived constant).
#
# NO MAP IS HAND-SET, AND NONE MAY BE. The calibration identified WHICH
# CONVENTION the data is written in; it did not supply a value. What ships is
# this one formula, applied identically everywhere, and every map's sun still
# comes from its own SunRotationX/Y in its own VisualEnvironment â€” including the
# maps nobody has ever looked at, and any map added later. The dock's sun
# sliders are a diagnostic that writes to a JSON for analysis; they feed nothing
# into apply(), and a per-map fudge table must never be added here.
static func sun_dir(az_deg: float, el_deg: float) -> Vector3:
	var az := deg_to_rad(az_deg)
	var el := deg_to_rad(el_deg)
	return Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el)).normalized()

# SunIntensity (lux) -> relative DirectionalLight energy. Perceptual-ish curve
# anchored so full midday (~120k lux) reads as a strong editor sun and a low
# golden-hour sun (~45k) stays clearly dimmer/warmer. The game auto-exposes;
# the editor doesn't, so absolute lux can't be used directly.
static func sun_energy(lux: float) -> float:
	if lux < 10.0:
		return 0.0        # indoor maps (Subsurface): no meaningful sun
	return clampf(1.7 * pow(lux / 120000.0, 0.45), 0.15, 2.2)

# overlay meshes built while this is false stay shadow-off (the background
# builder consults it) â€” kept in sync by apply()/set_shadows()
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
	# 1500 m: shadows previously cut off 600 m out â€” on city-scale maps whole
	# blocks past the street you were on rendered shadowless ("shadows don't
	# show very well"). Note the Aftermath preset is a 24,000-lux overcast sun
	# vs a full-sky ambient: its shadows ARE soft/shallow in the game photos
	# too â€” depth here should match the references, not a clear-noon look.
	sun.directional_shadow_max_distance = 1500.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	# Kept ON. Blending the cascades fixes the seam between splits, and the
	# draw-call saving from turning it off was measured at nothing: the whole
	# shadow pass is 203 draw calls against 49,277 for the camera pass, so
	# shadows are simply not the cost on this map.
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.5      # soft-edged sun shadows (sun disc size)
	rig.add_child(sun)

	# --- sky + environment ---
	# Maps with a "pano" entry use the REAL sky: the VE preset's PanoramicTexture
	# (equirect BC6H HDR, extracted from the dump into addons/highpoly_toggle/sky/).
	# That texture IS what the game renders behind the level â€” clouds, glow and
	# horizon come from data, not from gradient-colour approximation.
	var sky := Sky.new()
	var pano_tex: Texture2D = null
	var pano_scale := 0.0
	# The map package's own sky, converted from the level's PanoramicTexture.
	# EXR because Godot cannot load .dds at runtime â€” that limitation is why the
	# one sky this plugin used to have was welded into its own zip, and why only
	# one map ever had a real sky.
	# THE LEVEL'S OWN SKY, out of the install. The VE preset names its panorama
	# in its import list; the reader decodes it and remaps 360x90 to the 2:1
	# equirect PanoramaSkyMaterial wants. Preferred over everything below,
	# which is a downloaded conversion and a .dds that used to ship inside this
	# addon - Battlefield art no plugin should be handing out.
	if game_source != null:
		var gsky: Dictionary = game_source.sky()
		if not gsky.is_empty():
			pano_tex = gsky["texture"]
			pano_scale = float(gsky["luminance_scale"])
			_pano_rot = float(gsky.get("rotation", 0.0))
	var sp := "%s/%s/sky.exr" % [CACHE, map]
	if pano_tex != null:
		sp = ""
	if sp != "" and FileAccess.file_exists(sp):
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
		# LuminanceScale â€” the two disagree for exactly this reason.
		var pp := "res://addons/highpoly_toggle/sky/" + str(e["pano"])
		if ResourceLoader.exists(pp):
			pano_tex = load(pp)
	if pano_tex != null:
		# THE PANORAMA WITH A SUN DRAWN ON TOP OF IT, rather than a
		# PanoramaSkyMaterial, which can only show the texture.
		#
		# BF6's panoramas contain no sun disc. Rendered all 22 and crushed
		# exposure until only real highlights survive: every one goes black. The
		# engine draws its own, DrawSunDisc = 1 on every map. So the sky we built
		# had no sun in it at all, and the brightest thing in the level was
		# missing while the light casting every shadow came from a direction with
		# nothing visible there.
		#
		# The shader samples the panorama with PanoramaSkyMaterial's exact
		# mapping, verified pixel-identical on all four compass directions, and
		# adds a disc placed from the DirectionalLight this rig has already aimed
		# out of the level's own SunRotationX/Y.
		var pmat := ShaderMaterial.new()
		pmat.shader = SUN_SKY
		pmat.set_shader_parameter("panorama", pano_tex)
		var emul := 1.0
		if pano_scale > 0.0:
			# Bring the authored magnitude onto the ~1.0 scale the rest of the
			# rig is calibrated against: texture x LuminanceScale is the real
			# luminance, and SKY_REF is what we call "1".
			const SKY_REF := 7000.0        # median of texture-mean x scale, fleet-wide
			emul = clampf(pano_scale / SKY_REF, 0.05, 20.0)
		else:
			emul = 1.0 / maxf(float(e.get("pano_lum", 1.0)), 0.001)
		pmat.set_shader_parameter("energy_multiplier", emul)
		sky.sky_material = pmat
	else:
		var mat := ProceduralSkyMaterial.new()
		mat.sky_top_color = e["top"]
		mat.sky_horizon_color = e["hor"]
		mat.ground_horizon_color = e["hor"]
		mat.ground_bottom_color = e["gnd"]
		mat.sun_angle_max = 20.0          # generous halo â€” reads like the game's glow
		mat.sun_curve = 0.12
		sky.sky_material = mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# INTERIOR FILL. With sky_contribution at 1.0 every scrap of ambient came
	# from how much SKY a surface can see, so anything enclosed got none â€”
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
	# reference photos (median-luminance match, _DevTools/photomatch) â€” game
	# data, not taste. Maps without a calibrated value keep 1.0.
	env.tonemap_exposure = float(e.get("exp", 1.0))
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = 1.1
	# SDFGI IS THE WRONG TECHNIQUE HERE, and the game's own data says so.
	#
	# "Soft shading" used to switch on SDFGI + SSAO together. SDFGI made the
	# scene look markedly worse than with the chip off, and the reason is not
	# tuning:
	#
	#   - BF6 does not use real-time GI. Its GI component is ENLIGHTEN, an
	#     offline radiosity bake, plus GTAO for contact darkening. SDFGI is a
	#     different technique solving a different problem.
	#   - Our scene is close to SDFGI's worst case: a runtime overlay of
	#     thousands of MultiMeshInstance3D nodes with owner=null, spread over an
	#     8 km map. SDFGI voxelises static geometry into cascades that reach a
	#     few hundred metres, so it re-voxelises constantly as the camera flies
	#     and darkens blotchily where the cascade is sparse.
	#   - sdfgi_use_occlusion then darkens from that same sparse voxel field,
	#     which is where the "decimated" look came from.
	#
	# What the game actually has is ambient from its skybox plus contact AO. We
	# already have the real panorama driving ambient (AMBIENT_SOURCE_SKY above),
	# so the honest editor equivalent is that plus SSAO â€” no voxelisation, no
	# cascades, nothing to flicker.
	env.sdfgi_enabled = false
	# GTAO's editor equivalent. Radius/intensity and, importantly, whether it
	# touches direct light come from the map's own AO component in _apply_mined.
	env.ssao_enabled = gi
	if gi:
		# half-resolution AO buffer â€” near-identical look, large GPU saving.
		# Runtime call: doesn't touch project settings.
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
	# none â€” e.g. Aftermath, confirmed against all 21 PhotoMatch references).
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
	# sync the overlay's shadow casting with the checkbox â€” flips the built
	# meshes live, no rebuild (grass scatter stays shadow-off: GPU cost)
	cast_shadows = shadows
	var ctx := root.get_node_or_null("_MAP_CONTEXT")
	if ctx != null:
		_set_shadows(ctx, shadows)
	return "%s game lighting: sun az %.0fÂ° el %.0fÂ°, %s lux" % [
		map, float(e["az"]), float(e["el"]), String.num_uint64(int(e["lux"]))]

# live sub-toggles (dock checkboxes under "Game lighting") â€” operate on the
# existing rig/overlay, nothing rebuilds
# Apply the authored VE systems onto a Godot Environment + sun.
#
# Kelvin -> linear RGB, a Tanner Helland style black-body approximation. BF6
# authors a white balance (5600 K on mp_dumbo) and Godot has no white-balance
# stage, so it becomes a multiplier on the sun and ambient rather than being
# dropped. 6500 K is the neutral point: it returns white and changes nothing.
# Kept deliberately, though nothing calls it right now: it is the conversion the
# white-balance field needs once the direction is settled (see the note in
# _apply_mined). Verified against known values â€” 6500 K returns ~neutral, 3200 K
# is red-biased, 9000 K blue-biased.
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


# D65. The neutral the authored temperatures are measured against: it is the
# standard render white point AND the most common value in the fleet, so maps
# that author it want no correction at all.
const WB_NEUTRAL := 6500.0

# Per-channel gain that makes light of `kelvin` render as white â€” the ratio, not
# the illuminant. Normalised to preserve luminance so this shifts hue only.
static func _wb_gain(kelvin: float) -> Color:
	var n := _kelvin(WB_NEUTRAL)
	var t := _kelvin(kelvin)
	var g := Color(n.r / maxf(t.r, 0.001), n.g / maxf(t.g, 0.001), n.b / maxf(t.b, 0.001))
	var l := g.r * 0.2126 + g.g * 0.7152 + g.b * 0.0722
	if l > 0.001:
		g = Color(g.r / l, g.g / l, g.b / l)
	return g


static func _apply_mined(env: Environment, sun: DirectionalLight3D, m: Dictionary) -> void:
	# --- sky orientation -----------------------------------------------------
	# PanoramicRotation is a fraction of a turn (0.869 on dumbo, 0.159 on
	# aftermath), so the painted sun lines up with the one casting shadows.
	# THE LEVEL'S OWN PanoramicRotation, when we read the sky from the install.
	#
	# We were reading this field and then never applying it, so every panorama sat
	# at whatever rotation it happens to be authored at. Measured on two maps, the
	# brightest texel of the panorama (which IS the sun: its elevation matches the
	# authored SunRotationY to 0.1 degrees on aftermath) sits at u = 0.49 on both,
	# i.e. the centre of the texture, which is what a sky authored sun-forward and
	# rotated at runtime looks like.
	#
	# Read as TURNS, matching how the mined value below has always been read,
	# PLUS HALF A TURN.
	#
	# Godot's sky_rotation and Frostbite's PanoramicRotation disagree about which
	# way the panorama's u = 0 column faces: the two zero conventions are 180
	# degrees apart. The constant is 0.5 exactly, derived from where the sun is
	# actually painted, with no free parameter and no per-map term.
	#
	# MEASURED. The panorama's brightest region IS the sun, and its bearing is
	# stable to 0.3 degrees across a 200x change in the brightness threshold used
	# to find it, so this is not a centroid artefact:
	#
	#   mp_aftermath  needs 0.6602 turns   authored 0.1590 + 0.5 = 0.6590   0.44 deg
	#   mp_dumbo      needs 0.3406 turns   authored 0.8690 + 0.5 = 0.3690   10.2 deg
	#
	# Aftermath lands within half a degree. Dumbo is 10 degrees out, and that is
	# the ART disagreeing with the DATA rather than the rule failing: dumbo's
	# painted sun also misses its own authored SunRotationY by 4.6 degrees
	# (33.1 painted against 28.5 authored), while aftermath's matches to 0.15.
	# One is a sunset with a hard disc the sky is composed around; the other is a
	# cloudy preset whose sun is a diffuse glow nobody placed to the degree.
	#
	# So this is fitted to the map that can be measured and applied unchanged
	# everywhere, which is the same discipline sun_dir() is held to. If a third
	# map with a hard-edged sun disagrees, it is this constant that is wrong.
	if _pano_rot >= 0.0:
		env.sky_rotation = Vector3(0.0, fmod(_pano_rot + 0.5, 1.0) * TAU, 0.0)
	elif m.has("sky_rotation"):
		env.sky_rotation = Vector3(0.0, float(m["sky_rotation"]) * TAU, 0.0)

	# --- sun disc ------------------------------------------------------------
	# DrawSunDisc is true on every map read, so the engine paints a disc over the
	# panorama rather than relying on one baked into it. SunSize units are NOT
	# established (0.005 / 0.002), so it is not converted to degrees â€” the
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
	# Applied as a von Kries gain, which is a CORRECTION, not a tint. This was
	# unapplied for a while because the first attempt multiplied the sun by the
	# black-body colour of the authored temperature and made mp_dumbo read as a
	# sunset â€” the authored SunColor is already warm at (1.0, 0.776, 0.617), and
	# the 5600 K multiplier pushed green/red from 0.776 to 0.728, further toward
	# orange. That was backwards: "white balance 5600 K" means TREAT 5600 K AS
	# WHITE, so it should cancel warmth of that temperature, not add it.
	#
	# What was missing was the neutral point, and the fleet supplies it: 6500 K
	# is the most common authored value and the standard D65 render white point.
	# Reading the field against 6500 makes the whole thing fall out â€” the gain is
	# kelvin(6500)/kelvin(T), every 6500 K map comes out an exact (1,1,1) no-op,
	# and mp_dumbo's 5600 K becomes (0.950, 1.009, 1.055), a mild COOLING that
	# moves the sun's green/red from 0.776 to 0.824. That is the correction the
	# game applies and we were dropping, and dropping it is why a bright day map
	# read as evening.
	#
	# It goes in adjustment_color_correction rather than onto the sun, because a
	# camera white balance acts on the whole frame â€” sky and ambient included.
	# A 1D gradient from black to the gain is exactly a per-channel linear gain.
	# Luminance-normalised so this only shifts hue: brightness is the exposure
	# field's job, and letting white balance move it would double-count.
	#
	# TINT IS DELIBERATELY NOT APPLIED. Temperature has a physical unit and an
	# established neutral; `Tint` is +-27 on a scale nothing in the data pins
	# down, and at a guessed scale it swings mp_firestorm's green by 26%. Applying
	# an unknown-unit field at an invented scale is the exact mistake that
	# produced the inverted white balance above.
	var wk := float(m.get("white_temperature", 0.0))
	if wk > 1000.0 and absf(wk - WB_NEUTRAL) > 25.0:
		var grad := Gradient.new()
		grad.set_color(0, Color.BLACK)
		grad.set_color(1, _wb_gain(wk))
		var lut := GradientTexture1D.new()
		lut.use_hdr = true         # cooling gains exceed 1.0 on the blue channel
		lut.gradient = grad
		env.adjustment_enabled = true
		env.adjustment_color_correction = lut

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

	# --- GI ------------------------------------------------------------------
	# NOT used as a runtime ambient colour, deliberately.
	#
	# SkyBoxSkyColor / SkyBoxGroundColor are inputs to ENLIGHTEN, the game's
	# offline radiosity bake â€” they describe the skybox the bake sees, not a
	# colour to tint the frame with. They are also not all in 0..1: across the
	# fleet they run from (0.05, 0.05, 0.06) on mp_badlands to (8192, 8192, 8192)
	# on mp_limestone, whose SkyBoxSunLightColor is 32768. Assigning that to
	# ambient_light_color would white out the scene.
	#
	# Runtime ambient stays sky-derived (AMBIENT_SOURCE_SKY above), which is both
	# physically right and what the real panorama is for.


static func set_gi(root: Node, on: bool) -> String:
	var rig := root.get_node_or_null(NODE) if root != null else null
	var we := (rig.get_node_or_null("GameEnvironment") as WorldEnvironment) if rig != null else null
	if we == null or we.environment == null:
		return "Game lighting is off"
	# SDFGI stays off whichever way this goes â€” see the block in apply(). The
	# chip now toggles the contact shading the game actually has (GTAO), not
	# Godot's real-time GI, which made the scene worse than leaving it off.
	we.environment.sdfgi_enabled = false
	we.environment.ssao_enabled = on
	return "Contact shading " + ("on" if on else "off")

# Interior fill, live. Holding a fraction of ambient back from sky visibility
# keeps enclosed spaces from going black â€” see interior_fill and the block in
# apply(). No rebuild needed: the ambient split is a plain Environment property.
static func set_interior_fill(root: Node, amount: float) -> String:
	interior_fill = clampf(amount, 0.0, 1.0)
	var rig := root.get_node_or_null(NODE) if root != null else null
	var we := (rig.get_node_or_null("GameEnvironment") as WorldEnvironment) if rig != null else null
	if we == null or we.environment == null:
		return "Game lighting is off"
	we.environment.ambient_light_sky_contribution = 1.0 - interior_fill
	return "Interior light %d%%" % int(round(interior_fill * 100.0))


# (The sun-calibration scaffolding lived here â€” a live re-aim plus a writer for
# user://mapcontext/_sun_calibration.json â€” while the azimuth convention was
# being established against the running game. It is gone: SunRotationX is a
# compass bearing, sun_dir() says so with the derivation, and
# tools/test_sun_convention.gd locks it in. Nothing about the sun is adjustable
# any more, which is the point.)


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
		# surfaces back on â€” 26,508 draw calls â€” every time Shadows was toggled.
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
# â€” they are thin overrides carrying only the components they change, and on
# every map read that is the EXPOSURE component alone. The game blends one in by
# proximity: a proximity node drives a gate, the gate writes the VE reference
# object's `Visibility`, which is a 0..1 blend weight (traced edge by edge in
# bf6-research formats/VISUAL_ENVIRONMENT.md Â§1b).
#
# So an interior in BF6 is the camera's exposure changing, NOT the ambient being
# lifted. The "Interior light" slider raises ambient, which is a different thing
# that happens to look similar â€” it is kept as a comfort control, but this is the
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
# run at once â€” the dock timer culls to the nearest `lights_range` metres.
# The open HighpolyGameSource, or null. Set by the plugin; untyped so this
# module does not depend on the reader stack.
static var game_source = null

const LIGHTS_NODE := "_MAP_LIGHTS"

# How long to work before handing a frame back. Was 30 ms, which sounded polite
# and was anything but: a recording showed 753 slices doing 23.0 s of actual
# work and spending 44.9 s WAITING for the frames in between, because by the
# time the lights go in the whole map is drawn and a frame costs ~60 ms. Nearly
# two thirds of that stage was the yielding itself.
#
# 120 ms cuts the slice count fourfold and the waiting with it, and 120 ms is
# still well inside what reads as a responsive editor â€” the props build has used
# a 40 ms budget against far heavier per-slice work all along.
#
# A static var rather than a const so a test can force the yielding path with a
# tiny slice. Raising it to 120 made test_progress_lanes fail honestly: its
# workload now finished inside ONE slice, so no intermediate progress was
# reported and the assertion that the bar moves while running caught it.
static var LIGHT_SLICE_MS := 120
static var lights_range := 150.0

static func clear_map_lights(root: Node) -> void:
	if root == null: return
	for c in root.get_children():
		if String(c.name).contains(LIGHTS_NODE):   # orphan-proof
			root.remove_child(c)
			c.queue_free()

# ONE LIGHT FROM ONE MINED RECORD, and the only place a Light3D is built.
#
# Extracted so the level's own lights and the lights inside a prop the user
# placed cannot drift apart. They are the same fixtures out of the same install,
# read by the same walk; the only difference is whether the walk reached them
# through the level graph or through a pf_portal_ prefab. Two constructions would
# have meant two answers about energy, cone angle and aim, and the aim in
# particular took a lot of measuring to get right (see the minus-forward note in
# highpoly_gamesource._light_record).
static func make_light(L: Dictionary) -> Light3D:
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
	# raw Frostbite photometric intensity -> relative energy (empirical divisors
	# from the mining report; PhotoMatch refines later). Cap at 2.2: a handful of
	# outlier fixtures carry huge raw values the game's auto-exposure absorbs, and
	# uncapped they out-shone the sun.
	var unit := int(L.get("unit", 0))
	lt.light_energy = clampf(float(L.get("intensity", 1000.0))
			/ (20000.0 if unit == 0 else 4000.0) * cmax, 0.02, 2.2)
	lt.shadow_enabled = false
	# GPU-side fade: shaded pixels skip faded lights entirely and the culling
	# boundary stops popping
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
	return lt


# THE LIGHTS A PLACED PROP CARRIES, hung under its overlay.
#
# A lamp dropped into a scene used to arrive with its geometry and none of its
# lighting. Not misplaced: absent. object_node only ever built MeshInstance3D,
# and the prefab walk asked for no entity types at all, so the fixtures inside
# the prefab were never collected.
#
# CAPPED, and the cap is the reason this is a separate call rather than something
# object_node does by itself. Forward+ clusters lights and stops at 512 in view;
# a builder who lines a street with lamps would pass that without doing anything
# unreasonable, and past it lights start dropping out with no explanation. The
# cap makes the failure a number in the log instead.
#
# Shadows stay off and the distance fade is the same one the map lights use, so a
# placed lamp costs what a level lamp costs.
const PROP_LIGHT_CAP := 8

# PROP LIGHTING, one switch.
#
# A placed lamp brings its own fixtures in from the game, and it also has an
# emissive sheet for the bulb. With the switch off both are inert and the prop
# reads as a lamp that is not turned on, which is the honest default for a
# builder laying out geometry. With it on the fixtures light and the bulb glows.
#
# The lights are the GAME's - nothing is invented here - and the emission side
# lives in highpoly_gamesource, which builds the materials.
static var prop_lighting := true
const PROP_LIGHT_NAME := "_HP_LIGHT_"


# Switch every placed prop's fixtures on or off, without rebuilding anything.
# Returns how many it touched, so the panel can say something true.
static func set_prop_lights_shown(root: Node, on: bool) -> int:
	if root == null:
		return 0
	var n := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Light3D and str(node.name).begins_with(PROP_LIGHT_NAME):
			(node as Light3D).visible = on
			n += 1
			continue
		for c in node.get_children():
			# the map-context subtree is the level's own lighting and has its
			# own switch; walking it here would be six figures of nodes as well
			if c.name != "_MAP_CONTEXT":
				stack.append(c)
	return n


static func attach_prop_lights(overlay: Node3D, recs: Array) -> int:
	if overlay == null or recs.is_empty():
		return 0
	var n := 0
	for r in recs:
		if n >= PROP_LIGHT_CAP:
			break
		if not (r is Dictionary):
			continue
		var lt := make_light(r as Dictionary)
		lt.name = PROP_LIGHT_NAME + str(n)
		lt.visible = prop_lighting
		overlay.add_child(lt)
		lt.owner = null                 # editor-only, never saved into the scene
		n += 1
	return n


# `progress` is called as progress.call(done, total) on each yield, so the panel
# can show a bar. Thousands of fixtures take real seconds to place and the only
# feedback used to be a status line that changed once at the end.
static func set_map_lights(root: Node, on: bool, map: String,
		progress := Callable()) -> String:
	clear_map_lights(root)
	if root == null: return "No scene open"
	if not on: return "Map lights off"
	var p := "user://mapcontext/%s/lights.json" % map
	if not FileAccess.file_exists(p):
		return "No light data for %s" % map
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return "lights.json unreadable"
	# BUILT OFF-TREE AND ATTACHED ONCE, which is where the time was going.
	#
	# The holder used to be added to the scene BEFORE the loop, so all 11,641
	# fixtures were added into the LIVE edited tree one at a time. Every one of
	# those pays the editor's per-node cost - notifications, and a 3D gizmo built
	# for each Node3D in the edited scene - and the user's own profile put it at
	# 23.4 s of "build fixtures" over 194 slices, about 2 ms per light. Two
	# milliseconds is far too long to construct a node and about right for adding
	# one to an open scene.
	#
	# Detached, add_child is a parent pointer and nothing else. The tree only
	# learns about any of it at the attach below.
	#
	# The waiting half was already dealt with: LIGHT_SLICE_MS went 30 -> 120 and
	# took "waiting for a frame" from 44.9 s to 12.0 s in the same profiles. This
	# is the other half.
	var holder := Node3D.new()
	holder.name = LIGHTS_NODE
	# YIELDS. A map carries thousands of fixtures â€” Dumbo added 11,641 nodes in
	# one go â€” and building them between two frames was the last freeze in a
	# recorded cold load: 23.1 seconds with nothing drawn and no input taken.
	# Nothing here is atomic, so hand the editor a frame every ~30 ms.
	var n := 0
	var slice := Time.get_ticks_msec()
	var all: Array = d.get("lights", [])
	var seen := 0
	# TIMED, because a recording showed this holding its progress bar for 65.5 s
	# with not one second of it attributed to anything. It had no spans at all â€”
	# the phase table simply had a 65 s hole where the map lights were.
	HighpolyProfiler.crumb("lights", "placing %d fixture(s) for %s" % [all.size(), map])
	var _tl := Time.get_ticks_msec()
	var _tw := 0
	for L in all:
		seen += 1
		if Time.get_ticks_msec() - slice >= LIGHT_SLICE_MS:
			# split the WORK from the waiting: a slice that costs 30 ms and then
			# waits 90 ms for a frame is a very different problem from one that
			# costs 120 ms, and the bar looks identical either way
			HighpolyProfiler.span("map lights: build fixtures",
				Time.get_ticks_msec() - slice)
			_tw = Time.get_ticks_msec()
			if progress.is_valid():
				progress.call(seen, all.size())
			if root.is_inside_tree():
				await root.get_tree().process_frame
			# The scene can be closed or the layer switched off mid-build. The
			# holder is DETACHED now, so its being out of the tree is the normal
			# state and no longer the signal - the ROOT going away is. Left as
			# holder.is_inside_tree() this returned "cancelled" on the very first
			# yield of every build.
			if not is_instance_valid(root) or not root.is_inside_tree() \
					or not is_instance_valid(holder):
				if progress.is_valid():
					progress.call(all.size(), all.size())   # never strand the bar
				HighpolyProfiler.crumb("lights", "cancelled at %d of %d" % [seen, all.size()])
				if is_instance_valid(holder) and not holder.is_inside_tree():
					holder.free()   # detached, so nothing else will collect it
				return "Map lights cancelled"
			HighpolyProfiler.span("map lights: waiting for a frame",
				Time.get_ticks_msec() - _tw)
			slice = Time.get_ticks_msec()
		if not (L is Dictionary): continue
		if str(L.get("layer", "base")) != "base":
			continue                    # winter/gauntlet-only lights stay off
		var lt := make_light(L)
		lt.visible = false              # tick_lights enables the near ones
		holder.add_child(lt)
		lt.owner = null
		n += 1
	# THE ONE ATTACH. Every fixture above went into a DETACHED holder, so the
	# editor learns about all of them here, once, instead of 11,641 times.
	# Timed on its own so the next profile says plainly whether the cost moved
	# here rather than went away. If it moved, this is one hitch instead of
	# 23 s of them, and the next thing to try is not building the far ones.
	var _ta := Time.get_ticks_msec()
	root.add_child(holder)
	holder.owner = null
	HighpolyProfiler.span("map lights: attach holder", Time.get_ticks_msec() - _ta)
	invalidate_light_cull()      # everything starts hidden: the next tick must run
	if progress.is_valid():
		progress.call(all.size(), all.size())
	HighpolyProfiler.crumb("lights", "placed %d in %.1f s"
		% [n, (Time.get_ticks_msec() - _tl) / 1000.0])
	return "Map lights: %d loaded (nearest %d m lit)" % [n, int(lights_range)]

# dock-timer culling: only lights near the editor camera render.
#
# This runs on the panel's half-second timer and is O(EVERY light in the map) â€”
# 11,640 of them on Dumbo. It used to run on every tick regardless of whether
# anything had changed, so standing perfectly still cost ~11,640 distance tests
# twice a second, forever, to arrive at the same answer each time. That is the
# shape of a periodic hitch reported while stationary.
#
# The lights already carry GPU distance fade (see set_map_lights); this pass is
# the coarser one that keeps them out of the clustered-element budget entirely,
# so it is worth keeping â€” it just is not worth REPEATING for a camera that has
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
