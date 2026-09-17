extends SceneTree

# BISECT: does resolving the new default (Random) pose hang?
#
#   python tools/run_addon_script.py native/probe_random_default.gd --args <steam>
#
# The rig test started running past ten minutes with ~25% of one core and flat
# memory - the signature of a loop rather than of work - right after the default
# role became ROLE_RANDOM. This runs ONLY that, and writes progress to a file
# because Godot block-buffers stdout when it is redirected, so a killed run
# otherwise reports nothing at all.

const MARK := "user://random_default_probe.txt"


func mark(what: String) -> void:
	var f := FileAccess.open(MARK, FileAccess.READ_WRITE) if FileAccess.file_exists(MARK) \
		else FileAccess.open(MARK, FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line("%7.2f s  %s" % [Time.get_ticks_msec() / 1000.0, what])
		f.close()
	print(what)


func _init() -> void:
	await process_frame
	if FileAccess.file_exists(MARK):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MARK))
	var a := OS.get_cmdline_user_args()
	mark("start; user data at %s" % ProjectSettings.globalize_path(MARK))

	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0]) if a.size() > 0 else ""):
		mark("FAIL could not open the game")
		quit(1)
		return
	mark("game open")

	var req := HighpolyLoadout.soldier_request("PlayerSpawner", {}, "PlayerSpawner")
	mark("request built: role=%s seed=%s animated=%s"
		% [str(req.get("role", "")), str(req.get("role_seed", "")), str(req.get("animated", ""))])

	var roles := HighpolyLoadout.catalogue_list(core, "roles")
	mark("catalogue_list(roles) returned %d" % roles.size())

	for n in ["PlayerSpawner", "PlayerSpawner2", "AI_Spawner", "SpawnPoint"]:
		var one := HighpolyLoadout.soldier_request("PlayerSpawner", {}, n)
		var r := HighpolyLoadout.resolve_role(core, one)
		mark("  %s -> %s" % [n, str(r.get("role", ""))])

	mark("DONE")
	quit(0)
