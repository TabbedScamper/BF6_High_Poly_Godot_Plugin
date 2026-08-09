@tool
extends SceneTree
# What each prop group's layer resolves to, and how many instances hide by
# default (anything that is not "" and not default_event).
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable()):
		print("open failed"); quit(1); return
	var d: Dictionary = gs.map_data("user://bench/aft2")
	var tally := {}
	for e in d.get("props", []):
		var ed: Dictionary = e
		var L := str(ed.get("layer", ""))
		var n := int((ed.get("xf", []) as Array).size() / 12)
		tally[L] = int(tally.get(L, 0)) + n
	var rows: Array = []
	for k in tally: rows.append([str(k), int(tally[k])])
	rows.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	var shown := 0
	var hidden := 0
	print("%-30s %10s  %s" % ["layer", "instances", "visible by default"])
	for r in rows:
		var vis: bool = str(r[0]) == "" or str(r[0]) == "default_event"
		if vis: shown += int(r[1])
		else: hidden += int(r[1])
		print("%-30s %10d  %s" % [("(always on)" if str(r[0])=="" else str(r[0])), r[1], vis])
	print("\nvisible %d, hidden until its layer is picked %d" % [shown, hidden])
	quit(0)
