@tool
extends SceneTree
# Why the base field places on 0% when the fleet measured L00 95.3% +
# L08 3.9% + L02 0.5%. Rasterise block 7 with the CURRENT code and compare.

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
	var b1 := t.find_block(res, 1)
	var sp = BF6Splat.new()
	if not sp.parse(b1): print("FAIL splat parse"); quit(1); return
	var chunks := t.read_chunk_directory(res)
	if not sp.detect_layout(chunks): print("FAIL layout"); quit(1); return
	var b7 := t.find_block(res, 7)
	if b7.is_empty(): print("FAIL no block 7"); quit(1); return
	var pidx: Dictionary = gs.src.partition_index()
	var pal := BF6TerrainLayers.new()
	if not pal.load(gs.src, "mp_aftermath", pidx):
		print("FAIL palette"); quit(1); return
	var mt := BF6MaterialTree.new()
	if not mt.parse(b7): print("FAIL b7 parse: ", mt.error); quit(1); return
	var linked: Array = []
	for l in pal.layers:
		if int((l as Dictionary)["link"]) >= 0:
			linked.append(int((l as Dictionary)["index"]))
	linked.sort()
	var base := mt.rasterize(4096,
		func(cx, cz, w): return sp.base_list_at(cx, cz, w),
		sp.full_list(), linked, Vector2.INF, 0.0, sp.global_base_list())
	var hist := {}
	for i in range(base.size()):
		hist[int(base[i])] = int(hist.get(int(base[i]), 0)) + 1
	print("albedo_of(8) = '%s'" % pal.albedo_of(8))
	print("base field histogram at 4096 (fleet pooled: L00 95.3, L08 3.9):")
	var ks: Array = hist.keys()
	ks.sort_custom(func(a, b): return int(hist[a]) > int(hist[b]))
	for k in ks.slice(0, 10):
		var alb := pal.albedo_of(int(k)) if int(k) != 255 else ""
		print("   L%-3s %8.4f%%  albedo=%s" % [str(k),
			100.0 * int(hist[k]) / base.size(),
			alb.get_file() if alb != "" else "(none)"])
	quit(0)
