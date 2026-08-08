extends SceneTree

# WHY A GREY PLANE SITS ON TOP OF THE CORRECT ROAD.
#
# The report is that the right road texture is there, underneath a plain plane
# that follows the same spline. That is two ribbons over the same ground with
# the wrong one winning, and it is a DRAW ORDER problem, not a texture one.
#
# These decals draw blended with depth writes off (TERRAIN.md §10.4), so depth
# cannot separate two coplanar ribbons — whichever is submitted LAST wins. The
# records are chained by FirstIndex in file order, which is an authored
# sequence; our builder groups them by material and then emits the groups in
# whatever order the dictionary happens to hold, which throws that sequence away.
#
# Two things to establish before changing anything:
#
#   1. DO they overlap? Count record pairs whose XZ boxes intersect, split by
#      whether each side carries its own textures.
#
#   2. Is file order the right order? If the plain fill records are
#      consistently EARLIER in the file than the detailed records that sit on
#      them, then record order is the paint order and restoring it is the fix.
#      If they are interleaved arbitrarily, it is not, and I need another rule.
#
#   godot --headless --path native/_testproj --script probe_roadorder.gd -- [level]

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
	var res := BF6Decals.find_res(gs.src, level)
	var raw: PackedByteArray = gs.src.get_res(res)
	var td = BF6Decals.new()
	if not td.parse(raw):
		print("FAIL: %s" % td.error); quit(1); return

	var recs: Array = []
	for i in range(td.records.size()):
		var rec: Dictionary = td.records[i]
		var pr: Dictionary = rec["props"]
		var has_tex := false
		for h in pr.keys():
			var e = pr[h]
			if e is Array and str((e as Array)[0]) == "tex":
				has_tex = true; break
		var lo: Vector3 = rec["aabb_min"]
		var hi: Vector3 = rec["aabb_max"]
		recs.append({"i": i, "tex": has_tex, "slot": int(rec["asset_slot"]),
			"lo": Vector2(lo.x, lo.z), "hi": Vector2(hi.x, hi.z),
			"area": maxf(0.0, hi.x - lo.x) * maxf(0.0, hi.z - lo.z),
			"tris": int(rec["tri_count"])})

	# --- 1. overlap ----------------------------------------------------------
	var pairs := 0
	var plain_over_tex := 0
	var tex_over_plain := 0
	var same := 0
	var examples: Array = []
	for a in range(recs.size()):
		var ra: Dictionary = recs[a]
		for b in range(a + 1, recs.size()):
			var rb: Dictionary = recs[b]
			if not _hits(ra, rb):
				continue
			pairs += 1
			if bool(ra["tex"]) == bool(rb["tex"]):
				same += 1
				continue
			# b is later in the file, so b paints over a
			if bool(rb["tex"]):
				tex_over_plain += 1
			else:
				plain_over_tex += 1
				if examples.size() < 6:
					examples.append("record %d (textured, %d tris) is overlapped by record %d (PLAIN, slot %d, %d tris)"
						% [int(ra["i"]), int(ra["tris"]), int(rb["i"]),
						   int(rb["slot"]), int(rb["tris"])])

	print("\n=== do the ribbons overlap? ===")
	print("record pairs whose XZ boxes intersect: %d" % pairs)
	print("   both the same kind:                 %d" % same)
	print("   a PLAIN record later than a textured one: %d" % plain_over_tex)
	print("   a TEXTURED record later than a plain one: %d" % tex_over_plain)
	for e in examples:
		print("      %s" % e)

	# --- 2. is file order the paint order? -----------------------------------
	var plain_idx: Array = []
	var tex_idx: Array = []
	var plain_area := 0.0
	var tex_area := 0.0
	for r in recs:
		if bool((r as Dictionary)["tex"]):
			tex_idx.append(int((r as Dictionary)["i"]))
			tex_area += float((r as Dictionary)["area"])
		else:
			plain_idx.append(int((r as Dictionary)["i"]))
			plain_area += float((r as Dictionary)["area"])
	print("\n=== where do the two kinds sit in the file? ===")
	print("plain records:    %d, index %d..%d, mean %.0f, total area %.0f m2"
		% [plain_idx.size(), plain_idx[0] if plain_idx else -1,
		   plain_idx[-1] if plain_idx else -1, _mean(plain_idx), plain_area])
	print("textured records: %d, index %d..%d, mean %.0f, total area %.0f m2"
		% [tex_idx.size(), tex_idx[0] if tex_idx else -1,
		   tex_idx[-1] if tex_idx else -1, _mean(tex_idx), tex_area])
	if _mean(plain_idx) < _mean(tex_idx):
		print("-> the plain fills sit EARLIER on average: file order paints the")
		print("   base first and the detail on top, which is what we must keep")
	else:
		print("-> the plain fills sit LATER on average, so file order alone is not")
		print("   the rule and something else orders these")

	# --- 3. what our builder does today --------------------------------------
	print("\n=== the order our builder emits ===")
	var groups := {}
	var order: Array = []
	for i in range(td.records.size()):
		var rec: Dictionary = td.records[i]
		var pr: Dictionary = rec["props"]
		var cv := _g(pr, BF6Decals.SLOT_CV)
		var op := _g(pr, BF6Decals.SLOT_OP)
		var key := "%s|%s" % [cv, op]
		if cv == "" and op == "":
			key = "layer:%d" % int(rec["asset_slot"])
		if not groups.has(key):
			groups[key] = i
			order.append(key)
	print("%d groups, emitted in first-seen order. First record index per group:"
		% order.size())
	var inversions := 0
	for k in range(order.size()):
		var first: int = groups[order[k]]
		if k < 8:
			print("   %2d. %-14s first record %d"
				% [k, str(order[k]).substr(0, 14), first])
		if k > 0 and first < int(groups[order[k - 1]]):
			inversions += 1
	print("groups emitted out of file order: %d of %d" % [inversions, order.size()])
	print("\n(a group is one draw call and carries ALL its records, so grouping by")
	print(" material cannot preserve per-record order exactly - the question is")
	print(" whether the group ORDER can be made to respect it)")
	quit(0)


func _g(pr: Dictionary, slot: int) -> String:
	var p = pr.get(slot)
	if not (p is Array) or str((p as Array)[0]) != "tex":
		return ""
	return BF6Decals.guid_str((p as Array)[1])


func _hits(a: Dictionary, b: Dictionary) -> bool:
	var alo: Vector2 = a["lo"]; var ahi: Vector2 = a["hi"]
	var blo: Vector2 = b["lo"]; var bhi: Vector2 = b["hi"]
	# a real overlap, not a shared edge
	return alo.x < bhi.x - 0.05 and blo.x < ahi.x - 0.05 \
		and alo.y < bhi.y - 0.05 and blo.y < ahi.y - 0.05


func _mean(a: Array) -> float:
	if a.is_empty(): return 0.0
	var s := 0.0
	for v in a: s += float(v)
	return s / float(a.size())
