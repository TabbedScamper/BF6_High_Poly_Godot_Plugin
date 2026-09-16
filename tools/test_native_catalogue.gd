extends SceneTree
# The all-levels object catalogue written by the core (BF6Core.write_catalogue_index,
# used by BF6Source.mount_rest) against the one the script sweeps itself.
#   -- <install> <level>
# Same rules as test_native_reader_index.gd: identical keys, sizes and types;
# a different same-size copy of a duplicated asset is counted, not failed.
const SourceScript = preload("res://addons/highpoly_toggle/bf6_source.gd")


func _init() -> void:
	call_deferred("_run")


func _tables(src) -> Dictionary:
	return {"ebx": src.ebx, "res": src.res, "chunks": src.chunks, "chunk_seg": src.chunk_seg, "res_bundle": src.res_bundle}


func _mounted(game: String, level: String, native: bool) -> Array:
	var src = SourceScript.new()
	if not src.open(game):
		return [null, 0]
	src.native_index = native
	if not src.mount(level):
		return [null, 0]
	# A fresh catalogue each time: no cached all-levels file may answer.
	var path: String = src._cache_path_scoped(level, src.signature(), true)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var t0 := Time.get_ticks_msec()
	var ok: bool = src.mount_rest(Callable(), true)
	var ms := Time.get_ticks_msec() - t0
	return [src if ok else null, ms]


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var game := str(a[0])
	var level := str(a[1])
	var n: Array = _mounted(game, level, true)
	var s: Array = _mounted(game, level, false)
	if n[0] == null or s[0] == null:
		print("NATIVE CATALOGUE FAILED: a mount did not complete")
		quit(1)
		return
	print("catalogue: core %d ms, script %d ms" % [n[1], s[1]])
	var failures := 0
	var mine: Dictionary = _tables(s[0])
	var theirs: Dictionary = _tables(n[0])
	for table in mine:
		var x: Dictionary = mine[table]
		var y: Dictionary = theirs[table]
		var missing := 0
		var extra := 0
		var different := 0
		var copies := 0
		for k in x:
			if not y.has(k):
				missing += 1
			elif str(x[k]) != str(y[k]):
				var same: bool = table == "res_bundle"
				if x[k] is Array:
					var xa: Array = x[k]
					var ya: Array = y[k]
					same = xa.size() == ya.size() and xa.size() >= 4 and int(xa[3]) == int(ya[3])
					for i in range(4, xa.size()):
						same = same and int(xa[i]) == int(ya[i])
				if same:
					copies += 1
				else:
					different += 1
		for k in y:
			if not x.has(k):
				extra += 1
		print("%s: script %d, core %d, missing %d, extra %d, different %d, another copy %d" % [table, x.size(), y.size(), missing, extra, different, copies])
		failures += missing + extra + different
	print("NATIVE CATALOGUE %s (%d failures)" % ["PASSED" if failures == 0 else "FAILED", failures])
	quit(0 if failures == 0 else 1)
