@tool
extends RefCounted
class_name BF6MaterialTree

# Terrain block 7 — the TerrainMaterialTree — and the per-texel base layer it
# resolves to. Ported from TERRAIN.md §7 and §8.
#
# WHY THIS IS NOT OPTIONAL. The obvious reading of §5 is that the weight pages
# are the splat and the base field is a residual tidy-up, and that reading gives
# a ground made of two textures. Measured on mp_dumbo:
#
#   layers appearing as a PAINTED record (weight page):  30, textured:  2
#   layers appearing as a BASE record (no page):         16, textured: 11
#
# The palette's actual materials — cobblestone, concrete tile, broken asphalt,
# asphalt edge, gravel — are all on the base side. The weight pages say where
# the painted layers go; THIS says what the ground is made of underneath, which
# is nearly all of what it looks like.
#
# Structure:
#   header  dim, blurriness, world bounds, nodeCount, persistentNodeCount, levelMax
#   nodes   ONE depth-first quadtree, two leading flags and a TRAILING
#           hasChildren — the trailing position is the framing trap §7.2 warns
#           about, and taking three leading flags limps along for most of the
#           stream before failing near the end
#   rows    nibble-RLE, two 4-bit texels per byte (§7.3), verified engine-exact
#   footer  materialPairIndices + BackgroundMaterialIndex (§7.4)
#
# Each decoded 4-bit texel indexes the pair table; each pair entry names a list
# and two nibble indices into it (§8).

const HDR := 0x24                    # block 7 node stream starts here

var error := ""
var dim := 0
var levels := 0
var world_min := Vector2.ZERO
var world_max := Vector2.ZERO
var node_count := 0
var pairs: PackedInt32Array = PackedInt32Array()
var background := 0
var nodes: Array = []                # {key, depth, rows: PackedByteArray (dim*dim)}

var _d := PackedByteArray()
var _p := 0

const CHILD_X := [0, 1, 1, 0]
const CHILD_Z := [0, 0, 1, 1]


func parse(b7: PackedByteArray) -> bool:
	error = ""
	nodes.clear()
	if b7.size() < HDR:
		error = "block 7 shorter than its header"
		return false
	_d = b7
	dim = int(b7.decode_u32(0x00))
	world_min = Vector2(b7.decode_float(0x08), b7.decode_float(0x0C))
	world_max = Vector2(b7.decode_float(0x10), b7.decode_float(0x14))
	node_count = int(b7.decode_u32(0x18))
	levels = int(b7.decode_u32(0x20))
	if dim <= 0 or dim > 4096:
		error = "implausible raster dim %d" % dim
		return false
	_p = HDR
	if not _node(3, 0):
		return false
	# §7.4: the footer follows the root's trailing hasChildren, and the block
	# ends EXACTLY after it. That exactness is the check that the node walk did
	# not slip — a framing error leaves the footer somewhere else entirely.
	if _p + 8 > _d.size():
		error = "no room for the pair footer at %d" % _p
		return false
	var n := int(_d.decode_u32(_p))
	if n < 0 or n > 256 or _p + 4 + n * 4 + 4 != _d.size():
		error = "pair table of %d does not end the block (%d of %d)" % [n, _p, _d.size()]
		return false
	pairs.resize(n)
	for i in range(n):
		pairs[i] = int(_d.decode_u32(_p + 4 + i * 4))
	background = int(_d.decode_u32(_p + 4 + n * 4))
	return true


func _node(key: int, depth: int) -> bool:
	if _p + 2 > _d.size():
		error = "node %d flags past the end" % key
		return false
	var has_data := int(_d[_p])
	var has_persistent := int(_d[_p + 1])
	# §7.2: all three flag bytes are strictly 0 or 1 on every shipped block, so
	# anything else means the frame has slipped. Cheap and reliable.
	if has_data > 1 or has_persistent > 1:
		error = "node %d flags are %d/%d, not 0/1 — the frame has slipped" % [
			key, has_data, has_persistent]
		return false
	_p += 2
	var rows := PackedByteArray()
	if has_data != 0 and has_persistent != 0:
		if _p + 4 > _d.size():
			error = "node %d payload size past the end" % key
			return false
		var sz := int(_d.decode_s32(_p))
		_p += 4
		if sz < 0 or _p + sz + dim * 2 > _d.size():
			error = "node %d payload of %d past the end" % [key, sz]
			return false
		var payload_at := _p
		_p += sz
		var sizes_at := _p
		_p += dim * 2
		var total := 0
		for r in range(dim):
			total += int(_d.decode_u16(sizes_at + r * 2))
		if total != sz:
			error = "node %d: row sizes sum to %d, payload is %d" % [key, total, sz]
			return false
		rows.resize(dim * dim)
		var at := payload_at
		for r in range(dim):
			var rl := int(_d.decode_u16(sizes_at + r * 2))
			if not _decode_row(_d, at, rl, dim, rows, r * dim):
				error = "node %d row %d does not decode cleanly" % [key, r]
				return false
			at += rl
	if _p + 1 > _d.size():
		error = "node %d child flag past the end" % key
		return false
	var has_children := int(_d[_p])
	if has_children > 1:
		error = "node %d hasChildren is %d — the frame has slipped" % [key, has_children]
		return false
	_p += 1
	if not rows.is_empty():
		nodes.append({"key": key, "depth": depth, "rows": rows})
	if has_children != 0:
		for i in range(4):
			if not _node((key << 4) | i, depth + 1):
				return false
	return true


# §7.3's engine decoder at 0x145728250, byte for byte.
#
# Two 4-bit texels per RLE byte, low nibble first. The first byte of a row is
# the initial value; after that a byte EQUAL to the current value means the next
# byte is a run length in 2-texel groups, and a byte that differs is an implicit
# single group and becomes the current value.
#
# A clean row produces exactly `dim` texels AND consumes exactly its bytes.
static func _decode_row(d: PackedByteArray, at: int, rl: int, dim: int,
		out: PackedByteArray, o: int) -> bool:
	if rl <= 0 or at + rl > d.size():
		return false
	var src := 0
	var current := int(d[at])
	src += 1
	var groups := 0
	var x := 0
	while x < dim:
		while groups * 2 < x:
			if src >= rl:
				return false
			var b := int(d[at + src]); src += 1
			var run := 1
			if b == current:
				if src >= rl:
					return false
				run = int(d[at + src]); src += 1
			current = b
			groups += run
		out[o + x] = current & 0xF
		if x + 1 < dim:
			out[o + x + 1] = (current >> 4) & 0xF
		x += 2
	return src == rl


# ---------------------------------------------------------------------------
# §8: a pair entry -> a layer index.
#
#   e & 0xFF          framing, 0x80
#   (e >> 8) & 0xFF   X: low nibble primary, high nibble secondary, 15 = none
#   (e >> 16) & 0xF   Y-lo: which list  (1 node base, 0 full, 2 linked)
#   (e >> 20) & 0xF   Y-hi: clipmap level tag, not needed to resolve
#   (e >> 24) & 0xFF  framing, 0x06
# ---------------------------------------------------------------------------
static func entry_list_kind(e: int) -> int:
	return (e >> 16) & 0xF


static func entry_primary(e: int) -> int:
	return (e >> 8) & 0xF


static func entry_secondary(e: int) -> int:
	return (e >> 12) & 0xF


static func entry_is_framed(e: int) -> bool:
	return (e & 0xFF) == 0x80 and ((e >> 24) & 0xFF) == 0x06


# -> the layer index a texel value resolves to, or -1.
#
# `lists` is {0: full list, 1: node base list, 2: linked list}, each an Array of
# layer indices in ascending order. Try the primary nibble, then the secondary,
# then give up — 15 is the "none" sentinel and is not an index.
func resolve(texel: int, lists: Dictionary) -> int:
	var pi := texel & 0xF
	if pi >= pairs.size():
		return -1
	var e := int(pairs[pi])
	if e == 0 or not entry_is_framed(e):
		return -1
	var kind := entry_list_kind(e)
	var list = lists.get(kind)
	if list == null:
		# §8's practical fallback: a map with no linked layers resolves kind 2
		# against the base list, and a node with an empty base list uses the
		# map-global no-page list.
		list = lists.get(1, lists.get(0, []))
	var arr: Array = list
	for nib in [entry_primary(e), entry_secondary(e)]:
		if int(nib) == 15:
			continue
		if int(nib) < arr.size():
			return int(arr[int(nib)])
	return -1


static func bounds_of(key: int, root_lo: Vector2, root_hi: Vector2) -> Array:
	var path: Array = []
	var k := key
	while k > 3:
		path.push_front(k & 0xF)
		k >>= 4
	var lo := root_lo
	var hi := root_hi
	for i in path:
		var half := (hi - lo) * 0.5
		lo = Vector2(lo.x + half.x * float(CHILD_X[int(i)]),
			lo.y + half.y * float(CHILD_Z[int(i)]))
		hi = lo + half
	return [lo, hi]


# ---------------------------------------------------------------------------
# The whole base field, rasterised coarse-first so finer nodes overwrite.
#
# `base_list_for` is called with a node key and returns that node's ascending
# no-page layer list; `full_list` and `linked_list` are map-global.
#
# -> PackedByteArray of `size*size` layer indices, 255 where nothing resolved.
# ---------------------------------------------------------------------------
func rasterize(size: int, base_list_for: Callable, full_list: Array,
		linked_list: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(size * size)
	out.fill(255)
	var span := world_max - world_min
	if span.x <= 0.0 or span.y <= 0.0:
		error = "block 7 has an empty world bounds"
		return out
	var order: Array = nodes.duplicate()
	order.sort_custom(func(a, b): return int(a["depth"]) < int(b["depth"]))
	for n in order:
		var nd: Dictionary = n
		var key := int(nd["key"])
		var lists := {0: full_list, 1: base_list_for.call(key), 2: linked_list}
		# One resolve per DISTINCT texel value rather than per texel: the values
		# are 4-bit, so there are at most 16 answers for a whole 256x256 node and
		# resolving each of the 65,536 separately is the same answer 4,000 times.
		var lut := PackedInt32Array()
		lut.resize(16)
		for v in range(16):
			lut[v] = resolve(v, lists)
		var b: Array = bounds_of(key, world_min, world_max)
		var lo: Vector2 = b[0]
		var hi: Vector2 = b[1]
		var x0 := clampi(int(floor((lo.x - world_min.x) / span.x * size)), 0, size)
		var x1 := clampi(int(ceil((hi.x - world_min.x) / span.x * size)), 0, size)
		var z0 := clampi(int(floor((lo.y - world_min.y) / span.y * size)), 0, size)
		var z1 := clampi(int(ceil((hi.y - world_min.y) / span.y * size)), 0, size)
		if x1 <= x0 or z1 <= z0:
			continue
		var rows: PackedByteArray = nd["rows"]
		for gz in range(z0, z1):
			var fz := float(gz - z0) / float(maxi(1, z1 - z0 - 1)) if z1 - z0 > 1 else 0.0
			var sy := clampi(int(fz * float(dim - 1)), 0, dim - 1) * dim
			var drow := gz * size
			for gx in range(x0, x1):
				var fx := float(gx - x0) / float(maxi(1, x1 - x0 - 1)) if x1 - x0 > 1 else 0.0
				var l := int(lut[int(rows[sy + clampi(int(fx * float(dim - 1)), 0, dim - 1)]) & 0xF])
				if l >= 0 and l < 255:
					out[drow + gx] = l
	return out


func stats() -> Dictionary:
	var framed := 0
	var kinds := {}
	for e in pairs:
		if entry_is_framed(int(e)):
			framed += 1
			var k := entry_list_kind(int(e))
			kinds[k] = int(kinds.get(k, 0)) + 1
	return {"nodes": nodes.size(), "declared": node_count, "pairs": pairs.size(),
		"framed": framed, "kinds": kinds, "dim": dim, "levels": levels,
		"background": background}
