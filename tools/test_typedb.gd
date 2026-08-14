@tool
extends SceneTree
# DOES THE OTHER EXECUTABLE EMPTY THE WALK? asked on a KNOWN-GOOD install.
#
# A user's maps came back with 0 placements, 0 skyline groups and 0 gamemode
# markers while their mount, catalogue, textures and terrain were all perfect.
# The suspected cause is the type database: it is read out of bf6.exe, the SP
# and MP builds carry different ones, and the wrong one resolves every type to
# wrong offsets rather than failing - so the walk matches no fields and returns
# nothing. Their SP executable is 232 KB different from ours.
#
# That is a story, not evidence. This turns it into evidence by changing ONE
# variable on an install that is known to work: open the map normally, record
# the row count, then re-run the same walk with the type database taken from
# the other executable and record that. If the second number collapses to zero
# on a healthy install, the mechanism is proven and the fallback in
# highpoly_gamesource is aimed at the right thing.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_typedb.gd -- MP_Aftermath
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _init() -> void:
	var map := "MP_Aftermath"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			map = str(a)

	var gs = GS.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("could not open %s" % map)
		quit(1)
		return
	print("")
	print("opened %s in %.1f s" % [map, (Time.get_ticks_msec() - t0) / 1000.0])
	print("type database used:  %s" % gs._exe_used)
	print("rows from the walk:  %d" % gs.walk.rows.size())
	print("")

	# The other candidate, whichever it is.
	var other := ""
	for c in BF6Types.exe_candidates(gs.src.game):
		if c != gs._exe_used and FileAccess.file_exists(c):
			other = c
			break
	if other == "":
		print("no second executable on this install, nothing to compare")
		quit(0)
		return

	var f := FileAccess.open(other, FileAccess.READ)
	var sz := 0
	if f != null:
		sz = f.get_length()
		f.close()
	print("now forcing:         %s  (%d bytes)" % [other, sz])

	var t2 := BF6Types.new()
	if not t2.open(other):
		print("could not read it:   %s" % t2.error)
		quit(1)
		return
	# The SAME walk the reader builds, differing only in its type database.
	var w2 = BF6Walk.new(gs.src, t2)
	for g in GS.LIGHT_TYPES:
		w2.want_types[str(g)] = "light"
	for g in GS.EDV_TYPES:
		w2.want_types[str(g)] = "edv"
	w2.want_fields = GS.LIGHT_FIELDS + GS.EDV_FIELDS
	for d in gs._depot_bundles:
		w2.scope_index[str(d)] = str(d)
	var t1 := Time.get_ticks_msec()
	w2.run(gs.level)
	print("rows with that one:  %d   (%.1f s)"
		% [w2.rows.size(), (Time.get_ticks_msec() - t1) / 1000.0])
	print("")
	if gs.walk.rows.size() > 0 and w2.rows.is_empty():
		print("PROVEN: the wrong executable empties the walk while everything")
		print("        else about the install still works. That is exactly the")
		print("        user's symptom, and the fallback is aimed correctly.")
	elif w2.rows.size() > 0 and gs.walk.rows.is_empty():
		print("INVERTED: the OTHER executable is the correct one on this")
		print("          install, which means the candidate order is wrong.")
	elif w2.rows.size() > 0:
		print("BOTH WORK: %d against %d. The executables are interchangeable"
			% [gs.walk.rows.size(), w2.rows.size()])
		print("           here, so a wrong type database is NOT what empties a")
		print("           walk, and the user's fault is something else.")
	else:
		print("BOTH EMPTY: this install cannot walk the map at all, so the")
		print("            comparison says nothing. Check the map name.")
	quit(0)
