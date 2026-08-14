@tool
extends SceneTree
# DOES THE OTHER EXECUTABLE EMPTY THE WALK? asked on a KNOWN-GOOD install.
#
# A user's maps come back with 0 placements, 0 skyline groups and 0 gamemode
# markers on four different maps, while their mount, catalogue, textures and
# terrain are all perfect. The suspected cause is the type database: it is read
# out of bf6.exe, the SP and MP builds carry different ones, and the wrong one
# resolves every type to wrong offsets rather than failing - so the walk matches
# no fields and returns nothing. Their SP executable is 232 KB different from
# ours.
#
# That is a story, not evidence. This changes ONE variable on an install known
# to work: open the map normally, record the row count, then re-run the same
# walk with the type database from the other executable.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_typedb.gd -- MP_Battery
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.
#
# PROGRESS GOES TO A FILE, not just to stdout. Godot block-buffers stdout when
# it is piped, so the first version of this looked completely silent for
# thirteen minutes while it was in fact dead on arrival - the script had failed
# to compile and nothing said so until the process ended. A line appended and
# closed per step can be read from outside WHILE it runs, so a stall is visible
# immediately and its last line names the step it stalled in.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const OUT := "user://typedb_test.log"


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


func _init() -> void:
	var map := "MP_Battery"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			map = str(a)
	DirAccess.remove_absolute(OUT)
	_say("start, map=%s" % map)

	var gs = GS.new()
	_say("opening the map with the default executable")
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		_say("FAILED to open %s" % map)
		quit(1)
		return
	_say("opened. type database = %s" % gs._exe_used)
	_say("rows from that walk = %d" % gs.walk.rows.size())
	if gs.walk.rows.is_empty():
		_say("the DEFAULT walk is already empty on a known-good install, so "
			+ "this map says nothing about the executables. Pick another.")
		quit(0)
		return

	var other := ""
	for c in BF6Types.exe_candidates(gs.src.game):
		if c != gs._exe_used and FileAccess.file_exists(c):
			other = c
			break
	if other == "":
		_say("no second executable here, nothing to compare")
		quit(0)
		return
	var f := FileAccess.open(other, FileAccess.READ)
	var sz := 0
	if f != null:
		sz = f.get_length()
		f.close()
	_say("forcing %s (%d bytes)" % [other, sz])

	var t2 := BF6Types.new()
	if not t2.open(other):
		_say("could not read it: %s" % t2.error)
		quit(1)
		return
	_say("type database opened, building the second walk")
	var w2 = BF6Walk.new(gs.src, t2)
	for g in GS.LIGHT_TYPES:
		w2.want_types[str(g)] = "light"
	for g in GS.EDV_TYPES:
		w2.want_types[str(g)] = "edv"
	w2.want_fields = GS.LIGHT_FIELDS + GS.EDV_FIELDS
	for d in gs._depot_bundles:
		w2.scope_index[str(d)] = str(d)
	# Every 500 partitions, so a stall shows up in the file rather than as
	# silence. The first attempt at this test had no progress at all.
	w2.progress = func(found: int, seen: int):
		if seen % 500 == 0:
			_say("  walking: %d seen, %d found" % [seen, found])
	_say("running the second walk (uncached, this is the slow part)")
	var t0 := Time.get_ticks_msec()
	w2.run(gs.level)
	_say("second walk done in %.1f s, rows = %d"
		% [(Time.get_ticks_msec() - t0) / 1000.0, w2.rows.size()])

	_say("")
	if w2.rows.is_empty():
		_say("PROVEN: the wrong executable empties the walk while everything "
			+ "else about the install still works, which is the user's exact "
			+ "symptom. The fallback is aimed correctly.")
	elif w2.rows.size() > 0:
		_say(("BOTH WORK: %d rows against %d. A mismatched type database is "
			+ "NOT what empties a walk, so the user's fault is something else "
			+ "and the fallback would be treating a symptom it does not "
			+ "understand.") % [gs.walk.rows.size(), w2.rows.size()])
	quit(0)
