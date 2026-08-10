@tool
extends SceneTree
# #93 end to end: the surface build writes the palette, the classification
# finds the vegetation layers, and the coverage numbers are sane on the map
# whose ground is mostly plants (Badlands: oakshrub 51%, driedgrass, lawns).

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Badlands"):
		print("no source"); quit(1); return
	var dir := "user://painted_test"
	var sf: Dictionary = gs.terrain_surface(dir, true)
	if sf.is_empty():
		print("FAIL surface"); quit(1); return
	var pal: Array = sf.get("palette", [])
	print("palette rows: %d" % pal.size())
	var fails := 0
	if pal.size() < 40: print("FAIL palette missing"); fails += 1
	var cls := PackedByteArray(); cls.resize(256)
	var veg_layers := 0
	for prow in pal:
		var nm := str((prow as Dictionary).get("tex", "")).to_lower()
		for w in HighpolyScatter.VEG_WORDS:
			if nm.contains(str(w)):
				cls[int((prow as Dictionary).get("layer", 0))] = 1
				veg_layers += 1
				break
	print("vegetation layers: %d" % veg_layers)
	if veg_layers < 5: print("FAIL too few veg layers"); fails += 1
	var idx := Image.load_from_file(ProjectSettings.globalize_path("%s/splat/idx_raw.png" % dir))
	var wim := Image.load_from_file(ProjectSettings.globalize_path("%s/splat/w.png" % dir))
	if idx == null or wim == null:
		print("FAIL raw files"); quit(1); return
	var di := idx.get_data()
	var dw := wim.get_data()
	var res := idx.get_width()
	var veg_tex := 0
	var any_tex := 0
	var n := 0
	var o := 0
	var step := 4 * 7   # sample every 7th texel
	while o + 3 < di.size():
		n += 1
		var vw := 0
		var tw := 0
		for s in range(4):
			var w2 := int(dw[o + s])
			if w2 == 0: continue
			tw += w2
			var li := int(di[o + s])
			if li < 255 and int(cls[li]) == 1:
				vw += w2
		if tw > 0: any_tex += 1
		if vw > 64: veg_tex += 1
		o += step
	var veg_frac := float(veg_tex) / float(n)
	var painted_frac := float(any_tex) / float(n)
	print("sampled %d texels: painted %.1f%%, vegetation-dominant %.1f%%" % [n, painted_frac * 100.0, veg_frac * 100.0])
	if veg_frac < 0.15 or veg_frac > 0.95: print("FAIL veg fraction out of band"); fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
