@tool
extends SceneTree
# Open a map exactly the way the panel does, and say what failed.
#
# "could not read <map> from the install" is one message covering five distinct
# failures inside open_map: no install, the mount, no bf6.exe, the type
# database, and the placement walk. Which one it was is in gs.error and nowhere
# else, so print it - along with the state each stage reached, because a mount
# that finds 0 EBX entries and a mount that finds 200k and then fails the walk
# are not the same problem.
#
#   ... probe_open.gd -- MP_Tungsten [surface]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Tungsten"
	var with_surface := args.size() > 1 and str(args[1]) == "surface"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   | %s" % s)
	gs.catalogue_mount = false
	if with_surface:
		# what the panel sets whenever a map layer is on
		gs.surface_cache = "user://mapcontext/%s" % map
	print("opening %s   surface_cache=%s" % [map,
		gs.surface_cache if gs.surface_cache != "" else "(none)"])
	var t := Time.get_ticks_msec()
	var ok: bool = gs.open_map(map, "", Callable(), {"placements": true})
	print("")
	print("open_map -> %s in %.1f s" % [ok, (Time.get_ticks_msec() - t) / 1000.0])
	if not ok:
		print("ERROR: %s" % str(gs.error))
	print("   level             %s" % str(gs.level))
	print("   ebx entries       %d" % (gs.src.ebx.size() if gs.src != null else -1))
	print("   resources         %d" % (gs.src.res.size() if gs.src != null else -1))
	print("   placement rows    %d" % (gs.walk.rows.size() if gs.walk != null else -1))
	print("   collected ents    %d" % (gs.walk.ents.size() if gs.walk != null else -1))
	print("   walk stats        %s" % str(gs.walk.stats if gs.walk != null else {}))
	# where its caches live, because a poisoned one is the usual answer
	print("   walk cache dir    %s" % ProjectSettings.globalize_path("user://"))
	quit(0 if ok else 1)
