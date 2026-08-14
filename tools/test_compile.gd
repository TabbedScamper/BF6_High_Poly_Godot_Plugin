@tool
extends SceneTree
# DOES EVERY SCRIPT IN THE ADDON ACTUALLY COMPILE.
#
# WRITTEN AFTER A FALSE ALL-CLEAR. The check used before this was
#
#     Godot --headless --path <throwaway> --editor --quit
#
# grepped for "parse error", and it reported zero on a highpoly_gamesource.gd
# that could not load at all: four calls to an identifier that does not exist
# in that script. Importing a project does not COMPILE its GDScript; the error
# only appears when something loads the script. So the check was answering a
# different question from the one being asked, and answering it reassuringly.
#
# load() forces the compile. Loading one script also compiles everything it
# preloads, but not its siblings, so every file is loaded explicitly rather
# than trusting the graph to reach them.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_compile.gd
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.
#
# Compile errors are printed by the engine to stderr as they happen, so a run
# that prints SCRIPT ERROR above the summary has failed even where the count
# below cannot tell: a script whose dependency failed reports its own failure.

const ADDON := "res://addons/highpoly_toggle"


func _init() -> void:
	var names: Array[String] = []
	var da := DirAccess.open(ADDON)
	if da == null:
		print("cannot open %s" % ADDON)
		quit(1)
		return
	for f in da.get_files():
		var fn := str(f)
		if fn.get_extension().to_lower() == "gd":
			names.append(fn)
	names.sort()

	var ok := 0
	var bad: Array[String] = []
	for fn in names:
		var path := "%s/%s" % [ADDON, fn]
		var s = load(path)
		if s == null:
			bad.append(fn)
		else:
			ok += 1
	print("")
	print("scripts compiled: %d of %d" % [ok, names.size()])
	if bad.is_empty():
		print("ALL OK")
	else:
		print("FAILED TO LOAD:")
		for b in bad:
			print("   %s" % b)
	quit(0 if bad.is_empty() else 1)
