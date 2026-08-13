extends SceneTree
# The decision trace's plumbing, without needing a game install or a build.
#
# What this can prove: that decide() dedupes on the material state rather than
# per instance, that it is safe to call from several threads (the walk resolves
# meshes on workers), and that flush_decisions writes one valid JSON object per
# line where the query tools look for it.
#
# What it cannot prove: that the RULES are right. That is what explain.py and
# golden.py are for, against a real build.

const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")

var fails := 0

func _fail(what: String) -> void:
	fails += 1
	print("FAIL  %s" % what)

func _ok(what: String) -> void:
	print("ok    %s" % what)


func _init() -> void:
	print("=== decision trace ===")
	var gs = GS.new()

	var rules := [{"r": "uv.primary", "in": {"family": "carpaint"},
		"out": "tc0", "why": "reader rule carpaint.tc0"}]
	gs.decide("mesh_a", 0x1234, 0, 0, "M_CarPaint", rules)
	# The same material state reached again by another instance must NOT add a
	# row. This is the whole reason a map is a few thousand rows and not a
	# few hundred thousand.
	gs.decide("mesh_a", 0x1234, 0, 0, "M_CarPaint", rules)
	if gs.decision_count() == 1:
		_ok("a repeat of the same (mesh, state, var, surface) is deduped")
	else:
		_fail("dedupe failed: %d rows for one state" % gs.decision_count())

	# Each part of the key must be part of the identity.
	gs.decide("mesh_a", 0x1234, 0, 1, "M_CarPaint", rules)     # other surface
	gs.decide("mesh_a", 0x1234, 99, 0, "M_CarPaint", rules)    # other variation
	gs.decide("mesh_a", 0x9999, 0, 0, "M_CarPaint", rules)     # other state
	gs.decide("mesh_b", 0x1234, 0, 0, "M_CarPaint", rules)     # other mesh
	if gs.decision_count() == 5:
		_ok("surface, variation, state and mesh are each part of the identity")
	else:
		_fail("expected 5 distinct rows, got %d" % gs.decision_count())

	# Worker threads: the walk resolves meshes off the main thread, so a
	# corrupted array here would be a crash in the field, not a test failure.
	var tasks := []
	for t in range(4):
		tasks.append(WorkerThreadPool.add_task(_hammer.bind(gs, t)))
	for id in tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	if gs.decision_count() == 5 + 4 * 50:
		_ok("205 rows after 4 threads x 50 distinct states, no loss")
	else:
		_fail("threaded writes lost or duplicated rows: %d, expected %d"
			% [gs.decision_count(), 5 + 4 * 50])

	# ---- the file ----
	var path: String = gs.flush_decisions("MP_TestMap")
	if path == "":
		_fail("flush_decisions wrote nothing")
		_done()
		return
	if path != "user://mapcontext/MP_TestMap/decisions.jsonl":
		_fail("wrote to %s, which is not where the query tools look" % path)
	else:
		_ok("wrote to the path hp.py and explain.py read")

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_fail("the file it reported is not readable")
		_done()
		return
	var text := f.get_as_text()
	f.close()
	var lines := text.split("\n", false)
	if lines.size() != gs.decision_count():
		_fail("%d lines for %d rows" % [lines.size(), gs.decision_count()])
	else:
		_ok("one line per row")

	var bad := 0
	var keys := {}
	for ln in lines:
		var v = JSON.parse_string(ln)
		if not (v is Dictionary):
			bad += 1
			continue
		var row: Dictionary = v
		for k in ["key", "mesh", "state", "var", "surface", "material", "rules"]:
			if not row.has(k):
				bad += 1
				break
		keys[str(row.get("key", ""))] = true
	if bad > 0:
		_fail("%d line(s) are not a complete decision object" % bad)
	else:
		_ok("every line parses and carries the full envelope")
	if keys.size() != lines.size():
		_fail("duplicate keys reached the file")
	else:
		_ok("every key in the file is distinct")

	# The state key must be readable back as hex. It is the join to the depot,
	# and a %d here would silently break every downstream tool.
	var first = JSON.parse_string(lines[0])
	var st := str((first as Dictionary).get("state", ""))
	if not st.begins_with("0x") or st.length() != 18:
		_fail("state key is not 0x + 16 hex digits: %s" % st)
	else:
		_ok("state key is written as %s, which is what the depot join needs" % st)

	_done()


func _hammer(gs, t: int) -> void:
	for i in range(50):
		gs.decide("mesh_t%d" % t, 0x10000 + i, 0, 0, "M_Thread", [])


func _done() -> void:
	print("=== %s ===" % ("PASSED" if fails == 0 else "%d FAILURE(S)" % fails))
	quit(1 if fails > 0 else 0)
