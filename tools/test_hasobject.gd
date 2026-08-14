@tool
extends SceneTree
# CAN THE READER ACTUALLY DRAW THIS OBJECT? asked of the reader, not inferred.
#
# _asset_id() matches a placed SDK object by name and then asks
# game_source.has_object(key). A key that matches but has no object keeps EA's
# proxy, silently - the honest outcome, but indistinguishable on screen from a
# match that never happened. This tells the two apart in about a second, warm.
#
# Written after a chain of four wrong guesses about why a user's ceiling lamp
# was not skinned: that the mesh was missing (it is not), that the plugin was
# out of scope (it is not), that Godot's duplicate-renaming broke the match (it
# does not, measured at zero), and that the Portal prefab was absent (it is
# there under the exact name). Each was plausible. Ask the code.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_hasobject.gd -- MP_Aftermath Key1 Key2
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := "MP_Aftermath"
	var keys: Array = []
	for i in range(args.size()):
		if i == 0:
			map = str(args[i])
		else:
			keys.append(str(args[i]))
	if keys.is_empty():
		keys = ["CeilingLamp_Rect_01", "WallLamp_Rect_02_nbrk"]

	var gs = GS.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("could not open %s: %s" % [map, gs.last_error()
			if gs.has_method("last_error") else "?"])
		quit(1)
		return
	print("opened %s in %.1f s" % [map, (Time.get_ticks_msec() - t0) / 1000.0])
	print("")
	for k in keys:
		var ok: bool = gs.has_object(str(k))
		print("  %-34s has_object = %s" % [str(k), "YES" if ok else "no"])
	quit(0)
