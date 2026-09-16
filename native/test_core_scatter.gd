extends SceneTree

# First dependency-sized core -> Godot cut.
#
#   godot --headless --path <test project> --script test_core_scatter.gd --
#         <Steam BF6 root> [level]
#
# The fake-level control is part of the result, not an optional negative test:
# widening to another mounted level's one scatter database can return a
# plausible but confidently wrong catalogue.

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_core_scatter.gd -- <Steam BF6 root> [level]")
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
		print("FAIL open: %s" % (core.last_error() if core != null else "null instance"))
		quit(1)
		return
	var parsed = JSON.parse_string(str(core.scatter(level)))
	var control = JSON.parse_string(str(core.scatter("MP_NotARealLevel")))
	if not parsed is Dictionary or not control is Dictionary:
		print("FAIL: native JSON envelope did not parse")
		quit(1)
		return
	var rows: Array = parsed.get("rows", [])
	var control_rows: Array = control.get("rows", [])
	var resolved := 0
	for row in rows:
		if str((row as Dictionary).get("mesh", "")) != "":
			resolved += 1
	print("ABI %d" % int(core.abi_version()))
	print("REAL %s: %d row(s), %d resolved" % [level, rows.size(), resolved])
	print("CONTROL fake level: %d row(s)" % control_rows.size())
	var ok: bool = bool(parsed.get("ok", false)) and rows.size() > 0 \
		and resolved == rows.size() and control_rows.is_empty()
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)
