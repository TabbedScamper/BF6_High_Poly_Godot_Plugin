@tool
extends SceneTree
# Every distinct scope the placements resolve under, with how many groups each
# carries. The classification of "always on" vs "event/gamemode" has to come
# from this, not from guessing at names.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable()):
		print("open failed: ", gs.error); quit(1); return
	var d: Dictionary = gs.map_data("user://bench/aft")
	var by := {}
	var inst := {}
	for e in d.get("props", []):
		var k := str((e as Dictionary).get("mesh", ""))
		var meta = gs._group_meta.get(k)
		var scope: String = str(meta[1]) if meta != null and (meta as Array).size() > 1 else "?"
		by[scope] = int(by.get(scope, 0)) + 1
		inst[scope] = int(inst.get(scope, 0)) + int((((e as Dictionary).get("xf", []) as Array).size()) / 12)
	var rows: Array = []
	for k in by.keys(): rows.append([str(k), int(by[k]), int(inst[k])])
	rows.sort_custom(func(a, b): return int(a[2]) > int(b[2]))
	print("%-58s %7s %9s" % ["scope", "groups", "instances"])
	for r in rows:
		print("%-58s %7d %9d" % [str(r[0]).replace("game/glaciermp/levels/mp_aftermath/", "  ~/"), r[1], r[2]])
	quit(0)
