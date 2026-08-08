extends SceneTree

# WHERE IS FOLIAGE OPACITY, MEASURED RATHER THAN ASSUMED — and is any mask
# texture being decoded with the wrong signedness?
#
# bf6_depot's comment on SLOT_BASECOLOR_VEG says the opacity "rides the ALPHA
# twin, not the _cs". test_foliage already concluded the same from eight meshes
# and a min/max of the alpha channel. Neither is a measurement of the thing that
# actually decides the shader: min/max says a channel VARIES, it does not say
# the channel is a coverage mask, and it certainly does not say whether that
# mask is binary (alpha scissor) or a gradient (real blending).
#
# Three specific ways the current answer could be wrong:
#
#   1. mip level. Decoding with a max_dim cap hands back a DOWNSAMPLED mip, and
#      downsampling a hard 0/1 mask produces a smooth ramp. Every "soft
#      gradient" conclusion drawn from a capped decode is an artefact of the
#      cap. This probe decodes mip0 — max_dim 0 — for exactly that reason.
#
#   2. signedness. bf6_texture just turned out to map BF6 format 64 to DXGI 96
#      (BC6H_SF16) when it is 95 (BC6H_UF16); read signed, the sky came out with
#      14% negative pixels and a mean of 8328. BC4 and BC5 have the same trap
#      (80/81 and 83/84) and masks are exactly what ships as BC4. So this prints
#      the BF6 format code and the mapped DXGI for every texture it touches, and
#      flags any code the table does not map at all.
#
#   3. which channel. A one-channel BC4 image decompresses to R with G/B forced
#      to 0 and A forced to 1, so "A is 1.0 everywhere" on such a texture is a
#      property of the FORMAT, not of the asset. Per-channel stats are therefore
#      printed alongside the format's real channel count, and channels the
#      format cannot carry are marked so they are never read as evidence.
#
# What it does: walks every depot the map places from, keeps every shader state
# key that binds basecolor_veg, collects the distinct textures in the veg
# basecolor slot and in the alpha slot, resolves both to asset names through the
# partition index, then decodes each at mip0 and reports min/mean/max, the
# fraction near 0 and near 1, the fraction in the soft middle, and a 16-bucket
# histogram, for R G B and A.
#
#   godot --headless --path native/_testproj --script probe_vegalpha.gd \
#         -- [level] [max textures to decode]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6Texture := preload("res://bf6_texture.gd")

const DXGI_NAME := {
	10: "R16G16B16A16_FLOAT", 28: "R8G8B8A8_UNORM", 61: "R8_UNORM",
	70: "BC1_TYPELESS", 71: "BC1_UNORM", 72: "BC1_UNORM_SRGB",
	73: "BC2_TYPELESS", 74: "BC2_UNORM", 75: "BC2_UNORM_SRGB",
	76: "BC3_TYPELESS", 77: "BC3_UNORM", 78: "BC3_UNORM_SRGB",
	79: "BC4_TYPELESS", 80: "BC4_UNORM", 81: "BC4_SNORM",
	82: "BC5_TYPELESS", 83: "BC5_UNORM", 84: "BC5_SNORM",
	94: "BC6H_TYPELESS", 95: "BC6H_UF16", 96: "BC6H_SF16",
	97: "BC7_TYPELESS", 98: "BC7_UNORM", 99: "BC7_UNORM_SRGB",
}

# Which channels the DXGI format can physically carry. Everything else in a
# decompressed Image is a default the decoder invented.
const REAL_CH := {
	10: "RGBA", 28: "RGBA", 61: "R",
	# BC1's 1-bit alpha is dropped by Godot's DXT1 decode, so A on a BC1 image is
	# a decoder default whatever the block bytes said. Listed as RGB for that
	# reason, not because the format has no alpha mode.
	71: "RGB", 72: "RGB", 74: "RGBA", 75: "RGBA", 77: "RGBA", 78: "RGBA",
	80: "R", 81: "R", 83: "RG", 84: "RG", 95: "RGB", 96: "RGB",
	98: "RGBA", 99: "RGBA",
}

const SNORM_DXGI := [81, 84, 96]

var gs = null
var _seen_tex := {}          # asset name -> stats dictionary


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var cap := 48
	var got := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if got == 0:
			level = s
			got = 1
		else:
			cap = int(s)

	gs = HighpolyGameSource.new()
	gs.build_materials = false
	gs.log_fn = func(t): print("   " + str(t))
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1)
		return
	print("\n================ %s ================" % level)

	# ---- every depot this map places from, deduplicated by BUNDLE ----------
	# Two scopes can name the same depot bundle; counting per scope would then
	# count the same state key twice and every percentage below would be wrong.
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
			by_bundle[str(bn)] = pair
	print("scopes placed from: %d   distinct depot bundles: %d"
		% [scopes.size(), by_bundle.size()])

	# ---- 1. every state key that binds basecolor_veg -----------------------
	var total_keys := 0
	var veg_keys := 0
	var veg_with_alpha := 0
	var alpha_keys_all := 0
	var base_keys := 0
	var veg_tex := {}            # file guid -> key count
	var alpha_tex := {}          # file guid -> key count (veg keys only)
	var pairs := {}              # "veg|alpha" -> key count
	var co_slots := {}           # slot name -> key count over veg keys
	var slot_tex := {}           # slot name -> {file guid: key count}
	var same_asset := 0
	for bn in by_bundle.keys():
		var pair = by_bundle[bn]
		var dep: BF6Depot = pair[0]
		var blob: PackedByteArray = pair[1]
		for k in dep.key_to_record.keys():
			total_keys += 1
			var slots: Dictionary = dep.textures_for(int(k), blob)
			slots.erase("constants")
			if slots.has("alpha"):
				alpha_keys_all += 1
			if slots.has("basecolor"):
				base_keys += 1
			if not slots.has("basecolor_veg"):
				continue
			veg_keys += 1
			for s in slots.keys():
				co_slots[str(s)] = int(co_slots.get(str(s), 0)) + 1
				if not slot_tex.has(str(s)):
					slot_tex[str(s)] = {}
				var sub: Dictionary = slot_tex[str(s)]
				sub[str(slots[s])] = int(sub.get(str(slots[s]), 0)) + 1
			var vg := str(slots["basecolor_veg"])
			veg_tex[vg] = int(veg_tex.get(vg, 0)) + 1
			var ag := ""
			if slots.has("alpha"):
				veg_with_alpha += 1
				ag = str(slots["alpha"])
				alpha_tex[ag] = int(alpha_tex.get(ag, 0)) + 1
				if ag == vg:
					same_asset += 1
			var pk := "%s|%s" % [vg, ag]
			pairs[pk] = int(pairs.get(pk, 0)) + 1

	print("\n--- 1. shader states -------------------------------------------")
	print("state keys in those depots:          %d" % total_keys)
	print("   bind basecolor (non-veg):         %d" % base_keys)
	print("   bind an alpha slot at all:        %d" % alpha_keys_all)
	print("   bind basecolor_veg:               %d" % veg_keys)
	print("      of those, also bind alpha:     %d" % veg_with_alpha)
	print("      alpha guid == veg guid:        %d" % same_asset)
	print("distinct textures in the veg slot:   %d" % veg_tex.size())
	print("distinct textures in the alpha slot: %d" % alpha_tex.size())
	print("distinct (veg, alpha) pairings:      %d" % pairs.size())
	print("\nslots co-bound by basecolor_veg states:")
	var cs: Array = co_slots.keys()
	cs.sort_custom(func(x, y): return int(co_slots[x]) > int(co_slots[y]))
	for s in cs:
		print("   %-22s %5d  (%.0f%% of veg states)"
			% [str(s), int(co_slots[s]),
			   100.0 * int(co_slots[s]) / maxi(1, veg_keys)])

	print("\nthe (veg basecolor, alpha) pairings, most-used first:")
	var pk_keys: Array = pairs.keys()
	pk_keys.sort_custom(func(x, y): return int(pairs[x]) > int(pairs[y]))
	var shown := 0
	for p in pk_keys:
		if shown >= 40:
			print("   ... and %d more pairings" % (pk_keys.size() - shown))
			break
		var bits: PackedStringArray = str(p).split("|")
		print("   %5d states  veg %-42s  alpha %s"
			% [int(pairs[p]), _name_of(str(bits[0])).get_file().substr(0, 42),
			   _name_of(str(bits[1])).get_file() if str(bits[1]) != ""
			   else "(NONE)"])
		shown += 1

	# ---- 2/4/5. decode each distinct texture, mip0, per channel ------------
	print("\n--- 2. per-texture measurements (mip0, no size cap) ------------")
	var order: Array = []
	for g in veg_tex.keys():
		order.append([str(g), "veg", int(veg_tex[g])])
	for g in alpha_tex.keys():
		order.append([str(g), "alpha", int(alpha_tex[g])])
	order.sort_custom(func(x, y): return int(x[2]) > int(y[2]))

	print("%-38s %-5s %5s %4s %5s %-18s %-9s %9s %s"
		% ["texture", "slot", "uses", "fmt", "dxgi", "dxgi name", "real ch",
		   "size", "godot fmt (decompressed)"])
	var done := 0
	var rows: Array = []
	var unmapped: Array = []
	var snorm: Array = []
	for o in order:
		if done >= cap:
			break
		var guid := str(o[0])
		var slot := str(o[1])
		var uses := int(o[2])
		var an := _name_of(guid)
		if an == "":
			print("   %-38s %-5s %5d   (guid %s does not resolve to an asset)"
				% ["?", slot, uses, guid])
			continue
		var key := "%s|%s" % [an, slot]
		if _seen_tex.has(key):
			continue
		var st := _measure(an)
		_seen_tex[key] = st
		done += 1
		if st.is_empty():
			print("   %-38s %-5s %5d   FAILED: %s"
				% [an.get_file().substr(0, 38), slot, uses,
				   str(_last_err)])
			continue
		st["slot"] = slot
		st["uses"] = uses
		st["asset"] = an
		rows.append(st)
		if int(st["dxgi"]) == 0:
			unmapped.append("%s (BF6 fmt %d)" % [an.get_file(), int(st["bf6fmt"])])
		if SNORM_DXGI.has(int(st["dxgi"])):
			snorm.append("%s (DXGI %d)" % [an.get_file(), int(st["dxgi"])])
		print("%-38s %-5s %5d %4d %5d %-18s %-9s %4dx%-4d %d %s"
			% [an.get_file().substr(0, 38), slot, uses, int(st["bf6fmt"]),
			   int(st["dxgi"]), str(DXGI_NAME.get(int(st["dxgi"]), "?")),
			   str(REAL_CH.get(int(st["dxgi"]), "?")),
			   int(st["w"]), int(st["h"]), int(st["gfmt_raw"]),
			   "-> %d" % int(st["gfmt_dec"])])

	print("\n--- per-channel statistics (fractions of sampled texels) -------")
	print("near0 = value < 0.02, near1 = value > 0.98, mid = 0.10..0.90")
	for st in rows:
		var real := str(REAL_CH.get(int(st["dxgi"]), "?"))
		print("\n%s   [%s slot, %d states, %dx%d, DXGI %d %s, real channels %s]"
			% [str(st["asset"]).get_file(), str(st["slot"]), int(st["uses"]),
			   int(st["w"]), int(st["h"]), int(st["dxgi"]),
			   str(DXGI_NAME.get(int(st["dxgi"]), "?")), real])
		print("   ch  %-7s %-7s %-7s   near0   near1     mid  verdict"
			% ["min", "mean", "max"])
		var names := ["R", "G", "B", "A"]
		for i in range(4):
			var carried: bool = real.contains(str(names[i]))
			var mnv := float((st["min"] as Array)[i])
			var mxv := float((st["max"] as Array)[i])
			var mean := float((st["mean"] as Array)[i])
			var n0 := float((st["near0"] as Array)[i])
			var n1 := float((st["near1"] as Array)[i])
			var md := float((st["mid"] as Array)[i])
			var verdict := ""
			if not carried:
				verdict = "NOT CARRIED BY THE FORMAT - decoder default"
			elif mxv - mnv < 0.02:
				verdict = "constant"
			elif n0 + n1 > 0.85 and md < 0.10:
				verdict = "BINARY MASK (bimodal)"
			elif n0 + n1 > 0.5:
				verdict = "mostly bimodal, soft edge"
			else:
				verdict = "continuous"
			print("   %s   %-7.4f %-7.4f %-7.4f  %6.2f%%  %6.2f%%  %6.2f%%  %s"
				% [names[i], mnv, mean, mxv, 100.0 * n0, 100.0 * n1,
				   100.0 * md, verdict])
		# the histogram of the channels that could be a mask
		for i in [0, 3]:
			var real2 := str(REAL_CH.get(int(st["dxgi"]), "?"))
			if not real2.contains(["R", "G", "B", "A"][i]):
				continue
			var hs = (st["hist"] as Array)[i]
			var tot := maxi(1, int(st["samples"]))
			var bars: Array = []
			for b in hs:
				bars.append("%.1f" % (100.0 * float(b) / float(tot)))
			print("   %s hist(16 buckets, %% of texels): %s"
				% [["R", "G", "B", "A"][i], " ".join(bars)])

	print("\n--- 4. format audit --------------------------------------------")
	print("textures whose BF6 format code the table does NOT map: %d" % unmapped.size())
	for u in unmapped:
		print("   %s" % u)
	print("textures decoded through a SNORM/signed DXGI code: %d" % snorm.size())
	for s in snorm:
		print("   %s" % s)

	# A census of every BF6 format code that appears on these textures, so an
	# unmapped code shows up as a code rather than as a silent skip.
	var fmt_census := {}
	for st in rows:
		var f := int(st["bf6fmt"])
		fmt_census[f] = int(fmt_census.get(f, 0)) + 1
	var fk: Array = fmt_census.keys()
	fk.sort()
	print("BF6 format codes seen on veg/alpha textures:")
	for f in fk:
		print("   BF6 %2d -> DXGI %-3d %-18s  x%d"
			% [int(f), int(BF6Texture.FMT.get(int(f), 0)),
			   str(DXGI_NAME.get(int(BF6Texture.FMT.get(int(f), 0)), "UNMAPPED")),
			   int(fmt_census[f])])

	# ---- 3. the OTHER slots a vegetation state binds -----------------------
	# "The opacity is in the alpha slot" is only an answer if the slots nobody
	# has named yet are ruled out. A vegetation state binds six slots here and
	# four of them are still nh_******** — any of those could be the real
	# coverage. Two textures per unnamed slot, measured the same way.
	print("\n--- 3. the unnamed slots a veg state also binds ----------------")
	var others: Array = slot_tex.keys()
	others.sort()
	for s in others:
		if str(s) == "basecolor_veg" or str(s) == "alpha":
			continue
		var sub: Dictionary = slot_tex[str(s)]
		var gk: Array = sub.keys()
		gk.sort_custom(func(x, y): return int(sub[x]) > int(sub[y]))
		print("\n   slot %s — %d distinct textures over %d veg states"
			% [str(s), gk.size(), int(co_slots.get(str(s), 0))])
		var n := 0
		for g in gk:
			if n >= 2:
				break
			n += 1
			var an2 := _name_of(str(g))
			if an2 == "":
				print("      (guid %s does not resolve)" % str(g))
				continue
			var st2 := _measure(an2)
			if st2.is_empty():
				print("      %s  FAILED: %s" % [an2.get_file(), _last_err])
				continue
			var real3 := str(REAL_CH.get(int(st2["dxgi"]), "?"))
			print("      %-40s %dx%d BF6 %d -> DXGI %d %s (real %s)"
				% [an2.get_file().substr(0, 40), int(st2["w"]), int(st2["h"]),
				   int(st2["bf6fmt"]), int(st2["dxgi"]),
				   str(DXGI_NAME.get(int(st2["dxgi"]), "?")), real3])
			for i in range(4):
				var nm: String = ["R", "G", "B", "A"][i]
				print("         %s min %.4f mean %.4f max %.4f  near0 %.1f%%  near1 %.1f%%  mid %.1f%%%s"
					% [nm, float((st2["min"] as Array)[i]),
					   float((st2["mean"] as Array)[i]),
					   float((st2["max"] as Array)[i]),
					   100.0 * float((st2["near0"] as Array)[i]),
					   100.0 * float((st2["near1"] as Array)[i]),
					   100.0 * float((st2["mid"] as Array)[i]),
					   "" if real3.contains(nm) else "   (not carried)"])

	# ---- 5. corpus-wide census --------------------------------------------
	# The sections above are the top of the usage list. This one covers EVERY
	# distinct texture in both slots, so "the veg A is sometimes empty" becomes
	# a count rather than an anecdote.
	#
	# Decoded at a 512 cap here, which is a LOWER MIP. That is fine for what
	# this section asks — a channel that is zero at mip0 is zero at every mip,
	# and coverage fractions survive downsampling — but it is NOT valid for the
	# histogram shape, which is why sections 2 and 3 pay for mip0.
	print("\n--- 5. every distinct texture in both slots (512 cap) ----------")
	var veg_const := 0
	var veg_binary := 0
	var veg_other := 0
	var veg_fail := 0
	var a_spans := 0
	var a_below := 0
	var a_binary := 0
	var a_fail := 0
	var a_ramp := 0
	for g in veg_tex.keys():
		var nm2 := _name_of(str(g))
		var q := _quick(nm2)
		if q.is_empty():
			veg_fail += 1
			continue
		if float(q["a_hi"]) - float(q["a_lo"]) < 0.02:
			veg_const += 1
		elif float(q["a_bimodal"]) > 0.90:
			veg_binary += 1
		else:
			veg_other += 1
	for g in alpha_tex.keys():
		var nm3 := _name_of(str(g))
		var q2 := _quick(nm3)
		if q2.is_empty():
			a_fail += 1
			continue
		if float(q2["r_hi"]) < 0.5:
			a_below += 1
		else:
			a_spans += 1
		if float(q2["r_bimodal"]) > 0.90:
			a_binary += 1
		else:
			a_ramp += 1
	print("veg basecolor A over %d textures:" % veg_tex.size())
	print("   CONSTANT (span < 0.02, carries nothing):      %d" % veg_const)
	print("   bimodal 0/1 (a usable silhouette):            %d" % veg_binary)
	print("   neither:                                      %d" % veg_other)
	print("   failed to decode:                             %d" % veg_fail)
	print("alpha-slot R over %d textures:" % alpha_tex.size())
	print("   reaches above 0.5 (a 0.5 iso-line exists):    %d" % a_spans)
	print("   never reaches 0.5 (would vanish at t=0.5):    %d" % a_below)
	print("   bimodal 0/1 (a hard mask):                    %d" % a_binary)
	print("   a ramp (distance field, not a hard mask):     %d" % a_ramp)
	print("   failed to decode:                             %d" % a_fail)

	# ---- 6. a map-wide format census, headers only -------------------------
	# The BC6H bug was a mapping error, not a vegetation problem, so the same
	# class of error is worth looking for across every texture the map binds
	# rather than only the ones this probe decodes. Headers are cheap: no chunk
	# fetch and no decompress, so this can cover thousands of textures.
	print("\n--- 6. map-wide texture format census (headers only) -----------")
	var all_tex := {}
	var scanned_keys := 0
	for bn in by_bundle.keys():
		var pr3: Array = by_bundle[bn]
		var dep3: BF6Depot = pr3[0]
		var blob3: PackedByteArray = pr3[1]
		var step: int = maxi(1, int(dep3.key_to_record.size() / 400))
		var i3 := 0
		for k in dep3.key_to_record.keys():
			i3 += 1
			if i3 % step != 0:
				continue
			scanned_keys += 1
			var sl: Dictionary = dep3.textures_for(int(k), blob3)
			sl.erase("constants")
			for s in sl.keys():
				all_tex[str(sl[s])] = str(s)
			if all_tex.size() > 4000:
				break
	var census := {}
	var examples := {}
	var read_ok := 0
	var unmapped2 := {}
	for g in all_tex.keys():
		var nm4 := _name_of(str(g))
		if nm4 == "":
			continue
		var raw4: PackedByteArray = gs.src.get_res(nm4)
		if raw4.size() < 56:
			continue
		var tx4 := BF6Texture.new()
		var h4 := tx4.header(raw4)
		if h4.is_empty():
			continue
		read_ok += 1
		var f4 := int(h4["format"])
		census[f4] = int(census.get(f4, 0)) + 1
		# Example names per code. BF6 60 and 61 BOTH map to DXGI 78
		# (BC3_UNORM_SRGB) in the table, and 57/58 both map to 75 — exactly the
		# shape of the BC6H 64/65 collapse. If one of each pair turns out to be
		# the linear twin, the names will say so: normal and mask sheets are
		# never sRGB.
		if not examples.has(f4):
			examples[f4] = []
		if (examples[f4] as Array).size() < 4:
			(examples[f4] as Array).append("%s[%s]" % [nm4.get_file(),
				str(all_tex[str(g)])])
		if int(h4["dxgi"]) == 0:
			unmapped2[f4] = str(nm4.get_file())
	print("sampled %d state keys -> %d distinct textures, %d headers read"
		% [scanned_keys, all_tex.size(), read_ok])
	var ck2: Array = census.keys()
	ck2.sort()
	for f in ck2:
		var dg := int(BF6Texture.FMT.get(int(f), 0))
		print("   BF6 %2d -> DXGI %-3d %-20s x%d%s"
			% [int(f), dg, str(DXGI_NAME.get(dg, "UNMAPPED")), int(census[f]),
			   "   <- SIGNED/SNORM" if SNORM_DXGI.has(dg) else ""])
		print("        e.g. %s" % ", ".join(examples.get(int(f), [])))
	if unmapped2.is_empty():
		print("   no unmapped BF6 format codes in the sample")
	else:
		for f in unmapped2.keys():
			print("   UNMAPPED BF6 code %d, e.g. %s" % [int(f), str(unmapped2[f])])

	# ---- 7. is the BC3 pair collapsed the way BC6H was? --------------------
	# BF6 60 and 61 both map to DXGI 78 (BC3_UNORM_SRGB), so the reader calls
	# both sRGB. The BC7 pair right below them is NOT collapsed — 66 is linear
	# and 67 is sRGB — and their example names line up perfectly with that:
	# 66 carries _nts / _n, 67 carries _ca / _cs.
	#
	# A normal map's XY must average 0.5 in LINEAR encoding. If a BF6-60 normal
	# sheet's raw RG mean is ~0.5 it is linear data wearing an sRGB flag, and
	# 60 is the BC3_UNORM (77) twin rather than a second spelling of 78.
	print("\n--- 7. BF6 60 vs 61: which one is actually linear? -------------")
	for f in [60, 61]:
		print("   BF6 %d:" % f)
		var n7 := 0
		for g in all_tex.keys():
			if n7 >= 3:
				break
			var nm7 := _name_of(str(g))
			if nm7 == "":
				continue
			var raw7: PackedByteArray = gs.src.get_res(nm7)
			if raw7.size() < 56:
				continue
			var tx7 := BF6Texture.new()
			var h7 := tx7.header(raw7)
			if h7.is_empty() or int(h7["format"]) != f:
				continue
			var st7 := _measure(nm7)
			if st7.is_empty():
				continue
			n7 += 1
			print("      %-44s R %.3f  G %.3f  B %.3f  A %.3f"
				% [nm7.get_file().substr(0, 44),
				   float((st7["mean"] as Array)[0]),
				   float((st7["mean"] as Array)[1]),
				   float((st7["mean"] as Array)[2]),
				   float((st7["mean"] as Array)[3])])

	quit(0)


# A cheap look at one texture: enough to say whether a channel carries
# anything, not enough to judge histogram shape.
func _quick(asset_name: String) -> Dictionary:
	if asset_name == "":
		return {}
	var raw: PackedByteArray = gs.src.get_res(asset_name)
	if raw.is_empty():
		return {}
	var tx := BF6Texture.new()
	var got: Dictionary = tx.decode(raw,
		func(form): return gs.src.get_chunk(str(form)), 512)
	if got.is_empty() or not (got.get("image") is Image):
		return {}
	var c := (got["image"] as Image).duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		return {}
	var w := c.get_width()
	var h := c.get_height()
	var sx: int = maxi(1, int(w / 192))
	var sy: int = maxi(1, int(h / 192))
	var alo := 2.0
	var ahi := -1.0
	var rlo := 2.0
	var rhi := -1.0
	var ab := 0
	var rb := 0
	var n := 0
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var p := c.get_pixel(x, y)
			alo = minf(alo, p.a)
			ahi = maxf(ahi, p.a)
			rlo = minf(rlo, p.r)
			rhi = maxf(rhi, p.r)
			if p.a < 0.02 or p.a > 0.98:
				ab += 1
			if p.r < 0.02 or p.r > 0.98:
				rb += 1
			n += 1
	return {"a_lo": alo, "a_hi": ahi, "r_lo": rlo, "r_hi": rhi,
		"a_bimodal": float(ab) / float(maxi(1, n)),
		"r_bimodal": float(rb) / float(maxi(1, n))}


var _last_err := ""


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


# Decode a texture at FULL resolution and measure every channel.
#
# max_dim 0 on purpose. A capped decode returns a lower mip, and a downsampled
# binary mask is a gradient — which would answer question 5 backwards.
func _measure(asset_name: String) -> Dictionary:
	_last_err = ""
	var raw: PackedByteArray = gs.src.get_res(asset_name)
	if raw.is_empty():
		_last_err = "no res bytes"
		return {}
	var tx := BF6Texture.new()
	var hdr := tx.header(raw)
	var got: Dictionary = tx.decode(raw,
		func(form): return gs.src.get_chunk(str(form)), 0)
	if got.is_empty() or not (got.get("image") is Image):
		_last_err = "%s (BF6 fmt %d, dxgi %d)" % [tx.error,
			int(hdr.get("format", -1)), int(hdr.get("dxgi", 0))]
		return {}
	var img: Image = got["image"]
	var gfmt_raw := img.get_format()
	var c := img.duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		_last_err = "decompress failed"
		return {}

	var w := c.get_width()
	var h := c.get_height()
	var sx: int = maxi(1, int(w / 320))
	var sy: int = maxi(1, int(h / 320))
	var mn := [2.0, 2.0, 2.0, 2.0]
	var mx := [-2.0, -2.0, -2.0, -2.0]
	var sm := [0.0, 0.0, 0.0, 0.0]
	var n0 := [0, 0, 0, 0]
	var n1 := [0, 0, 0, 0]
	var md := [0, 0, 0, 0]
	# Plain Arrays, NOT PackedInt32Array. `hist[i][b] += 1` on a packed array
	# increments a COPY — GDScript hands back packed arrays by value — and the
	# first version of this printed sixteen zeroes for every histogram because of
	# it. Untyped Array is a reference type and accumulates in place.
	var hist: Array = []
	for i in range(4):
		var hh: Array = []
		hh.resize(16)
		hh.fill(0)
		hist.append(hh)
	var n := 0
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var p := c.get_pixel(x, y)
			var v := [p.r, p.g, p.b, p.a]
			for i in range(4):
				var f := float(v[i])
				mn[i] = minf(mn[i], f)
				mx[i] = maxf(mx[i], f)
				sm[i] += f
				if f < 0.02:
					n0[i] += 1
				elif f > 0.98:
					n1[i] += 1
				if f >= 0.10 and f <= 0.90:
					md[i] += 1
				var b: int = clampi(int(f * 16.0), 0, 15)
				(hist[i] as Array)[b] = int((hist[i] as Array)[b]) + 1
			n += 1
	var mean: Array = []
	var f0: Array = []
	var f1: Array = []
	var fm: Array = []
	for i in range(4):
		mean.append(sm[i] / float(maxi(1, n)))
		f0.append(float(n0[i]) / float(maxi(1, n)))
		f1.append(float(n1[i]) / float(maxi(1, n)))
		fm.append(float(md[i]) / float(maxi(1, n)))
	return {
		"bf6fmt": int(hdr.get("format", -1)),
		"dxgi": int(got.get("dxgi", 0)),
		"srgb": bool(got.get("srgb", false)),
		"chunk": str(got.get("chunk", "")),
		"w": w, "h": h,
		"gfmt_raw": gfmt_raw, "gfmt_dec": c.get_format(),
		"min": mn, "max": mx, "mean": mean,
		"near0": f0, "near1": f1, "mid": fm,
		"hist": hist, "samples": n,
	}
