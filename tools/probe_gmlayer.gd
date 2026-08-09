@tool
extends SceneTree
# What is actually inside a gameplay layer partition?
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	var pre := "game/glaciermp/levels/mp_aftermath/_layers_gameplay/"
	var parts: Array = []
	for k in gs.src.ebx.keys():
		var s := str(k)
		if s.begins_with(pre): parts.append(s)
	parts.sort()
	print("EBX partitions under _layers_gameplay: %d" % parts.size())
	for p in parts.slice(0, 24): print("   ", p.substr(pre.length()))
	if parts.size() > 24: print("   ... +%d more" % (parts.size() - 24))
	# Open one conquest partition and list the instance types inside it.
	var pick := ""
	for p in parts:
		if p.findn("conquest") >= 0: pick = p; break
	if pick == "":
		print("\nno conquest partition"); quit(0); return
	print("\nopening ", pick)
	var eb = gs.walk.open_ebx(pick)
	if eb == null:
		print("open_ebx returned null"); quit(0); return
	var types := {}
	for inst in eb.instances:
		var tn := str(gs.types.name_of(int(inst.get("type", 0)))) if gs.types != null else "?"
		if tn == "": tn = "0x%08X" % int(inst.get("type", 0))
		types[tn] = int(types.get(tn, 0)) + 1
	var rows: Array = []
	for k in types: rows.append([str(k), int(types[k])])
	rows.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	print("instance types (%d distinct):" % rows.size())
	for r in rows.slice(0, 30): print("   %-46s %d" % [r[0], r[1]])
	quit(0)
