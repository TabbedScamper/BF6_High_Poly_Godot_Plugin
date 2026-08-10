@tool
extends SceneTree
# EXTENDED TERRAIN, END TO END, ON ONE MAP.
#
# "Extended Terrain crashes Godot on MP_Tungsten" is reproducible or it is not,
# and a crash inside the reader is the half that can be caught headlessly. Each
# stage prints BEFORE it runs, so if the process dies the last line names what
# killed it - which a crash gives us nothing else to go on for.
#
#   ... probe_terrainbuild.gd -- MP_Tungsten

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Tungsten"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   | %s" % s)
	gs.catalogue_mount = false
	gs.surface_cache = "user://mapcontext/%s" % map      # what the panel sets

	_say("open_map (mount, typeinfo, partition index, walk)")
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: %s" % str(gs.error))
		quit(1)
		return
	_mem("after the read")

	var cache := "user://mapcontext/%s" % map
	DirAccess.make_dir_recursive_absolute(cache)

	_say("terrain() - heightfield, roads, water")
	var t: Dictionary = gs.terrain(cache)
	var keys: Array = t.keys()
	keys.sort()
	print("   terrain() -> %d key(s): %s" % [keys.size(), str(keys)])
	_mem("after terrain()")

	_say("terrain_surface() - colour map, splat and the LAYER PALETTE")
	# The layer palette is the table that used to be read out of the wrong
	# level's depot; that produced garbage slowly rather than failing, so this
	# is the stage worth watching on a map that crashes.
	var surf: Dictionary = gs.terrain_surface(cache)
	var sk: Array = surf.keys()
	sk.sort()
	print("   terrain_surface() -> %d key(s): %s" % [sk.size(), str(sk)])
	_mem("after terrain_surface()")

	print("")
	print("SURVIVED: nothing in the reader's terrain path crashed on %s" % map)
	quit(0)


func _say(what: String) -> void:
	print("")
	print("== %s" % what)
	# flushed by print itself; the point is that this line exists before the work
	# so a hard crash names its own stage


func _mem(when: String) -> void:
	print("   [%s] heap %d MB, free RAM %d MB" % [when,
		int(OS.get_static_memory_usage()) / 1048576,
		int(HighpolyVitals.free_mb())])
