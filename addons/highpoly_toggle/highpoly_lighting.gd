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
const LightingZones = preload("highpoly_lighting_zones.gd")

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
# The installed level's active VisualEnvironment is the only authority. Missing
# data stays visibly missing; no table or previously exported package fills it.

const NODE := "_GAME_LIGHTING"

# Lighting values are read from the active VisualEnvironment in the installed
# game. No compiled per-map table is a runtime fallback.

static func has_data(map: String) -> bool:
	return map != "" and not mined(map).is_empty()

# ---------------------------------------------------------------------------
# THE LIVE VisualEnvironment
#
# HighpolyGameSource selects the dominant outdoor preset from the level root and
# decodes its component-qualified fields directly from the installed game.
# `mined` keeps its old name only to avoid breaking callers; it no longer reads
# a map package or any exported intermediate.
# The source owns a map-keyed in-memory cache and drops it on map change. A miss
# is not cached here, so opening the reader later in the same editor session is
# observed immediately.
static func mined(map: String) -> Dictionary:
	if map == "" or game_source == null \
			or not game_source.has_method("environment_lighting") \
			or str(game_source.level) != map.to_lower():
		return {}
	return game_source.environment_lighting()

# Local lighting zones (interiors, alleys, dark spots) with a world extent.
static func zones(map: String) -> Array:
	if map != "" and game_source != null \
			and game_source.has_method("lighting_zones") \
			and str(game_source.level) == map.to_lower():
		var z = game_source.lighting_zones()
		return z if z is Array else []
	# Native reader unavailable or not opened. Returning no zones is explicit;
	# consuming an old placements.json would make a stale answer authoritative.
	return []

static func forget(map := "") -> void:
	# The live reader owns and invalidates its caches on map change/reload.
	pass

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
# SHADOWS IN A RADIUS, and heavily cheaper beyond it.
#
# The reason overlay shadows were switched off wholesale is in _set_textured:
# every placed object casting at once, into a directional atlas covering 1,500
# m, crashed the editor outright on the multi-threaded renderer this project
# ships with. The atlas is a fixed budget, so its cost per caster is set by how
# much WORLD it has to span - 1,500 m of it spread across four splits leaves
# almost no resolution for anything, and every caster still pays.
#
# Bounding the distance fixes both halves at once: Godot culls casters outside
# the shadow range for free, so a radius is not an extra pass, and the same
# atlas over 80 m instead of 1,500 is ~19x the linear resolution. Objects past
# the radius keep their lighting and lose only their shadow, which at that
# distance is a few pixels.
static var shadow_radius := 80.0
# ...and not for litter. The atlas cost is per CASTER, not per square metre, so
# a bottle books the same slot as a tower and returns a few pixels for it. A car
# is ~4.5 m and a building far more; both clear this, a crate lid does not.
static var shadow_min_size := 1.5

# Fraction of ambient held back from sky visibility so enclosed spaces keep a
# floor of light. See the block in apply() for why interiors were black without
# it. 0.0 restores the strictly sky-driven (PhotoMatch-calibrated) behaviour;
# raise it if rooms are still too dark to work in.
static var interior_fill := 0.0


# Mean hue of one panorama row, sampled at a fixed 128 columns. This replaces
# the old hand-copied top/horizon/ground table with a deterministic measurement
# of the decoded game texture. Magnitude remains the panorama luminance scale's
# job, so the returned colour is hue-normalised.
static func _pano_row_color(img: Image, v: float) -> Color:
	if img == null or img.get_width() <= 0 or img.get_height() <= 0:
		return Color.BLACK
	var y := clampi(int(round(v * float(img.get_height() - 1))), 0, img.get_height() - 1)
	var sum := Vector3.ZERO
	const SAMPLES := 128
	for i in range(SAMPLES):
		var x := mini(img.get_width() - 1, int((float(i) + 0.5) * img.get_width() / SAMPLES))
		var c := img.get_pixel(x, y)
		sum += Vector3(c.r, c.g, c.b)
	var peak := maxf(maxf(sum.x, sum.y), sum.z)
	if peak <= 0.000001:
		return Color.BLACK
	return Color(sum.x / peak, sum.y / peak, sum.z / peak)

# Build + inject the lighting rig. Idempotent (clears any previous rig first).
# gi/shadows: the dock's sub-checkboxes (PhotoMatch renders keep full quality
# via the defaults).
static func apply(root: Node, map: String, gi := true, shadows := true) -> String:
	if root == null:
		return "No scene open"
	clear(root)
	var m: Dictionary = mined(map)
	if m.is_empty():
		return "No lighting data for %s" % map
	# Sun values are the component-qualified fields of the selected live preset.
	# Panorama colours below are sampled from its decoded texture, not a map table.
	var e := {
		"az": float(m["sun_az"]),
		"el": float(m["sun_el"]),
		"lux": float(m["sun_lux"]),
		"sun": _col(m.get("sun_color"), Color.WHITE),
		"top": Color.BLACK,
		"hor": Color.BLACK,
		"gnd": Color.BLACK,
	}

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
	sun.directional_shadow_max_distance = shadow_radius
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
			var pimg: Image = (pano_tex as Texture2D).get_image()
			if pimg != null:
				e["top"] = _pano_row_color(pimg, 0.02)
				e["hor"] = _pano_row_color(pimg, 0.49)
				e["gnd"] = _pano_row_color(pimg, 0.75)
	# THE GAME'S SKY OR NO SKY. Two fallbacks used to sit here and both were
	# things this plugin is not allowed to have: a DOWNLOADED sky.exr conversion
	# in the cache, and a .dds of Battlefield art bundled inside the addon. The
	# bundled one was 16.8 MB and was still sitting in the user's install months
	# after it was supposedly removed, because deleting a file does not stop code
	# from looking for it.
	#
	# A level whose VE cannot be read now gets no panorama, which is visible and
	# reportable. That is the correct failure: the alternative is one map's sky
	# quietly standing in for another's, which is what "only one map ever had a
	# real sky" meant.
	if pano_tex != null:
		# THE PANORAMA WITH A SUN DRAWN ON TOP OF IT, rather than a
		# PanoramaSkyMaterial, which can only show the texture.
		#
		# CORRECTION: this used to say the panoramas contain no sun disc, on the
		# evidence that all 22 go black when exposure is crushed. That is FALSE
		# and was retracted to the research repo - measured on the decoded
		# panorama, aftermath's painted sun is 9 texels at elevation 12.8 against
		# an authored SunRotationY of 12.9. The disc drawn here lands BESIDE a
		# painted one. DrawSunDisc = 1 on every map is still true; it just does
		# not mean the art has no sun in it. So the sky we built
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
			emul = 1.0
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
	env.tonemap_exposure = 1.0
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
			# the level's own authored distance, but never past the radius: the
			# game renders this on a console GPU with a shadow budget the editor
			# does not have
			sun.directional_shadow_max_distance = minf(
				clampf(d * 8.0, 60.0, 2000.0), shadow_radius)

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
# A preset carries no volume. Its exact region is the OBBData or
# VolumeVectorShapeData linked from AreaProximityEntityData.Geometry in the
# owning blueprint, transformed through the placed level graph. The native
# installed-game reader supplies those shapes and its rotated-source control;
# channel-routed zones whose preset join is still open remain absent.
static var zones_enabled := true
static var _zones: Array = []              # for the open map
static var _zone_map := ""
static var _zone_blend := 1.0              # current exposure multiplier
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
	_zone_blend = 1.0
	for z in zones(map):
		if not (z is Dictionary):
			continue
		var row: Dictionary = z
		var xf: Variant = row.get("transform")
		var kind := int(row.get("kind", -1))
		if not (xf is Transform3D) or (kind != 0 and kind != 1):
			continue
		var cooked := {
			"kind": kind,
			"transform": xf,
			"ev": float(row.get("ev", 0.0)),
			"ev_max": float(row.get("ev_max", 0.0)),
			"name": str(row.get("preset", "")),
			# Preserved for diagnostics. The exact numeric proximity-output law is
			# still open, so this is not turned into an invented fade curve here.
			"fade_distance": float(row.get("fade_distance", 0.0)),
		}
		if kind == 0:
			var half: Array = row.get("half_extents", [])
			if half.size() != 3:
				continue
			cooked["half_extents"] = Vector3(
				float(half[0]), float(half[1]), float(half[2]))
		else:
			var raw_points: Array = row.get("points", [])
			if raw_points.size() < 3:
				continue
			var points: Array[Vector3] = []
			var planar := true
			var base_y := 0.0
			for p in raw_points:
				if not (p is Array) or (p as Array).size() < 3:
					points.clear()
					break
				var q := Vector3(float(p[0]), float(p[1]), float(p[2]))
				if points.is_empty():
					base_y = q.y
				elif not is_equal_approx(q.y, base_y):
					planar = false
				points.append(q)
			if points.size() < 3:
				continue
			cooked["points"] = points
			cooked["height"] = float(row.get("height", 0.0))
			cooked["base_y"] = base_y
			cooked["planar"] = planar
		_zones.append(cooked)
	return _zones.size()


static func _zone_contains(z: Dictionary, world_point: Vector3) -> bool:
	return LightingZones.contains(z, world_point)

# Exposure difference a zone asks for, as a multiplier. EV is a log2 stop scale,
# so one stop darker is half the light: 2^(base - zone).
static func _zone_exposure(z: Dictionary, base_ev: float) -> float:
	var ev := float(z.get("ev_max", 0.0))
	if ev <= 0.0:
		ev = float(z.get("ev", 0.0))
	if ev <= 0.0 or base_ev <= 0.0:
		return 1.0
	return pow(2.0, base_ev - ev)

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
		if _zone_contains(z, cam_pos):
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

# ---------- map lights (live records from the open game reader) -------------
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
# DEFAULTS OFF, matching the panel's chip. It defaulted to TRUE while the chip
# defaulted to false, so a fresh boot built every fixture visible and the switch
# read "off" - the user saw lights that the panel said were not on.
static var prop_lighting := false
const PROP_LIGHT_NAME := "_HP_LIGHT_"


# Switch every placed prop's fixtures on or off, without rebuilding anything.
# Returns how many it touched, so the panel can say something true.
# NOT BY NAME. Every fixture goes into one holder, so they all asked to be
# called _HP_LIGHT_0 and Godot - which renames on collision, and does it BEFORE
# the node is in the tree if the name is set first - threw the names away
# entirely: 2,534 fixtures in the holder, 4 of them still called _HP_LIGHT_*,
# the rest @OmniLight3D@25259. The name test then matched almost nothing and the
# switch turned the textures off while every light stayed on.
#
# The holder contains prop fixtures and nothing else, so its children ARE the
# set. No names involved.
static func set_prop_lights_shown(root: Node, on: bool) -> int:
	if root == null:
		return 0
	var n := 0
	var holder := root.get_node_or_null(PROP_LIGHT_HOLDER)
	if holder != null:
		for c in holder.get_children():
			if c is Light3D:
				(c as Light3D).visible = on
				n += 1
	# Fixtures built by a version that parented them INSIDE the overlay are
	# still out there in scenes people already have open. Those did keep their
	# names, so the old test heals them.
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
			if c.name != "_MAP_CONTEXT" and c.name != PROP_LIGHT_HOLDER:
				stack.append(c)
	return n


# A FIXTURE'S LIGHTS DO NOT LIVE INSIDE THE PROP.
#
# They used to be children of the overlay, and a Light3D's bounds are its RANGE:
# the ceiling lamp's are 6 m and 15 m. The editor's selection box merges every
# VisualInstance3D under the selected node, so selecting a lamp gave a box tens
# of metres across and the gizmo was unusable.
#
# So they hang off a scene-level holder instead and are kept in step with the
# prop by refresh_prop_lights, exactly as the collision overlay already does for
# the same reason. The prop's own subtree contains only geometry, so its box is
# its geometry.
#
# The alternative - shrinking the lights - would have changed the lighting to fix
# a selection problem, which is the wrong trade.
const PROP_LIGHT_HOLDER := "_HP_PROP_LIGHTS"
# [prop, light, light's transform in the prop's space]
static var _prop_tracked: Array = []


static func _prop_holder(root: Node) -> Node3D:
	var h := root.get_node_or_null(PROP_LIGHT_HOLDER)
	if h == null:
		h = Node3D.new()
		h.name = PROP_LIGHT_HOLDER
		root.add_child(h)
		h.owner = null                  # editor-only, never saved into the scene
	return h as Node3D


static func remove_prop_lights(prop: Node3D) -> void:
	var alive: Array = []
	for e in _prop_tracked:
		var row: Array = e
		var dead: bool = not is_instance_valid(row[0]) or row[0] == prop
		if dead:
			if is_instance_valid(row[1]):
				(row[1] as Node).queue_free()
			continue
		alive.append(row)
	_prop_tracked = alive


# Cheap periodic pass, the same shape as HighpolyCollision.refresh_transforms:
# a handful of matrix multiplies per tracked fixture, and dead rows dropped.
static func refresh_prop_lights() -> void:
	var alive: Array = []
	for e in _prop_tracked:
		var row: Array = e
		if not is_instance_valid(row[0]) or not is_instance_valid(row[1]):
			if is_instance_valid(row[1]):
				(row[1] as Node).queue_free()
			continue
		var prop := row[0] as Node3D
		var lt := row[1] as Node3D
		if not prop.is_inside_tree() or not lt.is_inside_tree():
			continue
		# ONLY MOVE A FIXTURE WHOSE PROP MOVED.
		#
		# This runs on the 0.5 s heartbeat over every tracked fixture, and a
		# user's profile put it at 3.0 ms a tick across 1,880 of them - 6 ms a
		# second, forever, while they were standing still doing nothing. Props
		# do not move unless somebody drags one, so nearly all of that was
		# rewriting transforms to the values they already had. Each write
		# dirties the light and notifies the RenderingServer, which is the part
		# that costs.
		#
		# Reading global_transform is cheap when nothing upstream is dirty
		# (Godot caches it); the write is what is worth avoiding.
		var now := prop.global_transform
		if row.size() > 3 and (row[3] as Transform3D).is_equal_approx(now):
			alive.append(row)
			continue
		lt.global_transform = now * (row[2] as Transform3D)
		if row.size() > 3:
			row[3] = now
		else:
			row.append(now)
		alive.append(row)
	_prop_tracked = alive


static func attach_prop_lights(prop: Node3D, recs: Array) -> int:
	if prop == null or recs.is_empty():
		return 0
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not prop.is_inside_tree():
		return 0
	remove_prop_lights(prop)            # rebuilt overlays must not stack fixtures
	var holder := _prop_holder(root)
	var n := 0
	for r in recs:
		if n >= PROP_LIGHT_CAP:
			break
		if not (r is Dictionary):
			continue
		var lt := make_light(r as Dictionary)
		# make_light places the fixture in the PROP's space; that is what has to
		# be preserved once the node is parented somewhere else entirely.
		var local := lt.transform
		lt.visible = prop_lighting
		holder.add_child(lt)
		# NAMED AFTER add_child, and uniquely. Setting a name first and letting
		# Godot resolve the collision is what discarded it: the node came out as
		# @OmniLight3D@25259 and nothing could find it again.
		lt.name = "%s%d_%d" % [PROP_LIGHT_NAME, prop.get_instance_id(), n]
		lt.owner = null                 # editor-only, never saved into the scene
		lt.global_transform = prop.global_transform * local
		# [prop, light, local offset, LAST APPLIED prop transform]. The fourth
		# entry lets refresh_prop_lights skip a fixture whose prop has not
		# moved; see the note there.
		_prop_tracked.append([prop, lt, local, prop.global_transform])
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
	if game_source == null or not game_source.has_method("level_lights"):
		return "No light data for %s" % map
	var all: Array = game_source.level_lights()
	if all.is_empty():
		return "No light data for %s" % map
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
	var props := root.get_node_or_null(PROP_LIGHT_HOLDER)
	if holder == null and props == null: return
	# 1 m of slack: below that, no light can cross the boundary in a way anyone
	# could see, and the editor camera jitters slightly even when "still"
	if not _cull_dirty and cam_pos.distance_squared_to(_last_cull_pos) < 1.0:
		return
	_last_cull_pos = cam_pos
	_cull_dirty = false
	var r2 := lights_range * lights_range
	# SPLIT SO THE 80 ms CAN BE ATTRIBUTED. The profiler puts this whole function
	# at 547.6 ms over 135 calls with a worst call of 80.63 ms - the largest
	# single stall left on the heartbeat. The two loops are NOT equivalent: this
	# one reads `position` (local, free) while the prop loop reads
	# `global_position`, which walks up the tree to rebuild a global transform
	# per light, on what a previous note measured as 2,534 fixtures. Timed apart
	# so the fix aims at whichever one is actually the cost.
	HighpolyProfile.begin("lights: map light distance loop")
	if holder != null:
		for c in holder.get_children():
			if c is Light3D:
				var l := c as Light3D
				l.visible = l.position.distance_squared_to(cam_pos) <= r2
	HighpolyProfile.end("lights: map light distance loop")
	# THE FIXTURES THE BUILDER PLACED FOLLOW THE SAME SLIDER.
	#
	# They did not, and nothing was culling them at all: one scene carried 2,534
	# prop fixtures lit at once, against a Forward+ budget that stops clustering
	# at 512 in view. The level's own lights have been distance-culled since the
	# range slider was unified; these were never added to it, because they used
	# to hang inside each prop rather than in a holder a pass like this could
	# walk.
	#
	# This is the ONE authority on their visibility now. set_prop_lights_shown
	# still gives the instant answer when the switch is flipped, but the next
	# tick decides again from the switch AND the distance, so the two cannot
	# drift apart.
	HighpolyProfile.begin("lights: prop fixture distance loop (global_position)")
	if props != null:
		for c in props.get_children():
			if c is Light3D:
				var l2 := c as Light3D
				l2.visible = prop_lighting \
					and l2.global_position.distance_squared_to(cam_pos) <= r2
	HighpolyProfile.end("lights: prop fixture distance loop (global_position)")


# ---------------------------------------------------------------------------
# REFLECTION VOLUMES: the local IBL boxes the level's artists placed.
#
# Without these the scene has only the sky to reflect, so interiors preview grey
# and metal reads as plastic. The game authors boxes with a baked cubemap each;
# what is consumed here is the BOX - its placement, orientation and extent - and
# Godot captures the reflection from the geometry we already build. That makes
# the influence volume 1:1 with the game while the content comes from the same
# scene the user is looking at.
#
# The transform arrives as a FULL BASIS whose axis LENGTHS are the box
# half-extents, so there is no separate size field: normalise the axes for the
# orientation and take twice the lengths for Godot's `size`. Reading the basis as
# already-normalised would give every probe a 1 m box.
#
# The core hands over the level's own world-space volumes only. Prefab-carried
# volumes are prefab-local and duplicated (pf_X and pf_X_nongroupable_autogen),
# so placing them would need their prefab placements composed first; see the
# note in bf6_environment.inc.
const REFLECTION_NODE := "_MAP_REFLECTIONS"


static func clear_reflection_probes(root: Node) -> void:
	for c in root.get_children():
		if String(c.name).contains(REFLECTION_NODE):
			root.remove_child(c)
			c.queue_free()


# Returns a short status line, the same shape the light builders return.
static func build_reflection_probes(root: Node, env) -> String:
	clear_reflection_probes(root)
	if env == null:
		return "Reflection volumes: no native environment"
	var data: Dictionary = env.request("reflection_probes")
	if data.is_empty():
		return "Reflection volumes: %s" % str(env.error)
	var probes: Array = data.get("probes", [])
	if probes.is_empty():
		# A real answer: several levels author none of their own. Saying so
		# beats an empty node that looks like a failure.
		return "Reflection volumes: this level authors none"

	var holder := Node3D.new()
	var degenerate := 0
	var skipped_global := 0
	for entry in probes:
		var p: Dictionary = entry
		# THE LEVEL-WIDE FALLBACK IS NOT PLACED. One volume per level covers the
		# whole map (10 x 8 x 10 km on mp_isolated against 2 to 230 m for all the
		# rest). As a probe it would be a single huge low-quality capture
		# overriding the sky everywhere, and the sky is what it stands in for:
		# ambient already comes from the level's own panorama. The CORE decides
		# which volume this is, so Unreal skips the same one.
		if int(p.get("is_global", 0)) == 1:
			skipped_global += 1
			continue
		var r := _vec3(p.get("right"))
		var u := _vec3(p.get("up"))
		var fwd := _vec3(p.get("forward"))
		var half := Vector3(r.length(), u.length(), fwd.length())
		# A zero axis has no interior: it would accept or reject every point.
		# Dropped with a count rather than clamped into a box that is not there.
		if half.x <= 0.001 or half.y <= 0.001 or half.z <= 0.001:
			degenerate += 1
			continue
		var probe := ReflectionProbe.new()
		probe.size = half * 2.0
		# Interiors are the whole point, so the probe must not also gather the
		# sky: the game's boxes are local capture volumes.
		probe.interior = true
		probe.enable_shadows = false
		probe.update_mode = ReflectionProbe.UPDATE_ONCE
		holder.add_child(probe)
		probe.owner = null
		probe.transform = Transform3D(
			Basis(r.normalized(), u.normalized(), fwd.normalized()),
			_vec3(p.get("translation")))
	root.add_child(holder)
	holder.name = REFLECTION_NODE
	holder.owner = null
	var note := ""
	if skipped_global > 0:
		note += ", %d level-wide (the sky covers it)" % skipped_global
	if degenerate > 0:
		note += ", %d degenerate skipped" % degenerate
	return "Reflection volumes: %d placed%s" % [holder.get_child_count(), note]


static func _vec3(v) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO
