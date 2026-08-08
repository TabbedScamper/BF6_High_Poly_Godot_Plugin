extends SceneTree
# Does the level's own sky panorama come out of the install, and is it the right
# shape? The 4:1 -> 2:1 remap is the thing worth checking: handed straight to a
# PanoramaSkyMaterial, a 360x90 dome puts the painted sun below the horizon.
const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	for x in a:
		if str(x) != "": level = str(x); break
	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error); quit(1); return
	print("VE candidates: %s" % str(gs._ve_candidates()))
	var s: Dictionary = gs.sky()
	if s.is_empty():
		print("FAIL: no panorama"); quit(1); return
	var t: ImageTexture = s["texture"]
	var img := t.get_image()
	print("panorama     %d x %d, format %d" % [img.get_width(), img.get_height(), img.get_format()])
	print("aspect       %.2f : 1  (2:1 is what PanoramaSkyMaterial wants)"
		% (float(img.get_width()) / maxf(1.0, float(img.get_height()))))
	print("luminance    %.0f" % float(s["luminance_scale"]))
	print("rotation     %.3f" % float(s["rotation"]))
	var fail := 0
	var ar := float(img.get_width()) / maxf(1.0, float(img.get_height()))
	if absf(ar - 2.0) > 0.05:
		print("\nFAIL: aspect %.2f is not 2:1 — the dome remap did not happen" % ar)
		fail += 1
	if float(s["luminance_scale"]) <= 0.0:
		print("\nFAIL: no LuminanceScale; panoramas ship normalised so the texture alone is not the brightness")
		fail += 1
	# The lower half must be the carried-down horizon, not a copy of the zenith:
	# if it were, the remap wrote the wrong half.
	var c := img.duplicate() as Image
	if c.is_compressed(): c.decompress()
	var zenith := c.get_pixel(int(c.get_width() / 2), 2)
	var horizon := c.get_pixel(int(c.get_width() / 2), int(c.get_height() / 2) - 2)
	var below := c.get_pixel(int(c.get_width() / 2), int(c.get_height() * 0.9))
	print("\nzenith  %s\nhorizon %s\nbelow   %s" % [zenith, horizon, below])
	if below.is_equal_approx(zenith) and not below.is_equal_approx(horizon):
		print("\nFAIL: below-horizon repeats the ZENITH — the halves are swapped")
		fail += 1
	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)
