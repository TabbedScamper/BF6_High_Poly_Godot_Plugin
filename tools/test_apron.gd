@tool
extends SceneTree
# Do the 66x66 weight pages carry a 1-texel apron? If yes, a record's edge
# column is a COPY of its neighbour's first interior column - byte equality,
# not mere continuity. Tested over every adjacent same-layer record pair on
# mp_aftermath. H_apron: A[:,65] == B[:,1]. H_none: A[:,65] == B[:,0] would
# only be continuity-similar, never systematically identical.

func _col(page: PackedByteArray, x: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(66)
	for y in range(66):
		out[y] = page[y * 66 + x]
	return out


func _eq_rate(a: PackedByteArray, b: PackedByteArray) -> float:
	var same := 0
	for i in range(a.size()):
		if a[i] == b[i]:
			same += 1
	return float(same) / a.size()


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
	if not sp.parse(b1): print("FAIL parse"); quit(1); return
	var chunks := t.read_chunk_directory(res)
	if not sp.detect_layout(chunks): print("FAIL layout"); quit(1); return
	var fetch := func(g): return gs.src.get_chunk(str(g))
	# collect decoded pages per record with bounds+layer, node by node
	var recs: Array = []
	for n in sp.nodes:
		var nd: Dictionary = n
		if int(nd["pages"]) <= 0: continue
		var pages: Array = sp.node_pages(nd, chunks, fetch)
		if pages.is_empty(): continue
		for r in nd["records"]:
			var rd: Dictionary = r
			var pi := int(rd["page"])
			if pi < 0 or pi >= pages.size(): continue
			var pg := sp.decode_page(pages[pi], sp.page_size)
			if pg.size() < 66 * 66: continue
			recs.append({"lo": rd["min"], "hi": rd["max"],
				"layer": int(rd["layer"]), "pg": pg})
		if recs.size() > 900: break
	print("decoded records: %d" % recs.size())
	var pairs := 0
	var e_apron := 0.0
	var e_none := 0.0
	var exact_apron := 0
	var exact_none := 0
	for i in range(recs.size()):
		var a: Dictionary = recs[i]
		var w := (a["hi"] as Vector2).x - (a["lo"] as Vector2).x
		for j in range(recs.size()):
			if i == j: continue
			var b: Dictionary = recs[j]
			if int(b["layer"]) != int(a["layer"]): continue
			var bw := (b["hi"] as Vector2).x - (b["lo"] as Vector2).x
			if absf(bw - w) > 0.01: continue
			# B directly to A's +X, same Z band
			if absf((b["lo"] as Vector2).x - (a["hi"] as Vector2).x) > 0.01: continue
			if absf((b["lo"] as Vector2).y - (a["lo"] as Vector2).y) > 0.01: continue
			pairs += 1
			var a65 := _col(a["pg"], 65)
			var r1 := _eq_rate(a65, _col(b["pg"], 1))
			var r0 := _eq_rate(a65, _col(b["pg"], 0))
			e_apron += r1
			e_none += r0
			if r1 > 0.98: exact_apron += 1
			if r0 > 0.98: exact_none += 1
			if pairs >= 400: break
		if pairs >= 400: break
	if pairs == 0:
		print("no adjacent same-layer pairs found")
		quit(1); return
	print("pairs tested: %d" % pairs)
	print("A[:,65] vs B[:,1] (apron hypothesis): mean %.3f, >98%% identical on %d pairs"
		% [e_apron / pairs, exact_apron])
	print("A[:,65] vs B[:,0] (no apron):        mean %.3f, >98%% identical on %d pairs"
		% [e_none / pairs, exact_none])
	quit(0)
