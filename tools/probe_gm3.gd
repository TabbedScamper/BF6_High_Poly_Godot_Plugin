@tool
extends SceneTree
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	var lvl := "game/glaciermp/levels/mp_aftermath/"
	var hits := {}
	for k in gs.src.ebx.keys():
		var s := str(k)
		if not s.begins_with(lvl): continue
		var f := s.get_file()
		for w in ["gem_", "capture", "spawn", "objective", "mcom", "flag",
				"combatarea", "deploy", "hq_", "sector"]:
			if f.findn(w) >= 0:
				if not hits.has(w): hits[w] = []
				(hits[w] as Array).append(s.substr(lvl.length()))
				break
	print("level partitions matching gameplay words:")
	for w in hits:
		var a: Array = hits[w]
		print("  %-12s %d" % [w, a.size()])
		for x in a.slice(0, 6): print("        ", x)
	quit(0)
