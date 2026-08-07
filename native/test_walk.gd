extends SceneTree

# Does the GDScript placement walk agree with the Python one?
#
# This is the claim that matters for #58, and it is not "it produced some rows".
# walk_level.py is the reference: it is what the packaged Dumbo build is made
# of, so any disagreement here is a map that would come out different from the
# one users see today. Compared three ways, because they fail independently:
#
#   COUNT     the same number of placements.
#   MESHES    the same set of mesh paths, with the same instance count each.
#             (A walk can hit the right total while placing the wrong things.)
#   TRANSFORM the same matrix for the same placement, within float tolerance.
#             (Both of the above can pass on a map transposed into nonsense —
#             that exact bug shipped once, from sorting the LinearTransform
#             member hashes numerically.)
#
# The reference JSON comes from:
#   python tools/walk_level.py --game <level_rel> ref.json
#
#   godot --headless --path <proj> --script test_walk.gd -- <ref.json> <level_rel> [game]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Walk := preload("res://bf6_walk.gd")

# Positions are metres and can reach ~4 km from the origin, where a float32 step
# is ~0.25 mm; basis entries are unit-scale. Compared with a tolerance derived
# from that rather than a round number, so a real disagreement cannot hide under
# a generous epsilon.
const POS_TOL := 0.01
const BASIS_TOL := 1e-4


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: test_walk.gd -- <ref.json> <level_rel> [game_dir]")
		quit(2); return
	# Flags scanned rather than positional. An empty "" placeholder for the game
	# directory does not survive the shell, so a trailing flag slid into the
	# game-dir slot and the run died on "no Data/layout.toc under --verify-skip".
	var verify_skip := false
	var pos: Array = []
	for a in args:
		if str(a) == "--verify-skip":
			verify_skip = true
		elif str(a) != "":
			pos.append(str(a))
	if pos.size() < 2:
		print("usage: test_walk.gd -- <ref.json> <level_rel> [game_dir] [--verify-skip]")
		quit(2); return
	var ref_path := str(pos[0])
	var level_rel := str(pos[1])
	var game := str(pos[2]) if pos.size() > 2 else ""
	var level := level_rel.replace("\\", "/").rstrip("/").get_file()

	var t0 := Time.get_ticks_msec()
	var src = BF6Source.new()
	if not src.open(game):
		print("FAIL open: %s" % src.error)
		quit(1); return
	print("game   %s" % src.game)
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error())
		quit(1); return
	print("mount  %d ebx, %d res  (%d ms%s)" % [src.ebx.size(), src.res.size(),
		int(src.stats.get("ms", 0)),
		", from cache" if src.stats.get("from_cache", false) else ""])

	# The type layouts come out of the game's own executable, so this too needs
	# nothing but the install.
	var types = BF6Types.new()
	var exe := ""
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			exe = c
			break
	if exe == "" or not types.open(exe):
		print("FAIL types: %s (exe %s)" % [types.error, exe])
		quit(1); return
	print("types  %s (%d ms)" % [exe.get_file(), Time.get_ticks_msec() - t0])

	var w = BF6Walk.new(src, types)
	var tc := Time.get_ticks_msec()
	w.build_catalog(func(done, total, found):
		print("   partition index %d/%d, %d guid(s)" % [done, total, found]))
	print("index  %d names, %d partition guids  (%d ms)"
		% [w.by_name.size(), w.gi.size(), Time.get_ticks_msec() - tc])

	var tw := Time.get_ticks_msec()
	var ok: bool = w.run(level_rel)
	var walk_ms := Time.get_ticks_msec() - tw
	print("walk   %d rows in %d ms   %s" % [w.rows.size(), walk_ms, w.stats])
	if not ok:
		print("FAIL walk produced nothing")
		quit(1); return

	# ---- compare -----------------------------------------------------------
	var f := FileAccess.open(ref_path, FileAccess.READ)
	if f == null:
		print("no reference at %s — walk ran but is UNVERIFIED" % ref_path)
		quit(1); return
	var ref = JSON.parse_string(f.get_as_text())
	f.close()
	var ref_rows: Array = []
	if ref is Dictionary and (ref as Dictionary).has("rows"):
		ref_rows = (ref as Dictionary)["rows"]
	elif ref is Array:
		ref_rows = ref
	else:
		print("FAIL reference json has neither 'rows' nor a top-level array")
		quit(1); return

	print("\nCOUNT   ours %d   python %d   %s"
		% [w.rows.size(), ref_rows.size(),
		   "MATCH" if w.rows.size() == ref_rows.size() else "DIFFER"])

	var ours_by := _tally(w.rows)
	var ref_by := _tally(ref_rows)
	var only_ours: Array = []
	var only_ref: Array = []
	var diff_count: Array = []
	for k in ours_by:
		if not ref_by.has(k):
			only_ours.append(k)
		elif int(ours_by[k]) != int(ref_by[k]):
			diff_count.append(k)
	for k in ref_by:
		if not ours_by.has(k):
			only_ref.append(k)
	print("MESHES  %d distinct ours, %d python;  %d only ours, %d only python, %d differing counts"
		% [ours_by.size(), ref_by.size(), only_ours.size(), only_ref.size(),
		   diff_count.size()])
	for k in only_ref.slice(0, 8):
		print("   python only: %-60s x%d" % [str(k).left(60), int(ref_by[k])])
	for k in only_ours.slice(0, 8):
		print("   ours only  : %-60s x%d" % [str(k).left(60), int(ours_by[k])])
	for k in diff_count.slice(0, 8):
		print("   count      : %-52s ours %d python %d"
			% [str(k).left(52), int(ours_by[k]), int(ref_by[k])])

	# TRANSFORMS. Matched on (mesh, rounded translation) rather than on order:
	# the two walkers visit the same graph but need not append in the same
	# sequence, and comparing index-to-index would report every row wrong the
	# moment one of them reordered a sibling list.
	# A LIST PER KEY, not one row. A mesh can be placed twice at the same point
	# with different rotations — mirrored pairs and stacked fence sections both
	# do it — and keeping only the last would compare our row against a sibling's
	# basis and report a difference that is not one.
	var ref_ix := {}
	for r in ref_rows:
		if r is Dictionary:
			var k := _key_of(r)
			if not ref_ix.has(k):
				ref_ix[k] = []
			(ref_ix[k] as Array).append(r)
	var matched := 0
	var pos_bad := 0
	var basis_bad := 0
	var unmatched := 0
	var examples: Array = []
	# Leftovers go through a second pass, so a row is only called UNMATCHED once
	# nothing of the same mesh is left anywhere near it. The position key is a
	# rounded float, and at 48,126 rows a handful landing either side of a
	# rounding boundary is expected — reporting those as missing placements
	# would be a false alarm about the one thing this test exists to check.
	var leftovers: Array = []
	var by_mesh := {}
	for r in ref_rows:
		if r is Dictionary:
			var mm := str((r as Dictionary).get("mesh", ""))
			if not by_mesh.has(mm):
				by_mesh[mm] = []
			(by_mesh[mm] as Array).append(r)

	for r in w.rows:
		var k := _key_of(r)
		var cands = ref_ix.get(k)
		if cands == null or (cands as Array).is_empty():
			leftovers.append(r)
			continue
		# Best of the candidates sharing this position, then consumed, so two of
		# ours cannot both claim the same reference row.
		var best := -1
		var best_d: Array = [INF, INF]
		for ci in range((cands as Array).size()):
			var d := _worst(r["xf"], ((cands as Array)[ci] as Dictionary)["xf"])
			if float(d[1]) < float(best_d[1]) or (
					is_equal_approx(float(d[1]), float(best_d[1]))
					and float(d[0]) < float(best_d[0])):
				best_d = d
				best = ci
		if best >= 0:
			(cands as Array).remove_at(best)
		matched += 1
		if float(best_d[0]) > POS_TOL:
			pos_bad += 1
			if examples.size() < 6:
				examples.append("pos %.4f m: %s"
					% [best_d[0], str(r["mesh"]).get_file()])
		if float(best_d[1]) > BASIS_TOL:
			basis_bad += 1
			if examples.size() < 6:
				examples.append("basis %.6f: %s at %s"
					% [best_d[1], str(r["mesh"]).get_file(), _pos_str(r["xf"])])
	# SECOND PASS: nearest same-mesh reference row, whatever the distance, so the
	# report distinguishes "the key rounded differently" from "this placement is
	# somewhere else entirely". Only the leftovers reach here, so the quadratic
	# search costs nothing.
	var near_ok := 0
	for r in leftovers:
		var mm := str(r["mesh"])
		var pool: Array = by_mesh.get(mm, [])
		var best := -1
		var best_pos := INF
		var best_d: Array = [INF, INF]
		for ci in range(pool.size()):
			var d := _worst(r["xf"], (pool[ci] as Dictionary)["xf"])
			if float(d[0]) < best_pos:
				best_pos = float(d[0])
				best_d = d
				best = ci
		if best < 0:
			unmatched += 1
			if examples.size() < 8:
				examples.append("NO reference row for %s at %s"
					% [mm.get_file(), _pos_str(r["xf"])])
			continue
		pool.remove_at(best)
		if float(best_d[0]) <= POS_TOL and float(best_d[1]) <= BASIS_TOL:
			# Same placement; the rounded key simply fell the other side of a
			# boundary. Counted as matched, and reported so the claim is visible.
			matched += 1
			near_ok += 1
		else:
			unmatched += 1
			if examples.size() < 8:
				examples.append("off by %.4f m / %.6f basis: %s at %s"
					% [best_d[0], best_d[1], mm.get_file(), _pos_str(r["xf"])])
	if near_ok > 0:
		print("        %d matched on the second pass (key rounding only, all "
			% near_ok + "within tolerance)")

	print("TRANSFORM matched %d, unmatched %d;  %d past %.3f m, %d past %.6f basis"
		% [matched, unmatched, pos_bad, POS_TOL, basis_bad, BASIS_TOL])
	for e in examples:
		print("   %s" % e)

	# ---- is the type skip actually equivalent? ------------------------------
	# The skip claims an instance whose type declares none of WALK_FIELDS cannot
	# contribute. That is an argument, and arguments about which fields matter
	# are exactly what has gone wrong in this walker before. So it is checked:
	# same map, skipping off, and the two row sets must be identical. Only worth
	# the second 100 s when the fast path has already agreed with Python.
	var skip_ok := true
	if verify_skip:
		var w2 = BF6Walk.new(src, types)
		w2.by_name = w.by_name
		w2.gi = w.gi
		w2.skip_types = false
		var t2 := Time.get_ticks_msec()
		w2.run(level_rel)
		print("\nSKIP    off: %d rows in %d ms (decoded %d instances)"
			% [w2.rows.size(), Time.get_ticks_msec() - t2, w2.n_instances])
		print("        on : %d rows in %d ms (skipped %d of %d)"
			% [w.rows.size(), walk_ms, w.n_skipped, w.n_instances])
		var t2a := _tally(w2.rows)
		skip_ok = w2.rows.size() == w.rows.size() and t2a.size() == ours_by.size()
		if skip_ok:
			for kk in t2a:
				if int(t2a[kk]) != int(ours_by.get(kk, 0)):
					skip_ok = false
					print("        count differs for %s: %d vs %d"
						% [kk, int(t2a[kk]), int(ours_by.get(kk, 0))])
					break
		print("        %s" % ("EQUIVALENT" if skip_ok
			else "NOT EQUIVALENT — the skip is dropping placements"))

	var pass_all: bool = (w.rows.size() == ref_rows.size()
		and only_ours.is_empty() and only_ref.is_empty()
		and diff_count.is_empty() and unmatched == 0
		and pos_bad == 0 and basis_bad == 0 and skip_ok)
	print("\n%s" % ("PASS — the GDScript walk agrees with Python"
		if pass_all else "FAIL — see above"))
	quit(0 if pass_all else 1)


static func _tally(rws: Array) -> Dictionary:
	var out := {}
	for r in rws:
		if r is Dictionary:
			var m := str((r as Dictionary).get("mesh", ""))
			out[m] = int(out.get(m, 0)) + 1
	return out


# Rounded to a millimetre: enough to pair two rows that describe the same
# placement, tight enough that two genuinely different placements of the same
# mesh do not collide.
static func _key_of(r: Dictionary) -> String:
	var t := _trans(r.get("xf"))
	return "%s|%.3f|%.3f|%.3f" % [str(r.get("mesh", "")), t.x, t.y, t.z]


static func _trans(xf) -> Vector3:
	if xf is Array and (xf as Array).size() >= 4:
		return _v((xf as Array)[3])
	return Vector3.ZERO


static func _v(row) -> Vector3:
	if row is Vector3:
		return row
	if row is Array and (row as Array).size() >= 3:
		return Vector3(float(row[0]), float(row[1]), float(row[2]))
	return Vector3.ZERO


static func _pos_str(xf) -> String:
	var t := _trans(xf)
	return "%.1f, %.1f, %.1f" % [t.x, t.y, t.z]


# -> [worst translation error in metres, worst basis component error]
static func _worst(a, b) -> Array:
	var pos := 0.0
	var bas := 0.0
	if not (a is Array) or not (b is Array):
		return [INF, INF]
	for i in range(4):
		if i >= (a as Array).size() or i >= (b as Array).size():
			return [INF, INF]
		var va := _v((a as Array)[i])
		var vb := _v((b as Array)[i])
		var e: float = maxf(maxf(absf(va.x - vb.x), absf(va.y - vb.y)),
			absf(va.z - vb.z))
		if i == 3:
			pos = maxf(pos, e)
		else:
			bas = maxf(bas, e)
	return [pos, bas]
