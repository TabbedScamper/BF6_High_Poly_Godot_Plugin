extends SceneTree

# Does the terrain SURFACE decode — colour map, layer palette, splat weights —
# and does the result agree with the ground it claims to describe?
#
# Three checks, in order of how much they can be fooled:
#
#   BYTE-EXACT WALK. Block 1 is a variable-size record stream; a wrong field
#   offset desynchronises within a node or two and cannot land on the final
#   byte, nor match both declared counts.
#
#   THE CHAIN CLOSES. Every one of the compiled layer graph's ShaderBlockKeys
#   must resolve in the layergraphs depot (§9.1 makes 100% the rule that pins
#   the record offset), and every texture the depot names must exist as a RES in
#   the same mount.
#
#   THE SPLAT AGREES WITH THE PHOTO. The decisive one, because the first two
#   only prove self-consistency. The colour map is an independent raster of the
#   same ground, so if the resolved layers are real, the texels the splat calls
#   GRASS must be greener in the photo than the ones it does not — and a
#   shuffled control must destroy the effect. A splat read at the wrong offset
#   is still self-consistent; it is not correlated with the aerial photograph.
#
#   godot --headless --path native/_testproj --script test_terrainsurface.gd -- [level] [size]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")
const BF6Splat := preload("res://bf6_splat.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")

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
	if res_name == "":
		print("FAIL: no streaming tree"); quit(1); return
	var raw: PackedByteArray = src.get_res(res_name)

	var fail := 0

	# --- block 1 -------------------------------------------------------------
	var t = BF6Terrain.new()
	var b1 := t.find_block(raw, 1)
	if b1.is_empty():
		print("FAIL: no block 1: %s" % t.error); quit(1); return
	var sp = BF6Splat.new()
	if not sp.parse(b1):
		print("FAIL block 1: %s" % sp.error); quit(1); return
	print("block 1: %d nodes / %d records, byte-exact, bounds %s..%s"
		% [sp.nodes.size(), sp.declared_records, str(sp.root_min), str(sp.root_max)])

	var dir := t.read_chunk_directory(raw)
	if not sp.detect_layout(dir):
		print("FAIL layout: %s" % sp.error); quit(1); return
	print("page codec %d bytes, colour tile %d bytes (%dx%d BC7)"
		% [sp.page_size, sp.tile_bytes, sp.tile_side, sp.tile_side])

	# --- the colour map -------------------------------------------------------
	var tiles := sp.color_tiles(dir, func(g): return src.get_chunk(g))
	print("colour tiles: %d" % tiles.size())
	if tiles.is_empty():
		print("FAIL: no colour tiles"); fail += 1
	var cmap := _assemble_color(tiles, sp, size)
	if cmap == null:
		print("FAIL: colour map did not assemble"); quit(1); return
	cmap.save_png("surf_color_%s.png" % level)

	# --- the layer palette ----------------------------------------------------
	var pidx: Dictionary = src.partition_index()
	var pal = BF6TerrainLayers.new()
	if not pal.load(src, level, pidx):
		print("FAIL palette: %s" % pal.error); quit(1); return
	print("\npalette: %d layers, record table @ %d, keys resolve %.0f%%"
		% [pal.layers.size(), pal.record_offset, pal.resolve_rate * 100.0])
	var textured: Array = pal.textured_indices()
	print("layers binding a texture: %d" % textured.size())
	var missing := 0
	for i in textured:
		var alb := pal.albedo_of(int(i))
		if alb != "" and src.res_info(alb) == null:
			missing += 1
	print("albedos missing from the mount: %d" % missing)
	if missing > 0:
		fail += 1

	# --- the splat ------------------------------------------------------------
	var t0 := Time.get_ticks_msec()
	var sr := _composite(sp, dir, src, size)
	print("\nsplat: %d pages decoded in %.1f s, %.1f%% of texels covered"
		% [int(sr["pages"]), (Time.get_ticks_msec() - t0) / 1000.0,
		   100.0 * float(sr["covered"]) / float(size * size)])
	var idx: PackedByteArray = sr["idx"]
	var wgt: PackedByteArray = sr["w"]

	var hist := {}
	for i in range(size * size):
		if wgt[i * 4] > 0:
			var l := int(idx[i * 4])
			hist[l] = int(hist.get(l, 0)) + 1
	var order: Array = hist.keys()
	order.sort_custom(func(x, y): return int(hist[x]) > int(hist[y]))
	print("\ndominant layer by area:")
	for k in order.slice(0, 10):
		var nm := pal.albedo_of(int(k)).get_file()
		print("   L%02d  %5.1f%%  %.1f m/repeat  %s"
			% [int(k), 100.0 * float(hist[k]) / float(size * size),
			   pal.metres_per_repeat(int(k)), nm if nm != "" else "(no albedo)"])

	# --- THE ORACLE: does the splat agree with the aerial photo? -------------
	var grass := -1
	for i in textured:
		if pal.albedo_of(int(i)).contains("grass"):
			grass = int(i); break
	if grass < 0:
		print("\n(no grass layer on this map — the correlation check is skipped)")
	else:
		print("\ngrass layer: L%02d %s" % [grass, pal.albedo_of(grass).get_file()])
		var on: Array = []
		var off: Array = []
		for i in range(0, size * size, 7):
			if wgt[i * 4] == 0:
				continue
			var px := i % size
			var pz := int(i / size)
			var c := cmap.get_pixel(px * cmap.get_width() / size,
				pz * cmap.get_height() / size)
			# green EXCESS, not green: a bright grey pixel has a high G too, and
			# an aerial photo of a city is mostly bright grey.
			var g := c.g - (c.r + c.b) * 0.5
			if int(idx[i * 4]) == grass:
				on.append(g)
			else:
				off.append(g)
		if on.size() < 50:
			print("   too few grass samples (%d) to test" % on.size())
		else:
			var m_on := _mean(on)
			var m_off := _mean(off)
			print("   samples on grass %d, off grass %d" % [on.size(), off.size()])
			print("   mean green excess  on %.4f   off %.4f   gap %+.4f"
				% [m_on, m_off, m_on - m_off])
			# The control: re-draw the same number of samples from the same pool
			# at random. Two rasters of one map share large-scale structure, so a
			# raw gap proves nothing without this.
			var pool: Array = on + off
			var gaps: Array = []
			var rng := RandomNumberGenerator.new()
			rng.seed = 12345
			for trial in range(200):
				var s := 0.0
				for k in range(on.size()):
					s += float(pool[rng.randi_range(0, pool.size() - 1)])
				gaps.append(s / float(on.size()) - m_off)
			var sd := _sd(gaps)
			var beat := 0
			for g2 in gaps:
				if absf(float(g2)) >= absf(m_on - m_off):
					beat += 1
			print("   shuffled gap sd %.4f, runs reaching the true gap: %d of 200"
				% [sd, beat])
			if beat > 4 or (m_on - m_off) <= 0.0:
				print("   FAIL: the splat's grass is not greener in the photo")
				fail += 1
			else:
				print("   PASS: grass lands on green, and shuffling destroys it")

	_save_index(idx, wgt, size, pal, "surf_splat_%s.png" % level)
	print("\nwrote surf_color_%s.png and surf_splat_%s.png" % [level, level])
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


func _assemble_color(tiles: Dictionary, sp, size: int) -> Image:
	var keys: Array = tiles.keys()
	keys.sort_custom(func(x, y): return BF6Splat.depth_of(int(x)) < BF6Splat.depth_of(int(y)))
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var span: Vector2 = sp.root_max - sp.root_min
	var apron := 2 if sp.tile_side == 68 else 4
	for k in keys:
		var bc := Image.create_from_data(sp.tile_side, sp.tile_side, false,
			Image.FORMAT_BPTC_RGBA, tiles[k])
		if bc == null or bc.decompress() != OK:
			continue
		bc.convert(Image.FORMAT_RGBA8)
		var inner := bc.get_region(Rect2i(apron, apron, sp.tile_side - apron * 2,
			sp.tile_side - apron * 2))
		var b: Array = BF6Splat.bounds_of(int(k), sp.root_min, sp.root_max)
		var lo: Vector2 = b[0]
		var hi: Vector2 = b[1]
		var x0 := int(floor((lo.x - sp.root_min.x) / span.x * size))
		var z0 := int(floor((lo.y - sp.root_min.y) / span.y * size))
		var w := maxi(1, int(round((hi.x - lo.x) / span.x * size)))
		var h := maxi(1, int(round((hi.y - lo.y) / span.y * size)))
		inner.resize(w, h, Image.INTERPOLATE_LANCZOS)
		img.blit_rect(inner, Rect2i(0, 0, w, h), Vector2i(x0, z0))
	return img


# Coarse-first, so a deeper node's finer page overwrites what a coarse one laid
# down. Per texel we keep the four strongest layers, which is what the shader's
# splat path consumes.
func _composite(sp, dir: Dictionary, src, size: int) -> Dictionary:
	var idx := PackedByteArray(); idx.resize(size * size * 4)
	var wgt := PackedByteArray(); wgt.resize(size * size * 4)
	var span: Vector2 = sp.root_max - sp.root_min
	var order: Array = sp.nodes.duplicate()
	order.sort_custom(func(x, y): return int(x["depth"]) < int(y["depth"]))
	var decoded := 0
	for n in order:
		var nd: Dictionary = n
		if int(nd["pages"]) <= 0:
			continue
		var pages: Array = sp.node_pages(nd, dir, func(g): return src.get_chunk(g))
		if pages.is_empty():
			continue
		for r in nd["records"]:
			var rd: Dictionary = r
			var pi := int(rd["page"])
			if pi < 0 or pi >= pages.size():
				continue
			var page := BF6Splat.decode_page(pages[pi], sp.page_size)
			if page.size() < BF6Splat.PAGE_SIDE * BF6Splat.PAGE_SIDE:
				continue
			decoded += 1
			var lo: Vector2 = rd["min"]
			var hi: Vector2 = rd["max"]
			var x0 := clampi(int(floor((lo.x - sp.root_min.x) / span.x * size)), 0, size - 1)
			var x1 := clampi(int(ceil((hi.x - sp.root_min.x) / span.x * size)), 0, size)
			var z0 := clampi(int(floor((lo.y - sp.root_min.y) / span.y * size)), 0, size - 1)
			var z1 := clampi(int(ceil((hi.y - sp.root_min.y) / span.y * size)), 0, size)
			if x1 <= x0 or z1 <= z0:
				continue
			var layer := int(rd["layer"])
			var ps := BF6Splat.PAGE_SIDE
			for gz in range(z0, z1):
				var fz := float(gz - z0) / float(maxi(1, z1 - z0 - 1)) if z1 - z0 > 1 else 0.0
				var sy := clampi(int(fz * float(ps - 1)), 0, ps - 1)
				var row := sy * ps
				var drow := gz * size
				for gx in range(x0, x1):
					var fx := float(gx - x0) / float(maxi(1, x1 - x0 - 1)) if x1 - x0 > 1 else 0.0
					var w := int(page[row + clampi(int(fx * float(ps - 1)), 0, ps - 1)])
					if w == 0:
						continue
					_insert(idx, wgt, (drow + gx) * 4, layer, w)
	var covered := 0
	for i in range(size * size):
		if wgt[i * 4] > 0:
			covered += 1
	return {"idx": idx, "w": wgt, "pages": decoded, "covered": covered}


# Keep the four strongest layers per texel, slot 0 the strongest. A layer that
# is already present is UPDATED rather than added a second time — the same layer
# is painted by several nodes and would otherwise fill all four slots with
# itself.
static func _insert(idx: PackedByteArray, wgt: PackedByteArray, o: int,
		layer: int, w: int) -> void:
	var lb := layer & 0xFF
	for s in range(4):
		if wgt[o + s] > 0 and idx[o + s] == lb:
			if w > wgt[o + s]:
				wgt[o + s] = w
				_bubble(idx, wgt, o, s)
			return
	for s in range(4):
		if wgt[o + s] == 0:
			idx[o + s] = lb
			wgt[o + s] = w
			_bubble(idx, wgt, o, s)
			return
	if w > wgt[o + 3]:
		idx[o + 3] = lb
		wgt[o + 3] = w
		_bubble(idx, wgt, o, 3)


static func _bubble(idx: PackedByteArray, wgt: PackedByteArray, o: int, s: int) -> void:
	var i := s
	while i > 0 and wgt[o + i] > wgt[o + i - 1]:
		var tw := wgt[o + i]; wgt[o + i] = wgt[o + i - 1]; wgt[o + i - 1] = tw
		var ti := idx[o + i]; idx[o + i] = idx[o + i - 1]; idx[o + i - 1] = ti
		i -= 1


# A look at the dominant layer, coloured by layer index, so the street grid and
# the parks are visible as shapes rather than as statistics.
func _save_index(idx: PackedByteArray, wgt: PackedByteArray, size: int, pal,
		path: String) -> void:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGB8)
	for z in range(size):
		for x in range(size):
			var o := (z * size + x) * 4
			if wgt[o] == 0:
				img.set_pixel(x, z, Color(0, 0, 0))
				continue
			var l := int(idx[o])
			var c := Color.from_hsv(fmod(float(l) * 0.137, 1.0), 0.75,
				0.35 + 0.65 * float(wgt[o]) / 255.0)
			img.set_pixel(x, z, c)
	img.save_png(path)
