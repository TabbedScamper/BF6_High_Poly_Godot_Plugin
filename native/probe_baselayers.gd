extends SceneTree

# WHICH LAYERS ARE PAINTED, AND WHICH ARE THE BASE — because the splat alone
# produced a ground made of two textures and that did not add up.
#
# The map's palette has 16 layers with real materials (cobblestone, concrete
# tile, broken asphalt, fairway grass, sand, gravel). The weight pages paint 25
# layers. Only 2 of those 25 have a texture. So either most of the palette is
# unused, or the painted layers and the textured layers are two different sets.
#
# §5.1 already says which: a record whose flags bit8 is SET has NO stored page
# and full coverage — the IgnoreMask layers. §8 then resolves which of those
# covers each texel, through the block-7 material tree. If the textured layers
# turn out to be the no-page ones, then block 7 is not an optional refinement to
# the splat; it is where the ground's actual materials come from.
#
#   godot --headless --path native/_testproj --script probe_baselayers.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")
const BF6Splat := preload("res://bf6_splat.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")

const TREE_RES := 0x22FE8AC8


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
	var pal = BF6TerrainLayers.new()
	if not pal.load(src, level, src.partition_index()):
		print("FAIL palette: %s" % pal.error); quit(1); return

	var use: Dictionary = sp.layer_usage()
	var painted: Dictionary = use["painted"]
	var base: Dictionary = use["base"]

	var all := {}
	for k in painted.keys(): all[int(k)] = true
	for k in base.keys(): all[int(k)] = true
	var keys: Array = all.keys()
	keys.sort()

	var textured_painted := 0
	var textured_base := 0
	print("layer   painted   base   albedo")
	for k in keys:
		var i := int(k)
		var nm: String = pal.albedo_of(i)
		var p := int(painted.get(i, 0))
		var b := int(base.get(i, 0))
		if nm != "":
			if p > 0: textured_painted += 1
			if b > 0: textured_base += 1
		print("  L%02d %8d %6d   %s" % [i, p, b,
			nm.get_file() if nm != "" else "(shader-computed)"])

	print("\nlayers appearing as a PAINTED record: %d, of which textured: %d"
		% [painted.size(), textured_painted])
	print("layers appearing as a BASE record:    %d, of which textured: %d"
		% [base.size(), textured_base])

	# The whole point: if the textures are on the base side, the splat alone
	# cannot dress the ground and block 7 has to be read.
	if textured_base > textured_painted:
		print("\n-> the palette's materials are on the BASE side. The weight pages "
			+ "say WHERE the\n   painted layers go; the block-7 material tree (§7/§8) "
			+ "says which material is\n   underneath, and that is where the ground's "
			+ "look actually comes from.")
	else:
		print("\n-> the painted layers carry the materials; the base field is a "
			+ "refinement.")

	# What block 7 would have to decode, so the size of the job is on the record.
	var b7 := t.find_block(raw, 7)
	if not b7.is_empty():
		var pairs := 0
		# the footer sits after the node stream; read the count the spec gives by
		# walking backwards is not safe, so just report the header
		print("\nblock 7 present: dim %d, %d nodes, %d with inline payload, levelMax %d"
			% [b7.decode_u32(0), b7.decode_u32(0x18), b7.decode_u32(0x1C),
			   b7.decode_u32(0x20)])
	quit(0)
