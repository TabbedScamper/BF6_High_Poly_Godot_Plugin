@tool
extends SceneTree
# The detect_layout rewrite (#90), against the real install.
#
# MP_Tungsten is the map the old scorer got wrong: page size 4356 read as 2592,
# and the colour tile sliced from the tail of a two-tile trailer (the second,
# degenerate raster - the flat teal). Asserts the new detection, then decodes
# the actual first-tiles and applies the corpus's own BC7 discriminator: image
# tiles sit in modes 4-7 (byte0 low nibble 0), the wrong raster in mode 3.
# Finally assembles the colour map and checks its mean is the warm terrain of
# the SDK overhead, not teal.

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Tungsten"):
		print("no source"); quit(1); return
	var fails := 0
	var pick := ""
	for rn in gs.src.res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains(gs.level):
			pick = n; break
	var res: PackedByteArray = gs.src.get_res(pick)
	var t := BF6Terrain.new()
	var b1: PackedByteArray = t.find_block(res, 1)
	var sp := BF6Splat.new()
	if not sp.parse(b1):
		print("FAIL parse: %s" % sp.error); quit(1); return
	var chunks: Dictionary = t.read_chunk_directory(res)
	if not sp.detect_layout(chunks):
		print("FAIL detect_layout: %s" % sp.error); quit(1); return
	print("page_size %d  tile_bytes %d  tile_side %d" % [sp.page_size, sp.tile_bytes, sp.tile_side])
	if sp.page_size != 4356: print("FAIL page_size want 4356"); fails += 1
	if sp.tile_bytes != 17424: print("FAIL tile_bytes want 17424"); fails += 1
	if sp.tile_side != 132: print("FAIL tile_side want 132"); fails += 1
	var fetch := func(g): return gs.src.get_chunk(str(g))
	var tiles: Dictionary = sp.color_tiles(chunks, fetch)
	print("%d colour tiles" % tiles.size())
	if tiles.size() < 200: print("FAIL too few tiles"); fails += 1
	# corpus discriminator on the first 64 tiles: modes 4-7 have byte0 low nibble 0
	var blocks := 0
	var hi := 0
	var n_t := 0
	for k in tiles.keys():
		n_t += 1
		if n_t > 64: break
		var d: PackedByteArray = tiles[k]
		for b in range(0, d.size(), 16):
			var b0 := int(d[b])
			blocks += 1
			if b0 != 0 and (b0 & 0x0F) == 0:
				hi += 1
	var frac := float(hi) / maxf(1.0, float(blocks))
	print("BC7 modes 4-7: %.1f%% of %d blocks" % [frac * 100.0, blocks])
	if frac < 0.90: print("FAIL: not the image raster"); fails += 1
	var img: Image = sp.assemble_colors(tiles, 1024)
	if img == null:
		print("FAIL assemble returned null"); fails += 1
	else:
		var sum := Vector3.ZERO
		var n_px := 0
		for y in range(0, 1024, 7):
			for x in range(0, 1024, 7):
				var c := img.get_pixel(x, y)
				sum += Vector3(c.r, c.g, c.b); n_px += 1
		var mean := sum / float(n_px)
		print("assembled mean (%.3f, %.3f, %.3f)  [teal was (0.00, 0.73, 0.73); SDK overhead (0.52, 0.47, 0.36)]"
			% [mean.x, mean.y, mean.z])
		if mean.x < 0.25 or absf(mean.y - mean.z) < 0.02 and mean.x < 0.1:
			print("FAIL: still teal-ish"); fails += 1
		if not (mean.x > 0.3 and mean.x < 0.65 and mean.y > 0.3 and mean.y < 0.6 \
				and mean.z > 0.15 and mean.z < 0.5):
			print("FAIL: mean not in the SDK overhead's neighbourhood"); fails += 1
		img.save_png("user://layout_test_tungsten.png")
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
