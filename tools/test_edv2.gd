@tool
extends SceneTree
# Round 2: (a) the smudge sheet actually builds an image with usable variance -
# t_3dperlinnoise is a 3D texture asset and the one decode in the chain that
# could plausibly come back flat or null; (b) MP_Subsurface, the biggest EDV
# map (dump probe: 1,204 indoor floor/wall markings), resolves at scale.

func _init() -> void:
	var fails := 0
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Capstone"):
		print("no source: ", gs.error)
		quit(1)
		return
	var md: Dictionary = gs.map_data("user://edvtest", {"edv": true})
	var noise_guid := ""
	for r in md.get("edv", []):
		if str((r as Dictionary).get("kind", "")) == "smudge":
			noise_guid = str((r as Dictionary).get("ca", ""))
			break
	if noise_guid == "":
		print("FAIL no smudge record on capstone")
		fails += 1
	else:
		var tex = gs.decal_sheet(noise_guid)
		if tex == null:
			print("FAIL the noise sheet does not decode")
			fails += 1
		else:
			var img: Image = (tex as Texture2D).get_image()
			var c := img.duplicate() as Image
			if c.is_compressed() and c.decompress() != OK:
				print("FAIL noise sheet cannot decompress")
				fails += 1
			else:
				c.convert(Image.FORMAT_RGBA8)
				var lo := 2.0
				var hi := -1.0
				for y in range(0, c.get_height(), maxi(1, c.get_height() / 24)):
					for x in range(0, c.get_width(), maxi(1, c.get_width() / 24)):
						var n := c.get_pixel(x, y).r
						lo = minf(lo, n)
						hi = maxf(hi, n)
				print("noise sheet %dx%d, r range %.2f..%.2f"
					% [c.get_width(), c.get_height(), lo, hi])
				if hi - lo < 0.15:
					print("FAIL noise sheet is flat - smudges would be uniform stamps")
					fails += 1
	gs = null

	var gs2 = HighpolyGameSource.new()
	if not gs2.open_map("MP_Subsurface"):
		print("no subsurface source: ", gs2.error)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var md2: Dictionary = gs2.map_data("user://edvtest2", {"edv": true})
	var recs: Array = md2.get("edv", [])
	var kinds := {}
	for r in recs:
		var kk := str((r as Dictionary).get("kind", "?"))
		kinds[kk] = int(kinds.get(kk, 0)) + 1
	print("subsurface: %d records in %d ms, kinds %s  [dump probe: 1,204 volumes]"
		% [recs.size(), Time.get_ticks_msec() - t0, str(kinds)])
	if recs.size() < 600:
		print("FAIL subsurface resolves under half the probe's count")
		fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
