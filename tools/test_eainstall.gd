@tool
extends SceneTree
# THE EA APP INSTALL, MEASURED HERE INSTEAD OF ON SOMEONE ELSE'S MACHINE.
#
# Everything about this fault has been inferred from user bundles. With an EA
# App install on this machine, all of it becomes a local measurement, and three
# questions get answered in one run:
#
#   1. Is the EA build's SP type table encrypted, as one user's is (8.00 bits
#      per byte against our Steam copy's 3.38)? If yes it is a property of the
#      build and not of their machine, and no reader will ever read types from
#      it. If no, that user has something else wrong and the encryption story
#      dies here.
#   2. Is the MP executable readable on this build? That is the escape route -
#      an unreadable SP database does not matter if its twin works.
#   3. Does a map actually come back? The v2.6.11 cache fix has never once run
#      against a genuinely encrypted install. It was verified by poisoning the
#      caches on a healthy install, which is a faithful simulation and not the
#      real thing.
#
# Pins the install through HighpolyGameDir.save() so the Steam copy is left
# alone, and PUTS IT BACK at the end - detection prefers the richest install and
# with two complete ones present it would otherwise be a coin toss afterwards.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_eainstall.gd -- "D:/EA/Battlefield 6" MP_Badlands

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("give me the EA install folder, the one that CONTAINS Data")
		quit(1)
		return
	var game := str(args[0]).replace("\\", "/").rstrip("/")
	var map := str(args[1]) if args.size() > 1 else "MP_Badlands"

	var v: Dictionary = HighpolyGameDir.verify(game)
	print("install: %s" % game)
	print("  verified=%s  %s" % [str(bool(v["ok"])), str(v["why"])])
	if not bool(v["ok"]):
		quit(1)
		return
	print("  levels carried: %d" % HighpolyGameDir.level_count(game))

	# --- 1 and 2: what do the two executables look like on THIS build --------
	print("")
	print("EXECUTABLES")
	var readable := ""
	for c in BF6Types.exe_candidates(game):
		if not FileAccess.file_exists(c):
			print("  %-12s absent" % c.get_file())
			continue
		var t := BF6Types.new()
		var ok := t.open(c)
		if not ok:
			print("  %-40s could not open: %s" % [c, t.error])
			continue
		var e: Dictionary = t.ti_entropy()
		var enc: bool = float(e.get("bits", 0.0)) > 7.5
		print("  %s" % c)
		print("      %d bytes, typeinfo %d, entropy %.2f bits, %.1f%% zeros  -> %s"
			% [t.file_size, t.ti_size, float(e.get("bits", -1)),
				float(e.get("zeros", -1)),
				"ENCRYPTED, unreadable" if enc else "plain, readable"])
		if not enc and readable == "":
			readable = c

	# --- 3: does the map come back -----------------------------------------
	print("")
	print("READING %s FROM IT" % map)
	var was := HighpolyGameDir.saved()
	HighpolyGameDir.save(game)
	var gs = GS.new()
	var opened: bool = gs.open_map(map, "", Callable(), {"placements": true})
	print("  open_map returned %s" % str(opened))
	if gs.walk != null:
		print("  %d row(s) from %s%s"
			% [gs.walk.rows.size(), str(gs._exe_used),
				"   (RETRY FIRED)" if gs._types_retried else ""])
		print("  %d instance(s) seen, %d skipped, %d type(s) unresolved"
			% [int(gs.walk.stats.get("instances", 0)),
				int(gs.walk.stats.get("instances_skipped", 0)),
				int(gs.walk.stats.get("types_unresolved", 0))])
	if not opened:
		print("  error: %s" % str(gs.error))
	HighpolyGameDir.save(was)          # leave detection as we found it
	print("  (restored the saved install path to '%s')" % was)

	print("")
	if gs.walk != null and gs.walk.rows.size() > 0:
		print("VERDICT: an EA App install READS, %d placements."
			% gs.walk.rows.size())
		if gs._types_retried:
			print("It needed the retry, so the 2.6.11 fix is what carried it,")
			print("and this is the first time that has run for real.")
	else:
		print("VERDICT: still empty here, on an install I can now instrument")
		print("directly. No more guessing from bundles.")
	quit(0)
