extends SceneTree
# The diagnostics bundle is the file a user attaches to a bug report, so the
# ways it can fail all look like "they sent something useless": a zip that
# does not open, one missing the very file the question is about, or one whose
# session log is silently the PREVIOUS session with nothing saying so.
#
# It must also survive being pressed on a fresh install where half these files
# do not exist yet, which is exactly when someone is most likely to press it.

const Log = preload("res://addons/highpoly_toggle/highpoly_log.gd")

var fails := 0

func _fail(w: String) -> void:
	fails += 1
	print("FAIL  %s" % w)

func _ok(w: String) -> void:
	print("ok    %s" % w)


func _init() -> void:
	print("=== diagnostics bundle ===")

	# A fresh install: no map, and most sources missing.
	var p_empty := Log.save_bundle("")
	if p_empty == "":
		_fail("it refused to write anything when the optional files were "
			+ "missing, which is the state a new user is in")
	else:
		_ok("writes on a fresh install with sources missing")

	# Now with content to carry.
	Log.event("test.bundle", {"n": 1})
	Log.warn("something worth reporting")
	DirAccess.make_dir_recursive_absolute("user://mapcontext/MP_Test")
	var d := FileAccess.open("user://mapcontext/MP_Test/decisions.jsonl",
		FileAccess.WRITE)
	d.store_line('{"key":"m|0x1|0|0","mesh":"m","rules":[{"r":"uv.primary"}]}')
	d.close()

	var path := Log.save_bundle("MP_Test")
	if path == "":
		_fail("save_bundle returned nothing")
		_done()
		return
	_ok("wrote %s" % path.get_file())

	# It must be a REAL zip, opened by something other than the writer.
	var rd := ZIPReader.new()
	if rd.open(ProjectSettings.globalize_path(path)) != OK:
		_fail("the zip does not open")
		_done()
		return
	var names := rd.get_files()
	_ok("opens as a zip with %d entries" % names.size())

	for want in ["MANIFEST.txt", "this-session.log", "events.jsonl",
			"state.json", "decisions.jsonl"]:
		if names.has(want):
			_ok("carries %s" % want)
		else:
			_fail("missing %s, which is one of the files it exists to carry"
				% want)

	# The live log has to come from memory: on disk it is the last session.
	if names.has("this-session.log"):
		var t := rd.read_file("this-session.log").get_string_from_utf8()
		if not t.contains("something worth reporting"):
			_fail("this-session.log does not contain this session's lines")
		elif not t.contains("plugin"):
			_fail("this-session.log has no header, so it cannot say which "
				+ "build produced it")
		else:
			_ok("this-session.log carries the header and the live lines")

	# The trap this names explicitly, so a reader cannot fall into it.
	var man := rd.read_file("MANIFEST.txt").get_string_from_utf8()
	if not man.contains("previous-session"):
		_fail("the manifest does not warn that the on-disk log is the "
			+ "PREVIOUS session")
	else:
		_ok("the manifest names the previous-session trap")
	if not man.contains("MP_Test"):
		_fail("the manifest does not record which map it is about")
	else:
		_ok("the manifest records the map")

	if names.has("decisions.jsonl"):
		var dt := rd.read_file("decisions.jsonl").get_string_from_utf8()
		if not dt.contains("uv.primary"):
			_fail("the decision trace did not survive the round trip")
		else:
			_ok("the decision trace round trips intact")
	rd.close()
	_done()


func _done() -> void:
	print("=== %s ===" % ("PASSED" if fails == 0 else "%d FAILURE(S)" % fails))
	quit(1 if fails > 0 else 0)
