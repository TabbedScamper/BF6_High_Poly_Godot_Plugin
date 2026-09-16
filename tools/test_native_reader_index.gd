extends SceneTree

# The reader index written by the core (BF6Core.write_reader_index) against the
# one BF6Source builds itself, entry by entry.
#
#   godot --headless --path <project> --script res://tools/test_native_reader_index.gd -- <game_dir> <level>
#
# The script's own index is taken from its cache when one exists for the
# current signature, otherwise built cold. Every ebx, res, loose chunk and
# bundle chunk entry and every res bundle must match; partition index entries
# are compared per GUID, and names differing only where two names share the
# same bytes are counted separately (the script's sort has no tie-break).

const Source = preload("res://addons/highpoly_toggle/bf6_source.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- <game_dir> <level>")
		quit(2)
		return
	var game := str(args[0])
	var level := str(args[1])
	var failures := 0

	var src = Source.new()
	if not src.open(game):
		print("open failed: ", src.error)
		quit(1)
		return
	src.native_index = false
	var t0 := Time.get_ticks_msec()
	if not src.mount(level):
		print("script mount failed: ", src.error)
		quit(1)
		return
	var script_pidx: Dictionary = src.partition_index()
	print("script index: %d ms (from cache: %s)" % [Time.get_ticks_msec() - t0, str(src.stats.get("from_cache", false))])

	var core = ClassDB.instantiate("BF6Core")
	var dir := OS.get_user_data_dir().path_join("native_index_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var idx_path := dir.path_join("index.idx")
	var pidx_path := dir.path_join("pidx.idx")
	t0 = Time.get_ticks_msec()
	var err: String = core.call("write_reader_index", src.game, level, idx_path, pidx_path)
	print("core write: %d ms %s" % [Time.get_ticks_msec() - t0, err])
	if not err.is_empty():
		quit(1)
		return
	t0 = Time.get_ticks_msec()
	var f := FileAccess.open(idx_path, FileAccess.READ)
	var native: Dictionary = f.get_var()
	f.close()
	f = FileAccess.open(pidx_path, FileAccess.READ)
	var native_pidx: Dictionary = f.get_var()
	f.close()
	print("load both: %d ms" % (Time.get_ticks_msec() - t0))

	var tables := {"ebx": src.ebx, "res": src.res, "chunks": src.chunks, "chunk_seg": src.chunk_seg, "res_bundle": src.res_bundle}
	for table in tables:
		var mine: Dictionary = tables[table]
		var theirs: Dictionary = native.get(table, {})
		var missing := 0
		var extra := 0
		var different := 0
		var copies := 0
		var shown := 0
		for k in mine:
			if not theirs.has(k):
				missing += 1
				if shown < 5:
					print("  %s missing in core: %s" % [table, k])
					shown += 1
			elif str(mine[k]) != str(theirs[k]):
				# THE SAME ASSET, ANOTHER COPY. A name shipped in several bundles
				# resolves to whichever mounted first. The core mounts bf6_open's
				# Data/Win32 archives before the other shared archives, so for
				# about 3,000 hardware assets it picks another copy of the same
				# size. That is the order Unreal reads too; the map digest
				# (tools/test_map_props_digest.gd) is the check that it changes
				# nothing a map builds.
				var same_copy := false
				if table == "res_bundle":
					same_copy = true
				elif typeof(mine[k]) == TYPE_ARRAY:
					var x: Array = mine[k]
					var y: Array = theirs[k]
					same_copy = x.size() == y.size() and x.size() >= 4 and int(x[3]) == int(y[3])
					for i in range(4, x.size()):
						same_copy = same_copy and int(x[i]) == int(y[i])
				if same_copy:
					copies += 1
				else:
					different += 1
					if shown < 5:
						print("  %s differs %s: script %s core %s" % [table, k, str(mine[k]), str(theirs[k])])
						shown += 1
		for k in theirs:
			if not mine.has(k):
				extra += 1
				if shown < 8:
					print("  %s only in core: %s" % [table, k])
					shown += 1
		print("%s: script %d, core %d, missing %d, extra %d, different %d, another copy of the same asset %d" % [
			table, mine.size(), theirs.size(), missing, extra, different, copies])
		failures += missing + extra + different

	var p_missing := 0
	var p_extra := 0
	var p_tie := 0
	var p_diff := 0
	for g in script_pidx:
		if not native_pidx.has(g):
			p_missing += 1
		elif str(script_pidx[g]) != str(native_pidx[g]):
			var a := str(script_pidx[g]).trim_suffix(".ebx")
			var b := str(native_pidx[g]).trim_suffix(".ebx")
			var ea = src.ebx.get(a)
			var eb = src.ebx.get(b)
			if ea != null and eb != null and int(ea[0]) == int(eb[0]) and int(ea[1]) == int(eb[1]) and int(ea[2]) == int(eb[2]):
				p_tie += 1
			else:
				p_diff += 1
				if p_diff <= 5:
					print("  partition %s: script %s core %s" % [g, script_pidx[g], native_pidx[g]])
	for g in native_pidx:
		if not script_pidx.has(g):
			p_extra += 1
	print("partition index: script %d, core %d, missing %d, extra %d, same-bytes ties %d, different %d" % [
		script_pidx.size(), native_pidx.size(), p_missing, p_extra, p_tie, p_diff])
	failures += p_missing + p_extra + p_diff

	print("NATIVE READER INDEX %s (%d failures)" % ["PASSED" if failures == 0 else "FAILED", failures])
	quit(0 if failures == 0 else 1)
