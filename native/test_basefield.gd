extends SceneTree

# Does the block-7 material tree decode, and does the ground it describes match
# the ground the colour map photographs?
#
# The self-consistency checks are strong here — the node walk has to land the
# footer exactly on the end of the block, and every row of nibble-RLE has to
# produce exactly `dim` texels while consuming exactly its own bytes — but they
# only prove the container was read correctly. §8's material-pair semantics are
# empirical, so they need an outside referee.
#
# THE REFEREE IS LUMINANCE. §8 reports that on dumbo the pair entries resolve
# L08 concrete tile to the city blocks and L10 broken asphalt to the streets.
# Streets are darker than blocks in any aerial photograph, so if the resolution
# is right, the colour map must be measurably darker over the asphalt texels
# than over the concrete ones — and a shuffled control must destroy the gap.
#
#   godot --headless --path native/_testproj --script test_basefield.gd -- [level] [size]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")
const BF6Splat := preload("res://bf6_splat.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")
const BF6MaterialTree := preload("res://bf6_materialtree.gd")

const TREE_RES := 0x22FE8AC8


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var size := 2048
	if a.size() > 0 and str(a[0]) != "": level = str(a[0])
	if a.size() > 1 and str(a[1]) != "": size = int(str(a[1]))

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

	var fail := 0

	# --- block 7 --------------------------------------------------------------
	var b7 := t.find_block(raw, 7)
	if b7.is_empty():
		print("FAIL: no block 7: %s" % t.error); quit(1); return
	var mt = BF6MaterialTree.new()
	var t0 := Time.get_ticks_msec()
	if not mt.parse(b7):
		print("FAIL block 7: %s" % mt.error); quit(1); return
	var st: Dictionary = mt.stats()
	print("block 7 parsed in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	print("   dim %d, levelMax %d, %d nodes with payload (%d declared total)"
		% [st["dim"], st["levels"], st["nodes"], st["declared"]])
	print("   pair table %d entries, %d correctly framed, list kinds %s"
		% [st["pairs"], st["framed"], str(st["kinds"])])
	print("   BackgroundMaterialIndex 0x%08X" % int(st["background"]))
	for i in range(mt.pairs.size()):
		var e := int(mt.pairs[i])
		if e == 0:
			continue
		print("      pair %2d = 0x%08X  list %d  primary %d  secondary %d"
			% [i, e, BF6MaterialTree.entry_list_kind(e),
			   BF6MaterialTree.entry_primary(e), BF6MaterialTree.entry_secondary(e)])
	# §8 saw Y-lo only in {0,1,2} over 58 entries across four maps; anything else
	# means the entry decode is off.
	for k in (st["kinds"] as Dictionary).keys():
		if int(k) > 2:
			print("   FAIL: list kind %d is outside §8's observed {0,1,2}" % int(k))
			fail += 1

	# --- resolve --------------------------------------------------------------
	var pal = BF6TerrainLayers.new()
	if not pal.load(src, level, src.partition_index()):
		print("FAIL palette: %s" % pal.error); quit(1); return
	var linked: Array = []
	for l in pal.layers:
		if int((l as Dictionary)["link"]) >= 0:
			linked.append(int((l as Dictionary)["index"]))
	linked.sort()
	var full: Array = sp.full_list()
	print("\nlists: full %d layers, linked %d layers" % [full.size(), linked.size()])

	t0 = Time.get_ticks_msec()
	var base := mt.rasterize(size, func(k): return sp.base_list(k), full, linked)
	print("base field rasterised in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))

	var hist := {}
	var unresolved := 0
	for i in range(base.size()):
		var l := int(base[i])
		if l == 255:
			unresolved += 1
		else:
			hist[l] = int(hist.get(l, 0)) + 1
	print("unresolved texels: %.1f%%" % (100.0 * float(unresolved) / float(base.size())))
	if unresolved > base.size() / 2:
		print("FAIL: more than half the map resolves to nothing"); fail += 1
	var order: Array = hist.keys()
	order.sort_custom(func(x, y): return int(hist[x]) > int(hist[y]))
	print("\nbase layer by area:")
	for k in order.slice(0, 12):
		var nm := pal.albedo_of(int(k)).get_file()
		print("   L%02d  %5.1f%%  %s" % [int(k),
			100.0 * float(hist[k]) / float(base.size()),
			nm if nm != "" else "(shader-computed)"])

	# --- the referee ----------------------------------------------------------
	var cmap := sp.assemble_colors(sp.color_tiles(dir, func(g): return src.get_chunk(g)), size)
	if cmap == null:
		print("\nFAIL: no colour map to referee with"); quit(1); return
	var asphalt := -1
	var concrete := -1
	for l in pal.layers:
		var i := int((l as Dictionary)["index"])
		var nm := pal.albedo_of(i)
		if asphalt < 0 and nm.contains("asphaltbroken"):
			asphalt = i
		if concrete < 0 and nm.contains("concretetile"):
			concrete = i
	if asphalt < 0 or concrete < 0 or not hist.has(asphalt) or not hist.has(concrete):
		print("\n(this map has no asphalt/concrete pair in its base field — "
			+ "the luminance referee is skipped)")
	else:
		print("\nreferee: L%02d %s (streets) against L%02d %s (blocks)"
			% [asphalt, pal.albedo_of(asphalt).get_file(), concrete,
			   pal.albedo_of(concrete).get_file()])
		var da: Array = []
		var dc: Array = []
		for i in range(0, base.size(), 3):
			var l := int(base[i])
			if l != asphalt and l != concrete:
				continue
			var lum := cmap.get_pixel(i % size, int(i / size)).get_luminance()
			if l == asphalt: da.append(lum)
			else: dc.append(lum)
		if da.size() < 200 or dc.size() < 200:
			print("   too few samples (%d / %d) to test" % [da.size(), dc.size()])
		else:
			var m_a := _mean(da)
			var m_c := _mean(dc)
			print("   samples: %d asphalt, %d concrete" % [da.size(), dc.size()])
			print("   mean colour-map luminance  asphalt %.4f  concrete %.4f  gap %+.4f"
				% [m_a, m_c, m_c - m_a])
			var pool: Array = da + dc
			var rng := RandomNumberGenerator.new()
			rng.seed = 987654
			var beat := 0
			var gaps: Array = []
			for trial in range(200):
				var s := 0.0
				for k in range(da.size()):
					s += float(pool[rng.randi_range(0, pool.size() - 1)])
				var g: float = m_c - s / float(da.size())
				gaps.append(g)
				if absf(g) >= absf(m_c - m_a):
					beat += 1
			print("   shuffled gap sd %.4f, runs reaching the true gap: %d of 200"
				% [_sd(gaps), beat])
			if m_c - m_a <= 0.0:
				print("   FAIL: the streets are not darker than the blocks")
				fail += 1
			elif beat > 4:
				print("   FAIL: the gap is within shuffling noise")
				fail += 1
			else:
				print("   PASS: the streets are darker than the blocks, and "
					+ "shuffling destroys it")

	# --- a picture ------------------------------------------------------------
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	for z in range(size):
		for x in range(size):
			var l := int(base[z * size + x])
			img.set_pixel(x, z, Color(0, 0, 0) if l == 255
				else Color.from_hsv(fmod(float(l) * 0.137, 1.0), 0.7, 0.9))
	img.save_png("base_%s.png" % level)
	print("\nwrote base_%s.png" % level)

	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)


func _mean(a: Array) -> float:
	if a.is_empty(): return 0.0
	var s := 0.0
	for v in a: s += float(v)
	return s / float(a.size())


func _sd(a: Array) -> float:
	var m := _mean(a)
	var s := 0.0
	for v in a: s += (float(v) - m) * (float(v) - m)
	return sqrt(s / float(maxi(1, a.size())))
