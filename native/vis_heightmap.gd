extends SceneTree

# The two heightmaps as pictures, side by side.
#
# A 3D view is the wrong instrument here: Dumbo's relief is 86 m over 8,192 m,
# about 1%, so from any distance that fits the map both grids render as flat
# slabs and agree perfectly whether or not they are the same. What actually
# needs checking is LAYOUT — a transpose, a flipped axis, a quadrant swap — and
# those are obvious in a top-down image and invisible in a shaded plane.
#
# Each grid is normalised to its OWN range before drawing, so the encoding
# difference (ours raw 6336..28302, the packaged one stretched to 0..65450) does
# not show up as a brightness difference and hide the thing being looked for.
#
#   godot --headless --path <proj> --script vis_heightmap.gd -- <out.png> [level] [ref.r16]

const BF6Source := preload("res://bf6_source.gd")
const BF6Terrain := preload("res://bf6_terrain.gd")

const OUT := 512                 # pixels per panel


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var out_png := "heightmap.png"
	var level := "mp_dumbo"
	var ref_r16 := ""
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			out_png = s; seen = 1
		elif seen == 1:
			level = s; seen = 2
		else:
			ref_r16 = s

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount"); quit(1); return
	var pick := ""
	for rn in src.res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains(level):
			pick = n
			break
	var t := BF6Terrain.new()
	var res := src.get_res(pick)
	var blk := t.find_block(res, BF6Terrain.BLOCK_HEIGHTS)
	if blk.is_empty() or not t.read_block_header(blk) or not t.walk_nodes(blk):
		print("FAIL parse: %s" % t.error); quit(1); return
	t.resolve_external(t.read_chunk_directory(res),
		func(form): return src.get_chunk(str(form)))
	var g := t.composite(4097)
	if g.is_empty():
		print("FAIL composite: %s" % t.error); quit(1); return

	var panels: Array = [_panel(g["data"], int(g["size"]), "ours")]
	if ref_r16 != "" and FileAccess.file_exists(ref_r16):
		var rb := FileAccess.get_file_as_bytes(ref_r16)
		var rn2 := int(round(sqrt(float(rb.size() / 2))))
		panels.append(_panel(rb, rn2, "packaged"))

	var w := OUT * panels.size() + 8 * (panels.size() - 1)
	var img := Image.create(w, OUT, false, Image.FORMAT_RGB8)
	img.fill(Color(0.1, 0.1, 0.12))
	var x0 := 0
	for p in panels:
		img.blit_rect(p as Image, Rect2i(0, 0, OUT, OUT), Vector2i(x0, 0))
		x0 += OUT + 8
	var err := img.save_png(out_png)
	print("%s %s (%d panels)" % ["wrote" if err == OK else "FAILED", out_png,
		panels.size()])
	quit(0 if err == OK else 1)


# One grid, normalised to its own min/max so the two are comparable as SHAPES
# rather than as brightness.
func _panel(raw: PackedByteArray, res: int, label: String) -> Image:
	var lo := 65535
	var hi := 0
	var step: int = maxi(1, int(res / OUT))
	for z in range(0, res, step):
		for x in range(0, res, step):
			var v := raw.decode_u16((z * res + x) * 2)
			lo = mini(lo, v); hi = maxi(hi, v)
	var span: float = maxf(1.0, float(hi - lo))
	print("%-10s res %d, raw range %d..%d" % [label, res, lo, hi])
	var img := Image.create(OUT, OUT, false, Image.FORMAT_RGB8)
	for py in range(OUT):
		var sz: int = mini(int(float(py) / OUT * res), res - 1)
		for px in range(OUT):
			var sx: int = mini(int(float(px) / OUT * res), res - 1)
			var v := raw.decode_u16((sz * res + sx) * 2)
			var f: float = clampf((float(v) - lo) / span, 0.0, 1.0)
			img.set_pixel(px, py, Color(f, f, f))
	return img
