extends SceneTree

# WHERE IS A ROAD DECAL'S TRANSPARENCY, REALLY?
#
# The road shader reads `op` as `texture(op, UV).r` and falls back to the
# basecolor's alpha when there is no op. Both halves of that are assumptions:
#
#   1. that the coverage rides the RED channel of the op texture. An op sheet
#      could be BC4 (one channel, R is the only choice), or BC7/BC3 where the
#      mask is just as likely to be in A.
#
#   2. that a record with no op slot is fully opaque. 195 of this map's 433
#      records have no op — 60 with a property stream and 135 prop-less — and
#      if their basecolor carries a real alpha, or the terrain layer they point
#      at has an `_op` of its own, then they are being drawn as solid slabs over
#      ground they should be letting through.
#
# So this measures, per texture, whether each channel VARIES. A channel that is
# constant is a default the format required, not a mask; a channel that spans
# the range is carrying something.
#
#   godot --headless --path native/_testproj --script probe_roadalpha.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Decals := preload("res://bf6_decals.gd")
const BF6Texture := preload("res://bf6_texture.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")


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

	var res := BF6Decals.find_res(gs.src, level)
	var raw: PackedByteArray = gs.src.get_res(res)
	var td = BF6Decals.new()
	if not td.parse(raw):
		print("FAIL: %s" % td.error); quit(1); return

	var op_tex := {}          # guid -> record count
	var cv_tex := {}
	var cv_no_op := {}        # basecolor of records that have NO op
	var propless := {}
	for r in td.records:
		var rec: Dictionary = r
		var pr: Dictionary = rec["props"]
		var cv := _guid(pr, BF6Decals.SLOT_CV)
		var op := _guid(pr, BF6Decals.SLOT_OP)
		if op != "":
			op_tex[op] = int(op_tex.get(op, 0)) + 1
		if cv != "":
			cv_tex[cv] = int(cv_tex.get(cv, 0)) + 1
			if op == "":
				cv_no_op[cv] = int(cv_no_op.get(cv, 0)) + 1
		if cv == "" and op == "":
			propless[int(rec["asset_slot"])] = \
				int(propless.get(int(rec["asset_slot"]), 0)) + 1

	print("\ndistinct op textures %d, cv textures %d, cv-with-no-op %d"
		% [op_tex.size(), cv_tex.size(), cv_no_op.size()])

	print("\n=== the op (coverage) textures — which channel is the mask? ===")
	_report(gs, op_tex, 14)

	print("\n=== basecolors of records that have NO op slot ===")
	print("(if A varies here, the transparency is in the basecolor instead)")
	_report(gs, cv_no_op, 12)

	# --- the terrain layers the prop-less records point at -------------------
	print("\n=== prop-less records: does their terrain LAYER carry an _op? ===")
	var pidx: Dictionary = gs.walk.gi if gs.walk != null else {}
	var pal = BF6TerrainLayers.new()
	if not pal.load(gs.src, level, pidx):
		print("   palette did not load: %s" % pal.error)
	else:
		var lk: Array = propless.keys()
		lk.sort_custom(func(a, b): return int(propless[a]) > int(propless[b]))
		for l in lk:
			var i := int(l)
			var t: Dictionary = (pal.layers[i] as Dictionary)["textures"] \
				if i < pal.layers.size() else {}
			var names: Array = []
			for k in t.keys():
				names.append("%s=%s" % [str(k), str(t[k]).get_file()])
			names.sort()
			print("   L%02d (%d records): %s" % [i, int(propless[l]),
				", ".join(names) if not names.is_empty() else "(no textures)"])
			# THE RISK I NEED TO RULE OUT. A prop-less record now binds the
			# layer's albedo as `cv`, and the road shader falls back to
			# `ALPHA = cv.a` when there is no op. A terrain layer's _cv alpha is
			# very often a HEIGHT field for height-based blending, not coverage
			# - and using it as alpha would draw every block pavement in a
			# splotchy semi-transparent pattern.
			var alb: String = pal.albedo_of(i)
			if alb != "":
				var ad: PackedByteArray = gs.src.get_res(alb)
				if not ad.is_empty():
					var atx = BF6Texture.new()
					var ag := atx.decode(ad,
						func(form): return gs.src.get_chunk(str(form)), 128)
					if not ag.is_empty() and ag.get("image") is Image:
						var ai: Image = ag["image"]
						if not ai.is_compressed() or ai.decompress() == OK:
							var ast := _channels(ai)
							print("        %s alpha %.2f..%.2f  %s"
								% [alb.get_file(), ast["a_lo"], ast["a_hi"],
								   "VARIES - must not be used as coverage"
								   if float(ast["a_span"]) > 0.05
								   else "constant, safe"])

	quit(0)


func _guid(pr: Dictionary, slot: int) -> String:
	var p = pr.get(slot)
	if not (p is Array) or str((p as Array)[0]) != "tex":
		return ""
	return BF6Decals.guid_str((p as Array)[1])


func _report(gs, tex: Dictionary, cap: int) -> void:
	var keys: Array = tex.keys()
	keys.sort_custom(func(a, b): return int(tex[a]) > int(tex[b]))
	var shown := 0
	var a_varies := 0
	var r_varies := 0
	var total := 0
	for g in keys:
		var asset = gs.walk.gi.get(str(g))
		if asset == null:
			continue
		var nm := str(asset).to_lower().trim_suffix(".ebx")
		var d: PackedByteArray = gs.src.get_res(nm)
		if d.is_empty():
			continue
		var tx = BF6Texture.new()
		var got := tx.decode(d, func(form): return gs.src.get_chunk(str(form)), 128)
		if got.is_empty() or not (got.get("image") is Image):
			continue
		var img: Image = got["image"]
		if img.is_compressed() and img.decompress() != OK:
			continue
		var st := _channels(img)
		total += 1
		if float(st["a_span"]) > 0.05:
			a_varies += 1
		if float(st["r_span"]) > 0.05:
			r_varies += 1
		if shown < cap:
			print("   %-46s %4d recs  fmt %2d  R %.2f..%.2f  A %.2f..%.2f%s"
				% [nm.get_file().substr(0, 46), int(tex[g]), img.get_format(),
				   st["r_lo"], st["r_hi"], st["a_lo"], st["a_hi"],
				   "   <- A is the mask" if float(st["a_span"]) > 0.05
					and float(st["r_span"]) <= 0.05 else ""])
			shown += 1
	print("   --- %d textures read: R varies on %d, A varies on %d ---"
		% [total, r_varies, a_varies])


func _channels(img: Image) -> Dictionary:
	var r_lo := 2.0; var r_hi := -1.0
	var a_lo := 2.0; var a_hi := -1.0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(0, h, maxi(1, h / 48)):
		for x in range(0, w, maxi(1, w / 48)):
			var c := img.get_pixel(x, y)
			r_lo = minf(r_lo, c.r); r_hi = maxf(r_hi, c.r)
			a_lo = minf(a_lo, c.a); a_hi = maxf(a_hi, c.a)
	return {"r_lo": r_lo, "r_hi": r_hi, "a_lo": a_lo, "a_hi": a_hi,
		"r_span": r_hi - r_lo, "a_span": a_hi - a_lo}
