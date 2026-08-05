extends SceneTree

# A recording must survive the process dying. That is not a nice-to-have: a
# session reached the lighting layer, crashed, and left NOTHING — no samples,
# no events, no last phase — because everything lived in memory until Stop.
#
# So: start a recording, let it collect, and read the files back WITHOUT ever
# calling stop(). Whatever is on disk at that moment is exactly what a crash
# would leave behind.

const P = preload("res://addons/highpoly_toggle/highpoly_profiler.gd")

var fails := 0


class FakeSync extends Node:
	func stats() -> Dictionary:
		return {"queued": 3, "active": 1, "done": 7, "failed": 0, "bytes": 1048576,
			"transfer_ms": 10, "workers": 1, "max_workers": 16,
			"paused": false, "bootstrapping": false}


func _init() -> void:
	await process_frame
	var prof: Node = P.new()
	root.add_child(prof)
	var fs := FakeSync.new()
	root.add_child(fs)
	prof.sync = fs
	prof.state_provider = func() -> Dictionary: return {"map_context": "on"}

	# clear the folder so we can be sure what this run produced
	var dir := "user://highpoly"
	DirAccess.make_dir_recursive_absolute(dir)
	var da := DirAccess.open(dir)
	for f in da.get_files():
		if f.begins_with("perf-"):
			DirAccess.remove_absolute(dir + "/" + f)

	prof.start()
	prof.event("phase", "pretending to build the lighting layer")
	for i in range(10):
		await create_timer(0.25).timeout

	# --- read the files back while STILL RECORDING (i.e. as a crash would) ---
	var samples := ""
	var events := ""
	da = DirAccess.open(dir)
	for f in da.get_files():
		if f.ends_with("-events.csv"):
			events = FileAccess.get_file_as_string(dir + "/" + f)
		elif f.begins_with("perf-") and f.ends_with(".csv") and not f.ends_with("-owners.csv"):
			samples = FileAccess.get_file_as_string(dir + "/" + f)

	var srows := samples.split("\n", false).size() - 1     # minus header
	var erows := events.split("\n", false).size() - 1
	print("mid-recording, on disk: %d sample row(s), %d event row(s)" % [srows, erows])

	_check("samples are on disk before stop() was ever called", srows > 0)
	_check("events are on disk too", erows > 0)
	_check("the header is there", samples.begins_with("t,fps,ms,"))
	_check("the injected phase marker survived", events.contains("lighting layer"))
	_check("the state change survived", events.contains("map_context"))

	# and stop() must still finish cleanly rather than double-writing
	var msg: String = prof.stop()
	var after := FileAccess.get_file_as_string(dir + "/" + _samples_name(dir))
	var arows := after.split("\n", false).size() - 1
	print("after stop(): %d sample row(s)  —  %s" % [arows, msg.left(60)])
	_check("stop() did not duplicate the rows", arows >= srows and arows < srows * 2)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _samples_name(dir: String) -> String:
	var da := DirAccess.open(dir)
	for f in da.get_files():
		if f.begins_with("perf-") and f.ends_with(".csv") \
				and not f.ends_with("-owners.csv") and not f.ends_with("-events.csv"):
			return f
	return ""


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
