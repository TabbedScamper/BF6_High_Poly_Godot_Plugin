@tool
extends SceneTree
# Environment decal volumes (task #52), against the real install.
#
# MP_Capstone is the specimen: the dump probe counted 88 EnvironmentDecalVolumeData
# under the level and 25 distinct templates, all of whose state keys were
# verified to sit in the depots of their mounting scopes. This asks the REAL
# reader for the same map and prints what the placer needs to know:
#   - how many collected, how many resolve to a sheet (the drop counts)
#   - per-template tally
#   - the basis geometry of known volumes, which is what settles the two
#     authored conventions (projection axis, unit-cube vs half-extent scale)

func _fmt_axis(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f) len %.2f" % [v.x, v.y, v.z, v.length()]


func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Capstone"):
		print("no source: ", gs.error)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var md: Dictionary = gs.map_data("user://edvtest", {"edv": true})
	var ms := Time.get_ticks_msec() - t0
	var recs: Array = md.get("edv", [])
	print("map_data in %d ms: %d decal volume records  [walk collects 300 on this map]"
		% [ms, recs.size()])
	var fails := 0
	if recs.size() < 200:
		print("FAIL too few records (the walk collects 300; graffiti alone is 30)")
		fails += 1
	var kinds := {}
	for r in recs:
		var kk := str((r as Dictionary).get("kind", "?"))
		kinds[kk] = int(kinds.get(kk, 0)) + 1
	print("kinds: %s" % str(kinds))
	# per-template tally, and the known specimens' geometry
	var tally := {}
	var shown := {}
	for r in recs:
		var rec: Dictionary = r
		var tpl := str(rec.get("tpl", ""))
		tally[tpl] = int(tally.get(tpl, 0)) + 1
		var want := tpl.begins_with("edv_cas_graffitischoolhouse") \
			or tpl.begins_with("edv_gobolight") \
			or tpl == "decalvol_sootnoisy_triprojected_c"
		if want and int(shown.get(tpl, 0)) < 2:
			shown[tpl] = int(shown.get(tpl, 0)) + 1
			var b: Array = rec.get("xf", [])
			print("  %s @ (%.1f, %.1f, %.1f)" % [tpl,
				(b[3] as Vector3).x, (b[3] as Vector3).y, (b[3] as Vector3).z])
			print("    right %s" % _fmt_axis(b[0] as Vector3))
			print("    up    %s" % _fmt_axis(b[1] as Vector3))
			print("    fwd   %s" % _fmt_axis(b[2] as Vector3))
			print("    ca=%s nrm=%s alpha=%.2f cull=%.1f"
				% [str(rec.get("ca", "")).substr(0, 8),
					str(rec.get("nrm", "")).substr(0, 8),
					float(rec.get("alpha", 1.0)), float(rec.get("cull", 0.0))])
	var keys := tally.keys()
	keys.sort_custom(func(a, b): return int(tally[a]) > int(tally[b]))
	print("templates (%d distinct)  [dump probe: 25]:" % keys.size())
	for k in keys:
		print("  x%-3d %s" % [int(tally[k]), k])
	if keys.size() < 10:
		print("FAIL too few distinct templates resolved")
		fails += 1
	# every record must carry a colour sheet guid and a sane transform
	var bad := 0
	for r in recs:
		var rec: Dictionary = r
		var b: Array = rec.get("xf", [])
		if str(rec.get("ca", "")) == "" or b.size() < 4:
			bad += 1
			continue
		var m := 0.0
		for i in range(3):
			m = maxf(m, (b[i] as Vector3).length())
		if m < 0.05 or m > 100.0:
			bad += 1
	if bad > 0:
		print("FAIL %d records with no sheet or degenerate extents" % bad)
		fails += 1
	# and the sheet fetch the builder does must produce a real texture
	var got := 0
	var tried := {}
	for r in recs:
		var ca := str((r as Dictionary).get("ca", ""))
		if ca == "" or tried.has(ca):
			continue
		tried[ca] = true
		if gs.decal_sheet(ca) != null:
			got += 1
		if tried.size() >= 8:
			break
	print("sheet fetch: %d of %d distinct sheets decoded" % [got, tried.size()])
	if got == 0:
		print("FAIL no decal sheet decodes")
		fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
