@tool
extends SceneTree
# THE COLD EXTRACTION BENCH - the scoreboard for "cold starts as fast as
# possible". bench_flight measures frames with everything already built and
# says nothing about extraction; this is the other pillar: it wipes ITS OWN
# user:// caches (the headless harness project's - never the editor's, whose
# warm state survives every run) and runs the full open the way an
# everything-on session would: mount, partition index, placement walk, ground
# surface. The phase table and the build journal are the result.
#
#   godot --headless --path <harness> --script res://bench_cold.gd
#   user args:  --map=MP_Dumbo     another map (default MP_Aftermath)
#               --deep             also wipe the surface cache, so the splat
#                                  bake and colour map run cold too (adds the
#                                  one-time ~4 min bake to the run; without it
#                                  the bench measures the every-patch cold
#                                  path, which is the one users actually hit)

const BJournal = preload("res://addons/highpoly_toggle/highpoly_journal.gd")


func _init() -> void:
	var map := "MP_Aftermath"
	var deep := false
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--map="):
			map = str(a).substr(6)
		elif str(a) == "--deep":
			deep = true
	# cold = the extraction caches gone. Index (mount), pidx (partition
	# index) and walk are the every-patch cold path; the game invalidates
	# all three on every update, so this is the start users meet most.
	var ud := ProjectSettings.globalize_path("user://")
	var wiped := 0
	for f in DirAccess.get_files_at(ud):
		var fn := str(f)
		if fn.begins_with("bf6_index_") or fn.begins_with("bf6_pidx_") \
				or fn.begins_with("bf6_walk_"):
			DirAccess.remove_absolute(ud.path_join(fn))
			wiped += 1
	var cache := ProjectSettings.globalize_path("user://bench_cold/%s" % map)
	if deep and DirAccess.dir_exists_absolute(cache):
		var stack: Array = [cache]
		var dirs: Array = []
		while not stack.is_empty():
			var d: String = stack.pop_back()
			dirs.append(d)
			for sub in DirAccess.get_directories_at(d):
				stack.append(d.path_join(str(sub)))
			for f2 in DirAccess.get_files_at(d):
				DirAccess.remove_absolute(d.path_join(str(f2)))
		dirs.reverse()
		for d2 in dirs:
			DirAccess.remove_absolute(str(d2))
	DirAccess.make_dir_recursive_absolute(cache)
	print("COLD BENCH: %s, %d cache file(s) wiped%s"
		% [map, wiped, ", surface cache wiped too" if deep else ""])
	# WHAT THIS RUN IS AND IS NOT, said out loud every time.
	#
	# The wipe above is the mount index, the partition index and the walk -
	# the three the game invalidates on every patch. It is NOT a first-ever
	# open, and the difference is not small: without --deep the splat
	# composite and the colour map are served from user://bench_cold/<map>,
	# and a run with that directory empty measured 127 s compositing and 147 s
	# for the terrain surface. Quoting this run's total as "the cold start"
	# understates a first open by more than the whole rest of the load.
	#
	# Nothing here can reset the OS page cache either. After one run the .cas
	# files and TOCs are in the file cache, so the disk is warm even when
	# these caches are not. Two runs compare fairly against each other; the
	# absolute number is optimistic against a fresh boot.
	print("  cold  : mount index, partition index, placement walk")
	if deep:
		print("  cold  : surface cache too (splat composite and colour map)")
	else:
		print("  WARM  : surface cache (splat + colour map). A first-ever open "
			+ "pays ~147 s more for these - pass --deep to include them.")
	print("  WARM  : the OS page cache, which nothing here can drop")
	print("  n/a   : bf6_geom, the prop geometry cache - this bench reads the "
		+ "map, it does not build props")
	BJournal.clear()
	var gs = HighpolyGameSource.new()
	gs.surface_cache = cache
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("COLD BENCH FAIL: ", gs.error)
		quit(1)
		return
	print("")
	print("COLD OPEN TOTAL: %.1f s  (%s)"
		% [(Time.get_ticks_msec() - t0) / 1000.0,
			"deep: bake included" if deep else "surface from cache where it exists"])
	for line in gs.phase_report("cold open %s" % map):
		print(line)
	print("")
	print("-- journal, slowest first --")
	for line in BJournal.report(true):
		print(line)
	quit(0)
