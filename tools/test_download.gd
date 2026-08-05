extends SceneTree

# Exercise fetch_to_file against the real host: does it land the bytes, clean up
# its .part, and report failure honestly? Parse checks cannot answer any of that,
# and this path now carries every model download.

const U = preload("res://addons/highpoly_toggle/highpoly_updater.gd")
const BASE := "https://pub-45114dae448e4a059f488662e3d47b19.r2.dev/"

var fails := 0


func _init() -> void:
	# _init runs before the tree is live, so the node would not be inside it yet
	# and every request would return ERR_UNCONFIGURED.
	await process_frame
	var http := HTTPRequest.new()
	root.add_child(http)
	await process_frame
	var dst := "user://dltest.glb"
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)

	# 1. a real model
	var t0 := Time.get_ticks_msec()
	var ok: bool = await U.fetch_to_file(http, BASE + "godot/seu_aagun_01.glb", dst)
	var ms := Time.get_ticks_msec() - t0
	_check("returns true for a real file", ok)
	_check("the file exists afterwards", FileAccess.file_exists(dst))
	var n := 0
	if FileAccess.file_exists(dst):
		var f := FileAccess.open(dst, FileAccess.READ)
		n = f.get_length()
		f.close()
	_check("the file has bytes in it (%d)" % n, n > 0)
	_check("it is a GLB (magic 'glTF')", _magic(dst) == "glTF")
	_check("no .part left behind", not FileAccess.file_exists(dst + ".part"))
	print("      %d bytes in %d ms" % [n, ms])

	# 2. overwriting an existing file must work — that is the refresh path
	var ok2: bool = await U.fetch_to_file(http, BASE + "godot/seu_aagun_01.glb", dst)
	_check("re-downloading over an existing file works", ok2 and _magic(dst) == "glTF")

	# 3. a 404 must fail cleanly, not leave a stub where a model belongs
	var bad := "user://dltest_missing.glb"
	var ok3: bool = await U.fetch_to_file(http, BASE + "godot/definitely_not_a_model.glb", bad)
	_check("returns false for a missing file", not ok3)
	_check("leaves no file behind on failure", not FileAccess.file_exists(bad))
	_check("leaves no .part behind on failure", not FileAccess.file_exists(bad + ".part"))

	DirAccess.remove_absolute(dst)
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _magic(p: String) -> String:
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	var s := f.get_buffer(4).get_string_from_ascii()
	f.close()
	return s


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
