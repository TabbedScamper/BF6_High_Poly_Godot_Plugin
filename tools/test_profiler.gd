extends SceneTree

# Drive the recorder for real: fake a sync manager whose counters climb, let the
# sampler tick, then stop and read the report. Every line of the download and
# timeline reporting is new code that has never executed, and a parse check
# cannot tell whether it divides by zero on the first sample or prints nonsense.

const P = preload("res://addons/highpoly_toggle/highpoly_profiler.gd")


class FakeSync extends Node:
	var mb := 0.0
	var done := 0
	var active := 0
	var queued := 40
	var failed := 0
	var calls := 0

	func stats() -> Dictionary:
		# ~6 MB and 3 files per call, so the rate maths has something to chew on
		mb += 6.0
		done += 3
		calls += 1
		# failures must ACCUMULATE during the run: reporting a constant is how a
		# first version of this test wrongly accused the report of missing them,
		# when a zero delta over the window is the right answer.
		if calls % 7 == 0:
			failed += 1
		queued = maxi(0, queued - 3)
		active = 4 if queued > 0 else 0
		return {"queued": queued, "active": active, "done": done, "failed": failed,
			"bytes": int(mb * 1048576.0), "transfer_ms": done * 300,
			"workers": active, "max_workers": 16, "paused": false,
			"bootstrapping": false}


var fails := 0


func _init() -> void:
	await process_frame
	var prof: Node = P.new()
	root.add_child(prof)
	var fs := FakeSync.new()
	root.add_child(fs)
	prof.sync = fs

	var toggles := {"map_context": "off", "lighting": "off", "models_local": 0}
	prof.state_provider = func() -> Dictionary: return toggles

	print(prof.start())

	# let the 0.25 s sampler run, flipping a toggle part way so a state CHANGE
	# has to be detected, and injecting a marker
	for i in range(24):
		await create_timer(0.25).timeout
		if i == 8:
			toggles["map_context"] = "on"
			toggles["models_local"] = 219
		if i == 14:
			toggles["lighting"] = "on"
			prof.event("phase", "building the map context overlay")

	var msg: String = prof.stop()
	print("\n--- stop() said ---\n%s" % msg)

	var rep := ""
	if prof.has_method("_summarise"):
		rep = prof.call("_summarise")
	print("\n--- report ---\n%s" % rep)

	_check("recorded samples", rep.contains("PERFORMANCE"))
	_check("has a DOWNLOADS section", rep.contains("DOWNLOADS"))
	_check("reports a MB/s rate", rep.contains("MB/s"))
	_check("has a TIMELINE", rep.contains("TIMELINE"))
	_check("caught the map_context toggle", rep.contains("map_context"))
	_check("caught the injected phase marker", rep.contains("building the map context"))
	_check("reports peaks", rep.contains("PEAKS"))
	_check("notes the failed download", rep.contains("FAILED") or rep.contains("failed"))
	_check("no formatting leftovers", not rep.contains("%d") and not rep.contains("%.2f"))

	var dir := "user://highpoly"
	var found := {"samples": false, "events": false}
	var da := DirAccess.open(dir)
	if da != null:
		for fn in da.get_files():
			if fn.ends_with("-events.csv"): found["events"] = true
			elif fn.begins_with("perf-") and fn.ends_with(".csv") and not fn.ends_with("-owners.csv"):
				found["samples"] = true
	_check("wrote a samples csv", bool(found["samples"]))
	_check("wrote an events csv", bool(found["events"]))

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
