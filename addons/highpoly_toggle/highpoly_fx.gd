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
# passing for authored data - and deliberately with no sheet, because lending a
# graph some other graph's flipbook is the kind of plausible wrong answer that
# never gets reported.
const CLASS_FALLBACK := {
	"fire":     {"lifetime_s": 5.0, "base_size": 2.4, "render": "emissive",
				 "color": [1.0, 0.55, 0.2, 1.0]},
	"smoke":    {"lifetime_s": 5.0, "base_size": 4.0, "render": "sixway",
				 "color": [0.32, 0.31, 0.30, 0.75]},
	"dust":     {"lifetime_s": 4.0, "base_size": 3.0, "render": "lit",
				 "color": [0.55, 0.5, 0.44, 0.5]},
	"electric": {"lifetime_s": 0.6, "base_size": 0.35, "render": "emissive",
				 "color": [1.0, 0.72, 0.35, 1.0]},
	"other":    {"lifetime_s": 3.0, "base_size": 1.0, "render": "lit",
				 "color": [0.8, 0.8, 0.8, 0.6]},
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
static func apply(root: Node, map: String, on: bool, progress := Callable(),
		gs = null) -> String:
	clear(root)
	if root == null: return "No scene open"
	if not on: return "FX off"
	_load_params()
	# Sheets first, so no material is baked untextured and then cached (see
	# _prime_sheets). Cheap after the first run: they are cached as PNG.
	var n_sheets := _prime_sheets(gs)
	var n_want := 0
	var seen_sheets := {}
	for k in _params.keys():
		if _params[k] is Dictionary:
			var sh := str((_params[k] as Dictionary).get("sheet", ""))
			if sh != "" and not seen_sheets.has(sh):
				seen_sheets[sh] = true
				n_want += 1
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
	msg += ", %d of %d flipbooks from the game" % [n_sheets, n_want]
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


# THE SHEETS USED TO SHIP INSIDE THE ADDON, and they were Battlefield art:
# fire_6x36.png and smoke_8x64.png, 5.5 MB of it, so every install handed
# someone a copy of EA's textures. Deleting the files was not enough either -
# this went on POINTING at addons/highpoly_toggle/fx_textures, and an install
# that still had the old copies went on drawing them, untracked by git and
# invisible to every parity check.
#
# They now come out of the player's own installation, decoded from the
# AtlasTexture the graph names. Nothing is bundled and nothing is downloaded.
static var _sheets: Dictionary = {}     # graph `sheet` value -> Texture2D or null
const SHEET_CACHE := "user://fxsheets"
# Cap on the usable width AFTER the LeftRightTiles crop. The mip chain is right
# there in the header, so a smaller sheet is a smaller mip of the game's own
# texture rather than a resample of the largest one.
const SHEET_MAX := 1024


# Six directional lighting terms folded down to one flat card.
#
# A LeftRightTiles sheet is a six-way lightmap: the same frames twice, and the
# halves are the two signs, so `L.rgb` is three directions and `R.rgb` is their
# three opposites (findings/atlastexture-grid-and-sixway-packing). Opposing
# terms sum to the total light arriving at that texel, so averaging the halves
# gives the directionally averaged lighting - which is exactly what a billboard
# with no six-way shader should show. Alpha comes from the LEFT half only: that
# is the density, proved by a sheet whose right alpha is entirely empty while
# the effect plainly renders.
#
# Done over the raw byte buffer rather than get_pixel/set_pixel, which is the
# difference between milliseconds and a visible stall, and the result is cached
# to disk so it happens once per sheet ever.
static func _fold_sixway(img: Image) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	@warning_ignore("integer_division")
	var half := w / 2
	if half < 1:
		return img
	var s := img.get_data()
	var out := PackedByteArray()
	out.resize(half * h * 4)
	for y in range(h):
		var row := y * w * 4
		var orow := y * half * 4
		for x in range(half):
			var li := row + x * 4
			var ri := row + (half + x) * 4
			var oi := orow + x * 4
			out[oi] = (s[li] + s[ri]) >> 1
			out[oi + 1] = (s[li + 1] + s[ri + 1]) >> 1
			out[oi + 2] = (s[li + 2] + s[ri + 2]) >> 1
			out[oi + 3] = s[li + 3]
	return Image.create_from_data(half, h, false, Image.FORMAT_RGBA8, out)


static func _decode_sheet(gs, sheet: String) -> Texture2D:
	var stem := BF6Atlas.norm_stem(sheet)
	if stem == "":
		return null
	var png := "%s/%s.png" % [SHEET_CACHE, stem]
	if FileAccess.file_exists(png):
		var ci := Image.new()
		if ci.load_png_from_buffer(FileAccess.get_file_as_bytes(png)) == OK:
			return ImageTexture.create_from_image(ci)
	if gs == null or gs.src == null:
		return null
	var rn := BF6Atlas.find_res(gs.src, sheet)
	if rn == "":
		return null
	var hdr := BF6Atlas.parse(gs.src.get_res(rn))
	if hdr.is_empty():
		return null
	var g := BF6Atlas.grid(gs.src, gs.types,
		gs.walk.gi if gs.walk != null else {}, rn)
	var lr := bool(g.get("lr", false))
	var level := 0
	var sizes: Array = hdr["sizes"]
	while level + 1 < sizes.size():
		@warning_ignore("integer_division")
		var uw := (int(hdr["width"]) >> level) / (2 if lr else 1)
		if uw <= SHEET_MAX:
			break
		level += 1
	var img := BF6Atlas.mip_image(gs.src, hdr, level)
	if img == null:
		return null
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if lr:
		img = _fold_sixway(img)
	DirAccess.make_dir_recursive_absolute(SHEET_CACHE)
	img.save_png(png)
	return ImageTexture.create_from_image(img)


# Resolve every sheet the graph table names, BEFORE any emitter is built.
#
# Doing it up front is what keeps the `_mats` cache honest: resolve lazily and
# the first emitter of a graph bakes an untextured material that every later
# one then reuses, so a sheet that became available a moment later never
# appears. Returns how many resolved.
static func _prime_sheets(gs) -> int:
	var seen := {}
	var added := false
	for k in _params.keys():
		var d: Variant = _params[k]
		if not (d is Dictionary):
			continue
		var sh := str((d as Dictionary).get("sheet", ""))
		# graphs share sheets - count the DISTINCT ones, not the references
		if sh == "" or seen.has(sh):
			continue
		seen[sh] = true
		if not _sheets.has(sh):
			var t := _decode_sheet(gs, sh)
			# DO NOT MEMOISE A MISS THAT ONLY HAPPENED FOR WANT OF A SOURCE.
			# FX can be switched on before the map has been read, and caching
			# the null then means the sheet never appears for the rest of the
			# session even once the source is open - the same shape of bug as
			# _obj_cache remembering NOT-FOUND.
			if t != null or (gs != null and gs.src != null):
				_sheets[sh] = t
				added = true
	var found := 0
	for sh in seen.keys():
		if _sheets.get(sh) != null:
			found += 1
	if added:
		_mats.clear()       # materials built before this would have no texture
	return found


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

	var sheet := str((gp as Dictionary).get("sheet", "")) if gp is Dictionary else ""
	var tex: Texture2D = _sheets.get(sheet)
	if tex != null:
		dm.albedo_texture = tex
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
