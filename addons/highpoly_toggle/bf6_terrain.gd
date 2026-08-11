@tool
extends RefCounted
class_name BF6Terrain

# The level's terrain heightfield, out of the game's streaming tree.
#
# The map context builds its ground from a `height.r16` — a raw grid of u16
# heights plus the world bounds it spans — which the download ships at 32 MB per
# map. That grid is derivable: the game keeps its heights in a streaming-tree
# resource, as a quadtree of per-node sample grids with world-space AABBs.
#
# Ported from BF6_Frostbite_Research/formats/TERRAIN.md §2-§4, which specifies
# the container, the chunk directory and the heightfield grammar, and states
# which parts are verified against shipped data.
#
#   RES 0x22FE8AC8, one per level
#     +0x00  34-byte container header (NodeCount at +0x19)
#     +0x22  typed blocks: u8 type, i32 size, payload — 0xFF ends the list
#            block 0 = heights, 2 = density, 1 = splat, 4/5 = masks, 7/8 = rasters
#     then   the chunk directory quadtree (NOT a typed block)
#
# A height node is a world-space AABB plus xs² u16 samples, and the samples can
# be INLINE in the RES, in the node's OWN CAS chunk, or packed into the PARENT's
# paired chunk with the four children in REVERSED order. All three occur.

const HEADER_SIZE := 0x22
const BLOCK_HEADER := 0x48
const BLOCK_HEIGHTS := 0
const BLOCK_DENSITY := 2

var error := ""
var xs := 0                      # NodeSamplesPerSide
var border := 0                  # NodeBorderWidth — see composite()
var world_size_y := 0.0          # height scale
var node_count := 0
var data_size := 0               # per-node payload stride (== InlineValueBytes)
var nodes: Array = []            # [{aabb_min, aabb_max, key, values or chunk ref}]

var _packed_bytes := 0
var _section_bytes := 0
var _density_bytes := 0


# Stack(depth, occluder) from TERRAIN.md §4.2. The per-node section sizes derive
# entirely from header fields — the constants 340/1156/1225 and 1364/4358/4489
# that circulate as per-xs magic numbers are this function's outputs.
static func _stack(depth: int, occluder: bool) -> int:
	if depth <= 0:
		return 0
	var b0 := 1 << (depth - 1)
	var total := 0
	for c in range(depth):
		var b := b0 >> c
		total += (b + 1) * (b + 1) if occluder else 2 * b * b
	return total


# -> the payload of the requested typed block, or an empty array.
#
# The 0xFF terminator is an empirical rule that holds on every shipped map but
# was never located in engine code, so a malformed walk must fail loudly rather
# than run off the end: every step is bounds-checked against the RES size.
func find_block(res: PackedByteArray, want_type: int) -> PackedByteArray:
	error = ""
	if res.size() < HEADER_SIZE:
		error = "shorter than the 34-byte container header"
		return PackedByteArray()
	node_count = int(res.decode_s32(0x19))
	var o := HEADER_SIZE
	while o + 5 <= res.size():
		var t := int(res[o])
		if t == 0xFF:
			break
		var sz := int(res.decode_s32(o + 1))
		if sz < 0 or o + 5 + sz > res.size():
			error = "block %d claims %d bytes at %d, past the end" % [t, sz, o]
			return PackedByteArray()
		if t == want_type:
			return res.slice(o + 5, o + 5 + sz)
		o += 5 + sz
	error = "no block of type %d" % want_type
	return PackedByteArray()


# Parse a heightfield block's 72-byte header and precompute the section sizes.
func read_block_header(b: PackedByteArray) -> bool:
	error = ""
	if b.size() < BLOCK_HEADER:
		error = "heightfield block shorter than its 72-byte header"
		return false
	xs = int(b.decode_s32(0x00))
	# NOT a constant 4. §4.4 quotes "a 4-sample pad border" and every map
	# measured does have 4, but the header carries the number at +0x44 and a map
	# that shipped a different one would silently shift the whole heightfield.
	border = int(b.decode_s32(0x44))
	if border < 0 or border * 2 >= xs:
		border = 0
	world_size_y = b.decode_float(0x10)
	var minmax_depth := int(b.decode_s32(0x1C))
	var occluder_depth := int(b.decode_s32(0x20))
	var density_side := int(b.decode_s32(0x24))
	if xs <= 0 or xs > 8192:
		error = "implausible NodeSamplesPerSide %d" % xs
		return false
	# Cross-check the spec's identity rather than trusting one field:
	# DensityMapNodeSamplesPerSide == (xs-1)/4 + 1, verified for both observed
	# xs. A mismatch means the header is being read at the wrong offset, which
	# would otherwise show up much later as a stride that is slightly wrong.
	var expect_density := int((xs - 1) / 4) + 1
	if density_side != expect_density:
		error = ("density side %d != (xs-1)/4+1 = %d — header offsets are wrong"
			% [density_side, expect_density])
		return false
	_packed_bytes = _stack(minmax_depth, false) * 2
	_section_bytes = _packed_bytes + _stack(occluder_depth, true) * 2
	_density_bytes = density_side * density_side
	data_size = xs * xs * 2 + _section_bytes + _density_bytes
	return true


# Pre-order DFS over the node grammar (§4.3). Collects every node that carries
# height values, with its world AABB. `fetch` resolves a chunk guid to bytes;
# pass an invalid Callable to read inline nodes only.
func walk_nodes(b: PackedByteArray) -> bool:
	nodes.clear()
	var pos := [BLOCK_HEADER]
	var ok := _node(b, pos, 3, 0)
	if ok and pos[0] != b.size():
		# The walk is specified as byte-exact. Anything else means the grammar
		# desynchronised, and the nodes read so far are not trustworthy even
		# though they look plausible.
		error = "walk consumed %d of %d bytes" % [pos[0], b.size()]
		return false
	return ok


func _node(b: PackedByteArray, pos: Array, key: int, depth: int) -> bool:
	var p: int = pos[0]
	if p + 29 > b.size():
		error = "node header past the end at %d" % p
		return false
	var lo := Vector3(b.decode_float(p), b.decode_float(p + 4), b.decode_float(p + 8))
	var hi := Vector3(b.decode_float(p + 12), b.decode_float(p + 16),
		b.decode_float(p + 20))
	p += 28                                  # 6 floats + the unused 7th
	var kind := int(b[p]); p += 1
	if kind == 1:
		# EMPTY leaf: ends here, with no flags and no children.
		pos[0] = p
		return true
	if p + 4 > b.size():
		error = "node flags past the end at %d" % p
		return false
	var skip_packed := int(b[p])
	var inline_values := int(b[p + 3])
	p += 4

	var vals := PackedByteArray()
	if skip_packed != 0:
		# PRUNED: only the min/max pyramid is inline, no samples.
		if p + _packed_bytes > b.size():
			error = "pruned payload past the end at %d" % p
			return false
		p += _packed_bytes
	elif inline_values != 0:
		if p + data_size > b.size():
			error = "inline payload past the end at %d" % p
			return false
		vals = b.slice(p, p + xs * xs * 2)
		p += data_size
	# else EXTERNAL: the samples live in a CAS chunk, resolved by the caller
	# through the chunk directory. Recorded as a node with no values.

	nodes.append({"key": key, "min": lo, "max": hi, "values": vals,
		"external": vals.is_empty() and skip_packed == 0, "depth": depth})

	if p + 1 > b.size():
		error = "child flag past the end at %d" % p
		return false
	var has_children := int(b[p]); p += 1
	pos[0] = p
	if has_children != 0:
		for i in range(4):
			if not _node(b, pos, (key << 4) | i, depth + 1):
				return false
	return true


# ---------------------------------------------------------------------------
# THE CHUNK DIRECTORY (§3), which is where the heights actually are.
#
# The heights block is only 10 KB on Dumbo because it carries the tree SHAPE:
# every one of its 100 value nodes is External, and the samples live in CAS
# chunks. The directory sits immediately after the typed-block list's 0xFF
# terminator — it is not itself a typed block — and walks the same quadtree keys
# so a height node's chunk is the directory node with the SAME KEY.
#
#   u32  PrimarySize
#   Guid PrimaryGuid       (16 bytes, .NET LE layout)
#   u8   hasPair           -> u32 PairedSize, Guid PairedGuid
#   u8   persistentDedicatedServer
#   u8   hasChildren       -> exactly 4 children, depth first
#
# -> key -> {primary, primary_size, paired, paired_size}
func read_chunk_directory(res: PackedByteArray) -> Dictionary:
	error = ""
	var o := HEADER_SIZE
	while o + 5 <= res.size():
		if int(res[o]) == 0xFF:
			o += 1
			break
		var sz := int(res.decode_s32(o + 1))
		if sz < 0 or o + 5 + sz > res.size():
			error = "block overruns while looking for the directory"
			return {}
		o += 5 + sz
	var out := {}
	var pos := [o]
	if not _dir_node(res, pos, 3, out):
		return {}
	if pos[0] != res.size():
		# Specified to consume to exact EOF. Anything else means the directory
		# grammar desynchronised and the guids are not to be trusted.
		error = "chunk directory consumed %d of %d bytes" % [pos[0], res.size()]
		return {}
	return out


func _dir_node(res: PackedByteArray, pos: Array, key: int, out: Dictionary) -> bool:
	var p: int = pos[0]
	if p + 21 > res.size():
		error = "directory node past the end at %d" % p
		return false
	var e := {"primary_size": int(res.decode_u32(p)),
		"primary": _guid(res, p + 4), "paired": "", "paired_size": 0}
	p += 20
	var has_pair := int(res[p]); p += 1
	if has_pair != 0:
		if p + 20 > res.size():
			error = "paired chunk past the end at %d" % p
			return false
		e["paired_size"] = int(res.decode_u32(p))
		e["paired"] = _guid(res, p + 4)
		p += 20
	if p + 2 > res.size():
		error = "directory flags past the end at %d" % p
		return false
	p += 1                                   # persistentDedicatedServer
	var has_children := int(res[p]); p += 1
	out[key] = e
	pos[0] = p
	if has_children != 0:
		for i in range(4):
			if not _dir_node(res, pos, (key << 4) | i, out):
				return false
	return true


# RAW HEX of the 16 bytes, not the dashed .NET spelling.
#
# The chunk index is keyed on `guid.hex_encode()` — the bytes as they lie — so
# the canonical mixed-endian text form that reads nicely in a spec resolves
# nothing at all: the first attempt produced dashed guids and found 0 of 100
# chunks while every other stage parsed byte-exactly.
static func _guid(b: PackedByteArray, o: int) -> String:
	if o + 16 > b.size():
		return ""
	return b.slice(o, o + 16).hex_encode()


# Fill in the External nodes' samples from their chunks.
#
# A node's values are in its OWN primary chunk when the directory has one for
# that key; otherwise in the PARENT's paired chunk, where the four children are
# concatenated in REVERSED order — read order [3,2,1,0] — at a fixed stride of
# DataSize. Getting that reversal wrong does not fail, it silently swaps
# quadrants of the map.
func resolve_external(dir: Dictionary, fetch: Callable) -> int:
	var got := 0
	var want := xs * xs * 2
	for n in nodes:
		var nd: Dictionary = n
		if not nd["external"]:
			continue
		var key: int = int(nd["key"])
		var e = dir.get(key)
		var data := PackedByteArray()
		if e != null and str((e as Dictionary)["primary"]) != "":
			data = _fetch_chunk(fetch, str((e as Dictionary)["primary"]))
		if data.size() >= want:
			nd["values"] = data.slice(0, want)
			nd["external"] = false
			got += 1
			continue
		# The parent's paired chunk, at the reversed-order offset.
		var parent_key: int = key >> 4
		var child_index: int = key & 0xF
		var pe = dir.get(parent_key)
		if pe == null or str((pe as Dictionary)["paired"]) == "":
			continue
		var pdata := _fetch_chunk(fetch, str((pe as Dictionary)["paired"]))
		if pdata.is_empty():
			continue
		var off: int = (3 - child_index) * data_size
		if off + want <= pdata.size():
			nd["values"] = pdata.slice(off, off + want)
			nd["external"] = false
			got += 1
	return got


var _chunk_cache := {}


func _fetch_chunk(fetch: Callable, guid: String) -> PackedByteArray:
	if guid == "":
		return PackedByteArray()
	if _chunk_cache.has(guid):
		return _chunk_cache[guid]
	# BOTH SPELLINGS. A chunk id is stored plain but indexed reversed in places,
	# and forgetting the reversed form fails on a SUBSET of nodes rather than
	# all of them — the worst kind to find later.
	var b := PackedByteArray()

	for form in [guid, _reverse_guid(guid)]:
		var got = fetch.call(str(form))
		if got is PackedByteArray and not (got as PackedByteArray).is_empty():
			b = got
			break
	_chunk_cache[guid] = b
	return b


static func _reverse_guid(g: String) -> String:
	var hex := g.replace("-", "")
	if hex.length() != 32:
		return g
	var bytes := PackedByteArray()
	for i in range(16):
		bytes.append(hex.substr(i * 2, 2).hex_to_int())
	bytes.reverse()
	return bytes.hex_encode()


# ---------------------------------------------------------------------------
# Composite the leaves into one square grid.
#
# The tree is a quadtree of overlapping detail levels, so the deepest node
# covering a texel wins — drawing them in depth order gives the finest data
# available everywhere without needing to know which levels exist.
#
# EVERY TILE HAS A PAD BORDER, and it is not the tile's own ground.
#
# §4.4 specifies a border of `NodeBorderWidth` samples on all four sides, so a
# node's AABB is spanned by grid[border .. xs-1-border] and the rest is a copy of
# whatever is next door. This used to sample 0..xs-1, which did two things at
# once: it stretched each tile's 257 real samples across 265 destination texels,
# shrinking every feature by 3.1%, and it painted 4 samples of the NEIGHBOUR's
# terrain into each tile edge, so tile boundaries carried a doubled ridge.
#
# The border is measurable rather than assumed. Over 40 x-adjacent same-depth
# node pairs on mp_dumbo, the shared-edge prediction A[xs-1-border] == B[border]
# holds 40/40 while the no-border reading A[xs-1] == B[0] holds 0/40, and all
# 160 of the pad columns are exactly the neighbour's interior columns. Two
# unrelated heightfields do not agree on a whole column of u16s.
#
# -> {"data": PackedByteArray (u16 LE), "size": int, "min": Vector3,
#     "max": Vector3} or {} on failure.
# ---------------------------------------------------------------------------

# THE RESOLUTION THE GAME ACTUALLY HAS, rather than one we picked.
#
# composite() paints every node carrying heights into one grid, deepest last,
# and its size was hardcoded at 4097. That is a number with no authority behind
# it: too small throws away the detail the deepest nodes carry, too large invents
# samples that are the same value repeated. Either way the ground is not what the
# game says it is, and "the ground is not sharp enough" cannot be answered by a
# setting when the data feeding it was fixed by a constant.
#
# The tree answers it directly. The deepest level divides the map into 2^depth
# nodes per side, each carrying (xs - 1 - 2*border) samples of its own ground, so
# the finest grid the data supports is that many per side, plus one for the
# closing grid line.
#
# -> samples per side, or 0 if no node carries heights.
func native_size() -> int:
	var d := -1
	for n in nodes:
		var nd: Dictionary = n
		if not (nd["values"] as PackedByteArray).is_empty():
			d = maxi(d, int(nd["depth"]))
	if d < 0:
		return 0
	return (1 << d) * maxi(1, xs - 1 - border * 2) + 1


# What the composite spends and how much of it is overdraw. Counted before
# anything is changed: the splat composite taught that the obvious target (the
# reads) was 0.7 s of 135 s and the paint was the rest.
var us_paint := 0
var texels := 0


func composite(size := 4096) -> Dictionary:
	var with_vals: Array = []
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for n in nodes:
		var nd: Dictionary = n
		lo = Vector3(minf(lo.x, nd["min"].x), minf(lo.y, nd["min"].y),
			minf(lo.z, nd["min"].z))
		hi = Vector3(maxf(hi.x, nd["max"].x), maxf(hi.y, nd["max"].y),
			maxf(hi.z, nd["max"].z))
		if not (nd["values"] as PackedByteArray).is_empty():
			with_vals.append(nd)
	if with_vals.is_empty() or lo.x >= INF:
		error = "no nodes carry height values"
		return {}
	with_vals.sort_custom(func(a, b): return int(a["depth"]) < int(b["depth"]))

	var out := PackedByteArray()
	out.resize(size * size * 2)
	var span_x: float = maxf(0.001, hi.x - lo.x)
	var span_z: float = maxf(0.001, hi.z - lo.z)
	# HOW MUCH OF THIS PAINT IS THROWN AWAY. The pyramid is concentric - a
	# coarse node covers the whole map and the fine tiers cover the middle - so
	# painting depth-ascending means the coarse pass writes texels that a finer
	# node overwrites moments later. Nothing had ever counted how many, and the
	# phase is 109-118 s cold, so the number decides whether the fix is worth
	# anything at all.
	us_paint = 0
	texels = 0
	for n in with_vals:
		var nd: Dictionary = n
		var v: PackedByteArray = nd["values"]
		var nlo: Vector3 = nd["min"]
		var nhi: Vector3 = nd["max"]
		# Destination rectangle for this node, in grid texels.
		var x0 := int(floorf((nlo.x - lo.x) / span_x * size))
		var x1 := int(ceilf((nhi.x - lo.x) / span_x * size))
		var z0 := int(floorf((nlo.z - lo.z) / span_z * size))
		var z1 := int(ceilf((nhi.z - lo.z) / span_z * size))
		x0 = clampi(x0, 0, size); x1 = clampi(x1, 0, size)
		z0 = clampi(z0, 0, size); z1 = clampi(z1, 0, size)
		if x1 <= x0 or z1 <= z0:
			continue
		# The node's own samples run from `border` to `xs-1-border` inclusive;
		# everything outside that is the neighbour's, repeated.
		#
		# BILINEAR, not nearest. The pyramid is concentric - 8 m/sample covers
		# the whole map while the fine tiers only cover the centre
		# (fleet-measured: 0.5 m over just 0.4-0.7% of the map) - so away from
		# the middle a coarse node is upsampled 4-16x into this grid, and
		# nearest turned every outskirt slope into 8 m stair steps.
		var s0 := border
		var s1 := xs - 1 - border
		var ssp := float(maxi(1, s1 - s0))
		texels += (x1 - x0) * (z1 - z0)
		var _tp := Time.get_ticks_usec()
		for gz in range(z0, z1):
			var fz: float = float(gz - z0) / float(maxi(1, z1 - z0 - 1)) if z1 - z0 > 1 else 0.0
			var sfy: float = clampf(float(s0) + fz * ssp, 0.0, float(xs - 1))
			var sy0: int = mini(int(sfy), xs - 2)
			var tz: float = sfy - float(sy0)
			for gx in range(x0, x1):
				var fx: float = float(gx - x0) / float(maxi(1, x1 - x0 - 1)) if x1 - x0 > 1 else 0.0
				var sfx: float = clampf(float(s0) + fx * ssp, 0.0, float(xs - 1))
				var sx0: int = mini(int(sfx), xs - 2)
				var tx: float = sfx - float(sx0)
				var r0 := (sy0 * xs + sx0) * 2
				var r1 := r0 + xs * 2
				if r1 + 3 >= v.size():
					continue
				var h0 := lerpf(float(v.decode_u16(r0)), float(v.decode_u16(r0 + 2)), tx)
				var h1 := lerpf(float(v.decode_u16(r1)), float(v.decode_u16(r1 + 2)), tx)
				out.encode_u16((gz * size + gx) * 2,
					clampi(int(round(lerpf(h0, h1, tz))), 0, 65535))
		us_paint += Time.get_ticks_usec() - _tp
	return {"data": out, "size": size, "min": lo, "max": hi,
		"world_size_y": world_size_y, "nodes": with_vals.size(),
		"us_paint": us_paint, "texels": texels, "grid": size * size}
