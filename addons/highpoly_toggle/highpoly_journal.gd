@tool
extends RefCounted
class_name HighpolyJournal
# THE BUILD JOURNAL - one sink for "what is the plugin actually doing".
#
# The phase table, the profiler and the log each answer part of "why is this
# slow", from different threads, in different formats, and none of them can
# say whether the user was watching a frozen bar while it happened. This is
# the one place every layer reports into, as rows:
#
#   t_ms      session-relative wall time the row was written
#   kind      "phase" (timed work), "ui" (a button press / job queued),
#             "note" (anything worth explaining)
#   label     what ran or what was pressed
#   dur_ms    how long it took (phases only)
#   items     the phase's own count (nodes, meshes, records...)
#   res_kb    KB read from the install's RES payloads DURING the row
#   chunk_kb  KB read from the install's chunks DURING the row
#   reads     read calls during the row (res + chunk)
#   bar_ticks how many times the job bar advanced during the row - a long
#             phase with 0 is exactly "the bar does not represent what is
#             happening", named instead of guessed
#   note      free text (trigger, queue depth, skip reason)
#
# Static + Mutex: rows arrive from the main thread, worker opens and thread
# pool bakes alike. Everything is appended; nothing is dropped until clear().

static var _mx := Mutex.new()
static var _rows: Array = []
static var _t0 := 0
static var _bar_ticks := 0
static var _last_bar_ms := 0
# monotonic read counters, bumped by BF6Source; sampled per phase
static var res_calls := 0
static var res_bytes := 0
static var chunk_calls := 0
static var chunk_bytes := 0


static func _now() -> int:
	if _t0 == 0:
		_t0 = Time.get_ticks_msec()
	return Time.get_ticks_msec() - _t0


static func clear() -> void:
	_mx.lock()
	_rows.clear()
	_t0 = Time.get_ticks_msec()
	_bar_ticks = 0
	_last_bar_ms = 0
	_mx.unlock()


# The job bar moved. Called from the dock whenever the bar's value changes;
# everything else only READS the counter, so phases can say whether the user
# saw progress while they ran.
static func bar_tick() -> void:
	_mx.lock()
	_bar_ticks += 1
	_last_bar_ms = _now()
	_mx.unlock()


# Sample the read counters - callers keep the returned array and hand it to
# phase() so the row carries only ITS OWN reads.
static func mark() -> Array:
	_mx.lock()
	var m := [res_calls, res_bytes, chunk_calls, chunk_bytes, _bar_ticks]
	_mx.unlock()
	return m


# reads/bar-ticks attributed to the PREVIOUS phase boundary when the caller
# does not pass its own mark() - build phases are near-serial, so "since the
# last phase row" is the right default and costs callers nothing. Parallel
# phases smear a little; a caller that cares passes its own mark.
static var _prev := [0, 0, 0, 0, 0]


static func phase(label: String, dur_ms: float, items := 0, note := "",
		since: Array = []) -> void:
	_mx.lock()
	var base := since if since.size() == 5 else _prev
	var rc := res_calls - int(base[0])
	var rb := res_bytes - int(base[1])
	var cc := chunk_calls - int(base[2])
	var cb := chunk_bytes - int(base[3])
	var bt := _bar_ticks - int(base[4])
	_prev = [res_calls, res_bytes, chunk_calls, chunk_bytes, _bar_ticks]
	_rows.append({"t": _now(), "kind": "phase", "label": label,
		"dur": int(dur_ms), "items": items,
		"res_kb": rb / 1024, "chunk_kb": cb / 1024, "reads": rc + cc,
		"bar": bt, "note": note})
	_mx.unlock()


static func event(kind: String, label: String, note := "") -> void:
	_mx.lock()
	_rows.append({"t": _now(), "kind": kind, "label": label, "dur": 0,
		"items": 0, "res_kb": 0, "chunk_kb": 0, "reads": 0, "bar": 0,
		"note": note})
	_mx.unlock()


# The table. `by_cost` sorts phases slowest-first (the bench view); the
# default keeps arrival order (the story view).
static func report(by_cost := false) -> PackedStringArray:
	_mx.lock()
	var rows := _rows.duplicate()
	_mx.unlock()
	if by_cost:
		rows = rows.filter(func(r): return str(r["kind"]) == "phase")
		rows.sort_custom(func(a, b): return int(a["dur"]) > int(b["dur"]))
	var out := PackedStringArray()
	out.append("  t+ms     kind   dur_ms   items    res_KB  chunk_KB reads bar  label / note")
	for r in rows:
		var rd: Dictionary = r
		out.append("%8d %-6s %8d %7d %9d %9d %5d %3d  %s%s" % [
			int(rd["t"]), str(rd["kind"]), int(rd["dur"]), int(rd["items"]),
			int(rd["res_kb"]), int(rd["chunk_kb"]), int(rd["reads"]),
			int(rd["bar"]), str(rd["label"]),
			"" if str(rd["note"]) == "" else "  (%s)" % rd["note"]])
	# the headline finding, computed rather than eyeballed: the longest
	# phase the user sat through with a motionless bar
	var worst := 0
	var worst_label := ""
	for r in rows:
		var rd: Dictionary = r
		if str(rd["kind"]) == "phase" and int(rd["bar"]) == 0 \
				and int(rd["dur"]) > worst:
			worst = int(rd["dur"])
			worst_label = str(rd["label"])
	if worst > 2000:
		out.append("  BAR SILENT: '%s' ran %.1f s with no job-bar movement"
			% [worst_label, worst / 1000.0])
	return out


# Written beside the session logs so a user can send it with one attachment.
static func save(path := "user://highpoly/build_journal.txt") -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	for line in report():
		f.store_line(line)
	f.store_line("")
	f.store_line("-- slowest first --")
	for line in report(true):
		f.store_line(line)
	f.close()
