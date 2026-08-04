extends SceneTree

# Does the new compass sun_dir() actually point where the hand calibrations said?
# The old code aimed at sun_dir_OLD(user_az); the new code aims at
# sun_dir_NEW(authored_az) with nothing hand-set. The angle between those two
# vectors IS the residual, so this checks the shipped function against the
# measurements rather than re-deriving the algebra that produced it.

const L = preload("res://addons/highpoly_toggle/highpoly_lighting.gd")

# map -> [authored_az, authored_el, user_az, user_el]
const CAL := {
	"MP_Dumbo":     [124.800003, 28.5, 325.5, 44.0],
	"MP_Aftermath": [237.899994, 12.9, 211.0, 13.0],
	"MP_Capstone":  [157.029999, 31.0, 284.5, 28.5],
	"MP_Badlands":  [354.0,      10.0,  71.5,  7.5],
}


func _old_dir(az_deg: float, el_deg: float) -> Vector3:
	var az := deg_to_rad(az_deg)
	var el := deg_to_rad(el_deg)
	return Vector3(cos(az) * cos(el), sin(el), sin(az) * cos(el)).normalized()


func _init() -> void:
	# 1. the shipped function must equal the old one at (90 - az)
	var worst := 0.0
	for a in [0.0, 37.5, 124.8, 237.9, 354.0]:
		for e in [0.0, 12.9, 45.0, 66.0]:
			var d: float = rad_to_deg(L.sun_dir(a, e).angle_to(_old_dir(90.0 - a, e)))
			worst = maxf(worst, d)
	print("compass(az) == old(90-az):  worst %.6f deg  %s"
		% [worst, "PASS" if worst < 0.001 else "FAIL"])

	# 2. against the hand calibrations, azimuth only (elevation is a separate
	#    question and was dialled while the sun was in the wrong place)
	print("\n%-14s %9s %9s   %s" % ["map", "data_az", "set_az", "residual"])
	for m in CAL:
		var c: Array = CAL[m]
		var el := float(c[1])
		var got: Vector3 = L.sun_dir(float(c[0]), el)       # nothing hand-set
		var want: Vector3 = _old_dir(float(c[2]), el)       # what they dialled
		print("%-14s %9.2f %9.2f   %6.2f deg" % [m, c[0], c[2], rad_to_deg(got.angle_to(want))])

	# 3. the sun must be ABOVE the horizon and shadows must run opposite it
	var d2: Vector3 = L.sun_dir(124.8, 28.5)
	print("\nDumbo dir %s  elevation %.2f  shadow %.2fx"
		% [d2, rad_to_deg(asin(d2.y)), sqrt(1.0 - d2.y * d2.y) / d2.y])
	quit(0)
