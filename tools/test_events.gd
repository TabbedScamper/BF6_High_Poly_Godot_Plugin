extends SceneTree
# Does the machine-readable sink actually WORK, and is it readable while the
# writer still holds the file open?
#
# That second half is the whole point. Godot's FileAccess in WRITE mode writes
# through a sibling .tmp and renames on close, so the session log has always
# been the PREVIOUS session while the editor runs (law C11) and every
# diagnosis cost a quit-and-paste. The event stream dodges it by opening
# READ_WRITE on a file that already exists. If that ever regresses, the stream
# silently becomes as useless as the log it replaced, so the test asserts it
# by READING THE FILE BACK from a separate handle mid-session.
#
# Run: godot --headless --path <proj> --script res://addons/highpoly_toggle/../tools/test_events.gd

const Log = preload("res://addons/highpoly_toggle/highpoly_log.gd")

var fails := 0

func _fail(what: String) -> void:
	fails += 1
	print("FAIL  %s" % what)

func _ok(what: String) -> void:
	print("ok    %s" % what)


func _init() -> void:
	print("=== event stream + state snapshot ===")

	Log.event("test.first", {"n": 1})
	Log.event("test.second", {"n": 2, "s": "two"}, Log.Level.WARN, "cid:7")
	Log.warn("a warning that should route itself into the stream")

	# THE LOAD-BEARING ASSERTION: read it back NOW, with the writer's handle
	# still open and no clean exit anywhere in sight.
	var f := FileAccess.open(Log.EVENTS_PATH, FileAccess.READ)
	if f == null:
		_fail("events.jsonl is not readable while the writer holds it open "
			+ "(this is the whole reason the stream exists)")
		quit(1)
		return
	var raw := f.get_as_text()
	f.close()
	var lines := raw.split("\n", false)
	if lines.size() < 4:
		_fail("expected at least 4 lines (session.start + 3), got %d"
			% lines.size())
	else:
		_ok("%d lines readable mid-session" % lines.size())

	var seen := {}
	var seq_last := 0
	for ln in lines:
		var v = JSON.parse_string(ln)
		if not (v is Dictionary):
			_fail("line is not a JSON object: %s" % ln.substr(0, 80))
			continue
		var row: Dictionary = v
		for k in ["t", "unix", "sess", "seq", "lvl", "ev", "cid", "d"]:
			if not row.has(k):
				_fail("line is missing the '%s' field: %s" % [k, ln.substr(0, 80)])
		seen[str(row.get("ev", ""))] = row
		# Sequence numbers must be strictly increasing or two writers are
		# interleaving and the order cannot be trusted.
		var sq := int(row.get("seq", 0))
		if sq <= seq_last:
			_fail("sequence went backwards: %d after %d" % [sq, seq_last])
		seq_last = sq

	for want in ["session.start", "test.first", "test.second", "log.warn"]:
		if seen.has(want):
			_ok("event %s present" % want)
		else:
			_fail("event %s missing (routing is broken)" % want)

	if seen.has("test.second"):
		var r: Dictionary = seen["test.second"]
		if str(r.get("cid", "")) != "cid:7":
			_fail("correlation id was dropped")
		elif int((r.get("d", {}) as Dictionary).get("n", 0)) != 2:
			_fail("payload was dropped")
		else:
			_ok("payload and correlation id survive the round trip")

	# ---- the state snapshot ----
	Log.write_state({"map": {"name": "MP_Test"}, "build": {"state": "idle"}})
	var sf := FileAccess.open(Log.STATE_PATH, FileAccess.READ)
	if sf == null:
		_fail("state.json was not written")
	else:
		var sv = JSON.parse_string(sf.get_as_text())
		sf.close()
		if not (sv is Dictionary):
			_fail("state.json is not a JSON object")
		else:
			var s: Dictionary = sv
			# The caller's keys and the writer's own must both survive: the
			# merge order is the thing that breaks silently.
			if not s.has("schema") or not s.has("counts"):
				_fail("state.json lost the writer's own fields")
			elif str((s.get("map", {}) as Dictionary).get("name", "")) != "MP_Test":
				_fail("state.json lost the caller's fields")
			else:
				_ok("state.json carries both the caller's and the writer's fields")
			if int((s.get("counts", {}) as Dictionary).get("warns", 0)) < 1:
				_fail("state.json did not pick up the warning count")
			else:
				_ok("state.json reports the live warning count")

	# A second write must REPLACE, never append or leave the temp behind.
	Log.write_state({"map": {"name": "MP_Second"}})
	if FileAccess.file_exists(Log.STATE_PATH + ".new"):
		_fail("the state temp file was left on disk")
	else:
		_ok("the state write leaves no temp behind")

	print("=== %s ===" % ("PASSED" if fails == 0 else "%d FAILURE(S)" % fails))
	quit(1 if fails > 0 else 0)
