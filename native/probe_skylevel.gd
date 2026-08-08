extends SceneTree

# How bright is the panorama the game ships, in the units Godot will sample it in?
#
# The sky path assumed the answer was "about 1". That assumption came from the
# OLD pipeline's sky.exr, whose stats are quoted in highpoly_lighting as
# "measured mean 0.057-1.345 across all 22" — but that EXR was a CONVERSION,
# and the conversion is where the normalising happened. The texture read
# straight out of the install has had nothing done to it, and it is fed to the
# same line that multiplies by LuminanceScale / 7000.
#
# If the raw panorama's mean is far from 1, that line is multiplying an
# already-absolute HDR sky by the magnitude a second time, and the whole world
# goes white.
#
#   godot --headless --path native/_testproj --script probe_skylevel.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return

	var sky: Dictionary = gs.sky()
	if sky.is_empty():
		print("no sky on %s" % level); quit(1); return
	print("\nluminance_scale (VE LuminanceScale): %.1f" % float(sky["luminance_scale"]))

	var tex = sky["texture"]
	if tex == null:
		print("FAIL: no texture"); quit(1); return
	var img: Image = tex.get_image()
	if img == null:
		print("FAIL: no image behind the texture"); quit(1); return
	print("panorama %dx%d, format %d, mipmaps %s"
		% [img.get_width(), img.get_height(), img.get_format(), img.has_mipmaps()])

	if img.is_compressed():
		if img.decompress() != OK:
			print("FAIL: cannot decompress"); quit(1); return
		print("decompressed to format %d" % img.get_format())

	# Sample on a coarse grid: this is 8192x4096 and we want the level, not
	# every pixel.
	var lo := INF
	var hi := -INF
	var sum := 0.0
	var n := 0
	var over1 := 0
	for y in range(0, img.get_height(), 17):
		for x in range(0, img.get_width(), 17):
			var c := img.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			lo = minf(lo, l); hi = maxf(hi, l); sum += l; n += 1
			if l > 1.0:
				over1 += 1
	var mean := sum / float(maxi(1, n))
	print("\nluminance over %d samples:" % n)
	print("   min  %.5f" % lo)
	print("   mean %.5f" % mean)
	print("   max  %.5f" % hi)
	print("   above 1.0: %.1f%%" % (100.0 * float(over1) / float(maxi(1, n))))

	# What the current code does, and what it should do.
	const SKY_REF := 7000.0
	var energy := clampf(float(sky["luminance_scale"]) / SKY_REF, 0.05, 20.0)
	print("\ncurrent sky energy_multiplier: %.3f" % energy)
	print("so the sky renders at a mean of %.2f and a peak of %.2f"
		% [mean * energy, hi * energy])
	if mean * energy > 3.0:
		print("   -> that is a blown-out sky, and ambient comes from the sky, "
			+ "so the whole world goes with it")
	print("\nto land the sky's mean on 1.0 the multiplier would be %.4f" % (1.0 / maxf(mean, 0.00001))
		+ "  (x LuminanceScale/%.0f = %.4f)" % [SKY_REF, energy / maxf(mean, 0.00001)])
	quit(0)
