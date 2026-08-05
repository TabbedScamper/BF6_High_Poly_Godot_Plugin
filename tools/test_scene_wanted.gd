extends SceneTree

# "If we have it set to High-Poly the already placed assets in the scene don't
# get downloaded and upgraded."
#
# Under scope=scene, check_now() queues ONLY globals — a placed prop reaches the
# download queue by exactly one route:
#
#   HighpolyLib.apply()   records a prop it could not draw in `wanted`
#   take_wanted()         drains that list, ONCE, and clears it
#   prioritize_scene()    queues them and records what the scene uses
#
# Every step of that is drain-once, which makes it fragile in a specific way: a
# second caller reading `wanted` gets nothing, and a caller that passes a
# partial list to prioritize_scene overwrites the record of what the scene uses
# with just that part.
#
# Run with no arguments.

const HighpolyLib = preload("res://addons/highpoly_toggle/highpoly_lib.gd")
const Sync = preload("res://addons/highpoly_toggle/highpoly_sync.gd")

var fails := 0


func _init() -> void:
	await process_frame

	# ---- a prop the scene uses and does not have -------------------------
	HighpolyLib.wanted.clear()
	HighpolyLib.wanted["PropA"] = true
	HighpolyLib.wanted["PropB"] = true

	var first: Array = HighpolyLib.take_wanted()
	_check("take_wanted returns what the scene is missing (%d)" % first.size(),
		first.size() == 2)

	# THE DRAIN. _apply_scene() and _mode_changed() BOTH call this, and
	# _apply_scene runs first, so the second call is always empty. Whatever the
	# second caller meant to do with the list, it does not do.
	var second: Array = HighpolyLib.take_wanted()
	_check("a second caller in the same pass gets nothing (%d)" % second.size(),
		second.is_empty())

	# ---- what prioritize_scene records ----------------------------------
	var sync = Sync.new()
	get_root().add_child(sync)
	await process_frame

	sync.prioritize_scene(["PropA", "PropB", "PropC"])
	var full_set: int = sync._scene_set.size()
	_check("the scene set lists every prop it was told about (%d)" % full_set,
		full_set == 3)

	# THE OVERWRITE. Its own comment says _scene_set "must list EVERY prop the
	# scene uses, not only the ones still pending" — and it used to clear() and
	# rebuild from whatever it was handed. The caller hands it take_wanted(),
	# which is only the props still MISSING. So once one prop arrived and the
	# pass ran again with a shorter list, the scene set forgot the rest, and
	# _needs() consults that set to decide the full-quality tier.
	sync.prioritize_scene(["PropA"])
	var after: int = sync._scene_set.size()
	_check("a later PARTIAL call does not shrink it (%d, still 3)" % after,
		after == 3)

	# It has to reset SOMEWHERE, or the next scene inherits this one's props.
	# prioritize_scene cannot be that place, because it only ever sees a part.
	sync.forget_scene()
	_check("and a scene change forgets it (%d)" % sync._scene_set.size(),
		sync._scene_set.is_empty())

	sync.prioritize_scene(["PropX"])
	_check("so the next scene starts from its own props (%d)"
		% sync._scene_set.size(), sync._scene_set.size() == 1)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
