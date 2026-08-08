extends SceneTree

# The terrain COLOUR MAP — the thing the removed maptile was standing in for,
# except this one ships inside the game.
#
# TERRAIN.md §5.3: the engine's terrain colour map is one BC7 square tile per
# streaming-tree node, trailing the splat weight pages inside the node's CAS
# chunk. On dumbo that is a 68x68 tile (64 + a 2-px apron per edge) = 4,624
# bytes. Paired chunks end with four consecutive child tiles in reversed child
# order [3,2,1,0].
#
# Why this matters here: we deleted the downloaded maptile from the terrain
# shader, which was correct — it was the SDK's own photo, redistributed. This is
# the same picture, read from the player's install, and it is the large-scale
# ground colour the shader has been missing ever since.
#
# The probe assembles it and writes a PNG so the result can be looked at rather
# than asserted. A seamless aerial photo is the oracle; a mosaic with the
# quadrants shuffled is what a wrong child order looks like.
#
#   godot --headless --path native/_testproj --script probe_colormap.gd -- [level] [out.png]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")

const TREE_RES := 0x22FE8AC8
const B1_HEADER := 0x3D          # §5.1 splat metadata block header
const RECORD := 33
const PAGE_SIZES := [2592, 4356, 5184]
const NO_PAGE_FLAG := 0x0100

var _b1 := PackedByteArray()
var _pos := 0
var _nodes: Array = []           # [{key, depth, pages, bounds}]
var _err := ""


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var out_png := "colormap.png"
	if a.size() > 0 and str(a[0]) != "": level = str(a[0])
	if a.size() > 1 and str(a[1]) != "": out_png = str(a[1])

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount: %s" % src.error); quit(1); return
	var res_name := ""
	for rn in src.res.keys():
		if int(src.res[rn][5]) == TREE_RES:
			res_name = str(rn); break
	if res_name == "":
		print("FAIL: no streaming tree"); quit(1); return
	var raw := src.get_res(res_name)

	var t = BF6Terrain.new()
	_b1 = t.find_block(raw, 1)
	if _b1.is_empty():
		print("FAIL: no splat block: %s" % t.error); quit(1); return

	# the heightfield stride, which is the prefix the pages sit behind
	var hb := t.find_block(raw, 0)
	if hb.is_empty() or not t.read_block_header(hb):
		print("FAIL heights: %s" % t.error); quit(1); return
	var prefix_sizes := [0, t.data_size]
	var b2 := t.find_block(raw, 2)
	if not b2.is_empty():
		var t2 = BF6Terrain.new()
		if t2.read_block_header(b2):
			prefix_sizes.append(t2.data_size)
			prefix_sizes.append(t.data_size + t2.data_size)
	print("height prefix candidates: %s" % str(prefix_sizes))

	var root_min := Vector2(_b1.decode_float(0x18), _b1.decode_float(0x1C))
	var root_max := Vector2(_b1.decode_float(0x20), _b1.decode_float(0x24))
	var declared_nodes := int(_b1.decode_u32(0x2C))
	var declared_recs := int(_b1.decode_u32(0x30))
	print("block 1: bounds %s .. %s, %d nodes, %d records declared"
		% [str(root_min), str(root_max), declared_nodes, declared_recs])

	# --- walk the metadata quadtree ------------------------------------------
	_pos = B1_HEADER
	var total_recs := [0]
	if not _walk(3, 0, root_min, root_max, total_recs):
		print("FAIL block 1 walk: %s (at %d of %d)" % [_err, _pos, _b1.size()])
		quit(1); return
	print("walked %d nodes / %d records, consumed %d of %d bytes"
		% [_nodes.size(), total_recs[0], _pos, _b1.size()])
	var exact := _pos == _b1.size()
	print("byte-exact: %s   node count matches: %s   record count matches: %s"
		% [exact, _nodes.size() == declared_nodes, total_recs[0] == declared_recs])
	if not exact:
		print("   (the walk must land on the final byte; it did not, so nothing below is trustworthy)")
		quit(1); return

	# --- which page codec does this map use? ---------------------------------
	var dir := t.read_chunk_directory(raw)
	print("chunk directory: %d nodes" % dir.size())

	var best_size := 0
	var best_score := -1
	for ps in PAGE_SIZES:
		var score := 0
		for n in _nodes:
			var nd: Dictionary = n
			var e = dir.get(int(nd["key"]))
			if e == null: continue
			var sz := int((e as Dictionary)["primary_size"])
			if sz <= 0: continue
			for pre in prefix_sizes:
				var residual: int = sz - int(pre) - int(nd["pages"]) * ps
				if residual == 4624 or residual == 17424 or residual == 67600 \
						or residual == 85024:
					score += 1
					break
		print("   page size %5d -> %d nodes land on a known colour-tile trailer" % [ps, score])
		if score > best_score:
			best_score = score; best_size = ps
	if best_score <= 0:
		print("FAIL: no page size explains any node's primary chunk")
		quit(1); return
	print("page codec: %d bytes (%d nodes fit)" % [best_size, best_score])

	# --- pull one tile per node ----------------------------------------------
	var tiles := {}          # key -> PackedByteArray (BC7)
	var tile_bytes := 0
	var from_primary := 0
	var from_paired := 0
	for n in _nodes:
		var nd: Dictionary = n
		var key := int(nd["key"])
		var e = dir.get(key)
		if e == null: continue
		var ed: Dictionary = e
		var psz := int(ed["primary_size"])
		if psz > 0:
			for pre in prefix_sizes:
				var residual: int = psz - int(pre) - int(nd["pages"]) * best_size
				if residual == 4624 or residual == 17424 or residual == 67600:
					var data := src.get_chunk(str(ed["primary"]))
					if data.size() >= residual:
						tiles[key] = data.slice(data.size() - residual, data.size())
						tile_bytes = residual
						from_primary += 1
					break
	# paired chunks: the last 4 x tile_bytes are the four children, [3,2,1,0]
	if tile_bytes > 0:
		for key in dir.keys():
			var ed: Dictionary = dir[key]
			if str(ed["paired"]) == "" or int(ed["paired_size"]) < tile_bytes * 4:
				continue
			var data := src.get_chunk(str(ed["paired"]))
			if data.size() < tile_bytes * 4:
				continue
			var base := data.size() - tile_bytes * 4
			for slot in range(4):
				var child := 3 - slot
				var ck := (int(key) << 4) | child
				if tiles.has(ck):
					continue
				tiles[ck] = data.slice(base + slot * tile_bytes,
					base + (slot + 1) * tile_bytes)
				from_paired += 1
	print("colour tiles: %d (%d from primary chunks, %d from paired), %d bytes each"
		% [tiles.size(), from_primary, from_paired, tile_bytes])
	if tiles.is_empty():
		quit(1); return

	# --- decode and assemble --------------------------------------------------
	var side := int(round(sqrt(float(tile_bytes) / 16.0))) * 4     # BC7: 16 B per 4x4
	var apron := 2 if side == 68 else 4
	print("tile %dx%d BC7, apron %d px -> %d px of interior"
		% [side, side, apron, side - apron * 2])

	# deepest key wins, so draw coarse first
	var keys: Array = tiles.keys()
	keys.sort_custom(func(x, y): return _depth(int(x)) < _depth(int(y)))

	var out_side := 4096
	var img := Image.create_empty(out_side, out_side, false, Image.FORMAT_RGBA8)
	var span := root_max - root_min
	var drawn := 0
	var failed := 0
	for k in keys:
		var bc := Image.create_from_data(side, side, false, Image.FORMAT_BPTC_RGBA,
			tiles[k])
		if bc == null:
			failed += 1; continue
		if bc.decompress() != OK:
			failed += 1; continue
		bc.convert(Image.FORMAT_RGBA8)
		var interior := bc.get_region(Rect2i(apron, apron, side - apron * 2,
			side - apron * 2))
		var b: Array = _bounds_of(int(k), root_min, root_max)
		var lo: Vector2 = b[0]
		var hi: Vector2 = b[1]
		var x0 := int(floor((lo.x - root_min.x) / span.x * out_side))
		var z0 := int(floor((lo.y - root_min.y) / span.y * out_side))
		var w := maxi(1, int(round((hi.x - lo.x) / span.x * out_side)))
		var h := maxi(1, int(round((hi.y - lo.y) / span.y * out_side)))
		interior.resize(w, h, Image.INTERPOLATE_LANCZOS)
		img.blit_rect(interior, Rect2i(0, 0, w, h), Vector2i(x0, z0))
		drawn += 1
	print("assembled %d tiles (%d failed to decode)" % [drawn, failed])

	# a flat grey result means the decode is wrong even if nothing errored
	var lo_c := Color(9, 9, 9, 9)
	var hi_c := Color(-9, -9, -9, -9)
	var sum := Vector3.ZERO
	var samples := 0
	for sy in range(0, out_side, 37):
		for sx in range(0, out_side, 37):
			var c := img.get_pixel(sx, sy)
			lo_c = Color(minf(lo_c.r, c.r), minf(lo_c.g, c.g), minf(lo_c.b, c.b), 1)
			hi_c = Color(maxf(hi_c.r, c.r), maxf(hi_c.g, c.g), maxf(hi_c.b, c.b), 1)
			sum += Vector3(c.r, c.g, c.b)
			samples += 1
	sum /= float(maxi(1, samples))
	print("colour range  min %s  max %s  mean %s" % [str(lo_c), str(hi_c), str(sum)])

	img.save_png(out_png)
	print("wrote %s" % ProjectSettings.globalize_path(out_png))
	quit(0)


static func _depth(key: int) -> int:
	var d := 0
	var k := key
	while k > 3:
		k >>= 4; d += 1
	return d


# Quadrant bounds for a key, using the TRAVERSAL child order of §2.4
# (0,0) (1,0) (1,1) (0,1) — the one the 1088/1088 placement audit proved.
static func _bounds_of(key: int, root_min: Vector2, root_max: Vector2) -> Array:
	var path: Array = []
	var k := key
	while k > 3:
		path.push_front(k & 0xF)
		k >>= 4
	var lo := root_min
	var hi := root_max
	var ox := [0, 1, 1, 0]
	var oz := [0, 0, 1, 1]
	for i in path:
		var half := (hi - lo) * 0.5
		lo = Vector2(lo.x + half.x * float(ox[int(i)]),
			lo.y + half.y * float(oz[int(i)]))
		hi = lo + half
	return [lo, hi]


func _walk(key: int, depth: int, lo: Vector2, hi: Vector2, total: Array) -> bool:
	if _pos + 6 > _b1.size():
		_err = "node header past the end"
		return false
	var rec_count := int(_b1.decode_u16(_pos))
	var stored := int(_b1.decode_u16(_pos + 2))
	_pos += 6
	if _pos + rec_count * RECORD > _b1.size():
		_err = "records past the end"
		return false
	var pages := 0
	for i in range(rec_count):
		var flags := int(_b1.decode_u16(_pos + i * RECORD + 20))
		if (flags & NO_PAGE_FLAG) == 0:
			pages += 1
	_pos += rec_count * RECORD
	total[0] += rec_count
	# The declared stored-page count is a free check on the flag reading: a wrong
	# flag offset changes `pages` and nothing else would notice.
	if stored != pages:
		_err = "node %d declares %d stored pages, %d records say otherwise" % [key, stored, pages]
		return false
	_nodes.append({"key": key, "depth": depth, "pages": pages,
		"min": lo, "max": hi})
	if rec_count == 0:
		if _pos >= _b1.size():
			return true
		_pos += 1
		return true
	if _pos + 2 > _b1.size():
		_err = "node flags past the end"
		return false
	var has_children := int(_b1[_pos + 1])
	_pos += 2
	if _pos < _b1.size():
		_pos += 1                      # t1, omitted only on the terminal node
	if has_children != 0:
		var half := (hi - lo) * 0.5
		var ox := [0, 1, 1, 0]
		var oz := [0, 0, 1, 1]
		for i in range(4):
			var clo := Vector2(lo.x + half.x * float(ox[i]), lo.y + half.y * float(oz[i]))
			if not _walk((key << 4) | i, depth + 1, clo, clo + half, total):
				return false
	return true
