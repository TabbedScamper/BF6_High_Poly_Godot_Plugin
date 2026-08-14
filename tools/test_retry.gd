@tool
extends SceneTree
# DOES THE EMPTY-WALK RETRY ACTUALLY FIRE ON THE PATH A USER TAKES?
#
# The retry has now been shipped twice and fired for nobody. First it was only
# in open_map, and the user turns the ground on first and the objects on second,
# which walks in ensure_placements instead. Then it was on both, and their log
# still showed nothing. Each time the mechanism was proven and the reachability
# was assumed.
#
# So this reproduces their sequence exactly, on our install, with a type
# database deliberately swapped for the wrong one:
#
#   1. open the map with placements NOT wanted   (what "terrain first" does)
#   2. swap in the wrong executable's layouts    (what their install is)
#   3. delete the walk cache                     (so the walk really runs)
#   4. call ensure_placements()                  (what "objects on" does)
#
# and then asks the only question that matters: are there rows afterwards.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_retry.gd -- MP_Battery
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const OUT := "user://retry_test.log"


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


# The walk cache has to go or run_cached serves the good rows straight back and
# the retry is never reached. This is also why the USER's cache matters: theirs
# holds an EMPTY walk saved by an earlier session.
func _drop_walk_cache() -> int:
	var n := 0
	var da := DirAccess.open("user://")
	if da == null:
		return 0
	for f in da.get_files():
		if str(f).begins_with("bf6_walk_"):
			DirAccess.remove_absolute("user://" + str(f))
			n += 1
	return n


func _init() -> void:
	var map := "MP_Battery"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			map = str(a)
	DirAccess.remove_absolute(OUT)
	_say("start, map=%s" % map)

	var gs = GS.new()
	# STEP 1: the open a "terrain first" user performs. placements NOT wanted,
	# so the walk does not run here and neither does open_map's retry.
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		_say("FAILED to open %s" % map)
		quit(1)
		return
	_say("opened with placements=false. exe=%s rows=%d ready=%s"
		% [gs._exe_used.get_file(), gs.walk.rows.size(),
			str(gs.placements_ready)])

	# STEP 2: make this install look like theirs, by walking with the wrong
	# type database.
	var other := ""
	for c in BF6Types.exe_candidates(gs.src.game):
		if c != gs._exe_used and FileAccess.file_exists(c):
			other = c
			break
	if other == "":
		_say("no second executable, cannot simulate")
		quit(0)
		return
	var t2 := BF6Types.new()
	if not t2.open(other):
		_say("could not read %s" % other)
		quit(1)
		return
	var good: String = gs._exe_used
	# SWAP THE DATABASE ON THE REAL WALK, exactly as a broken install would
	# present it. An earlier version of this test built a REPLACEMENT walk here
	# and it failed with "could not resolve the level root" - because a fresh
	# BF6Walk has no `gi`, the partition guid index that open_map filled in. That
	# was the test being wrong, not the plugin, and it cost a round of chasing.
	gs.types = t2
	gs._exe_used = other
	gs.walk.types = t2
	_say("swapped to the WRONG database: %s" % other.get_file())

	# STEP 3
	_say("dropped %d walk cache file(s)" % _drop_walk_cache())

	# STEP 4: the layer toggle.
	_say("calling ensure_placements, which is what switching the layer on does")
	var ok: bool = gs.ensure_placements()
	_say("ensure_placements returned %s" % str(ok))
	_say("after: exe=%s rows=%d retried=%s err=%s"
		% [gs._exe_used, gs.walk.rows.size(), str(gs._types_retried),
			str(gs.error)])
	_say("")
	if gs.walk.rows.size() > 0 and gs._exe_used == good:
		_say("PASS: the walk came back empty on the wrong database, the retry "
			+ "fired on the ensure_placements path, and it recovered %d rows "
			+ "with %s." % [gs.walk.rows.size(), good.get_file()])
	elif gs.walk.rows.is_empty():
		_say("FAIL: still empty. The retry did not fire, or fired and the "
			+ "other database is no better. This is the user's exact outcome.")
	else:
		_say("ODD: rows exist but the executable did not change back. Check "
			+ "whether the cache served them.")
	quit(0)
