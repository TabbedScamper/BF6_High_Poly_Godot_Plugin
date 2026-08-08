extends SceneTree

# DOES THE GAME AUTHOR A FOLIAGE ALPHA-TEST THRESHOLD?
#
# Our cutoff is invented: clampf(mask_max * 0.45, 0.12, 0.5). This asks whether
# a depot constant carries an authored one instead.
#
# Method: every unique depot blob on a level (deduplicated by content hash, so
# the same material shared by 400 keys is counted once), classified by which
# texture slots it binds:
#
#   veg     binds basecolor_veg 0x54bbcd36            -> foliage
#   cut     binds the alpha twin 0xd405b0e1, no veg   -> non-veg cutouts
#   solid   binds basecolor 0x54bbcd30, neither       -> architecture
#   other   binds neither basecolor
#
# then every constant on each side with its value histogram. A real alpha
# threshold should be on veg AND on cut, and absent on solid.
#
#   godot --headless --path native/_testproj --script probe_vegcut.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Depot := preload("res://bf6_depot.gd")

const SHADERSTATE := "_win32_shaderstate/"
const VEG := 0x54bbcd36
const BASE := 0x54bbcd30
const ALPHA := 0xd405b0e1
const TH_TEXTURE := 0xcc84d53d
const TH_FLOAT := 0x14a0b1c1

# hashes worth a per-texture breakdown once the first pass has named them
const WATCH := [0x8365aebe, 0x87843e6d, 0x323eb98d, 0xd7e01208, 0x3f82b6ae,
	0x2b882739, 0x8c361b04]


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var src = BF6Source.new()
	if not src.open(""):
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return

	var depots: Array = []
	for rn in src.res.keys():
		var n := str(rn)
		var at := n.find(SHADERSTATE)
		if at > 0 and n.find("shaderblockdepot", at) > 0:
			depots.append(n)
	depots.sort()
	print("level %s: %d depot resources" % [level, depots.size()])
	var pidx: Dictionary = src.partition_index()

	var stat := {"veg": {}, "cut": {}, "solid": {}, "other": {}}
	var nrec := {"veg": 0, "cut": 0, "solid": 0, "other": 0}
	var nkey := {"veg": 0, "cut": 0, "solid": 0, "other": 0}
	var seen_blob := {}
	var veg_tex := {}
	var samples := {"veg": [], "cut": []}
	var watch_by_tex := {}     # "%08x|value" -> {texture name: n}
	var veg_coslot := {}       # slot name32 -> veg blobs binding it
	var parse_fail := 0

	for dn in depots:
		var blob: PackedByteArray = src.get_res(str(dn))
		if blob.is_empty():
			continue
		var dep = BF6Depot.new()
		if not dep.parse(blob):
			parse_fail += 1
			continue
		var keyw := {}
		for k in dep.key_to_record.keys():
			var ri := int(dep.key_to_record[k])
			keyw[ri] = int(keyw.get(ri, 0)) + 1
		for ri in range(dep.records.size()):
			var rec: Dictionary = dep.records[ri]
			var ch: int = int(rec["content_hash"])
			if seen_blob.has(ch):
				continue
			var ps: Array = dep.params(ri, blob)
			if ps.is_empty():
				continue
			var slots := {}
			var consts := {}
			for p in ps:
				var pd: Dictionary = p
				var n32: int = int(pd["name32"])
				if int(pd["type_hash"]) == TH_TEXTURE:
					var refs: Array = pd["refs"]
					slots[n32] = (str(refs[0][1]) if not refs.is_empty() else "")
				else:
					consts[n32] = pd
			var cls := "other"
			if slots.has(VEG):
				cls = "veg"
			elif slots.has(ALPHA):
				cls = "cut"
			elif slots.has(BASE):
				cls = "solid"
			seen_blob[ch] = cls
			var w := int(keyw.get(ri, 0))
			nrec[cls] = int(nrec[cls]) + 1
			nkey[cls] = int(nkey[cls]) + w
			_accum(stat[cls], consts, w)

			var an := ""
			if cls == "veg":
				for s32 in slots.keys():
					veg_coslot[int(s32)] = int(veg_coslot.get(int(s32), 0)) + 1
				an = str(pidx.get(str(slots[VEG]), str(slots[VEG])))
				veg_tex[an] = int(veg_tex.get(an, 0)) + 1
			elif cls == "cut":
				var g2 = slots.get(BASE, slots.get(ALPHA))
				an = str(pidx.get(str(g2), str(g2)))
			if cls == "veg" or cls == "cut":
				if (samples[cls] as Array).size() < 5:
					(samples[cls] as Array).append([an, consts.duplicate(), w])
				for wh in WATCH:
					if not consts.has(wh):
						continue
					var vk := "%08x|%s" % [int(wh), _vals(consts[wh])]
					var t: Dictionary = watch_by_tex.get(vk, {})
					if t.is_empty():
						watch_by_tex[vk] = t
					var nm := an.get_file()
					t[nm] = int(t.get(nm, 0)) + 1

	print("unique blobs: veg %d (%d keys), cut %d (%d keys), solid %d (%d keys), other %d (%d keys)"
		% [nrec["veg"], nkey["veg"], nrec["cut"], nkey["cut"],
		   nrec["solid"], nkey["solid"], nrec["other"], nkey["other"]])
	print("depot parse failures: %d" % parse_fail)

	print("\n=== texture slots co-bound by vegetation blobs ===")
	var csk: Array = veg_coslot.keys()
	csk.sort_custom(func(a, b): return int(veg_coslot[a]) > int(veg_coslot[b]))
	for s in csk:
		print("   %-16s %08x  %4d/%d (%.0f%%)"
			% [str(BF6Depot.SLOT_NAME.get(int(s), "?")), int(s), int(veg_coslot[s]),
			   int(nrec["veg"]), 100.0 * float(int(veg_coslot[s])) / maxf(1.0, float(int(nrec["veg"])))])

	print("\n=== vegetation textures (top 20 of %d) ===" % veg_tex.size())
	var vk2: Array = veg_tex.keys()
	vk2.sort_custom(func(a, b): return int(veg_tex[a]) > int(veg_tex[b]))
	for i in range(mini(20, vk2.size())):
		print("   %4d  %s" % [int(veg_tex[vk2[i]]), str(vk2[i]).get_file()])

	for cls in ["veg", "cut"]:
		print("\n=== FULL CONSTANT DUMP: sample %s records ===" % cls)
		for s in samples[cls]:
			var sa: Array = s
			print("  --- %s  (%d state keys) ---" % [str(sa[0]).get_file(), int(sa[2])])
			var cd: Dictionary = sa[1]
			var ck: Array = cd.keys()
			ck.sort()
			for c in ck:
				var pd2: Dictionary = cd[c]
				print("      %08x th=%08x n=%-2d  %s"
					% [int(c), int(pd2["type_hash"]), int(pd2["count"]), _vals(pd2)])

	for cls in ["veg", "cut", "solid"]:
		print("\n=== CONSTANTS ON %s (%d unique blobs) ===" % [cls.to_upper(), nrec[cls]])
		_table(stat[cls], int(nrec[cls]), stat, nrec)

	print("\n=== CANDIDATE RANKING ===")
	print("scalar float, count 1, all observed values in 0.02..0.95, on veg")
	var cand: Array = []
	for c in (stat["veg"] as Dictionary).keys():
		var st: Dictionary = (stat["veg"] as Dictionary)[c]
		if int(st["type"]) != TH_FLOAT:
			continue
		var cnts: Dictionary = st["counts"]
		if cnts.size() != 1 or not cnts.has(1):
			continue
		var ok := true
		for v in (st["hist"] as Dictionary).keys():
			var f := float(str(v))
			if f < 0.02 or f > 0.95:
				ok = false; break
		if not ok:
			continue
		cand.append([c, _cov(stat, nrec, c, "veg"), _cov(stat, nrec, c, "cut"),
			_cov(stat, nrec, c, "solid"), st])
	# a real threshold is high on veg AND high on cut, low on solid
	cand.sort_custom(func(a, b):
		return (float(a[1]) + float(a[2]) - float(a[3])) > (float(b[1]) + float(b[2]) - float(b[3])))
	for c in cand:
		var ca: Array = c
		print("  %08x  veg %5.1f%%  cut %5.1f%%  solid %5.1f%%"
			% [int(ca[0]), float(ca[1]) * 100.0, float(ca[2]) * 100.0,
			   float(ca[3]) * 100.0])
		print("        veg   %s" % _hist(((ca[4] as Dictionary)["hist"]), 10))
		for other in ["cut", "solid"]:
			var s2: Dictionary = stat[other]
			if s2.has(ca[0]):
				print("        %-5s %s" % [other, _hist((s2[ca[0]] as Dictionary)["hist"], 10)])

	print("\n=== WATCHED HASHES: which textures carry which value ===")
	var wk: Array = watch_by_tex.keys()
	wk.sort()
	for k in wk:
		var t: Dictionary = watch_by_tex[k]
		var tk: Array = t.keys()
		tk.sort_custom(func(a, b): return int(t[a]) > int(t[b]))
		var parts: Array = []
		for i in range(mini(6, tk.size())):
			parts.append("%s(%d)" % [str(tk[i]), int(t[tk[i]])])
		if tk.size() > 6:
			parts.append("+%d more" % (tk.size() - 6))
		print("  %-28s %2d textures: %s" % [str(k), tk.size(), ", ".join(parts)])

	quit(0)


func _cov(stat: Dictionary, nrec: Dictionary, c, cls: String) -> float:
	var s: Dictionary = stat[cls]
	if not s.has(c):
		return 0.0
	return float(int((s[c] as Dictionary)["recs"])) / maxf(1.0, float(int(nrec[cls])))


func _accum(stat: Dictionary, consts: Dictionary, w: int) -> void:
	for c in consts.keys():
		var pd: Dictionary = consts[c]
		var st: Dictionary = stat.get(c, {})
		if st.is_empty():
			st = {"recs": 0, "keys": 0, "type": int(pd["type_hash"]),
				"counts": {}, "hist": {}}
			stat[c] = st
		st["recs"] = int(st["recs"]) + 1
		st["keys"] = int(st["keys"]) + w
		var cn := int(pd["count"])
		(st["counts"] as Dictionary)[cn] = int((st["counts"] as Dictionary).get(cn, 0)) + 1
		var v := _vals(pd)
		(st["hist"] as Dictionary)[v] = int((st["hist"] as Dictionary).get(v, 0)) + 1


func _vals(pd: Dictionary) -> String:
	var raw = pd["raw"]
	if not (raw is PackedByteArray):
		return "(no payload)"
	var b: PackedByteArray = raw
	var th := int(pd["type_hash"])
	var n := int(pd["count"])
	var out: Array = []
	var elem := 4
	match th:
		0x39ab6941: elem = 8
		0x25f81af1: elem = 12
		0xdef2e1a5: elem = 16
		0x26b52646: elem = 1
	for i in range(maxi(1, n)):
		var o := (16 * i) if n > 1 else 0
		if o + elem > b.size():
			break
		if elem == 1:
			out.append("%d" % b[o])
		elif elem == 4:
			if th == TH_FLOAT:
				out.append(_f(b.decode_float(o)))
			else:
				out.append("%s|u%d" % [_f(b.decode_float(o)), b.decode_u32(o)])
		elif elem == 8:
			out.append("(%s,%s)" % [_f(b.decode_float(o)), _f(b.decode_float(o + 4))])
		elif elem == 12:
			out.append("(%s,%s,%s)" % [_f(b.decode_float(o)),
				_f(b.decode_float(o + 4)), _f(b.decode_float(o + 8))])
		else:
			out.append("(%s,%s,%s,%s)" % [_f(b.decode_float(o)),
				_f(b.decode_float(o + 4)), _f(b.decode_float(o + 8)),
				_f(b.decode_float(o + 12))])
	if out.size() > 4:
		out.resize(4)
		out.append("...")
	return ",".join(out)


func _f(v: float) -> String:
	if not is_finite(v):
		return "nan"
	if absf(v) >= 1e6:
		return "%.1f" % v
	return ("%.4f" % v).rstrip("0").rstrip(".")


func _hist(h: Dictionary, cap: int) -> String:
	var k: Array = h.keys()
	k.sort_custom(func(a, b): return int(h[a]) > int(h[b]))
	var parts: Array = []
	for i in range(mini(cap, k.size())):
		parts.append("%s x%d" % [str(k[i]), int(h[k[i]])])
	if k.size() > cap:
		parts.append("(+%d more)" % (k.size() - cap))
	return "  ".join(parts)


func _table(s: Dictionary, total: int, stat: Dictionary, nrec: Dictionary) -> void:
	var keys: Array = s.keys()
	keys.sort_custom(func(a, b):
		return int((s[a] as Dictionary)["recs"]) > int((s[b] as Dictionary)["recs"]))
	var shown := 0
	for c in keys:
		if shown >= 70:
			print("  ... and %d rarer hashes" % (keys.size() - shown))
			break
		shown += 1
		var st: Dictionary = s[c]
		var cnts: Array = (st["counts"] as Dictionary).keys()
		cnts.sort()
		print("  %08x th=%08x n=%s  here %5.1f%% (%d/%d) | veg %5.1f%% cut %5.1f%% solid %5.1f%% other %5.1f%% | %d distinct"
			% [int(c), int(st["type"]), str(cnts),
			   100.0 * float(int(st["recs"])) / maxf(1.0, float(total)),
			   int(st["recs"]), total,
			   100.0 * _cov(stat, nrec, c, "veg"), 100.0 * _cov(stat, nrec, c, "cut"),
			   100.0 * _cov(stat, nrec, c, "solid"), 100.0 * _cov(stat, nrec, c, "other"),
			   (st["hist"] as Dictionary).size()])
		print("        %s" % _hist(st["hist"], 8))
