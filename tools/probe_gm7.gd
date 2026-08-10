@tool
extends SceneTree
# Every instance type inside the conquest subworld's partitions, so the ones
# that matter can be named by joining back through the research tables.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	var pre := "game/glaciermp/levels/mp_aftermath/_layers_gameplay/conquest/"
	var parts: Array = []
	for k in gs.src.ebx.keys():
		if str(k).begins_with(pre): parts.append(str(k))
	parts.sort()
	print("conquest partitions: %d" % parts.size())
	var types := {}
	for p in parts:
		var eb = gs.walk.open_ebx(p)
		if eb == null: continue
		for i in range(eb.exported_instance_count):
			var t := str(eb.instance_type(i))
			types[t] = int(types.get(t, 0)) + 1
	var rows: Array = []
	for k in types: rows.append([str(k), int(types[k])])
	rows.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	print("%d distinct instance types:" % rows.size())
	for r in rows: print("   %s  %d" % [r[0], r[1]])
	quit(0)
