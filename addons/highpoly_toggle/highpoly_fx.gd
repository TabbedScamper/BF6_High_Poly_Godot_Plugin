@tool
extends Object
class_name HighpolyFx
# Map FX layer: live GPU particles at the map's real FX spawn points
# (user://mapcontext/<map>/fx.json - mined + classified from the level EBX).
#
# Parameters are the GAME'S OWN, per emitter graph, from fx_params.json (the FX
# Browser's editor_fx_params.json, whose stated purpose is to be "consumed by
# the site player and the Godot map-context overlay so both previews match").
# fx.json already records WHICH graph each spawn point uses in its `effect`
# field, so the join needs no extra data.
#
# This replaces three hardcoded class looks. What that cost:
#   * every fire on every map drew identically, ignoring authored lifetime,
#     spawn rate, drag, colour, size and flipbook;
#   * two of the five classes fx.json emits were silently dropped - the class
#     table had fire/smoke/electric only, so `dust` and `other` fell through
#     `if not counts.has(cls): continue`. On Abbasid that is 1,741 of 3,460
#     points (50%); `dust` is the largest or second-largest class on most maps.
#
# Per-graph values used: lifetime_s, spawn.{mode,rate,max_count,initial_count},
# drag, gravity, buoyancy, spawn_speed, rotation_speed_deg, spawn_rot_deg,
# turbulence, opacity, color/color0, base_size, cols/rows/frames/fps, and
# `render` (emissive -> additive; sixway/lit -> alpha). Game colours are LINEAR
# and are converted to display space here.

const NODE := "_MAP_FX"
const PARAMS_PATH := "res://addons/highpoly_toggle/fx_params.json"
# Emitter budget. Correcting the source_class filter took the drawn population
# from 1,504 (one map) to 59,289 across 21 maps - Granite TechCampus alone is
# 7,671 - and every emitter is a node with its own process material. Distance
# culling hides them but does not remove the node cost, so cap the count and
# SAY SO in the status line rather than truncating quietly. Points are kept in
# file order, which is spatially clustered, so a trimmed map still reads.
const MAX_EMITTERS := 3000
# Some graphs author an effectively endless particle life (EG_Bird_Flocking_ES
# and EG_Butterfly_ES both say 99999 s, meaning "loops until told otherwise" in
# the game's system). Fed to GPUParticles3D that reads as particles that spawn
# once and then hang motionless, and it also drives the flipbook clock, so the
# sheet animation slows to a stop. Cap it at something a preview can show.
const MAX_LIFETIME := 30.0

static var _mats: Dictionary = {}       # cache key -> [ParticleProcessMaterial, Mesh]
static var _params: Dictionary = {}     # UPPERCASE graph name -> params
static var _params_loaded := false

# Fallback look per class, used only when a spawn point's graph is absent from
# the table. Deliberately plain so a miss looks like a miss rather than quietly
# passing for authored data.
const CLASS_FALLBACK := {
	"fire":     {"lifetime_s": 5.0, "base_size": 2.4, "render": "emissive",
				 "color": [1.0, 0.55, 0.2, 1.0], "sheet_key": "fire"},
	"smoke":    {"lifetime_s": 5.0, "base_size": 4.0, "render": "sixway",
				 "color": [0.32, 0.31, 0.30, 0.75], "sheet_key": "smoke"},
	"dust":     {"lifetime_s": 4.0, "base_size": 3.0, "render": "lit",
				 "color": [0.55, 0.5, 0.44, 0.5], "sheet_key": "smoke"},
	"electric": {"lifetime_s": 0.6, "base_size": 0.35, "render": "emissive",
				 "color": [1.0, 0.72, 0.35, 1.0], "sheet_key": ""},
	"other":    {"lifetime_s": 3.0, "base_size": 1.0, "render": "lit",
				 "color": [0.8, 0.8, 0.8, 0.6], "sheet_key": ""},
}
# draw distance per class (metres). Smoke columns read from far away.
const CLASS_RANGE := {"fire": 300.0, "smoke": 600.0, "dust": 400.0,
					  "electric": 220.0, "other": 300.0}


static func _load_params() -> void:
	if _params_loaded:
		return
	_params_loaded = true
	if not FileAccess.file_exists(PARAMS_PATH):
		return
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
	if not (raw is Dictionary):
		return
	var graphs: Variant = (raw as Dictionary).get("graphs", {})
	if graphs is Dictionary:
		# fx.json spells the effect lowercase, the table uses CamelCase
		for k in (graphs as Dictionary).keys():
			_params[String(k).to_upper()] = _strip_nulls(graphs[k])


# A null in the params table means "not authored", but every reader here does
# float(d.get(key, fallback)) — and .get() only returns the fallback when the key
# is ABSENT, so a present-but-null value reached float() and threw "Nonexistent
# 'float' constructor". That aborts _emitter(), which then returns null and the
# caller sets .position on Nil. 65 of the 146 graphs carry a null spawn.rate, so
# on Dumbo this silently dropped 508 of 727 spawn points. Removing the nulls at
# load time makes every existing .get(key, fallback) behave as it reads.
static func _strip_nulls(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary).keys():
			var val: Variant = (v as Dictionary)[k]
			if val == null:
				continue
			out[k] = _strip_nulls(val)
		return out
	return v


static func clear(root: Node) -> void:
	if root == null: return
	# name-pattern sweep: plugin reloads orphan owner=null overlays, and a
	# rebuilt twin gets auto-RENAMED next to the orphan - a single
	# get_node_or_null() then deletes the wrong one ("FX won't turn off")
	for c in root.get_children():
		if String(c.name).contains(NODE):
			root.remove_child(c)
			c.queue_free()


# YIELDS, and reports through `progress` as progress.call(done, total).
#
# This used to build up to MAX_EMITTERS GPUParticles3D between two frames with
# no feedback of any kind: no bar, and no repaint either, so the panel simply
# stopped responding until it finished. A progress bar on a function that never
# gives a frame back cannot draw, so the yielding is not decoration here — it is
# what makes the bar possible.
static func apply(root: Node, map: String, on: bool, progress := Callable()) -> String:
	clear(root)
	if root == null: return "No scene open"
	if not on: return "FX off"
	_load_params()
	var p := "user://mapcontext/%s/fx.json" % map
	if not FileAccess.file_exists(p):
		return "No FX data for %s" % map
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return "fx.json unreadable"
	var holder := Node3D.new()
	holder.name = NODE
	root.add_child(holder)
	holder.owner = null
	var n := 0
	var authored := 0
	var skipped := 0
	var all: Array = d.get("fx", [])
	var seen := 0
	var slice := Time.get_ticks_msec()
	for f in all:
		seen += 1
		if Time.get_ticks_msec() - slice >= 30:
			if progress.is_valid():
				progress.call(seen, all.size())
			if root.is_inside_tree():
				await root.get_tree().process_frame
			# switching the layer back off, or closing the scene, frees the
			# holder underneath us: stop rather than parent onto a dead node
			if not is_instance_valid(holder) or not holder.is_inside_tree():
				if progress.is_valid():
					progress.call(all.size(), all.size())
				return "FX cancelled"
			slice = Time.get_ticks_msec()
		if not (f is Dictionary): continue
		if n >= MAX_EMITTERS:
			skipped += 1
			continue
		# Exclude ONLY the seasonal/gamemode-exclusive layer. This used to read
		# `!= "base"`, which was far more aggressive than intended: across the
		# 21 mined maps the split is gamemode-layer 57,785 / base 1,504 /
		# seasonal 39, and ONLY Dumbo has any `base` FX at all - so the overlay
		# drew nothing whatsoever on 20 of 21 maps. `gamemode-layer` is ordinary
		# level content that is present in normal play; `seasonal/gamemode-only`
		# is the winter/gauntlet set the original filter was aiming at.
		if str(f.get("source_class", "base")).begins_with("seasonal"):
			continue
		var cls := str(f.get("class", ""))
		if not CLASS_FALLBACK.has(cls):
			cls = "other"               # never drop a spawn point
		var effect := str(f.get("effect", ""))
		var gp: Variant = _params.get(effect.to_upper())
		if gp != null:
			authored += 1
		var pos: Array = f.get("pos", [0, 0, 0])
		var e := _emitter(cls, effect, gp)
		e.position = Vector3(pos[0], pos[1], pos[2])
		e.rotation.y = float(f.get("yaw", 0.0))
		holder.add_child(e)
		e.owner = null
		n += 1
	if progress.is_valid():
		progress.call(all.size(), all.size())
	var msg := "FX: %d emitters, %d with authored parameters (%d%%)" % [
		n, authored, (authored * 100 / maxi(n, 1))]
	if skipped > 0:
		msg += " - %d more skipped at the %d budget" % [skipped, MAX_EMITTERS]
	return msg


static func _lin_to_srgb(c: float) -> float:
	# game colours are LINEAR; Godot albedo/vertex colour wants display space
	return 12.92 * c if c <= 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055


static func _colour_of(gp: Variant, fb: Dictionary) -> Color:
	var arr: Variant = null
	if gp is Dictionary:
		arr = (gp as Dictionary).get("color")
		if arr == null:
			arr = (gp as Dictionary).get("color0")
	if not (arr is Array) or (arr as Array).size() < 3:
		var f: Array = fb.get("color", [1, 1, 1, 1])
		return Color(f[0], f[1], f[2], f[3] if f.size() > 3 else 1.0)
	var a: Array = arr
	var alpha := 1.0
	if gp is Dictionary and (gp as Dictionary).has("opacity"):
		alpha = float((gp as Dictionary)["opacity"])
	elif a.size() > 3:
		alpha = float(a[3])
	return Color(_lin_to_srgb(float(a[0])), _lin_to_srgb(float(a[1])),
				 _lin_to_srgb(float(a[2])), clampf(alpha, 0.0, 1.0))


static func _sheet_for(gp: Variant, fb: Dictionary) -> String:
	# The plugin ships the two sheets that cover the most-placed FX. A graph
	# naming any other sheet falls back to the closest bundled one rather than
	# drawing an untextured quad.
	var base := (HighpolyFx as Script).resource_path.get_base_dir() + "/fx_textures"
	var key := str(fb.get("sheet_key", ""))
	if gp is Dictionary:
		var s := str((gp as Dictionary).get("sheet", "")).to_lower()
		if s.contains("fire") or s.contains("muzzleflash") or s.contains("glow"):
			key = "fire"
		elif s.contains("smoke") or s.contains("clastic") or s.contains("puff"):
			key = "smoke"
	match key:
		"fire":  return base + "/fire_6x36.png"
		"smoke": return base + "/smoke_8x64.png"
	return ""


static func _emitter(cls: String, effect: String, gp: Variant) -> GPUParticles3D:
	var g := GPUParticles3D.new()
	var cfg := _build_mats(cls, gp)
	g.process_material = cfg[0]
	g.draw_pass_1 = cfg[1]

	var fb: Dictionary = CLASS_FALLBACK[cls]
	var life := float(fb.get("lifetime_s", 4.0))
	var amount := 6
	if gp is Dictionary:
		var d: Dictionary = gp
		life = float(d.get("lifetime_s", life))
		var sp: Variant = d.get("spawn")
		if sp is Dictionary:
			var s: Dictionary = sp
			# Godot has no spawn-rate knob: the on-screen population is `amount`
			# over `lifetime`, so rate*life is the steady state, capped by the
			# authored max_count.
			var rate := float(s.get("rate", 1.0))
			var cap := int(s.get("max_count", 64))
			amount = clampi(int(round(rate * life)), 1, maxi(cap, 1))
			if str(s.get("mode", "continuous")) == "burst":
				g.one_shot = true
				g.explosiveness = 1.0
				amount = clampi(int(s.get("initial_count", cap)), 1, maxi(cap, 1))
	g.lifetime = clampf(life, 0.05, MAX_LIFETIME)
	g.amount = clampi(amount, 1, 256)

	var vr := float(CLASS_RANGE.get(cls, 300.0))
	g.visibility_range_end = vr
	g.visibility_range_end_margin = 40.0
	g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	g.visibility_aabb = AABB(Vector3(-6, -1, -6), Vector3(12, 14, 12))
	g.set_meta("vr", vr)       # class default, for set_range
	return g


static func _build_mats(cls: String, gp: Variant) -> Array:
	var fb: Dictionary = CLASS_FALLBACK[cls]
	var ck := cls
	if gp is Dictionary:
		ck = str((gp as Dictionary).get("graph", cls))
	if _mats.has(ck): return _mats[ck]

	var pm := ParticleProcessMaterial.new()
	var qm := QuadMesh.new()
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.vertex_color_use_as_albedo = true

	var render := str(fb.get("render", "lit"))
	var size := float(fb.get("base_size", 1.0))
	pm.direction = Vector3(0, 1, 0)
	pm.initial_velocity_min = 0.4
	pm.initial_velocity_max = 1.0
	pm.damping_min = 0.3
	pm.damping_max = 0.3
	pm.gravity = Vector3(0, 0.6, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.5

	var life := float(fb.get("lifetime_s", 4.0))
	if gp is Dictionary:
		var d: Dictionary = gp
		# same cap as the emitter: this life also clocks the flipbook below
		life = clampf(float(d.get("lifetime_s", life)), 0.05, MAX_LIFETIME)
		render = str(d.get("render", render))
		size = float(d.get("base_size", size)) * float(d.get("base_size_bias", 1.0))
		var drag := float(d.get("drag", 0.3))       # authored Drag -> damping
		pm.damping_min = drag
		pm.damping_max = drag
		var gy := float(d.get("gravity", 0.0))      # authored negative (-9.81)
		if gy == 0.0:
			gy = float(d.get("buoyancy", 0.0))
			if gy == 0.0 and (cls == "smoke" or cls == "fire" or cls == "dust"):
				gy = 0.6                            # these rise regardless
		pm.gravity = Vector3(0, gy, 0)
		var ss: Variant = d.get("spawn_speed")
		if ss is Array and (ss as Array).size() >= 2:
			pm.initial_velocity_min = float(ss[0])
			pm.initial_velocity_max = maxf(float(ss[1]), float(ss[0]))
		elif d.has("speed_mult"):
			var sm := float(d["speed_mult"])
			pm.initial_velocity_min = sm * 0.25
			pm.initial_velocity_max = sm
		if d.has("rotation_speed_deg"):
			var rs := deg_to_rad(float(d["rotation_speed_deg"]))
			pm.angular_velocity_min = -rs
			pm.angular_velocity_max = rs
		if d.has("spawn_rot_deg"):
			var sr := float(d["spawn_rot_deg"])
			pm.angle_min = -sr
			pm.angle_max = sr
		if d.has("turbulence_strength"):
			pm.turbulence_enabled = true
			pm.turbulence_noise_strength = float(d["turbulence_strength"]) * 0.1
			if d.has("turbulence_frequency"):
				pm.turbulence_noise_scale = maxf(float(d["turbulence_frequency"]), 0.01)
		var bb: Variant = d.get("emitter_bbox")
		if bb is Array and (bb as Array).size() == 2 and bb[0] is Array:
			var hi: Array = bb[0]
			if hi.size() >= 3:
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
				pm.emission_box_extents = Vector3(
					absf(float(hi[0])), absf(float(hi[1])), absf(float(hi[2])))

	pm.color = _colour_of(gp, fb)

	# `render` carries what the compiled shader's blend state does not expose:
	# emissive effects (fire, sparks, muzzle flash) draw additively.
	dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if render == "emissive" \
		else BaseMaterial3D.BLEND_MODE_MIX

	var sheet := _sheet_for(gp, fb)
	if sheet != "" and ResourceLoader.exists(sheet):
		dm.albedo_texture = load(sheet)
		var cols := 6
		var rows := 6
		var frames := 36
		var fps := 12.0
		if gp is Dictionary:
			var d2: Dictionary = gp
			cols = int(d2.get("cols", cols))
			rows = int(d2.get("rows", rows))
			frames = int(d2.get("frames", cols * rows))
			fps = float(d2.get("fps", fps))
		elif str(fb.get("sheet_key", "")) == "smoke":
			cols = 8; rows = 8; frames = 64; fps = 12.8
		dm.particles_anim_h_frames = maxi(cols, 1)
		dm.particles_anim_v_frames = maxi(rows, 1)
		dm.particles_anim_loop = true
		# Godot plays one full sheet per particle lifetime at anim_speed 1.0,
		# so scale it to hit the authored frames-per-second
		var sp2 := (fps * life) / maxf(float(frames), 1.0)
		pm.anim_speed_min = sp2
		pm.anim_speed_max = sp2

	qm.size = Vector2(size, size)
	qm.material = dm
	_mats[ck] = [pm, qm]
	return _mats[ck]


# Range-slider tie-in: clamp every emitter's draw distance to the dock's
# Range value (never past its class default). 0 hides FX entirely.
static func set_range(root: Node, r: float) -> void:
	var h := root.get_node_or_null(NODE) if root != null else null
	if h == null: return
	for c in h.get_children():
		if c is GPUParticles3D:
			var g := c as GPUParticles3D
			if r <= 0.0:
				g.visible = false
			else:
				g.visible = true
				g.visibility_range_end = minf(float(g.get_meta("vr", 300.0)), r)
