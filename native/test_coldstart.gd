extends SceneTree

# A map's placements, from a cold start, with nothing but the game installed.
#
# Every other test here runs against caches something earlier built. This one
# deletes them first, so the number it reports is what a user gets on the very
# first open after installing the plugin: no dump, no download, no host, no
# prebuilt index, nothing but the files EA put on their disk.
#
# Then it runs the SAME work again to report the warm number, because the two
# are different products and quoting either alone is misleading — a cold start
# is what someone waits through once, a warm one is what they wait through every
# time after.
#
#   godot --headless --path <proj> --script test_coldstart.gd -- <level> [game] [--keep-cache]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Walk := preload("res://bf6_walk.gd")


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var keep := false
	var pos: Array = []
	for a in args:
		if str(a) == "--keep-cache":
			keep = true
		elif str(a) != "":
			pos.append(str(a))
	var level := str(pos[0]) if pos.size() > 0 else "mp_dumbo"
	var game := str(pos[1]) if pos.size() > 1 else ""

	if not keep:
		var n := _purge_caches()
		print("purged %d cache file(s) from user:// — this is a COLD start\n" % n)

	var cold := _run(level, game, "COLD")
	print("")
	var warm := _run(level, game, "WARM")

	print("\n%-26s %10s %10s" % ["stage", "cold", "warm"])
	print("%s" % "-".repeat(48))
	var total_c := 0
	var total_w := 0
	for k in ["open the install", "mount", "type layouts", "partition index",
			"placement walk"]:
		var c: int = int(cold.get(k, 0))
		var w: int = int(warm.get(k, 0))
		total_c += c
		total_w += w
		print("%-26s %9.1fs %9.1fs" % [k, c / 1000.0, w / 1000.0])
	print("%s" % "-".repeat(48))
	print("%-26s %9.1fs %9.1fs" % ["TOTAL", total_c / 1000.0, total_w / 1000.0])
	print("\n%d placements, %d distinct meshes" % [int(cold.get("rows", 0)),
		int(cold.get("meshes", 0))])
	var ct: Dictionary = cold.get("tally", {})
	var wt: Dictionary = warm.get("tally", {})
	var bad := 0
	for k in ct:
		if int(wt.get(k, 0)) != int(ct[k]):
			if bad < 5:
				print("   %s: cold %d, warm %d" % [k, int(ct[k]), int(wt.get(k, 0))])
			bad += 1
	for k in wt:
		if not ct.has(k):
			if bad < 5:
				print("   %s: only warm" % k)
			bad += 1
	var dsum: float = absf(float(cold.get("checksum", 0.0))
		- float(warm.get("checksum", 0.0)))
	if int(cold.get("rows", 0)) != int(warm.get("rows", 0)) or bad > 0 or dsum > 1.0:
		print("MISMATCH: rows %d vs %d, %d mesh tallies differ, "
			% [cold.get("rows", 0), warm.get("rows", 0), bad]
			+ "position checksum off by %.3f — the cache is NOT reproducing "
			% dsum + "the cold result")
		quit(1); return
	print("cold and warm agree: same rows, same per-mesh counts, "
		+ "position checksum within %.4f" % dsum)
	quit(0)


# Everything this stack writes under user://. Named by prefix rather than
# deleted wholesale: user:// also holds the editor's own files, and a test that
# clears those would be destroying state it does not own.
func _purge_caches() -> int:
	var d := DirAccess.open("user://")
	if d == null:
		return 0
	var n := 0
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and (f.begins_with("bf6_index_")
				or f.begins_with("bf6_pidx_") or f.begins_with("bf6_walk_")):
			if d.remove(f) == OK:
				print("   removed %s" % f)
				n += 1
		f = d.get_next()
	d.list_dir_end()
	return n


func _run(level: String, game: String, label: String) -> Dictionary:
	var out := {}
	print("--- %s ---" % label)

	var t := Time.get_ticks_msec()
	var src = BF6Source.new()
	if not src.open(game):
		print("FAIL open: %s" % src.error)
		quit(1)
		return out
	out["open the install"] = Time.get_ticks_msec() - t
	print("install  %s" % src.game)

	t = Time.get_ticks_msec()
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error())
		quit(1)
		return out
	out["mount"] = Time.get_ticks_msec() - t
	print("mount    %d ebx, %d res  (%.1f s%s)" % [src.ebx.size(), src.res.size(),
		int(out["mount"]) / 1000.0,
		", from cache" if src.stats.get("from_cache", false) else ""])

	t = Time.get_ticks_msec()
	var types = BF6Types.new()
	var exe := ""
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			exe = c
			break
	if exe == "" or not types.open(exe):
		print("FAIL types: %s" % types.error)
		quit(1)
		return out
	out["type layouts"] = Time.get_ticks_msec() - t
	print("types    %s  (%.1f s)" % [exe.get_file(), int(out["type layouts"]) / 1000.0])

	var w = BF6Walk.new(src, types)
	t = Time.get_ticks_msec()
	var last := [0]
	w.build_catalog(func(done, total, found):
		# One line per 10%, not per batch: a cold index is 223k files and the
		# per-2000 callback buried everything else in the report.
		var pct := int(100.0 * done / maxf(1.0, float(total)))
		if pct >= int(last[0]) + 10:
			last[0] = pct
			print("   partition index %d%%  (%d guids)" % [pct, found]))
	out["partition index"] = Time.get_ticks_msec() - t
	print("index    %d names, %d partition guids  (%.1f s)"
		% [w.by_name.size(), w.gi.size(), int(out["partition index"]) / 1000.0])

	t = Time.get_ticks_msec()
	if not w.run_cached(level):
		print("FAIL walk: %s" % w.stats.get("error", "no rows"))
		quit(1)
		return out
	out["placement walk"] = Time.get_ticks_msec() - t
	out["walk_cached"] = w.stats.get("from_cache", false)
	# A per-mesh tally AND a positional checksum, not just a row count. A cache
	# that dropped every instance of one mesh and gained the same number of
	# another would match on count alone, and "the map is subtly not the map" is
	# the failure mode a cache actually has.
	var meshes := {}
	var sum := 0.0
	for r in w.rows:
		var m := str((r as Dictionary)["mesh"])
		meshes[m] = int(meshes.get(m, 0)) + 1
		var xf = (r as Dictionary)["xf"]
		if xf is Array and (xf as Array).size() >= 4:
			var tr = (xf as Array)[3]
			if tr is Vector3:
				sum += (tr as Vector3).x + (tr as Vector3).y + (tr as Vector3).z
	out["rows"] = w.rows.size()
	out["meshes"] = meshes.size()
	out["tally"] = meshes
	out["checksum"] = sum
	print("walk     %d rows, %d meshes  (%.1f s%s)"
		% [w.rows.size(), meshes.size(), int(out["placement walk"]) / 1000.0,
		   ", from cache" if out.get("walk_cached", false) else ""])
	print("         decoded %d of %d instances (%d skipped by type)"
		% [w.n_instances - w.n_skipped, w.n_instances, w.n_skipped])
	print("         read %d ms, parse %d ms, decode %d ms"
		% [w.t_read / 1000, w.t_parse / 1000, w.t_decode / 1000])
	return out
