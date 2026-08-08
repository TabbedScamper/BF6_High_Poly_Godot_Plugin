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
	var n_meshes := _prime_meshes(gs)
	var n_want := _sheet_by_res.size()
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
	var nonsprite := 0
	var decals := 0
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
		# fx.json's `name` IS the effect blueprint, which is what the sheet is
		# really keyed on. Without it the backdrop columns fall back to a
		# per-graph majority and get somebody else's smoke.
		var nm := str(f.get("name", ""))
		var cls := str(f.get("class", ""))
		if not CLASS_FALLBACK.has(cls):
			cls = "other"               # never drop a spawn point
		var effect := str(f.get("effect", ""))
		var gp: Variant = _params.get(effect.to_upper())
		if gp != null:
			authored += 1

		# ONLY SPRITE EMITTERS GET A BILLBOARD.
		#
		# A spawn point with no flipbook was still drawing a quad, filled with
		# the class fallback colour - hundreds of solid orange and white squares
		# standing in for effects that are not billboards at all. The families
		# without a sheet are not missing art, they are a different kind of
		# effect: sparks, volumedecals, thindebris, meshdebris, sand, pebbles,
		# lights, birds, rats, and two graphs the game itself calls `dummy`.
		# Only `globalsorting` is the sprite smoke and fire family, and 40 of
		# its 41 graphs carry a sheet.
		#
		# So draw what can be drawn correctly and COUNT the rest into the status
		# line. A coloured square that reads as a solid lit cube is a wrong
		# answer; nothing, said out loud, is an honest one.
		# VOLUME DECALS GET A DECAL, NOT A BILLBOARD. All 34 projection meshes
		# measure exactly +/-1, so the real extent is the emitter transform's
		# basis scale and the flattened axis is always Y. fx.json records only
		# position and yaw, so the box falls back to the commonest authored
		# scale rather than being invented per point.
		if gp is Dictionary and str((gp as Dictionary).get("family", "")) == "volumedecals":
			var pos2: Array = f.get("pos", [0, 0, 0])
			var dc := Decal.new()
			dc.size = DECAL_BOX
			dc.texture_albedo = _decal_texture()
			dc.modulate = _colour_of(gp, CLASS_FALLBACK[cls])
			dc.position = Vector3(pos2[0], pos2[1], pos2[2])
			dc.rotation.y = float(f.get("yaw", 0.0))
			holder.add_child(dc)
			dc.owner = null
			decals += 1
			continue

		if not _drawable(nm, effect, gp):
			nonsprite += 1
			continue

		var pos: Array = f.get("pos", [0, 0, 0])
		var e := _emitter(cls, effect, gp, _sheet_res(nm, effect))
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
	if n_meshes > 0:
		msg += ", %d graphs draw real debris geometry" % n_meshes
	if decals > 0:
		msg += ", %d volume decals" % decals
	if nonsprite > 0:
		msg += ". %d points are mesh, decal, spark or light effects rather than billboards, and are not drawn" % nonsprite
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
static var _sheets: Dictionary = {}     # lowercase graph name -> sheet dict or null
static var _sheet_tbl: Dictionary = {}  # lowercase graph name -> {sheet, n, total, distinct}
static var _sheet_tbl_loaded := false
# THE SHEET IS A PER-EFFECT PROPERTY, NOT A PER-GRAPH ONE. Measured over 17,643
# emitter rows from the effect blueprints: 68 distinct atlases are actually
# bound, and 58 graphs bind more than one. eg_gs_basicsmoke_01 alone uses 31
# different sheets across the effects that instance it. fx_params.json records
# a single sheet per graph, which is why 44 graphs got one and the rest got
# nothing.
#
# fx.json identifies a spawn point by its GRAPH, so a per-effect sheet is not
# reachable from what the map walk records. This table is the honest middle: the
# sheet MOST OFTEN bound for each graph, with the sample counts kept so the
# status line can admit how firm the pick is. It covers 103 graphs against 44.
const SHEETS_PATH := "res://addons/highpoly_toggle/fx_sheets.json"
# PER-EFFECT SHEETS, which beat the per-graph majority whenever we know the
# effect. fx.json's `name` field IS the effect blueprint
# (fx_backdrop_mp_aftermath_firesmokecolumn_l_01), so the distant backdrop
# columns can be resolved exactly instead of averaged: they bind
# t_smokethick_02_tg1_4x32f, which no majority over eg_gs_basicsmoke_preroll_01
# would ever have picked. Keyed "<effect>|<graph>" first, then "<effect>".
const EFFECT_SHEETS_PATH := "res://addons/highpoly_toggle/fx_effect_sheets.json"
static var _effect_tbl: Dictionary = {}
static var _sheet_by_res: Dictionary = {}   # atlas res name -> sheet dict
const SIZES_PATH := "res://addons/highpoly_toggle/fx_sizes.json"
static var _sizes: Dictionary = {}      # lowercase graph name -> {size, field, n, ...}
# MESH PARTICLES. The propdest and clusteroid graphs import a 3-vertex default
# triangle as a placeholder and each EFFECT substitutes the real chunk, so the
# graph looks mesh-less while the 210 debris-pile points on Aftermath actually
# draw a 158-vertex wood shard. This is the mesh most often substituted per
# graph, util placeholders and anything over 4k triangles excluded.
const SPAWN_PATH := "res://addons/highpoly_toggle/fx_spawn.json"
static var _spawn: Dictionary = {}      # lowercase graph name -> {rate, max_count, spawn_spread}
const MESHES_PATH := "res://addons/highpoly_toggle/fx_meshes.json"
static var _meshtbl: Dictionary = {}    # lowercase graph name -> {mesh, verts, tris}
static var _meshes: Dictionary = {}     # lowercase graph name -> Mesh or null
const SHEET_CACHE := "user://fxsheets"
# Cap on the usable width AFTER the LeftRightTiles crop. The mip chain is right
# there in the header, so a smaller sheet is a smaller mip of the game's own
# texture rather than a resample of the largest one.
const SHEET_MAX := 1024
# BUMP THIS WHENEVER THE FOLD OR THE MIP BUDGET CHANGES. The decoded sheets are
# cached to disk, so a corrected fold is invisible until the old PNGs stop being
# read - which is how the first version of this shipped looking identical to the
# broken one. The epoch is in the FILENAME so a stale file cannot be mistaken
# for a current one, and anything from another epoch is swept.
const FOLD_EPOCH := 2


# Six directional lighting terms folded down to one flat card.
#
# A LeftRightTiles sheet is a six-way lightmap: the same frames twice, and the
# two halves carry six directional lighting terms across their RGB
# (findings/atlastexture-grid-and-sixway-packing). Alpha comes from the LEFT
# half only: that is the density, proved by a sheet whose right alpha is
# entirely empty while the effect plainly renders.
#
# THE LIGHTING FOLDS TO ONE SCALAR, not to three. A billboard with no six-way
# shader should show the light averaged over all directions, and that is the
# mean of all SIX terms - a single number, written to r, g and b alike. The
# first attempt averaged the halves per channel, (L.r+R.r)/2 and so on, which
# leaves three different values and therefore a colour: measured saturation
# 0.21 against 0.000 for the six-term mean, and it looked exactly as pastel as
# the raw sheet did. It also has the advantage of not depending on WHICH pairs
# are opposite, since the mean of six is the same however they pair up.
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
			@warning_ignore("integer_division")
			var v := (s[li] + s[li + 1] + s[li + 2]
				+ s[ri] + s[ri + 1] + s[ri + 2]) / 6
			out[oi] = v
			out[oi + 1] = v
			out[oi + 2] = v
			out[oi + 3] = s[li + 3]
	return Image.create_from_data(half, h, false, Image.FORMAT_RGBA8, out)


static var _swept := false

# Drop sheets decoded by an older fold, once per session.
static func _sweep_stale_cache() -> void:
	if _swept:
		return
	_swept = true
	var d := DirAccess.open(SHEET_CACHE)
	if d == null:
		return
	var keep := ".e%d.png" % FOLD_EPOCH
	for f in d.get_files():
		if f.ends_with(".png") and not f.ends_with(keep):
			d.remove(f)


# Families that are not billboards at all, so nothing we draw could be right.
# volumedecals are unit-cube PROJECTION volumes (all 34 measure exactly +/-1),
# lights are lens flares and volumetric cones, and the game itself names two
# graphs `dummy`. A Decal node is the right primitive for the first of those and
# is not built yet.
const NO_DRAW_FAMILIES := {
	"dummy": true, "debug": true, "lights": true,
}
# The commonest authored volume-decal box, doubled from the half-extent basis:
# (1,1,1) on 129 of 250 emitter rows, then (1.24,0.3,1.2) and (2.0,0.3,2.0).
const DECAL_BOX := Vector3(2.0, 2.0, 2.0)


# Is this graph something a camera-facing quad can honestly stand in for?
#
# The earlier rule was "has a flipbook", which was too blunt in both directions.
# Sparks, thindebris, pebbles and sand ARE billboards - every one is the same
# 4-vertex unit quad with clean 0..1 UVs - they just carry no sheet because they
# are driven by curl noise in the compute shader rather than by a flipbook.
# Exhaustive pointer walk over 592 graph partitions: no ribbon, distortion,
# normal-map, gobo or decal texture field exists on an emitter graph, so those
# families are not missing art that we failed to find. They have none.
#
# What made them look wrong was never the texture, it was the SIZE: drawn at the
# 2.4-3.0 m class fallback when the game authors 2 to 100 cm. With the authored
# size wired they are specks, which is what they are, so draw them.
static func _drawable(nm: String, effect: String, gp: Variant) -> bool:
	var key := effect.to_lower()
	if gp is Dictionary and NO_DRAW_FAMILIES.has(str((gp as Dictionary).get("family", ""))):
		return false
	var sd: Variant = _sheet_by_res.get(_sheet_res(nm, effect))
	if sd is Dictionary and not (sd as Dictionary).is_empty():
		return true
	# no sheet: a quad is still right if the game authored a quad size for it
	var sz: Variant = _sizes.get(key)
	if sz is Dictionary:
		var f := str((sz as Dictionary).get("field", ""))
		return f == "QuadSize" or f == "BaseSize"
	return false


# The atlas res for one spawn point. Most specific wins.
static func _sheet_res(nm: String, graph: String) -> String:
	var e := nm.to_lower()
	var g := graph.to_lower()
	for k in ["%s|%s" % [e, g], e, g]:
		var t: Variant = _effect_tbl.get(k, _sheet_tbl.get(k))
		if t is Dictionary:
			var r := str((t as Dictionary).get("sheet", ""))
			if r != "":
				return r
	return ""


static func _load_sheet_table() -> void:
	if _sheet_tbl_loaded:
		return
	_sheet_tbl_loaded = true
	if not FileAccess.file_exists(SHEETS_PATH):
		return
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(SHEETS_PATH))
	if raw is Dictionary:
		_sheet_tbl = raw
	if FileAccess.file_exists(EFFECT_SHEETS_PATH):
		var ef: Variant = JSON.parse_string(FileAccess.get_file_as_string(EFFECT_SHEETS_PATH))
		if ef is Dictionary:
			_effect_tbl = ef
	if FileAccess.file_exists(SIZES_PATH):
		var sz: Variant = JSON.parse_string(FileAccess.get_file_as_string(SIZES_PATH))
		if sz is Dictionary:
			_sizes = sz
	if FileAccess.file_exists(SPAWN_PATH):
		var sp: Variant = JSON.parse_string(FileAccess.get_file_as_string(SPAWN_PATH))
		if sp is Dictionary:
			_spawn = sp
	if FileAccess.file_exists(MESHES_PATH):
		var mt: Variant = JSON.parse_string(FileAccess.get_file_as_string(MESHES_PATH))
		if mt is Dictionary:
			_meshtbl = mt


# Real geometry for the mesh-emitter graphs, resolved once per distinct mesh.
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
		if rn == "":
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
# anywhere in the EBX - an exhaustive walk of 592 graph partitions found no
# decal texture field at all, and the mark's art lives inside the compiled
# GraphEmVSF shader. This is a generated gradient, not game art and not
# something downloaded; it carries the authored COLOUR and the authored BOX,
# which are real, and makes no claim about the pattern.
static var _decal_tex: Texture2D = null

static func _decal_texture() -> Texture2D:
	if _decal_tex != null:
		return _decal_tex
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in range(n):
		for x in range(n):
			var d := Vector2(x - c, y - c).length() / c
			var a := clampf(1.0 - d * d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_decal_tex = ImageTexture.create_from_image(img)
	return _decal_tex


# {"tex", "cols", "rows", "frames"} for one graph's sheet, or an empty dict.
#
# The grid comes from the ATLAS's own EBX, never from fx_params: this picks the
# sheet the effects actually bind, which is frequently NOT the one fx_params
# recorded, and a 6x36 grid on an 8x64 sheet samples the wrong frames entirely.
static func _decode_sheet(gs, sheet: String) -> Dictionary:
	var stem := BF6Atlas.norm_stem(sheet)
	if stem == "":
		return {}
	var png := "%s/%s.e%d.png" % [SHEET_CACHE, stem, FOLD_EPOCH]
	var meta := "%s/%s.e%d.json" % [SHEET_CACHE, stem, FOLD_EPOCH]
	if FileAccess.file_exists(png) and FileAccess.file_exists(meta):
		var ci := Image.new()
		var mj: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta))
		if ci.load_png_from_buffer(FileAccess.get_file_as_bytes(png)) == OK \
				and mj is Dictionary:
			var d: Dictionary = mj
			d["tex"] = ImageTexture.create_from_image(ci)
			return d
	if gs == null or gs.src == null:
		return {}
	# the table stores the RES name, so try it directly before normalising
	var rn := sheet if gs.src.res.has(sheet) else BF6Atlas.find_res(gs.src, sheet)
	if rn == "":
		return {}
	var hdr := BF6Atlas.parse(gs.src.get_res(rn))
	if hdr.is_empty():
		return {}
	var g := BF6Atlas.grid(gs.src, gs.types,
		gs.walk.gi if gs.walk != null else {}, rn)
	if g.is_empty():
		return {}
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
		return {}
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if lr:
		img = _fold_sixway(img)
	DirAccess.make_dir_recursive_absolute(SHEET_CACHE)
	img.save_png(png)
	var out := {"cols": int(g["cols"]), "rows": int(g["rows"]),
				"frames": int(g["frames"])}
	var fh := FileAccess.open(meta, FileAccess.WRITE)
	if fh != null:
		fh.store_string(JSON.stringify(out))
		fh.close()
	out["tex"] = ImageTexture.create_from_image(img)
	return out


# Resolve every sheet the graph table names, BEFORE any emitter is built.
#
# Doing it up front is what keeps the `_mats` cache honest: resolve lazily and
# the first emitter of a graph bakes an untextured material that every later
# one then reuses, so a sheet that became available a moment later never
# appears. Returns how many resolved.
static func _prime_sheets(gs) -> int:
	_sweep_stale_cache()
	_load_sheet_table()
	var added := false
	# every atlas named by EITHER table, decoded once each
	var want := {}
	for tbl in [_sheet_tbl, _effect_tbl]:
		for k in tbl.keys():
			var rec: Variant = tbl[k]
			if rec is Dictionary:
				var r := str((rec as Dictionary).get("sheet", ""))
				if r != "":
					want[r] = true
	for res in want.keys():
		if _sheet_by_res.has(res):
			continue
		var d: Dictionary = _decode_sheet(gs, res)
		# DO NOT MEMOISE A MISS THAT ONLY HAPPENED FOR WANT OF A SOURCE. FX can
		# be switched on before the map has been read, and caching the empty
		# result then means the sheet never appears for the rest of the session
		# even once the source is open - the same shape of bug as _obj_cache
		# remembering NOT-FOUND.
		if not d.is_empty() or (gs != null and gs.src != null):
			_sheet_by_res[res] = d
			added = true
	var found := 0
	for r in _sheet_by_res.keys():
		var dd: Variant = _sheet_by_res[r]
		if dd is Dictionary and not (dd as Dictionary).is_empty():
			found += 1
	if added:
		_mats.clear()       # materials built before this would have no texture
	return found


static func _emitter(cls: String, effect: String, gp: Variant, sheet_res := "") -> GPUParticles3D:
	var g := GPUParticles3D.new()
	var cfg := _build_mats(cls, gp, sheet_res)
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
			# THE LAYER'S RATE, NOT THE TEMPLATE'S - the same bug as size.
			# Reading the graph template gave every emitter of a graph one
			# identical rate, which is why the whole map pulsed together.
			# Two traps in the source, both resolved in fx_spawn.json: the
			# BF2042 labels on SpawnModeContinuous are SWAPPED (the field
			# named InitialParticleCount is the float RATE, the one named
			# SpawnRate is the int initial count), and MaxSpawnRate is a
			# clamp ceiling of 10000-65000 rather than a rate.
			var sr: Variant = _spawn.get(effect.to_lower())
			if sr is Dictionary:
				var srd: Dictionary = sr
				if srd.get("rate") != null:
					rate = float(srd["rate"])
				if srd.get("max_count") != null:
					cap = int(srd["max_count"])
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


static func _build_mats(cls: String, gp: Variant, sheet_res := "") -> Array:
	var fb: Dictionary = CLASS_FALLBACK[cls]
	var ck := cls
	if gp is Dictionary:
		ck = str((gp as Dictionary).get("graph", cls))
	var gkey := ck.to_lower()          # graph alone, for the size/spawn tables
	# TWO EFFECTS OF ONE GRAPH NOW DIFFER, so the sheet has to be part of the
	# material identity. Leaving it out would hand the first effect's sheet to
	# every later one, which is the same cache bug the untextured materials had.
	if sheet_res != "":
		ck += "|" + sheet_res
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
		# EMITTER_BBOX IS NOT AN EMISSION VOLUME and using it as one was the
		# other half of "everything has the same spread". At template level 67%
		# of graphs are exactly +/-1, so two thirds of the map emitted from an
		# identical unit cube. It is a CULLING bound: of 1,189 off-centre boxes
		# 1,076 are offset upward and only 113 downward, which is a bound
		# tracking particles that rise, and a handheld repair torch carries a
		# 6x4x6 m one. Wiring it would have swapped one wrong preview for a
		# worse one.
		#
		# The authored spread is SpawnPosScale, which really does vary per
		# layer. Ratios are trustworthy - [1,0.1,1] is a flat disc, [0.3,1,0.3]
		# a vertical stalk - while the absolute metre scale is inferred, so a
		# graph with none falls back to the small default sphere above rather
		# than borrowing the bound.
		var sp2: Variant = _spawn.get(gkey)
		if sp2 is Dictionary and (sp2 as Dictionary).get("spawn_spread") != null:
			var sv: Array = (sp2 as Dictionary)["spawn_spread"]
			if sv.size() >= 3:
				pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
				pm.emission_box_extents = Vector3(
					absf(float(sv[0])), absf(float(sv[1])), absf(float(sv[2])))

	# AUTHORED SIZE BEATS BOTH OF THOSE.
	#
	# fx_params ships base_size 1.0 for everything, because it reads the GRAPH
	# TEMPLATE table where BaseSize is exactly 1.0 on all 45 templates that carry
	# one. The authored size lives on the per-emitter LAYER instead, so it was
	# never visible and every emitter fell back to the hand-tuned class table.
	# Measured against the real values, that table had smoke about 2x too small
	# and the debris and spark families up to 100x too LARGE - a 2 cm spark drawn
	# as a 3 m square is what "hundreds of cubes everywhere" was.
	#
	# fx_sizes.json is the per-graph median of the layer values. `field` is not a
	# unit: BaseSize is a sprite quad, QuadSize a spark/pebble quad, SpawnSize a
	# mesh particle and WidthMult a ribbon width, so only the first two are a
	# billboard edge length and the others are left alone.
	#
	# Half-extent versus full-extent is UNRESOLVED in the data. If everything
	# comes out uniformly 2x or 0.5x, that is this reading, not the numbers.
	var sz: Variant = _sizes.get(gkey)
	if sz is Dictionary:
		var f := str((sz as Dictionary).get("field", ""))
		if f == "BaseSize" or f == "QuadSize":
			size = float((sz as Dictionary).get("size", size))

	pm.color = _colour_of(gp, fb)

	# `render` carries what the compiled shader's blend state does not expose:
	# emissive effects (fire, sparks, muzzle flash) draw additively.
	dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if render == "emissive" \
		else BaseMaterial3D.BLEND_MODE_MIX

	# THE GRID COMES WITH THE SHEET. This picks the atlas the effects actually
	# bind, which is often not the one fx_params recorded, so taking cols/rows
	# from fx_params would sample a 6x36 grid off an 8x64 sheet - right texture,
	# wrong frames, and it reads as the animation stuttering rather than as a
	# mismatch. Only fps stays authored per graph.
	var sd: Variant = _sheet_by_res.get(sheet_res)
	var tex: Texture2D = (sd as Dictionary).get("tex") if sd is Dictionary else null
	if tex != null:
		var sdd: Dictionary = sd
		dm.albedo_texture = tex
		var cols := int(sdd.get("cols", 1))
		var rows := int(sdd.get("rows", 1))
		var frames := int(sdd.get("frames", cols * rows))
		var fps := 12.0
		if gp is Dictionary:
			fps = float((gp as Dictionary).get("fps", fps))
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
	# REAL GEOMETRY WHERE THE GAME SUBSTITUTES IT. mesh_for returns the mesh
	# already dressed through the depot, so these arrive textured rather than
	# tinted. The authored SpawnSize is a mesh scale, not a quad edge, so it is
	# deliberately not applied here - the chunk is drawn at its authored size.
	var gm: Variant = _meshes.get(gkey)
	if gm is Mesh:
		_mats[ck] = [pm, gm]
		return _mats[ck]
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
