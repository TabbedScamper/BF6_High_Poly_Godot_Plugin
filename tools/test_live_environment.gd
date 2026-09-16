extends SceneTree

# Runtime-path regression for the Godot environment reader. Expected numbers
# are verification oracles only; the renderer never consumes this file or any
# table beside it. The control deliberately pairs Dumbo with Aftermath's oracle.
const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")

const REAL := {"sun_az": 124.800003, "sun_el": 28.5, "sun_lux": 120000.0}
const SHUFFLED := {"sun_az": 237.899994, "sun_el": 12.9, "sun_lux": 24000.0}


func _score(got: Dictionary, oracle: Dictionary) -> int:
	var n := 0
	for key in oracle:
		if got.has(key) and is_equal_approx(float(got[key]), float(oracle[key])):
			n += 1
	return n


func _init() -> void:
	var gs = GS.new()
	gs.geom_cache = false
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		push_error("live environment open failed: %s" % gs.error)
		quit(1)
		return
	var got: Dictionary = gs.environment_lighting()
	var real_score := _score(got, REAL)
	var shuffled_score := _score(got, SHUFFLED)
	print("environment oracle: real %d/%d, shuffled control %d/%d"
		% [real_score, REAL.size(), shuffled_score, SHUFFLED.size()])
	var ok := real_score == REAL.size() and shuffled_score == 0
	ok = ok and str(got.get("preset_path", "")).contains("/levels/")
	ok = ok and int(got.get("preset_candidates", 0)) >= 1
	var sky: Dictionary = gs.sky()
	ok = ok and (sky.is_empty() or str(sky.get("preset", "")) == str(got["preset"]))
	if not ok:
		push_error("live environment/control mismatch: %s" % str(got))
	quit(0 if ok else 1)
