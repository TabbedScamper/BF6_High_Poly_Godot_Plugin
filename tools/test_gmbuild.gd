@tool
extends SceneTree
# The whole chain, once: install -> mined file -> real Portal objects.
#
# Runs INSIDE the Portal project, because instancing CapturePoint.tscn and
# PolygonVolume.tscn is half of what is being tested and those only exist there.
# It mines a map, writes the file, then builds a mode into a throwaway scene and
# reads back what actually landed - node types, the polygon on the volume, the
# spawns wired into their flag.
#
#   godot --headless --path C:/PortalSDK/GodotProject \
#         --script User_Created/tools/bf6-portal-highpoly-preview/tools/test_gmbuild.gd \
#         -- MP_Aftermath conquest
#
# The editor must be closed first: it holds this project.

var fails := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var want := str(args[1]) if args.size() > 1 else ""

	print("== mining %s from the install" % map)
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	var t := Time.get_ticks_msec()
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("FAIL open_map: %s" % str(gs.error))
		quit(1)
		return
	print("   mount %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))

	t = Time.get_ticks_msec()
	var n := HighpolyGmMine.mine_to_disk(gs, str(gs.level), map)
	print("   mine  %.1f s -> %d mode(s)" % [(Time.get_ticks_msec() - t) / 1000.0, n])
	if n <= 0:
		print("FAIL nothing mined")
		quit(1)
		return

	var d: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(HighpolyGamemode.data_path(map)))
	print("   schema v%d, %d bytes" % [int(d.get("v", 0)),
		FileAccess.open(HighpolyGamemode.data_path(map), FileAccess.READ).get_length()])
	ck("schema is current", int(d.get("v", 0)), HighpolyGamemode.SCHEMA)
	ck("dropdown lists them", HighpolyGamemode.modes(map).size(), n)
	ck("usable() agrees", HighpolyGamemode.usable(map), true)

	print("")
	print("%-22s %6s %8s %9s %7s" % ["mode", "total", "capture", "spawn", "other"])
	var modes: Dictionary = d["modes"]
	var keys: Array = modes.keys()
	keys.sort()
	for k in keys:
		var by := {}
		for o in ((modes[k] as Dictionary)["objects"] as Array):
			var kd := str((o as Dictionary).get("kind", "?"))
			by[kd] = int(by.get(kd, 0)) + 1
		var tot := 0
		for kd in by:
			tot += int(by[kd])
		var other := tot - int(by.get("capture", 0)) - int(by.get("spawn", 0))
		print("%-22s %6d %8d %9d %7d" % [k, tot, int(by.get("capture", 0)),
			int(by.get("spawn", 0)), other])

	# ---- build one into a scene made of the SDK's own objects ----
	var mode := want if want != "" and modes.has(want) else str(keys[0])
	print("")
	print("== building %s" % mode)
	var root := Node3D.new()
	root.name = "TestLevel"
	get_root().add_child(root)
	print("   %s" % HighpolyGamemode.apply(root, map, mode))

	var gm := HighpolyGamemode.built(root).get(mode)
	if gm == null:
		print("FAIL no node for the mode")
		quit(1)
		return
	ck("named for the mode", String((gm as Node).name),
		HighpolyGamemode.pretty(mode).replace(" ", ""))
	ck("in the scene dock", (gm as Node).owner == root, true)

	var by_type := {}
	var owned := 0
	var labels := 0
	var poly := 0
	var wired := 0
	for c in (gm as Node).get_children():
		if String(c.name) == "_HP_LABELS":
			labels = c.get_child_count()
			ck("labels are not saved", c.owner == null, true)
			continue
		var scn := String((c as Node).scene_file_path).get_file()
		by_type[scn] = int(by_type.get(scn, 0)) + 1
		if c.owner == root:
			owned += 1
		for g in c.get_children():
			if String((g as Node).scene_file_path).get_file() == "PolygonVolume.tscn":
				poly += 1
				var pts = g.get("points")
				if pts is PackedVector2Array and (pts as PackedVector2Array).size() >= 3:
					wired += 1
	print("   objects by scene: %s" % str(by_type))
	ck("every object is owned", owned, _count_objects(gm as Node))
	ck("one label per object", labels, _count_objects(gm as Node))
	ck("volumes carry a polygon", poly > 0 and poly == wired, true)

	# the polygons must be the game's, not the scene's 10x10 default
	var sizes: Array = []
	for c in (gm as Node).get_children():
		for g in c.get_children():
			if String((g as Node).scene_file_path).get_file() != "PolygonVolume.tscn":
				continue
			var a = g.call("area")
			sizes.append(int(a))
	if not sizes.is_empty():
		sizes.sort()
		print("   volume areas m2: min %d, median %d, max %d"
			% [int(sizes[0]), int(sizes[sizes.size() / 2]), int(sizes[-1])])
		ck("not the 10x10 default", int(sizes[-1]) != 100, true)

	# spawns wired into their flag
	for c in (gm as Node).get_children():
		if String((c as Node).scene_file_path).get_file() != "CapturePoint.tscn":
			continue
		var a = c.get("InfantrySpawnPoints_Team1")
		var b = c.get("InfantrySpawnPoints_Team2")
		var m := (a.size() if a is Array else 0) + (b.size() if b is Array else 0)
		if m > 0:
			print("   %s holds %d spawn(s)" % [String(c.name), m])
			break

	# ---- switching modes hides, it does not destroy ----
	if keys.size() > 1:
		var other_mode := str(keys[1]) if str(keys[1]) != mode else str(keys[0])
		print("")
		print("== switching to %s" % other_mode)
		print("   %s" % HighpolyGamemode.apply(root, map, other_mode))
		ck("first mode still in the tree",
			is_instance_valid(gm) and (gm as Node).get_parent() == root, true)
		ck("first mode hidden", (gm as Node3D).visible, false)
		print("   %s" % HighpolyGamemode.apply(root, map, mode))
		ck("switching back shows it", (gm as Node3D).visible, true)
		ck("and rebuilt nothing", HighpolyGamemode.built(root).size(), 2)

		# deleting it is a normal thing to do, and re-selecting must rebuild
		var n_before := _count_objects(gm as Node)
		root.remove_child(gm)
		(gm as Node).queue_free()
		ck("gone after delete", HighpolyGamemode.built(root).has(mode), false)
		print("   %s" % HighpolyGamemode.apply(root, map, mode))
		var again = HighpolyGamemode.built(root).get(mode)
		ck("rebuilt from the mined file", again != null, true)
		if again != null:
			ck("same object count", _count_objects(again as Node), n_before)

	print("")
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)


func _count_objects(gm: Node) -> int:
	var n := 0
	for c in gm.get_children():
		if String(c.name) != "_HP_LABELS":
			n += 1
	return n


func ck(name: String, got, want) -> void:
	var ok := str(got) == str(want)
	if not ok:
		fails += 1
	print("   %s %-34s got %s%s" % ["ok  " if ok else "FAIL", name, str(got),
		"" if ok else ("   want " + str(want))])
