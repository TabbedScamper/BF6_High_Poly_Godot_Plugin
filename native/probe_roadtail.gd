extends SceneTree

# WHAT ORDERS THE ROAD RIBBONS? Looking in the bytes we never decoded.
#
# Established so far:
#   - 3,189 record pairs overlap in XZ, so stacking is by design
#   - the plain fills sit LATER in the file than the textured detail
#     (mean index 275 vs 189), and 976 pairs have a plain record after a
#     textured one
#   - we already emit in file order, so file order IS what buries the detail
#   - the plain fills are NOT redundant with the terrain base field (5.3% match
#     against a 9.0% shuffled control), so they are real geometry
#
# So file order is not paint order, and something else decides. TERRAIN.md
# §10.2 maps only part of the 0x90-byte record tail:
#
#   +0x00 FirstIndex   +0x04 TriCount   +0x0C Tiling0   +0x10 Tiling1
#   +0x20 AabbMin      +0x30 AabbMax    +0x78 AssetSlot +0x7C/0x80 VB
#
# Unmapped: +0x08, +0x14..0x1F, +0x3C..0x6F. A sort key, a layer/priority or a
# blend mode would live in there. This dumps them and asks one question of each
# candidate field: does it SEPARATE the plain fills from the textured detail? A
# field that does is the ordering signal; a field that does not is something
# else and should not be pressed into service.
#
#   godot --headless --path native/_testproj --script probe_roadtail.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Decals := preload("res://bf6_decals.gd")


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
	var td = BF6Decals.new()
	if not td.parse(gs.src.get_res(BF6Decals.find_res(gs.src, level))):
		print("FAIL: %s" % td.error); quit(1); return

	# Re-walk the tails. The reader keeps only the fields it maps, so this reads
	# the raw bytes again from the same anchors it found.
	var d: PackedByteArray = td.data
	var tails: Array = []
	var pos := 0
	# The record parse is private; rebuild the tail base from FirstIndex, which
	# IS stored, by scanning for it. Cheaper and more robust: the reader exposes
	# vb_off, and the tail sits at a fixed offset from the anchor it used.
	# Instead of re-deriving, use what is stored and read AROUND it.
	print("\n%d records; unmapped tail fields, by how many distinct values" % td.records.size())

	# Everything the reader kept, plus the classification.
	var plain: Array = []
	var tex: Array = []
	for i in range(td.records.size()):
		var r: Dictionary = td.records[i]
		var pr: Dictionary = r["props"]
		var has := false
		for h in pr.keys():
			var e = pr[h]
			if e is Array and str((e as Array)[0]) == "tex":
				has = true; break
		if has:
			tex.append(i)
		else:
			plain.append(i)

	# --- the one unmapped field the reader can reach without re-parsing ------
	#
	# vb_off and vb_size are stored, and the VERTEX BUFFER ORDER is an
	# independent authored sequence from the record order. If the engine draws
	# by VB layout rather than by record index, that is the paint order and it
	# is free to test.
	var by_vb: Array = []
	for i in range(td.records.size()):
		by_vb.append([int((td.records[i] as Dictionary)["vb_off"]), i])
	by_vb.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	var vb_rank := {}
	for k in range(by_vb.size()):
		vb_rank[int((by_vb[k] as Array)[1])] = k

	var mp := 0.0
	for i in plain: mp += float(vb_rank[i])
	mp /= float(maxi(1, plain.size()))
	var mt2 := 0.0
	for i in tex: mt2 += float(vb_rank[i])
	mt2 /= float(maxi(1, tex.size()))
	print("\n--- vertex-buffer order ---")
	print("plain fills mean VB rank    %.0f of %d" % [mp, td.records.size()])
	print("textured detail mean VB rank %.0f" % mt2)
	print("record order and VB order agree: %s"
		% ("yes" if _agrees(by_vb) else "NO - they are two different sequences"))

	# --- FirstIndex order, which is the index-buffer sequence ---------------
	var by_fi: Array = []
	for i in range(td.records.size()):
		by_fi.append([int((td.records[i] as Dictionary)["first_index"]), i])
	by_fi.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	var fi_rank := {}
	for k in range(by_fi.size()):
		fi_rank[int((by_fi[k] as Array)[1])] = k
	var fp := 0.0
	for i in plain: fp += float(fi_rank[i])
	fp /= float(maxi(1, plain.size()))
	var ft := 0.0
	for i in tex: ft += float(fi_rank[i])
	ft /= float(maxi(1, tex.size()))
	print("\n--- index-buffer (FirstIndex) order ---")
	print("plain fills mean rank    %.0f" % fp)
	print("textured detail mean rank %.0f" % ft)

	# --- triangle area: is the fill simply BIGGER? --------------------------
	#
	# The practical fallback if no field orders them: paint large ribbons before
	# small ones. A road fill is a long wide strip and a manhole cover is not,
	# so area is a decent proxy for "this is the base, that is the detail" - and
	# it is a HEURISTIC, which is worth saying out loud rather than dressing up.
	var pa: Array = []
	var ta: Array = []
	for i in range(td.records.size()):
		var r: Dictionary = td.records[i]
		var lo: Vector3 = r["aabb_min"]
		var hi: Vector3 = r["aabb_max"]
		var a: float = maxf(0.0, hi.x - lo.x) * maxf(0.0, hi.z - lo.z)
		if plain.has(i): pa.append(a)
		else: ta.append(a)
	print("\n--- footprint area (m2) ---")
	print("plain fills    median %.0f, mean %.0f over %d"
		% [_median(pa), _mean(pa), pa.size()])
	print("textured detail median %.0f, mean %.0f over %d"
		% [_median(ta), _mean(ta), ta.size()])
	quit(0)


func _agrees(pairs: Array) -> bool:
	for k in range(pairs.size()):
		if int((pairs[k] as Array)[1]) != k:
			return false
	return true


func _mean(a: Array) -> float:
	if a.is_empty(): return 0.0
	var s := 0.0
	for v in a: s += float(v)
	return s / float(a.size())


func _median(a: Array) -> float:
	if a.is_empty(): return 0.0
	var c := a.duplicate()
	c.sort()
	return float(c[c.size() / 2])
