extends SceneTree

# Public ABI -> raw GDExtension -> Godot proof for exact local VE zones.
# The result is parsed in memory; no exported intermediate is read or written.

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_core_lighting_zones.gd -- <Steam BF6 root> [level]")
		quit(2)
		return
	var game_dir := str(args[0])
	var level := str(args[1]) if args.size() > 1 else "mp_dumbo"
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered")
		quit(1)
		return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(game_dir):
		print("FAIL open: %s" % (core.last_error() if core != null else "null"))
		quit(1)
		return

	var envelope = JSON.parse_string(str(core.lighting_zones(level)))
	var fake = JSON.parse_string(str(core.lighting_zones("mp_this_level_does_not_exist")))
	if not envelope is Dictionary or not fake is Dictionary:
		print("FAIL: JSON envelope did not parse")
		quit(1)
		return
	var rows: Array = envelope.get("rows", [])
	var stats: Dictionary = envelope.get("stats", {})
	var provenance := 0
	var valid_shapes := 0
	for row in rows:
		var r := row as Dictionary
		if str(r.get("preset", "")) != "" and str(r.get("source", "")) != "":
			provenance += 1
		var kind := int(r.get("kind", -1))
		var half: Array = r.get("half_extents", [])
		var points: Array = r.get("points", [])
		if (kind == 0 and half.size() == 3 and float(half[0]) > 0.0) \
				or (kind == 1 and points.size() >= 3):
			valid_shapes += 1

	print("ABI %d" % int(core.abi_version()))
	print("REAL %s: %d zones, %d provenance, %d valid shapes" % \
			[level, rows.size(), provenance, valid_shapes])
	print("REAL shape links %d; direct joins %d; omitted channel route %d" % [
		int(stats.get("shape_links", 0)), int(stats.get("joined_preset", 0)),
		int(stats.get("omitted_no_preset", 0))])
	print("CONTROL rotated source: %d/%d" % [
		int(stats.get("rotated_control_hits", -1)),
		int(stats.get("shape_links", 0))])
	print("CONTROL fake level: ok=%s rows=%d" % [
		str(fake.get("ok", true)), (fake.get("rows", []) as Array).size()])

	var ok: bool = bool(envelope.get("ok", false)) and rows.size() > 0 \
			and provenance == rows.size() and valid_shapes == rows.size() \
			and int(stats.get("total", -1)) == rows.size() \
			and int(stats.get("joined_preset", -1)) == rows.size() \
			and int(stats.get("target_other", -1)) == 0 \
			and int(stats.get("rotated_control_hits", -1)) \
				< int(stats.get("shape_links", 0)) \
			and not bool(fake.get("ok", true)) \
			and (fake.get("rows", []) as Array).is_empty()
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)
