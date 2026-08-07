extends SceneTree

# Does the GDScript CAS reader produce what fb_cas.py produces?
#
# fb_oodlevector proved the decompressor in isolation. This tests the layer that
# decides WHAT to hand it: the block header parse, the guard nibble, the
# single-block fast path, the multi-block walk, and the raw segment-0 case.
#
# The vectors deliberately mix all three shapes. A reader that only meets
# single compressed blocks looks flawless until it meets a multi-block span,
# and then reads the first block and silently drops the rest.
#
#   godot --headless --path <proj> --script test_cas.gd -- <vector dir> <game dir>

const BF6Cas := preload("res://bf6_cas.gd")

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() > 0 else "res://casvectors"
	var game := str(args[1]) if args.size() > 1 else ""

	var cas = BF6Cas.new()
	if not cas.open(game):
		print("FAIL: %s" % cas.last_error())
		quit(1); return
	print("CAS reader ready (oodle from the game install)")

	var meta = JSON.parse_string(
			FileAccess.get_file_as_string(dir.path_join("casvectors.json")))
	if meta == null or not meta.has("vectors"):
		print("FAIL: no casvectors.json in %s" % dir)
		quit(1); return

	var ok := 0
	var bad := 0
	var bytes := 0
	var by_kind := {}
	for v in meta["vectors"]:
		var i: int = int(v["index"])
		var kind := str(v["kind"])
		var want := FileAccess.get_file_as_bytes(dir.path_join("cas%d.out" % i))
		var got: PackedByteArray = cas.read(str(v["path"]), int(v["offset"]),
				int(v["size"]), bool(v["allow_raw"]))
		var good := got.size() == want.size() and got == want
		if good:
			ok += 1
			bytes += got.size()
			by_kind[kind] = int(by_kind.get(kind, 0)) + 1
		else:
			bad += 1
			print("  cas%d (%s): FAIL got %d, expected %d  %s"
					% [i, kind, got.size(), want.size(), cas.last_error()])
	print("  identical: %d   wrong: %d   %d bytes verified" % [ok, bad, bytes])
	print("  by kind: %s" % by_kind)

	# A bad offset must fail loudly, not return something shaped like data.
	var junk: PackedByteArray = cas.read(
			str(meta["vectors"][0]["path"]), 3, 64, false)
	print("  deliberately bad read -> %d bytes (%s)"
			% [junk.size(), cas.last_error()])
	if not junk.is_empty():
		bad += 1

	if bad == 0 and ok > 0:
		print("\nGDScript reads the game's CAS exactly as Python does.")
		quit(0)
	else:
		quit(1)
