@tool
extends SceneTree
# DOES THE RETRY RECOVER, AND DOES A FAILED RETRY PUT EVERYTHING BACK?
#
# The first attempt at this test (test_retry.gd) kept measuring itself. It
# swapped the type database AFTER open_map and then called ensure_placements,
# which consults the walk cache first - so a previous run's saved rows were
# served, the retry never fired, and the log said "retried=false" on a run that
# had proved nothing. Deleting the cache did not help either: run() walks and
# re-saves, so the next run was poisoned again.
#
# This one never touches ensure_placements or the cache. _retry_other_typedb
# calls walk.run() directly, so driving it straight tests the real function with
# no cache in the path at all, in both directions:
#
#   A  RECOVERY. Present the session as if it had opened with the MP database
#      (the wrong one). The retry should reach for SP and get the map back.
#
#   B  RESTORE. Make BOTH walks fail, by pointing the walk at a level that
#      cannot resolve. The retry should give up AND put the original database
#      back - the v2.6.5 fix. `types` is shared with FX, the gamemode miner and
#      every other read, so a retry that fails and keeps the other database
#      leaves the whole session decoding with one that reads nothing.
#
#      B also exercises the discriminator the user's diagnosis now rests on:
#      when neither executable reached a single object, the walk stopped before
#      it read anything and no type database could have helped.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_retry2.gd -- MP_Battery
#
# Copy to <project>/hp_test/ first: --script only loads from res://, and the
# repo is .gdignore'd so the editor never sees it.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const OUT := "user://retry2_test.log"

var _fails: Array[String] = []


func _say(s: String) -> void:
	print(s)
	var f := FileAccess.open(OUT, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(OUT, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("%6.1fs  %s" % [Time.get_ticks_msec() / 1000.0, s])
	f.close()


func _check(name: String, ok: bool, detail: String) -> void:
	_say(("  PASS  %s" if ok else "  FAIL  %s") % name)
	if detail != "":
		_say("          %s" % detail)
	if not ok:
		_fails.append(name)


func _init() -> void:
	var map := "MP_Battery"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			map = str(a)
	DirAccess.remove_absolute(OUT)
	_say("start, map=%s" % map)

	var gs = GS.new()
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		_say("FAILED to open %s: %s" % [map, str(gs.error)])
		quit(1)
		return
	var good: String = gs._exe_used
	var good_types = gs.types
	var baseline: int = gs.walk.rows.size()
	_say("opened. exe=%s rows=%d" % [good.get_file(), baseline])
	if baseline == 0:
		_say("this map is already empty on a known-good install, so it can "
			+ "prove nothing. Pick another.")
		quit(1)
		return

	var other := ""
	for c in BF6Types.exe_candidates(gs.src.game):
		if c != good and FileAccess.file_exists(c):
			other = c
			break
	if other == "":
		_say("only one executable here, nothing to test")
		quit(1)
		return

	# ------------------------------------------------------------------ A
	_say("")
	_say("A. RECOVERY: present the session as if it had opened with the wrong one")
	var t_other := BF6Types.new()
	if not t_other.open(other):
		_say("could not read %s: %s" % [other, t_other.error])
		quit(1)
		return
	# Exactly the state a wrong-database session is in when the layer is toggled:
	# the other database everywhere, and an empty walk.
	gs.types = t_other
	gs._exe_used = other
	gs._exe_others = [good]
	gs.walk.types = t_other
	gs.walk.rows = []
	gs._types_retried = false
	var t0 := Time.get_ticks_msec()
	gs._retry_other_typedb()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	_say("  retry took %.1f s" % secs)
	_check("A: the map came back", gs.walk.rows.size() == baseline,
		"%d rows, expected %d" % [gs.walk.rows.size(), baseline])
	_check("A: the good database is in use", gs._exe_used == good,
		"exe=%s" % str(gs._exe_used).get_file())
	_check("A: game source types were swapped too, not just the walk",
		gs.types == gs.walk.types, "")

	# ------------------------------------------------------------------ B
	_say("")
	_say("B. RESTORE: make both walks fail, and check nothing is left swapped")
	gs.types = good_types
	gs._exe_used = good
	gs._exe_others = [other]
	gs.walk.types = good_types
	gs.walk.rows = []
	gs._types_retried = false
	# A level that cannot resolve fails BEFORE any type is read, which is the
	# state a user's log implied: two walks, same second, zero objects seen.
	var real_level = gs.level
	gs.level = "MP_ThisLevelDoesNotExist"
	t0 = Time.get_ticks_msec()
	gs._retry_other_typedb()
	secs = (Time.get_ticks_msec() - t0) / 1000.0
	gs.level = real_level
	_say("  failed retry took %.1f s" % secs)
	_check("B: it did fail", gs.walk.rows.is_empty(),
		"%d rows" % gs.walk.rows.size())
	_check("B: the original database is back", gs._exe_used == good,
		"exe=%s, expected %s" % [str(gs._exe_used).get_file(), good.get_file()])
	_check("B: game source types restored", gs.types == good_types, "")
	_check("B: the walk's types restored", gs.walk.types == good_types, "")
	var seen := int(gs.walk.stats.get("instances", 0))
	_check("B: it reached zero objects, which is the discriminator", seen == 0,
		"instances=%d" % seen)
	_check("B: the walk said why it stopped",
		str(gs.walk.stats.get("error", "")) != "",
		"error=%s" % str(gs.walk.stats.get("error", "")))
	# A FAILED RETRY MUST BE FAST. If both walks are instant, that IS the user's
	# signature and the timestamp reading was sound.
	_check("B: both walks were instant, as in the user's log", secs < 2.0,
		"%.1f s" % secs)

	_say("")
	if _fails.is_empty():
		_say("ALL PASS")
	else:
		_say("FAILURES: " + ", ".join(_fails))
	quit(0 if _fails.is_empty() else 1)
