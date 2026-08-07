extends SceneTree

# Can every placement the walk produces actually be turned into geometry?
#
# The walk names each placement by its mesh ASSET path (an .ebx). Geometry lives
# in a RES of the same mount. If the two are the same name minus the extension
# this is a lookup; if they are not, #59 needs a resolution step nobody has
# written, and it is much better to learn that from a coverage number than from
# a half-built map with holes in it.
#
# Reports, over the DISTINCT meshes of a real map:
#   direct       res[name] with the .ebx dropped
#   suffixed     the same name with a known MeshSet suffix
#   unresolved   nothing in the mount answers to it
#
# and then actually parses a sample of the hits, because a name that resolves and
# whose bytes do not parse is not a hit — it is a hole that shows up later.
#
#   godot --headless --path <proj> --script test_resolve.gd -- <level> [game] [sample]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Walk := preload("res://bf6_walk.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")


func _init() -> void:
	await process_frame
	# Empty placeholders do not survive the shell, so an omitted game directory
	# slides the sample count into its slot and the run dies on
	# "no Data/layout.toc under 60". Classified rather than positional: a bare
	# integer is the sample, anything else is a path.
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var game := ""
	var sample := 60
	var seen_level := false
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if s.is_valid_int():
			sample = int(s)
		elif not seen_level:
			level = s
			seen_level = true
		else:
			game = s

	var src = BF6Source.new()
	if not src.open(game):
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return
	var types = BF6Types.new()
	var exe := ""
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			exe = c
			break
	if exe == "" or not types.open(exe):
		print("FAIL types: %s" % types.error); quit(1); return

	var w = BF6Walk.new(src, types)
	w.build_catalog()
	if not w.run_cached(level):
		print("FAIL walk"); quit(1); return
	print("%d rows%s" % [w.rows.size(),
		"  (from cache)" if w.stats.get("from_cache", false) else ""])

	# Distinct meshes, with how many placements each carries — so the coverage
	# number can be weighted by INSTANCES as well as by name. Missing one mesh
	# used 4,000 times is not the same as missing four used once.
	var by_mesh := {}
	for r in w.rows:
		var m := str((r as Dictionary)["mesh"])
		by_mesh[m] = int(by_mesh.get(m, 0)) + 1
	print("%d distinct meshes\n" % by_mesh.size())

	# THE WALK DOES NOT NAME MESHES, IT NAMES BLUEPRINTS. The first version of
	# this test looked the row's path up in `res` directly and got 0 of 2,727,
	# with a miss list full of gmc_combatarea and keyevents_global — gameplay
	# objects, not geometry. The pipeline's own resolver (build_multimat.
	# find_meshset) says the convention: a blueprint `X` owns the MeshSet
	# `X_mesh`, falling back to `X` itself.
	#
	# It also indexes by BASENAME rather than full path, so a MeshSet need not
	# live beside the blueprint that references it. Both are tried here, and
	# reported separately, because a basename index can collide across
	# directories and a full-path hit is the stronger claim.
	var by_leaf := {}
	for rn in src.res.keys():
		var leaf := str(rn).get_file()
		if not by_leaf.has(leaf):
			by_leaf[leaf] = str(rn)

	var direct := 0
	var direct_inst := 0
	var via_leaf := 0
	var via_leaf_inst := 0
	var missing: Array = []
	var missing_inst := 0
	var hits: Array = []
	for m in by_mesh:
		var n := str(m).to_lower()
		if n.ends_with(".ebx"):
			n = n.substr(0, n.length() - 4)
		var got := ""
		for cand in [n + "_mesh", n]:
			if src.res.has(cand):
				got = cand
				break
		if got != "":
			direct += 1
			direct_inst += int(by_mesh[m])
			hits.append(got)
			continue
		var leaf := n.get_file()
		for cand in [leaf + "_mesh", leaf]:
			if by_leaf.has(cand):
				got = str(by_leaf[cand])
				break
		if got != "":
			via_leaf += 1
			via_leaf_inst += int(by_mesh[m])
			hits.append(got)
		else:
			missing.append(n)
			missing_inst += int(by_mesh[m])

	var total_inst := 0
	for v in by_mesh.values():
		total_inst += int(v)
	print("RES BY NAME  (<blueprint>_mesh, then <blueprint>)")
	print("   full path   %5d meshes   %6d placements" % [direct, direct_inst])
	print("   by basename %5d meshes   %6d placements" % [via_leaf, via_leaf_inst])
	print("   RESOLVED    %5d of %5d meshes   %6d of %6d placements  (%.1f%%)"
		% [direct + via_leaf, by_mesh.size(), direct_inst + via_leaf_inst,
		   total_inst,
		   100.0 * (direct_inst + via_leaf_inst) / maxf(1.0, float(total_inst))])
	print("   unresolved  %5d meshes, %d placements  (%.1f%%)"
		% [missing.size(), missing_inst,
		   100.0 * missing_inst / maxf(1.0, float(total_inst))])
	for n in missing.slice(0, 10):
		print("      %s" % n)

	# A NAME THAT RESOLVES IS NOT YET GEOMETRY. Parse a sample: a hit whose
	# bytes do not parse is a hole that would otherwise appear as a missing prop
	# halfway through a build.
	if hits.is_empty():
		print("\nnothing to parse")
		quit(1); return
	var ms := BF6MeshSet.new()
	var parsed := 0
	var failed := 0
	var lods := 0
	var t0 := Time.get_ticks_msec()
	var n_try: int = mini(sample, hits.size())
	for i in range(n_try):
		var d: PackedByteArray = src.get_res(str(hits[i]))
		if d.is_empty():
			failed += 1
			continue
		var info := ms.parse(d)
		if info.is_empty():
			failed += 1
			if failed <= 5:
				print("      parse failed: %s (%s)" % [str(hits[i]).get_file(),
					ms.error if ms.error != "" else "empty"])
			continue
		parsed += 1
		lods += (info["lods"] as Array).size()
	print("\nMESHSET PARSE over %d sampled")
	print("   parsed %d, failed %d, %.1f lods each, %.1f ms per mesh"
		% [parsed, failed, float(lods) / maxf(1.0, float(parsed)),
		   float(Time.get_ticks_msec() - t0) / maxf(1.0, float(n_try))])
	quit(0)
