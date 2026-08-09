@tool
extends SceneTree
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	# every vehicle art directory the install actually has
	var dirs := {}
	for rn in gs.src.res.keys():
		var n := str(rn)
		if not n.begins_with("common/hardware/vehicles/"): continue
		var p := n.substr(25)
		var bits := p.split("/")
		if bits.size() >= 3 and bits[2] == "art":
			dirs["%s/%s" % [bits[0], bits[1]]] = true
	var names := dirs.keys()
	names.sort()
	print("install has %d vehicle art directories:" % names.size())
	print("  ", ", ".join(names))
	# the SDK's 28
	var sdk: Array = []
	for f in DirAccess.get_files_at("res://objects/gameplay/vehicles"):
		if str(f).ends_with(".tscn"): sdk.append(str(f).get_basename())
	sdk.sort()
	print("\nSDK has %d vehicle scenes. Matching VEH_<Name> to <dir> by name:" % sdk.size())
	var hit := 0
	for k in sdk:
		var want := str(k).trim_prefix("VEH_").to_lower().replace("_", "")
		var found := ""
		for d in names:
			var leaf := str(d).get_file().replace("_", "")
			if leaf == want or want.begins_with(leaf) or leaf.begins_with(want):
				found = str(d); break
		if found != "": hit += 1
		print("  %-24s -> %s" % [k, found if found != "" else "NO MATCH"])
	print("\nmatched %d of %d" % [hit, sdk.size()])
	quit(0)
