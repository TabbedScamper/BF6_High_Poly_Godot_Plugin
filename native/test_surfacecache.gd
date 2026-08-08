extends SceneTree

# The whole ground pipeline, end to end, as the plugin runs it: open the game,
# build the terrain surface into a map cache, and check that what lands on disk
# is what the terrain shader's splat path expects to read.
#
# The shader is unforgiving in one specific way and it has bitten this project
# before: Texture2DArray.create_from_images rejects a set whose images are not
# all the same size and leaves a ZERO-LAYER texture behind. Zero layers is not
# null, so every downstream null check passes and the shader samples an empty
# array across the entire map — the speckled-black ground. So the sizes are
# checked here, at the point they are written, not at the point they are loaded.
#
#   godot --headless --path native/_testproj --script test_surfacecache.gd -- [level]

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

	var cache := "user://surfacetest/%s" % level
	# Always rebuild: a cached result would make this test pass without running
	# any of the code it exists to test.
	var t0 := Time.get_ticks_msec()
	var meta: Dictionary = gs.terrain_surface(cache, true)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	if meta.is_empty():
		print("FAIL: terrain_surface produced nothing"); quit(1); return
	print("\nbuilt in %.1f s" % secs)

	var fail := 0
	var slices := int(meta.get("slices", 0))
	print("slices: %d" % slices)
	if slices <= 0:
		print("FAIL: no textured slices"); fail += 1

	for f in ["idx.png", "w.png", "layers.json"]:
		var p := "%s/splat/%s" % [cache, f]
		if not FileAccess.file_exists(p):
			print("FAIL: missing %s" % f); fail += 1
	if not FileAccess.file_exists("%s/colormap.png" % cache):
		print("FAIL: missing colormap.png"); fail += 1

	# --- every slice present, and every slice the SAME SIZE -----------------
	var dims := {}
	var missing := 0
	for i in range(slices):
		for tag in ["alb", "nrm"]:
			var p := "%s/splat/l%02d_%s.png" % [cache, i, tag]
			if not FileAccess.file_exists(p):
				missing += 1
				continue
			var img := Image.load_from_file(ProjectSettings.globalize_path(p))
			if img == null:
				missing += 1
				continue
			dims["%dx%d" % [img.get_width(), img.get_height()]] = true
	print("slice images missing: %d" % missing)
	print("distinct slice sizes: %s" % str(dims.keys()))
	if missing > 0:
		fail += 1
	if dims.size() != 1:
		print("FAIL: slices are not all the same size — Texture2DArray would "
			+ "silently produce a 0-layer texture")
		fail += 1

	# --- the array actually builds ------------------------------------------
	var albs: Array[Image] = []
	var nrms: Array[Image] = []
	for i in range(slices):
		var a := Image.load_from_file(ProjectSettings.globalize_path(
			"%s/splat/l%02d_alb.png" % [cache, i]))
		var n := Image.load_from_file(ProjectSettings.globalize_path(
			"%s/splat/l%02d_nrm.png" % [cache, i]))
		if a == null or n == null:
			continue
		a.convert(Image.FORMAT_RGB8); a.generate_mipmaps(); albs.append(a)
		n.convert(Image.FORMAT_RGB8); n.generate_mipmaps(); nrms.append(n)
	if albs.size() == slices and slices > 0:
		var ta := Texture2DArray.new()
		var err := ta.create_from_images(albs)
		print("albedo array: err %d, %d layers" % [err, ta.get_layers()])
		if err != OK or ta.get_layers() != slices:
			print("FAIL: the albedo array did not build"); fail += 1

	# --- the index raster points somewhere real -----------------------------
	var idx := Image.load_from_file(ProjectSettings.globalize_path(
		"%s/splat/idx.png" % cache))
	var wgt := Image.load_from_file(ProjectSettings.globalize_path(
		"%s/splat/w.png" % cache))
	if idx != null and wgt != null:
		var in_range := 0
		var fallback := 0
		var empty := 0
		var n := 0
		for z in range(0, idx.get_height(), 13):
			for x in range(0, idx.get_width(), 13):
				n += 1
				var w := wgt.get_pixel(x, z).r
				if w <= 0.0:
					empty += 1
					continue
				var id := int(round(idx.get_pixel(x, z).r * 255.0))
				if id < slices:
					in_range += 1
				else:
					fallback += 1
		print("\nindex raster over %d samples: %.1f%% textured slice, "
			% [n, 100.0 * float(in_range) / float(maxi(1, n))]
			+ "%.1f%% shader-computed layer, %.1f%% unpainted"
			% [100.0 * float(fallback) / float(maxi(1, n)),
			   100.0 * float(empty) / float(maxi(1, n))])
		if in_range == 0:
			print("FAIL: not one texel resolves to a textured slice"); fail += 1

	# --- the colour map is a photo, not a flat fill --------------------------
	var cm := Image.load_from_file(ProjectSettings.globalize_path(
		"%s/colormap.png" % cache))
	if cm == null:
		print("FAIL: colour map did not load"); fail += 1
	else:
		var lo := 2.0
		var hi := -1.0
		var sum := 0.0
		var cnt := 0
		for z in range(0, cm.get_height(), 29):
			for x in range(0, cm.get_width(), 29):
				var l := cm.get_pixel(x, z).get_luminance()
				lo = minf(lo, l); hi = maxf(hi, l); sum += l; cnt += 1
		print("colour map %dx%d, luminance %.3f..%.3f mean %.3f"
			% [cm.get_width(), cm.get_height(), lo, hi, sum / float(maxi(1, cnt))])
		# A decode that went wrong lands on a constant or on noise. §5.3 says the
		# raster is 0.5-centred, so a mean far from 0.5 or a range of nearly
		# nothing both mean the tiles are not being read as BC7.
		if hi - lo < 0.2:
			print("FAIL: the colour map has almost no contrast"); fail += 1
		if absf(sum / float(maxi(1, cnt)) - 0.5) > 0.2:
			print("FAIL: the colour map is not 0.5-centred"); fail += 1

	print("\nfallback layers written: %s"
		% str(DirAccess.get_files_at("%s/terrain_layers" % cache)))

	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)
