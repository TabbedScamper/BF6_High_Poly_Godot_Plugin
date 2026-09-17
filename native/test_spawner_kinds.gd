extends SceneTree

# WHICH PLACED OBJECTS PREVIEW A SOLDIER, and which keep the SDK's own proxy.
#
# HQ_PlayerSpawner is a DEPLOYMENT POST that the SDK draws as a low-poly flag
# post. Its class name ends in "PlayerSpawner", and on that basis alone it was
# being dressed with a soldier: a man standing where the flag should be, and the
# one marker that reads from across the map replaced by one that does not.
#
# The name is the trap, so the test names it: anything matching *PlayerSpawner
# looks like a soldier spawner and HQ is the one that is not.

const Soldier = preload("res://addons/highpoly_toggle/highpoly_soldier.gd")
const Loadout = preload("res://addons/highpoly_toggle/highpoly_loadout.gd")


func _init() -> void:
	await process_frame
	var failures := 0

	# scene basename -> should it preview a soldier?
	var cases := {
		"PlayerSpawner": true,
		"AI_Spawner": true,
		"SpawnPoint": true,
		"HQ_PlayerSpawner": false,   # the flag post
	}
	for key in cases.keys():
		var want: bool = cases[key]
		var faction := str(Soldier.faction_for(str(key)))
		var builds := not faction.is_empty()
		var offered: bool = Loadout.is_soldier_type(str(key))
		var ok := builds == want and offered == want
		if not ok:
			failures += 1
		print("%-20s soldier overlay %-5s loadout choices %-5s  want %-5s%s" % [
			str(key), str(builds), str(offered), str(want),
			"" if ok else "   <-- FAIL"])

	# An empty faction is what makes highpoly_lib fall through to _show_proxy_only
	# and keep the SDK post, so it is asserted rather than assumed.
	if not str(Soldier.faction_for("HQ_PlayerSpawner")).is_empty():
		print("FAIL HQ_PlayerSpawner still resolves a faction, so it would build a soldier")
		failures += 1

	print("\n%s" % ("PASS" if failures == 0 else "FAIL: %d case(s)" % failures))
	quit(1 if failures else 0)
