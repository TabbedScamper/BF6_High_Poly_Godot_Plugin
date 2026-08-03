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


static func _open_session() -> void:
	if _fh != null:
		return
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
		# Scoped explicitly: the old header said "errors 0 warnings 0" while the
		# renderer was logging thousands of its own, which reads as "nothing
		# went wrong" when the truth was "we are not the one complaining".
		"our errors %d      our warnings %d" % [_errors, _warnings],
		"verbose    %s" % ("ON" if verbose() else "off: enable it in the panel for per-model detail"),
		"data       %s" % ProjectSettings.globalize_path("user://"),
		"free disk  %s" % _free_space(),
		"godot log  %s" % _godot_log_hint(),
		"".rpad(60, "-"),
	]
	return "\n".join(lines)


# Renderer/engine complaints (missing tangents, shader errors) never reach this
# log — they are Godot's, not ours. Point at where they DO live rather than
# leaving a reader to conclude the engine was quiet.
static func _godot_log_hint() -> String:
	for p in ["user://logs/godot.log", "user://logs/godot.1.log"]:
		if FileAccess.file_exists(p):
			return ProjectSettings.globalize_path(p) + "  (engine messages)"
	return "engine file logging is off (Project Settings > Debug > File Logging)"

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
	# Prefer the write-through session file: the in-memory ring holds the last
	# 800 lines, and the interesting part of a long download run is usually
	# further back than that.
	var body := ""
	if _fh != null:
		_fh.flush()
	var sf := FileAccess.open(SESSION_LOG, FileAccess.READ)
	if sf != null:
		body = sf.get_as_text()
		sf.close()
	if body.strip_edges() == "":
		body = header() + "\n" + as_text()
	# Problem markers ride along with the log, because the log is the thing that
	# actually gets sent. A marker alone says "something is wrong here"; appended
	# here it also carries what the package expects at that spot and whether the
	# files are present, which is the difference between a report and a
	# diagnosis. Never let this stop the log being written.
	f.store_string(body + "\n" + _markers_section() + "\n")
	f.close()
	return ProjectSettings.globalize_path(path)
