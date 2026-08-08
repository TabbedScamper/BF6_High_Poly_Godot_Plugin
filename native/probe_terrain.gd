extends SceneTree

# Reconnaissance around the terrain finds: what blocks a level actually ships,
# what the heightfield header says, and whether the 4-sample pad border that
# TERRAIN.md §4.4 specifies is really there.
#
# The pad test is the one that matters for us, because our own compositor
# ignores the border and samples 0..xs-1. If the border is real, every tile is
# being stretched over its own padding and the padding is a copy of the
# neighbour — which would show up as a seam and as slightly-wrong scale.
#
# The oracle needs no ground truth: if the border is padding, a node's pad
# columns are its NEIGHBOUR's interior columns, and the two nodes are
# independent records in the file. Exact byte equality across a whole column is
# not something two unrelated heightfields do.
#
#   godot --headless --path native/_testproj --script probe_terrain.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")

const TREE_RES := 0x22FE8AC8


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount: %s" % src.error); quit(1); return

	var res_name := ""
	for rn in src.res.keys():
		if int(src.res[rn][5]) == TREE_RES:
			res_name = str(rn); break
	if res_name == "":
		print("FAIL: no streaming tree"); quit(1); return
	var raw := src.get_res(res_name)
	print("tree: %s  (%d bytes)" % [res_name, raw.size()])

	# --- typed block inventory ------------------------------------------------
	var o := 0x22
	print("\nheader NodeCount %d  PersistentNodeCount %d"
		% [raw.decode_s32(0x19), raw.decode_s32(0x1E)])
	print("\nblocks:")
	var blocks := {}
	while o + 5 <= raw.size():
		var t := int(raw[o])
		if t == 0xFF:
			print("   0xFF terminator at %d, %d bytes of chunk directory follow"
				% [o, raw.size() - o - 1])
			break
		var sz := int(raw.decode_s32(o + 1))
		blocks[t] = [o + 5, sz]
		print("   block %-2d  %10d bytes  @ %d" % [t, sz, o + 5])
		o += 5 + sz

	# --- heightfield header ---------------------------------------------------
	var t2 = BF6Terrain.new()
	var hb := t2.find_block(raw, 0)
	if hb.is_empty():
		print("FAIL: %s" % t2.error); quit(1); return
	var names := ["NodeSamplesPerSide", "AtlasSampleCountX", "AtlasSampleCountY",
		"Blurriness", "WorldSizeY(f)", "PhysicsMetersPerSample(f)",
		"PhysicsCropWidth", "MinMaxStackDepth", "OccluderGridStackDepth",
		"DensityMapNodeSamplesPerSide", "DensityMapBorderWidth",
		"DensityMapNodeSamplesPerSidePot", "DensityMapResolutionRatio(f)",
		"NodeCount", "PersistentNodeCount", "PersistentDedicatedServerNodeCount",
		"Unknown0x40", "NodeBorderWidth"]
	print("\nblock 0 header:")
	for i in range(names.size()):
		var nm: String = names[i]
		if nm.ends_with("(f)"):
			print("   %-34s %.4f" % [nm, hb.decode_float(i * 4)])
		else:
			print("   %-34s %d" % [nm, hb.decode_s32(i * 4)])

	if not t2.read_block_header(hb):
		print("FAIL header: %s" % t2.error); quit(1); return
	if not t2.walk_nodes(hb):
		print("FAIL walk: %s" % t2.error); quit(1); return
	var dir := t2.read_chunk_directory(raw)
	var got := t2.resolve_external(dir, func(g): return src.get_chunk(g))
	print("\nnodes %d, external resolved %d" % [t2.nodes.size(), got])

	var xs: int = t2.xs
	var with_vals: Array = []
	for n in t2.nodes:
		if not (n["values"] as PackedByteArray).is_empty():
			with_vals.append(n)
	print("nodes carrying samples: %d   xs = %d" % [with_vals.size(), xs])

	# --- THE PAD-BORDER ORACLE ------------------------------------------------
	#
	# For every pair of nodes that share an edge in X at the same depth, compare
	# the columns the two hypotheses predict. Only one of them can produce exact
	# equality across a full column of independently-stored samples.
	var pairs := 0
	var pad_hits := 0        # A[xs-5] == B[4]        (border of 4 is padding)
	var nopad_hits := 0      # A[xs-1] == B[0]        (no padding)
	var pad_cols_hit := 0    # A[xs-4+j] == B[5+j]    (the pad IS the neighbour)
	var pad_cols_tried := 0
	for a in with_vals:
		for b in with_vals:
			if a == b: continue
			if int(a["depth"]) != int(b["depth"]): continue
			var amax: Vector3 = a["max"]; var bmin: Vector3 = b["min"]
			if absf(amax.x - bmin.x) > 0.01: continue
			if absf((a["min"] as Vector3).z - (b["min"] as Vector3).z) > 0.01: continue
			if absf(amax.z - (b["max"] as Vector3).z) > 0.01: continue
			pairs += 1
			var av: PackedByteArray = a["values"]
			var bv: PackedByteArray = b["values"]
			if _col_eq(av, bv, xs, xs - 5, 4): pad_hits += 1
			if _col_eq(av, bv, xs, xs - 1, 0): nopad_hits += 1
			for j in range(4):
				pad_cols_tried += 1
				if _col_eq(av, bv, xs, xs - 4 + j, 5 + j): pad_cols_hit += 1
			if pairs >= 40: break
		if pairs >= 40: break

	print("\npad-border oracle over %d x-adjacent same-depth node pairs:" % pairs)
	print("   A[x=%d] == B[x=%d]   (4-sample pad, shared edge)   %d / %d"
		% [xs - 5, 4, pad_hits, pairs])
	print("   A[x=%d] == B[x=%d]   (no pad)                    %d / %d"
		% [xs - 1, 0, nopad_hits, pairs])
	print("   pad columns are the neighbour's interior          %d / %d"
		% [pad_cols_hit, pad_cols_tried])

	# --- what the pad costs us ------------------------------------------------
	if pairs > 0 and pad_hits > 0:
		var usable := xs - 9
		print("\nour compositor samples 0..%d, so each tile is stretched over %d"
			% [xs - 1, xs])
		print("samples where only %d are its own: features are %.2f%% too small"
			% [usable + 1, 100.0 * (float(xs - 1) / float(usable) - 1.0)])

	# --- block 1 splat metadata header ---------------------------------------
	if blocks.has(1):
		var b1: PackedByteArray = raw.slice(blocks[1][0], blocks[1][0] + blocks[1][1])
		print("\nblock 1 (splat) header:")
		print("   ValidTexelHint   %d" % b1.decode_u32(0x00))
		print("   Version          %d" % b1.decode_u32(0x04))
		print("   unknown x4       %d %d %d %d" % [b1.decode_u32(0x08),
			b1.decode_u32(0x0C), b1.decode_u32(0x10), b1.decode_u32(0x14)])
		print("   bounds           %.1f %.1f  %.1f %.1f" % [b1.decode_float(0x18),
			b1.decode_float(0x1C), b1.decode_float(0x20), b1.decode_float(0x24)])
		print("   LayerSlotCount   %d" % b1.decode_u32(0x28))
		print("   NodeCount        %d" % b1.decode_u32(0x2C))
		print("   RecordCount      %d" % b1.decode_u32(0x30))
		print("   unknown x2       %d %d" % [b1.decode_u32(0x34), b1.decode_u32(0x38)])

	# --- block 7 footer: the material pair table ------------------------------
	if blocks.has(7):
		var b7: PackedByteArray = raw.slice(blocks[7][0], blocks[7][0] + blocks[7][1])
		print("\nblock 7 header: dim %d  blurriness %d  nodes %d  persistent %d  levelMax %d"
			% [b7.decode_u32(0), b7.decode_s32(4), b7.decode_u32(0x18),
			   b7.decode_u32(0x1C), b7.decode_u32(0x20)])

	# --- the other terrain resources in this mount ----------------------------
	print("\nterrain resources in the mount:")
	var want := {0x22FE8AC8: "streaming tree", 0xDE540C59: "compiled layer graphs",
		0x73312045: "layergraphs shader depot", 0x15E1F32E: "terrain decals",
		0x1CA38E06: "layer combinations", 0x9C4FAA17: "heightfield decal"}
	var seen := {}
	for rn in src.res.keys():
		var ty := int(src.res[rn][5])
		if want.has(ty):
			seen[ty] = int(seen.get(ty, 0)) + 1
			if int(seen[ty]) <= 2:
				print("   %-26s %s  (%d bytes)"
					% [want[ty], str(rn), src.get_res(str(rn)).size()])
	for ty in want.keys():
		if not seen.has(ty):
			print("   %-26s ABSENT" % want[ty])

	quit(0)


func _col_eq(av: PackedByteArray, bv: PackedByteArray, xs: int, ax: int, bx: int) -> bool:
	var same := 0
	var n := 0
	for z in range(xs):
		var ai := (z * xs + ax) * 2
		var bi := (z * xs + bx) * 2
		if ai + 1 >= av.size() or bi + 1 >= bv.size():
			return false
		n += 1
		if av[ai] == bv[bi] and av[ai + 1] == bv[bi + 1]:
			same += 1
	return n > 0 and same == n
