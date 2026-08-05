extends SceneTree

# Getting a map in is more stages than the panel was showing. The download had a
# bar and the scenery build had a bar, but unpacking the archive between them had
# none — 31 s on Dumbo with nothing moving — and placing the map lights and the
# FX had none either. A long job with no bar is indistinguishable from a hang.
#
# Two things can go wrong with the fix and neither one throws:
#
#   1. a lane that opens and never closes leaves a bar stuck on screen for the
#      rest of the session, including on the cancel paths;
#   2. HighpolyFx.apply had to start yielding before a bar could move at all,
#      which turned it into a coroutine — and a caller that forgets `await` gets
#      a GDScriptFunctionState assigned to a Label instead of a String, silently.
#
# Builds its own fx.json/lights.json so it does not depend on whatever the last
# session happened to download.

const FX = preload("res://addons/highpoly_toggle/highpoly_fx.gd")
const Lighting = preload("res://addons/highpoly_toggle/highpoly_lighting.gd")
const Jobs = preload("res://addons/highpoly_toggle/highpoly_jobs.gd")
const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

const MAP := "TEST_ProgressMap"
# Big enough that the loops span several 30 ms slices. At 900 the whole thing
# finished inside ONE slice, so only the closing report fired and the test
# passed without ever exercising the intermediate reporting it exists to check.
const N := 20000

var fails := 0
var seen: Array = []          # [done, total] pairs, in order


func _init() -> void:
	await process_frame
	_write_data()

	var root := Node3D.new()
	root.name = "TestRoot"
	get_root().add_child(root)
	await process_frame

	# ---- FX ---------------------------------------------------------------
	seen = []
	var msg = await FX.apply(root, MAP, true, _rec())
	_lane_checks("FX", msg, N)

	# ---- map lights -------------------------------------------------------
	seen = []
	msg = await Lighting.set_map_lights(root, true, MAP, _rec())
	_lane_checks("map lights", msg, N)

	# ---- the lane bookkeeping itself --------------------------------------
	var jobs = Jobs.new()
	get_root().add_child(jobs)
	jobs.set_activity("A", 1, 10)
	jobs.set_activity("B", 5, 10)
	_check("two jobs hold two separate lanes", jobs.busy())
	jobs.clear_activity("A")
	_check("clearing one lane leaves the other", jobs.busy())
	jobs.clear_activity("B")
	_check("clearing the last lane frees the bar", not jobs.busy())
	# a label typo would open one lane and close another, stranding a bar
	jobs.set_activity(MC.UNPACK_JOB, 3, 10)
	jobs.clear_activity(MC.UNPACK_JOB)
	_check("the unpack lane closes under the shared constant", not jobs.busy())

	# ---- the coroutine cascade -------------------------------------------
	# every call site of a function that now yields must await it, or a Label
	# gets a GDScriptFunctionState and the status line reads as gibberish
	_check("every HighpolyFx.apply call site awaits",
		_all_awaited("HighpolyFx.apply("))
	_check("every set_map_lights call site awaits",
		_all_awaited("LightingScript.set_map_lights("))

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _rec() -> Callable:
	return func(done: int, total: int) -> void:
		seen.append([done, total])


func _lane_checks(what: String, msg: Variant, total: int) -> void:
	print("\n%s: %d progress report(s), returned %s" % [what, seen.size(), msg])
	_check("%s returns a String, not a coroutine handle" % what, msg is String)
	# more than one: a single closing report means the bar jumped straight from
	# nothing to done, which is exactly the dead gap being fixed
	_check("%s reported progress WHILE running, not just at the end" % what,
		seen.size() > 1)
	if seen.is_empty():
		return
	var ok := true
	var last := -1
	for s in seen:
		if int(s[0]) < last or int(s[0]) > int(s[1]):
			ok = false
		last = int(s[0])
	_check("%s progress only moves forward and never exceeds its total" % what, ok)
	# THE ONE THAT MATTERS: the last report must close the lane. A run that stops
	# reporting at 87% leaves the bar on screen forever.
	var fin: Array = seen[seen.size() - 1]
	_check("%s finishes at %d/%d, which closes the lane"
		% [what, int(fin[0]), int(fin[1])], int(fin[0]) >= int(fin[1]))
	_check("%s reported against the real total (%d)" % [what, total],
		int(fin[1]) == total)


func _all_awaited(needle: String) -> bool:
	var src := FileAccess.get_file_as_string("res://addons/highpoly_toggle/highpoly_toggle.gd")
	if src.is_empty():
		return false
	var ok := true
	var from := 0
	while true:
		var i := src.find(needle, from)
		if i < 0:
			break
		from = i + needle.length()
		# walk back over the assignment to whatever precedes the call
		var line_start := src.rfind("\n", i) + 1
		var line := src.substr(line_start, i - line_start)
		if not line.contains("await"):
			print("      not awaited: %s%s..." % [line.strip_edges(), needle])
			ok = false
	return ok


func _write_data() -> void:
	DirAccess.make_dir_recursive_absolute("user://mapcontext/%s" % MAP)
	var fx: Array = []
	var lights: Array = []
	for i in range(N):
		fx.append({"class": "fire", "effect": "TEST", "pos": [i * 0.5, 1.0, 0.0],
			"yaw": 0.0, "source_class": "gamemode-layer"})
		lights.append({"pos": [i * 0.5, 3.0, 0.0], "color": [1, 1, 1],
			"intensity": 1000.0, "radius": 5.0, "layer": "base"})
	var f := FileAccess.open("user://mapcontext/%s/fx.json" % MAP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"fx": fx})); f.close()
	f = FileAccess.open("user://mapcontext/%s/lights.json" % MAP, FileAccess.WRITE)
	f.store_string(JSON.stringify({"lights": lights})); f.close()


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
