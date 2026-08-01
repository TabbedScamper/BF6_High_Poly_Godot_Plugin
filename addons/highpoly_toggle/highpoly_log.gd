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

enum Level { INFO, WARN, ERROR }

const MAX_LINES := 800     # ring buffer: a long session must not grow forever
const SAVE_DIR := "user://"

static var _lines: Array = []
static var _errors := 0
static var _warnings := 0
static var _on_line: Callable = Callable()

# The panel registers here so new lines appear as they happen. Cleared on
# teardown so a freed dock can never be called into.
static func hook(cb: Callable) -> void:
	_on_line = cb

static func _add(lvl: int, msg: String) -> void:
	var row := {"t": Time.get_time_string_from_system(), "lvl": lvl, "m": msg}
	_lines.append(row)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
	if lvl == Level.ERROR:
		_errors += 1
		push_error("[High-Poly] " + msg)
	elif lvl == Level.WARN:
		_warnings += 1
		push_warning("[High-Poly] " + msg)
	if _on_line.is_valid():
		_on_line.call(lvl, msg)

static func info(msg: String) -> void: _add(Level.INFO, msg)
static func warn(msg: String) -> void: _add(Level.WARN, msg)
static func error(msg: String) -> void: _add(Level.ERROR, msg)

# Record a Godot Error code with its meaning spelled out — "error 7" in a
# user-sent log is worth almost nothing on its own.
static func err_code(what: String, code: int) -> void:
	error("%s — %s (code %d)" % [what, error_string(code), code])

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
		_: return "info "

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
		"BF6 High-Poly Preview — log",
		"saved      %s" % Time.get_datetime_string_from_system(true),
		"plugin     v%s" % ver,
		"Godot      %s" % Engine.get_version_info().get("string", "?"),
		"OS         %s %s" % [OS.get_name(), OS.get_version()],
		"video      %s" % RenderingServer.get_video_adapter_name(),
		"errors     %d      warnings %d" % [_errors, _warnings],
		"data       %s" % ProjectSettings.globalize_path("user://"),
		"free disk  %s" % _free_space(),
		"".rpad(60, "-"),
	]
	return "\n".join(lines)

# Returns the saved path, or "" if it could not be written.
static func save() -> String:
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	var path := "%shighpoly-log-%s.txt" % [SAVE_DIR, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		# deliberately not routed through error(): if the log cannot be written,
		# recording that fact in the log helps nobody
		push_error("[High-Poly] could not write %s — %s"
			% [path, error_string(FileAccess.get_open_error())])
		return ""
	f.store_string(header() + "\n" + as_text() + "\n")
	f.close()
	return ProjectSettings.globalize_path(path)
