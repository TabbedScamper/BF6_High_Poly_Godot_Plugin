extends SceneTree
# Required sky rotation vs the authored PanoramicRotation, and how stable the
# painted-sun bearing is against the brightness threshold used to find it.
# A bearing that wanders with the threshold is a diffuse glow, not a disc, and is
# the weaker measurement.
const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")

func bearing_at(img: Image, frac: float) -> Array:
	var w := img.get_width(); var h := img.get_height()
	var best := -1.0
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			var l: float = c.r + c.g + c.b
			if l > best: best = l
	var cut := best * frac
	var sx := 0.0; var sy := 0.0; var n := 0
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			if c.r + c.g + c.b >= cut:
				sx += float(x); sy += float(y); n += 1
	if n == 0: return [0.0, 0.0, 0]
	var u := (sx / float(n)) / float(w)
	var v := (sy / float(n)) / float(h)
	var theta := u * TAU; var phi := v * PI
	var dir := Vector3(sin(theta) * sin(phi), cos(phi), -cos(theta) * sin(phi))
	var az := rad_to_deg(atan2(dir.x, dir.z)); if az < 0.0: az += 360.0
	return [az, rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))), n]

func look(map: String, authored_az: float) -> void:
	var g = GS.new(); g.geom_cache = false
	if not g.open_map(map, "", Callable()): return
	var s: Dictionary = g.sky()
	if s.is_empty(): return
	var img: Image = (s["texture"] as ImageTexture).get_image()
	var rot := float(s.get("rotation", 0.0))
	print("\n=== %s   PanoramicRotation %.4f turns (%.1f deg), authored az %.1f ==="
		% [map, rot, rot * 360.0, authored_az])
	for frac in [0.995, 0.98, 0.92, 0.80, 0.60]:
		var r := bearing_at(img, frac)
		var painted: float = r[0]
		var need: float = fmod(authored_az - painted + 720.0, 360.0)
		print("  cut %.3f  %6d texels  painted az %6.1f  el %5.1f  ->  rotation NEEDED %6.1f deg (%.4f turns)"
			% [frac, int(r[2]), painted, float(r[1]), need, need / 360.0])
	print("  authored rotation %.4f turns; +0.5 turns = %.4f" % [rot, fmod(rot + 0.5, 1.0)])

func _initialize() -> void:
	look("mp_aftermath", 237.90)
	look("mp_dumbo", 124.80)
	quit()
