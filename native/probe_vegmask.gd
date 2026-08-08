extends SceneTree

# IS 0x8365AEBE (=0.25) CONSISTENT WITH BEING THE ALPHA-TEST REFERENCE?
#
# probe_vegcut found two veg-exclusive floats that co-vary on one asset family
# (0x87843e6d 0.03->0.22 and 0x8365aebe 0.25->0.4 on the japanese maple) plus a
# family-scoped 0x323eb98d (0.2, 0.25 on boxwood, 0.35 on bougainvillea). Names
# are unrecoverable (cooked SBD Name32 is opaque), so the only remaining
# evidence is the MASK ITSELF: a number that is an alpha reference must sit
# where the mask's own histogram says a cutoff belongs.
#
# For every distinct vegetation _cu texture: decode mip0 (max_dim 0 — a capped
# decode averages hard edges into grey and invents a ramp), then report the
# alpha histogram, the coverage that survives each candidate value, and where
# the histogram's valley actually is.
#
#   godot --headless --path native/_testproj --script probe_vegmask.gd -- [level] [cap]

const BF6Source := preload("res://bf6_source.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6Texture := preload("res://bf6_texture.gd")

const SHADERSTATE := "_win32_shaderstate/"
const VEG := 0x54bbcd36
const TH_TEXTURE := 0xcc84d53d
const WATCH := {0x8365aebe: "C_hi", 0x87843e6d: "C_lo", 0x323eb98d: "A", 0xd7e01208: "B"}
const CUTS := [0.03, 0.1, 0.2, 0.25, 0.3, 0.4, 0.5]


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	var cap := 40
	var got := 0
	for x in OS.get_cmdline_user_args():
		var s := str(x)
		if s == "":
			continue
		if got == 0:
			level = s; got = 1
		else:
			cap = int(s)

	var src = BF6Source.new()
	if not src.open(""):
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return
	var pidx: Dictionary = src.partition_index()

	var tex_use := {}       # asset name -> record count
	var tex_vals := {}      # asset name -> {label: value}
	var seen := {}
	for rn in src.res.keys():
		var n := str(rn)
		var at := n.find(SHADERSTATE)
		if at <= 0 or n.find("shaderblockdepot", at) <= 0:
			continue
		var blob: PackedByteArray = src.get_res(n)
		if blob.is_empty():
			continue
		var dep = BF6Depot.new()
		if not dep.parse(blob):
			continue
		for ri in range(dep.records.size()):
			var rec: Dictionary = dep.records[ri]
			if seen.has(int(rec["content_hash"])):
				continue
			var ps: Array = dep.params(ri, blob)
			if ps.is_empty():
				continue
			seen[int(rec["content_hash"])] = true
			var vg := ""
			var vals := {}
			for p in ps:
				var pd: Dictionary = p
				var n32: int = int(pd["name32"])
				if int(pd["type_hash"]) == TH_TEXTURE:
					if n32 == VEG and not (pd["refs"] as Array).is_empty():
						vg = str((pd["refs"] as Array)[0][1])
				elif WATCH.has(n32) and pd["raw"] is PackedByteArray:
					var b: PackedByteArray = pd["raw"]
					if b.size() >= 4:
						vals[str(WATCH[n32])] = b.decode_float(0)
			if vg == "":
				continue
			var an := str(pidx.get(vg, vg))
			tex_use[an] = int(tex_use.get(an, 0)) + 1
			if not tex_vals.has(an):
				tex_vals[an] = vals
			else:
				# a texture used by two materials with DIFFERENT values is the
				# interesting case — keep both spellings visible
				var have: Dictionary = tex_vals[an]
				for k in vals.keys():
					if have.has(k) and absf(float(have[k]) - float(vals[k])) > 1e-6:
						have[str(k) + "!"] = vals[k]
					else:
						have[k] = vals[k]

	# DEVIATIONS FIRST. A constant that is an alpha reference earns that name on
	# the assets where the artist moved it off the default, not on the 600 that
	# kept it — so those are the ones whose masks have to be looked at.
	var DEF := {"A": 0.2, "B": 0.3, "C_hi": 0.25, "C_lo": 0.03}
	var dev := func(an) -> int:
		var v: Dictionary = tex_vals[an]
		var d := 0
		for k in v.keys():
			var base := str(k).trim_suffix("!")
			if DEF.has(base) and absf(float(v[k]) - float(DEF[base])) > 1e-6:
				d += 1
		return d
	var keys: Array = tex_use.keys()
	keys.sort_custom(func(a, b):
		var da: int = dev.call(a)
		var db: int = dev.call(b)
		if da != db:
			return da > db
		return int(tex_use[a]) > int(tex_use[b]))
	print("level %s: %d distinct vegetation textures, decoding the top %d at mip0"
		% [level, keys.size(), mini(cap, keys.size())])
	print("cuts: %s" % str(CUTS))
	print("")

	for i in range(mini(cap, keys.size())):
		var an := str(keys[i])
		var nm := an.to_lower().trim_suffix(".ebx")
		var d: PackedByteArray = src.get_res(nm)
		if d.is_empty():
			print("  %-46s (no resource)" % nm.get_file())
			continue
		var tx = BF6Texture.new()
		var g := tx.decode(d, func(form): return src.get_chunk(str(form)), 0)
		if g.is_empty() or not (g.get("image") is Image):
			print("  %-46s (decode failed: %s)" % [nm.get_file(), tx.error])
			continue
		var img: Image = g["image"]
		if img.is_compressed() and img.decompress() != OK:
			print("  %-46s (decompress failed)" % nm.get_file())
			continue
		var st := _alpha_stats(img)
		var vals: Dictionary = tex_vals[an]
		var vk: Array = vals.keys()
		vk.sort()
		var vs: Array = []
		for k in vk:
			vs.append("%s=%.3f" % [str(k), float(vals[k])])
		print("  %-44s %4dx%-4d recs %-3d  %s" % [nm.get_file().substr(0, 44),
			img.get_width(), img.get_height(), int(tex_use[an]), ", ".join(vs)])
		var cov: Array = []
		for c in CUTS:
			cov.append("%.2f:%4.1f%%" % [c, 100.0 * float(st["cov"][c])])
		print("       max %.3f  mean %.3f  coverage  %s" % [st["max"], st["mean"],
			"  ".join(cov)])
		print("       valley at %.3f (%.2f%% of texels in its bucket)   hist %s"
			% [st["valley"], 100.0 * float(st["valley_frac"]), st["hist"]])

	quit(0)


# 32-bucket alpha histogram over every texel of mip0 (strided only when the
# image is enormous, and a stride samples REAL texels — it never averages).
func _alpha_stats(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var sx := maxi(1, w / 512)
	var sy := maxi(1, h / 512)
	var buckets := PackedInt32Array()
	buckets.resize(32)
	var n := 0
	var mx := 0.0
	var sum := 0.0
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var a := img.get_pixel(x, y).a
			mx = maxf(mx, a)
			sum += a
			var bi := clampi(int(a * 32.0), 0, 31)
			buckets[bi] += 1
			n += 1
	var cov := {}
	for c in CUTS:
		var k := 0
		for b in range(32):
			if (float(b) + 0.5) / 32.0 >= c:
				k += buckets[b]
		cov[c] = float(k) / maxf(1.0, float(n))
	# the valley: the emptiest bucket strictly between the two ends
	var vb := 2
	var vmin := 1e30
	for b in range(2, 24):
		if float(buckets[b]) < vmin:
			vmin = float(buckets[b])
			vb = b
	var hs: Array = []
	for b in range(0, 32, 2):
		var f := 100.0 * float(buckets[b] + buckets[b + 1]) / maxf(1.0, float(n))
		hs.append("%d" % int(round(f)))
	return {"max": mx, "mean": sum / maxf(1.0, float(n)), "cov": cov,
		"valley": (float(vb) + 0.5) / 32.0,
		"valley_frac": vmin / maxf(1.0, float(n)),
		"hist": "|".join(hs)}
