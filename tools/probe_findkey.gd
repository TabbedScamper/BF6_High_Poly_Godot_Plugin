@tool
extends SceneTree
# Which depot scope holds these shader state keys? Compared as HEX STRINGS:
# these keys have the high bit set and String.hex_to_int cannot represent them,
# which silently collapsed two of the three into one value on the first attempt.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var want := ["24493504082ce316", "95745203d6265d69", "82edd800df1c5ba4"]
	var scopes: Array = []
	for k in gs._depot_bundles.keys():
		var s := str(k)
		if s.findn("aftermath") >= 0 or s.findn("/common/") >= 0:
			scopes.append(s)
	print("searching %d candidate scopes\n" % scopes.size())
	var found := {}
	for s in scopes:
		var pair = gs._depot_for(s)
		if pair == null: continue
		var dep = pair[0]
		for rk in dep.key_to_record.keys():
			var h: String = BF6Depot.key_hex(int(rk))
			if want.has(h) and not found.has(h):
				found[h] = s
				print("  %s  ->  %s" % [h, s])
	print("\nfound %d of %d" % [found.size(), want.size()])
	for h in want:
		if not found.has(h): print("  %s : in none of them" % h)
	quit(0)
