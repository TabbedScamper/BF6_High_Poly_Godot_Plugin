extends SceneTree

# ARE THE PLAIN ROAD RIBBONS THE SAME THING THE TERRAIN ALREADY PAINTS?
#
# The symptom: a plain plane follows the spline and the correct road texture is
# UNDERNEATH it. Underneath is our terrain, which since the block-7 work paints
# its base layer per texel — and on this map that base field is 16% cobblestone
# in exactly the shape of the city blocks.
#
# The 135 prop-less decal records name a terrain LAYER INDEX rather than any
# texture of their own. So there are two candidate readings and they want
# opposite fixes:
#
#   A. they are geometry to draw, and our draw order puts them over the detail.
#      Fix: reorder.
#   B. they are the road FILL that the terrain's own layer compositing already
#      accounts for — the same statement twice — and drawing them as a separate
#      lifted surface is what buries the road. Fix: do not draw them.
#
# The test discriminates. If a prop-less record's AssetSlot matches the layer the
# terrain's base field independently resolves at the same world position, far
# above chance, they are the same information. A shuffled control has to destroy
# it, because both rasters describe the same map and share large-scale structure.
#
#   godot --headless --path native/_testproj --script probe_roadvsbase.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Decals := preload("res://bf6_decals.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")
const BF6Splat := preload("res://bf6_splat.gd")
const BF6MaterialTree := preload("res://bf6_materialtree.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")

const TREE_RES := 0x22FE8AC8
const SIZE := 2048


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return

	# --- the terrain base field ---------------------------------------------
	var res_name := ""
	for rn in gs.src.res.keys():
		if int(gs.src.res[rn][5]) == TREE_RES:
			res_name = str(rn); break
	var raw: PackedByteArray = gs.src.get_res(res_name)
	var t = BF6Terrain.new()
	var sp = BF6Splat.new()
	if not sp.parse(t.find_block(raw, 1)):
		print("FAIL block 1: %s" % sp.error); quit(1); return
	var mt = BF6MaterialTree.new()
	if not mt.parse(t.find_block(raw, 7)):
		print("FAIL block 7: %s" % mt.error); quit(1); return
	var pal = BF6TerrainLayers.new()
	var pidx: Dictionary = gs.walk.gi if gs.walk != null else {}
	pal.load(gs.src, level, pidx)
	var linked: Array = []
	for l in pal.layers:
		if int((l as Dictionary)["link"]) >= 0:
			linked.append(int((l as Dictionary)["index"]))
	linked.sort()
	var base: PackedByteArray = mt.rasterize(SIZE, func(k): return sp.base_list(k),
		sp.full_list(), linked)
	print("\nbase field rasterised at %d, world %s..%s"
		% [SIZE, str(mt.world_min), str(mt.world_max)])

	# --- the prop-less road records ------------------------------------------
	var dres := BF6Decals.find_res(gs.src, level)
	var td = BF6Decals.new()
	if not td.parse(gs.src.get_res(dres)):
		print("FAIL decals: %s" % td.error); quit(1); return

	var span: Vector2 = mt.world_max - mt.world_min
	var hits := 0
	var total := 0
	var per_slot := {}
	var samples: Array = []          # (world point, record slot) for the control
	for rec in td.records:
		var r: Dictionary = rec
		var pr: Dictionary = r["props"]
		var textured := false
		for h in pr.keys():
			var e = pr[h]
			if e is Array and str((e as Array)[0]) == "tex":
				textured = true; break
		if textured:
			continue
		var slot := int(r["asset_slot"])
		var lo: Vector3 = r["aabb_min"]
		var hi: Vector3 = r["aabb_max"]
		# Sample the record's own footprint. The AABB overshoots a diagonal
		# ribbon, but a systematic overshoot cannot manufacture a MATCH — it can
		# only dilute one, so this is the conservative direction.
		for k in range(24):
			var fx := (float(k % 6) + 0.5) / 6.0
			var fz := (float(k / 6) + 0.5) / 4.0
			var wx: float = lo.x + (hi.x - lo.x) * fx
			var wz: float = lo.z + (hi.z - lo.z) * fz
			var px := int((wx - mt.world_min.x) / span.x * SIZE)
			var pz := int((wz - mt.world_min.y) / span.y * SIZE)
			if px < 0 or pz < 0 or px >= SIZE or pz >= SIZE:
				continue
			var b := int(base[pz * SIZE + px])
			if b == 255:
				continue
			total += 1
			samples.append([b, slot])
			if b == slot:
				hits += 1
				per_slot[slot] = int(per_slot.get(slot, 0)) + 1
	print("\nsamples inside prop-less road footprints: %d" % total)
	print("terrain base layer == the record's AssetSlot: %d (%.1f%%)"
		% [hits, 100.0 * float(hits) / float(maxi(1, total))])
	for s in per_slot.keys():
		print("   slot %2d matched %d times" % [int(s), int(per_slot[s])])

	# --- the control ---------------------------------------------------------
	# Re-pair each base-field reading with a record slot drawn from the same
	# pool. Two rasters of one map share structure, so the raw rate means
	# nothing without this.
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var shuffled := 0
	var trials := 40
	var best := 0
	for run in range(trials):
		var c := 0
		for s in samples:
			var pick: Array = samples[rng.randi_range(0, samples.size() - 1)]
			if int((s as Array)[0]) == int(pick[1]):
				c += 1
		shuffled += c
		best = maxi(best, c)
	var sh := float(shuffled) / float(maxi(1, trials))
	print("\nshuffled control: mean %.0f matches (%.1f%%), best of %d runs %d"
		% [sh, 100.0 * sh / float(maxi(1, total)), trials, best])
	if hits > best:
		print("\n-> the plain ribbons state the SAME layer the terrain already")
		print("   resolves at the same place, beyond anything shuffling produces.")
		print("   Drawing them as a separate lifted surface paints the road on")
		print("   top of the road.")
	else:
		print("\n-> no better than chance: they are NOT redundant with the base")
		print("   field, so they carry something the terrain does not and the")
		print("   fix is ordering, not removal.")
	quit(0)
