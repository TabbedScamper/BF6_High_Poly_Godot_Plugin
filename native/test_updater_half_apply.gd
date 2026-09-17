extends SceneTree

# AN UPDATE THAT CANNOT WRITE A NEW FILE MUST FAIL, NOT REPORT SUCCESS.
#
#   python tools/run_addon_script.py native/test_updater_half_apply.gd
#
# On 2026-09-17 a user's plugin disabled itself and stayed broken through every
# version they tried afterwards. The cause was here: the updater treated a file
# it could not open for writing as harmless and reported "Plugin updated". That
# is true for a CHANGED file, whose old version stays on disk. It is false for a
# NEW one, where nothing lands at all and every script preloading it fails to
# compile. Their install ended up as 2.8.0's highpoly_toggle.gd over 2.7.0's
# file set, with ten preloads pointing at files that were never written - and a
# later update only overwrites, so nothing could repair it.
#
# The failure was untestable before, because applying an update meant
# downloading a real release over the network into the live addon folder.
# apply_zip() is that logic split out with an injectable destination.
#
# HOW A FAILED WRITE IS FORCED: a DIRECTORY is created where the new file is
# meant to go. FileAccess.open(path, WRITE) cannot open a directory, so the
# write fails exactly as a locked file does, with no mocking and no special
# case in the code under test.

const Updater := preload("res://addons/highpoly_toggle/highpoly_updater.gd")

var fails := 0

func _bad(m: String) -> void:
	print("  FAIL %s" % m)
	fails += 1

func _ok(m: String) -> void:
	print("  ok   %s" % m)


func _init() -> void:
	await process_frame
	var work := "user://test_half_apply"
	var dest := work + "/install"
	var zip := work + "/update.zip"
	_reset(work)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest))

	# An install already holding one file the update also carries.
	_write(dest + "/existing.gd", "# old\n")

	# An update carrying that file plus one the install does not have.
	_make_zip(zip, {
		"addons/highpoly_toggle/existing.gd": "# new\n",
		"addons/highpoly_toggle/brand_new.gd": "# added by the update\n",
	})

	print("\n--- 1. a clean apply reports success ---")
	var said: Array = []
	var say := func(s: String) -> void: said.append(s)
	var r: Dictionary = Updater.apply_zip(zip, dest, say)
	if not bool(r.get("ok", false)):
		_bad("a complete update reported failure: %s" % str(said))
	else:
		_ok("complete update reported ok")
	if not FileAccess.file_exists(dest + "/brand_new.gd"):
		_bad("the new file was not written")
	else:
		_ok("the new file landed")
	if _read(dest + "/existing.gd") != "# new\n":
		_bad("the changed file was not updated")
	else:
		_ok("the changed file was updated")

	print("\n--- 2. a NEW file that cannot be created must FAIL the update ---")
	_reset(work)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest))
	_write(dest + "/existing.gd", "# old\n")
	_make_zip(zip, {
		"addons/highpoly_toggle/existing.gd": "# new\n",
		"addons/highpoly_toggle/brand_new.gd": "# added by the update\n",
	})
	# Block the new file's path with a directory of the same name.
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(dest + "/brand_new.gd"))
	said.clear()
	r = Updater.apply_zip(zip, dest, say)
	if bool(r.get("ok", false)):
		_bad("REGRESSION: a half-applied update reported SUCCESS - this is the"
			+ " exact bug that broke a user's install permanently")
	else:
		_ok("half-applied update reported failure")
	var missing: Array = r.get("missing", [])
	if not missing.has("brand_new.gd"):
		_bad("the unwritable new file was not named as missing: %s" % str(missing))
	else:
		_ok("named the file that did not land")
	var told := " ".join(PackedStringArray(said))
	if not told.contains("delete"):
		_bad("the message does not tell the user to delete and reinstall: %s" % told)
	else:
		_ok("told the user to delete the folder and reinstall")

	print("\n--- 3. a CHANGED file that cannot be written is NOT a failure ---")
	# The old version is still on disk, so the install stays complete. This is
	# the case the original code was right about, and it must not regress into
	# failing every update over a locked waves.ogv.
	_reset(work)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dest))
	_write(dest + "/existing.gd", "# old\n")
	_make_zip(zip, {"addons/highpoly_toggle/existing.gd": "# new\n"})
	var held := FileAccess.open(dest + "/existing.gd", FileAccess.READ)
	said.clear()
	r = Updater.apply_zip(zip, dest, say)
	if held != null:
		held.close()
	# Windows may or may not let the write through while the handle is open, so
	# only the SHAPE is asserted: whatever happened, the file still exists, so
	# the update must not be reported as incomplete.
	if not FileAccess.file_exists(dest + "/existing.gd"):
		_bad("the existing file vanished")
	elif not bool(r.get("ok", false)):
		_bad("an install with every file present was reported incomplete: %s" % str(said))
	else:
		_ok("a present-but-stale file does not fail the update")

	_reset(work)
	print("")
	if fails == 0:
		print("test_updater_half_apply: ok")
	else:
		print("test_updater_half_apply: %d FAILURE(S)" % fails)
	quit(0 if fails == 0 else 1)


func _reset(dir: String) -> void:
	var abs := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs):
		_rm_tree(abs)
	DirAccess.make_dir_recursive_absolute(abs)


func _rm_tree(abs: String) -> void:
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var child := abs.path_join(name)
		if d.current_is_dir():
			_rm_tree(child)
		else:
			DirAccess.remove_absolute(child)
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _make_zip(path: String, files: Dictionary) -> void:
	var zp := ZIPPacker.new()
	if zp.open(ProjectSettings.globalize_path(path)) != OK:
		_bad("could not create the test archive")
		return
	for name in files.keys():
		zp.start_file(String(name))
		zp.write_file(String(files[name]).to_utf8_buffer())
		zp.close_file()
	zp.close()
