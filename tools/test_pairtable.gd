@tool
extends SceneTree
# Our pair->layer table for mp_aftermath, printed the way the reference probe
# prints its own - the two must be identical.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath"):
		print("no source"); quit(1); return
	var pick := ""
	for rn in gs.src.res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains("mp_aftermath"):
			pick = n; break
	var res: PackedByteArray = gs.src.get_res(pick)
	var t := BF6Terrain.new()
	var sp = BF6Splat.new()
	sp.parse(t.find_block(res, 1))
	var mt := BF6MaterialTree.new()
	mt.parse(t.find_block(res, 7))
	var pidx: Dictionary = gs.src.partition_index()
	var pal := BF6TerrainLayers.new()
	pal.load(gs.src, "mp_aftermath", pidx)
	var linked: Array = []
	for l in pal.layers:
		if int((l as Dictionary)["link"]) >= 0:
			linked.append(int((l as Dictionary)["index"]))
	linked.sort()
	var lists := {0: sp.full_list(), 1: sp.global_base_list(), 2: linked}
	print("pairs: %d  background: 0x%08X" % [mt.pairs.size(), mt.background])
	print("list1: ", sp.global_base_list())
	print("list2: ", linked)
	var row := "pair -> layer: {"
	for v in range(mt.pairs.size()):
		row += "%d: %s, " % [v, str(mt.resolve(v, lists))]
	print(row, "}")
	print("raw entries:")
	for v in range(mt.pairs.size()):
		var e := int(mt.pairs[v])
		print("  pair %2d: 0x%08X  X=0x%02X Ylo=%d framed=%s" % [v, e,
			(e >> 8) & 0xFF, (e >> 16) & 0xF,
			str(BF6MaterialTree.entry_is_framed(e))])
	# pooled per-node row values, exactly the probe's counting
	var counts := {}
	var tot := 0
	for n2 in mt.nodes:
		var rows: PackedByteArray = (n2 as Dictionary)["rows"]
		for b in rows:
			var lay := mt.resolve(int(b) & 0xF, lists)
			counts[lay] = int(counts.get(lay, 0)) + 1
			tot += 1
	print("pooled shares (probe: L0 95.3, L8 3.9, L2 0.5):")
	var ks: Array = counts.keys()
	ks.sort_custom(func(a, b2): return int(counts[a]) > int(counts[b2]))
	for k in ks.slice(0, 8):
		print("   L%-3s %6.2f%%" % [str(k), 100.0 * int(counts[k]) / tot])
	# which nodes hold L8 texels, and do their bounds map into the raster?
	var l8nodes := 0
	var shown := 0
	for n3 in mt.nodes:
		var nd: Dictionary = n3
		var rows: PackedByteArray = nd["rows"]
		var has8 := false
		for b in rows:
			if mt.resolve(int(b) & 0xF, lists) == 8:
				has8 = true
				break
		if not has8:
			continue
		l8nodes += 1
		if shown < 6:
			shown += 1
			var bnd: Array = BF6MaterialTree.bounds_of(int(nd["key"]),
				mt.world_min, mt.world_max)
			print("  L8 node key=0x%X depth=%s rows=%d dim=%d bounds=%s..%s" % [
				int(nd["key"]), str(nd.get("depth")), rows.size(), mt.dim,
				str(bnd[0]), str(bnd[1])])
	print("nodes carrying L8: %d of %d   world %s..%s dim %d" % [l8nodes,
		mt.nodes.size(), str(mt.world_min), str(mt.world_max), mt.dim])
	quit(0)
