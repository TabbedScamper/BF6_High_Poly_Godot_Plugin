@tool
extends SceneTree
# What the mined file actually contains, by partition. Reads the JSON only, so
# it runs in a second and needs no install.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var p := "user://mapcontext/%s/gamemode_markers.json" % map
	if not FileAccess.file_exists(p):
		print("no file at ", ProjectSettings.globalize_path(p))
		quit(1)
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(p))
	var modes: Dictionary = d["modes"]
	var keys: Array = modes.keys()
	keys.sort()

	print("=== kinds across every mode")
	var all := {}
	for k in keys:
		for o in ((modes[k] as Dictionary)["objects"] as Array):
			var kd := str((o as Dictionary).get("kind", "?"))
			all[kd] = int(all.get(kd, 0)) + 1
	print(str(all))

	var want := str(args[1]) if args.size() > 1 else "conquest"
	print("")
	print("=== %s, by partition" % want)
	var by := {}
	for o in ((modes.get(want, {}) as Dictionary).get("objects", []) as Array):
		var od := o as Dictionary
		var key := "%s | %s" % [str(od.get("kind", "?")), str(od.get("src", "?"))]
		if not by.has(key):
			by[key] = {"n": 0, "area": []}
		(by[key] as Dictionary)["n"] = int((by[key] as Dictionary)["n"]) + 1
		if od.has("points"):
			(by[key] as Dictionary)["area"].append(int(_area(od["points"])))
	var bk: Array = by.keys()
	bk.sort()
	for k in bk:
		var e: Dictionary = by[k]
		var extra := ""
		if not (e["area"] as Array).is_empty():
			var a: Array = e["area"]
			a.sort()
			extra = "   areas m2 %s" % str(a)
		print("%5d  %s%s" % [int(e["n"]), k, extra])

	# WHAT TELLS A CAPTURE ZONE FROM A COMBAT BOUNDARY. Every conquest volume
	# comes out of one partition, so the name cannot say. These are the numbers
	# that might: the area, the authored height, and how near a
	# CombatAreaEntityData stands to each one.
	print("")
	print("=== %s volumes vs combat-area entities" % want)
	var vols: Array = []
	var refs: Array = []
	for o in ((modes.get(want, {}) as Dictionary).get("objects", []) as Array):
		var od := o as Dictionary
		if od.has("points"):
			vols.append(od)
		elif str(od.get("kind", "")) == "combatref":
			refs.append(od)
	vols.sort_custom(func(a, b): return _area(a["points"]) < _area(b["points"]))
	print("%10s %8s %6s   %-26s %s" % ["area m2", "points", "height",
		"centroid", "nearest combat entity"])
	for v in vols:
		var c := _centroid(v)
		var best := INF
		for r in refs:
			var rx: Array = r["xf"]
			best = minf(best, Vector3(rx[9], rx[10], rx[11]).distance_to(c))
		print("%10d %8d %6.1f   (%7.1f,%7.1f,%7.1f)   %s" % [
			int(_area(v["points"])), (v["points"] as Array).size(),
			float(v.get("height", 0.0)), c.x, c.y, c.z,
			("%.1f m" % best) if best < INF else "(none in this mode)"])
	for r in refs:
		var rx: Array = r["xf"]
		print("   combat entity at (%.1f, %.1f, %.1f)  from %s"
			% [rx[9], rx[10], rx[11], str(r.get("src", "?"))])

	# CONTAINMENT, which is a proof rather than a guess: a combat boundary has
	# to contain every other volume and every spawn; a capture zone cannot. If
	# one volume contains all the rest, it is the boundary, and that can be
	# checked instead of assumed.
	print("")
	print("=== %s containment (spawns in each volume, volumes in each volume)" % want)
	var spawns: Array = []
	for o in ((modes.get(want, {}) as Dictionary).get("objects", []) as Array):
		var od := o as Dictionary
		if str(od.get("kind", "")) == "spawn":
			var sx: Array = od["xf"]
			spawns.append(Vector3(sx[9], sx[10], sx[11]))
	var polys: Array = []
	for v in vols:
		polys.append(_world_poly(v))
	for i in range(vols.size()):
		var ns := 0
		for s in spawns:
			if _inside(polys[i], s):
				ns += 1
		var nv := 0
		for j in range(vols.size()):
			if i != j and _inside(polys[i], _centroid(vols[j])):
				nv += 1
		print("%10d m2   %3d of %d spawns   %d of %d other volumes" % [
			int(_area(vols[i]["points"])), ns, spawns.size(), nv, vols.size() - 1])

	print("")
	print("=== every mode's partitions (first 3 each)")
	for k in keys:
		var srcs := {}
		for o in ((modes[k] as Dictionary)["objects"] as Array):
			srcs[str((o as Dictionary).get("src", "?"))] = true
		var s: Array = srcs.keys()
		s.sort()
		print("%-42s %d partition(s): %s" % [k, s.size(),
			", ".join(PackedStringArray(s.slice(0, 3)))])
	quit(0)


func _world_poly(v: Dictionary) -> PackedVector2Array:
	var xf: Array = v["xf"]
	var out := PackedVector2Array()
	for p in (v["points"] as Array):
		var q := Vector3(p[0], p[1], p[2])
		out.append(Vector2(
			xf[0] * q.x + xf[3] * q.y + xf[6] * q.z + xf[9],
			xf[2] * q.x + xf[5] * q.y + xf[8] * q.z + xf[11]))
	return out


func _inside(poly: PackedVector2Array, p: Vector3) -> bool:
	return Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), poly)


func _centroid(v: Dictionary) -> Vector3:
	var pts: Array = v["points"]
	var xf: Array = v["xf"]
	var c := Vector3.ZERO
	for p in pts:
		c += Vector3(p[0], p[1], p[2])
	c /= float(pts.size())
	return Vector3(
		xf[0] * c.x + xf[3] * c.y + xf[6] * c.z + xf[9],
		xf[1] * c.x + xf[4] * c.y + xf[7] * c.z + xf[10],
		xf[2] * c.x + xf[5] * c.y + xf[8] * c.z + xf[11])


func _area(pts: Array) -> float:
	var n := pts.size()
	var a := 0.0
	for i in range(n):
		var c: Array = pts[i]
		var d: Array = pts[(i + 1) % n]
		a += float(c[0]) * float(d[2]) - float(d[0]) * float(c[2])
	return absf(a) * 0.5
