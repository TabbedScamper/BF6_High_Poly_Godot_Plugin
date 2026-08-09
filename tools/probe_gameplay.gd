@tool
extends SceneTree
# The walk rows that resolve to no geometry. The log calls them "gameplay
# objects" and drops them; the gamemode overlay needs exactly these.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable()):
		print("open failed: ", gs.error); quit(1); return
	var by_scope := {}
	var by_name := {}
	var kinds := {}
	var n := 0
	for r in gs.walk.rows:
		var row: Dictionary = r
		if gs.resolve_mesh(str(row["mesh"])) != "":
			continue
		n += 1
		var sc := str(row.get("scope", "?"))
		by_scope[sc] = int(by_scope.get(sc, 0)) + 1
		var nm := str(row["mesh"]).get_file()
		by_name[nm] = int(by_name.get(nm, 0)) + 1
		kinds[str(row.get("kind", "?"))] = int(kinds.get(str(row.get("kind","?")), 0)) + 1
	print("rows with no geometry: %d\n" % n)
	print("by kind:")
	for k in kinds: print("   %-28s %d" % [k, kinds[k]])
	print("\ntop 25 asset names:")
	var rows: Array = []
	for k in by_name: rows.append([str(k), int(by_name[k])])
	rows.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	for r in rows.slice(0, 25): print("   %-52s %d" % [r[0], r[1]])
	print("\nby scope (gameplay layers only):")
	var s2: Array = []
	for k in by_scope: s2.append([str(k), int(by_scope[k])])
	s2.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	for r in s2.slice(0, 18):
		print("   %-56s %d" % [str(r[0]).replace("game/glaciermp/levels/mp_aftermath/", "~/"), r[1]])
	quit(0)
