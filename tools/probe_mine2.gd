@tool
extends SceneTree
# End to end: write the file, then read it back the way the panel does.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   ", s)
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	var n := HighpolyGmMine.mine_to_disk(gs, "mp_aftermath", "MP_Aftermath")
	print("mine_to_disk -> %d modes" % n)
	var modes: Array = HighpolyGamemode.modes("MP_Aftermath")
	print("HighpolyGamemode.modes() -> %d: %s" % [modes.size(),
		", ".join(modes.slice(0, 8).map(func(x): return str(x)))])
	# and what the renderer would draw for one
	var p := HighpolyGamemode.data_path("MP_Aftermath")
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(p))
	var cq: Dictionary = (d["modes"] as Dictionary).get("conquest", {})
	print("conquest: %d markers, %d areas" % [(cq.get("markers", []) as Array).size(),
		(cq.get("areas", []) as Array).size()])
	print("file size: %d bytes" % FileAccess.open(p, FileAccess.READ).get_length())
	quit(0)
