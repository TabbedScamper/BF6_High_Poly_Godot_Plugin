@tool
extends RefCounted
class_name BF6TerrainLayers

# The terrain LAYER PALETTE: which materials a level's ground is painted with,
# read from the game rather than guessed at.
#
# Chain, from TERRAIN.md §9:
#
#   <level>_terrain/<level>_terrain            RES 0x1CA38E06  layer combinations
#       -> layerCount, and which layers are Linked (crater sets)
#   <level>_terrain.layergraphslayergraphs     RES 0xDE540C59  compiled layer graphs
#       -> per layer, a ShaderBlockKey
#   <level>_terrain.layergraphs_shaderblockdepot  RES 0x73312045
#       -> per key, the texture refs and shading constants
#
# On mp_dumbo this yields 47 layers whose names are exactly the ones the
# research correlated by hand — L02 cobblestone, L08 concrete tile, L10 broken
# asphalt, L22 fairway grass — plus sand, gravel, cracked concrete and the
# crater set. All 45 distinct textures resolve to a RES in the same mount.
#
# WHAT THE SLOT HASHES ARE. §9.1 classifies these textures by NAME SUFFIX
# (`_cv`, `_nhs`, `_ao`, `_ncs`, `_op`). That works until a layer binds two
# materials at once, which four of dumbo's do — L42 binds cracked concrete AND
# asphalt edge, so it binds two `_cv`s and the suffix cannot say which is which.
# The depot keys each texture by a parameter hash, and those hashes fall into
# clean per-slot families, measured over every layer of the map:
#
#   set A   0x0929399A _cv (12/12)   0x09293A41 _ao (11/11)   0x2E50567A _nhs (12/12)
#   set B   0x2E5ACDA8 _cv           0x2E5ACDF3 _ao           0xF9B44F08 _nhs
#   set C   0x2E5B5189 _cv           0x2E5B51D2 _ao           0xF9C55709 _nhs
#   shared  0x09293810 default/_op   0xB6C7E795 _ncs          0x0B725504 breakup noise
#
# No hash was ever seen carrying two different suffixes, so the families are the
# reliable reading and the suffix is the corroboration.

const RES_LAYERGRAPHS := 0xDE540C59
const RES_DEPOT := 0x73312045
const RES_LAYERCOMB := 0x1CA38E06
const STRIDE := 32

# slot hash -> [set, role]
const SLOTS := {
	0x0929399A: ["a", "cv"], 0x09293A41: ["a", "ao"], 0x2E50567A: ["a", "nhs"],
	0x2E5ACDA8: ["b", "cv"], 0x2E5ACDF3: ["b", "ao"], 0xF9B44F08: ["b", "nhs"],
	0x2E5B5189: ["c", "cv"], 0x2E5B51D2: ["c", "ao"], 0xF9C55709: ["c", "nhs"],
	0x304613CC: ["b", "ao"], 0xF860C3BE: ["c", "ao"],
	0x09293810: ["a", "default"], 0xB6C7E795: ["a", "ncs"],
	0x0B725504: ["a", "breakup"],
}
# §9.1's identified shading constants, all three of which this map does set:
# tiling on 37 layers, smoothness on 29, tint on 7.
const C_TILING := 0x5707A992         # f32 repeats per metre
const C_SMOOTHNESS := 0xFA13C5B0     # f32
const C_TINT := 0x4FDCF6B1           # vec3 linear albedo tint

var error := ""
var layers: Array = []               # per index: {textures:{}, tiling, smoothness, tint, link}
var surface_key := 0
var record_offset := -1
var resolve_rate := 0.0
# What the offset search cost and how much of the buffer it had to look at.
# Recorded because this search froze a user's editor for 2 m 34 s and the log
# could only say that it happened, not how close it came or how much work it
# did. A future report should be able to say whether the fix held.
var scan_ms := 0
var scan_candidates := 0


# -> true when the whole chain closes on this level.
func load(src, level: String, pidx: Dictionary) -> bool:
	error = ""
	layers.clear()
	var lg_name := ""
	var lc_name := ""
	var depot_name := ""
	var low := level.to_lower()
	for rn in src.res.keys():
		var ty := int(src.res[rn][5])
		if ty != RES_LAYERGRAPHS and ty != RES_LAYERCOMB and ty != RES_DEPOT:
			continue
		var n := str(rn)
		var nl := n.to_lower()
		if ty == RES_LAYERGRAPHS and nl.contains(low):
			lg_name = n
		elif ty == RES_LAYERCOMB and nl.contains(low):
			lc_name = n
		elif ty == RES_DEPOT and nl.contains("layergraph"):
			depot_name = n
	if lg_name == "" or depot_name == "":
		error = "no layer graphs (%s) or layergraphs depot (%s) for %s" % [
			lg_name, depot_name, level]
		return false

	# --- §9.2: layer count and the Linked (crater) layers --------------------
	var link_of: Array = []
	if lc_name != "":
		var lc: PackedByteArray = src.get_res(lc_name)
		# The table is located by its own invariant — it must end exactly at EOF
		# — rather than by measuring the variable-length string region.
		for off in range(0, maxi(0, lc.size() - 12)):
			var n := int(lc.decode_u32(off + 8))
			if n > 0 and n < 512 and off + 12 + n * 5 == lc.size():
				surface_key = int(lc.decode_u64(off))
				for i in range(n):
					link_of.append(int(lc.decode_u32(off + 12 + i * 5 + 1)))
				break

	# --- §9.1: find the record table by the 100%-resolve rule ----------------
	var draw: PackedByteArray = src.get_res(depot_name)
	var depot = BF6Depot.new()
	if not depot.parse(draw):
		error = "layergraphs depot: %s" % depot.error
		return false
	var lg: PackedByteArray = src.get_res(lg_name)
	var declared := int(lg.decode_u32(8))
	if declared <= 0 or declared > 4096:
		error = "implausible layer-graph record count %d" % declared
		return false
	record_offset = -1
	resolve_rate = 0.0
	var t_scan := Time.get_ticks_msec()
	# TWO PASSES, because the one-pass version froze the editor for two and a
	# half minutes on the installs that need this code to be fast.
	#
	# The old loop tested all `declared` keys at every 4-byte offset and broke
	# out only on a 100% match. On an install where the offset CAN be pinned
	# that break comes early and the cost is invisible. On an install where it
	# cannot, there is no break at all: it grinds the whole buffer at `declared`
	# dictionary lookups per offset, on the main thread, and the editor is gone
	# for minutes.
	#
	# So the two failures we have been treating as separate are one failure. The
	# users who report "the terrain textures are corrupt" are exactly the users
	# for whom this never reaches 100%, and therefore exactly the users for whom
	# it never breaks early. Measured from a user's log: 2 m 34 s here, then
	# 5.7 s, on a map whose palette then came out unusable.
	#
	# PASS 1 filters on the FIRST record only. If all `declared` keys resolve at
	# an offset then that offset's first key resolves too, so no possible winner
	# is discarded - the filter is a superset of the answer, not a heuristic.
	# One lookup per offset instead of `declared` of them.
	var cands: Array = []
	for off in range(12, lg.size() - declared * STRIDE + 1, 4):
		if depot.key_to_record.has(lg.decode_u64(off + 20)):
			cands.append(off)
	# PASS 2 is the original test, run only on what survived. A 64-bit key
	# colliding with this depot by chance is vanishingly unlikely, so this list
	# is short on every install, including the ones that never find a match.
	for off in cands:
		var hit := 0
		for i in range(declared):
			if depot.key_to_record.has(lg.decode_u64(off + i * STRIDE + 20)):
				hit += 1
		var rate := float(hit) / float(declared)
		if rate > resolve_rate:
			resolve_rate = rate
			record_offset = off
		if hit == declared:
			break
	scan_ms = Time.get_ticks_msec() - t_scan
	scan_candidates = cands.size()
	if cands.is_empty():
		# Distinct from a partial fit, and a stronger statement: not one offset
		# in the whole table resolved even its first record. That is a depot
		# that does not describe this level's layer graphs at all, rather than a
		# record layout we failed to locate.
		error = ("terrain layer palette UNUSABLE - this level's layer graphs "
			+ "match NOTHING in its shader depot (no offset resolved even one "
			+ "record, %d records looked for, scan took %d ms). The ground will "
			+ "draw without its layer materials.") % [declared, scan_ms]
		return false
	if record_offset < 0 or resolve_rate < 1.0:
		# §9.1 makes the 100% requirement the thing that pins the offset. A
		# partial fit is not a partial answer, it is the wrong offset.
		#
		# SAY THAT, because the bare percentage reads as "most of it resolved"
		# and it means the opposite: the palette is unusable and the ground
		# draws with no layer materials at all. A user reported "textures are
		# really corrupt" and their log carried this at 5.0% as a passing info
		# line that nobody read as a failure - including me, at first.
		#
		# The usual cause is a game version whose record layout this search
		# cannot pin, NOT missing files, and those are different fixes.
		error = ("terrain layer palette UNUSABLE - the record table offset "
			+ "could not be pinned (best fit %.1f%% of %d records over %d "
			+ "candidate offsets, needs 100%%; scan took %d ms). Usually a "
			+ "game version whose layout differs from what this reader "
			+ "expects, rather than missing files. The ground will draw "
			+ "without its layer materials.") % [resolve_rate * 100.0,
				declared, scan_candidates, scan_ms]
		return false

	# --- what each layer binds ------------------------------------------------
	for i in range(declared):
		var key := lg.decode_u64(record_offset + i * STRIDE + 20)
		var lay := {
			"index": i, "textures": {}, "tiling": 0.0, "smoothness": -1.0,
			"tint": Color(1, 1, 1),
			"link": int(link_of[i]) if i < link_of.size() else -1,
		}
		if int(lay["link"]) == -1 or int(lay["link"]) == 0xFFFFFFFF:
			lay["link"] = -1
		if depot.key_to_record.has(key):
			var ps: Array = depot.params(int(depot.key_to_record[key]), draw)
			for p in ps:
				var pd: Dictionary = p
				var n32 := int(pd["name32"])
				if int(pd["type_hash"]) == BF6Depot.TH_TEXTURE:
					if (pd["refs"] as Array).is_empty() or not SLOTS.has(n32):
						continue
					var role: Array = SLOTS[n32]
					var guid: String = ((pd["refs"] as Array)[0] as Array)[1]
					var nm := str(pidx.get(guid, "")).trim_suffix(".ebx")
					if nm == "":
						continue
					# The pixels are the RES of the same path with `.ebx`
					# dropped; the partition index names the EBX.
					(lay["textures"] as Dictionary)["%s_%s" % [role[0], role[1]]] = nm
				else:
					var raw = pd["raw"]
					if raw == null:
						continue
					var rb: PackedByteArray = raw
					if n32 == C_TILING and rb.size() >= 4:
						lay["tiling"] = rb.decode_float(0)
					elif n32 == C_SMOOTHNESS and rb.size() >= 4:
						lay["smoothness"] = rb.decode_float(0)
					elif n32 == C_TINT and rb.size() >= 12:
						lay["tint"] = Color(rb.decode_float(0), rb.decode_float(4),
							rb.decode_float(8))
		layers.append(lay)
	return true


# The albedo of a layer, preferring the primary material set.
func albedo_of(i: int) -> String:
	if i < 0 or i >= layers.size():
		return ""
	var t: Dictionary = (layers[i] as Dictionary)["textures"]
	for k in ["a_cv", "b_cv", "c_cv"]:
		if t.has(k):
			return str(t[k])
	return ""


func normal_of(i: int) -> String:
	if i < 0 or i >= layers.size():
		return ""
	var t: Dictionary = (layers[i] as Dictionary)["textures"]
	for k in ["a_nhs", "b_nhs", "c_nhs"]:
		if t.has(k):
			return str(t[k])
	return ""


# World metres per texture repeat, for a layer, with a sane default.
#
# The constant is `repeats per metre`, so the shader wants its reciprocal. A
# layer that sets no tiling (10 of dumbo's 47) gets the map's median rather than
# an invented number.
func metres_per_repeat(i: int, fallback := 4.0) -> float:
	if i < 0 or i >= layers.size():
		return fallback
	var t := float((layers[i] as Dictionary)["tiling"])
	if t <= 0.00001:
		return fallback
	return 1.0 / t


func textured_indices() -> Array:
	var out: Array = []
	for l in layers:
		if not ((l as Dictionary)["textures"] as Dictionary).is_empty():
			out.append(int((l as Dictionary)["index"]))
	return out
