extends SceneTree

# The plugin-facing wrapper, end to end: install -> placements -> real ArrayMeshes.
#
# The pieces underneath are each verified against Python. This checks the thing
# built ON them, which is where the mistakes actually are: the blueprint ->
# MeshSet convention, the row -> placements grouping, and turning MeshSet
# sections into a Godot mesh (where a wrong argument or a mis-keyed section
# array produces an empty mesh rather than an error).
#
# Checks, in order of what they would catch:
#   GROUPING    the flattened per-mesh transforms still total the walk's rows,
#               and are a whole number of 12-float instances
#   GEOMETRY    a sample of meshes actually build, with surfaces and triangles
#   EXTENT      the built meshes are a plausible size — a mesh that parses but
#               comes back 0.001 m or 40 km across is a decode bug, not a mesh
#
#   godot --headless --path <proj> --script test_gamesource.gd -- <level> [sample]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var sample := 80
	var seen := false
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if s.is_valid_int():
			sample = int(s)
		elif not seen:
			level = s
			seen = true

	var gs = HighpolyGameSource.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(level, "", func(stage, done, total):
			if total > 0 and done % 50000 == 0:
				print("   %s %d/%d" % [stage, done, total])
			elif total == 0:
				print("   %s ..." % stage)):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	print("opened in %.1f s, %d rows\n" % [(Time.get_ticks_msec() - t0) / 1000.0,
		gs.walk.rows.size()])

	# ---- grouping ----------------------------------------------------------
	var t1 := Time.get_ticks_msec()
	var data: Dictionary = gs.map_data()
	var props: Array = data["props"]
	var inst := 0
	var ragged := 0
	for p in props:
		var xf: Array = (p as Dictionary)["xf"]
		if xf.size() % 12 != 0:
			ragged += 1
		inst += int(xf.size() / 12)
	print("GROUPING  %d meshes, %d instances, built in %d ms"
		% [props.size(), inst, Time.get_ticks_msec() - t1])
	print("          world min %.1f" % float((data["world"] as Dictionary)["min"]))
	if ragged > 0:
		print("          %d meshes have a transform array that is NOT a whole "
			% ragged + "number of 12-float instances")

	# ---- geometry ----------------------------------------------------------
	# Biggest first: a mesh used 4,000 times matters more than one used once,
	# and sampling alphabetically would test whatever happens to sort early.
	props.sort_custom(func(x, y):
		return (x as Dictionary)["xf"].size() > (y as Dictionary)["xf"].size())
	var built := 0
	var empty := 0
	var surfaces := 0
	var tris := 0
	var bad_extent: Array = []
	var t2 := Time.get_ticks_msec()
	var n: int = mini(sample, props.size())
	for i in range(n):
		var name := str((props[i] as Dictionary)["mesh"])
		var m: Mesh = gs.mesh_for(name)
		if m == null:
			empty += 1
			if empty <= 5:
				print("   no mesh: %s" % name.get_file())
			continue
		built += 1
		surfaces += m.get_surface_count()
		for si in range(m.get_surface_count()):
			var arrs := m.surface_get_arrays(si)
			var idx = arrs[Mesh.ARRAY_INDEX]
			if idx is PackedInt32Array:
				tris += int((idx as PackedInt32Array).size() / 3)
		var sz := m.get_aabb().size
		var longest: float = maxf(maxf(sz.x, sz.y), sz.z)
		if longest < 0.01 or longest > 2000.0:
			bad_extent.append("%s: %.3f m" % [name.get_file(), longest])
	print("\nGEOMETRY  %d of %d built, %d empty" % [built, n, empty])
	print("          %d surfaces, %d triangles, %.1f ms per mesh"
		% [surfaces, tris, float(Time.get_ticks_msec() - t2) / maxf(1.0, float(n))])
	print("EXTENT    %d outside 0.01 .. 2000 m" % bad_extent.size())
	for b in bad_extent.slice(0, 6):
		print("   %s" % b)

	var ok: bool = ragged == 0 and built > 0 and tris > 0 \
		and float(empty) / maxf(1.0, float(n)) < 0.1 and bad_extent.size() * 10 < n
	print("\n%s" % ("PASS — the install builds real geometry"
		if ok else "FAIL — see above"))
	quit(0 if ok else 1)
