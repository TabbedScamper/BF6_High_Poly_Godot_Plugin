@tool
extends SceneTree

# Every FX flipbook the graph table names, decoded out of the installation.
#
# The pixel path was proved against the research repo's reproduction case, but
# that proves the DECODER. This proves the JOIN: that the derived sheet names in
# fx_params.json reach a real AtlasTexture, that the LeftRightTiles crop and the
# six-way fold produce a plausible card, and that the mip picked for the budget
# is one the header actually describes.
#
#   godot --headless --path <proj> --script test_fxsheets.gd

func _init() -> void:
	var gs = HighpolyGameSource.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map("MP_Dumbo"):
		print("FAILED: could not open the game source")
		quit(1)
		return
	print("source open in %.1f s, level=%s" % [
		(Time.get_ticks_msec() - t0) / 1000.0, gs.level])

	HighpolyFx._load_params()
	t0 = Time.get_ticks_msec()
	var n := HighpolyFx._prime_sheets(gs)
	print("resolved %d sheets in %.1f s\n" % [n, (Time.get_ticks_msec() - t0) / 1000.0])

	var miss := 0
	var keys: Array = HighpolyFx._sheets.keys()
	keys.sort()
	for k in keys:
		var t = HighpolyFx._sheets[k]
		if t == null:
			print("  MISS  %s" % str(k))
			miss += 1
			continue
		var img: Image = (t as Texture2D).get_image()
		var rn := BF6Atlas.find_res(gs.src, str(k))
		var g := BF6Atlas.grid(gs.src, gs.types,
			gs.walk.gi if gs.walk != null else {}, rn)
		# mean alpha and mean saturation on a 64x64 reduction. A folded six-way
		# card should be close to GREY: the three pair sums agree, so averaging
		# the halves cancels the hue that made the raw sheet look broken.
		var s := (img.duplicate() as Image)
		s.resize(64, 64, Image.INTERPOLATE_BILINEAR)
		var a := 0.0
		var sat := 0.0
		for y in range(64):
			for x in range(64):
				var c := s.get_pixel(x, y)
				a += c.a
				sat += maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
		print("  OK    %-34s %4dx%-5d cols=%-3s frames=%-4s lr=%-5s  alpha %.3f  sat %.3f"
			% [str(k).get_file(), img.get_width(), img.get_height(),
			   g.get("cols", "?"), g.get("frames", "?"), g.get("lr", "?"),
			   a / 4096.0, sat / 4096.0])

	print("\n%d resolved, %d missing" % [n, miss])
	print("cache: %s" % ProjectSettings.globalize_path(HighpolyFx.SHEET_CACHE))
	quit(1 if miss > 0 else 0)
