extends SceneTree

# Production-path proof: GDScript install source + one shared BF6Core + exact
# native zone geometry + exact local-preset exposure. All inputs come from the
# installed Steam game. Nothing is exported or read back from a staged table.


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_live_lighting_zones.gd -- <Steam BF6 root> [level]")
		quit(2)
		return
	var game_dir := str(args[0])
	var level := str(args[1]) if args.size() > 1 else "mp_dumbo"
	var gs := HighpolyGameSource.new()
	var began := Time.get_ticks_msec()
	if not gs.open_map(level, game_dir, Callable(), {"placements": false}):
		print("FAIL open: %s" % gs.error)
		quit(1)
		return
	var opened_ms := Time.get_ticks_msec() - began
	began = Time.get_ticks_msec()
	var scatter := gs.scatter_entries()
	var scatter_ms := Time.get_ticks_msec() - began
	var shared_after_scatter = gs._native_core
	began = Time.get_ticks_msec()
	var rows := gs.lighting_zones()
	var first_ms := Time.get_ticks_msec() - began
	var core = gs._native_core
	began = Time.get_ticks_msec()
	var again := gs.lighting_zones()
	var cached_ms := Time.get_ticks_msec() - began
	var stats: Dictionary = gs._lighting_zones_stats

	var shaped := 0
	var exposed := 0
	for row in rows:
		var r: Dictionary = row
		if r.get("transform") is Transform3D:
			shaped += 1
		if float(r.get("ev", 0.0)) > 0.0 or float(r.get("ev_max", 0.0)) > 0.0:
			exposed += 1
	var same_core := core != null and is_same(shared_after_scatter, core) \
		and is_same(core, gs._native_core)
	var fake = JSON.parse_string(str(core.lighting_zones("mp_this_level_does_not_exist"))) \
		if core != null else {}

	print("REAL production: rows=%d shaped=%d exposed=%d direct=%d omitted=%d" % [
		rows.size(), shaped, exposed, int(stats.get("joined_preset", -1)),
		int(stats.get("omitted_no_preset", -1))])
	print("REAL shared native products: scatter=%d zones=%d" % [scatter.size(), rows.size()])
	print("REAL timing: GDScript open=%d ms native+scatter=%d ms zones=%d ms cached=%d ms" % [
		opened_ms, scatter_ms, first_ms, cached_ms])
	print("CONTROL rotated=%d/%d fake_ok=%s fake_rows=%d shared_core=%s" % [
		int(stats.get("rotated_control_hits", -1)), int(stats.get("shape_links", -1)),
		str(fake.get("ok", true)), (fake.get("rows", []) as Array).size(), str(same_core)])

	var ok := scatter.size() > 0 and rows.size() > 0 and again.size() == rows.size() \
			and shaped == rows.size() and exposed == rows.size() \
			and int(stats.get("total", -1)) >= rows.size() \
			and int(stats.get("rotated_control_hits", -1)) == 0 \
			and same_core and not bool(fake.get("ok", true)) \
			and (fake.get("rows", []) as Array).is_empty()
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)
