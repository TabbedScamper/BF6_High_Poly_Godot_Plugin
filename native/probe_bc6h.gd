extends SceneTree

# Is the sky panorama BC6H SIGNED or UNSIGNED, and does our table know?
#
# The decoded sky has a mean luminance of 8,606 and a MINIMUM of -65,260.
# Negative radiance is not a thing a sky panorama contains, so the pixels are
# being decoded in the wrong flavour of the right format.
#
# BC6H has two: DXGI 95 BC6H_UF16 (unsigned) and DXGI 96 BC6H_SF16 (signed).
# Godot has one enum for each — FORMAT_BPTC_RGBFU and FORMAT_BPTC_RGBF. Our
# table maps BOTH BF6 format codes 64 and 65 to DXGI 96, so whichever of them
# means "unsigned" is being decoded as signed, and a leading 1 bit that should
# be magnitude becomes a sign.
#
# This is the same shape as the recorded srgb-dds-decode-fix: two DXGI codes
# that differ only in interpretation, collapsed to one in a lookup table.
#
#   godot --headless --path native/_testproj --script probe_bc6h.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Texture := preload("res://bf6_texture.gd")
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
	var src = gs.src

	# find the level's sky panorama RES by name
	var pano := ""
	for rn in src.res.keys():
		var n := str(rn).to_lower()
		var leaf := n.get_file()
		if leaf.contains("panoramicsky") and not leaf.contains("procedural") \
				and not leaf.contains("hdrcube") and leaf.contains(level):
			pano = str(rn); break
	if pano == "":
		for rn in src.res.keys():
			var n2 := str(rn).to_lower().get_file()
			if n2.contains("panoramicsky") and not n2.contains("procedural") \
					and not n2.contains("hdrcube"):
				pano = str(rn); break
	if pano == "":
		print("FAIL: no panorama in this mount"); quit(1); return
	print("panorama: %s" % pano)

	var raw: PackedByteArray = src.get_res(pano)
	var tx = BF6Texture.new()
	var hdr: Dictionary = tx.header(raw)
	print("header: %s" % str(hdr))
	var bf6_fmt := int(hdr.get("format", -1))
	var dxgi = BF6Texture.FMT.get(bf6_fmt, -1)
	print("\nBF6 format %d -> DXGI %s -> Godot %s"
		% [bf6_fmt, str(dxgi), str(BF6Texture.DXGI_GODOT.get(dxgi, -1))])
	print("   DXGI 95 = BC6H_UF16 (unsigned), 96 = BC6H_SF16 (signed)")

	var got := tx.decode(raw, func(form): return src.get_chunk(str(form)), 0)
	if got.is_empty() or not (got.get("image") is Image):
		print("FAIL decode: %s" % tx.error); quit(1); return
	var img: Image = got["image"]
	print("\ndecoded %dx%d, format %d, compressed %s"
		% [img.get_width(), img.get_height(), img.get_format(), img.is_compressed()])

	# The same block bytes read both ways.
	var comp := img.duplicate() as Image
	for pair in [["as signed (BC6H_SF16)", Image.FORMAT_BPTC_RGBF],
				 ["as unsigned (BC6H_UF16)", Image.FORMAT_BPTC_RGBFU]]:
		var label: String = pair[0]
		var fmt: int = pair[1]
		var t := Image.create_from_data(comp.get_width(), comp.get_height(),
			comp.has_mipmaps(), fmt, comp.get_data())
		if t == null:
			print("\n%-22s could not be built" % label)
			continue
		if t.decompress() != OK:
			print("\n%-22s does not decompress" % label)
			continue
		print("\n%-22s %s" % [label, _stats(t)])

	print("\nA sky has no negative radiance. Whichever reading has none, and a "
		+ "mean in\nthe low units rather than the thousands, is the right one.")
	quit(0)


func _stats(img: Image) -> String:
	var lo := INF
	var hi := -INF
	var sum := 0.0
	var n := 0
	var neg := 0
	for y in range(0, img.get_height(), 23):
		for x in range(0, img.get_width(), 23):
			var c := img.get_pixel(x, y)
			var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			lo = minf(lo, l); hi = maxf(hi, l); sum += l; n += 1
			if c.r < 0.0 or c.g < 0.0 or c.b < 0.0:
				neg += 1
	return ("min %.4f  mean %.4f  max %.4f  negative pixels %.1f%%"
		% [lo, sum / float(maxi(1, n)), hi, 100.0 * float(neg) / float(maxi(1, n))])
