@tool
extends RefCounted
class_name BF6Depot

# ShaderBlockDepotResource: which textures a piece of geometry actually binds.
#
# This is the last link. bf6_walk says WHERE a prop goes, bf6_meshset gives its
# geometry, bf6_texture turns a TextureResource into an Image — and this says
# WHICH textures. Without it the reader produces untextured maps, and textures
# are 4.5 GB of the 6.6 GB download the reader exists to delete.
#
# Ported from tools/shaderblock.py, whose layout was reverse-engineered from
# retail data and then validated by parsing all 8,744 depot files in the dump
# to their exact end. The container is NOT the SWBF2 one Frosty documents:
# there is no 16-byte resMeta, no {offset,type} entry table and no five-type
# resource tree.
#
#   +0    u64 header_a  (= 16: the key table starts here)
#   +8    u64 header_b  (= 0)
#   +16   KEY TABLE   N x {u64 key; u64 recPtr}
#         recPtr is an ABSOLUTE file offset of a 24-byte record.
#         The table runs to the first record's data offset — key table and
#         blob area are back to back, which is how N is recovered.
#   +D    BLOB AREA   contiguous, CONTENT-DEDUPLICATED parameter blobs
#                     (4,238 blobs for 24,696 keys in the reference file)
#   +R    RECORDS     M x {u64 dataOffset; u64 contentHash; u64 size},
#                     dataOffset ascending and exactly tiling the blob area
#
# THE JOIN, which is the part nobody had: a MeshSet section stores its 64-bit
# shader state key inline at +0x130, and key_to_record[state_key] is the
# record holding that section's textures. It is NOT the MVDB's
# SurfaceShaderGuid/SurfaceShaderId — those name the shader ASSET (nine
# distinct values across 4,454 MVDB entries) and appear nowhere in a depot.
#
# Validated in Python on mp_portal_sand: 20 random meshes -> 32/32 materials
# joined; the 40 largest multi-material meshes -> 346/366, with all 20 misses
# being M_*Shadow* materials whose states are simply not in the depot. Every
# renderable material joins exactly.

const TH_TEXTURE := 0xcc84d53d

# Inline scalar sizes by type hash. The type hash IS a Frostbite name hash, but
# BF6 changed the hash function from SWBF2's, so most of these are known by
# size and behaviour rather than by name. An unknown type hash is a hard error
# rather than a skip: the entries are packed with no alignment, so guessing a
# size does not lose one parameter, it desynchronises the whole blob.
const SCALAR_SIZE := {
	0x14a0b1c1: 4,   # Float32
	0xa1c34f4a: 4, 0x34791132: 4, 0x56b8d054: 4, 0x80f40524: 4,
	0xf682b971: 4, 0xbb4b3d1c: 4, 0x8182bee2: 4, 0x6f07e870: 4,
	0x56403cba: 4, 0x68b06dfb: 4, 0xa08d014b: 4,
	0x48ecee3e: 4,   # QualityLevel — inline WITHOUT the usual flags bit15,
	                 # which is why the form is dispatched on the TYPE hash
	                 # and never on the flags
	0x39ab6941: 8,   # Vec2
	0x25f81af1: 12,  # float3
	0xdef2e1a5: 16,  # float4
	0x26b52646: 1,   # bool/u8
}

# Texture slots, by the parameter's full 32-bit name hash. THE FULL 32 BITS
# matter: BaseColor and BaseColorVeg share the top half 0x54BB, and Emissive
# and Alpha share 0xD405, so comparing nameHashHi alone silently confuses them.
const SLOT_BASECOLOR := 0x54bbcd30
const SLOT_BASECOLOR_VEG := 0x54bbcd36   # vegetation *_cu sheet; its opacity
                                         # rides the ALPHA twin, not the _cs
const SLOT_NORMAL := 0xec35a74c
const SLOT_NORMAL_VT := 0xec35a9e2       # architecture normal paired with the
                                         # tiling basecolor; RG only
const SLOT_EMISSIVE := 0xd405b0e5
const SLOT_ALPHA := 0xd405b0e1
const SLOT_TILEBREAKER := 0x851a1207
const SLOT_WRAP := 0x54bbcd22
const SLOT_FACADE_BAKE := 0x21f3f4e1
const SLOT_FACADE_ALPHA := 0xa7e2f2fb
const SLOT_BACKDROP_FACADE := 0xc8c9370a
const SLOT_BACKDROP_ROOF := 0x62dfb21a
const SLOT_BACKDROP_PALETTE := 0x31ebaba9
const SLOT_GLASS_VOLUME := 0xbb245590
const SLOT_CARPAINT_FLAKES := 0xa11011b8
# THE LIT SHEET. A light fixture's glow is here and NOT in SLOT_EMISSIVE, which
# is why lamps drew dark: of 1,075 sampled records 53 bind this and only 4 bind
# the named emissive slot. Its textures are named _ea, _e or _emissive - the same
# suffix convention the decal sheets use - and RGB is the glow. 30 of the 53 bind
# t_red, a flat placeholder, so the content test still has to run.
const SLOT_EMISSIVE_LIT := 0x407055fd

# BACKDROP SMOKE PLUMES bind their own pair and no named basecolor, which is why
# 23 placed plumes on mp_aftermath drew white. RGB+A is the smoke, and the noise
# sheet beside it is where the motion comes from. See smoke.gdshader.
const SLOT_SMOKE_CA := 0x48b69b15
const SLOT_SMOKE_NOISE := 0xba5b7844
# The VERTICAL plume family is a second recipe on the same colour slot: a 1 m
# card, a different noise, a soft-edge mask, and a blackbody ramp that colours
# the hot part of the column instead of a flat tint.
const SLOT_SMOKE_NOISE2 := 0xd0182167    # t_tilingnoises_curly_01_d
const SLOT_SMOKE_RAMP := 0x0127e78c      # t_blackbodyramps_01_m
const SLOT_SMOKE_EDGE := 0x42ec27b9      # box_softedge_02

# Placeable mesh decals bind a family of their own and none of the slots above.
# Only these two ever carry content: on mp_dumbo's 160 decal prefabs the other
# three are defaulted on every record (0x416b0e23 = t_grid 134/134, 0x4227843b =
# t_debug_r 120/120, 0x91dfa679 = t_base_n 22/22), so they are never read.
const SLOT_DECAL_CA := 0x87180b38        # RGB colour, A coverage
const SLOT_DECAL_NRM := 0x6a19658a       # RG normal; B/A per family, see decal.gdshader

const SLOT_NAME := {
	SLOT_BASECOLOR: "basecolor", SLOT_BASECOLOR_VEG: "basecolor_veg",
	SLOT_NORMAL: "normal", SLOT_NORMAL_VT: "normal_vt",
	SLOT_EMISSIVE: "emissive", SLOT_ALPHA: "alpha",
	SLOT_TILEBREAKER: "tilebreaker", SLOT_WRAP: "wrap",
	SLOT_FACADE_BAKE: "facade", SLOT_FACADE_ALPHA: "facade_alpha",
	SLOT_BACKDROP_FACADE: "backdrop_facade", SLOT_BACKDROP_ROOF: "backdrop_roof",
	SLOT_BACKDROP_PALETTE: "backdrop_palette",
	SLOT_GLASS_VOLUME: "glass_volume", SLOT_CARPAINT_FLAKES: "carpaint_flakes",
	SLOT_DECAL_CA: "decal_ca", SLOT_DECAL_NRM: "decal_nrm",
	SLOT_EMISSIVE_LIT: "emissive_lit",
	SLOT_SMOKE_CA: "smoke_ca", SLOT_SMOKE_NOISE: "smoke_noise",
	SLOT_SMOKE_NOISE2: "smoke_noise2", SLOT_SMOKE_RAMP: "smoke_ramp",
	SLOT_SMOKE_EDGE: "smoke_edge",
}

var error := ""
var records: Array = []          # [{offset, content_hash, size, params}]
var key_to_record := {}          # u64 state key -> record index
var header: Array = [0, 0]


# The parameter's full 32-bit name hash, recomposed from the two halves the
# entry stores apart. (SWBF2's formula; BF6's mapping back to text is unsolved,
# but the composition is still what identifies a slot.)
static func name32(param_hash: int, name_hash_hi: int) -> int:
	return ((name_hash_hi << 16) | ((param_hash >> 48) & 0xFFFF)) & 0xFFFFFFFF


# A state key as 16 hex digits.
#
# GDScript has no unsigned 64-bit integer, so any key with the top bit set is a
# NEGATIVE int and "%016x" renders it as "-1ca05f4a9d69dcd0" rather than
# "e35fa0b562962330". The bit pattern is right and dictionary lookups work
# perfectly — which is exactly why this is dangerous: it is invisible until a
# key is printed, logged or used as a string cache key, and then two spellings
# of the same key stop matching each other.
static func key_hex(v: int) -> String:
	return "%08x%08x" % [(v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF]


static func guid_str(b: PackedByteArray) -> String:
	if b.size() < 16:
		return ""
	return "%08x-%04x-%04x-%s-%s" % [b.decode_u32(0), b.decode_u16(4),
			b.decode_u16(6), b.slice(8, 10).hex_encode(),
			b.slice(10, 16).hex_encode()]


func parse(d: PackedByteArray) -> bool:
	error = ""
	records.clear()
	key_to_record.clear()
	if d.size() < 32:
		error = "too small to be a depot"
		return false
	var a := int(d.decode_u64(0))
	header = [a, int(d.decode_u64(8))]
	if a != 16:
		error = "unexpected header_a %d (expected the key table at 16)" % a
		return false

	# THE KEY TABLE'S LENGTH IS NOT STORED. It is recovered by dereferencing the
	# first pair's record pointer: that record's dataOffset is where the blob
	# area starts, which is exactly where the key table ends.
	var ptr0 := int(d.decode_u64(24))
	if ptr0 + 8 > d.size():
		error = "first record pointer %d is outside the file" % ptr0
		return false
	var data_start := int(d.decode_u64(ptr0))
	if data_start <= 16 or data_start >= d.size() or (data_start - 16) % 16 != 0:
		error = "bad key-table extent %d" % data_start
		return false
	var npairs := int((data_start - 16) / 16)

	var keys := PackedInt64Array()
	var ptrs := PackedInt64Array()
	keys.resize(npairs)
	ptrs.resize(npairs)
	var rec_base := 0x7FFFFFFFFFFFFFFF
	for i in range(npairs):
		var o := 16 + 16 * i
		keys[i] = d.decode_u64(o)
		var p := int(d.decode_u64(o + 8))
		ptrs[i] = p
		if p < rec_base:
			rec_base = p

	# The record array tiles the blob area exactly: each record's dataOffset is
	# the previous one's end. That contiguity IS the terminator — there is no
	# count — so a record that does not continue the tiling ends the array.
	var rp := rec_base
	var expect := data_start
	while rp + 24 <= d.size():
		var off := int(d.decode_u64(rp))
		var ch := int(d.decode_u64(rp + 8))
		var sz := int(d.decode_u64(rp + 16))
		if off != expect or off + sz > rec_base:
			break
		records.append({"offset": off, "content_hash": ch, "size": sz,
			"params": null})
		expect = off + sz
		rp += 24
	if records.is_empty():
		error = "no records tile the blob area"
		return false
	var last: Dictionary = records[records.size() - 1]
	var gap: int = rec_base - (int(last["offset"]) + int(last["size"]))
	if gap < 0 or gap > 16:
		error = "record array does not tile the blob area (gap %d)" % gap
		return false

	for i in range(npairs):
		var ri := int((ptrs[i] - rec_base) / 24)
		if ri < 0 or ri >= records.size() or (ptrs[i] - rec_base) % 24 != 0:
			continue
		key_to_record[keys[i]] = ri
	return true


# Parsed lazily: a depot holds thousands of blobs and a map touches a fraction
# of them. Returns [] for a blob that does not parse, and says so in `error`.
func params(rec_index: int, d: PackedByteArray) -> Array:
	if rec_index < 0 or rec_index >= records.size():
		return []
	var rec: Dictionary = records[rec_index]
	if rec["params"] != null:
		return rec["params"]
	var out := _parse_blob(d, int(rec["offset"]), int(rec["size"]))
	rec["params"] = out
	return out


# One blob: u32 count, then `count` packed entries with NO alignment.
#
#   u64 parameterHash, u32 typeHash, u16 flags, u16 nameHashHi
#   texture (typeHash == TH_TEXTURE): u8 n, then n x 32 bytes of
#       {root-instance guid A, FILE guid B}. B is the one that resolves through
#       the partition index to an asset name.
#   inline: u32 n, then n == 1 ? scalar : 16*(n-1) + scalar
#       (HLSL cbuffer array packing — 16-byte element stride, last element
#        unpadded; verified against a float3[8] measuring 124 bytes)
func _parse_blob(d: PackedByteArray, off: int, size: int) -> Array:
	var end := off + size
	if off < 0 or end > d.size() or size < 4:
		error = "blob outside the file"
		return []
	var cnt := int(d.decode_u32(off))
	var pos := off + 4
	var out: Array = []
	for i in range(cnt):
		if pos + 17 > end:
			error = "header overrun at entry %d" % i
			return []
		var ph := int(d.decode_u64(pos))
		var th := int(d.decode_u32(pos + 8))
		var fl := int(d.decode_u16(pos + 12))
		var nh := int(d.decode_u16(pos + 14))
		pos += 16
		var p := {"param_hash": ph, "type_hash": th, "flags": fl,
			"name_hi": nh, "name32": name32(ph, nh), "refs": [], "raw": null}
		if th != TH_TEXTURE:
			var n := int(d.decode_u32(pos))
			pos += 4
			if not SCALAR_SIZE.has(th):
				# Hard error on purpose: entries are packed with no alignment,
				# so an unknown size does not lose one parameter, it
				# desynchronises everything after it.
				error = "unknown inline type hash %08x at entry %d" % [th, i]
				return []
			var s: int = SCALAR_SIZE[th]
			var vlen: int = s if n <= 1 else 16 * (n - 1) + s
			if pos + vlen > end:
				error = "value overrun at entry %d" % i
				return []
			p["count"] = n
			p["raw"] = d.slice(pos, pos + vlen)
			pos += vlen
		else:
			var n2 := int(d[pos])
			pos += 1
			for _k in range(n2):
				if pos + 32 > end:
					error = "texture ref overrun at entry %d" % i
					return []
				p["refs"].append([guid_str(d.slice(pos, pos + 16)),
					guid_str(d.slice(pos + 16, pos + 32))])
				pos += 32
			p["count"] = n2
		out.append(p)
	if pos != end:
		# The blob must be consumed EXACTLY. Anything else means the entry
		# stream desynchronised, and the params read so far are not trustworthy
		# even though they look plausible.
		error = "end mismatch: consumed %d of %d" % [pos - off, size]
		return []
	return out


# -> {slot name: file guid} for one state key, plus "constants" by name32.
# The file guid (B of the pair) is what the partition index resolves to a name.
func textures_for(state_key: int, d: PackedByteArray) -> Dictionary:
	if not key_to_record.has(state_key):
		return {}
	var out := {}
	var consts := {}
	for p in params(int(key_to_record[state_key]), d):
		var pd: Dictionary = p
		var n32: int = int(pd["name32"])
		if int(pd["type_hash"]) == TH_TEXTURE:
			if (pd["refs"] as Array).is_empty():
				continue
			var pair: Array = (pd["refs"] as Array)[0]
			var slot: String = str(SLOT_NAME.get(n32, "nh_%08x" % n32))
			out[slot] = pair[1]              # the FILE guid
		else:
			consts[n32] = pd["raw"]
	out["constants"] = consts
	return out
