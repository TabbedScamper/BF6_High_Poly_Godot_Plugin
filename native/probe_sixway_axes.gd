extends SceneTree

# WHICH CHANNEL IS WHICH AXIS in a six-way lightmap?
#
#   python tools/run_addon_script.py native/probe_sixway_axes.gd --args <steam> [level]
#
# The packing finding proves the two halves of a LeftRightTiles sheet carry
# three directions and their three opposites, and deliberately does not settle
# WHICH direction each channel is - "that needs a shader, not a statistical
# test". The shader exists now, and the assignment is a uniform in it precisely
# because it was a guess. This is the test that can retire the guess.
#
# THE IDEA. A six-way term is the light arriving from one direction, so for a
# roughly convex puff the channel for direction d is brightest on the side of
# the puff FACING d. That is a property of the pixels, not of the renderer:
#
#   * the channel pair for the LEFT/RIGHT axis has its brightness centroid
#     displaced horizontally, and the two halves displace OPPOSITE ways;
#   * the UP/DOWN pair displaces vertically, opposite ways;
#   * the pair for the view axis (BACK/FRONT) is the discriminator - light from
#     in front or behind lands on the near or far face, which a flat sheet sees
#     head on, so that pair should displace LEAST in both directions.
#
# So: measure the centroid of each of the six channels inside one frame,
# relative to the frame's own alpha centroid, and read the axes off the answer.
# Reported with the numbers, so a weak result reads as weak.

const BF6Atlas := preload("res://addons/highpoly_toggle/bf6_atlas.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: probe_sixway_axes.gd -- <steam root> [level]"); quit(2); return
	var level := str(a[1]) if a.size() > 1 else "mp_isolated"
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0])):
		print("FAIL open"); quit(1); return
	var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
	var d: Dictionary = env.request("fx_layers")
	var rows: Array = d.get("layers", [])
	if rows.is_empty():
		print("FAIL no layers: %s" % str(env.error)); quit(1); return

	# The source has to be open for the atlas bytes; the environment alone only
	# names them.
	var gs = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd").new()
	if not gs.open_map(level, str(a[0]), func(_s, _dd, _t): pass):
		print("FAIL open_map: %s" % gs.error); quit(1); return

	var seen := {}
	var tested := 0
	var totals := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]   # dx per channel, weighted
	var totals_y := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for r in rows:
		if tested >= 6:
			break
		var L: Dictionary = r
		if int(L.get("atlas_left_right", 0)) == 0:
			continue
		var res := str(L.get("atlas_res", ""))
		if res.is_empty() or seen.has(res):
			continue
		seen[res] = true
		var img := _decode(gs, res)
		if img == null:
			continue
		var cols := maxi(int(L.get("atlas_cols", 1)), 1)
		var frames := maxi(int(L.get("atlas_frames", 1)), 1)
		var stats := _frame_centroids(img, cols, frames)
		if stats.is_empty():
			continue
		tested += 1
		print("\n%s  %dx%d grid, %d frames, %dx%d px"
			% [res, cols, int(ceil(float(frames) / cols)), frames,
			   img.get_width(), img.get_height()])
		var names := ["L.r", "L.g", "L.b", "R.r", "R.g", "R.b"]
		print("   %-5s %8s %8s   (offset from the frame's own alpha centroid, in cell widths)"
			% ["chan", "dx", "dy"])
		for i in range(6):
			print("   %-5s %+8.4f %+8.4f" % [names[i], stats["dx"][i], stats["dy"][i]])
			totals[i] += float(stats["dx"][i])
			totals_y[i] += float(stats["dy"][i])

	if tested == 0:
		print("no six-way sheet decoded on %s" % level); quit(1); return

	print("\n==== MEAN OVER %d SHEET(S) ====" % tested)
	var names := ["L.r", "L.g", "L.b", "R.r", "R.g", "R.b"]
	for i in range(6):
		print("   %-5s dx %+8.4f   dy %+8.4f" % [names[i], totals[i] / tested, totals_y[i] / tested])
	# Which PAIR moves least: that is the view axis, and it is the one piece
	# that cannot be read off a single channel.
	var mag := []
	for i in range(3):
		var m := absf(totals[i] / tested) + absf(totals_y[i] / tested) \
			+ absf(totals[i + 3] / tested) + absf(totals_y[i + 3] / tested)
		mag.append(m)
	print("\n   pair displacement magnitude: r=%.4f g=%.4f b=%.4f" % [mag[0], mag[1], mag[2]])
	var quietest := 0
	for i in range(3):
		if mag[i] < mag[quietest]: quietest = i
	print("   quietest pair (the view axis, if this test has power): %s"
		% ["r", "g", "b"][quietest])
	print("\nREAD IT AS: the pair that moves horizontally is the screen X axis,")
	print("the pair that moves vertically is Y, and the quiet pair is the view")
	print("axis. A result where all three are similar means the test has no")
	print("power on this art and the shader's uniform stays a uniform.")
	quit(0)


func _decode(gs, res: String) -> Image:
	var rn: String = res if gs.src.res.has(res) else BF6Atlas.find_res(gs.src, res)
	if rn.is_empty():
		return null
	var hdr: Dictionary = BF6Atlas.parse(gs.src.get_res(rn))
	if hdr.is_empty():
		return null
	var level := 0
	var sizes: Array = hdr["sizes"]
	while level + 1 < sizes.size() and (int(hdr["width"]) >> level) > 1024:
		level += 1
	var img: Image = BF6Atlas.mip_image(gs.src, hdr, level)
	if img == null:
		return null
	img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


# The six channels' brightness centroids within ONE frame, as an offset from
# that frame's alpha centroid. Using the alpha centroid as the origin is what
# removes the puff's own off-centre placement from the answer.
func _frame_centroids(img: Image, cols: int, frames: int) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	@warning_ignore("integer_division")
	var half := w / 2
	var rows := int(ceil(float(frames) / cols))
	if half < 8 or rows < 1:
		return {}
	@warning_ignore("integer_division")
	var cw := half / cols
	@warning_ignore("integer_division")
	var ch := h / rows
	if cw < 8 or ch < 8:
		return {}
	# A middle frame: the first is often nearly empty and the last nearly gone.
	var fi := mini(frames / 2, frames - 1)
	var fx := (fi % cols) * cw
	var fy := (fi / cols) * ch

	var sum := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var sx := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var sy := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var asum := 0.0
	var ax := 0.0
	var ay := 0.0
	for y in range(ch):
		for x in range(cw):
			var lp := img.get_pixel(fx + x, fy + y)
			var rp := img.get_pixel(fx + x + half, fy + y)
			var av: float = lp.a
			if av <= 0.02:
				continue
			asum += av
			ax += av * x
			ay += av * y
			var v := [lp.r, lp.g, lp.b, rp.r, rp.g, rp.b]
			for i in range(6):
				var c: float = v[i]
				sum[i] += c
				sx[i] += c * x
				sy[i] += c * y
	if asum <= 0.0:
		return {}
	var cx := ax / asum
	var cy := ay / asum
	var dx := []
	var dy := []
	for i in range(6):
		if sum[i] <= 0.0:
			dx.append(0.0); dy.append(0.0); continue
		dx.append((sx[i] / sum[i] - cx) / float(cw))
		dy.append((sy[i] / sum[i] - cy) / float(ch))
	return {"dx": dx, "dy": dy}
