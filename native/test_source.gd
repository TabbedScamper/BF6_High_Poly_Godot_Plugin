extends SceneTree

# Mount a level in Godot and check it against the Python reader.
#
# Three claims, and they fail independently:
#
#   INDEX   the mount finds the same TOCs and the same number of names.
#   LOOKUP  a name resolves to the same asset, not merely to something.
#   BYTES   the bytes are identical.
#
# The vectors carry Python's answer for a set of real names, including chunks
# from BOTH sources (the loose map and bundle-local), because those take
# different code paths and only one of them is exercised by a casual sample.
#
#   godot --headless --path <proj> --script test_source.gd -- <vec dir> <game> <level>

const BF6Source := preload("res://bf6_source.gd")

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() > 0 else "res://srcvectors"
	var game := str(args[1]) if args.size() > 1 else ""
	var level := str(args[2]) if args.size() > 2 else "mp_dumbo"

	var src = BF6Source.new()
	if not src.open(game):
		print("FAIL open: %s" % src.error)
		quit(1); return
	print("game: %s" % src.game)

	var t0 := Time.get_ticks_msec()
	if not src.mount(level):
		print("FAIL mount: %s" % src.error)
		quit(1); return
	print("mounted %s in %d ms" % [level, Time.get_ticks_msec() - t0])
	for k in ["tocs", "bundles_opened", "bundles_failed", "ebx", "res",
			"chunks_loose", "chunks_bundle_local", "size_disagreements"]:
		print("   %-22s %s" % [k, src.stats.get(k)])

	var meta = JSON.parse_string(
			FileAccess.get_file_as_string(dir.path_join("srcvectors.json")))
	if meta == null:
		print("FAIL: no srcvectors.json in %s" % dir)
		quit(1); return

	# --- index comparison ---
	var py = meta["stats"]
	var idx_ok := true
	for k in ["tocs", "ebx", "res", "chunks_loose", "chunks_bundle_local"]:
		var mine := int(src.stats.get(k, -1))
		var theirs := int(py.get(k, -2))
		var same := mine == theirs
		idx_ok = idx_ok and same
		print("   index %-22s godot %-8d python %-8d %s"
				% [k, mine, theirs, "" if same else "<-- DIFFERS"])

	# --- byte comparison ---
	var ok := 0
	var bad := 0
	var bytes := 0
	var by_kind := {}
	for v in meta["vectors"]:
		var kind := str(v["kind"])
		var name := str(v["name"])
		var want := FileAccess.get_file_as_bytes(
				dir.path_join("src%d.out" % int(v["index"])))
		var got: PackedByteArray
		match kind:
			"ebx": got = src.get_ebx(name)
			"res": got = src.get_res(name)
			_: got = src.get_chunk(name)
		if got.size() == want.size() and got == want:
			ok += 1
			bytes += got.size()
			by_kind[kind] = int(by_kind.get(kind, 0)) + 1
		else:
			bad += 1
			print("   %s %s: FAIL got %d want %d  %s"
					% [kind, name.substr(max(0, name.length() - 44)),
					   got.size(), want.size(), src.error])

	print("\n   identical %d, wrong %d, %d bytes verified" % [ok, bad, bytes])
	print("   by kind: %s" % by_kind)

	var missing: PackedByteArray = src.get_res("this/asset/does/not/exist")
	print("   missing name -> %d bytes (%s)" % [missing.size(), src.error])
	if not missing.is_empty():
		bad += 1

	if bad == 0 and ok > 0 and idx_ok:
		print("\nGodot mounts the level and reads it exactly as Python does.")
		quit(0)
	else:
		quit(1)
