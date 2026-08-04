extends SceneTree

# Reproduce the Capstone bug and prove the fix, in the order it actually happens:
# the dock asks before the map package has downloaded, the package then arrives.
# Under the old code the second read returned the cached miss forever.

const L = preload("res://addons/highpoly_toggle/highpoly_lighting.gd")
const MAP := "MP_TestCache"


func _init() -> void:
	var dir := "user://mapcontext/%s" % MAP
	var path := "%s/placements.json" % dir
	DirAccess.make_dir_recursive_absolute(dir)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	L.forget()

	var fails := 0

	# 1. asked too early, before the download lands
	var early: Dictionary = L.mined(MAP)
	fails += _check("empty before the package exists", early.is_empty())
	fails += _check("has_data false before it exists (no TABLE row)",
		not L.has_data(MAP))

	# 2. the package arrives
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"lighting": {"fields": {"sun_az": 157.03, "sun_el": 31.0, "sun_lux": 120000.0}}}))
	f.close()

	# 3. THE REGRESSION: this used to still be empty, for the whole session
	var after: Dictionary = L.mined(MAP)
	fails += _check("picks the package up once it exists", not after.is_empty())
	fails += _check("reads the right value", is_equal_approx(float(after.get("sun_az", 0.0)), 157.03))
	fails += _check("has_data true once it exists", L.has_data(MAP))

	# 4. a REPUBLISHED package must also be seen (mtime changes, contents differ)
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_string(JSON.stringify({
		"lighting": {"fields": {"sun_az": 42.0, "sun_el": 12.0}}}))
	f2.close()
	# mtime has 1 s granularity on some filesystems, so make the change visible
	FileAccess.set_read_only_attribute(path, false)
	var t := Time.get_unix_time_from_system()
	while Time.get_unix_time_from_system() - t < 1.2:
		pass
	var f3 := FileAccess.open(path, FileAccess.WRITE)
	f3.store_string(JSON.stringify({
		"lighting": {"fields": {"sun_az": 42.0, "sun_el": 12.0}}}))
	f3.close()
	var re: Dictionary = L.mined(MAP)
	fails += _check("picks up a republished package",
		is_equal_approx(float(re.get("sun_az", 0.0)), 42.0))

	DirAccess.remove_absolute(path)
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> int:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	return 0 if ok else 1
