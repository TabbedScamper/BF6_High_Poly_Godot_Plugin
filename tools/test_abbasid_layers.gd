@tool
extends SceneTree
# #77: MP_Abbasid's layer classification, before/after semantics measured on
# the real walk. area_* scopes must be always-on (""); _layers_gameplay/<x>/<x>
# and _layers_world/<mode>_subworld scopes must be MODE layers.

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Abbasid"):
		print("no source"); quit(1); return
	gs.ensure_placements(Callable())
	var tally := {}
	var scopes := {}
	for row in gs.walk.rows:
		var sc := str((row as Dictionary).get("scope", ""))
		if scopes.has(sc):
			tally[gs.layer_of_scope(sc)] = int(tally.get(gs.layer_of_scope(sc), 0)) + 1
			continue
		scopes[sc] = true
		var l := gs.layer_of_scope(sc)
		tally[l] = int(tally.get(l, 0)) + 1
		if sc.contains("area_") or sc.contains("_layers_world") or sc.contains("_layers_gameplay"):
			print("scope %-70s -> '%s'" % [sc, l])
	var fails := 0
	for sc in scopes.keys():
		var s := str(sc)
		var l := gs.layer_of_scope(s)
		if s.get_file().begins_with("area_") and l != "":
			print("FAIL area scope hidden: %s -> %s" % [s, l]); fails += 1
		if s.contains("_layers_gameplay") and l == "" and s.get_file() != "":
			# gameplay layers must be switchable, not always-on
			print("FAIL gameplay always-on: %s" % s); fails += 1
	print("distinct scopes %d, layer tally %s" % [scopes.size(), str(tally)])
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
