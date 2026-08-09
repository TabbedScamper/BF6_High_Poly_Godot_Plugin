@tool
extends SceneTree
# The Abrams hull surface: which depot, if any, holds its state key?
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var want := BF6Depot.key_hex(7778057341684822587)
	print("looking for state key ", want)
	var cand: Array = []
	for k in gs._depot_bundles.keys():
		var s := str(k)
		if s.findn("veh") >= 0 or s.findn("abrams") >= 0:
			cand.append(s)
	print("candidate scopes: %d" % cand.size())
	var hits: Array = []
	for s in cand:
		var pair = gs._depot_for(s)
		if pair == null: continue
		for rk in pair[0].key_to_record.keys():
			if BF6Depot.key_hex(int(rk)) == want:
				hits.append(s); break
	print("found in %d scope(s)" % hits.size())
	for h in hits.slice(0, 6): print("   ", h)
	quit(0)
