@tool
extends SceneTree
# WHAT WATER A MAP ACTUALLY DECLARES.
#
# water() collects one type out of ONE partition and keeps only surfaces at
# least 1 m on both axes, which is the shape of an OCEAN: a flat rectangle at a
# fixed height. MP_Aftermath gets exactly that - one plane, 10000 x 10000 m at
# y 49.7. A river through a map whose ground spans 65..992 m is not that shape,
# so before assuming the reader is dropping it, look at what is there: the
# partition it picks, every instance of the water type in it with its size and
# height, and the types it is NOT collecting.
#
#   ... probe_water.gd -- MP_Tungsten

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Tungsten"
	var names := _guid_names()

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   | %s" % s)
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: %s" % str(gs.error)); quit(1); return

	print("")
	print("== what water() returns")
	var w: Array = gs.water()
	print("   %d surface(s)" % w.size())
	for s in w:
		var d: Dictionary = s
		print("      y %.1f   %.0f x %.0f m   centre (%.0f, %.0f)" % [
			float(d["height"]), float((d["size"] as Array)[0]),
			float((d["size"] as Array)[1]),
			float((d["center"] as Array)[0]), float((d["center"] as Array)[1])])

	var part: String = gs._water_partition()
	print("")
	print("== the partition it reads: '%s'" % part)
	if part == "":
		print("   none found - _water_partition scanned every ebx name and no")
		print("   candidate counted any water instances.")

	# every water-ish partition on the level, and what each holds
	print("")
	print("== every partition whose name mentions water")
	var lvl := ""
	for k in gs.src.ebx.keys():
		var at := str(k).findn("/levels/%s/" % map.to_lower())
		if at >= 0:
			lvl = str(k).substr(0, at + ("/levels/%s/" % map.to_lower()).length() - 1)
			break
	var hits: Array = []
	for k in gs.src.ebx.keys():
		var n := str(k)
		if lvl != "" and not n.begins_with(lvl):
			continue
		if n.findn("water") >= 0 or n.findn("river") >= 0 or n.findn("ocean") >= 0 \
				or n.findn("stream") >= 0:
			hits.append(n)
	hits.sort()
	print("   %d partition(s)" % hits.size())
	for n in hits.slice(0, 25):
		print("      %s" % n.trim_prefix(lvl + "/"))

	# and what types those partitions contain, named
	print("")
	print("== types inside them")
	var counts := {}
	for n in hits:
		var eb = gs.walk.open_ebx(n)
		if eb == null:
			continue
		for i in range(eb.instance_offsets.size()):
			var tg := str(eb.instance_type(i))
			if tg == "":
				continue
			var nm := str(names.get(tg, tg))
			counts[nm] = int(counts.get(nm, 0)) + 1
	var rows: Array = []
	for nm in counts:
		rows.append([int(counts[nm]), str(nm)])
	rows.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for r in rows.slice(0, 30):
		print("   %6d  %s" % [int(r[0]), str(r[1])])
	quit(0)


func _guid_names() -> Dictionary:
	var out := {}
	var p := "user://typeguids.tsv"
	if not FileAccess.file_exists(p):
		return out
	for line in FileAccess.get_file_as_string(p).split("\n"):
		var c := str(line).split("\t")
		if c.size() >= 2:
			out[str(c[0]).strip_edges()] = str(c[1]).strip_edges()
	return out
