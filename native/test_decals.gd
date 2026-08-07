extends SceneTree

# Does the GDScript TerrainDecals reader agree with bf6_decals.py?
#
# The Python is the reference here for the same reason it was for the walk: it
# has been run against all 23 dumped resources and its three corrections to the
# Frostbite reference were each found by a map that parsed cleanly until it did
# not. A port that agrees on record count, triangle count and the FirstIndex
# chain has reproduced those corrections; one that agrees on record count alone
# has not.
#
#   godot --headless --path <proj> --script test_decals.gd -- [level] [ref.json]
#
# `ref.json` is what tools/dump_decals_ref.py writes. Without it this still runs
# and reports, it just cannot compare.

const BF6Source := preload("res://bf6_source.gd")
const BF6Decals := preload("res://bf6_decals.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var ref := ""
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			ref = s

	var t0 := Time.get_ticks_msec()
	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL: mount — %s" % src.error)
		quit(1); return
	print("mounted in %.1f s, %d res" % [(Time.get_ticks_msec() - t0) / 1000.0,
		src.res.size()])

	var name := BF6Decals.find_res(src, level)
	if name == "":
		print("FAIL: no TerrainDecals resource in the mount for %s" % level)
		quit(1); return
	print("resource: %s" % name)
	var raw := src.get_res(name)
	if raw.is_empty():
		print("FAIL: cannot read %s — %s" % [name, src.error])
		quit(1); return
	print("           %d bytes" % raw.size())

	var t1 := Time.get_ticks_msec()
	var td = BF6Decals.new()
	var ok: bool = td.parse(raw)
	var ms := Time.get_ticks_msec() - t1
	var st: Dictionary = td.stats()
	print("parse: %s in %d ms" % ["ok" if ok else "FAILED (%s)" % td.error, ms])
	for k in ["records", "declared", "slots", "triangles", "chain_ok",
			"anchor_ok", "vb_from_anchor", "truncated_at", "vb_start", "vb_size"]:
		print("   %-16s %s" % [k, st[k]])
	if not ok:
		quit(1); return

	# EVERY RECORD'S VERTEX COUNT AGAINST ITS TRIANGLE COUNT. The Python's own
	# measurement is that all of Dumbo's records have exactly tri_count*3
	# vertices — there is no index buffer to reconstruct — so a record that
	# disagrees means the VB start is wrong, and a wrong VB start still produces
	# plausible-looking floats.
	var exact := 0
	var short := 0
	var props := 0
	var with_cv := 0
	var with_op := 0
	var inside := 0
	var sampled := 0
	for r in td.records:
		var rec: Dictionary = r
		var vs := td.vertices(rec)
		var n := vs.size() / 4
		if n == int(rec["tri_count"]) * 3:
			exact += 1
		else:
			short += 1
		var pr: Dictionary = rec["props"]
		if not pr.is_empty():
			props += 1
		if pr.has(BF6Decals.SLOT_CV):
			with_cv += 1
		if pr.has(BF6Decals.SLOT_OP):
			with_op += 1
		# Vertices inside their own record AABB — the Python's 66% figure over
		# all maps, and the one number that says the VB is being read at the
		# right place rather than merely at a consistent one.
		var lo: Vector3 = rec["aabb_min"]
		var hi: Vector3 = rec["aabb_max"]
		for i in range(0, mini(vs.size(), 40), 4):
			sampled += 1
			var x := vs[i]
			var z := vs[i + 1]
			if x >= lo.x - 1.0 and x <= hi.x + 1.0 and z >= lo.z - 1.0 \
					and z <= hi.z + 1.0:
				inside += 1

	print("\nrecords with exactly tri_count*3 vertices: %d of %d (%d short)"
		% [exact, td.records.size(), short])
	print("records carrying properties:              %d  (cv %d, op %d)"
		% [props, with_cv, with_op])
	print("sampled vertices inside their own AABB:   %d of %d (%.0f%%)"
		% [inside, sampled, 100.0 * inside / maxi(sampled, 1)])

	var fail := 0
	if ref != "" and FileAccess.file_exists(ref):
		var d = JSON.parse_string(FileAccess.get_file_as_string(ref))
		if d is Dictionary:
			print("\nagainst %s:" % ref)
			for k in ["records", "triangles", "slots", "vb_start", "vb_size"]:
				if not (d as Dictionary).has(k):
					continue
				var want = (d as Dictionary)[k]
				var got = st[k]
				var same: bool = int(want) == int(got)
				if not same:
					fail += 1
				print("   %-10s ours %-10s python %-10s %s"
					% [k, got, want, "" if same else "  <-- DIFFERS"])
			# The chain itself, record by record: a total that matches while the
			# per-record split differs means both readers found the same bytes by
			# different routes, and only one of them will keep working.
			var pf = (d as Dictionary).get("first_index")
			if pf is Array:
				var bad := 0
				var n: int = mini((pf as Array).size(), td.records.size())
				for i in range(n):
					if int((pf as Array)[i]) != int((td.records[i] as Dictionary)["first_index"]):
						bad += 1
				print("   first_index mismatches: %d of %d compared" % [bad, n])
				if bad > 0:
					fail += 1
	else:
		print("\n(no reference json given — nothing to compare against)")

	print("\n%s" % ("PASS" if fail == 0 else "FAIL (%d difference(s))" % fail))
	quit(0 if fail == 0 else 1)
