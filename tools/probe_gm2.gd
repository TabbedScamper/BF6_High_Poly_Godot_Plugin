@tool
extends SceneTree
# What entity types live in a gamemode layer partition? Level mount only.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	print("opening..."); OS.delay_msec(1)
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed: ", gs.error); quit(1); return
	print("open done, ebx=%d" % gs.src.ebx.size())
	var pre := "game/glaciermp/levels/mp_aftermath/_layers_gameplay/"
	var parts: Array = []
	for k in gs.src.ebx.keys():
		var s := str(k)
		if s.begins_with(pre): parts.append(s)
	parts.sort()
	print("partitions under _layers_gameplay: %d" % parts.size())
	for p in parts.slice(0, 20): print("   ", p.substr(pre.length()))
	if parts.size() > 20: print("   ... +%d" % (parts.size() - 20))
	# open the first few and tally instance types
	var types := {}
	var opened := 0
	for p in parts:
		if opened >= 6: break
		var eb = gs.walk.open_ebx(p)
		if eb == null: continue
		opened += 1
		for i in range(eb.exported_instance_count):
			var tn := str(eb.instance_type(i))
			types[tn] = int(types.get(tn, 0)) + 1
	print("\nopened %d partitions, %d distinct instance types" % [opened, types.size()])
	var rows: Array = []
	for k in types: rows.append([str(k), int(types[k])])
	rows.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	for r in rows.slice(0, 30): print("   %-50s %d" % [r[0], r[1]])
	quit(0)
