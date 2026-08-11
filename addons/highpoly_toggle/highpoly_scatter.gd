@tool
extends RefCounted
class_name HighpolyScatter
# Vegetation scatter (grass/shrub/weed kits) for the map-context overlay.
#
# Types come from the game's decoded MeshScatteringDatabase, shipped per map as
# scatter.json in the map package (see pipeline scatter_build.py):
#   {"budget": N, "entries": [{mesh, kit:[[x,z,w]..], viewDistance, param,
#                              budgetShare, spacing}, ...]}
# The game places these at runtime from its terrain-layer splat masks. Those
# masks are now DECODED: idx_raw.png + w.png + the layers.json palette (the
# baked combined coverage of the map's grass layers) accept anchors by the REAL
# coverage weight, with slope kept only as a cliff sanity clamp. Anchors are
# still generated as a deterministic jittered grid in a ring around the editor
# camera (position-seeded hash — the same spot always grows the same grass),
# snapped to the map heightfield. Maps without the mask keep the old heuristic
# (low slope; maptile greenness where a satellite tile exists). Each accepted
# anchor stamps the entry's kit point pattern (random yaw, 0.8-1.2 scale jitter).
#
# Rendering: ONE MultiMeshInstance3D per scatter mesh; regenerated only when
# the camera crosses a 32 m cell. DB distance model: full kit to 65 m, every
# 4th point to min(viewDistance, 300) m, nothing beyond. Total instances are
# capped by the DB budget. Maps without scatter.json are a strict no-op.

const NODE := "_SCATTER"
const PROPS_CACHE := "user://mapcontext/_props"   # shared prop-mesh store
const NEAR_R := 65.0          # LodGroup full-detail distance
const CULL_R := 300.0         # LodGroup cull distance
const FAR_THIN := 4           # every 4th kit point beyond NEAR_R
const REGEN_CELL := 32.0      # regenerate when the camera crosses this grid
const SLOPE_FULL := 0.35      # slope (1 - normal.y) with full density…
const SLOPE_NONE := 0.55      # …fading to none here (terrain shader ground band)
const Y_EPS := 0.02           # lift above the heightfield to dodge z-fighting
const OUTSIDE := -1.0e9

var active := false
# How far from the camera clutter grows, metres. 0 = off, and OFF IS THE
# DEFAULT again — but this time the panel has a Grass chip that owns it
# (HighpolyMapContext.set_grass), so the value is reachable. The history is a
# warning worth keeping: this default was 0 once before, v1.19.0 deleted the
# Grass slider without deleting the default, and set_range() sat with no
# callers for months while the status line said "49 scatter types" over a
# ground with zero instances. A default the UI cannot reach must carry the
# value the feature needs; a default the UI CAN reach may be conservative.
var grass_range := 0.0
var last_regen_ms := 0        # debug: last regeneration cost
var last_instances := 0       # debug: instances currently placed
const HARD_TOTAL := 90000     # absolute instance safety cap across all entries

var _entries: Array = []      # {mesh, kit:PackedVector3Array(x,z,w), spacing, radius, cap, seed, mmi}
var _budget := 0
var _root: Node3D = null
var _mesh_cache: Dictionary = {}
# heightfield (same raw uint16 blob the map-context terrain is built from)
var _hm_raw := PackedByteArray()
var _hm_res := 0
var _hm_min := 0.0
var _hm_span := 1.0
var _hm_base := 0.0
var _hm_scale := 0.0
# optional maptile greenness (satellite jpg + world bounds)
var _tile: Image = null
var _tile_b := Vector4()      # xmin, zmin, sizeX, sizeZ
# REAL painted coverage (task #93): splat/idx_raw.png holds the TRUE per-texel
# palette indices (4 layer slots per texel, RGBA8) and splat/w.png the matching
# blend weights - the game's own statement of where each ground layer is,
# preserved by the compositor before the shader remap collapses it. Together
# with the palette table in layers.json (layer index -> texture stem) they
# replace the slope-band + satellite-greenness heuristic: a grass kit accepts
# by the summed weight of VEGETATION-classified layers under the anchor, a
# debris kit by the rest. Slope stays only as a cliff sanity clamp. Maps whose
# cache predates the table keep the heuristic - graceful, not silent: setup
# says which path it took.
var _cov := PackedByteArray()      # idx_raw RGBA8 bytes, _cov_res^2 * 4
var _covw := PackedByteArray()     # w.png RGBA8 bytes, same shape
var _cov_res := 0
var _cov_b := Vector4()            # xmin, zmin, sizeX, sizeZ (splat world box)
# layer index -> class: 0 ground, 1 vegetation. 255 (no layer) counts as
# ground, so debris still lands on the unpainted background.
var _cov_cls := PackedByteArray()
var _debris_layers := 0            # debris-painted layers in this map's palette
const VEG_WORDS := ["grass", "tuft", "shrub", "weed", "plant", "flower",
	"fern", "bush", "leaf", "clover", "moss", "ivy", "hay", "wheat", "crop",
	"reed", "lawn", "fairway", "turf", "iceplant", "oakshrub", "driedgrass"]
# Hard-debris kits (brick rubble, asphalt chunks, wreckage). The catalogue
# ships them next to the grass, but "anywhere vegetation does not dominate"
# is the WRONG where for them: it accepted debris at full weight across every
# open patch of dirt, and a rubble kit tiled the countryside. Debris keys to
# the map's own debris-PAINTED layers instead, exactly as grass keys to
# vegetation layers.
const DEBRIS_WORDS := ["debris", "rubble", "wreck", "burnt", "trash",
	"scrap", "junk", "ruin", "demolit", "brickpile", "concretechunk",
	"asphaltchunk"]
# ground lift applied by the map context when the splat terrain is active (the
# extended terrain is raised slightly to win the SDK-bowl depth fight; grass
# must sit on the lifted surface, not inside it)
var y_lift := 0.0
var _last_cell := Vector2i(2147483647, 2147483647)

func clear() -> void:
	if _root != null and is_instance_valid(_root):
		var p := _root.get_parent()
		if p != null: p.remove_child(_root)
		_root.queue_free()
	_root = null
	_entries.clear()
	_mesh_cache.clear()
	_hm_raw = PackedByteArray()
	_tile = null
	_cov = PackedByteArray()
	_covw = PackedByteArray()
	_cov_res = 0
	_cov_cls = PackedByteArray()
	# (y_lift is NOT reset here: the map context owns it and assigns it around
	# setup(); clear() runs at the start of setup and must not wipe it)
	_last_cell = Vector2i(2147483647, 2147483647)
	active = false
	last_instances = 0

# Build the scatter layer under `ctx` (the _MAP_CONTEXT node). `mc` is the
# HighpolyMapContext instance (reused untyped for its GLB loader/baker).
# `tile` = {"img": res path, "bounds": Vector4} or {} — maptile greenness.
# Returns the number of scatter types placed; 0 = no scatter data (no-op).
func setup(mc: Object, ctx: Node3D, map: String, dir: String, hm: Dictionary, tile: Dictionary) -> int:
	clear()
	# THE CATALOGUE COMES FROM THE GAME. scatter.json was a downloaded list of
	# which clutter meshes a level uses, invented by the pipeline on the belief
	# that the game ships none. It ships a MeshScatteringDatabase per level - 44
	# meshes on mp_dumbo, each a real MeshSet - with a view distance and a ratio
	# for every one. That is read here; scatter.json is only a fallback for a
	# cache built before this existed.
	var ents: Array = []
	var from_game := false
	if mc != null and mc.game_source != null:
		ents = mc.game_source.scatter_entries()
		from_game = not ents.is_empty()
	if ents.is_empty():
		var sj := "%s/scatter.json" % dir
		if not FileAccess.file_exists(sj): return 0
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(sj))
		if not (d is Dictionary): return 0
		ents = (d as Dictionary).get("entries", [])
		_budget = int((d as Dictionary).get("budget", 16384))
	if ents.is_empty(): return 0
	# heightfield (required — grass must sit on the terrain)
	if not hm.has("file"): return 0
	_hm_raw = FileAccess.get_file_as_bytes("%s/%s" % [dir, hm["file"]])
	if _hm_raw.is_empty(): return 0
	_hm_res = int(hm.get("res", 4097))
	_hm_min = float(hm.get("world_min", -2048))
	_hm_span = float(hm.get("world_max", 2048)) - _hm_min
	_hm_base = float(hm.get("base", 0.0))
	_hm_scale = float(hm.get("scale", 1.0)) / 65535.0
	# optional maptile for greenness weighting
	if tile.has("img"):
		var gp := ProjectSettings.globalize_path(str(tile["img"]))
		var img := Image.new()
		if img.load(gp) == OK:
			_tile = img
			_tile_b = tile.get("bounds", Vector4())
	# REAL painted coverage: idx_raw + w + the palette table (see the field
	# notes above). The old grass_mask.png path is gone with the pipeline that
	# baked it; this reads what the surface build now preserves.
	var mp := "%s/splat/idx_raw.png" % dir
	var wp := "%s/splat/w.png" % dir
	var lj := "%s/splat/layers.json" % dir
	if FileAccess.file_exists(mp) and FileAccess.file_exists(wp) \
			and FileAccess.file_exists(lj):
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(lj))
		if meta is Dictionary and (meta as Dictionary).get("palette", null) is Array \
				and (meta as Dictionary).get("world", {}) is Dictionary:
			var wj: Dictionary = (meta as Dictionary)["world"]
			var mimg := Image.load_from_file(ProjectSettings.globalize_path(mp))
			var wimg := Image.load_from_file(ProjectSettings.globalize_path(wp))
			if mimg != null and wimg != null \
					and mimg.get_width() == wimg.get_width():
				_cov = mimg.get_data()
				_covw = wimg.get_data()
				_cov_res = mimg.get_width()
				_cov_b = Vector4(float(wj.get("x0", 0.0)), float(wj.get("z0", 0.0)),
					float(wj.get("size", 1.0)), float(wj.get("size", 1.0)))
				_cov_cls = PackedByteArray()
				_cov_cls.resize(256)
				var veg_n := 0
				for prow in ((meta as Dictionary)["palette"] as Array):
					var pd: Dictionary = prow
					var nm2 := str(pd.get("tex", "")).to_lower()
					var li2 := int(pd.get("layer", -1))
					if li2 < 0 or li2 >= 255:
						continue
					for wv in VEG_WORDS:
						if nm2.contains(str(wv)):
							_cov_cls[li2] = 1
							veg_n += 1
							break
					if _cov_cls[li2] == 0:
						for wd in DEBRIS_WORDS:
							if nm2.contains(str(wd)):
								_cov_cls[li2] = 2
								_debris_layers += 1
								break
				print("MapContext[%s]: scatter uses the game's painted coverage (%d vegetation, %d debris layer(s))"
					% [map, veg_n, _debris_layers])
	_root = Node3D.new()
	_root.name = NODE
	ctx.add_child(_root)
	_root.owner = null
	var skipped: Array = []
	for e in ents:
		if not (e is Dictionary) or not e.has("mesh"): continue
		# A game-sourced entry has no kit pattern, because the game does not ship
		# one: the database says WHICH meshes and with what parameters, not where
		# each clump goes. One is generated below, which is what the pipeline did
		# for every entry anyway.
		if not from_game and not e.has("kit"): continue
		var nm := str(e["mesh"])
		# GRASS IS THE POINT. Neutral kits - pebbles, litter, anything neither
		# vegetation nor debris - used to place by "anywhere grass is not" and
		# carpeted every open surface. The user's verdict is the right spec:
		# vegetation places by its painted coverage, debris by ITS painted
		# coverage, and the neutral remainder places nothing at all.
		if _kit_class(str(e.get("name", nm))) == 0 and _kit_class(nm) == 0:
			continue
		var mesh := _scatter_mesh(mc, nm)
		if mesh == null:
			skipped.append(nm)
			continue
		var kit := PackedVector3Array()
		if from_game:
			kit = _make_kit(nm, float(e.get("ratio", 0.15)))
		else:
			for p in e["kit"]:
				if p is Array and p.size() >= 2:
					kit.append(Vector3(float(p[0]), float(p[1]),
						float(p[2]) if p.size() > 2 else 0.0))
		if kit.is_empty(): continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		var mmi := MultiMeshInstance3D.new()
		mmi.name = nm
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(mmi)
		mmi.owner = null
		# Game-sourced entries carry no budgetShare; the equal split is the
		# real path, and the key is only ever present in legacy scatter.json.
		var share := float(e.get("budgetShare", 1.0 / ents.size()))
		# CARPET spacing from the kit's own footprint: clumps tile nearly
		# edge-to-edge where the mask is full (the game's cell budget works
		# out near-continuous close up — the old DB-ring reading was ~8x too
		# sparse and read as "scattered blobs" vs the screenshots)
		var span := 0.0
		for p in kit:
			span = maxf(span, maxf(absf(p.x), absf(p.y)))
		var dense := clampf(span * 2.0 * 0.9, 1.5, 6.0)
		_entries.append({
			"kit": kit,
			# the kit's class, from its own catalogue name: what the painted
			# coverage matches it against (0 neutral, 1 vegetation, 2 debris)
			"cls": _kit_class(nm),
			"spacing": dense,
			# "distance" is what scatter_entries() emits from the game's own DB
			# (real per-mesh values {30, 50, 55, 75, 100, 150, 200, 300});
			# "viewDistance" was the legacy scatter.json key, and reading only
			# it meant every game entry silently took the 300 m default — the
			# whole budget spent placing pebbles to the horizon.
			"radius": minf(CULL_R, float(e.get("distance",
				e.get("viewDistance", CULL_R)))),
			"share": share,
			"seed": nm.hash(),
			"mmi": mmi,
		})
	if _entries.is_empty():
		clear()
		return 0
	if not skipped.is_empty():
		print("MapContext[%s]: scatter: %d kit meshes not cached yet (%s…)" %
			[map, skipped.size(), skipped[0]])
	active = true
	return _entries.size()

func set_range(v: float, cam_pos: Vector3) -> void:
	grass_range = clampf(v, 0.0, CULL_R)
	if not active: return
	if not _alive():
		clear()                         # our nodes were freed externally — self-heal
		return
	_regenerate(cam_pos)

# regenerate when the camera crosses a REGEN_CELL boundary
func tick(cam_pos: Vector3) -> void:
	if not active: return
	if not _alive():
		clear()                         # our nodes were freed externally — self-heal
		return
	if grass_range <= 0.0: return       # grass off: nothing to follow
	var cell := Vector2i(int(floor(cam_pos.x / REGEN_CELL)), int(floor(cam_pos.z / REGEN_CELL)))
	if cell == _last_cell:
		_regen_step()                   # still draining the last crossing
		return
	_last_cell = cell
	_regenerate(cam_pos)

# _MAP_CONTEXT (and everything under it, our _root included) can be freed by
# an apply()/_clear() we don't control — another HighpolyMapContext instance
# (PhotoMatch's render hook builds its own) tears the shared node down, and
# with the props layer now building across frames those frees interleave with
# our camera-follow ticks. A RefCounted can't get freed-node signals, so every
# entry point re-checks liveness instead of trusting the held references.
func _alive() -> bool:
	return _root != null and is_instance_valid(_root)

# THE REGENERATE IS SPREAD ACROSS FRAMES, and that is the whole point.
#
# Every 32 m of camera travel this rebuilds the clumps, and it used to do all
# of them in ONE frame: 49 scatter types on aftermath, each generating up to a
# budget of instance transforms in GDScript and then re-uploading a MultiMesh
# buffer. That is a guaranteed hitch every 32 m, which while flying is
# constant - the user called it before the measurement did ("I know its the
# grass").
#
# The entries are independent, so the work divides cleanly: a queue is filled
# when the camera crosses a cell and drained a few milliseconds at a time. The
# hitch becomes a spread. Grass appears a frame or two later than it did,
# which nobody can see; the frame it used to cost is what everybody saw.
const REGEN_MS_PER_FRAME := 2.0
var _regen_queue: Array = []
var _regen_cam := Vector3.ZERO


# Drain a few milliseconds of the queue. Called every tick, cheap when empty.
func _regen_step() -> void:
	if _regen_queue.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	var made := 0
	while not _regen_queue.is_empty():
		var e = _regen_queue.pop_front()
		var node = e["mmi"]
		if is_instance_valid(node):
			var buf := _gen_entry(e, _regen_cam)
			var cnt := int(buf.size() / 12)
			var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
			mm.instance_count = 0
			mm.instance_count = cnt
			if cnt > 0:
				mm.buffer = buf
			made += cnt
		if Time.get_ticks_msec() - t0 >= REGEN_MS_PER_FRAME:
			break
	last_instances = made if _regen_queue.is_empty() else last_instances + made
	last_regen_ms = Time.get_ticks_msec() - t0


func _regenerate(cam_pos: Vector3) -> void:
	# Queue it rather than doing it here: see _regen_step.
	if grass_range > 0.0:
		_regen_queue = _entries.duplicate()
		_regen_cam = cam_pos
		last_instances = 0
		_regen_step()
		return
	_regenerate_now(cam_pos)


func _regenerate_now(cam_pos: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var total := 0
	if grass_range <= 0.0:
		# slider at 0 = grass off: empty every MultiMesh
		for e in _entries:
			var node0 = e["mmi"]        # untyped on purpose: casting a freed ref errors
			if not is_instance_valid(node0): continue
			var mm0: MultiMesh = (node0 as MultiMeshInstance3D).multimesh
			mm0.instance_count = 0
		last_instances = 0
		last_regen_ms = 0
		return
	for e in _entries:
		var node = e["mmi"]             # untyped on purpose: casting a freed ref errors
		if not is_instance_valid(node): continue
		var buf := _gen_entry(e, cam_pos)
		var cnt := int(buf.size() / 12)
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		mm.instance_count = 0          # drop the old buffer before resizing
		mm.instance_count = cnt
		if cnt > 0:
			mm.buffer = buf
		total += cnt
	last_instances = total
	last_regen_ms = Time.get_ticks_msec() - t0

# one entry's instance transforms around the camera (deterministic per anchor
# cell — revisiting a spot regenerates the identical clumps)
func _gen_entry(e: Dictionary, cam: Vector3) -> PackedFloat32Array:
	var kit: PackedVector3Array = e["kit"]
	var n := kit.size()
	var spacing: float = e["spacing"]                       # carpet spacing (kit footprint)
	var radius: float = minf(e["radius"], grass_range)      # dock range slider
	# per-entry cap: its share of the hard safety total
	var cap: int = maxi(64, int(float(HARD_TOTAL) * float(e["share"])))
	var seed_i: int = e["seed"]
	var buf := PackedFloat32Array()
	buf.resize(cap * 12)
	var w := 0                          # write cursor (floats)
	var r2 := radius * radius
	var near2 := NEAR_R * NEAR_R
	# NEAREST-FIRST, in square rings outward from the camera's cell. The old
	# row-major scan from (cam - radius) upward hit the per-entry cap while
	# still in the far -x/-z corner, so the entire budget was a clutter blob
	# ~radius metres off to one side with bare ground under the camera. The cap
	# must truncate the FAR field, and ring order gives that without sorting:
	# every cell in ring r is nearer than any cell in ring r+2, which is as
	# sorted as an accept-reject scatter needs.
	var ccx := int(floor(cam.x / spacing))
	var ccz := int(floor(cam.z / spacing))
	var max_ring := int(ceil(radius / spacing)) + 1
	var count := 0
	for ring in range(0, max_ring + 1):
		if count >= cap:
			break
		# the ring's cells: the full row at top and bottom, the two side columns
		# between them (ring 0 is just the centre cell)
		var cells := PackedInt32Array()
		if ring == 0:
			cells.append(ccx); cells.append(ccz)
		else:
			for i in range(-ring, ring + 1):
				cells.append(ccx + i); cells.append(ccz - ring)
				cells.append(ccx + i); cells.append(ccz + ring)
			for i in range(-ring + 1, ring):
				cells.append(ccx - ring); cells.append(ccz + i)
				cells.append(ccx + ring); cells.append(ccz + i)
		for c in range(0, cells.size(), 2):
			var cx := int(cells[c])
			var cz := int(cells[c + 1])
			# jittered, deterministic anchor inside the cell — same hash, same
			# anchors as before; only the VISIT ORDER changed, so a spot still
			# regenerates the identical clumps
			var ax := (float(cx) + 0.1 + 0.8 * _hash01(seed_i, cx, cz, 0)) * spacing
			var az := (float(cz) + 0.1 + 0.8 * _hash01(seed_i, cx, cz, 1)) * spacing
			var dx := ax - cam.x
			var dz := az - cam.z
			var d2 := dx * dx + dz * dz
			if d2 > r2: continue
			# slope: with the real grass mask it is only a cliff SANITY clamp;
			# without it, it keeps its old fade-band role in the heuristic
			var sl := _slope(ax, az)
			if sl >= SLOPE_NONE: continue
			var wgt: float
			if _cov_res > 0:
				# EXACT accept weight: the game's own painted coverage, matched
				# to this kit's class - grass on vegetation layers, debris on
				# the rest. This is also what finally answers "which mesh goes
				# where": the 49 kits stop being 49 identical carpets.
				wgt = _cov_weight(ax, az, int(e.get("cls", 0)))
			else:
				wgt = clampf((SLOPE_NONE - sl) / (SLOPE_NONE - SLOPE_FULL), 0.0, 1.0)
				wgt *= _green_weight(ax, az)
			if wgt <= 0.0: continue
			if _hash01(seed_i, cx, cz, 2) > wgt: continue
			var yaw := _hash01(seed_i, cx, cz, 3) * TAU
			var ca := cos(yaw)
			var sa := sin(yaw)
			var thin := 1 if d2 <= near2 else FAR_THIN
			var pi := 0
			while pi < n:
				var k := kit[pi]
				# rotate the kit offset by the same yaw basis the meshes get
				# (Basis(UP,yaw): x=(c,0,-s), z=(s,0,c))
				var wx := ax + k.x * ca + k.y * sa
				var wz := az - k.x * sa + k.y * ca
				var wy := _height(wx, wz)
				pi += thin
				if wy < -1.0e8: continue
				wy += y_lift            # sit on the (possibly lifted) splat terrain
				# w (k.z) is the DB per-point seed but ships as 0 — hash instead
				var sc: float = 0.8 + 0.4 * _hash01(seed_i, cx * 131 + pi, cz, 4) if k.z == 0.0 \
					else 0.8 + 0.4 * (k.z - floorf(k.z))
				# MultiMesh buffer: 3 rows of the 3x4 transform, row-major
				buf[w] = sc * ca;  buf[w + 1] = 0.0; buf[w + 2] = sc * sa;  buf[w + 3] = wx
				buf[w + 4] = 0.0;  buf[w + 5] = sc;  buf[w + 6] = 0.0;      buf[w + 7] = wy + Y_EPS
				buf[w + 8] = -sc * sa; buf[w + 9] = 0.0; buf[w + 10] = sc * ca; buf[w + 11] = wz
				w += 12
				count += 1
				if count >= cap: break
			if count >= cap: break
	buf.resize(count * 12)
	return buf

# ---------- heightfield sampling (bilinear over the raw uint16 blob) ----------
func _height(x: float, z: float) -> float:
	var fx := (x - _hm_min) / _hm_span * float(_hm_res - 1)
	var fz := (z - _hm_min) / _hm_span * float(_hm_res - 1)
	if fx < 0.0 or fz < 0.0 or fx > float(_hm_res - 1) or fz > float(_hm_res - 1):
		return OUTSIDE
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, _hm_res - 1)
	var z1 := mini(z0 + 1, _hm_res - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var h00 := float(_hm_raw.decode_u16((z0 * _hm_res + x0) * 2))
	var h10 := float(_hm_raw.decode_u16((z0 * _hm_res + x1) * 2))
	var h01 := float(_hm_raw.decode_u16((z1 * _hm_res + x0) * 2))
	var h11 := float(_hm_raw.decode_u16((z1 * _hm_res + x1) * 2))
	return _hm_base + lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz) * _hm_scale

# slope = 1 - normal.y, central differences (same measure the terrain shader
# selects its ground layer with)
func _slope(x: float, z: float) -> float:
	var s := 2.0
	var hxm := _height(x - s, z)
	var hxp := _height(x + s, z)
	var hzm := _height(x, z - s)
	var hzp := _height(x, z + s)
	if hxm < -1.0e8 or hxp < -1.0e8 or hzm < -1.0e8 or hzp < -1.0e8:
		return 1.0
	var gx := hxp - hxm
	var gz := hzp - hzm
	return 1.0 - (2.0 * s) / sqrt(gx * gx + gz * gz + 4.0 * s * s)

# The painted-coverage accept weight at a world position, for one kit class.
# The texel's four layer slots are summed where their class matches the kit:
# a grass kit reads the vegetation weight, anything else reads the remainder
# (255 = no layer counts as ground, so debris still lands on the unpainted
# background). Nearest texel - the slots are INDICES, and indices cannot be
# bilinearly blended; at 2 m per texel the block edge is finer than a clump.
# 0 outside the splat box, which is the playable area: no heuristic scatter
# out in the void.
# A kit's class from its catalogue name, same vocabulary as the layer table.
# 0 neutral ground (pebbles, litter), 1 vegetation, 2 hard debris.
static func _kit_class(nm: String) -> int:
	var low := nm.to_lower()
	for w in VEG_WORDS:
		if low.contains(str(w)):
			return 1
	for w in DEBRIS_WORDS:
		if low.contains(str(w)):
			return 2
	return 0


func _cov_weight(x: float, z: float, cls: int) -> float:
	var u := (x - _cov_b.x) / _cov_b.z
	var v := (z - _cov_b.y) / _cov_b.w
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return 0.0
	# A debris kit on a map whose palette paints no debris places NOTHING.
	# The old fallback dropped it to the neutral rule, which accepts anywhere
	# grass is not - debris everywhere, the exact spam the class exists to
	# stop.
	if cls == 2 and _debris_layers == 0:
		return 0.0
	var px := clampi(int(u * float(_cov_res - 1) + 0.5), 0, _cov_res - 1)
	var pz := clampi(int(v * float(_cov_res - 1) + 0.5), 0, _cov_res - 1)
	var o := (pz * _cov_res + px) * 4
	var hit := 0
	var veg_w := 0
	var total := 0
	for s in range(4):
		var w := int(_covw[o + s])
		if w == 0:
			continue
		total += w
		var li := int(_cov[o + s])
		var lc := int(_cov_cls[li]) if li < 255 else 0
		if lc == 1:
			veg_w += w
		if lc == cls:
			hit += w
	if cls == 1:
		# grass grows by how much of the texel its layers cover
		return clampf(float(hit) / 255.0, 0.0, 1.0)
	if cls == 2:
		# debris piles up by how much of the texel its DEBRIS layers cover -
		# the same rule as grass, keyed to the rubble paint. "Anywhere the
		# grass is not" accepted a rubble kit across every open field.
		return clampf(float(hit) / 255.0, 0.0, 1.0)
	# neutral kits: full weight wherever vegetation does NOT dominate,
	# including unpainted background (total 0)
	if total == 0:
		return 1.0
	return clampf(1.0 - float(veg_w) / 255.0, 0.0, 1.0)

# maptile greenness: density weight 0.15..1 inside the satellite footprint,
# 1 outside it (or when the map has no tile). Grey/asphalt reads low, green
# reads full; the jpg's black no-data border is ignored.
func _green_weight(x: float, z: float) -> float:
	if _tile == null or _tile_b.z <= 0.0 or _tile_b.w <= 0.0:
		return 1.0
	var u := (x - _tile_b.x) / _tile_b.z
	var v := (z - _tile_b.y) / _tile_b.w
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return 1.0
	var c := _tile.get_pixel(int(u * float(_tile.get_width() - 1)), int(v * float(_tile.get_height() - 1)))
	var lum := (c.r + c.g + c.b) / 3.0
	if lum < 0.04:
		return 1.0                      # out-of-bounds black border = no data
	# vegetation reads GREEN or DRY-GOLD (scorched/steppe maps grow tan grass —
	# FireStorm was starved to the floor by the green-only term)
	var veg := maxf(c.g - maxf(c.r, c.b), minf(c.r, c.g) - c.b - 0.02)
	return clampf(0.3 + 6.0 * veg + 0.5 * (lum - 0.25), 0.15, 1.0)

# deterministic position-seeded hash -> [0,1]
static func _hash01(seed_i: int, a: int, b: int, k: int) -> float:
	var h := seed_i + a * 374761393 + b * 668265263 + k * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777215.0

# ---------- kit mesh loading (shared props cache, foliage-corrected) ----------
# A clump pattern for one clutter mesh.
#
# The game ships no placement data - the MeshScatteringDatabase names the
# meshes and their parameters, not where each one goes - so the pattern is
# generated, which is what the pipeline did for every entry before this.
#
# SEEDED ON THE MESH NAME, so a given mesh has the same clump on every machine
# and every reopen. An unseeded pattern would reshuffle the grass each time the
# camera crossed a cell, which reads as the ground crawling.
#
# `ratio` comes from the record and scales the clump's spread: the values seen
# are 0, 0.1, 0.15, 0.2 and 0.25, and a bigger one gets a wider, denser clump.
func _make_kit(nm: String, ratio: float) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(nm)
	var spread: float = 0.6 + clampf(ratio, 0.0, 0.5) * 6.0
	var n: int = 6 + int(clampf(ratio, 0.0, 0.5) * 40.0)
	var out := PackedVector3Array()
	for i in range(n):
		# Poisson-ish: a jittered ring rather than uniform noise, which clumps
		# far less and leaves obvious bald patches at these counts.
		var a := rng.randf() * TAU
		var r := spread * sqrt(rng.randf())
		out.append(Vector3(cos(a) * r, sin(a) * r, rng.randf_range(0.7, 1.0)))
	return out


func _scatter_mesh(mc: Object, nm: String) -> Mesh:
	if _mesh_cache.has(nm): return _mesh_cache[nm]
	var m: Mesh = null
	# FROM THE GAME when the entry came from the game. A catalogue entry's
	# "mesh" is a resolved group key, not a file stem, so it goes straight to
	# the reader - same MeshSet path the props take, same texture chain, same
	# cache.
	if mc != null and mc.game_source != null and nm.contains("|"):
		m = mc.game_source.mesh_for(nm)
		_mesh_cache[nm] = m
		return m
	var gp := "%s/%s.glb" % [PROPS_CACHE, nm]
	if FileAccess.file_exists(gp):
		var inst: Node = mc._load_external_glb(gp)   # live root, ours to free
		if inst != null:
			var pair: Array = mc._first_mesh_and_xf(inst, Transform3D())
			if not pair.is_empty():
				m = mc._bake_mesh(pair[0], pair[1])
				if m == pair[0]:
					# the mesh outlives the node it came from (Resources are
					# refcounted), and it is about to be cached and shared —
					# never mutate the one the loader handed back
					m = (m as Mesh).duplicate()
				_foliage_fix(m)
				mc._wind_swap_materials(m)    # grass joins Foliage Wind
			inst.queue_free()
	_mesh_cache[nm] = m
	return m

# foliage-correct materials: double-sided alpha-cutout cards, no metal — grass
# GLBs export alphaMode OPAQUE, which would render the card rectangles solid.
static func _foliage_fix(mesh: Mesh) -> void:
	if not (mesh is ArrayMesh): return
	for s in range(mesh.get_surface_count()):
		var m := mesh.surface_get_material(s)
		if m is BaseMaterial3D:
			var bm := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
			bm.cull_mode = BaseMaterial3D.CULL_DISABLED
			bm.metallic = 0.0
			bm.roughness = 1.0
			if bm.albedo_texture != null:
				bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				bm.alpha_scissor_threshold = 0.35
			else:
				# kit whose atlas isn't extractable yet: plausible foliage green
				# beats the default white (e.g. ms_kal_groundcover_01)
				bm.albedo_color = Color(0.22, 0.31, 0.11)
			(mesh as ArrayMesh).surface_set_material(s, bm)
