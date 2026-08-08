extends SceneTree

# The terrain LAYER chain: level -> compiled layer graphs -> layergraphs
# ShaderBlockDepot -> the per-layer albedo / normal textures the game streams.
#
# This is the chain TERRAIN.md §9 specifies and that nothing here has ever
# walked. Our ground currently comes from four bundled PNGs (ground/cliff, albedo
# and normal) that were extracted once by hand; the game ships a whole palette
# per level and says which layer covers which texel.
#
# §9.1's locating rule is the interesting part: the record table's start offset
# is NOT stored. You find it by scanning candidate offsets until EVERY record's
# ShaderBlockKey resolves in the paired depot. That 100%-resolve requirement is
# what makes the fit unambiguous, so this probe reports the resolve rate for
# every candidate rather than taking the first that looks plausible.
#
#   godot --headless --path native/_testproj --script probe_layers.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Depot := preload("res://bf6_depot.gd")

const RES_LAYERGRAPHS := 0xDE540C59
const RES_DEPOT := 0x73312045
const RES_LAYERCOMB := 0x1CA38E06
const STRIDE := 32


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount: %s" % src.error); quit(1); return

	# --- the three resources of the chain ------------------------------------
	var lg_name := ""
	var lc_name := ""
	var depot_name := ""
	for rn in src.res.keys():
		var n := str(rn)
		var ty := int(src.res[rn][5])
		if ty == RES_LAYERGRAPHS and n.to_lower().contains(level):
			lg_name = n
		elif ty == RES_LAYERCOMB and n.to_lower().contains(level):
			lc_name = n
		elif ty == RES_DEPOT and n.to_lower().contains("layergraph"):
			depot_name = n
	print("layer graphs      %s" % (lg_name if lg_name != "" else "ABSENT"))
	print("layer combinations %s" % (lc_name if lc_name != "" else "ABSENT"))
	print("layergraphs depot  %s" % (depot_name if depot_name != "" else "ABSENT"))
	if depot_name == "":
		# The depot may not carry "layergraph" in its name; take any depot that
		# lives beside the terrain resources.
		for rn in src.res.keys():
			if int(src.res[rn][5]) == RES_DEPOT and str(rn).to_lower().contains(level + "_terrain"):
				depot_name = str(rn)
				print("   (found beside the terrain: %s)" % depot_name)
				break
	if lg_name == "" or depot_name == "":
		print("\nFAIL: the chain does not close on this level"); quit(1); return

	# --- §9.2 layer combinations: how many layers, and which are Linked -------
	var link_of: Array = []
	if lc_name != "":
		var lc := src.get_res(lc_name)
		print("\nlayer combinations (%d bytes):" % lc.size())
		var strs := _strings(lc)
		for s in strs:
			print("   shader: %s" % s)
		# after the strings: u64 SurfaceShaderBlockKey, u32 layerCount,
		# layerCount x [u8 flag][u32 linkTarget], ending exactly at EOF.
		var tail_n := -1
		for cand in range(strs.size()):
			pass
		# Locate by the invariant instead of by string length: the table must
		# end exactly at EOF, so layerCount is fixed by the file size.
		for off in range(0, lc.size() - 12):
			var n := int(lc.decode_u32(off + 8))
			if n > 0 and n < 512 and off + 12 + n * 5 == lc.size():
				print("   SurfaceShaderBlockKey 0x%016X" % lc.decode_u64(off)
					if lc.decode_u64(off) >= 0 else "   SurfaceShaderBlockKey (neg)")
				print("   layerCount %d" % n)
				tail_n = n
				var linked := 0
				for i in range(n):
					var t := int(lc.decode_u32(off + 12 + i * 5 + 1))
					link_of.append(t)
					if t != -1 and t != 0xFFFFFFFF:
						linked += 1
				print("   linked layers %d of %d" % [linked, n])
				break
		if tail_n < 0:
			print("   (layer table did not land on EOF)")

	# --- the depot ------------------------------------------------------------
	var draw := src.get_res(depot_name)
	var depot = BF6Depot.new()
	if not depot.parse(draw):
		print("\nFAIL depot: %s" % depot.error); quit(1); return
	print("\ndepot %s: %d records" % [depot_name, depot.records.size()])

	# --- §9.1 record table: find the start by the 100%-resolve rule ----------
	var lg := src.get_res(lg_name)
	var declared := int(lg.decode_u32(8))
	print("\nlayer graphs (%d bytes): recordCount @ +8 = %d" % [lg.size(), declared])
	if declared <= 0 or declared > 4096:
		print("FAIL: implausible record count"); quit(1); return

	var best := -1
	var best_rate := -1.0
	for off in range(12, lg.size() - declared * STRIDE + 1, 4):
		var hit := 0
		for i in range(declared):
			var k := lg.decode_u64(off + i * STRIDE + 20)
			if depot.key_to_record.has(k):
				hit += 1
		var rate := float(hit) / float(declared)
		if rate > best_rate:
			best_rate = rate; best = off
		if hit == declared:
			break
	print("record table start %d, ShaderBlockKey resolve %d/%d (%.1f%%)"
		% [best, int(best_rate * declared), declared, best_rate * 100.0])
	if best_rate < 1.0:
		print("   (the §9.1 rule wants 100%; anything less means the fit is wrong)")

	# --- what each layer actually binds ---------------------------------------
	#
	# textures_for returns {slot NAME: file guid}. The guid resolves to an asset
	# name through the partition index, which is the expensive part of a cold
	# open and is cached — worth paying here because the NAMES are what say what
	# a layer is (asphalt, fairway grass, sand), and that is the whole point of
	# reading the palette instead of guessing at it.
	var pidx: Dictionary = src.partition_index()
	print("\npartition index: %d guids" % pidx.size())

	print("\nper-layer textures:")
	var named := 0
	var tex_guids := {}
	# slot hash -> {suffix: count}. §9.1 classifies terrain textures by the NAME
	# suffix; the slot hash is what the depot actually keys on, and the two are
	# worth cross-tabulating because a layer that binds two materials binds two
	# `_cv`s and the suffix alone cannot tell them apart.
	var slot_suffix := {}
	var const_hist := {}
	for i in range(declared):
		var base := best + i * STRIDE
		var key := lg.decode_u64(base + 20)
		if not depot.key_to_record.has(key):
			print("   L%02d  key %s  UNRESOLVED" % [i, BF6Depot.key_hex(key)])
			continue
		var tex: Dictionary = depot.textures_for(key, draw)
		var consts: Dictionary = tex.get("constants", {})
		tex.erase("constants")
		for ch in consts.keys():
			const_hist[ch] = int(const_hist.get(ch, 0)) + 1
		var bits: Array = []
		var slots: Array = tex.keys()
		slots.sort()
		for slot in slots:
			var g := str(tex[slot])
			var nm := str(pidx.get(g, g))
			var f := nm.get_file() if nm.contains("/") else nm
			f = f.trim_suffix(".ebx")
			bits.append("%s=%s" % [str(slot), f])
			tex_guids[g] = nm
			var suf := "_" + f.get_slice("_", f.get_slice_count("_") - 1)
			if not slot_suffix.has(slot):
				slot_suffix[slot] = {}
			(slot_suffix[slot] as Dictionary)[suf] = \
				int((slot_suffix[slot] as Dictionary).get(suf, 0)) + 1
		if not bits.is_empty():
			named += 1
		var link := ""
		if i < link_of.size() and int(link_of[i]) != -1 and int(link_of[i]) != 0xFFFFFFFF:
			link = "->L%02d" % int(link_of[i])
		print("   L%02d %-7s %2d const  %s"
			% [i, link, consts.size(),
			   ", ".join(bits) if not bits.is_empty() else "(no textures)"])
	print("\nlayers with at least one texture: %d of %d" % [named, declared])
	print("distinct textures referenced:      %d" % tex_guids.size())

	print("\nslot hash -> texture suffix:")
	var sk: Array = slot_suffix.keys()
	sk.sort()
	for s in sk:
		print("   %-12s %s" % [str(s), str(slot_suffix[s])])

	print("\nconstant param hashes, by how many layers set them:")
	var ck: Array = const_hist.keys()
	ck.sort_custom(func(x, y): return int(const_hist[x]) > int(const_hist[y]))
	for c in ck:
		print("   0x%08X  %d layers" % [int(c), int(const_hist[c])])

	# --- do those textures actually exist in this mount? ----------------------
	#
	# The partition index names an EBX partition; the pixels live in the RES of
	# the same path with the `.ebx` dropped. Forgetting that reports every
	# texture as missing, which looks like a broken chain and is not.
	var present := 0
	var missing: Array = []
	for g in tex_guids.keys():
		var nm := str(tex_guids[g]).trim_suffix(".ebx")
		if src.res_info(nm) != null:
			present += 1
		elif missing.size() < 8:
			missing.append(nm)
	print("\nresolvable to a RES in the mount:  %d of %d" % [present, tex_guids.size()])
	for m in missing:
		print("   unresolved: %s" % m)

	quit(0)


# Consecutive NUL-terminated printable runs, per §9.2's locating rule.
func _strings(d: PackedByteArray) -> Array:
	var out: Array = []
	var i := 0
	while i < d.size():
		if d[i] >= 0x20 and d[i] < 0x7F:
			var j := i
			while j < d.size() and d[j] >= 0x20 and d[j] < 0x7F:
				j += 1
			if j - i >= 16 and j < d.size() and d[j] == 0:
				var s := d.slice(i, j).get_string_from_utf8()
				if s.contains("/"):
					out.append(s)
			i = j + 1
		else:
			i += 1
	return out
