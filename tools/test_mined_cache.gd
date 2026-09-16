extends SceneTree

# Unit boundary for HighpolyLighting's runtime input. The old version of this
# test created placements.json and proved a derived file could become a runtime
# dependency. This one proves the opposite: only the open live reader is used,
# and a wrong-map pairing is the negative control.
const L = preload("res://addons/highpoly_toggle/highpoly_lighting.gd")
const MAP := "MP_TestLive"


class FakeSource:
	extends RefCounted
	var level := "mp_testlive"
	var fields := {
		"sun_az": 157.03,
		"sun_el": 31.0,
		"sun_lux": 120000.0,
		"sun_color": [1.0, 0.8, 0.6],
	}

	func environment_lighting() -> Dictionary:
		return fields


func _init() -> void:
	var fails := 0
	L.game_source = null
	fails += _check("no reader means no runtime lighting", not L.has_data(MAP))

	var live := FakeSource.new()
	L.game_source = live
	var got: Dictionary = L.mined(MAP)
	fails += _check("reads the open live reader", not got.is_empty())
	fails += _check("keeps the decoded value",
		is_equal_approx(float(got.get("sun_az", 0.0)), 157.03))
	fails += _check("wrong-map pairing is rejected",
		L.mined("MP_ShuffledControl").is_empty())
	fails += _check("no staged light zones are accepted", L.zones(MAP).is_empty())

	L.game_source = null
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> int:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	return 0 if ok else 1
