@tool
extends SceneTree
# The gamemode miner and builder, on the parts that need no install and no SDK.
#
# Everything that turns a collected entity into a placed Portal object is pure:
# picking the polygon out of a field dict by shape, lettering the flags, tying a
# spawn to the flag it belongs to, moving a shape's points into the world and
# back into PolygonVolume's local XZ. Those are tested here against values whose
# right answer is known by hand.
#
# What is NOT covered: the walk that produces the entities (needs the game) and
# instancing the SDK scenes (needs the Portal project). Both are named at the
# end so a passing run is not read as more than it is.

var fails := 0


func _init() -> void:
	_shape_reading()
	_lettering()
	_spawn_to_flag()
	_volume_geometry()
	print("")
	if fails == 0:
		print("ALL OK")
		print("NOT COVERED HERE: the install walk (needs the game) and")
		print("instancing the SDK scenes (needs the Portal project).")
	else:
		print("%d FAILED" % fails)
	quit(1 if fails else 0)


func ck(name: String, got, want) -> void:
	var ok := str(got) == str(want)
	if not ok:
		fails += 1
	print("%s %-42s got %s%s" % ["ok  " if ok else "FAIL", name, str(got),
		"" if ok else ("   want " + str(want))])


func vec(x: float, y: float, z: float) -> Dictionary:
	return {BF6Walk.K_VEC_X: x, BF6Walk.K_VEC_Y: y, BF6Walk.K_VEC_Z: z}


# ---------- fields are found by shape, not by name ----------
func _shape_reading() -> void:
	print("-- reading a field dict by shape")
	# A VolumeVectorShapeData as the walk hands it over: Points as an array of
	# Vec3, Tension left at its 0.5 default, Height authored, two bools. The
	# hashes are deliberately arbitrary - the point is that none of them is
	# known and the values are still identified.
	var f := {
		0x11111111: 0.5,                                   # Tension (default)
		0x22222222: [vec(-10, 0, -10), vec(-10, 0, 10),
					 vec(10, 0, 10), vec(10, 0, -10)],     # Points
		0x33333333: true,                                  # IsClosed
		0x44444444: 12.5,                                  # Height
	}
	var pts := HighpolyGmMine._points_of(f)
	ck("polygon found", pts.size(), 4)
	ck("first point", str(pts[0]), "[-10.0, 0.0, -10.0]")
	ck("height is not Tension", HighpolyGmMine._height_of(f), 12.5)

	# Tension alone, nothing authored: no height, which PolygonVolume reads as
	# infinite - the right answer for a capture zone.
	ck("height with only Tension", HighpolyGmMine._height_of(
		{0x11111111: 0.5, 0x22222222: []}), 0.0)
	# two authored floats cannot be told apart, so neither is guessed at
	ck("height when ambiguous", HighpolyGmMine._height_of(
		{0x1: 3.0, 0x2: 9.0}), 0.0)

	# OBBData: the LinearTransform became the world xf, so the one Vec3 left is
	# HalfExtents.
	ck("half extents", HighpolyGmMine._vec3_of({0x1: Vector3(2, 3, 4), 0x2: 1.0}),
		Vector3(2, 3, 4))
	# AlternateSpawnEntityData: Priority is a float and Enabled a bool, so the
	# int is Team.
	ck("team", HighpolyGmMine._int_of({0x1: 1.0, 0x2: true, 0x3: 2}), 2)

	print("-- what a partition name says a volume is")
	ck("capture", HighpolyGmMine._role_of("conquest_capturepoint_a"), "capture")
	ck("combat beats hq", HighpolyGmMine._role_of("hq_combatarea"), "combat")
	ck("hq", HighpolyGmMine._role_of("conquest_hq_us"), "hq")
	ck("unknown falls back", HighpolyGmMine._role_of("conquest_zone_04"), "capture")

	print("-- one mode per subworld, digits folded")
	ck("plain", HighpolyGmMine._mode_of("conquest/conquest"), "conquest")
	ck("numbered variant", HighpolyGmMine._mode_of("conquest0/x"), "conquest")
	ck("winter is its own", HighpolyGmMine._mode_of("winter_domination/x"),
		"winter_domination")


# ---------- flags are lettered by position, not by walk order ----------
func _lettering() -> void:
	print("-- lettering")
	var objs := [
		_cap(100.0, 0.0), _cap(-100.0, 0.0), _cap(0.0, 0.0),
	]
	HighpolyGmMine._name_objects("conquest", objs)
	# sorted west to east, so the one at -100 is A whatever order it was found in
	ck("east flag", objs[0]["label"], "Flag C")
	ck("west flag", objs[1]["label"], "Flag A")
	ck("middle flag", objs[2]["label"], "Flag B")
	ck("mode carried", objs[0]["mode"], "conquest")

	# and the order is stable: shuffling the input must not move the letters
	var again := [_cap(0.0, 0.0), _cap(100.0, 0.0), _cap(-100.0, 0.0)]
	HighpolyGmMine._name_objects("conquest", again)
	ck("stable under reorder", again[2]["label"], "Flag A")


# ---------- a spawn takes the name of the flag it stands at ----------
func _spawn_to_flag() -> void:
	print("-- spawns")
	var objs := [
		_cap(-100.0, 0.0), _cap(100.0, 0.0),
		_spawn(-95.0, 3.0), _spawn(104.0, -2.0), _spawn(-100.0, 40.0),
	]
	HighpolyGmMine._name_objects("domination", objs)
	ck("near the west flag", objs[2]["label"], "Flag A Spawn")
	ck("near the east flag", objs[3]["label"], "Flag B Spawn")
	# 40 m out is still nearer A than B, and belongs to A
	ck("further out, same flag", objs[4]["label"], "Flag A Spawn")

	# with no flags at all a spawn still gets a readable name
	var lone := [_spawn(0.0, 0.0)]
	HighpolyGmMine._name_objects("teamdeathmatch", lone)
	ck("no flags on the mode", lone[0]["label"], "Spawn Point")


# ---------- the polygon lands where the game put it ----------
func _volume_geometry() -> void:
	print("-- volume geometry")
	# A shape whose points are local to a holder standing at (50, 10, -20),
	# turned a quarter turn about Y. The polygon is a 20 m square.
	var xf := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(50, 10, -20))
	var local := [[-10.0, 0.0, -10.0], [-10.0, 0.0, 10.0],
				  [10.0, 0.0, 10.0], [10.0, 0.0, -10.0]]
	var world := HighpolyGamemode._world_points(local, xf)
	ck("point count kept", world.size(), 4)
	var c: Vector3 = HighpolyGamemode._centre(world)
	# a square centred on its holder, so the centre is the holder's position
	ck("centre x", snappedf(c.x, 0.001), 50.0)
	ck("centre z", snappedf(c.z, 0.001), -20.0)
	ck("centre sits on the lowest point", snappedf(c.y, 0.001), 10.0)

	# PolygonVolume takes XZ relative to its own node, and its area must survive
	# the round trip: a 20 m square is 400 m2 wherever it is and however turned.
	var area := 0.0
	var n := world.size()
	for i in range(n):
		var a: Vector3 = world[i]
		var b: Vector3 = world[(i + 1) % n]
		area += (a.x - c.x) * (b.z - c.z) - (b.x - c.x) * (a.z - c.z)
	ck("area preserved", snappedf(absf(area) * 0.5, 0.01), 400.0)

	# a 12-float row is read back as the transform it was written from
	var back := HighpolyGamemode._xf([1, 0, 0, 0, 1, 0, 0, 0, 1, 7, 8, 9])
	ck("origin round trip", back.origin, Vector3(7, 8, 9))
	ck("a short row is identity", HighpolyGamemode._xf([1, 2, 3]), Transform3D())


func _cap(x: float, z: float) -> Dictionary:
	return {"kind": "capture", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, x, 0, z],
		"points": [[-5.0, 0.0, -5.0], [-5.0, 0.0, 5.0],
				   [5.0, 0.0, 5.0], [5.0, 0.0, -5.0]], "height": 0.0}


func _spawn(x: float, z: float) -> Dictionary:
	return {"kind": "spawn", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, x, 0, z], "team": 1}
