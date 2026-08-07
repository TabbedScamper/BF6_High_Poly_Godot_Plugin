extends SceneTree

# Does Godot now read Oodle, and does it read it the SAME WAY Python does?
#
# The second half is the point. A decompressor that returns plausible bytes is
# worthless here — the Python reader has already been proven byte-identical to
# the closed-source dump across 400 chunks and 600 meshsets, so the only
# standard worth holding the shim to is "produces exactly what fb_cas produces".
#
# fb_oodlevector.py writes real compressed blocks out of the game's CAS files
# alongside Python's exact output for each. This decompresses the first and
# compares to the second.
#
#   godot --headless --path <proj> --script test_oodle.gd -- <vectors dir> <game dir>

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var vecdir := str(args[0]) if args.size() > 0 else "res://vectors"
	var game := str(args[1]) if args.size() > 1 else ""

	if not ClassDB.class_exists("BF6Oodle"):
		print("FAIL: BF6Oodle is not registered — the extension did not load")
		quit(1); return
	print("BF6Oodle is registered")

	var o = ClassDB.instantiate("BF6Oodle")
	if o == null:
		print("FAIL: could not instantiate BF6Oodle")
		quit(1); return

	if game == "":
		print("FAIL: no game directory given")
		quit(1); return
	if not o.open(game):
		print("FAIL: open(%s) -> %s" % [game, o.last_error()])
		quit(1); return
	print("loaded oo2core from the game install")

	var meta_txt := FileAccess.get_file_as_string(vecdir.path_join("vectors.json"))
	var meta = JSON.parse_string(meta_txt)
	if meta == null or not meta.has("vectors"):
		print("FAIL: no vectors.json in %s" % vecdir)
		quit(1); return

	var ok := 0
	var bad := 0
	var bytes := 0
	for v in meta["vectors"]:
		var i: int = int(v["index"])
		var src := FileAccess.get_file_as_bytes(vecdir.path_join("vec%d.in" % i))
		var want := FileAccess.get_file_as_bytes(vecdir.path_join("vec%d.out" % i))
		if src.is_empty() or want.is_empty():
			print("  vec%d: missing files" % i)
			bad += 1
			continue
		var got: PackedByteArray = o.decompress(src, want.size())
		if got.size() != want.size():
			print("  vec%d: FAIL size %d, expected %d" % [i, got.size(), want.size()])
			bad += 1
			continue
		if got != want:
			var first := -1
			for k in range(got.size()):
				if got[k] != want[k]:
					first = k
					break
			print("  vec%d: FAIL bytes differ at %d" % [i, first])
			bad += 1
			continue
		ok += 1
		bytes += got.size()
		print("  vec%d: %d -> %d bytes, identical to Python" % [i, src.size(), got.size()])

	print("\n%d identical, %d wrong, %d bytes verified" % [ok, bad, bytes])

	# A decompressor that cannot fail is a decompressor that is lying. Garbage
	# in must come back empty, not as a buffer of plausible-looking noise.
	var junk := PackedByteArray()
	junk.resize(64)
	for k in range(64):
		junk[k] = k * 7
	var j: PackedByteArray = o.decompress(junk, 4096)
	print("garbage input -> %d bytes (0 is correct)" % j.size())
	if j.size() != 0:
		bad += 1

	if bad == 0 and ok > 0:
		print("\nGodot reads Oodle, and reads it exactly as Python does.")
		quit(0)
	else:
		quit(1)
