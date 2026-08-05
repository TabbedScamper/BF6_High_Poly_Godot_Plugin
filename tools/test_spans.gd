extends SceneTree

# The TIME BY PHASE table is the one thing that will be read first, so it has to
# rank correctly, total correctly, and be a no-op when nothing is recording —
# because these calls now sit in the hot build loop permanently.

const P = preload("res://addons/highpoly_toggle/highpoly_profiler.gd")

var fails := 0


class FakeSync extends Node:
	func stats() -> Dictionary:
		return {"queued": 0, "active": 0, "done": 0, "failed": 0, "bytes": 0,
			"transfer_ms": 0, "workers": 0, "max_workers": 16,
			"paused": false, "bootstrapping": false}


func _init() -> void:
	await process_frame

	# not recording yet: these must be silently ignored, not accumulated
	P.span("ghost", 5000.0)
	P.mark("phase", "should not appear")

	var prof: Node = P.new()
	root.add_child(prof)
	prof.sync = FakeSync.new()
	root.add_child(prof.sync)
	prof.start()

	# a few calls of a big cost vs many calls of a small one: both shapes have
	# to be distinguishable in the output
	for i in range(3):
		P.span("one big blocking step", 2000.0)
	for i in range(500):
		P.span("many tiny steps", 4.0)
	P.span("a middling step", 900.0)
	P.mark("phase", "halfway marker")

	for i in range(6):
		await create_timer(0.25).timeout
	prof.stop()
	var rep: String = prof.call("_summarise")
	print(rep)

	_check("has the phase table", rep.contains("TIME BY PHASE"))
	_check("ranks the biggest first",
		rep.find("one big blocking step") < rep.find("many tiny steps"))
	_check("keeps the call count (500)", rep.contains("500"))
	_check("shows per-call cost so shape is visible", rep.contains("4.0ms"))
	_check("pre-recording spans were dropped", not rep.contains("ghost"))
	_check("pre-recording marks were dropped", not rep.contains("should not appear"))
	_check("kept the mark made while recording", rep.contains("halfway marker"))
	_check("no format leftovers", not rep.contains("%d") and not rep.contains("%.1f"))

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
