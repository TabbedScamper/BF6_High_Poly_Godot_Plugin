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
# masks are now DECODED: maps whose package ships splat/grass_mask.png (the
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
var density := 3.0            # dock slider: 1.0 = raw DB-budget reading (sparse);
                              # true density unknown until splat masks are decoded
var last_regen_ms := 0        # debug: last regeneration cost
var last_instances := 0       # debug: instances currently placed

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
# REAL grass coverage (splat/grass_mask.png, baked from the game's own terrain
# layer masks by the pipeline's splat_build.py). When present it REPLACES the
# slope-band + maptile-greenness heuristic as the anchor accept weight; slope
# stays only as a cliff sanity clamp. Maps without the file keep the heuristic.
var _mask: Image = null
var _mask_b := Vector4()      # xmin, zmin, sizeX, sizeZ (splat bake box)
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
	_mask = null
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
	var sj := "%s/scatter.json" % dir
	if not FileAccess.file_exists(sj): return 0
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(sj))
	if not (d is Dictionary): return 0
	var ents: Array = (d as Dictionary).get("entries", [])
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
	_budget = int((d as Dictionary).get("budget", 16384))
	# optional maptile for greenness weighting
	if tile.has("img"):
		var gp := ProjectSettings.globalize_path(str(tile["img"]))
		var img := Image.new()
		if img.load(gp) == OK:
			_tile = img
			_tile_b = tile.get("bounds", Vector4())
	# REAL grass coverage from the map package's splat bake (preferred over the
	# heuristic): grass_mask.png = combined coverage of the map's grass layers,
	# world box from splat/layers.json
	var mp := "%s/splat/grass_mask.png" % dir
	var lj := "%s/splat/layers.json" % dir
	if FileAccess.file_exists(mp) and FileAccess.file_exists(lj):
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(lj))
		if meta is Dictionary and (meta as Dictionary).get("world", {}) is Dictionary:
			var wj: Dictionary = (meta as Dictionary)["world"]
			var mimg := Image.load_from_file(ProjectSettings.globalize_path(mp))
			if mimg != null:
				_mask = mimg
				_mask_b = Vector4(float(wj.get("x0", 0.0)), float(wj.get("z0", 0.0)),
					float(wj.get("size", 1.0)), float(wj.get("size", 1.0)))
				print("MapContext[%s]: scatter uses the real grass-layer mask" % map)
	_root = Node3D.new()
	_root.name = NODE
	ctx.add_child(_root)
	_root.owner = null
	var skipped: Array = []
	for e in ents:
		if not (e is Dictionary) or not e.has("mesh") or not e.has("kit"): continue
		var nm := str(e["mesh"])
		var mesh := _scatter_mesh(mc, nm)
		if mesh == null:
			skipped.append(nm)
			continue
		var kit := PackedVector3Array()
		for p in e["kit"]:
			if p is Array and p.size() >= 2:
				kit.append(Vector3(float(p[0]), float(p[1]), float(p[2]) if p.size() > 2 else 0.0))
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
		var share := float(e.get("budgetShare", 1.0 / ents.size()))
		_entries.append({
			"kit": kit,
			"spacing": maxf(1.0, float(e.get("spacing", 16.0))),
			"radius": minf(CULL_R, float(e.get("viewDistance", CULL_R))),
			"cap": maxi(8, int(ceil(share * _budget * 1.2))),
			"seed": nm.hash(),
			"mmi": mmi,
		})
	if _entries.is_empty():
		clear()
		return 0
	if not skipped.is_empty():
		print("MapContext[%s]: scatter — %d kit meshes not cached yet (%s…)" %
			[map, skipped.size(), skipped[0]])
	active = true
	return _entries.size()

func set_density(v: float, cam_pos: Vector3) -> void:
	density = clampf(v, 0.1, 8.0)
	if active:
		_regenerate(cam_pos)

# regenerate when the camera crosses a REGEN_CELL boundary
func tick(cam_pos: Vector3) -> void:
	if not active: return
	var cell := Vector2i(int(floor(cam_pos.x / REGEN_CELL)), int(floor(cam_pos.z / REGEN_CELL)))
	if cell == _last_cell: return
	_last_cell = cell
	_regenerate(cam_pos)

func _regenerate(cam_pos: Vector3) -> void:
	var t0 := Time.get_ticks_msec()
	var total := 0
	for e in _entries:
		var buf := _gen_entry(e, cam_pos)
		var cnt := int(buf.size() / 12)
		var mm: MultiMesh = (e["mmi"] as MultiMeshInstance3D).multimesh
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
	# density is a free parameter until the terrain splat masks are decoded —
	# the DB budget reading is conservative; the dock slider scales it
	var spacing: float = e["spacing"] / sqrt(maxf(0.05, density))
	var radius: float = e["radius"]
	var cap: int = int(e["cap"] * maxf(0.05, density))
	var seed_i: int = e["seed"]
	var buf := PackedFloat32Array()
	buf.resize(cap * 12)
	var w := 0                          # write cursor (floats)
	var r2 := radius * radius
	var near2 := NEAR_R * NEAR_R
	var cx0 := int(floor((cam.x - radius) / spacing))
	var cx1 := int(floor((cam.x + radius) / spacing))
	var cz0 := int(floor((cam.z - radius) / spacing))
	var cz1 := int(floor((cam.z + radius) / spacing))
	var count := 0
	for cz in range(cz0, cz1 + 1):
		for cx in range(cx0, cx1 + 1):
			# jittered, deterministic anchor inside the cell
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
			if _mask != null:
				# EXACT accept weight: the game's own grass-layer coverage here
				wgt = _mask_weight(ax, az)
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

# real grass-layer coverage (bilinear); 0 outside the splat box — the box is
# the whole playable maptile area, so no more heuristic desert scatter beyond it
func _mask_weight(x: float, z: float) -> float:
	var u := (x - _mask_b.x) / _mask_b.z
	var v := (z - _mask_b.y) / _mask_b.w
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return 0.0
	var fx := u * float(_mask.get_width() - 1)
	var fz := v * float(_mask.get_height() - 1)
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, _mask.get_width() - 1)
	var z1 := mini(z0 + 1, _mask.get_height() - 1)
	var tx := fx - float(x0)
	var tz := fz - float(z0)
	var m00 := _mask.get_pixel(x0, z0).r
	var m10 := _mask.get_pixel(x1, z0).r
	var m01 := _mask.get_pixel(x0, z1).r
	var m11 := _mask.get_pixel(x1, z1).r
	return lerpf(lerpf(m00, m10, tx), lerpf(m01, m11, tx), tz)

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
func _scatter_mesh(mc: Object, nm: String) -> Mesh:
	if _mesh_cache.has(nm): return _mesh_cache[nm]
	var m: Mesh = null
	var gp := "%s/%s.glb" % [PROPS_CACHE, nm]
	if FileAccess.file_exists(gp):
		var g: PackedScene = mc._load_external_glb(gp)
		if g != null:
			var inst: Node = g.instantiate()
			var pair: Array = mc._first_mesh_and_xf(inst, Transform3D())
			if not pair.is_empty():
				m = mc._bake_mesh(pair[0], pair[1])
				if m == pair[0]:
					m = (m as Mesh).duplicate()   # never mutate the packed scene's mesh
				_foliage_fix(m)
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
