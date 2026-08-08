extends SceneTree
# Aftermath's panorama reportedly HAS a painted sun. If so it is ground truth for
# the sun angle, which our finding claims nothing shipped can supply. Find the
# brightest region, convert its UV to a direction, and compare with what
# SunRotationX/Y give through sun_dir().
const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const LS = preload("res://addons/highpoly_toggle/highpoly_lighting.gd")

func look(map: String, az: float, el: float) -> void:
	var g = GS.new(); g.geom_cache = false
	if not g.open_map(map, "", Callable()): print("%s: open failed" % map); return
	var s: Dictionary = g.sky()
	if s.is_empty(): print("%s: no panorama" % map); return
	var img: Image = (s["texture"] as ImageTexture).get_image()
	var w := img.get_width(); var h := img.get_height()
	# brightest texel, and the centroid of everything within 92% of it
	var best := -1.0; var bx := 0; var by := 0
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			var l: float = c.r + c.g + c.b
			if l > best: best = l; bx = x; by = y
	var cut := best * 0.92
	var sx := 0.0; var sy := 0.0; var n := 0
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			if c.r + c.g + c.b >= cut:
				sx += float(x); sy += float(y); n += 1
	var cx := sx / maxf(1.0, float(n)); var cy := sy / maxf(1.0, float(n))
	# UV -> direction, inverting the shader's mapping exactly
	var u := cx / float(w); var v := cy / float(h)
	var theta := u * TAU                       # atan(x, -z), wrapped to 0..TAU
	var phi := v * PI                          # acos(y)
	var dir := Vector3(sin(theta) * sin(phi), cos(phi), -cos(theta) * sin(phi)).normalized()
	# back to compass bearing / elevation
	var pano_az := rad_to_deg(atan2(dir.x, dir.z)); if pano_az < 0.0: pano_az += 360.0
	var pano_el := rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
	var ours: Vector3 = LS.sun_dir(az, el)
	print("\n=== %s  (%s) ===" % [map, str(s.get("preset", "?"))])
	print("  panorama %dx%d, brightest sum %.2f, bright region %d texel(s)" % [w, h, best, n])
	print("  painted sun at uv (%.4f, %.4f)  ->  dir %s" % [u, v, str(dir.snapped(Vector3(0.001,0.001,0.001)))])
	print("  painted  az %.1f  el %.1f" % [pano_az, pano_el])
	print("  authored az %.1f  el %.1f  -> dir %s" % [az, el, str(ours.snapped(Vector3(0.001,0.001,0.001)))])
	print("  angle between painted and authored: %.1f deg" % rad_to_deg(acos(clampf(dir.dot(ours), -1.0, 1.0))))

func _initialize() -> void:
	look("mp_aftermath", 237.90, 12.90)
	look("mp_dumbo", 124.80, 28.50)
	quit()
