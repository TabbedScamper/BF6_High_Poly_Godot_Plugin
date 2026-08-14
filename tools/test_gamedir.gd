@tool
extends SceneTree
# The registry-based Steam root and the autodetect that rides on it,
# against this machine's real Steam and real install.
#
# NOW ALSO PRINTS EVERY SOURCE SEPARATELY. The gate reports one word, detected
# or not, and that word was wrong for a user whose EA App install sat on I: -
# invisible to the candidate list and to Steam's library file, so the panel
# gated itself off repeatedly while the reader underneath was mounting the game
# happily. A machine that fails should be able to say WHICH lookup came back
# empty instead of leaving it to be guessed from a one line warning.
#
# saved() is "" outside the editor by design, so a headless run always exercises
# the SEARCH rather than the remembered answer, which is the half that broke.
func _init() -> void:
	print("")
	print("drives seen:  %s" % ", ".join(HighpolyGameDir._drives()))
	var ea: Array = HighpolyGameDir._ea_registry()
	print("EA registry:  %s" % ("(nothing)" if ea.is_empty() else ", ".join(ea)))
	var root := HighpolyGameDir._steam_root()
	print("steam root:   '%s'" % root)
	# THE LIST ITSELF, not just its length. This is what to paste at a user who
	# says the plugin cannot find their game: if their folder is not in it, the
	# sweep needs another parent, and if it is in it then the fault is verify()
	# rather than discovery.
	print("drive sweep would probe:")
	for d in HighpolyGameDir._drives():
		for parent in HighpolyGameDir.DRIVE_PARENTS:
			var p: String = d.path_join(parent).path_join("Battlefield 6") \
				if parent != "" else d.path_join("Battlefield 6")
			print("   %s" % p)
	print("")

	var t0 := Time.get_ticks_msec()
	var found := HighpolyGameDir.autodetect()
	var ms := Time.get_ticks_msec() - t0
	print("autodetect:   '%s'  (%d ms)" % [found, ms])
	var v: Dictionary = HighpolyGameDir.verify(found)
	print("verified:     %s (%s)" % [str(v["ok"]), str(v["why"])])

	var fails := 0
	if root == "":
		print("FAIL registry found no Steam root on a machine that has Steam")
		fails += 1
	if found == "" or not bool(v["ok"]):
		print("FAIL autodetect no longer finds the install")
		fails += 1
	# THE SWEEP MUST NOT COST A USER ANYTHING NOTICEABLE. It runs on every panel
	# build, and a machine with several drives and a sleeping external disk is
	# exactly where a per-drive probe could stall. If this ever trips, cache the
	# answer rather than dropping the sweep: it is the only thing that finds an
	# EA App install.
	if ms > 2000:
		print("FAIL autodetect took %d ms, which a user will feel" % ms)
		fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
