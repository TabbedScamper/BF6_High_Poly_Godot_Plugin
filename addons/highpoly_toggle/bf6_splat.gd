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
# §5.3 tile sizes -> side. 8712 is 132² BC1 (MP_Portal_Sand; 33×33 blocks of
# 8 bytes — not even 16-divisible, so it cannot be a BC7 tile), the rest are
# BC7. 85024 is deliberately NOT here: it is a 67600 + 17424 MIP PAIR trailer
# (survey-style), not a tile, and the old entry decoded it as a 260² image
# with 17,424 bytes too many. A map whose residuals decompose to no known size
# fails detect_layout LOUDLY with the residual list in the error.
const TILE_SIZES := {4624: 68, 17424: 132, 67600: 260, 8712: 132}
# Candidate order for the decomposition, LARGEST FIRST, and that is
# load-bearing: 17424 = 2 × 8712, so every two-tile BC7 trailer (Tungsten's
# 34848) also divides by the BC1 size — tried smallest-first, the BC1 branch
# would steal every BC7 map. A larger size can never divide a smaller one, so
# descending order is unambiguous for the sizes above.
const TILE_ORDER := [67600, 17424, 8712, 4624]
# Which Godot format decodes a tile of that byte size.
const TILE_FMTS := {4624: Image.FORMAT_BPTC_RGBA, 17424: Image.FORMAT_BPTC_RGBA,
	67600: Image.FORMAT_BPTC_RGBA, 8712: Image.FORMAT_DXT1}
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
var tile_fmt := Image.FORMAT_BPTC_RGBA   # BC7 everywhere but Portal_Sand (BC1)
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
# Neither is stored, and the old test here could not fail: it counted nodes
# where `primarySize − tile − pages × pageSize >= 0`, a count that is
# monotonically decreasing in BOTH parameters, so the smallest pair
# (2592, 4624) won on EVERY map. That was wrong on nine of sixteen — every
# 4356-page map had misaligned weight pages decoded with the wrong codec AND a
# colour "tile" sliced out of the middle of the real trailer (the flat teal at
# 78% of Tungsten's colormap.png was the tail of a different raster entirely).
#
# The decisive test, measured across maps (docs/MAP-TUNGSTEN.md): for the TRUE
# page size the per-node residual `primarySize − pages × pageSize` collapses to
# a handful of distinct values — Tungsten: 3 {184145, 333442, 0}; Aftermath: 3
# {166721, 17424, 0} — while every wrong page size scatters into dozens, many
# negative. So: pick the page size with the fewest distinct residuals, then
# derive the tile size by decomposing those residuals as
#
#     residual = heightPrefix + k × tileBytes
#
# with the §5.2 prefix set below. The trailer (k tiles) is per RESIDUAL, so a
# map can mix one-tile and two-tile nodes, which Tungsten does.
# ---------------------------------------------------------------------------

# §5.2 height prefixes, plus the observed sum 2×149297 (Tungsten's two-tile
# nodes). 189216 is itself 149297 + 39919, so the set is closed under the
# combinations seen so far.
const PREFIXES := [0, 39919, 149297, 189216, 298594]
# residual -> trailer bytes (k × tile_bytes), filled by detect_layout.
var _trailer := {}
# residual -> OFFSET of the colour tile inside an 85,024-byte MIP PAIR trailer
# (a 260² tile with its 132² mip after it). Which component is "the" colour
# depends on the map's tile size: beside 132² tiles (MAP-EASTWOOD.md's 19
# mixed nodes) the pair's TAIL mip matches scale, offset 67,600; on a 260²
# map (Granite's marina family) the pair's HEAD is the tile, offset 0.
var _mip := {}
# Model B (constant non-tile trailer, MAP-CONTAMINATED.md's 936): the constant,
# or -1 when model A fit.
var _tail_const := -1
# True when neither the primary nor the paired chunks yielded a tile size: the
# map ships no colour raster we recognise. The splat still builds.
var no_colour := false


func detect_layout(dir: Dictionary) -> bool:
	error = ""
	_trailer.clear()
	_mip.clear()
	_tail_const = -1
	no_colour = false
	# --- the page size: fewest distinct residuals, none negative -------------
	# Residuals are weighted by NODE COUNT so the outlier tolerance below can
	# reason in nodes: MAP-SUBSURFACE.md found 8 of 107 chunks carrying a
	# variable extra payload no algebra fits, and a fit test over distinct
	# values alone would let those 8 veto the model for the other 99.
	var best_ps := 0
	var best_resid := {}
	for ps in PAGE_SIZES:
		var resid := {}
		var ok := true
		for n in nodes:
			var nd: Dictionary = n
			if int(nd["pages"]) <= 0:
				continue
			var e = dir.get(int(nd["key"]))
			if e == null:
				continue
			var sz := int((e as Dictionary)["primary_size"])
			if sz <= 0:
				continue
			var r := sz - int(nd["pages"]) * int(ps)
			if r < 0:
				# pages that do not fit their own chunk: this page size is too big
				ok = false
				break
			resid[r] = int(resid.get(r, 0)) + 1
		if not ok or resid.is_empty():
			continue
		if best_ps == 0 or resid.size() < best_resid.size():
			best_ps = int(ps)
			best_resid = resid
	if best_ps == 0:
		error = "no page size fits the per-node chunk sizes"
		return false
	page_size = best_ps
	var total := 0
	for r in best_resid.keys():
		total += int(best_resid[r])
	# --- MODEL A: the trailer is k colour tiles ------------------------------
	# Tried before model B because B (a constant) can partially fit tile maps.
	# A ≥90% node fit accepts, so a handful of irregular chunks (Subsurface's
	# 8) lose their own tile and pages without vetoing the whole map.
	tile_bytes = 0
	var best_fit := 0
	for tb in TILE_ORDER:
		var t_of := {}
		var t_mip := {}
		var okn := 0
		for r in best_resid.keys():
			var k := _tiles_in(int(r), int(tb))
			if k >= 0:
				t_of[int(r)] = k * int(tb)
				okn += int(best_resid[r])
			elif (int(tb) == 17424 or int(tb) == 67600) and _mip_fits(int(r)):
				t_of[int(r)] = 85024
				t_mip[int(r)] = 67600 if int(tb) == 17424 else 0
				okn += int(best_resid[r])
		if okn * 10 >= total * 9 and okn > best_fit:
			best_fit = okn
			tile_bytes = int(tb)
			tile_side = int(TILE_SIZES[tb])
			tile_fmt = int(TILE_FMTS[tb])
			_trailer = t_of
			_mip = t_mip
	if tile_bytes > 0:
		return true
	# --- MODEL B: the trailer is a CONSTANT, and it is not a tile ------------
	# MAP-CONTAMINATED.md: every primary chunk ends in the same 936 bytes of an
	# unknown raster, and the colour tiles live ONLY in the paired chunks. The
	# constant is whatever value `residual − prefix` agrees on across ≥90% of
	# nodes; the colour tile size then comes from the paired trailers below.
	var cand := {}
	for r in best_resid.keys():
		for p in PREFIXES:
			var c := int(r) - int(p)
			if c >= 0:
				cand[c] = int(cand.get(c, 0)) + int(best_resid[r])
	var best_c := -1
	var best_cn := 0
	for c in cand.keys():
		if int(cand[c]) > best_cn:
			best_cn = int(cand[c])
			best_c = int(c)
	if best_c < 0 or best_cn * 10 < total * 9:
		error = ("page size %d fits but no trailer model covers its residuals %s"
			% [page_size, str(best_resid.keys())])
		return false
	_tail_const = best_c
	for r in best_resid.keys():
		for p in PREFIXES:
			if int(r) - int(p) == best_c:
				_trailer[int(r)] = best_c
				break
	# The colour tile's size and codec, from the paired trailers: four child
	# tiles each, so a quarter of the paired remainder names the tile.
	for key in dir.keys():
		var ed: Dictionary = dir[key]
		if str(ed["paired"]) == "":
			continue
		var kids_pages := 0
		var known := true
		for i in range(4):
			var sib = _by_key.get((int(key) << 4) | i)
			if sib == null:
				known = false
				break
			kids_pages += int((sib as Dictionary)["pages"])
		if not known:
			continue
		var tp := int(ed["paired_size"]) - kids_pages * page_size \
			if ed.has("paired_size") else -1
		if tp > 0 and tp % 4 == 0 and TILE_SIZES.has(tp / 4):
			tile_bytes = tp / 4
			tile_side = int(TILE_SIZES[tile_bytes])
			tile_fmt = int(TILE_FMTS[tile_bytes])
			break
	if tile_bytes <= 0:
		# No colour anywhere is a legal outcome: the weight pages and layers
		# still decode, so the surface builds without a colour map rather than
		# failing outright. tile_bytes 0 makes color_tiles return empty.
		no_colour = true
	return true


# Does `residual` decompose as a prefix plus the 260²+132² mip pair?
func _mip_fits(residual: int) -> bool:
	for p in PREFIXES:
		if residual - int(p) == 85024:
			return true
	return false


# How many tiles a residual holds under `tb`, or -1 if no prefix decomposes it.
# k = 0 is legal: a node whose chunk is prefix + pages and no colour tile.
func _tiles_in(residual: int, tb: int) -> int:
	var best_k := -1
	for p in PREFIXES:
		var rem := residual - int(p)
		if rem < 0 or rem % tb != 0:
			continue
		var k := rem / tb
		if k > 8:
			continue
		# Prefer the decomposition with the fewest tiles: a residual that can be
		# read as either "big prefix + 1 tile" or "no prefix + many tiles" is
		# height data plus one tile, not a stack of tiles.
		if best_k < 0 or k < best_k:
			best_k = k
	return best_k


# The trailer (colour tile block) size for one node's primary chunk, from the
# decomposition table detect_layout built. A residual not seen at detection
# time (a no-page node, say) is decomposed on demand and remembered.
func _trailer_bytes(primary_size: int, pages: int) -> int:
	var r := primary_size - pages * page_size
	if r < 0:
		return -1
	if _trailer.has(r):
		return int(_trailer[r])
	# On-demand decomposition mirrors the model detect_layout settled on:
	# constant tail, mip pair, or k tiles - in that order of specificity.
	if _tail_const >= 0:
		for p in PREFIXES:
			if r - int(p) == _tail_const:
				_trailer[r] = _tail_const
				return _tail_const
		return -1
	if (tile_bytes == 17424 or tile_bytes == 67600) and _mip_fits(r):
		_trailer[r] = 85024
		_mip[r] = 67600 if tile_bytes == 17424 else 0
		return 85024
	var k := _tiles_in(r, tile_bytes)
	if k < 0:
		return -1
	var t := k * tile_bytes
	_trailer[r] = t
	return t


# ---------------------------------------------------------------------------
# THE COLOUR MAP.
#
# §5.3 plus docs/MAP-TUNGSTEN.md: the trailer at the end of a node's primary
# chunk holds ONE OR TWO tiles, and the COLOUR tile is the FIRST — the second,
# where present, is a degenerate second raster (BC7 mode-3 constant blocks;
# decoded, it is the flat teal that used to cover 78% of Tungsten's colour
# map). So the slice is taken from the trailer's START, never from the end of
# the chunk. Paired chunks group the four children's tiles by raster, colour
# tiles first, in reversed child order [3,2,1,0]; the old code took the LAST
# four tiles, which on two-raster maps is the wrong raster entirely.
#
# Both sources are needed — on mp_dumbo the primary chunks give 272 tiles and
# the paired chunks another 832.
#
# -> {quadtree key: BC7 bytes}
# ---------------------------------------------------------------------------
func color_tiles(dir: Dictionary, fetch: Callable,
		progress := Callable()) -> Dictionary:
	var out := {}
	if tile_bytes <= 0:
		error = "detect_layout has not run"
		return out
	var seen := 0
	for n in nodes:
		var nd: Dictionary = n
		seen += 1
		if progress.is_valid() and (seen & 63) == 0:
			progress.call(seen, nodes.size())
		var e = dir.get(int(nd["key"]))
		if e == null:
			continue
		var ed: Dictionary = e
		var trailer := _trailer_bytes(int(ed["primary_size"]), int(nd["pages"]))
		if trailer < tile_bytes:
			continue                      # no colour tile in this node's chunk
		var data: PackedByteArray = fetch.call(str(ed["primary"]))
		if data.size() < trailer:
			continue
		var start := data.size() - trailer
		var resid := data.size() * 0      # keep typed int
		resid = int(ed["primary_size"]) - int(nd["pages"]) * page_size
		if _mip.has(resid):
			# The 85,024-byte mip pair: the offset stored at detection picks the
			# component matching the map's tile size (tail 132² beside 132²
			# tiles, head 260² on a 260² map). A signature scan must not run
			# here: every window of the big tile is itself a valid image, so the
			# scan would happily return a piece of the wrong-resolution mip.
			start = data.size() - trailer + int(_mip[resid])
		elif trailer > tile_bytes:
			# WHICH tile of a multi-tile trailer is the colour is decided by
			# SIGNATURE, not position. On Tungsten the colour tile is first and
			# the second is a degenerate raster, but MAP-CAPSTONE.md shows that
			# reading is not a law (its single tile makes first and last
			# coincide), so a position rule is one unstudied map from wrong.
			var best_off := 0
			var best_frac := -1.0
			var off := 0
			while off + tile_bytes <= trailer:
				var f := _tile_score(data, start + off)
				if f > best_frac:
					best_frac = f
					best_off = off
				off += tile_bytes
			start += best_off
		# The same absolute floor the paired pass applies: exact decomposition
		# puts the boundary in the right place, but on a map whose trailer is
		# something new this refuses to ship page bytes as a picture.
		if not _tile_looks_real(data, start):
			continue
		out[int(nd["key"])] = data.slice(start, start + tile_bytes)
	for key in dir.keys():
		var ed: Dictionary = dir[key]
		if str(ed["paired"]) == "":
			continue
		# The paired trailer's size comes from what precedes it: the children's
		# pages from offset 0, no height prefix. All four children must be known
		# or the offsets cannot be trusted.
		var kids_pages := 0
		var kids_known := true
		for i in range(4):
			var sib = _by_key.get((int(key) << 4) | i)
			if sib == null:
				kids_known = false
				break
			kids_pages += int((sib as Dictionary)["pages"])
		if not kids_known:
			continue
		var data: PackedByteArray = fetch.call(str(ed["paired"]))
		var trailer := data.size() - kids_pages * page_size
		if trailer < tile_bytes * 4:
			continue
		var base := data.size() - trailer
		# Same signature rule for the paired trailer: the four children's colour
		# tiles are grouped with the second raster's four after them on
		# Tungsten, but which GROUP is the colour is decided by testing the
		# first tile of each group of four, not by trusting the order.
		if trailer >= tile_bytes * 8:
			var best_g := 0
			var best_frac := -1.0
			var g := 0
			while (g + 4) * tile_bytes <= trailer:
				var f := _tile_score(data, base + g * tile_bytes)
				if f > best_frac:
					best_frac = f
					best_g = g
				g += 4
			base += best_g * tile_bytes
		# ABSOLUTE gate, not just relative: on MP_Plaza the paired chunks hold
		# the DESCENDANT nodes' weight pages and no tiles at all, so the
		# "trailer" computed from the four direct children's counts is really
		# deeper pages - and slicing it ships weight pages as colour. Real
		# tiles measure far above these floors (BC7 modes 4-7: >=0.64 on the
		# mode-1-heavy Badlands, ~1.0 elsewhere; BC1 c0>c1: 0.99 on
		# Contaminated) and page data far below (<=0.14 both codecs).
		if not _tile_looks_real(data, base):
			continue
		for slot in range(4):
			var ck := (int(key) << 4) | (3 - slot)
			if out.has(ck):
				continue
			out[ck] = data.slice(base + slot * tile_bytes,
				base + (slot + 1) * tile_bytes)
	return out


# The fraction of a tile's BC7 blocks in modes 4-7 (byte0 low nibble clear,
# byte0 nonzero). Image tiles measure 0.86-1.00 across studied maps; the
# degenerate second raster is mode-0-3 and measures ~0. Sampled every fourth
# block: the two populations are far enough apart that 272 blocks of a 132
# tile settle it, and this runs per tile on a 1,000-tile map.
# The codec-appropriate "how much does this look like a colour raster" score,
# used both to CHOOSE between candidate tiles (relative) and to GATE a chosen
# one (absolute, in _tile_looks_real). Granite proved the mode test is wrong
# for BC1 both ways - real BC1 colour reads "mode 3" and uniform BC1 filler
# reads "mode 6" - so the score is per format.
func _tile_score(d: PackedByteArray, start: int) -> float:
	if tile_fmt == Image.FORMAT_DXT1:
		# BC1: opaque blocks order their two RGB565 endpoints c0 > c1. Colour
		# tiles measure ~99% ordered; page bytes ~14%; Granite's constant
		# filler tiles (identical endpoints) score ~0 and are rejected by the
		# gate, which is exactly the "skip filler over the play area" its
		# study calls for.
		var ordered := 0
		var n := 0
		var b := start
		while b + 8 <= d.size() and n < 512:
			if d.decode_u16(b) > d.decode_u16(b + 2):
				ordered += 1
			n += 1
			b += 32
		return float(ordered) / maxf(1.0, float(n))
	return _mode47_frac(d, start)


# Is the tile at `start` a plausible colour raster for the map's codec?
# Thresholds sit in the wide gap between measured populations; a tile that
# fails is weight-page data (or constant filler) wearing a tile-sized coat.
func _tile_looks_real(d: PackedByteArray, start: int) -> bool:
	return _tile_score(d, start) >= (0.6 if tile_fmt == Image.FORMAT_DXT1 else 0.4)


static func _mode47_frac(d: PackedByteArray, start: int) -> float:
	var hits := 0
	var n := 0
	var b := start
	var end := start + (d.size() - start)
	while b + 16 <= end and n < 512:
		var b0 := int(d[b])
		if b0 != 0 and (b0 & 0x0F) == 0:
			hits += 1
		n += 1
		b += 64
	return float(hits) / maxf(1.0, float(n))


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
		# The pages sit between the height prefix and the colour trailer, so the
		# offset back from the end is the TRAILER, not one tile — a two-tile node
		# read with a one-tile offset lands every page 17,424 bytes off and the
		# weights decode as coloured noise.
		var trailer := _trailer_bytes(int(ed["primary_size"]), n_pages)
		if trailer >= 0:
			var need := trailer + n_pages * page_size
			if int(ed["primary_size"]) >= need:
				var data: PackedByteArray = fetch.call(str(ed["primary"]))
				if data.size() >= need:
					var start := data.size() - trailer - n_pages * page_size
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
func composite(dir: Dictionary, fetch: Callable, size: int,
		progress := Callable()) -> Dictionary:
	var idx := PackedByteArray(); idx.resize(size * size * 4)
	var wgt := PackedByteArray(); wgt.resize(size * size * 4)
	var span: Vector2 = root_max - root_min
	if span.x <= 0.0 or span.y <= 0.0:
		error = "block 1 has an empty world bounds"
		return {}
	var order: Array = nodes.duplicate()
	order.sort_custom(func(x, y): return int(x["depth"]) < int(y["depth"]))
	var decoded := 0
	var seen := 0
	for n in order:
		var nd: Dictionary = n
		seen += 1
		if progress.is_valid() and (seen & 15) == 0:
			progress.call(seen, order.size())
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
	# 2 per edge ALWAYS (§5.3: the payload is side − 4 total, 132 = 128 + 4 and
	# 68 = 64 + 4 alike). The old `4 for anything but 68` guess cropped a 132
	# tile to 124 px of a 128 px payload and shifted every tile by 2 px.
	var apron := 2
	for k in keys:
		var bc := Image.create_from_data(tile_side, tile_side, false,
			tile_fmt, tiles[k])
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
