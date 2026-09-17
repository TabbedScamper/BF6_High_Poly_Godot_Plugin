extends SceneTree

# HOW BIG ARE THE WATER TILES, REALLY?
#
#   python tools/run_addon_script.py native/probe_water_tree.gd --args <steam> [level]
#
# Two water fixes have now failed to stop Tsuru Reef boiling, and both rested on
# the same unmeasured assumption: that the finest draw-tree tile is 16 m, so the
# mesh has one metre between vertices. Everything downstream depends on that
# number - the mip floor I added computes log2(vertex_spacing / texel), so if
# the real tiles are much smaller the floor is zero and the "fix" does nothing
# at all, which would explain why nothing changed.
#
# So measure it. The tree comes from the core, the same call the driver makes.

const NativeWater := preload("res://addons/highpoly_toggle/highpoly_native_water.gd")

func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: probe_water_tree.gd -- <steam root> [level]"); quit(2); return
	var level := str(a[1]) if a.size() > 1 else "mp_isolated"
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0])):
		print("FAIL open"); quit(1); return
	if not core.has_method("water_draw_tree"):
		print("FAIL: this binding has no water_draw_tree"); quit(1); return

	# The bounds the driver hands the tree, plus a camera. Tsuru's ocean is
	# 5946 m square centred near (-700, 0) per water_test.
	var half := 2973.0
	var cx := -700.0
	var cz := 0.0
	print("%s: tile widths from the core's draw tree\n" % level)
	print("%-28s %8s %9s %9s %s"
		% ["camera", "tiles", "min_w_m", "max_w_m", "finest vertex spacing"])
	for cam in [Vector3(cx, 30.0, cz), Vector3(cx, 120.0, cz), Vector3(cx + 1500.0, 60.0, cz)]:
		# The driver's own argument order (highpoly_native_water.gd): camera
		# x, z, y then forward x, z, then hfov, viewport width, then the
		# surface bounds x0, z0, x1, z1, height, then patch quads, tile cap and
		# off-view depth. Copied from the call site rather than reconstructed,
		# because a probe that passes a different shape measures a different
		# tree than the one that ships.
		var args := PackedFloat32Array([
			cam.x, cam.z, cam.y, 0.0, 1.0, 1.4, 1920.0,
			cx - half, cz - half, cx + half, cz + half, 100.0,
			float(NativeWater.PATCH_QUADS), 4096.0, 4.0])
		var tiles: PackedFloat32Array = core.call("water_draw_tree", args)
		var n := tiles.size() / 4
		if n <= 0:
			print("%-28s %8s" % [str(cam), "no tiles - signature may differ"])
			continue
		var wmin := 1e30
		var wmax := -1e30
		var hist := {}
		for i in range(n):
			var w := tiles[i * 4 + 2]
			wmin = minf(wmin, w)
			wmax = maxf(wmax, w)
			hist[w] = int(hist.get(w, 0)) + 1
		print("%-28s %8d %9.2f %9.2f %.4f m"
			% [str(cam), n, wmin, wmax, wmin / float(NativeWater.PATCH_QUADS)])
		var keys := hist.keys()
		keys.sort()
		var line := "   widths:"
		for k in keys:
			line += " %.1f x%d" % [k, hist[k]]
		print(line)

	# What that means for each cascade, which is the number the fix turns on.
	print("\nAgainst the cascades (texel = tile/resolution):")
	print("   #0 texel 2.3438   #1 1.0562   #2 1.3438   #3 0.0938")
	print("   mip floor = log2(vertex_spacing / texel), clamped at 0.")
	print("   If the finest vertex spacing is well under 0.09 m, the floor is")
	print("   zero everywhere and the mip fix cannot have changed anything.")
	quit(0)
