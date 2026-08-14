@tool
extends SceneTree
# THE RETRY RAN THE GOOD DATABASE AGAINST THE FAILED ONE'S CACHE.
#
# An EA App user's SP executable ships its type table encrypted (8.00 bits/byte
# against our 3.38), so every lookup misses. Their MP executable is plain and
# resolves everything. The retry switches to it and STILL produced nothing, with
# a signature that named the cause once I knew to look:
#
#   bf6.exe: 0 row(s), 39 instance(s) seen, 0 skipped, 0 lookup(s) found nothing
#
# Zero skipped, zero misses, zero rows. A database that resolves everything and
# yields nothing is not being consulted. The walk caches layouts and "does this
# type matter" verdicts KEYED BY TYPE ID, on the walk rather than on the database
# that produced them, and hands the layout cache straight to the decoder. So the
# first walk fills it with the empty layouts an unreadable database returns, and
# swapping `types` afterwards changes where answers WOULD come from while keeping
# the answers already recorded.
#
# This reproduces that on a healthy install by poisoning the caches the way an
# unreadable database would leave them, then shows the swap alone does not
# recover and use_types() does.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_cachepoison.gd -- MP_Badlands

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")

var _fails: Array[String] = []


func _check(name: String, ok: bool, detail: String) -> void:
	print(("  PASS  %s" if ok else "  FAIL  %s") % name)
	if detail != "":
		print("          %s" % detail)
	if not ok:
		_fails.append(name)


# What an unreadable type database leaves behind: an empty layout recorded for
# every type it was asked about, and - since 2.6.8 fails open on unknown types -
# a "this type matters" verdict for each.
func _poison(w) -> int:
	var n := 0
	for k in w._layouts.keys():
		w._layouts[k] = {}
		n += 1
	for k in w._type_matters_cache.keys():
		w._type_matters_cache[k] = true
	return n


func _init() -> void:
	var map := "MP_Badlands"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			map = str(a)

	var gs = GS.new()
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: ", gs.error)
		quit(1)
		return
	var w = gs.walk
	var sp = gs.types
	var baseline: int = w.rows.size()
	print("baseline with SP: %d rows, %d layout(s) cached"
		% [baseline, w._layouts.size()])
	if baseline == 0:
		print("already empty, proves nothing")
		quit(1)
		return

	var other := ""
	for c in BF6Types.exe_candidates(gs.src.game):
		if c != gs._exe_used and FileAccess.file_exists(c):
			other = c
			break
	var mp := BF6Types.new()
	if other == "" or not mp.open(other):
		print("no second executable")
		quit(1)
		return

	# --- reproduce -------------------------------------------------------
	print("")
	print("A. swap the database the OLD way, leaving the caches in place")
	var n := _poison(w)
	print("   poisoned %d cached layout(s), as an unreadable database would" % n)
	w.types = mp                      # the pre-fix behaviour, deliberately
	w.rows = []
	w.run(gs.level)
	print("   %d row(s), %d instance(s) seen, %d skipped, %d lookup(s) missed"
		% [w.rows.size(), int(w.stats.get("instances", 0)),
			int(w.stats.get("instances_skipped", 0)), mp.n_miss])
	_check("A: reproduces the user's empty result", w.rows.is_empty(),
		"%d rows" % w.rows.size())
	_check("A: and reproduces their signature, nothing skipped and no misses",
		int(w.stats.get("instances_skipped", 0)) == 0 and mp.n_miss == 0,
		"skipped=%d missed=%d" % [int(w.stats.get("instances_skipped", 0)),
			mp.n_miss])

	# --- fix -------------------------------------------------------------
	print("")
	print("B. swap it through use_types(), which drops what the old one left")
	w.use_types(mp)
	w.rows = []
	w.run(gs.level)
	print("   %d row(s), %d instance(s) seen, %d skipped"
		% [w.rows.size(), int(w.stats.get("instances", 0)),
			int(w.stats.get("instances_skipped", 0))])
	_check("B: the map comes back from the MP database", w.rows.size() == baseline,
		"%d rows, expected %d" % [w.rows.size(), baseline])

	# --- and the same for the original database --------------------------
	print("")
	print("C. the same poison with the ORIGINAL database, to show the cache is")
	print("   the cause and not which executable is in use")
	_poison(w)
	w.types = sp
	w.rows = []
	w.run(gs.level)
	var poisoned_sp: int = w.rows.size()
	w.use_types(sp)
	w.rows = []
	w.run(gs.level)
	_check("C: poisoned cache empties even the GOOD database",
		poisoned_sp == 0, "%d rows" % poisoned_sp)
	_check("C: and use_types recovers it", w.rows.size() == baseline,
		"%d rows, expected %d" % [w.rows.size(), baseline])

	print("")
	if _fails.is_empty():
		print("ALL PASS")
	else:
		print("FAILURES: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
