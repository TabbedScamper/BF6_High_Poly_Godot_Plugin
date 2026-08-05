extends SceneTree

# The skyline is kept across a rebuild only when nothing affecting it changed.
# Both ways of getting this wrong are bad and neither is obvious on screen:
# too strict and every toggle costs another 375 s, too loose and you keep a
# skyline built for a different map or a different detail mode.
#
# apply() needs a real scene, so this drives the decision directly rather than
# through the editor: same inputs, same branch.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0


# mirrors the condition in apply(); if that changes, this must fail loudly
func salvage(backdrop, prev_backdrop, map, prev_map, tex, prev_tex, total, done) -> bool:
	return backdrop and prev_backdrop and map == prev_map and tex == prev_tex \
		and total > 0 and done >= total


func _init() -> void:
	# the case this exists for: another layer toggled, skyline untouched
	_check("keeps it when only an unrelated layer changed",
		salvage(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2, 155, 155))

	# must NOT keep it
	_check("rebuilds when the map changed",
		not salvage(true, true, "MP_Plaza", "MP_Dumbo", 2, 2, 155, 155))
	_check("rebuilds when the detail mode changed (materials are baked per mode)",
		not salvage(true, true, "MP_Dumbo", "MP_Dumbo", 0, 2, 155, 155))
	_check("rebuilds when the previous build never finished",
		not salvage(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2, 155, 92))
	_check("builds normally when there was no skyline before",
		not salvage(true, false, "MP_Dumbo", "MP_Dumbo", 2, 2, 0, 0))
	_check("does nothing when the skyline is switched off",
		not salvage(false, true, "MP_Dumbo", "MP_Dumbo", 2, 2, 155, 155))
	_check("rebuilds when there was nothing queued",
		not salvage(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2, 0, 0))

	# _clear must keep the mesh list only when asked
	var mc = MC.new()
	root.add_child(mc)
	mc._bd_list.append(null)
	mc._clear(root, true)
	_check("_clear(keep) preserves the skyline mesh list", mc._bd_list.size() == 1)
	mc._bd_list.append(null)
	mc._clear(root, false)
	_check("_clear() still clears it by default", mc._bd_list.size() == 0)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
