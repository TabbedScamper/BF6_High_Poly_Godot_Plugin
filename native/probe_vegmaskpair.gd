extends SceneTree

# THE VEG BASECOLOR'S A AND THE ALPHA SLOT'S R ARE BOTH PLAUSIBLE MASKS.
# Do they describe the SAME shape, and if so which one is the authored one?
#
# probe_vegalpha measured the two candidates separately and found a split that
# no per-texture statistic can resolve:
#
#   leaf atlases (t_com_*_leaves_cu)   _cu.A is bimodal 0/1, 0.1-4% in between
#                                      _a.R  is a smooth ramp, 0..~0.7, never 1
#   t_com_treedestroyed_02_cu          _cu.A is ZERO everywhere (max 0.0157)
#                                      _a.R  is bimodal, 51% at 1
#
# Read one texture at a time, either channel can be argued for. So this compares
# them SPATIALLY, on a shared normalised grid, and asks the only question that
# distinguishes "the same mask twice" from "two different things":
#
#   is there a threshold t where (alpha.R > t) reproduces (veg.A > 0.5)?
#
# If yes at high agreement, the two are the same authored silhouette and the
# _a is a distance-field / mip-friendly re-encoding of it. If no, they are
# different maps and only one of them is coverage.
#
# It also dumps the depot CONSTANTS of one state key per pairing. A shader that
# alpha-tests against a distance field needs the reference value from somewhere,
# and the depot record is the only place it can come from — a float near the
# best threshold measured here would confirm the reading.
#
#   godot --headless --path native/_testproj --script probe_vegmaskpair.gd \
#         -- [level] [pairs to test]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6Texture := preload("res://bf6_texture.gd")

const GRID := 256          # samples per axis, in normalised UV

var gs = null


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var npairs := 10
	var got := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if got == 0:
			level = s
			got = 1
		else:
			npairs = int(s)

	gs = HighpolyGameSource.new()
	gs.build_materials = false
	gs.log_fn = func(t): print("   " + str(t))
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1)
		return
	print("\n================ %s ================" % level)

	var scopes := {}
	for r in gs.walk.rows:
		var sc := str((r as Dictionary).get("scope", ""))
		if sc != "":
			scopes[sc] = true
	var by_bundle := {}
	for sc in scopes.keys():
		var bn = gs._depot_bundles.get(str(sc))
		if bn == null or by_bundle.has(str(bn)):
			continue
		var pair = gs._depot_for(str(sc))
		if pair != null:
			by_bundle[str(bn)] = [pair, str(sc)]

	# one representative state key per (veg, alpha) pairing
	var pairs := {}         # "vegguid|alphaguid" -> [count, key, bundle]
	for bn in by_bundle.keys():
		var ent: Array = by_bundle[bn]
		var pr: Array = ent[0]
		var dep: BF6Depot = pr[0]
		var blob: PackedByteArray = pr[1]
		for k in dep.key_to_record.keys():
			var slots: Dictionary = dep.textures_for(int(k), blob)
			if not slots.has("basecolor_veg"):
				continue
			var vg := str(slots["basecolor_veg"])
			var ag := str(slots.get("alpha", ""))
			var pk := "%s|%s" % [vg, ag]
			if pairs.has(pk):
				(pairs[pk] as Array)[0] = int((pairs[pk] as Array)[0]) + 1
			else:
				pairs[pk] = [1, int(k), str(bn)]

	var pk_keys: Array = pairs.keys()
	pk_keys.sort_custom(func(x, y):
		return int((pairs[x] as Array)[0]) > int((pairs[y] as Array)[0]))

	print("\n%d distinct (veg basecolor, alpha) pairings; testing the top %d\n"
		% [pk_keys.size(), mini(npairs, pk_keys.size())])

	var agree_best: Array = []
	var n := 0
	for p in pk_keys:
		if n >= npairs:
			break
		n += 1
		var bits: PackedStringArray = str(p).split("|")
		var vn := _name_of(str(bits[0]))
		var an := _name_of(str(bits[1])) if str(bits[1]) != "" else ""
		var uses := int((pairs[p] as Array)[0])
		print("=== %d states   veg %s   alpha %s"
			% [uses, vn.get_file(), an.get_file() if an != "" else "(none)"])
		var vi = _decode(vn)
		var ai = _decode(an) if an != "" else null
		if vi == null or ai == null:
			print("   could not decode both; skipping\n")
			continue

		# sample both on the same normalised grid
		var va := PackedFloat32Array()
		var ar := PackedFloat32Array()
		va.resize(GRID * GRID)
		ar.resize(GRID * GRID)
		var vw := (vi as Image).get_width()
		var vh := (vi as Image).get_height()
		var aw := (ai as Image).get_width()
		var ah := (ai as Image).get_height()
		var idx := 0
		for y in range(GRID):
			var fy := (float(y) + 0.5) / float(GRID)
			var vy: int = clampi(int(fy * vh), 0, vh - 1)
			var ay: int = clampi(int(fy * ah), 0, ah - 1)
			for x in range(GRID):
				var fx := (float(x) + 0.5) / float(GRID)
				va[idx] = (vi as Image).get_pixel(
					clampi(int(fx * vw), 0, vw - 1), vy).a
				ar[idx] = (ai as Image).get_pixel(
					clampi(int(fx * aw), 0, aw - 1), ay).r
				idx += 1

		# Pearson correlation of the two candidate channels
		var sx := 0.0
		var sy := 0.0
		var sxx := 0.0
		var syy := 0.0
		var sxy := 0.0
		var m := va.size()
		for i in range(m):
			var u := float(va[i])
			var v := float(ar[i])
			sx += u
			sy += v
			sxx += u * u
			syy += v * v
			sxy += u * v
		var mu := sx / float(m)
		var mv := sy / float(m)
		var cov := sxy / float(m) - mu * mv
		var sdu := sqrt(maxf(0.0, sxx / float(m) - mu * mu))
		var sdv := sqrt(maxf(0.0, syy / float(m) - mv * mv))
		var corr := 0.0
		if sdu > 1e-6 and sdv > 1e-6:
			corr = cov / (sdu * sdv)

		# the reference silhouette: the veg basecolor's own A, thresholded at 0.5
		var cover := 0
		for i in range(m):
			if float(va[i]) > 0.5:
				cover += 1
		# best threshold on the alpha texture's R
		var best_t := -1.0
		var best_ag := -1.0
		var t := 0.02
		while t < 0.99:
			var ok := 0
			for i in range(m):
				var lhs: bool = float(ar[i]) > t
				var rhs: bool = float(va[i]) > 0.5
				if lhs == rhs:
					ok += 1
			var frac := float(ok) / float(m)
			if frac > best_ag:
				best_ag = frac
				best_t = t
			t += 0.02
		var ag50 := 0
		for i in range(m):
			if (float(ar[i]) > 0.5) == (float(va[i]) > 0.5):
				ag50 += 1

		print("   veg A: mean %.4f, coverage(A>0.5) %.1f%%   [sd %.4f]"
			% [mu, 100.0 * float(cover) / float(m), sdu])
		print("   alpha R: mean %.4f  [sd %.4f]" % [mv, sdv])
		print("   Pearson corr(vegA, alphaR)          %.4f" % corr)
		print("   agreement of (alphaR>0.50) with (vegA>0.5)  %.2f%%"
			% [100.0 * float(ag50) / float(m)])
		print("   BEST threshold on alphaR: %.2f -> agreement %.2f%%"
			% [best_t, 100.0 * best_ag])
		# The three numbers that separate "a mask" from "a distance field", and
		# a usable veg A from a degenerate one.
		var cov_a := 0
		var band := 0
		var vbin := 0
		for i in range(m):
			if float(ar[i]) > 0.5:
				cov_a += 1
			if float(ar[i]) >= 0.45 and float(ar[i]) <= 0.55:
				band += 1
			if float(va[i]) < 0.02 or float(va[i]) > 0.98:
				vbin += 1
		print("   coverage(alphaR>0.5) %.1f%%   alphaR in 0.45..0.55 %.2f%%   vegA bimodal %.1f%%"
			% [100.0 * float(cov_a) / float(m), 100.0 * float(band) / float(m),
			   100.0 * float(vbin) / float(m)])
		agree_best.append([vn.get_file(), best_t, best_ag, corr,
			float(cover) / float(m), float(cov_a) / float(m),
			float(band) / float(m)])

		# the constants on one state key of this pairing — where an alpha-test
		# reference value would have to live
		var ent2: Array = by_bundle[str((pairs[p] as Array)[2])]
		var pr2: Array = ent2[0]
		var slots2: Dictionary = (pr2[0] as BF6Depot).textures_for(
			int((pairs[p] as Array)[1]), pr2[1])
		var consts: Dictionary = slots2.get("constants", {})
		var ck: Array = consts.keys()
		ck.sort()
		var out: Array = []
		for c in ck:
			var raw: PackedByteArray = consts[c]
			out.append("%08x=%s" % [int(c), _fmt_const(raw)])
		print("   %d constants: %s\n" % [ck.size(), "  ".join(out)])

	print("\n--- summary ----------------------------------------------------")
	print("%-38s %6s %10s %8s %8s %8s %7s"
		% ["veg basecolor", "best t", "agreement", "corr", "cov vegA",
		   "cov aR", "band"])
	for r in agree_best:
		print("%-38s %6.2f %9.2f%% %8.4f %7.1f%% %7.1f%% %6.2f%%"
			% [str(r[0]).substr(0, 38), float(r[1]), 100.0 * float(r[2]),
			   float(r[3]), 100.0 * float(r[4]), 100.0 * float(r[5]),
			   100.0 * float(r[6])])
	quit(0)


func _fmt_const(raw: PackedByteArray) -> String:
	if raw.size() == 4:
		return "%.4f" % raw.decode_float(0)
	if raw.size() == 1:
		return "u8:%d" % int(raw[0])
	if raw.size() % 4 == 0 and raw.size() <= 16:
		var b: Array = []
		for i in range(raw.size() / 4):
			b.append("%.3f" % raw.decode_float(i * 4))
		return "(" + ",".join(b) + ")"
	return "%dB" % raw.size()


func _name_of(file_guid: String) -> String:
	if file_guid == "":
		return ""
	var asset = gs.walk.gi.get(file_guid)
	if asset == null:
		return ""
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	return an


# mip0, decompressed. A capped decode would hand back a downsampled mip, and a
# downsampled binary mask correlates with everything.
func _decode(asset_name: String):
	if asset_name == "":
		return null
	var raw: PackedByteArray = gs.src.get_res(asset_name)
	if raw.is_empty():
		return null
	var tx := BF6Texture.new()
	var got: Dictionary = tx.decode(raw,
		func(form): return gs.src.get_chunk(str(form)), 0)
	if got.is_empty() or not (got.get("image") is Image):
		return null
	var c := (got["image"] as Image).duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		return null
	return c
