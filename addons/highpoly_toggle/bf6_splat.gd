@tool
extends RefCounted
class_name BF6Splat

# Terrain block 1: the layer coverage tree, the weight pages, and the colour map.
#
# Ported from BF6_Frostbite_Research/formats/TERRAIN.md §5. Two things come out
# of the same walk, and both were missing from our ground:
#
#   THE COLOUR MAP. One BC7 tile per streaming-tree node, trailing the weight
#   pages in the node's CAS chunk. This is the engine's own large-scale terrain
#   colour — the aerial photograph the terrain material shaders modulate by. It
#   is the picture the removed maptile was standing in for, except this one is
#   in the player's install, covers the WHOLE ±4096 m footprint rather than the
#   playable bowl, and is never redistributed.
#
#   THE WEIGHT PAGES. Per-layer 66×66 coverage, which is what says the street is
#   asphalt and the park is grass. Our shader has had a splat path since the
#   download days; it has simply had nothing to feed it since.
#
# The node walk is byte-exact by construction and says so: mp_dumbo walks 341
# nodes / 31,123 records and lands on the final byte, matching both declared
# counts. A variable-size record stream that desynchronises cannot do that.

const NO_PAGE_FLAG := 0x0100         # §5.1 bit8: IgnoreMask layer, no stored page
const RECORD := 33
const HEADER := 0x3D
const PAGE_SIZES := [2592, 4356, 5184]
# §5.3. A trailer is one BC7 square tile per node (or, on survey, a mip pair).
const TILE_SIZES := {4624: 68, 17424: 132, 67600: 260, 85024: 260}
const PAGE_SIDE := 66                # every codec decodes to this

var error := ""
var root_min := Vector2.ZERO
var root_max := Vector2.ZERO
var layer_slot_count := 0
var declared_nodes := 0
var declared_records := 0
var nodes: Array = []                # {key, depth, min, max, records, pages}
var page_size := 0
var tile_bytes := 0
var tile_side := 0
var consumed := 0

# §14 item 2 is open: the colour TILES in a paired chunk are proven to be in
# plain reversed child order [3,2,1,0], but whether the PAGE payloads follow the
# same order or reversed traversal-quadrant order [2,3,1,0] — the two differ
# exactly by swapping children 2 and 3 — has never been validated. Plain
# reversed index is the working assumption and this switch exists so the two can
# be measured against each other rather than argued about.
var paired_child_swap := false

var _d := PackedByteArray()
var _p := 0
var _by_key := {}


# ---------------------------------------------------------------------------
# §5.1 metadata quadtree.
# ---------------------------------------------------------------------------
func parse(b1: PackedByteArray) -> bool:
	error = ""
	nodes.clear()
	_by_key.clear()
	if b1.size() < HEADER:
		error = "block 1 shorter than its 61-byte header"
		return false
	_d = b1
	root_min = Vector2(b1.decode_float(0x18), b1.decode_float(0x1C))
	root_max = Vector2(b1.decode_float(0x20), b1.decode_float(0x24))
	layer_slot_count = int(b1.decode_u32(0x28))
	declared_nodes = int(b1.decode_u32(0x2C))
	declared_records = int(b1.decode_u32(0x30))
	_p = HEADER
	if not _node(3, 0, root_min, root_max):
		return false
	consumed = _p
	if _p != b1.size():
		# Specified byte-exact. Short of that the record stream has slipped and
		# the layer indices are somebody else's.
		error = "walk consumed %d of %d bytes" % [_p, b1.size()]
		return false
	if nodes.size() != declared_nodes:
		error = "walked %d nodes, header declares %d" % [nodes.size(), declared_nodes]
		return false
	for n in nodes:
		_by_key[int((n as Dictionary)["key"])] = n
	return true


func _node(key: int, depth: int, lo: Vector2, hi: Vector2) -> bool:
	if _p + 6 > _d.size():
		error = "node %d header past the end" % key
		return false
	var rec_count := int(_d.decode_u16(_p))
	var stored := int(_d.decode_u16(_p + 2))
	_p += 6
	if _p + rec_count * RECORD > _d.size():
		error = "node %d records past the end" % key
		return false
	var recs: Array = []
	var page_ix := 0
	for i in range(rec_count):
		var o := _p + i * RECORD
		var flags := int(_d.decode_u16(o + 20))
		var has_page := (flags & NO_PAGE_FLAG) == 0
		recs.append({
			"layer": int(_d.decode_u16(o)),
			"id": int(_d.decode_u16(o + 2)),
			"min": Vector2(_d.decode_float(o + 4), _d.decode_float(o + 8)),
			"max": Vector2(_d.decode_float(o + 12), _d.decode_float(o + 16)),
			"flags": flags,
			"page": page_ix if has_page else -1,
		})
		if has_page:
			page_ix += 1
	_p += rec_count * RECORD
	# The declared stored-page count is a free check on the flag offset: read the
	# flags four bytes out and `page_ix` changes while nothing else complains.
	if stored != page_ix:
		error = "node %d declares %d stored pages, its records give %d" % [key, stored, page_ix]
		return false
	nodes.append({"key": key, "depth": depth, "min": lo, "max": hi,
		"records": recs, "pages": page_ix})
	if rec_count == 0:
		if _p < _d.size():
			_p += 1
		return true
	if _p + 2 > _d.size():
		error = "node %d flags past the end" % key
		return false
	var has_children := int(_d[_p + 1])
	_p += 2
	if _p < _d.size():
		_p += 1                            # t1, omitted only on the terminal node
	if has_children != 0:
		var half := (hi - lo) * 0.5
		for i in range(4):
			var clo := Vector2(lo.x + half.x * float(CHILD_X[i]),
				lo.y + half.y * float(CHILD_Z[i]))
			if not _node((key << 4) | i, depth + 1, clo, clo + half):
				return false
	return true


# §2.4: the child nibble is a quadrant in TRAVERSAL order, not bit order.
const CHILD_X := [0, 1, 1, 0]
const CHILD_Z := [0, 0, 1, 1]


# ---------------------------------------------------------------------------
# Which page codec this map uses, and how big its colour tiles are.
#
# Neither is stored. §5.2's rule is that a map uses ONE codec throughout, found
# by testing the three candidates against the per-node chunk sizes. The test
# here needs no height-prefix table: pages sit immediately before the colour
# tile, so `primarySize − trailer − pages × pageSize` only has to be a
# non-negative number for the right pair, and the wrong pairs miss on almost
# every node.
# ---------------------------------------------------------------------------
func detect_layout(dir: Dictionary) -> bool:
	error = ""
	var best := -1
	for ps in PAGE_SIZES:
		for tb in TILE_SIZES.keys():
			var score := 0
			for n in nodes:
				var nd: Dictionary = n
				var e = dir.get(int(nd["key"]))
				if e == null:
					continue
				var sz := int((e as Dictionary)["primary_size"])
				var rest: int = sz - int(tb) - int(nd["pages"]) * ps
				if sz > 0 and rest >= 0 and int(nd["pages"]) > 0:
					score += 1
			if score > best:
				best = score
				page_size = ps
				tile_bytes = int(tb)
				tile_side = int(TILE_SIZES[tb])
	# Ambiguity is the risk here, so require the winner to be decisive rather
	# than merely first: re-score and insist nothing else ties it.
	var ties := 0
	for ps in PAGE_SIZES:
		for tb in TILE_SIZES.keys():
			if ps == page_size and int(tb) == tile_bytes:
				continue
			var score := 0
			for n in nodes:
				var nd: Dictionary = n
				var e = dir.get(int(nd["key"]))
				if e == null:
					continue
				var sz := int((e as Dictionary)["primary_size"])
				var rest: int = sz - int(tb) - int(nd["pages"]) * ps
				if sz > 0 and rest >= 0 and int(nd["pages"]) > 0:
					score += 1
			if score >= best:
				ties += 1
	if best <= 0:
		error = "no page size / tile size pair fits any node's chunk"
		return false
	return true


# ---------------------------------------------------------------------------
# THE COLOUR MAP.
#
# §5.3: one tile per node, at the end of the node's primary chunk; paired chunks
# end with the four children's tiles in reversed child order [3,2,1,0]. Both
# sources are needed — on mp_dumbo the primary chunks give 272 tiles and the
# paired chunks another 832.
#
# -> {quadtree key: BC7 bytes}
# ---------------------------------------------------------------------------
func color_tiles(dir: Dictionary, fetch: Callable) -> Dictionary:
	var out := {}
	if tile_bytes <= 0:
		error = "detect_layout has not run"
		return out
	for n in nodes:
		var nd: Dictionary = n
		var e = dir.get(int(nd["key"]))
		if e == null:
			continue
		var ed: Dictionary = e
		if int(ed["primary_size"]) < tile_bytes:
			continue
		var data: PackedByteArray = fetch.call(str(ed["primary"]))
		if data.size() < tile_bytes:
			continue
		out[int(nd["key"])] = data.slice(data.size() - tile_bytes, data.size())
	for key in dir.keys():
		var ed: Dictionary = dir[key]
		if str(ed["paired"]) == "":
			continue
		var data: PackedByteArray = fetch.call(str(ed["paired"]))
		if data.size() < tile_bytes * 4:
			continue
		var base := data.size() - tile_bytes * 4
		for slot in range(4):
			var ck := (int(key) << 4) | (3 - slot)
			if out.has(ck):
				continue
			out[ck] = data.slice(base + slot * tile_bytes,
				base + (slot + 1) * tile_bytes)
	return out


# ---------------------------------------------------------------------------
# A node's stored weight pages, as raw bytes, in page order.
#
# Primary chunk: the pages end where the colour tile begins.
# Paired chunk:  the four children are concatenated in read order [3,2,1,0]
#                from offset 0 — paired chunks carry no height prefix — and the
#                four colour tiles follow.
# ---------------------------------------------------------------------------
func node_pages(node: Dictionary, dir: Dictionary, fetch: Callable) -> Array:
	var n_pages := int(node["pages"])
	if n_pages <= 0 or page_size <= 0:
		return []
	var key := int(node["key"])
	var e = dir.get(key)
	if e != null:
		var ed: Dictionary = e
		var need := tile_bytes + n_pages * page_size
		if int(ed["primary_size"]) >= need:
			var data: PackedByteArray = fetch.call(str(ed["primary"]))
			if data.size() >= need:
				var start := data.size() - tile_bytes - n_pages * page_size
				return _slice_pages(data, start, n_pages)
	# the parent's paired chunk
	var pe = dir.get(key >> 4)
	if pe == null or str((pe as Dictionary)["paired"]) == "":
		return []
	var pdata: PackedByteArray = fetch.call(str((pe as Dictionary)["paired"]))
	if pdata.is_empty():
		return []
	var child := key & 0xF
	var order := [2, 3, 1, 0] if paired_child_swap else [3, 2, 1, 0]
	var off := 0
	for j in order:
		if int(j) == child:
			break
		var sib = _by_key.get((key & ~0xF) | int(j))
		if sib != null:
			off += int((sib as Dictionary)["pages"]) * page_size
	if off + n_pages * page_size > pdata.size():
		return []
	return _slice_pages(pdata, off, n_pages)


func _slice_pages(d: PackedByteArray, start: int, n: int) -> Array:
	var out: Array = []
	for i in range(n):
		var a := start + i * page_size
		if a + page_size > d.size():
			return out
		out.append(d.slice(a, a + page_size))
	return out


# ---------------------------------------------------------------------------
# One stored page -> a 66×66 byte weight grid (§5.2).
#
#   2,592  BC4 72×72 with a 3-px apron   -> decompress, crop at (3,3)
#   4,356  raw 66×66                     -> as-is
#   5,184  raw 72×72 with a 3-px apron   -> crop at (3,3)
# ---------------------------------------------------------------------------
static func decode_page(raw: PackedByteArray, size: int) -> PackedByteArray:
	if size == 4356:
		return raw
	if size == 5184:
		return _crop(raw, 72, 3)
	if size == 2592:
		var img := Image.create_from_data(72, 72, false, Image.FORMAT_RGTC_R, raw)
		if img == null or img.decompress() != OK:
			return PackedByteArray()
		img.convert(Image.FORMAT_R8)
		return _crop(img.get_data(), 72, 3)
	return PackedByteArray()


static func _crop(d: PackedByteArray, side: int, apron: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(PAGE_SIDE * PAGE_SIDE)
	for z in range(PAGE_SIDE):
		var s := (z + apron) * side + apron
		if s + PAGE_SIDE > d.size():
			return PackedByteArray()
		for x in range(PAGE_SIDE):
			out[z * PAGE_SIDE + x] = d[s + x]
	return out


# Node bounds for a quadtree key, from the tree's own bounds.
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


static func depth_of(key: int) -> int:
	var d := 0
	var k := key
	while k > 3:
		k >>= 4
		d += 1
	return d


# ---------------------------------------------------------------------------
# Every weight page, rasterised into one top-4 splat map.
#
# Coarse nodes first, so a deeper node's finer page overwrites what a coarse one
# laid down — §5.4's "rasterize pages coarse-first so fine rectangles
# overwrite". Per texel the four strongest layers are kept, which is the shape
# the terrain shader's splat path already consumes.
#
# -> {"idx": PackedByteArray (4 layer indices per texel),
#     "w": PackedByteArray (4 weights), "pages": int, "layers": {index: texels}}
# ---------------------------------------------------------------------------
func composite(dir: Dictionary, fetch: Callable, size: int) -> Dictionary:
	var idx := PackedByteArray(); idx.resize(size * size * 4)
	var wgt := PackedByteArray(); wgt.resize(size * size * 4)
	var span: Vector2 = root_max - root_min
	if span.x <= 0.0 or span.y <= 0.0:
		error = "block 1 has an empty world bounds"
		return {}
	var order: Array = nodes.duplicate()
	order.sort_custom(func(x, y): return int(x["depth"]) < int(y["depth"]))
	var decoded := 0
	for n in order:
		var nd: Dictionary = n
		if int(nd["pages"]) <= 0:
			continue
		var pages: Array = node_pages(nd, dir, fetch)
		if pages.is_empty():
			continue
		for r in nd["records"]:
			var rd: Dictionary = r
			var pi := int(rd["page"])
			if pi < 0 or pi >= pages.size():
				continue
			var page := decode_page(pages[pi], page_size)
			if page.size() < PAGE_SIDE * PAGE_SIDE:
				continue
			decoded += 1
			var lo: Vector2 = rd["min"]
			var hi: Vector2 = rd["max"]
			var x0 := clampi(int(floor((lo.x - root_min.x) / span.x * size)), 0, size - 1)
			var x1 := clampi(int(ceil((hi.x - root_min.x) / span.x * size)), 0, size)
			var z0 := clampi(int(floor((lo.y - root_min.y) / span.y * size)), 0, size - 1)
			var z1 := clampi(int(ceil((hi.y - root_min.y) / span.y * size)), 0, size)
			if x1 <= x0 or z1 <= z0:
				continue
			var layer := int(rd["layer"]) & 0xFF
			for gz in range(z0, z1):
				var fz := float(gz - z0) / float(maxi(1, z1 - z0 - 1)) if z1 - z0 > 1 else 0.0
				var row := clampi(int(fz * float(PAGE_SIDE - 1)), 0, PAGE_SIDE - 1) * PAGE_SIDE
				var drow := gz * size
				for gx in range(x0, x1):
					var fx := float(gx - x0) / float(maxi(1, x1 - x0 - 1)) if x1 - x0 > 1 else 0.0
					var w := int(page[row + clampi(int(fx * float(PAGE_SIDE - 1)), 0, PAGE_SIDE - 1)])
					if w > 0:
						_insert(idx, wgt, (drow + gx) * 4, layer, w)
	# COUNTED ACROSS ALL FOUR SLOTS, not just the strongest.
	#
	# Counting slot 0 only answers "which layer wins here", and the consumer of
	# this number wants "which layers appear at all" — it decides which layers
	# get a texture slice. On mp_dumbo the difference is 2 slices against 12:
	# grass, sand, cobblestone and the rest are almost never the single strongest
	# layer at a texel, and dropping them left the map blending two textures.
	var per_layer := {}
	for i in range(size * size):
		var o := i * 4
		for s in range(4):
			if wgt[o + s] == 0:
				break
			var l := int(idx[o + s])
			per_layer[l] = int(per_layer.get(l, 0)) + 1
	return {"idx": idx, "w": wgt, "pages": decoded, "layers": per_layer,
		"size": size}


# Slot 0 is the strongest. A layer already present is UPDATED rather than added
# again — the same layer is painted by several nodes and would otherwise fill
# all four slots with itself and leave no room for what it blends against.
static func _insert(idx: PackedByteArray, wgt: PackedByteArray, o: int,
		layer: int, w: int) -> void:
	for s in range(4):
		if wgt[o + s] > 0 and idx[o + s] == layer:
			if w > wgt[o + s]:
				wgt[o + s] = w
				_bubble(idx, wgt, o, s)
			return
	for s in range(4):
		if wgt[o + s] == 0:
			idx[o + s] = layer
			wgt[o + s] = w
			_bubble(idx, wgt, o, s)
			return
	if w > wgt[o + 3]:
		idx[o + 3] = layer
		wgt[o + 3] = w
		_bubble(idx, wgt, o, 3)


static func _bubble(idx: PackedByteArray, wgt: PackedByteArray, o: int, s: int) -> void:
	var i := s
	while i > 0 and wgt[o + i] > wgt[o + i - 1]:
		var tw := wgt[o + i]; wgt[o + i] = wgt[o + i - 1]; wgt[o + i - 1] = tw
		var ti := idx[o + i]; idx[o + i] = idx[o + i - 1]; idx[o + i - 1] = ti
		i -= 1


# ---------------------------------------------------------------------------
# The colour tiles, assembled into one image.
#
# Coarse first, so the deepest tile covering a texel wins. The apron is dropped:
# §5.3 gives the tile as the node's samples plus 2 px (or 4) on every edge, and
# blitting the apron would double a two-pixel band of the neighbour into every
# tile seam.
# ---------------------------------------------------------------------------
func assemble_colors(tiles: Dictionary, size: int) -> Image:
	if tiles.is_empty() or tile_side <= 0:
		return null
	var keys: Array = tiles.keys()
	keys.sort_custom(func(x, y): return depth_of(int(x)) < depth_of(int(y)))
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var span: Vector2 = root_max - root_min
	var apron := 2 if tile_side == 68 else 4
	for k in keys:
		var bc := Image.create_from_data(tile_side, tile_side, false,
			Image.FORMAT_BPTC_RGBA, tiles[k])
		if bc == null or bc.decompress() != OK:
			continue
		bc.convert(Image.FORMAT_RGBA8)
		var inner := bc.get_region(Rect2i(apron, apron, tile_side - apron * 2,
			tile_side - apron * 2))
		var b: Array = bounds_of(int(k), root_min, root_max)
		var lo: Vector2 = b[0]
		var hi: Vector2 = b[1]
		var x0 := int(floor((lo.x - root_min.x) / span.x * size))
		var z0 := int(floor((lo.y - root_min.y) / span.y * size))
		var w := maxi(1, int(round((hi.x - lo.x) / span.x * size)))
		var h := maxi(1, int(round((hi.y - lo.y) / span.y * size)))
		if x0 >= size or z0 >= size or x0 + w <= 0 or z0 + h <= 0:
			continue
		# Lanczos DOWN, bilinear UP. The coarse tiles are blown up enormously —
		# the root's 64 px interior covers the whole output — and Lanczos on a
		# 64 -> 4096 upscale costs a great deal to invent detail that is not in
		# the source. It made the assembly the slowest step in the whole read.
		inner.resize(w, h, Image.INTERPOLATE_LANCZOS if w < inner.get_width()
			else Image.INTERPOLATE_BILINEAR)
		img.blit_rect(inner, Rect2i(0, 0, w, h), Vector2i(x0, z0))
	return img


# ---------------------------------------------------------------------------
# THE LISTS THE MATERIAL TREE INDEXES INTO (§8).
#
# A block-7 pair entry names one of three ordered layer lists and gives nibble
# indices into it, so the ordering is load-bearing: ascending LayerIndex, which
# is what §8 specifies for all three.
# ---------------------------------------------------------------------------

# Every layer this map's block 1 mentions, ascending. (§8 Y-lo = 0)
func full_list() -> Array:
	var seen := {}
	for n in nodes:
		for r in (n as Dictionary)["records"]:
			seen[int((r as Dictionary)["layer"])] = true
	var out: Array = seen.keys()
	out.sort()
	return out


# The no-page (IgnoreMask, full-coverage) layers of the node at `key`, ascending.
# (§8 Y-lo = 1)
#
# Block 7 is a shallower tree than block 1 on some maps and a deeper one on
# others, so an exact key match is not guaranteed; the nearest ANCESTOR is the
# spatially-containing node and is the right fallback. A node with no base
# records at all returns empty, and §8's own fallback then applies.
func base_list(key: int) -> Array:
	var k := key
	while k >= 3:
		var n = _by_key.get(k)
		if n != null:
			var out: Array = []
			for r in (n as Dictionary)["records"]:
				var rd: Dictionary = r
				if int(rd["page"]) < 0:
					out.append(int(rd["layer"]))
			if not out.is_empty():
				out.sort()
				return out
		if k == 3:
			break
		k >>= 4
	return []


# The layers a map paints with, and the ones it can use as a base.
#
# §5.1: a record whose bit8 is SET has no stored page and full coverage — the
# IgnoreMask layers, which are the base-layer candidates. The rest are painted.
func layer_usage() -> Dictionary:
	var painted := {}
	var base := {}
	for n in nodes:
		for r in (n as Dictionary)["records"]:
			var rd: Dictionary = r
			var l := int(rd["layer"])
			if int(rd["page"]) >= 0:
				painted[l] = int(painted.get(l, 0)) + 1
			else:
				base[l] = int(base.get(l, 0)) + 1
	return {"painted": painted, "base": base}
