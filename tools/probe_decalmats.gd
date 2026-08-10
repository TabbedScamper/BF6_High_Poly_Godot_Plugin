@tool
extends SceneTree
# WHAT THE TERRAIN DECALS ACTUALLY ARE, group by group.
#
# We call the whole layer "Roads", because on the maps it was written against
# that is what it is. MP_Tungsten builds 613 records in 20 groups and the river
# reads as mud where water should be, so the guess to test is that one of those
# groups IS the river - drawn with whatever texture the decal names, through the
# road shader, instead of as water.
#
# Grouped exactly as roads() groups them: by (basecolor, coverage) guid, or by
# "layer:N" for a record that carries no textures and takes a terrain layer's
# material instead. Names resolved through the partition index, so a watery one
# turns the guess into a fact.
#
#   ... probe_decalmats.gd -- MP_Tungsten

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Tungsten"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: %s" % str(gs.error)); quit(1); return
	var pidx: Dictionary = gs.walk.gi if gs.walk != null else {}

	var name: String = BF6Decals.find_res(gs.src, gs.level)
	if name == "":
		print("no TerrainDecals resource for %s" % map); quit(1); return
	print("== %s" % name)
	var td := BF6Decals.new()
	if not td.parse(gs.src.get_res(name)):
		print("parse failed: %s" % td.error); quit(1); return
	print("   %d record(s)" % td.records.size())

	var groups := {}
	for r in td.records:
		var rec: Dictionary = r
		var pr: Dictionary = rec["props"]
		var cv: String = _guid_of(pr, BF6Decals.SLOT_CV)
		var op: String = _guid_of(pr, BF6Decals.SLOT_OP)
		var key := "%s|%s" % [cv, op]
		var layer := -1
		if cv == "" and op == "":
			layer = int(rec["asset_slot"])
			key = "layer:%d" % layer
		if not groups.has(key):
			groups[key] = {"n": 0, "cv": cv, "op": op, "layer": layer, "tris": 0}
		var g: Dictionary = groups[key]
		g["n"] = int(g["n"]) + 1
		g["tris"] = int(g["tris"]) + int(rec["tri_count"])

	print("")
	print("%5s %7s  %-52s %s" % ["recs", "tris", "basecolor", "coverage / layer"])
	var keys: Array = groups.keys()
	keys.sort_custom(func(a, b): return int(groups[a]["n"]) > int(groups[b]["n"]))
	for k in keys:
		var g: Dictionary = groups[k]
		var cvn := "(none)"
		var opn := ""
		if str(g["cv"]) != "":
			cvn = str(pidx.get(str(g["cv"]), "(guid not indexed)")).get_file()
		if str(g["op"]) != "":
			opn = str(pidx.get(str(g["op"]), "(guid not indexed)")).get_file()
		if int(g["layer"]) >= 0:
			opn = "terrain layer %d" % int(g["layer"])
		print("%5d %7d  %-52s %s" % [int(g["n"]), int(g["tris"]),
			cvn.left(52), opn])

	# and call out anything watery, since that is the whole question
	print("")
	print("== anything whose texture mentions water")
	var found := 0
	for k in keys:
		var g: Dictionary = groups[k]
		for slot in ["cv", "op"]:
			if str(g[slot]) == "":
				continue
			var nm := str(pidx.get(str(g[slot]), "")).to_lower()
			if nm.findn("water") >= 0 or nm.findn("river") >= 0 \
					or nm.findn("stream") >= 0 or nm.findn("wet") >= 0:
				found += 1
				print("   %d record(s), %d tris: %s" % [int(g["n"]), int(g["tris"]),
					nm.get_file()])
	if found == 0:
		print("   none — the decals name no water texture at all")
	quit(0)


func _guid_of(props: Dictionary, slot: int) -> String:
	var p = props.get(slot)
	if not (p is Array) or str((p as Array)[0]) != "tex":
		return ""
	return BF6Decals.guid_str((p as Array)[1])
