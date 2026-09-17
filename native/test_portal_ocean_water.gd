extends SceneTree

# DOES THE PLUGIN SEE PORTAL OCEAN'S WATER?
#
#   python tools/run_addon_script.py native/test_portal_ocean_water.gd --args <steam>
#
# mp_portal_ocean does not author water under its own level directory. It PLACES
# the Portal water prefab gmpf_water at (0, 70, 0), so a reader that only
# searches the level directory finds nothing while the map plainly has an
# 8192 m ocean.
#
# The C++ core handles this (bf6_level_water follows one prefab reference and
# composes the transform). The QUESTION THIS ASKS is whether the paths the Godot
# plugin actually renders from do the same, because the plugin carries its own
# GDScript reader in highpoly_gamesource.gd that predates the core and was
# ported the other way round.
#
# Both paths are checked, and mp_atoll is the control: it authors its water
# normally, so it must come back with a surface on every path. A test that only
# looked at Portal Ocean could not tell "this reader is broken" from "this
# harness never worked".

func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: test_portal_ocean_water.gd -- <steam root>")
		quit(2); return
	var root := str(a[0])
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return

	var levels := ["mp_portal_ocean", "mp_atoll"]
	var rows: Array = []
	for level in levels:
		rows.append(_check(root, str(level)))

	print("")
	print("%-18s %-14s %-14s" % ["level", "native core", "gamesource"])
	for r in rows:
		print("%-18s %-14s %-14s" % [r["level"], r["native"], r["gds"]])

	# THE CONTROL DECIDES WHETHER A FAILURE MEANS ANYTHING, and it is checked
	# PER PATH. Requiring both paths to fail before calling the run
	# inconclusive let a broken harness through once already: the native path
	# passed, so the guard stayed quiet while the gamesource column reported
	# zero on every level including the control.
	var control: Dictionary = rows[1]
	var dead := []
	for key in ["native", "gds"]:
		if str(control[key]).begins_with("0 surfaces") or str(control[key]).contains("failed"):
			dead.append(key)
	if not dead.is_empty():
		print("\nINCONCLUSIVE: the control level mp_atoll authors water normally,")
		print("so a zero there means this harness is not exercising that path:")
		for k in dead:
			print("    %s -> %s" % [k, str(control[k])])
		quit(2); return

	var ocean: Dictionary = rows[0]
	var bad := 0
	if ocean["native"] == "0 surfaces":
		print("\nFAIL native core path finds no water on mp_portal_ocean")
		bad += 1
	if ocean["gds"] == "0 surfaces":
		print("FAIL gamesource path finds no water on mp_portal_ocean")
		print("     (this is the reader the preview renders from)")
		bad += 1
	if bad == 0:
		print("\nOK both paths see Portal Ocean's water")
	quit(0 if bad == 0 else 1)


func _check(root: String, level: String) -> Dictionary:
	var out := {"level": level, "native": "?", "gds": "?"}

	# --- the native core, through the same GDExtension the plugin loads ---
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(root):
		out["native"] = "open failed"
	else:
		var env = preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
		var w: Variant = env.request("water")
		if typeof(w) == TYPE_DICTIONARY and not (w as Dictionary).is_empty():
			var surfaces: Array = (w as Dictionary).get("surfaces", [])
			out["native"] = ("%d surfaces" % surfaces.size()) if not surfaces.is_empty() \
				else "0 surfaces"
		else:
			out["native"] = "0 surfaces"

	# --- the plugin's own GDScript reader ---
	# This is highpoly_gamesource.water(), which is what the preview builds the
	# water mesh from, so it is the one that decides whether the user sees an
	# ocean on this map.
	# open_map(map, game_dir) is the real entry point - an earlier version of
	# this test guessed at open()/load_level()/set_level(), none of which exist,
	# and reported the resulting nothing as if the reader had failed. The
	# control level is what caught it.
	var gs_script := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
	var gs = gs_script.new()
	if not bool(gs.open_map(level, root)):
		out["gds"] = "open failed: " + str(gs.error)
		return out
	var arr: Variant = gs.water()
	out["gds"] = ("%d surfaces" % (arr as Array).size()) \
		if typeof(arr) == TYPE_ARRAY and not (arr as Array).is_empty() \
		else "0 surfaces"
	return out
