extends SceneTree

# Do our placements agree with the packaged ones, ROTATION included?
#
# The reader was verified against the Python walk on positions and matched to
# 0.01 m — and shipped a map where every rotated object faced the wrong way,
# because the two conventions for a 12-float transform differ by a transpose and
# the translation is identical either way.
#
# Nothing cheap catches that. The positions match. A transposed rotation is
# still orthonormal, so an orthonormality audit passes it. And on mp_dumbo 26.3%
# of placements have a symmetric rotation where the transpose IS the original,
# so a spot check of a few props can come back clean.
#
# So this compares against the packaged placements.json — the build that was
# known good — element by element over all twelve floats, and reports the
# transpose case SEPARATELY from a general mismatch, because "wrong" and
# "wrong in exactly this way" are different bugs.
#
#   godot --headless --path <proj> --script test_transforms.gd -- <placements.json> [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")

const EPS := 0.002


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var ref := ""
	var level := "mp_dumbo"
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			ref = s; seen = 1
		else:
			level = s
	if ref == "" or not FileAccess.file_exists(ref):
		print("FAIL: give me a packaged placements.json to compare against")
		quit(1); return

	var d = JSON.parse_string(FileAccess.get_file_as_string(ref))
	if not (d is Dictionary):
		print("FAIL: %s is not readable" % ref)
		quit(1); return
	# The packaged file keys on a file stem; ours keys on a RES path plus a
	# scope. Both reduce to the mesh's leaf name, which is what can be joined.
	var want := {}
	var n_ref := 0
	for e in (d as Dictionary).get("props", []):
		var rec: Dictionary = e
		var stem := str(rec.get("glb", rec.get("mesh", ""))).get_file()
		if stem.ends_with(".glb"):
			stem = stem.substr(0, stem.length() - 4)
		var xf: Array = rec.get("xf", [])
		if stem == "" or xf.is_empty():
			continue
		if not want.has(stem):
			want[stem] = []
		for i in range(0, xf.size(), 12):
			if i + 12 <= xf.size():
				(want[stem] as Array).append(xf.slice(i, i + 12))
				n_ref += 1
	print("packaged: %d meshes, %d instances" % [want.size(), n_ref])

	var gs = HighpolyGameSource.new()
	gs.build_materials = false
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data("")

	# Instances are matched by POSITION, not by order: the two pipelines group
	# and sort differently, and comparing index-to-index would report a hundred
	# per cent mismatch on data that agrees perfectly.
	var joined := 0
	var exact := 0
	var transposed := 0
	var other := 0
	var no_mesh := 0
	var examples: Array = []
	for entry in data.get("props", []):
		var rec: Dictionary = entry
		var stem := str(rec["mesh"]).split("|")[0].get_file()
		if stem.ends_with("_mesh"):
			stem = stem.substr(0, stem.length() - 5)
		if not want.has(stem):
			no_mesh += 1
			continue
		var theirs: Array = want[stem]
		# position -> EVERY transform they have there, not the last one.
		#
		# Rotational copies share an origin: a carousel, a playground igloo, a
		# ring of seats are all placed at one point with different rotations.
		# Keeping a single transform per position made all of them compare
		# against whichever happened to be last and reported 41 false mismatches
		# — including four that looked like genuine transposes, which is exactly
		# the failure being hunted and would have been believed.
		var by_pos := {}
		for t in theirs:
			var pk := _pkey((t as Array)[9], (t as Array)[10], (t as Array)[11])
			if not by_pos.has(pk):
				by_pos[pk] = []
			(by_pos[pk] as Array).append(t)
		var ours: Array = rec["xf"]
		for i in range(0, ours.size(), 12):
			if i + 12 > ours.size():
				break
			var mine: Array = ours.slice(i, i + 12)
			var k := _pkey(mine[9], mine[10], mine[11])
			if not by_pos.has(k):
				continue
			var cands: Array = by_pos[k]
			joined += 1
			# Any transform they place at this point counts as a match. A hit on
			# the plain comparison wins over a hit on the transposed one, so a
			# rotation that is its own transpose is never miscounted as a bug.
			var hit_same := false
			var hit_tr := false
			for them in cands:
				if _same(mine, them as Array, false):
					hit_same = true
					break
				if _same(mine, them as Array, true):
					hit_tr = true
			if hit_same:
				exact += 1
			elif hit_tr:
				transposed += 1
				if examples.size() < 4:
					examples.append("%s at %.1f,%.1f,%.1f"
						% [stem, mine[9], mine[10], mine[11]])
			else:
				other += 1
				if examples.size() < 8:
					examples.append("%s DIFFERS: ours %s / theirs %s (%d there)"
						% [stem, _fmt(mine), _fmt(cands[0] as Array), cands.size()])

	print("\njoined by position: %d instances (%d of our meshes not in the packaged set)"
		% [joined, no_mesh])
	print("   identical                 %d (%.1f%%)"
		% [exact, 100.0 * exact / maxi(joined, 1)])
	print("   differ by a TRANSPOSE     %d (%.1f%%)"
		% [transposed, 100.0 * transposed / maxi(joined, 1)])
	print("   differ some other way     %d (%.1f%%)"
		% [other, 100.0 * other / maxi(joined, 1)])
	for e in examples:
		print("      %s" % e)

	var fail := 0
	if joined < 1000:
		print("\nFAIL: only %d instances joined — too few to conclude anything" % joined)
		fail += 1
	if transposed > 0:
		print("\nFAIL: %d placements are the TRANSPOSE of the packaged rotation." % transposed
			+ " That is the inverse rotation: right spot, wrong facing.")
		fail += 1
	if other > joined * 0.01:
		print("\nFAIL: %d placements differ in some other way" % other)
		fail += 1
	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)


# Position rounded to a millimetre, as a join key. Both pipelines compose the
# same floats in the same order, so this is exact in practice — and matching on
# position is what lets the comparison ignore ordering entirely.
static func _pkey(x, y, z) -> String:
	return "%.3f,%.3f,%.3f" % [float(x), float(y), float(z)]


static func _same(m: Array, t: Array, transpose: bool) -> bool:
	for r in range(3):
		for c in range(3):
			var mine := float(m[r * 3 + c])
			var them := float(t[(c * 3 + r) if transpose else (r * 3 + c)])
			if absf(mine - them) > EPS:
				return false
	return true


static func _fmt(v: Array) -> String:
	var s: Array = []
	for i in range(9):
		s.append("%.2f" % float(v[i]))
	return "[" + ",".join(PackedStringArray(s)) + "]"
