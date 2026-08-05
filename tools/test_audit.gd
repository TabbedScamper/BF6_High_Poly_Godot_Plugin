extends SceneTree

# The diagnostics themselves, tested. An instrument that silently records
# nothing is worse than none, because it converts "we do not know" into "we
# looked and there was nothing there" — which has already happened twice here:
# a texture counter that read 0 on a scene full of textures, and a session log
# that stopped at its own header after the editor died mid-build.
#
# Three things have to hold:
#   1. BREADCRUMBS survive a crash. They are written outside any recording, they
#      flush per line, and a session that never wrote its clean-exit marker is
#      reported as such on the next start.
#   2. PROGRESS LANES are captured wherever they are opened and closed, and a
#      lane left open is called out rather than quietly averaged away.
#   3. SPAN GROWTH separates work that is merely expensive from work that gets
#      worse as the scene fills up — the shape behind "the panel slows down the
#      more you have loaded".

const Prof = preload("res://addons/highpoly_toggle/highpoly_profiler.gd")
const Jobs = preload("res://addons/highpoly_toggle/highpoly_jobs.gd")

var fails := 0


func _init() -> void:
	await process_frame

	# ---- 1. breadcrumbs --------------------------------------------------
	# a previous session that died: crumbs written, no clean-exit marker
	DirAccess.make_dir_recursive_absolute(Prof.CRUMB_DIR)
	var f := FileAccess.open(Prof.CRUMB_PATH, FileAccess.WRITE)
	f.store_line("   1.00 main props                  at 900/2761  some_prop")
	f.store_line("   1.20 wrkr prefetch               dispatch 48 files")
	f.close()

	var prof = Prof.new()
	get_root().add_child(prof)      # _ready rotates and reopens
	await process_frame

	var last: String = Prof.last_session_end()
	_check("a session with no clean-exit marker is reported as a crash",
		last != "")
	_check("and the report names the last thing it was doing",
		last.contains("prefetch") or last.contains("props"))

	Prof.crumb("test", "a crumb written with nothing recording")
	_check("crumbs are written outside any recording",
		FileAccess.get_file_as_string(Prof.CRUMB_PATH).contains("nothing recording"))
	_check("and are flushed immediately, not at exit",
		FileAccess.get_file_as_string(Prof.CRUMB_PATH).contains("test"))

	Prof.crumbs_end()
	_check("a clean exit writes its marker",
		FileAccess.get_file_as_string(Prof.CRUMB_PATH).contains(Prof.CRUMB_CLEAN))
	# and that marker is what stops the NEXT session crying crash
	var f2 := FileAccess.open(Prof.CRUMB_PREV, FileAccess.WRITE)
	f2.store_line("   1.00 main session                started")
	f2.store_line("   2.00 main session                " + Prof.CRUMB_CLEAN)
	f2.close()
	_check("a clean previous session is NOT reported as a crash",
		Prof.last_session_end() == "")

	# ---- 2. progress lanes ----------------------------------------------
	prof.recording = true
	prof._t0 = Time.get_ticks_msec() / 1000.0
	var jobs = Jobs.new()
	get_root().add_child(jobs)

	jobs.set_activity("Lane A", 1, 10)
	jobs.set_activity("Lane B", 1, 10)
	jobs.set_activity("Lane A", 5, 10)          # progress, not a second open
	_check("two concurrent lanes are both recorded", Prof._lanes.size() >= 2)
	_check("the overlap is noticed", Prof._lane_peak >= 2)
	_check("progress does not count as re-opening a lane",
		int(Prof._lanes["Lane A"]["opens"]) == 1)

	jobs.clear_activity("Lane A")
	_check("closing a lane records it as closed", not Prof._lane_live.has("Lane A"))
	_check("and the other one stays open", Prof._lane_live.has("Lane B"))

	var report: String = "\n".join(prof._lane_report())
	_check("the report calls out the lane still open",
		report.contains("STILL OPEN"))
	_check("and does not accuse the closed one", report.contains("Lane A"))

	# ---- 3. span growth --------------------------------------------------
	# a job that costs the same every time, and one that gets steadily worse
	Prof._spans.clear()
	for i in range(60):
		prof._t0 = Time.get_ticks_msec() / 1000.0 - float(i) * 4.0   # walk time forward
		Prof.span("steady job", 5.0)
		Prof.span("growing job", 1.0 + float(i) * 0.5)
	var keys: Array = Prof._spans.keys()
	var g: String = "\n".join(prof._growth_report(keys))
	_check("the growth table appears once there is enough history",
		g.contains("DID IT GET WORSE"))
	_check("a job that gets worse is flagged", g.contains("WORSE"))
	_check("both jobs are listed", g.contains("growing job") and g.contains("steady job"))

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
