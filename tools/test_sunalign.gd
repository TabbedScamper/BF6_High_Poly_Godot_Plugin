extends SceneTree
# Does the drawn sun land on the painted one?
#
# The panorama's brightest region is the sun (its bearing is stable to 0.3 deg
# across a 200x threshold change, and on aftermath its elevation matches the
# authored SunRotationY to 0.15 deg). So the sky rotation we apply is checkable:
# painted bearing + rotation must equal the authored azimuth the DirectionalLight
# is aimed from.
const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
var fails: Array = []
func ck(c: bool, w: String) -> void:
	print(("  ok   " if c else "  FAIL ") + w)
	if not c: fails.append(w)

func painted(img: Image) -> Array:
	var w := img.get_width(); var h := img.get_height()
	var best := -1.0
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			if c.r + c.g + c.b > best: best = c.r + c.g + c.b
	var cut := best * 0.92
	var sx := 0.0; var sy := 0.0; var n := 0
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			if c.r + c.g + c.b >= cut:
				sx += float(x); sy += float(y); n += 1
	var u := (sx / float(n)) / float(w); var v := (sy / float(n)) / float(h)
	var th := u * TAU; var ph := v * PI
	var d := Vector3(sin(th) * sin(ph), cos(ph), -cos(th) * sin(ph))
	var az := rad_to_deg(atan2(d.x, d.z)); if az < 0.0: az += 360.0
	return [az, rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))]

func check(map: String, authored_az: float, tol: float) -> void:
	var g = GS.new(); g.geom_cache = false
	if not g.open_map(map, "", Callable()):
		ck(false, "%s: could not open" % map); return
	var s: Dictionary = g.sky()
	if s.is_empty():
		ck(false, "%s: no panorama" % map); return
	var p := painted((s["texture"] as ImageTexture).get_image())
	# the rotation the plugin applies
	var applied: float = fmod(float(s.get("rotation", 0.0)) + 0.5, 1.0) * 360.0
	var lands: float = fmod(float(p[0]) + applied + 720.0, 360.0)
	var err: float = absf(fmod(lands - authored_az + 540.0, 360.0) - 180.0)
	print("  %s: painted az %.1f + applied rotation %.1f = %.1f, sun aimed at %.1f, error %.1f deg"
		% [map, float(p[0]), applied, lands, authored_az, err])
	ck(err <= tol, "%s: painted sun lands on the drawn sun within %.0f deg" % [map, tol])

func _initialize() -> void:
	print("\n--- sun alignment ---")
	# aftermath is the calibration map: a hard sunset disc the sky is composed
	# around, and its painted elevation matches the authored value to 0.15 deg.
	check("mp_aftermath", 237.90, 2.0)
	# dumbo's sun is a diffuse cloudy glow that misses its OWN authored elevation
	# by 4.6 deg, so it is held to a loose bound on purpose. Tightening this
	# would be fitting the rule to the art.
	check("mp_dumbo", 124.80, 15.0)
	print("\n%s  (%d failure(s))" % ["PASS" if fails.is_empty() else "FAILED", fails.size()])
	quit(0 if fails.is_empty() else 1)
