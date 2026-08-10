@tool
extends SceneTree
# EVERY type in a mode's partitions, named.
#
# The volumes cannot be classified from geometry - containment is disproven
# (conquest's largest holds 5 of 7 others; rush has no dominant volume at all)
# and there are only 4 CombatAreaEntityData on the whole map, all in
# strikepoint. So find what OWNS them instead: dump every instance type in the
# mode's own partitions and name it through the GUID table built from the C#
# type dumps in the research corpus.

const TSV := "user://typeguids.tsv"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := str(args[0]) if args.size() > 0 else "conquest"
	var names := {}
	if FileAccess.file_exists(TSV):
		for line in FileAccess.get_file_as_string(TSV).split("\n"):
			var p := str(line).split("\t")
			if p.size() >= 2:
				names[str(p[0]).strip_edges()] = str(p[1]).strip_edges()
	print("named %d type guids" % names.size())

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed: ", gs.error); quit(1); return

	var pre := ""
	for k in gs.src.ebx.keys():
		var s := str(k)
		var at := s.findn("/levels/mp_aftermath/_layers_gameplay/")
		if at >= 0:
			pre = s.substr(0, at) + "/levels/mp_aftermath/_layers_gameplay/"
			break

	var parts: Array = []
	for k in gs.src.ebx.keys():
		var s := str(k)
		if s.begins_with(pre + mode):
			parts.append(s)
	parts.sort()
	print("%d partition(s) under %s\n" % [parts.size(), mode])

	var counts := {}
	for p in parts:
		var eb = gs.walk.open_ebx(p)
		if eb == null:
			continue
		for i in range(eb.instance_offsets.size()):
			var tg := str(eb.instance_type(i))
			if tg == "":
				continue
			counts[tg] = int(counts.get(tg, 0)) + 1
	var rows: Array = []
	for g in counts:
		rows.append([int(counts[g]), str(names.get(g, "?")), str(g)])
	rows.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	print("%6s  %-46s %s" % ["count", "type", "guid"])
	for r in rows:
		print("%6d  %-46s %s" % [int(r[0]), str(r[1]), str(r[2])])
	quit(0)
