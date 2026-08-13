@tool
extends RefCounted
class_name HighpolyLog
# What the plugin has been doing, and everything that went wrong doing it.
#
# Static on purpose: a download deep inside the map-context code has to be able
# to record a failure without anyone having threaded a reference down to it, and
# the alternative — returning error strings up through six layers of async
# calls — is how failures end up silently dropped instead.
#
# Errors and warnings also go to Godot's own Output panel, so nothing is hidden
# from someone who already knows to look there. The point of keeping our own
# copy is the Save button: a user who hits a problem can hand over one file that
# already says which version, which map and which step, instead of a screenshot
# of a red line with no context.

enum Level { DEBUG, INFO, WARN, ERROR }

const MAX_LINES := 800     # ring buffer for the PANEL only; the file keeps all
const SAVE_DIR := "user://"
const SESSION_LOG := "user://highpoly-session.log"
const VERBOSE_SETTING := "highpoly/verbose_log"

static var _lines: Array = []
static var _errors := 0
static var _warnings := 0
static var _on_line: Callable = Callable()
# Write-through file handle. The old log only existed in memory until Save was
# pressed, so the two failures worth diagnosing — a hang and a run that quietly
# did nothing — left no evidence at all. Every line now hits disk as it happens.
static var _fh: FileAccess = null
static var _since_flush := 0
static var _verbose := false
static var _verbose_loaded := false


static func verbose() -> bool:
	if not _verbose_loaded:
		_verbose_loaded = true
		if ProjectSettings.has_setting(VERBOSE_SETTING):
			_verbose = bool(ProjectSettings.get_setting(VERBOSE_SETTING))
	return _verbose


static func set_verbose(v: bool) -> void:
	_verbose = v
	_verbose_loaded = true
	ProjectSettings.set_setting(VERBOSE_SETTING, v)
	ProjectSettings.save()
	info("verbose logging %s" % ("ON" if v else "off"))


# When this editor session started logging, as wall-clock. Compared against the
# plugin files on disk so a log can say it is describing code that is no longer
# there. See _staleness().
static var _session_at := 0


static func _open_session() -> void:
	if _fh != null:
		return
	_session_at = int(Time.get_unix_time_from_system())
	# truncate per editor session: one file, always the current run
	_fh = FileAccess.open(SESSION_LOG, FileAccess.WRITE)
	if _fh != null:
		_fh.store_string(header() + "\n")
		_fh.flush()


# The panel registers here so new lines appear as they happen. Cleared on
# teardown so a freed dock can never be called into.
static func hook(cb: Callable) -> void:
	_on_line = cb

static func _add(lvl: int, msg: String) -> void:
	if lvl == Level.DEBUG and not verbose():
		return
	var stamp := Time.get_time_string_from_system()
	var row := {"t": stamp, "lvl": lvl, "m": msg}
	_lines.append(row)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
	if lvl == Level.ERROR:
		_errors += 1
		push_error("[High-Poly] " + msg)
	elif lvl == Level.WARN:
		_warnings += 1
		push_warning("[High-Poly] " + msg)
	_open_session()
	if _fh != null:
		_fh.store_string("%s  %s  %s\n" % [stamp, _tag(lvl), msg])
		# errors flush immediately (the next thing may be a crash); routine
		# lines batch, or a busy download loop would fsync per model
		_since_flush += 1
		if lvl >= Level.WARN or _since_flush >= 20:
			_fh.flush()
			_since_flush = 0
	# Route what already exists rather than adding a second instrument (law C8):
	# every warning and error is also an event, so an outside reader gets the
	# failures without scraping prose. Info lines stay out of the stream - they
	# are narration, and the events that matter are emitted deliberately.
	if lvl >= Level.WARN:
		event("log." + _tag(lvl).strip_edges().to_lower(), {"m": msg}, lvl)
	if _on_line.is_valid():
		_on_line.call(lvl, msg)

static func debug(msg: String) -> void: _add(Level.DEBUG, msg)
static func info(msg: String) -> void: _add(Level.INFO, msg)
static func warn(msg: String) -> void: _add(Level.WARN, msg)
static func error(msg: String) -> void: _add(Level.ERROR, msg)


# ---------- measuring, not guessing ----------
# "took forever" is not a diagnosis. Every unit of work that can be slow should
# say how long it took and how big it was, so a slow run names its own cause.
static func started(what: String) -> int:
	debug("> %s" % what)
	return Time.get_ticks_msec()


static func finished(what: String, t0: int, detail := "") -> void:
	var ms := Time.get_ticks_msec() - t0
	var s := "< %s in %s" % [what, human_ms(ms)]
	if detail != "":
		s += " (%s)" % detail
	if ms >= 10000:
		info(s)              # anything over 10 s is worth seeing without verbose
	else:
		debug(s)


static func human_ms(ms: int) -> String:
	if ms < 1000: return "%d ms" % ms
	if ms < 60000: return "%.1f s" % (ms / 1000.0)
	return "%d m %02d s" % [ms / 60000, (ms / 1000) % 60]


static func human_bytes(n: int) -> String:
	if n < 1024: return "%d B" % n
	if n < 1048576: return "%.0f KB" % (n / 1024.0)
	if n < 1073741824: return "%.1f MB" % (n / 1048576.0)
	return "%.2f GB" % (n / 1073741824.0)

# Record a Godot Error code with its meaning spelled out — "error 7" in a
# user-sent log is worth almost nothing on its own.
static func err_code(what: String, code: int) -> void:
	error("%s: %s (code %d)" % [what, error_string(code), code])

# Force the write-through buffer to disk. Routine lines batch twenty at a time,
# which is right for a busy loop and wrong for the moment before a freeze: the
# last thing written before an editor is force-quit is exactly the line that
# says where it froze.
static func flush() -> void:
	if _fh != null:
		_fh.flush()
		_since_flush = 0


# IS THIS LOG DESCRIBING CODE THAT IS STILL ON DISK?
#
# Godot loads plugin scripts once, at editor start. Update the plugin while the
# editor is open and every line written afterwards describes the OLD code, with
# nothing to say so - the log is byte-identical to one from before the update,
# same timestamps, same behaviour, and it reads as "the fix did not work".
#
# That has cost three rounds of diagnosis on this project alone: a fix deployed
# at 18:25 against a session that opened at 18:18, and a log full of the
# behaviour it had already fixed.
#
# Returns "" when the running code is current.
static func _staleness() -> String:
	if _session_at == 0:
		return ""
	var dir := "res://addons/highpoly_toggle"
	var newest := 0
	var name := ""
	for f in DirAccess.get_files_at(dir):
		if not str(f).ends_with(".gd"):
			continue
		var mt := int(FileAccess.get_modified_time("%s/%s" % [dir, f]))
		if mt > newest:
			newest = mt
			name = str(f)
	# A minute of slack: the plugin logs its first line a moment after the files
	# it was loaded from were read, and a deploy that lands in that window is the
	# one being tested rather than a stale one.
	if newest <= _session_at + 60:
		return ""
	return ("THE PLUGIN ON DISK IS NEWER THAN THE ONE RUNNING. %s was written\n"
		% name
		+ "           %s, after this editor session started at %s.\n"
			% [Time.get_datetime_string_from_unix_time(newest, true),
			   Time.get_datetime_string_from_unix_time(_session_at, true)]
		+ "           Godot loads plugin scripts once, at editor start, so\n"
		+ "           everything below describes the OLDER code. Restart the\n"
		+ "           editor before reading this as evidence of anything.")


# ---------------------------------------------------------------------------
# THE MACHINE-READABLE HALF OF THE LOG
#
# WHY IT EXISTS BESIDE THE TEXT LOG. Godot's FileAccess in WRITE mode writes
# through a sibling `.tmp` and renames on close, so while the editor is
# RUNNING the file at `user://highpoly-session.log` is the PREVIOUS session
# (law C11). Everything this plugin knows was therefore unreadable until the
# editor was quit, and every diagnosis cost a quit-and-paste round trip.
#
# The dodge is the open mode: READ_WRITE opens the real path in place (no
# `.tmp`), so a line flushed here is on disk and readable by an outside tool
# immediately. `tools/hp.py log` tails it.
#
# It lives in this class rather than a new one deliberately: it holds mutable
# statics, and law C4 says those must sit behind an existing `class_name` - a
# brand new global class does not register until the editor is restarted,
# which is exactly the moment this stream is meant to save us.
#
# The stream is COARSE on purpose: phases, jobs, picks, swaps, failures. Per
# section decisions are far too many to flush per line and go to the build's
# own `decisions.jsonl` sidecar instead.
const EVENTS_DIR := "user://highpoly"
const EVENTS_PATH := "user://highpoly/events.jsonl"
const EVENTS_PREV := "user://highpoly/events-prev.jsonl"
const STATE_PATH := "user://highpoly/state.json"

static var _ev_fh: FileAccess = null
static var _ev_seq := 0
static var _ev_sess := ""
static var _ev_t0 := 0
static var _ev_failed := false     # one complaint, not one per line


static func plugin_version() -> String:
	var cf := ConfigFile.new()
	if cf.load("res://addons/highpoly_toggle/plugin.cfg") == OK:
		return str(cf.get_value("plugin", "version", "?"))
	return "?"


static func session_id() -> String:
	if _ev_sess == "":
		# Enough to tell two sessions apart in a file, not a security token.
		_ev_sess = "%08x" % (int(Time.get_unix_time_from_system()) ^ (randi() << 8))
	return _ev_sess


static func _ev_open() -> void:
	if _ev_fh != null or _ev_failed:
		return
	_ev_t0 = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(EVENTS_DIR)
	# Last session rolls aside whole. A crash leaves its stream intact, which
	# is the case worth keeping: it ends exactly where the editor died.
	if FileAccess.file_exists(EVENTS_PATH):
		if FileAccess.file_exists(EVENTS_PREV):
			DirAccess.remove_absolute(EVENTS_PREV)
		DirAccess.rename_absolute(EVENTS_PATH, EVENTS_PREV)
	# Create it in WRITE (which is where the .tmp dance happens) and close, so
	# that READ_WRITE below has a real file to open in place.
	var mk := FileAccess.open(EVENTS_PATH, FileAccess.WRITE)
	if mk == null:
		_ev_failed = true
		return
	mk.close()
	_ev_fh = FileAccess.open(EVENTS_PATH, FileAccess.READ_WRITE)
	if _ev_fh == null:
		_ev_failed = true
		return
	_ev_fh.seek_end()
	event("session.start", {
		"plugin": plugin_version(),
		"godot": Engine.get_version_info().get("string", ""),
		"stale": _staleness() != "",
	})


# One JSON object per line: {t, unix, sess, seq, lvl, ev, cid, d}.
#   ev  a dotted name, queried by PREFIX ("build." matches every build event)
#   cid a correlation id tying a burst together ("build:7"), "" when none
#   d   the payload, whatever this event is actually reporting
static func event(ev: String, d: Dictionary = {}, lvl := Level.INFO,
		cid := "") -> void:
	if _ev_fh == null:
		_ev_open()
		if _ev_fh == null:
			return
	_ev_seq += 1
	var row := {
		"t": snappedf((Time.get_ticks_msec() - _ev_t0) / 1000.0, 0.01),
		"unix": int(Time.get_unix_time_from_system()),
		"sess": session_id(),
		"seq": _ev_seq,
		"lvl": _tag(lvl).strip_edges(),
		"ev": ev,
		"cid": cid,
		"d": d,
	}
	# Flushed per line on purpose: a stream that is only readable after a clean
	# exit is the exact thing this replaces. The rate is bounded by keeping
	# per-item events out of here.
	_ev_fh.store_line(JSON.stringify(row))
	_ev_fh.flush()


# The "where am I" snapshot, rewritten in place whenever the dock has news.
# One read answers: which plugin build is running, is it stale, which map,
# which layers, what is the build doing, which caches exist and under what
# key, how many errors, and what was last picked. The caller assembles it
# (only the dock can see all of that); this just lands it atomically enough
# to be read by a tool at any moment.
static func write_state(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(EVENTS_DIR)
	var full := {
		"schema": 1,
		"written": int(Time.get_unix_time_from_system()),
		"t": snappedf((Time.get_ticks_msec() - _ev_t0) / 1000.0, 0.01),
		"sess": session_id(),
		"counts": {"errors": _errors, "warns": _warnings},
	}
	full.merge(d, true)
	# Written whole through a temp and renamed, so a reader never catches a
	# half-written object. This one WANTS the rename dance the event stream
	# had to dodge.
	var tmp := STATE_PATH + ".new"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(full, "  "))
	f.close()
	if FileAccess.file_exists(STATE_PATH):
		DirAccess.remove_absolute(STATE_PATH)
	DirAccess.rename_absolute(tmp, STATE_PATH)


static func events_close() -> void:
	if _ev_fh != null:
		event("session.end", {"errors": _errors, "warns": _warnings})
		_ev_fh.flush()
		_ev_fh = null


static func lines() -> Array: return _lines
static func error_count() -> int: return _errors
static func warning_count() -> int: return _warnings

static func clear() -> void:
	_lines.clear()
	_errors = 0
	_warnings = 0

static func _tag(lvl: int) -> String:
	match lvl:
		Level.ERROR: return "ERROR"
		Level.WARN: return "WARN "
		Level.DEBUG: return "debug"
		_: return "info "

# The marker report, or "" when there is no scene, no markers, or anything goes
# wrong building it. Saving the log is what someone does when something is
# already broken, so this must never be the reason the log fails to write.
static func _markers_section() -> String:
	if not Engine.is_editor_hint():
		return ""
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	# one rule for the map name, the map context's own
	return HighpolyMarkers.report(root, HighpolyMapContext.map_of(root))


static func as_text() -> String:
	var out := PackedStringArray()
	for r in _lines:
		out.append("%s  %s  %s" % [r["t"], _tag(int(r["lvl"])), r["m"]])
	return "\n".join(out)

# "out of disk space" explains a whole class of failure at a glance, so it is
# worth carrying even though the call can fail. get_space_left is an instance
# method on an OPEN directory, not a static one taking a path.
static func _free_space() -> String:
	var da := DirAccess.open("user://")
	if da == null: return "unknown"
	return "%.1f GB" % (float(da.get_space_left()) / 1073741824.0)

# The header is the whole point of saving to a file rather than copying lines:
# almost every question worth asking about a bug report is answered here.
static func header() -> String:
	var cf := ConfigFile.new()
	var ver := "?"
	if cf.load("res://addons/highpoly_toggle/plugin.cfg") == OK:
		ver = str(cf.get_value("plugin", "version", "?"))
	var lines := [
		"BF6 High-Poly Preview log",
		"saved      %s" % Time.get_datetime_string_from_system(true),
		"plugin     v%s" % ver,
		"Godot      %s" % Engine.get_version_info().get("string", "?"),
		"OS         %s %s" % [OS.get_name(), OS.get_version()],
		"video      %s" % RenderingServer.get_video_adapter_name(),
		# THE REST OF THE MACHINE. We were recording the GPU's name and nothing
		# else, and every resource complaint we get is unanswerable without the
		# rest: "it maxed out my RAM at 13 GB" means a crash on a 16 GB machine
		# and nothing at all on a 64 GB one. Joined into one entry because the
		# surrounding literal cannot splice an array.
		"\n".join(HighpolyVitals.machine()),
		# Scoped explicitly: the old header said "errors 0 warnings 0" while the
		# renderer was logging thousands of its own, which reads as "nothing
		# went wrong" when the truth was "we are not the one complaining".
		"our errors %d      our warnings %d" % [_errors, _warnings],
		"verbose    %s" % ("ON" if verbose() else "off: enable it in the panel for per-model detail"),
		"data       %s" % ProjectSettings.globalize_path("user://"),
		"free disk  %s" % _free_space(),
		"godot log  %s" % _godot_log_hint(),
		# Stated unconditionally, because the moment it is needed is AFTER the
		# editor has died — too late to go looking for how to have captured it.
		"if it crashed  this log stops dead at the crash, and Godot writes NO",
		"           editor log of its own. Close Godot, start it again with the",
		"           line below, reproduce the crash, then send that file:",
		"           %s" % _crash_capture_cmd(),
	]
	# Breadcrumbs run whether or not a recording is going and are rotated at
	# startup, so if the LAST session never wrote its clean-exit marker, the tail
	# of that file is where it died. Printed here because it is the first thing
	# anyone wants after a crash, and because the alternative — "reproduce it
	# with a log file attached" — asks the user to hit an intermittent crash a
	# second time before learning anything at all.
	# FIRST, above everything. A stale session makes every other line in the file
	# describe code that no longer exists, so it has to be read before them and
	# not found afterwards.
	var stale := _staleness()
	if stale != "":
		lines.append("")
		lines.append(stale)
		lines.append("")
	var last := HighpolyProfiler.last_session_end()
	if last != "":
		lines.append("PREVIOUS SESSION DID NOT EXIT CLEANLY. It stopped here:")
		lines.append("           %s" % last)
	lines.append("".rpad(60, "-"))
	return "\n".join(lines)


# Renderer/engine complaints (missing tangents, shader errors) never reach this
# log — they are Godot's, not ours. Point at where they DO live rather than
# leaving a reader to conclude the engine was quiet.
#
# THIS USED TO SEND PEOPLE SOMEWHERE THE ANSWER CANNOT BE. When no file was
# found it said "engine file logging is off (Project Settings > Debug > File
# Logging)", and a user chasing an editor crash duly turned that on and waited
# hours for a logs folder that was never going to appear. The setting governs a
# RUNNING PROJECT (and headless runs); the editor process does not write it.
# Measured: every log in this project is byte-identical 445-byte output from
# headless invocations, across a day in which the editor ran for hours and
# produced none. There is no %APPDATA%/Godot/logs either.
#
# For an EDITOR crash the only reliable capture on Windows is the console build
# that ships in the same zip — the normal exe detaches from the console, so
# redirecting it to a file gets you nothing.
#
# It also only ever looked for "godot.log" and "godot.1.log". Godot rotates to
# TIMESTAMPED names (godot2026-08-04T17.26.21.log), so the moment the current
# file was absent it reported "off" while several real logs sat beside it.
static func _godot_log_hint() -> String:
	var newest := ""
	var newest_at := -1
	var d := DirAccess.open("user://logs")
	if d != null:
		for fn in d.get_files():
			if not fn.ends_with(".log"):
				continue
			var p := "user://logs/" + fn
			var at := int(FileAccess.get_modified_time(p))
			if at > newest_at:
				newest_at = at
				newest = p
	if newest != "":
		return "%s  (engine messages; the EDITOR does not write here, see below)" \
			% ProjectSettings.globalize_path(newest)
	return "none: the editor writes no log file of its own (see below)"


# The exact command that captures an editor crash, with THIS install's real
# paths already filled in, so it is copy-and-paste rather than a puzzle.
#
# --log-file is the answer, NOT Godot's *_console.exe: the console build is a
# separate executable that the Portal SDK does not ship, so telling people to
# use it sends them off to find a download. --log-file is built into the editor
# they already have and was verified to capture a real editor session.
static func _crash_capture_cmd() -> String:
	var exe := OS.get_executable_path()
	var dst := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	if dst == "":
		dst = ProjectSettings.globalize_path("user://").rstrip("/")
	return "\"%s\" --log-file \"%s/godot-crash.log\"" % [exe, dst]

# Returns the saved path, or "" if it could not be written.
static func save() -> String:
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	var path := "%shighpoly-log-%s.txt" % [SAVE_DIR, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		# deliberately not routed through error(): if the log cannot be written,
		# recording that fact in the log helps nobody
		push_error("[High-Poly] could not write %s: %s"
			% [path, error_string(FileAccess.get_open_error())])
		return ""
	# The IN-MEMORY ring is the source of truth, not the session file.
	#
	# It used to be the other way round, on the reasoning that the ring only
	# holds the last 800 lines while the file holds everything. The file is not
	# readable while we are writing it: Godot's FileAccess writes through a
	# sibling .tmp and only renames on close, so a read of SESSION_LOG during a
	# live session returns the last CLEANLY CLOSED session instead. An editor
	# that was killed, or a plugin reloaded without teardown, leaves the .tmp
	# orphaned and the real file frozen.
	#
	# The result was a saved log that looked plausible and was completely stale:
	# byte-identical across saves, reporting an older plugin version, with none
	# of the session's actual entries. Hours were spent hunting a second editor
	# instance that did not exist.
	var body := header() + "\n" + as_text()
	# The older session file is still worth appending when it belongs to a
	# DIFFERENT run, since it holds what came before the ring's 800 lines. It is
	# clearly labelled so it can never again be mistaken for the current one.
	if _fh != null:
		_fh.flush()
	var sf := FileAccess.open(SESSION_LOG, FileAccess.READ)
	if sf != null:
		var prev := sf.get_as_text()
		sf.close()
		if prev.strip_edges() != "" and not prev.begins_with(header().split("\n")[0] + "\n" + "saved"):
			body += "\n\n" + "-".repeat(60) + "\n" \
				+ "PREVIOUS SESSION (from %s, kept because the ring above holds only\n" % SESSION_LOG \
				+ "the last %d lines and the earlier part of a long run is often what\n" % MAX_LINES \
				+ "matters). This is NOT this session.\n" + "-".repeat(60) + "\n" + prev
	# Problem markers ride along with the log, because the log is the thing that
	# actually gets sent. A marker alone says "something is wrong here"; appended
	# here it also carries what the package expects at that spot and whether the
	# files are present, which is the difference between a report and a
	# diagnosis. Never let this stop the log being written.
	# Memory, freezes and disk speed ride along for the same reason the markers
	# do: the log is the thing that actually gets sent. Every one of those three
	# has cost a round of asking the user to go and read a number off Task
	# Manager for us, and none of them was ever in the file we already had.
	f.store_string(body + "\n" + HighpolyVitals.report() + "\n"
		+ _markers_section() + "\n")
	f.close()
	return ProjectSettings.globalize_path(path)
