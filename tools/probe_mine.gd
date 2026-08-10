@tool
extends SceneTree
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   ", s)
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	var t := Time.get_ticks_msec()
	var d := HighpolyGmMine.mine(gs, "mp_aftermath")
	print("mined in %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))
	if d.is_empty(): print("NOTHING MINED"); quit(1); return
	var modes: Dictionary = d["modes"]
	print("%-26s %8s %8s %8s %8s" % ["mode", "spawn", "capture", "objectiv", "areas"])
	for k in modes:
		var m: Dictionary = modes[k]
		var c := {"spawn":0, "capture":0, "objective":0}
		for mk in m["markers"]: c[str((mk as Dictionary)["type"])] += 1
		print("%-26s %8d %8d %8d %8d" % [k, c["spawn"], c["capture"], c["objective"],
			(m["areas"] as Array).size()])
	# a sample position, to prove they are real world coordinates
	for k in modes:
		var mk: Array = modes[k]["markers"]
		if mk.size() > 0:
			print("\nsample %s marker: %s at %s" % [k, mk[0]["type"], str(mk[0]["pos"])])
			break
	quit(0)
