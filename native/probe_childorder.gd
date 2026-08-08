extends SceneTree

# Two of TERRAIN.md's open questions, both of the same shape: a child order that
# has never been validated because the data carries no bounds to check it
# against.
#
#   §14 item 2 — splat pages inside a paired chunk. The colour-map TILES are
#   proven [3,2,1,0] by the 1088/1088 parent-mosaic audit, but whether the PAGE
#   payloads are packed by plain reversed child index or by reversed
#   traversal-quadrant order has never been tested. The two differ exactly by
#   swapping children 2 and 3, so under the wrong one a quarter of every paired
#   chunk's pages land in the wrong quadrant.
#
#   §14 item 1 — blocks 4/5 store no per-node bounds at all, so their child
#   convention is unvalidated in the same way.
#
# THE ORACLE IS THE COLOUR MAP, which is the point. It is an independent raster
# of the same ground, decoded through a path whose own child order is already
# proven, so it can referee the ones that are not. If the splat's grass layer
# lands on green pixels under one packing order and not the other, that settles
# it; if both do equally well, the test says so instead of picking a winner.
#
#   godot --headless --path native/_testproj --script probe_childorder.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")
const BF6Splat := preload("res://bf6_splat.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")

const TREE_RES := 0x22FE8AC8
const SIZE := 1024


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount: %s" % src.error); quit(1); return
	var res_name := ""
	for rn in src.res.keys():
		if int(src.res[rn][5]) == TREE_RES:
			res_name = str(rn); break
	var raw: PackedByteArray = src.get_res(res_name)
	var t = BF6Terrain.new()
	var sp = BF6Splat.new()
	if not sp.parse(t.find_block(raw, 1)):
		print("FAIL block 1: %s" % sp.error); quit(1); return
	var dir := t.read_chunk_directory(raw)
	if not sp.detect_layout(dir):
		print("FAIL layout: %s" % sp.error); quit(1); return
	var fetch := func(g): return src.get_chunk(str(g))

	# the referee
	var cmap := sp.assemble_colors(sp.color_tiles(dir, fetch), SIZE)
	if cmap == null:
		print("FAIL: no colour map"); quit(1); return

	var pidx: Dictionary = src.partition_index()
	var pal = BF6TerrainLayers.new()
	if not pal.load(src, level, pidx):
		print("FAIL palette: %s" % pal.error); quit(1); return
	var grass := -1
	for l in pal.layers:
		var i := int((l as Dictionary)["index"])
		if pal.albedo_of(i).contains("grass"):
			grass = i; break
	if grass < 0:
		print("this level has no grass layer, so there is no referee here")
		quit(0); return
	print("referee: L%02d %s against the colour map\n"
		% [grass, pal.albedo_of(grass).get_file()])

	# --- §14 item 2 ----------------------------------------------------------
	print("§14 item 2 — splat page packing inside paired chunks")
	var how_many := 0
	for key in dir.keys():
		if str((dir[key] as Dictionary)["paired"]) != "":
			how_many += 1
	print("   %d of %d directory nodes carry a paired chunk" % [how_many, dir.size()])

	for mode in ["plain reversed index [3,2,1,0]", "reversed quadrant [2,3,1,0]"]:
		sp.paired_child_swap = mode.begins_with("reversed quadrant")
		var comp: Dictionary = sp.composite(dir, fetch, SIZE)
		var r := _score(comp, cmap, SIZE, grass)
		print("   %-32s  grass %.2f%% of ground, green excess on %+.4f off %+.4f, gap %+.4f"
			% [mode, 100.0 * float(r["frac"]), r["on"], r["off"], r["gap"]])

	# --- §14 item 1 ----------------------------------------------------------
	#
	# Report what block 4 actually contains before claiming anything about its
	# quadrant order: a mask that is nearly all one value has no spatial
	# structure for an oracle to grip, and saying so is the honest result.
	print("\n§14 item 1 — blocks 4/5 quadrant order")
	for bt in [4, 5]:
		var b := t.find_block(raw, bt)
		if b.is_empty():
			print("   block %d: not present on this map" % bt)
			continue
		var dim := int(b.decode_s32(0x00))
		var total := int(b.decode_s32(0x31))
		var ok: bool = b.size() == 57 + 4 * total
		var leaves := 0
		var cov := 0
		var data := 0
		for i in range(total):
			var o := 57 + i * 4
			if o + 4 > b.size():
				break
			if int(b[o]) != 0: data += 1
			if int(b[o + 1]) != 0: cov += 1
			if int(b[o + 3]) == 0: leaves += 1
		print("   block %d: dim %d, %d nodes (size fits: %s), %d leaves, "
			% [bt, dim, total, ok, leaves]
			+ "hasData %d, coverage %d" % [data, cov])
		if cov == total or cov == 0:
			print("      coverage is constant, so no oracle can separate the two "
				+ "child orders here — the question stays open")
		else:
			print("      coverage varies (%.1f%%), so an oracle is possible; it "
				% (100.0 * float(cov) / float(maxi(1, total)))
				+ "needs a signal that is not itself quadrant-symmetric")

	quit(0)


func _score(comp: Dictionary, cmap: Image, size: int, grass: int) -> Dictionary:
	var idx: PackedByteArray = comp["idx"]
	var wgt: PackedByteArray = comp["w"]
	var on := 0.0
	var off := 0.0
	var n_on := 0
	var n_off := 0
	for i in range(0, size * size, 3):
		if wgt[i * 4] == 0:
			continue
		var c := cmap.get_pixel(i % size, int(i / size))
		var g := c.g - (c.r + c.b) * 0.5
		if int(idx[i * 4]) == grass:
			on += g; n_on += 1
		else:
			off += g; n_off += 1
	var m_on := on / float(maxi(1, n_on))
	var m_off := off / float(maxi(1, n_off))
	return {"on": m_on, "off": m_off, "gap": m_on - m_off,
		"frac": float(n_on) / float(maxi(1, n_on + n_off))}
