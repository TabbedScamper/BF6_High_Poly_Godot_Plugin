@tool
extends SceneTree
# Which depot slots the non-graffiti decal templates bind. The graffiti family
# uses decal_ca/decal_nrm; sootnoisy/gobo/dust records resolve but bind slots
# our SLOT_NAME table has no name for. This prints every slot of every distinct
# template's record, with the bound texture's NAME, so the hashes can be added
# with the right meanings rather than guessed.

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Capstone"):
		print("no source: ", gs.error)
		quit(1)
		return
	gs.map_data("user://edvtest", {"edv": true})   # runs the walk (cached now)
	var seen := {}
	for e in gs.walk.ents:
		var ent: Dictionary = e
		if str(ent.get("tag", "")) != "edv":
			continue
		var f: Dictionary = ent.get("f", {})
		var info = gs._edv_template(f.get(gs.F_EDV_TEMPLATE))
		if info == null:
			continue
		var tpl := str(info["name"])
		if seen.has(tpl):
			continue
		seen[tpl] = true
		var pair = gs._depot_for(str(ent.get("scope", "")))
		if pair == null:
			print("%s: no depot for scope %s" % [tpl, ent.get("scope", "")])
			continue
		var dep: BF6Depot = pair[0]
		var skey := int(info["key"])
		if not dep.key_to_record.has(skey):
			print("%s: no record for its key" % tpl)
			continue
		var slots: Dictionary = dep.textures_for(skey, pair[1])
		slots.erase("constants")
		print("%s:" % tpl)
		for k in slots.keys():
			var g := str(slots[k])
			var nm = gs.walk.gi.get(g)
			print("   %-14s %s" % [k, str(nm) if nm != null else g])
	print("done, %d distinct templates" % seen.size())
	quit(0)
