extends SceneTree

# Does the terrain heightfield parse, and does it agree with the shipped r16?
#
# The spec's own correctness criterion is that the node walk consumes the block
# BYTE-EXACTLY, so that is checked first and failing it stops everything else:
# a grammar that desynchronises still yields nodes with plausible AABBs and
# nonsense samples, which would render as terrain rather than as an error.
#
# Then, if the packaged height.r16 is on disk, the composited grid is compared
# against it. That file is what the download ships and what the map context
# builds its ground from, so agreement with it is the real test — a heightfield
# that parses cleanly and describes different ground is worthless.
#
#   godot --headless --path <proj> --script test_terrain.gd -- [level] [r16 path]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var r16 := ""
	var seen := false
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if not seen:
			level = s
			seen = true
		else:
			r16 = s

	var src = BF6Source.new()
	if not src.open():
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return

	# The streaming tree is one RES per level. Found by name rather than by
	# scanning every res for a magic number: the naming is documented
	# (<level>_terrain.streamingtree_win32) and a name match cannot be confused
	# with an unrelated resource that happens to start with plausible bytes.
	var cands: Array = []
	for rn in src.res.keys():
		var n := str(rn)
		if n.contains("streamingtree"):
			cands.append(n)
	print("%d streamingtree resources in the mount" % cands.size())
	var pick := ""
	for n in cands:
		if n.to_lower().contains(level.to_lower()):
			pick = n
			break
	if pick == "" and not cands.is_empty():
		pick = str(cands[0])
	if pick == "":
		print("FAIL no streaming tree for %s" % level)
		quit(1); return
	var res := src.get_res(pick)
	print("using %s (%d bytes)\n" % [pick, res.size()])

	var t = BF6Terrain.new()
	var blk := t.find_block(res, BF6Terrain.BLOCK_HEIGHTS)
	if blk.is_empty():
		print("FAIL find_block: %s" % t.error)
		quit(1); return
	print("CONTAINER  NodeCount %d, heights block %d bytes"
		% [t.node_count, blk.size()])

	if not t.read_block_header(blk):
		print("FAIL block header: %s" % t.error)
		quit(1); return
	print("HEADER     xs %d, worldSizeY %.1f, per-node payload %d bytes"
		% [t.xs, t.world_size_y, t.data_size])

	if not t.walk_nodes(blk):
		print("FAIL walk: %s" % t.error)
		quit(1); return
	var inline_n := 0
	var ext_n := 0
	for n in t.nodes:
		if (n as Dictionary)["external"]:
			ext_n += 1
		elif not ((n as Dictionary)["values"] as PackedByteArray).is_empty():
			inline_n += 1
	print("WALK       byte-exact, %d nodes (%d inline, %d external)"
		% [t.nodes.size(), inline_n, ext_n])

	# The heights block carries the tree SHAPE; on Dumbo every value node is
	# External and the samples are in CAS chunks, so the directory is not
	# optional.
	var dir := t.read_chunk_directory(res)
	if dir.is_empty():
		print("FAIL chunk directory: %s" % t.error)
		quit(1); return
	print("DIRECTORY  %d nodes (container header said %d)"
		% [dir.size(), t.node_count])
	var got := t.resolve_external(dir,
		func(form): return src.get_chunk(str(form)))
	print("CHUNKS     %d of %d external nodes resolved" % [got, ext_n])

	# SIZED FROM THE REFERENCE, when there is one. The packaged grid is
	# 16,785,409 samples = 4097x4097, not 4096x4096 — the usual heightmap N+1,
	# one sample per grid LINE rather than per cell. Compositing at 4096 and
	# comparing shifts every row by one from the first, which reports a mean
	# difference of 14,014 on data that may be perfectly fine.
	var side := 4096
	if r16 != "" and FileAccess.file_exists(r16):
		var n_ref := int(FileAccess.get_file_as_bytes(r16).size() / 2)
		var s := int(round(sqrt(float(n_ref))))
		if s * s == n_ref:
			side = s
			print("\n(sizing the grid %dx%d from the reference)" % [s, s])
	var g := t.composite(side)
	if g.is_empty():
		print("FAIL composite: %s" % t.error)
		quit(1); return
	var lo: Vector3 = g["min"]
	var hi: Vector3 = g["max"]
	print("GRID       %dx%d from %d nodes, world x %.0f..%.0f  z %.0f..%.0f  y %.0f..%.0f"
		% [g["size"], g["size"], g["nodes"], lo.x, hi.x, lo.z, hi.z, lo.y, hi.y])

	# ---- against the shipped r16 -------------------------------------------
	if r16 == "" or not FileAccess.file_exists(r16):
		print("\nno packaged height.r16 given — the parse is UNVERIFIED against it")
		quit(1); return
	var f := FileAccess.open(r16, FileAccess.READ)
	var ref := f.get_buffer(f.get_length())
	f.close()
	var ours: PackedByteArray = g["data"]
	print("\nREFERENCE  %d bytes (%d samples), ours %d bytes"
		% [ref.size(), int(ref.size() / 2), ours.size()])
	if ref.size() != ours.size():
		print("           sizes differ — comparing the overlap only")
	var n: int = mini(ref.size(), ours.size()) / 2
	var same := 0
	var diff_sum := 0.0
	var worst := 0
	var nonzero_ref := 0
	for i in range(n):
		var a2 := ref.decode_u16(i * 2)
		var b2 := ours.decode_u16(i * 2)
		if a2 != 0:
			nonzero_ref += 1
		if a2 == b2:
			same += 1
		else:
			var d: int = absi(a2 - b2)
			diff_sum += float(d)
			worst = maxi(worst, d)
	print("SAMPLES    %d compared, %d identical (%.1f%%), mean |diff| %.1f, worst %d"
		% [n, same, 100.0 * same / maxf(1.0, float(n)), diff_sum / maxf(1.0, float(n)),
		   worst])
	print("           reference has %d non-zero samples (%.1f%%)"
		% [nonzero_ref, 100.0 * nonzero_ref / maxf(1.0, float(n))])

	# IS IT THE SAME TERRAIN, SCALED, OR DIFFERENT TERRAIN?
	#
	# Byte equality was never likely: the packaged r16 came out of a different
	# pipeline that chose its own resolution, filtering and normalisation. What
	# matters is whether the two describe the same ground, and a correlation
	# answers that where a mean difference cannot — r near 1 means the shape
	# agrees and only the encoding differs, which is a scaling fix; r near 0
	# means the heights are simply wrong.
	#
	# Strided rather than exhaustive: 16.8 million samples through GDScript is
	# minutes, and a 450k-sample stride settles a correlation to far more
	# precision than this needs.
	var stride := 37
	var cnt := 0
	var sa := 0.0
	var sb := 0.0
	var saa := 0.0
	var sbb := 0.0
	var sab := 0.0
	var amin := 65535
	var amax := 0
	var bmin := 65535
	var bmax := 0
	for i in range(0, n, stride):
		var a3 := ref.decode_u16(i * 2)
		var b3 := ours.decode_u16(i * 2)
		amin = mini(amin, a3); amax = maxi(amax, a3)
		bmin = mini(bmin, b3); bmax = maxi(bmax, b3)
		sa += a3; sb += b3
		saa += float(a3) * a3
		sbb += float(b3) * b3
		sab += float(a3) * b3
		cnt += 1
	var fc := float(cnt)
	var cov := sab / fc - (sa / fc) * (sb / fc)
	var va := saa / fc - (sa / fc) * (sa / fc)
	var vb := sbb / fc - (sb / fc) * (sb / fc)
	var r := cov / maxf(1e-9, sqrt(maxf(0.0, va) * maxf(0.0, vb)))
	print("\nRANGE      reference %d..%d (mean %.0f), ours %d..%d (mean %.0f)"
		% [amin, amax, sa / fc, bmin, bmax, sb / fc])
	print("CORRELATION r = %.4f over %d strided samples" % [r, cnt])
	if r > 0.95:
		print("           the same ground; the encoding differs")
	elif r > 0.5:
		print("           related but not the same — layout or filtering differs")
	else:
		print("           NOT the same terrain")
	quit(0)
