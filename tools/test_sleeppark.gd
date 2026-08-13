extends SceneTree
# The bench harness zeroes the editor's two idle sleeps so it measures a cost
# instead of a cap, and puts them back when the flight ends. perfrun.py
# force-kills the editor on hang, crash or timeout, so "when the flight ends"
# is a promise it cannot always keep - and a machine was found rendering the
# whole map at full rate behind a running game because of exactly that.
#
# The park file is the fix: written BEFORE the settings change, consumed at
# the next boot. This asserts the file's contract, which is the part that has
# to survive a kill. It cannot assert the editor-settings write itself, since
# there is no EditorInterface in a headless script.

const FR = preload("res://addons/highpoly_toggle/highpoly_flightrun.gd")

var fails := 0

func _fail(w: String) -> void:
	fails += 1
	print("FAIL  %s" % w)

func _ok(w: String) -> void:
	print("ok    %s" % w)


func _init() -> void:
	print("=== bench sleep parking ===")

	FR._unpark_sleeps()
	if FileAccess.file_exists(FR.SLEEP_PARK):
		_fail("could not clear a stale park file")

	# Nothing to save means nothing to restore: an editor that does not expose
	# these settings must not leave a file that lies about them.
	FR._park_sleeps(null, null)
	if FileAccess.file_exists(FR.SLEEP_PARK):
		_fail("parked a file when there were no values to park")
	else:
		_ok("no file when there is nothing to put back")

	FR._park_sleeps(100000, 6900)
	if not FileAccess.file_exists(FR.SLEEP_PARK):
		_fail("the park file was not written")
		_done()
		return
	_ok("park file written before the settings are touched")

	var f := FileAccess.open(FR.SLEEP_PARK, FileAccess.READ)
	var v = JSON.parse_string(f.get_as_text())
	f.close()
	if not (v is Dictionary):
		_fail("the park file is not JSON")
	else:
		var d: Dictionary = v
		if int(d.get("unfocused", -1)) != 100000 or int(d.get("focused", -1)) != 6900:
			_fail("the park file lost the values: %s" % str(d))
		else:
			_ok("it carries the ORIGINAL values, not the zeroes")
		if int(d.get("at", 0)) <= 0:
			_fail("no timestamp, so a stale park cannot be recognised")
		else:
			_ok("timestamped, so the boot can say how long it sat there")

	# The happy path clears it, or every later boot would keep announcing a
	# restore that already happened.
	FR._unpark_sleeps()
	if FileAccess.file_exists(FR.SLEEP_PARK):
		_fail("a completed flight left its park file behind")
	else:
		_ok("a completed flight clears it")

	# And the kill path: a file left on disk is exactly what boot must find.
	FR._park_sleeps(100000, 6900)
	if FileAccess.file_exists(FR.SLEEP_PARK):
		_ok("a killed flight leaves the file for the next boot to consume")
	else:
		_fail("nothing left for the next boot")
	FR._unpark_sleeps()

	_done()


func _done() -> void:
	print("=== %s ===" % ("PASSED" if fails == 0 else "%d FAILURE(S)" % fails))
	quit(1 if fails > 0 else 0)
