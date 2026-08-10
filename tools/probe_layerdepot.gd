@tool
extends SceneTree
# WHERE THE MISSING GROUND LAYERS' MATERIALS LIVE.
#
# The palette declares 40 layers for MP_Aftermath and only 12 carry a texture.
# The 28 empty ones are not failing to parse - their tiling reads back fine, so
# the layer record IS being found. What fails is one line:
#
#     if depot.key_to_record.has(key):
#
# i.e. the shader state key that names the layer's material is not in the depot
# this reader picked. It picks ONE: the RES whose name contains "layergraph"
# and the level's name.
#
# So: list every layergraph depot this level has, and for each of the 40 layer
# keys say which of them holds it. If the missing 28 turn up in a sibling depot,
# the fix is to search them all. If they turn up nowhere, it is not a depot
# problem and this rules that out.

const RES_LAYERGRAPHS := 0xDE540C59
const RES_DEPOT := 0x73312045
const STRIDE := 32           # must match BF6TerrainLayers.STRIDE

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("open failed: %s" % str(gs.error)); quit(1); return
	var low: String = gs.level

	# every layergraph depot the mount has, and which belong to this level
	var depots: Array = []
	for rn in gs.src.res.keys():
		var n := str(rn).to_lower()
		if n.findn("layergraph") >= 0 and n.findn("shaderblockdepot") >= 0:
			depots.append(str(rn))
	depots.sort()
	print("== %d layergraph depot(s) in the mount" % depots.size())
	var mine: Array = []
	for n in depots:
		var is_level := str(n).to_lower().findn(low) >= 0
		if is_level:
			mine.append(n)
		print("   %s %s" % ["*" if is_level else " ", str(n)])
	print("   (* = name contains '%s', which is the one the reader picks)" % low)

	# the palette, to get the keys
	var pal := BF6TerrainLayers.new()
	if not pal.load(gs.src, low, gs.walk.gi if gs.walk != null else {}):
		print("palette load failed: %s" % pal.error); quit(1); return
	print("")
	print("   reader used depot: %s" % str(pal.depot_used))

	# re-read the layer graph to recover each layer's key
	var lg_name := ""
	for rn in gs.src.res.keys():
		var n := str(rn)
		if n.to_lower().findn("layergraphs") >= 0 and n.to_lower().findn(low) >= 0 \
				and n.to_lower().findn("depot") < 0:
			lg_name = n
			break
	if lg_name == "":
		print("could not find the layer graphs resource"); quit(1); return
	var lg: PackedByteArray = gs.src.get_res(lg_name)

	# open every candidate depot once
	var opened := {}
	for n in depots:
		var d := BF6Depot.new()
		if d.parse(gs.src.get_res(str(n))):
			opened[str(n)] = d
	print("   opened %d depot(s) successfully" % opened.size())

	print("")
	print("== per layer: which depot holds its key")
	var found_elsewhere := 0
	var found_nowhere := 0
	for i in range(pal.layers.size()):
		var alb := pal.albedo_of(i)
		if alb != "":
			continue                      # this one already works
		var key := lg.decode_u64(pal.record_offset + i * STRIDE + 20)
		var holders: Array = []
		for n in opened:
			if (opened[n] as BF6Depot).key_to_record.has(key):
				holders.append(str(n).get_file())
		if holders.is_empty():
			found_nowhere += 1
		else:
			found_elsewhere += 1
		print("   layer %-3d key 0x%016X  ->  %s" % [i, key,
			"NOWHERE" if holders.is_empty() else ", ".join(PackedStringArray(holders))])
	print("")
	print("   of the empty layers: %d have their key in SOME depot, %d in none"
		% [found_elsewhere, found_nowhere])
	quit(0)
