@tool
extends Object
class_name HighpolyFx
# THE MAP'S FX, BUILT PER LAYER.
#
# WHAT CHANGED AND WHY. This used to build every effect from about forty
# hand-curated emitter-graph ARCHETYPES in fx_params.json, plus five side tables
# that each guessed one property per graph by taking a median or a majority over
# the effects that used it. The game does not author effects that way. It
# authors LAYERS: 1,368 distinct effects on 14 retail levels expand to 3,983
# layers, and a single explosion carries BaseSize 100/200/35 and Drag
# 0.5/0.0/0.7/0.01 across its own layers. Averaging those into one archetype
# throws away exactly the variation that makes an explosion read as an explosion
# and leaves a generic puff - which is what our FX looked like.
#
# The core now reads every layer with its own values (bf6_fx_layer +
# bf6_fx_layer_look), so this builds ONE emitter per spawn point per layer from
# that layer's own numbers. Measured on MP_Isolated: 1,200 spawn points join to
# 2,343 layer emitters at 99.8% coverage, against 1,200 identical archetype
# puffs before. The only two that do not join are named *_schematic - the
# editor's own placeholder effects.
#
# WHAT THIS RETIRES. fx_params.json, fx_sizes.json, fx_spawn.json,
# fx_motion.json, fx_sheets.json and fx_effect_sheets.json were all attempts to
# recover per-layer data from per-graph aggregates. Every one of them is now
# answered directly and exactly by the layer row, including the sheet - which
# the core resolves through the layer's own binding rather than the template's,
# the difference between 2,577 layers with a sheet and 255.
#
# WHAT STAYS IN THE CORE. The layer values, the sheet grid, and the emitter
# BUDGET (bf6_fx_budget_keep). The budget is there and not here because Unreal
# has to trim to the identical set or the two previews stop being comparable.
#
# WHAT IS STILL LOCAL. Which Godot node stands in for which family, and the
# distance at which we stop drawing. Both are rendering decisions this editor
# has to make and the game does not express.

const NODE := "_MAP_FX"
# TWO SHADERS, ONE BODY. Godot fixes the blend mode at compile time, so
# "this layer is emissive" cannot be a uniform: fire, sparks and muzzle flash
# genuinely ADD light to the scene and everything else composites over it.
# Both include fx_sixway.gdshaderinc, which is where the actual work lives.
const SHADER_PATH := "res://addons/highpoly_toggle/fx_sixway.gdshader"
const SHADER_ADD_PATH := "res://addons/highpoly_toggle/fx_sixway_add.gdshader"
# LEGACY FALLBACK ONLY. The mesh now comes down per layer from the core, which
# reads the graph template's own EmitterMesh import. This per-graph majority
# table is consulted only when the core names no mesh, so an install running an
# older reader still draws what it used to.
const MESHES_PATH := "res://addons/highpoly_toggle/fx_meshes.json"
const SHEET_CACHE := "user://fxsheets"
# Cap on the sheet's decoded width. The mip chain is in the atlas header, so a
# smaller sheet is a smaller mip of the game's own texture rather than a resample
# of the largest one. NOT halved for LeftRightTiles any more: the shader needs
# both halves, so the whole sheet is kept.
const SHEET_MAX := 2048
# BUMP WHENEVER THE DECODE CHANGES. Sheets are cached to disk, so a corrected
# decode is invisible until the old files stop being read - which is how the
# first version of the six-way fold shipped looking identical to the broken one.
# Epoch 3 is the first that does NOT fold the six-way halves together, because
# the shader now uses them.
const SHEET_EPOCH := 3
# Particle life that means "until told otherwise" in the game's system. Fed to
# GPUParticles3D it reads as particles that spawn once and hang motionless, and
# it also clocks the flipbook, so the sheet animation stops.
const MAX_LIFETIME := 30.0
# Per-emitter particle ceiling. The game's own particle_max runs to the tens of
# thousands for effects that are meant to be seen once at close range; a preview
# that honours those literally spends its whole frame on one explosion.
const MAX_PARTICLES := 192
# Metres per second a previewed particle may reach. See the note where it is
# applied: a handful of layers author thousands, which is meaningful in the game
# for a tracer and is meaningless on screen here.
const MAX_SPEED := 25.0
# Metres per second squared. Same reasoning as MAX_SPEED, applied to the summed
# gravity + buoyancy + LocalForce vector.
const MAX_FORCE := 20.0

# ALIGNMENT, as the game numbers it. Passed straight to the shader.
const ALIGN_SCREEN := 0
const ALIGN_SCREEN_STRETCH := 2
const ALIGN_NAMES := ["Screen", "Directional", "ScreenStretch", "FullRotation",
					  "Emitter", "Up"]
# LIGHTING MODEL: 0 Emissive, 1 VertexLit, 2 GnomonLit, -1 the layer states none.
const LIGHT_EMISSIVE := 0
const LIGHT_GNOMON := 2

# WHICH GODOT NODE STANDS IN FOR WHICH FAMILY. The core classifies a layer from
# its graph path alone, independently of the lighting model, so this is a
# straight mapping rather than a guess.
#
# The families that draw nothing are not missing art. An exhaustive pointer walk
# over 592 graph partitions found no ribbon, distortion, normal-map, gobo or
# decal texture field on any emitter graph: those effects live in compiled
# shaders, and a camera-facing quad filled with a flat colour standing in for one
# is a wrong answer that looks like a right one. Nothing, counted and said out
# loud in the status line, is the honest one.
const FAMILY_QUAD := {
	"billboard_globalsorting": true, "sparks": true, "other": true,
}
const FAMILY_MESH := {"debris_mesh": true}
const FAMILY_DECAL := {"volumedecal": true}
const FAMILY_NONE := {
	"distortion": "screen-space distortion, which has no texture to draw",
	"ribbon": "ribbons, which are trails rather than billboards",
	"lensflare": "lens flares, drawn by the game's own post pass",
	"creature": "birds and rats, which are animated meshes",
}
# The commonest authored volume-decal box, doubled from the half-extent basis:
# (1,1,1) on 129 of 250 emitter rows.
const DECAL_BOX := Vector3(2.0, 2.0, 2.0)
# Draw distance. The layer's own gpu_cull_distance is the game's answer and is
# used whenever it is authored; this is the floor and ceiling around it, because
# a handful of layers author 0 (meaning "never cull" in the game, and "never
# draw" if taken literally) and a few author kilometres.
const RANGE_MIN := 120.0
const RANGE_MAX := 900.0

static var _shader: Shader = null
static var _shader_add: Shader = null
static var _mats: Dictionary = {}          # cache key -> {process, mesh, ...}
static var _sheet_by_res: Dictionary = {}  # atlas res -> Texture2D or null
static var _meshtbl: Dictionary = {}
static var _meshes: Dictionary = {}
static var _meshes_loaded := false
static var _decal_tex: Texture2D = null
static var _swept := false


static func clear(root: Node) -> void:
	if root == null: return
	# Name-pattern sweep: plugin reloads orphan owner=null overlays, and a
	# rebuilt twin gets auto-RENAMED next to the orphan, so a single
	# get_node_or_null() deletes the wrong one ("FX won't turn off").
	for c in root.get_children():
		if String(c.name).contains(NODE):
			root.remove_child(c)
			c.queue_free()


# YIELDS, and reports through `progress` as progress.call(done, total).
static func apply(root: Node, map: String, on: bool, progress := Callable(),
		gs = null) -> String:
	clear(root)
	if root == null: return "No scene open"
	if not on: return "FX off"

	var p := "user://mapcontext/%s/fx.json" % map
	if not FileAccess.file_exists(p):
		return "No FX data for %s" % map
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return "fx.json unreadable"
	var points: Array = (d as Dictionary).get("fx", [])

	# THE LAYERS. Without these there is nothing to build: the archetype path
	# this replaced is gone, and standing in for it with a hand-tuned table is
	# what put us here. Say what is missing instead.
	var env = gs.native_environment() if gs != null and gs.has_method("native_environment") else null
	if env == null:
		return "FX: the native reader is not open, so no layer data is available"
	var fxd: Dictionary = env.request("fx_layers")
	if fxd.is_empty():
		return "FX: %s" % str(env.error)
	var rows: Array = fxd.get("layers", [])
	if rows.is_empty():
		var note := str(fxd.get("reader_note", ""))
		return "FX: this level reports no emitter layers%s" % \
			("" if note.is_empty() else " (%s)" % note)

	# The core names its own `has` bits, so nothing here has to know their order.
	var hb: Variant = fxd.get("has_bits")
	if hb is Dictionary:
		_has_bits = hb

	var by_effect := {}
	for r in rows:
		if not (r is Dictionary): continue
		var key := str((r as Dictionary).get("effect", "")).to_lower()
		if key.is_empty(): continue
		if not by_effect.has(key):
			by_effect[key] = []
		by_effect[key].append(r)

	_load_meshes()
	_prime_meshes(gs)
	var sun := _sun_of(root)

	# THE MATERIAL CACHE LASTS ONE BUILD, because a material BAKES THE SUN IN.
	# Lighting is computed in the shader from the level's own sun direction and
	# colour, so a material kept from an earlier build would light this map's
	# smoke with the previous map's sun - or with the sun as it was before
	# someone moved it. Both are wrong answers that look entirely plausible and
	# only show up on the SECOND build, which is the worst kind.
	#
	# Cheap to rebuild: it is a few hundred materials and the expensive part,
	# decoding the atlases, has its own cache that deliberately survives here
	# because a decoded sheet is the same texture whoever binds it.
	_mats.clear()

	# EVERY CANDIDATE FIRST, THEN THE TRIM. The budget has to see the whole list
	# to spread over it; deciding point by point can only truncate, and file
	# order is spatially clustered, so truncating empties most of the map.
	var cand: Array = []
	var unjoined := {}
	for f in points:
		if not (f is Dictionary): continue
		# Exclude ONLY the seasonal/gamemode-exclusive layer. `gamemode-layer`
		# is ordinary level content present in normal play.
		if str((f as Dictionary).get("source_class", "base")).begins_with("seasonal"):
			continue
		var nm := str((f as Dictionary).get("name", "")).to_lower()
		var ls: Variant = by_effect.get(nm)
		if ls == null:
			unjoined[nm] = true
			continue
		for L in (ls as Array):
			cand.append([f, L])

	var budget: PackedByteArray = PackedByteArray()
	var budget_from_core := false
	if env.core != null and env.core.has_method("fx_budget"):
		budget = env.core.call("fx_budget", cand.size(), 0)
		budget_from_core = budget.size() == cand.size()

	var holder := Node3D.new()
	holder.name = NODE
	root.add_child(holder)
	holder.owner = null

	var drawn := 0
	var trimmed := 0
	var decals := 0
	var meshes := 0
	var stretched := 0
	var lit_sixway := 0
	var faded := 0
	var no_draw := {}
	var slice := Time.get_ticks_msec()
	for i in range(cand.size()):
		if Time.get_ticks_msec() - slice >= 30:
			if progress.is_valid():
				progress.call(i, cand.size())
			if root.is_inside_tree():
				await root.get_tree().process_frame
			# Switching the layer back off, or closing the scene, frees the
			# holder underneath us: stop rather than parent onto a dead node.
			if not is_instance_valid(holder) or not holder.is_inside_tree():
				if progress.is_valid():
					progress.call(cand.size(), cand.size())
				return "FX cancelled"
			slice = Time.get_ticks_msec()
		if budget_from_core and budget[i] == 0:
			trimmed += 1
			continue

		var f: Dictionary = cand[i][0]
		var L: Dictionary = cand[i][1]
		var fam := str(L.get("family", "other"))
		# A FAMILY THAT DRAWS NOTHING, UNLESS IT NAMES A MESH. `creature` is
		# birds and rats: not billboards, but not missing either - they are
		# meshes, and the core now says which. The family rule is about what
		# kind of primitive to build, so the mesh takes precedence over it.
		if FAMILY_NONE.has(fam) and not _has_mesh(L):
			no_draw[fam] = int(no_draw.get(fam, 0)) + 1
			continue

		# The spawn point's transform, then the LAYER'S OWN OFFSET inside the
		# effect. Without the offset every layer of a fire stacks on the
		# placement origin and the column sits inside the flame.
		var pos: Array = f.get("pos", [0, 0, 0])
		var origin := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		var yaw := float(f.get("yaw", 0.0))
		var local: Array = L.get("local", [])
		var offset := Vector3.ZERO
		if local.size() >= 12:
			offset = Vector3(float(local[9]), float(local[10]), float(local[11]))
		var placed := origin + Basis(Vector3.UP, yaw) * offset

		if FAMILY_DECAL.has(fam):
			var dc := Decal.new()
			dc.size = DECAL_BOX
			dc.texture_albedo = _decal_texture()
			dc.modulate = _colour_of(L)
			dc.position = placed
			dc.rotation.y = yaw
			holder.add_child(dc)
			dc.owner = null
			decals += 1
			continue

		if not (FAMILY_QUAD.has(fam) or FAMILY_MESH.has(fam) or _has_mesh(L)):
			no_draw[fam] = int(no_draw.get(fam, 0)) + 1
			continue

		var e := _emitter(L, gs, sun)
		if e == null:
			no_draw[fam] = int(no_draw.get(fam, 0)) + 1
			continue
		e.position = placed
		e.rotation.y = yaw
		holder.add_child(e)
		e.owner = null
		drawn += 1
		if e.get_meta("bf6_mesh", false): meshes += 1
		if e.get_meta("bf6_sixway", false): lit_sixway += 1
		if e.get_meta("bf6_stretch", false): stretched += 1
		if e.get_meta("bf6_fade", false): faded += 1

	if progress.is_valid():
		progress.call(cand.size(), cand.size())

	var msg := "FX: %d emitters from %d layers over %d spawn points" % [
		drawn, rows.size(), points.size()]
	if lit_sixway > 0:
		msg += ", %d six-way lit" % lit_sixway
	if faded > 0:
		msg += ", %d with authored over-life fades" % faded
	if stretched > 0:
		msg += ", %d velocity-aligned" % stretched
	if meshes > 0:
		msg += ", %d drawing real debris geometry" % meshes
	if decals > 0:
		msg += ", %d volume decals" % decals
	if not no_draw.is_empty():
		var parts: Array = []
		for k in no_draw.keys():
			parts.append("%d %s" % [no_draw[k], FAMILY_NONE.get(k, k)])
		msg += ". Not drawn: %s" % ", ".join(parts)
	if not unjoined.is_empty():
		msg += ". %d effect(s) have no layer data" % unjoined.size()
	if trimmed > 0:
		msg += " - %d more trimmed by the core's budget" % trimmed
	elif not budget_from_core:
		msg += ". The core's budget was unavailable, so nothing was trimmed"
	return msg


# THE LEVEL'S OWN SUN, taken from the light the lighting builder made out of the
# game's authored azimuth, elevation and colour. Reading it back off the scene
# rather than re-deriving it is what keeps the FX lit by the same sun as
# everything else, including after someone nudges it.
static func _sun_of(root: Node) -> Dictionary:
	var best: DirectionalLight3D = null
	var stack: Array = [root]
	while not stack.is_empty() and best == null:
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is DirectionalLight3D:
				best = c
				break
			if c.get_child_count() > 0:
				stack.append(c)
	if best == null:
		# Said plainly rather than silently: overhead white light, which is
		# obviously not a real sun angle if it ever shows up.
		return {"dir": Vector3(0, -1, 0), "color": Color(1, 1, 1),
				"ambient": Color(0.35, 0.40, 0.48), "found": false}
	# A DirectionalLight3D shines along its local -Z.
	var dir: Vector3 = -best.global_transform.basis.z
	var amb := Color(0.35, 0.40, 0.48)
	var we := root.get_node_or_null("WorldEnvironment")
	if we is WorldEnvironment and (we as WorldEnvironment).environment != null:
		amb = (we as WorldEnvironment).environment.ambient_light_color
	return {"dir": dir.normalized(), "color": best.light_color,
			"ambient": amb, "found": true}


# The layer's authored tint, or white.
#
# A LAYER THAT AUTHORS NO COLOUR MUST NOT COME BACK BLACK. The core leaves an
# unauthored field at zero, so reading `color` without asking `has` first turns
# every layer that relies on its sheet's own colour - which is most of them,
# because findings/bf6-fx-colour-lives-in-texture says that is where the colour
# lives - into an invisible black card. White is the identity tint, which is
# what "this layer does not tint" means.
static func _colour_of(L: Dictionary) -> Color:
	if not _has(L, "color"):
		return Color(1, 1, 1, 1)
	var c: Array = L.get("color", [])
	if c.size() < 3:
		return Color(1, 1, 1, 1)
	# Game colours are LINEAR; Godot albedo and modulate want display space.
	return Color(_lin_to_srgb(float(c[0])), _lin_to_srgb(float(c[1])),
				 _lin_to_srgb(float(c[2])), 1.0)


# One authored linear colour as a display-space Color, or null when the layer
# did not state it. Null rather than white, because "not authored" and "white"
# lead to different decisions: a missing Color1 means there is no gradient at
# all, not a fade to white.
static func _linear_colour(L: Dictionary, field: String):
	if not _has(L, field):
		return null
	var c: Array = L.get(field, [])
	if c.size() < 3:
		return null
	return Color(_lin_to_srgb(float(c[0])), _lin_to_srgb(float(c[1])),
				 _lin_to_srgb(float(c[2])), 1.0)


static func _ramp(a: Color, b: Color) -> GradientTexture1D:
	var grad := Gradient.new()
	grad.set_color(0, a)
	grad.set_color(1, b)
	var tex := GradientTexture1D.new()
	tex.gradient = grad
	return tex


static func _lin_to_srgb(c: float) -> float:
	return 12.92 * c if c <= 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055


# WHICH FIELDS THE LAYER ACTUALLY STATED. `has` is the bitmask the core fills so
# a consumer can tell an authored 0 from a value the layer never set - a missing
# drag and a drag of 0 are two quite different looks, and reading the second as
# the first is how "no value" turns into a confident wrong one.
#
# The bit POSITIONS come down with the packet rather than being copied here, so
# inserting a field into the core's enum cannot silently shift what this reads.
static var _has_bits: Dictionary = {}

static func _has(L: Dictionary, field: String) -> bool:
	var bit: Variant = _has_bits.get(field)
	if bit == null:
		# The core did not name this field. Treat it as unauthored rather than
		# guessing a bit number, and let the value's own default stand.
		return false
	# THE MASK ARRIVES AS 32-BIT WORDS, not as one number. It is 128 bits wide
	# and JSON carries only doubles, which are exact to 2^53 - as a single value
	# the high bits would be silently rounded away, and the fields that vanished
	# would be the ones added most recently.
	var w: Array = L.get("has", [])
	var i := int(bit) >> 5
	if i >= w.size():
		return false
	return (int(w[i]) >> (int(bit) & 31)) & 1 != 0


static func _emitter(L: Dictionary, gs, sun: Dictionary) -> GPUParticles3D:
	var cfg := _build(L, gs, sun)
	if cfg.is_empty():
		return null
	var g := GPUParticles3D.new()
	g.process_material = cfg["process"]
	g.draw_pass_1 = cfg["mesh"]

	# THE LAYER'S OWN LIFETIME AND POPULATION. Godot has no spawn-rate knob:
	# the steady-state count on screen is amount/lifetime, so rate*life is the
	# population the authored rate produces.
	var life := float(L.get("particle_life", 0.0))
	if life <= 0.0 or life >= 1000.0:
		life = 4.0
	life = clampf(life, 0.05, MAX_LIFETIME)
	g.lifetime = life

	# HOW MANY PARTICLES EXIST AT ONCE - which is ParticleMaxCount, directly.
	#
	# This used to compute rate*life from a "spawn rate" field, and got a median
	# of FIVE particles per emitter: a smoke column made of five big spinning
	# cards, which is exactly what it looked like. The mistake was looking for a
	# rate at all. A continuous emitter's config holds no float rate - dumping
	# every field of SpawnModeContinuous gives an initial count of 1, a clamp
	# ceiling of 10000, and ParticleMaxCount; and the SpawnRate PARAMETER has
	# zero shipped overrides, so it is not authored anywhere either. A
	# continuous emitter simply sustains ParticleMaxCount over the particle's
	# lifetime, and Godot's `amount` means precisely "how many exist", so the
	# two line up with no arithmetic in between.
	#
	# Measured on MP_Isolated: 285 of 336 continuous layers author 64, against
	# the 5 the old reading produced.
	var amount := int(L.get("particle_max", 0))
	if amount <= 0:
		amount = 16
	if str(L.get("spawn_mode", "")) == "SpawnModeBurst":
		# A burst emits its whole population at once and stops.
		g.one_shot = true
		g.explosiveness = 1.0
	g.amount = clampi(amount, 1, MAX_PARTICLES)

	# THE GAME'S OWN CULL DISTANCE where it authors one.
	# PREROLL. A smoke column that has been burning since the round started is
	# not a column that begins at its source and grows - the game simulates
	# `preroll_time` seconds before the first frame, which is why a plume is
	# already full height when you first see it. Without this every fire on the
	# map visibly starts up the moment it is built.
	var preroll := float(L.get("preroll_time", 0.0))
	if preroll > 0.0:
		g.preprocess = clampf(preroll, 0.0, MAX_LIFETIME)

	var vr := float(L.get("cull_distance", 0.0))
	if vr <= 0.0:
		vr = 300.0
	vr = clampf(vr, RANGE_MIN, RANGE_MAX)
	g.visibility_range_end = vr
	g.visibility_range_end_margin = 40.0
	g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	var reach := maxf(float(L.get("base_size", 1.0)) * 4.0, 12.0)
	g.visibility_aabb = AABB(Vector3(-reach, -reach * 0.2, -reach),
							 Vector3(reach * 2.0, reach * 2.0, reach * 2.0))
	g.set_meta("vr", vr)
	g.set_meta("bf6_mesh", cfg.get("is_mesh", false))
	g.set_meta("bf6_sixway", cfg.get("sixway", false))
	g.set_meta("bf6_stretch", cfg.get("stretch", false))
	g.set_meta("bf6_fade", cfg.get("fade", false))
	return g


# The process material and draw mesh for ONE layer. Cached on everything that
# can differ between layers, which after this rewrite is most of the row: two
# layers of the same graph legitimately differ in almost every value, so a
# coarse key would hand the first one's look to all the rest - the same cache
# bug the untextured materials had, one level up.
static func _build(L: Dictionary, gs, sun: Dictionary) -> Dictionary:
	var ck := "%s|%d|%s" % [str(L.get("effect", "")), int(L.get("layer", 0)),
							str(L.get("atlas_res", ""))]
	if _mats.has(ck):
		return _mats[ck]

	var fam := str(L.get("family", "other"))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.5
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0

	# MOTION IS THE PATH. An FX references no animation clip and no spline -
	# measured over every import reachable from every emitter graph on three
	# levels, 25 distinct assets and not one of them is an animation, skeleton,
	# spline or curve (findings/fx-reference-no-animation-or-path-assets). A
	# missile's arc and a bird's circle are the INTEGRAL of these forces, so
	# implementing them exactly is implementing the motion exactly.
	var speed := float(L.get("spawn_speed", 0.0)) if _has(L, "spawn_speed") else 0.0
	# The authored speed RANGE, not a made-up half. SpawnSpeedMult is a Vec2
	# min/max multiplier and SpawnSpeedMinMult the low end on its own; the old
	# code used speed*0.5 for the minimum, which is a guess that happens to look
	# reasonable and is authored 15,502 times.
	# THE SPEED RANGE - and NOT a product of every multiplier in sight.
	#
	# This compounded SpawnSpeed x SpawnSpeedMult x SpeedMult, which is how a
	# 1 m/s smoke puff became 120 m/s and why everything shot off the screen.
	# SpawnSpeedMult really is a Vec2 min/max on the spawn speed - authored
	# (3,24), (15,20), (8,16) - so it is used. SpeedMult is NOT established as a
	# multiplier of spawn speed: it is authored on 59 layers with a median of 5
	# and a maximum of 5000, and nothing that multiplies a velocity has a range
	# like that. Guessing cost more than leaving it out, so it is left out and
	# said so rather than quietly folded in.
	var lo_mult := 1.0
	var hi_mult := 1.0
	if _has(L, "spawn_speed_mult"):
		var sm: Array = L.get("spawn_speed_mult", [])
		if sm.size() >= 2:
			lo_mult = float(sm[0])
			hi_mult = float(sm[1])
	elif _has(L, "spawn_speed_min_mult"):
		# The low end on its own; the high end stays at the authored speed.
		lo_mult = float(L.get("spawn_speed_min_mult", 1.0))
	var v_lo := absf(speed) * minf(lo_mult, hi_mult)
	var v_hi := absf(speed) * maxf(lo_mult, hi_mult)
	# A PREVIEW CEILING, stated rather than hidden. A few layers really do
	# author hundreds of metres per second - tracers and shockwaves - and drawn
	# literally they cross the whole map between two frames and read as noise.
	# The units are also not independently established, so this is a bound on a
	# number we are not certain of.
	pm.initial_velocity_min = clampf(v_lo, 0.0, MAX_SPEED)
	pm.initial_velocity_max = clampf(v_hi, 0.0, MAX_SPEED)

	# Drag is the game's damping, and it has a RANGE too. An authored 0 is a
	# real value meaning no drag at all, which is why this asks `has` rather
	# than treating 0 as absent.
	if _has(L, "drag"):
		var drag := float(L.get("drag", 0.0))
		pm.damping_max = drag
		pm.damping_min = drag * float(L.get("drag_min_mult", 1.0)) 			if _has(L, "drag_min_mult") else drag

	# A smoke column does NOT rise from its initial velocity: that is Buoyancy,
	# a force applied over life. Driving rise from speed is wrong in a way that
	# looks almost right.
	#
	# Both gravity and buoyancy carry a cubic over the particle's life. Godot's
	# gravity is one constant vector, so the curve is evaluated at MID-LIFE
	# rather than dropped: the average behaviour of the authored curve beats
	# both its start value and ignoring it, and this says which it is doing.
	var gy := 0.0
	if _has(L, "gravity"):
		gy += float(L.get("gravity", 0.0))
	if _has(L, "buoyancy"):
		var b := float(L.get("buoyancy", 0.0))
		if _has(L, "buoyancy_over_life"):
			b *= _cubic_at(L.get("buoyancy_over_life", []), 0.5)
		gy += b

	# LocalForce is a constant directed push in the emitter's own space - the
	# term that makes a vent blow sideways and a UAV circle. It is a Vec3, so it
	# goes into the gravity vector beside the vertical terms rather than being
	# flattened into one of them.
	var force := Vector3(0.0, gy, 0.0)
	if _has(L, "local_force"):
		var lf: Array = L.get("local_force", [])
		if lf.size() >= 3:
			var f := Vector3(float(lf[0]), float(lf[1]), float(lf[2]))
			if _has(L, "local_force_over_life"):
				f *= _cubic_at(L.get("local_force_over_life", []), 0.5)
			force += f
	# The same ceiling reasoning as the speed: Buoyancy is authored as low as
	# -100 and LocalForce as (-10, 5, 1), and a preview that accelerates a card
	# at 100 m/s^2 shows a streak rather than an effect. Clamped by MAGNITUDE so
	# the authored DIRECTION survives, which is the part that reads.
	if force.length() > MAX_FORCE:
		force = force.normalized() * MAX_FORCE
	pm.gravity = force

	# RandomForce is the turbulence a plume curls with, authored on 18,590
	# layers. Godot's turbulence is the closest primitive it has; the strength
	# is scaled because Godot's noise field is unit-amplitude while the game's
	# is a force in metres per second squared.
	if _has(L, "random_force"):
		var rf := absf(float(L.get("random_force", 0.0)))
		if _has(L, "random_force_over_life"):
			rf *= absf(_cubic_at(L.get("random_force_over_life", []), 0.5))
		if rf > 0.0:
			pm.turbulence_enabled = true
			pm.turbulence_noise_strength = clampf(rf * 0.1, 0.0, 10.0)
			pm.turbulence_noise_scale = 2.0

	# DirectionFromEmitterOrigin 1.0 is a radial burst - every particle leaves
	# along its own offset from the centre - and 0 is the emitter's own axis.
	if _has(L, "direction_from_origin") and float(L.get("direction_from_origin", 0.0)) > 0.5:
		pm.spread = 180.0
	if _has(L, "rotation_speed"):
		var rs := float(L.get("rotation_speed", 0.0))
		if _has(L, "rotation_speed_bias"):
			rs += float(L.get("rotation_speed_bias", 0.0))
		pm.angular_velocity_min = -rs
		pm.angular_velocity_max = rs
	# The authored spawn rotation, in radians, rather than a blanket +/-180.
	if _has(L, "spawn_rotation_min") or _has(L, "spawn_rotation_max"):
		var rmin: Array = L.get("spawn_rotation_min", [])
		var rmax: Array = L.get("spawn_rotation_max", [])
		pm.angle_min = rad_to_deg(float(rmin[2])) if rmin.size() >= 3 else -180.0
		pm.angle_max = rad_to_deg(float(rmax[2])) if rmax.size() >= 3 else 180.0
	elif _has(L, "rotation_speed"):
		pm.angle_min = -180.0
		pm.angle_max = 180.0

	# THE SPAWN VOLUME, AUTHORED. A fixed half-metre sphere for everything was a
	# placeholder: SpawnScale is the box the particles are born in and
	# SpawnPosition its offset, and a ground fog sheet and a torch flame are not
	# the same shape. OuterRadius/InnerRadius describe the sphere and cone
	# emitters instead.
	if _has(L, "spawn_scale"):
		var ss: Array = L.get("spawn_scale", [])
		if ss.size() >= 3:
			pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			pm.emission_box_extents = Vector3(
				maxf(absf(float(ss[0])), 0.01), maxf(absf(float(ss[1])), 0.01),
				maxf(absf(float(ss[2])), 0.01))
	elif _has(L, "outer_radius"):
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		pm.emission_sphere_radius = maxf(float(L.get("outer_radius", 0.5)), 0.01)
	if _has(L, "spawn_position"):
		var sp: Array = L.get("spawn_position", [])
		if sp.size() >= 3:
			pm.emission_shape_offset = Vector3(
				float(sp[0]), float(sp[1]), float(sp[2]))

	var align := int(L.get("alignment", -1))
	var stretch := align == ALIGN_SCREEN_STRETCH or align == 1
	if stretch:
		# Directional and ScreenStretch orient the card along the particle's
		# travel. Godot expresses that on the PROCESS side, by turning the
		# particle's +Y to follow its velocity; the shader then billboards
		# around that axis rather than facing the camera flat.
		pm.set_particle_flag(ParticleProcessMaterial.PARTICLE_FLAG_ALIGN_Y_TO_VELOCITY, true)

	# THE SHEET, resolved by the RES the core says the layer binds. The grid is
	# AUTHORED in the atlas's own EBX and comes down with the layer, so nothing
	# here is inferred from a filename.
	var res := str(L.get("atlas_res", ""))
	var tex: Texture2D = _sheet(gs, res)
	var lr := int(L.get("atlas_left_right", 0)) != 0
	var light := int(L.get("lighting_model", -1))

	# Emissive layers - fire, sparks, muzzle flash - add light rather than
	# compositing over what is behind them.
	var additive := light == LIGHT_EMISSIVE or fam == "sparks"
	var sm := ShaderMaterial.new()
	sm.shader = _load_shader(additive)
	sm.set_shader_parameter("sheet", tex)
	sm.set_shader_parameter("has_sheet", tex != null)
	sm.set_shader_parameter("left_right", lr)
	sm.set_shader_parameter("cols", maxi(int(L.get("atlas_cols", 1)), 1))
	sm.set_shader_parameter("frames", maxi(int(L.get("atlas_frames", 1)), 1))
	sm.set_shader_parameter("frame_blend", int(L.get("disable_frame_blend", 0)) == 0)
	sm.set_shader_parameter("align_mode", maxi(align, 0))
	sm.set_shader_parameter("sun_direction", sun["dir"])
	sm.set_shader_parameter("sun_color", sun["color"])
	sm.set_shader_parameter("ambient_color", sun["ambient"])
	# The authored light scales. A layer that states none gets 1.0, which is
	# this file saying "unscaled" rather than inventing a different number.
	sm.set_shader_parameter("sun_scale",
		float(L.get("sun_light", 1.0)) if _has(L, "sun_light") else 1.0)
	sm.set_shader_parameter("ambient_scale",
		float(L.get("ambient_light", 1.0)) if _has(L, "ambient_light") else 1.0)
	sm.set_shader_parameter("backlight",
		float(L.get("gnomon_backlight", 0.0)) if _has(L, "gnomon_backlight") else 0.0)
	sm.set_shader_parameter("tint", _colour_of(L))
	# THE COLOUR RANGE. Color0..Color1 is a gradient over the particle's life and
	# RandomColorMin..Max a per-particle tint, authored on 16,276 and 13,683
	# layers. A single flat colour is what made every fire the same orange.
	# These go on the PROCESS material, which is where Godot varies colour per
	# particle and over life.
	# Untyped on purpose: _linear_colour returns a Color OR null, and null is
	# the answer that matters - "the layer authored no gradient" is different
	# from "the gradient is white".
	var g0: Variant = _linear_colour(L, "color0")
	var g1: Variant = _linear_colour(L, "color1")
	if g0 != null and g1 != null:
		pm.color_ramp = _ramp(g0, g1)
	var r0: Variant = _linear_colour(L, "random_color_min")
	var r1: Variant = _linear_colour(L, "random_color_max")
	if r0 != null and r1 != null and r0 != r1:
		pm.color_initial_ramp = _ramp(r0, r1)
	sm.set_shader_parameter("opacity",
		clampf(float(L.get("opacity", 1.0)), 0.0, 1.0) if _has(L, "opacity") else 1.0)
	sm.set_shader_parameter("alpha_cull",
		float(L.get("alpha_cull", 0.0)) if _has(L, "alpha_cull") else 0.0)

	# THE OVER-LIFE CURVES, as cubics in the particle's normalised age. See
	# findings/fx-over-life-fields-are-cubic-coefficients: four floats over a
	# life reads naturally as four keyframes and is not - only 14 of 518 layers
	# have all four values inside a plausible opacity range, while 440 of 518
	# describe a sane curve.
	var fade := false
	if _has(L, "opacity_over_life"):
		var oc: Array = L.get("opacity_over_life", [])
		if oc.size() >= 4:
			sm.set_shader_parameter("opacity_curve",
				Vector4(float(oc[0]), float(oc[1]), float(oc[2]), float(oc[3])))
			fade = true
	sm.set_shader_parameter("flip_u_probability",
		clampf(float(L.get("flip_u_probability", 0.0)), 0.0, 1.0) if _has(L, "flip_u_probability") else 0.0)
	sm.set_shader_parameter("flip_v_probability",
		clampf(float(L.get("flip_v_probability", 0.0)), 0.0, 1.0) if _has(L, "flip_v_probability") else 0.0)
	sm.set_shader_parameter("pivot_y",
		clampf(float(L.get("pivot_y", 0.0)), -1.0, 1.0) if _has(L, "pivot_y") else 0.0)
	sm.set_shader_parameter("camera_bias",
		clampf(float(L.get("camera_bias", 0.0)), -5.0, 5.0) if _has(L, "camera_bias") else 0.0)
	sm.set_shader_parameter("inv_z_fade",
		maxf(float(L.get("inv_z_fade", 0.0)), 0.0) if _has(L, "inv_z_fade") else 0.0)
	sm.set_shader_parameter("backlight_contrast",
		maxf(float(L.get("backlight_contrast", 1.0)), 0.01) if _has(L, "backlight_contrast") else 1.0)
	# SizeCurve is authored on 5,898 layers and SizeOverLife on 118; both are
	# the same cubic, so whichever the layer states drives the card's growth.
	for key in ["size_curve", "size_over_life"]:
		if _has(L, key):
			var sc: Array = L.get(key, [])
			if sc.size() >= 4:
				sm.set_shader_parameter("size_curve",
					Vector4(float(sc[0]), float(sc[1]), float(sc[2]), float(sc[3])))
				sm.set_shader_parameter("size_curve_on", true)
				break
	if _has(L, "rotation_over_life"):
		var rc: Array = L.get("rotation_over_life", [])
		if rc.size() >= 4:
			sm.set_shader_parameter("rotation_curve",
				Vector4(float(rc[0]), float(rc[1]), float(rc[2]), float(rc[3])))
			sm.set_shader_parameter("rotation_curve_on", true)

	# THE LAYER'S OWN SIZE. fx_params shipped 1.0 for everything because it read
	# the graph TEMPLATE, where BaseSize is exactly 1.0 on all 45 templates that
	# carry one; the authored size lives on the layer. Against the real values
	# the old class table had smoke about 2x too small and sparks up to 100x too
	# LARGE - a 2 cm spark drawn as a 3 m square is what "cubes everywhere" was.
	var size := float(L.get("base_size", 1.0)) if _has(L, "base_size") else 1.0
	size = clampf(size, 0.01, 60.0)

	var out := {"process": pm, "sixway": lr and light != LIGHT_EMISSIVE,
				"stretch": stretch, "fade": fade, "is_mesh": false}

	# MESH PARTICLES: missiles, UAVs, aircraft vapour, birds and debris.
	#
	# These draw GEOMETRY, not a billboard, and until the core read the
	# template's EmitterMesh import they drew nothing at all - 284 creature and
	# 157 debris_mesh layers on MP_Isolated. The mesh name now comes down with
	# the layer, so this no longer consults a per-graph majority table.
	#
	# `mesh_is_placeholder` is the core saying the template imports the 3-vertex
	# stand-in the game expects each effect to substitute. Drawing that would put
	# a triangle where a wood shard belongs, so those are still skipped and
	# counted - the substitution itself is not decoded yet. mesh_for returns the
	# mesh already dressed through the depot, so what does draw arrives textured
	# rather than tinted.
	if FAMILY_MESH.has(fam) or _has_mesh(L):
		if int(L.get("mesh_is_placeholder", 0)) != 0:
			return {}
		var gm: Variant = _mesh_of(L, gs)
		if gm is Mesh:
			out["mesh"] = gm
			out["is_mesh"] = true
			_mats[ck] = out
			return out
		# No mesh resolved: a quad standing in for a shard is a wrong answer.
		return {}

	# DRAW ORDER, the game's own. Transparent cards are drawn back to front
	# within a priority, and the layer says which priority it belongs to: a fire
	# authored to sit in front of its own smoke does not get to be behind it
	# because the two happened to be built in the wrong order.
	sm.render_priority = clampi(int(L.get("draw_layer", 0)), -128, 127)

	var qm := QuadMesh.new()
	# SizeY is a SEPARATE authored parameter, so a card can be taller than it is
	# wide - a flame lick and a ground splat are not both squares.
	var size_y := size
	if _has(L, "size_y"):
		size_y = clampf(float(L.get("size_y", size)), 0.01, 60.0)
	elif _has(L, "size_y_mult"):
		size_y = clampf(size * float(L.get("size_y_mult", 1.0)), 0.01, 60.0)
	qm.size = Vector2(size, size_y)
	qm.material = sm
	out["mesh"] = qm
	_mats[ck] = out
	return out


# f(t) = a*t^3 + b*t^2 + c*t + d, the game's over-life encoding.
#
# See findings/fx-over-life-fields-are-cubic-coefficients. Used here for the
# terms Godot can only take as a constant, evaluated at mid-life: the average
# behaviour of the authored curve is closer than either its start value or
# ignoring it, and doing it in one named place is what makes that choice
# visible rather than scattered.
static func _cubic_at(k, t: float) -> float:
	if not (k is Array) or (k as Array).size() < 4:
		return 1.0
	var a: Array = k
	return ((float(a[0]) * t + float(a[1])) * t + float(a[2])) * t + float(a[3])


static func _has_mesh(L: Dictionary) -> bool:
	return not str(L.get("mesh", "")).is_empty()


# The layer's own mesh, resolved once per distinct mesh name.
static func _mesh_of(L: Dictionary, gs) -> Variant:
	var name := str(L.get("mesh", ""))
	if name.is_empty() or gs == null or gs.src == null or not gs.has_method("mesh_for"):
		# Falls back to the old per-graph table only when the core named none,
		# so an install without the new reader still draws what it used to.
		return _meshes.get(_graph_leaf(L))
	if not _meshes.has(name):
		_meshes[name] = gs.mesh_for(name)
	return _meshes[name]


static func _graph_leaf(L: Dictionary) -> String:
	var g := str(L.get("graph", ""))
	return g.get_file().to_lower() if g.contains("/") else g.to_lower()


static func _load_shader(additive: bool) -> Shader:
	if additive:
		if _shader_add == null:
			_shader_add = load(SHADER_ADD_PATH) as Shader
		return _shader_add
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	return _shader


# One sheet, decoded whole. NOT folded: the shader reads both halves, which is
# the entire point of the six-way work.
static func _sheet(gs, res: String) -> Texture2D:
	if res.is_empty():
		return null
	if _sheet_by_res.has(res):
		return _sheet_by_res[res]
	_sweep_stale_cache()
	var stem := BF6Atlas.norm_stem(res)
	if stem.is_empty():
		return null
	var png := "%s/%s.e%d.png" % [SHEET_CACHE, stem, SHEET_EPOCH]
	if FileAccess.file_exists(png):
		var ci := Image.new()
		if ci.load_png_from_buffer(FileAccess.get_file_as_bytes(png)) == OK:
			var t := ImageTexture.create_from_image(ci)
			_sheet_by_res[res] = t
			return t
	if gs == null or gs.src == null:
		# DO NOT MEMOISE A MISS THAT ONLY HAPPENED FOR WANT OF A SOURCE. FX can
		# be switched on before the map has been read, and caching the empty
		# answer then means the sheet never appears for the rest of the session.
		return null
	var rn := res if gs.src.res.has(res) else BF6Atlas.find_res(gs.src, res)
	if rn.is_empty():
		_sheet_by_res[res] = null
		return null
	var hdr := BF6Atlas.parse(gs.src.get_res(rn))
	if hdr.is_empty():
		_sheet_by_res[res] = null
		return null
	var level := 0
	var sizes: Array = hdr["sizes"]
	while level + 1 < sizes.size() and (int(hdr["width"]) >> level) > SHEET_MAX:
		level += 1
	var img := BF6Atlas.mip_image(gs.src, hdr, level)
	if img == null:
		_sheet_by_res[res] = null
		return null
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	DirAccess.make_dir_recursive_absolute(SHEET_CACHE)
	img.save_png(png)
	var tex := ImageTexture.create_from_image(img)
	_sheet_by_res[res] = tex
	return tex


# Drop sheets decoded by an older epoch, once per session.
static func _sweep_stale_cache() -> void:
	if _swept:
		return
	_swept = true
	var dir := DirAccess.open(SHEET_CACHE)
	if dir == null:
		return
	var keep := ".e%d.png" % SHEET_EPOCH
	for f in dir.get_files():
		if (f.ends_with(".png") or f.ends_with(".json")) and not f.ends_with(keep):
			dir.remove(f)


static func _load_meshes() -> void:
	if _meshes_loaded:
		return
	_meshes_loaded = true
	if not FileAccess.file_exists(MESHES_PATH):
		return
	var mt: Variant = JSON.parse_string(FileAccess.get_file_as_string(MESHES_PATH))
	if mt is Dictionary:
		_meshtbl = mt


static func _prime_meshes(gs) -> int:
	if gs == null or gs.src == null or not gs.has_method("mesh_for"):
		return 0
	var by_res := {}
	for g in _meshtbl.keys():
		if _meshes.has(g):
			continue
		var rec: Variant = _meshtbl[g]
		if not (rec is Dictionary):
			continue
		var rn := str((rec as Dictionary).get("mesh", ""))
		if rn.is_empty():
			continue
		if not by_res.has(rn):
			by_res[rn] = gs.mesh_for(rn)
		_meshes[g] = by_res[rn]
	var n := 0
	for g in _meshes.keys():
		if _meshes[g] != null:
			n += 1
	return n


# A soft radial falloff for the volume decals.
#
# STAND-IN, AND SAID SO. The scorch and soot marks have no decal texture
# anywhere in the EBX - an exhaustive walk of 592 graph partitions found no decal
# texture field at all, and the mark's art lives inside the compiled GraphEmVSF
# shader. This is a generated gradient, not game art and not something
# downloaded; it carries the authored COLOUR and the authored BOX, which are
# real, and makes no claim about the pattern.
static func _decal_texture() -> Texture2D:
	if _decal_tex != null:
		return _decal_tex
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in range(n):
		for x in range(n):
			var dd := Vector2(x - c, y - c).length() / c
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - dd * dd, 0.0, 1.0)))
	_decal_tex = ImageTexture.create_from_image(img)
	return _decal_tex


# Range-slider tie-in: clamp every emitter's draw distance to the dock's Range
# value, never past the layer's own authored cull distance. 0 hides FX entirely.
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
