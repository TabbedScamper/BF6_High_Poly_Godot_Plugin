@tool
extends RefCounted
class_name BF6Decals

# TerrainDecals (RES type 0x15E1F32E) — the road network, in GDScript.
#
# One resource per level: the pre-tessellated compiled output of the
# TerrainFillDecalData / TerrainQuadDecalData authoring instances. The spline
# control points are stripped from the runtime EBX, so this compiled geometry is
# the ONLY source for road, kerb, crosswalk, lane-marking and manhole layout —
# without it a rebuilt map is bare dirt where the streets should be.
#
# Ported from tools/bf6_decals.py, which carries three corrections to the
# Frostbite reference's dumbo-only layout. All three are here, because all three
# were found by a map that parsed cleanly right up until it did not:
#
#   1. The reference's ~0x300 anchor window is too small; some pads run far
#      longer, so the window is 0x8000 and the FirstIndex chain invariant CHOOSES
#      among candidate anchors rather than merely checking the result afterwards.
#   2. Seven of 23 maps carry a 12-byte non-zero blob at the record-stream start
#      where dumbo has zeros, so reading a propSize there gives garbage. Record 0
#      is pinned by the invariant FirstIndex == 0 instead.
#   3. "VB starts at the record-stream end rounded up to 4 KiB" holds on dumbo
#      and fails on most maps. The trailing `u32 4, u32 0` landmark after the
#      vertex buffer is reliable, and using it took vertex-in-AABB from 18% to
#      66%.
#
# GEOMETRY NOTE, and the reason this needs the heightfield: decal vertices carry
# world X and Z but NO Y. They are draped on the terrain, and the engine draws
# them blended with depth-write off. We cannot, so the consumer samples the
# height grid and lifts by a small bias.

const RES_TYPE := 0x15E1F32E

# Texture-slot property name hashes (u64), verified on mp_dumbo.
const SLOT_CV := 0x399AC0336ACFE03C     # basecolor
const SLOT_NHS := 0x567A9BC35CCBB1B2    # normal / height / smoothness
const SLOT_AO := 0x3A411B3E209FC9E2     # ambient occlusion
const SLOT_OP := 0x3810287D4CE70B49     # coverage / opacity — MARKINGS LIVE ONLY HERE

const TYPE_RESOURCE := 0xCC84D53D       # 33 B: u8 count + 16 B pair + 16 B guid @ +17
const TYPE_FLOAT := 0x14A0B1C1          # u32 count + count * 4
const TYPE_VEC3 := 0x25F81AF1           # u32 count + count * 12

const VTX_STRIDE := 32
const ANCHOR_WINDOW := 0x8000

var data := PackedByteArray()
var slots: Array = []                   # slot index -> 16-byte guid, or empty
var records: Array = []                 # [{first_index, tri_count, tiling0, tiling1,
                                        #   aabb_min, aabb_max, asset_slot, vb_off,
                                        #   vb_size, props}]
var record_count := 0
var vb_start := 0
var vb_size := 0
var chain_ok := true
var truncated_at := -1
var format := ""                        # "fixed-header" or "props-first"
var anchor_ok := false
var vb_from_anchor := false
var total_tris := 0
var error := ""


# The level's decal resource, by RES type rather than by name. The name is
# `<level path>/<level>_terraindecals` on the maps sampled, but the TYPE is what
# the format guarantees, and a map that spells its name differently would
# otherwise silently ship no roads at all.
static func find_res(src: BF6Source, level: String) -> String:
	var low := level.to_lower()
	var fallback := ""
	for rn in src.res.keys():
		var e = src.res[rn]
		if int(e[5]) != RES_TYPE:
			continue
		var n := str(rn)
		if n.to_lower().contains(low):
			return n
		if fallback == "":
			fallback = n
	return fallback


func parse(d: PackedByteArray) -> bool:
	data = d
	slots.clear()
	records.clear()
	error = ""
	if d.size() < 0x18:
		error = "too small (%d bytes)" % d.size()
		return false
	var slot_count := int(d.decode_u32(16))
	if slot_count <= 0 or slot_count > 4096:
		error = "slotCount %d outside the guard range" % slot_count
		return false
	var p := 0x14
	for i in range(slot_count):
		if p + 16 > d.size():
			error = "slot table runs past the end"
			return false
		var g := d.slice(p, p + 16)
		slots.append(PackedByteArray() if _all_zero(g) else g)
		p += 16
	if p + 4 > d.size():
		error = "no record count"
		return false
	record_count = int(d.decode_u32(p))
	p += 4

	# TWO RECORD FRAMINGS SHIP, and the map does not say which (MAP-*.md, task
	# #98). The FIXED-HEADER family (badlands, plaza, and by their headers
	# outskirts and golmud) leads each record with a 16-byte id and holds every
	# geometry field at a constant offset, with the property stream LAST. The
	# PROPS-FIRST family (dumbo, tungsten, aftermath, and with quirks firestorm
	# and contaminated) is the TERRAIN.md 10.2 layout this file always parsed.
	# The fixed walk is tried first because it is cheap and self-checking: on a
	# props-first map its chain collapses on record 0 and the walk is rejected.
	var fixed_recs := _parse_fixed(p)
	if fixed_recs >= 0:
		format = "fixed-header"
		p = fixed_recs
	else:
		format = "props-first"
		records.clear()
		chain_ok = true
		truncated_at = -1
		# Record 0 is pinned by an invariant rather than by its header: its
		# FirstIndex is 0 by definition. From record 1 on, the chain carries the
		# frame — each record's FirstIndex must be the previous one's plus its
		# triangle count times three, and that is what disambiguates the stray
		# 1.0/1.0/0 patterns inside long pads and property payloads.
		var expect_first := 0
		for i in range(record_count):
			var got := _record(p, expect_first)
			if got.is_empty():
				# KEEP WHAT PARSED. A map's road network is worth having
				# partially; several maps truncate partway and still yield
				# thousands of good records each, and raising here discards
				# all of them for one bad one.
				truncated_at = i
				break
			var rec: Dictionary = got["rec"]
			p = int(got["next"])
			if int(rec["first_index"]) != expect_first:
				chain_ok = false
			expect_first = int(rec["first_index"]) + int(rec["tri_count"]) * 3
			records.append(rec)

	var span := 0
	for r in records:
		span = maxi(span, int(r["vb_off"]) + int(r["vb_size"]))
		total_tris += int(r["tri_count"])
	vb_size = span
	vb_start = (p + 0xFFF) & ~0xFFF
	if span > 0:
		var cand := _find_vb_anchor(span, p)
		if cand >= 0:
			vb_start = cand
			vb_from_anchor = true
	var a := vb_start + span
	if a + 8 <= d.size():
		anchor_ok = int(d.decode_u32(a)) == 4 and int(d.decode_u32(a + 4)) == 0
	return not records.is_empty()


# ---------------------------------------------------------------------------
# THE FIXED-HEADER RECORD FAMILY (measured on badlands 628/628 and plaza
# 485/485, docs/MAP-BADLANDS.md and MAP-PLAZA.md):
#
#   +0x00  16 B  record id (a material-group hash on badlands, the decal-asset
#                GUID on plaza — where it joins the slot table by VALUE)
#   +0x20  u32   FirstIndex        +0x24  u32  TriCount
#   +0x2C  f32   Tiling0           +0x30  f32  Tiling1
#   +0x40  f32x3 AabbMin           +0x50  f32x3 AabbMax
#   +0x90  the anchor row (f32 1.0, +0x14 f32 1.0, +0x18 u64 0)
#   +0x98  u32 slot   +0x9C u32 vbOff   +0xA0 u32 vbSize
#   +0xB0  u32 propSize, then the same 10.3 property grammar; next record at
#          +0xB4 + propSize
#
# Walked WITHOUT scanning — every field at a constant offset — and validated by
# the same FirstIndex chain as the other family. Rejection is the detector: a
# props-first map read this way breaks the chain immediately, and a walk below
# 90% chain integrity or overrunning the stream returns -1 so the caller falls
# back. Returns the stream-end offset on success.
# ---------------------------------------------------------------------------
const FIXED_GEO := 0xB0

func _parse_fixed(start: int) -> int:
	var p := start
	var out: Array = []
	var expect_first := 0
	var chain_hits := 0
	# Plaza joins records to the slot table by GUID value; build the index once.
	var slot_by_guid := {}
	for i in range(slots.size()):
		var g: PackedByteArray = slots[i]
		if not g.is_empty():
			slot_by_guid[g.hex_encode()] = i
	for i in range(record_count):
		if p + FIXED_GEO + 4 > data.size():
			return -1
		var first := int(data.decode_u32(p + 0x20))
		var tri := int(data.decode_u32(p + 0x24))
		var psize := int(data.decode_u32(p + 0xB0))
		if tri <= 0 or tri > 2000000 or psize < 0 or psize > 0x8000 \
				or p + FIXED_GEO + 4 + psize > data.size():
			return -1
		if first == expect_first:
			chain_hits += 1
		elif i * 10 > record_count and chain_hits * 10 < i * 9:
			return -1                  # the chain is not holding: wrong family
		var slot := int(data.decode_u32(p + 0x98))
		if slot >= slots.size():
			# 65535 sentinel or the plaza value-join: resolve via the record id
			slot = int(slot_by_guid.get(data.slice(p, p + 16).hex_encode(), slot))
		var props := {}
		if psize > 0:
			_props(p + 0xB0 + 8, p + 0xB0 + 4 + psize, props)
		out.append({
			"first_index": first,
			"tri_count": tri,
			"tiling0": data.decode_float(p + 0x2C),
			"tiling1": data.decode_float(p + 0x30),
			"aabb_min": Vector3(data.decode_float(p + 0x40),
				data.decode_float(p + 0x44), data.decode_float(p + 0x48)),
			"aabb_max": Vector3(data.decode_float(p + 0x50),
				data.decode_float(p + 0x54), data.decode_float(p + 0x58)),
			"asset_slot": slot,
			"vb_off": int(data.decode_u32(p + 0x9C)),
			"vb_size": int(data.decode_u32(p + 0xA0)),
			"props": props,
			"prop_size": psize,
		})
		expect_first = first + tri * 3
		p += FIXED_GEO + 4 + psize
	if out.size() < record_count or chain_hits * 10 < out.size() * 9:
		return -1
	records = out
	chain_ok = chain_hits == out.size()
	return p


# Scan the tail for the `u32 4, u32 0` VB-end landmark and return the implied VB
# start (landmark - span), or -1.
func _find_vb_anchor(span: int, stream_end: int) -> int:
	var page := (stream_end + 0xFFF) & ~0xFFF
	var q: int = maxi(0, page + span - 0x20000)
	var end: int = mini(data.size() - 8, page + span + 0x200000)
	while q <= end:
		if int(data.decode_u32(q)) == 4 and int(data.decode_u32(q + 4)) == 0:
			var cand := q - span
			if cand >= stream_end:
				return cand
		q += 4
	return -1


# One record: [u32 propSize][props][pad][0x90 tail], the tail found by anchor.
# Returns {} on failure, else {rec, next}.
func _record(p: int, expect_first: int) -> Dictionary:
	var prop_off := p
	if prop_off + 4 > data.size():
		return {}
	var prop_size := int(data.decode_u32(p))
	var prop_end := prop_off + 4 + prop_size
	var props := {}
	if prop_size > data.size() or prop_end > data.size():
		# The unreadable prefix (see the record-0 note): fall back to scanning
		# from the record start and let the FirstIndex invariant find the tail.
		prop_end = prop_off
		prop_size = 0
	elif prop_size > 0:
		_props(prop_off + 8, prop_end, props)
	var m := _find_anchor(prop_end, expect_first)
	if m < 0:
		return {}
	var t := m - 0x70
	if t < 0 or m + 0x20 > data.size():
		return {}
	return {"rec": {
			"first_index": int(data.decode_u32(t)),
			"tri_count": int(data.decode_u32(t + 4)),
			"tiling0": data.decode_float(t + 0x0C),
			"tiling1": data.decode_float(t + 0x10),
			"aabb_min": Vector3(data.decode_float(t + 0x20),
				data.decode_float(t + 0x24), data.decode_float(t + 0x28)),
			"aabb_max": Vector3(data.decode_float(t + 0x30),
				data.decode_float(t + 0x34), data.decode_float(t + 0x38)),
			"asset_slot": int(data.decode_u32(m + 8)),
			"vb_off": int(data.decode_u32(m + 12)),
			"vb_size": int(data.decode_u32(m + 16)),
			"props": props,
			"prop_size": prop_size,
		}, "next": m + 0x20}


# Byte offset M of the record tail, or -1. Anchor shape (TERRAIN.md 10.2):
# f32 1.0 @ M, f32 1.0 @ M+0x14, u64 0 @ M+0x18. When the previous record's
# FirstIndex says what this one's must be, PREFER the candidate that matches —
# a false anchor almost never lands on the exact expected value, so this locks
# the frame instead of drifting.
#
# STEPPED ONE BYTE, not four: MAP-FIRESTORM.md measured odd propSizes, which
# put every later tail on an unaligned offset a 4-byte scan can never land on.
#
# AND A CHAIN-LOCKED SECOND PASS: on MAP-CONTAMINATED.md the transform region
# stops being identity-shaped at record 336 of 1053, so the 1.0/1.0 pattern
# simply is not there. When the anchor pass finds nothing and the chain says
# what FirstIndex must be, the tail is found by that value directly, sanity-
# checked by TriCount and both tilings — 1053/1053 on the map that proved it.
func _find_anchor(prop_end: int, expect_first: int) -> int:
	var lim: int = mini(prop_end + ANCHOR_WINDOW, data.size() - 0x20)
	var first_any := -1
	var q := prop_end
	while q <= lim:
		if data.decode_float(q) == 1.0 and data.decode_float(q + 0x14) == 1.0 \
				and int(data.decode_u64(q + 0x18)) == 0:
			var t := q - 0x70
			if t >= 0:
				if first_any < 0:
					first_any = q
				if expect_first < 0:
					return q
				if int(data.decode_u32(t)) == expect_first:
					return q
		q += 1
	if expect_first >= 0:
		q = prop_end
		while q <= lim:
			if int(data.decode_u32(q)) == expect_first:
				var tri := int(data.decode_u32(q + 4))
				var t0 := absf(data.decode_float(q + 0x0C))
				var t1 := absf(data.decode_float(q + 0x10))
				if tri > 0 and tri < 2000000 \
						and t0 > 0.001 and t0 < 10000.0 \
						and t1 > 0.001 and t1 < 10000.0:
					return q + 0x70    # q IS the tail t; M sits 0x70 past it
			q += 1
	return first_any


func _props(p: int, end: int, out: Dictionary) -> void:
	while p + 16 <= end:
		var name := int(data.decode_u64(p))
		var tid := int(data.decode_u32(p + 8))
		p += 16
		match tid:
			TYPE_RESOURCE:
				if p + 33 > end:
					return
				out[name] = ["tex", data.slice(p + 17, p + 33)]
				p += 33
			TYPE_FLOAT:
				var n := int(data.decode_u32(p))
				p += 4
				if n < 0 or p + n * 4 > end:
					return
				var fs := PackedFloat32Array()
				for k in range(n):
					fs.push_back(data.decode_float(p + k * 4))
				out[name] = ["f32", fs]
				p += n * 4
			TYPE_VEC3:
				var nv := int(data.decode_u32(p))
				p += 4
				if nv < 0 or p + nv * 12 > end:
					return
				var vs: Array = []
				for k in range(nv):
					vs.append(Vector3(data.decode_float(p + k * 12),
						data.decode_float(p + k * 12 + 4),
						data.decode_float(p + k * 12 + 8)))
				out[name] = ["vec3", vs]
				p += nv * 12
			_:
				return          # unknown size -> the walk ends (documented)


# One record's vertices as [x, z, u, v, r, g, b, a] — stride 8 — in a flat
# float array.
#
# NO Y: drape on the heightfield at (x, z).
#
# THE UVS ARE FULL f32s AT +0x10 AND +0x14, decoded 2026-08-10. The earlier
# reading — "f16 v0/v1 at +0x12/+0x16, divide by 1.875" — was the HIGH HALVES
# of these very floats read as halves: f32 1.0 is 0x3F800000, and its top 16
# bits decode as f16 to exactly 1.875. That one bit-pattern accident invented
# the 1.875 constant, the "u overflows half precision" myth, and the whole
# world-projection fallback. Nothing overflows. u (+0x10) runs 0..1 ACROSS the
# ribbon (x Tiling1 metres); v (+0x14) is tessellated arc length ALONG the
# spline, already divided by Tiling0 — continuous and monotonic around curves,
# proven on a curved stripe whose frame rotates 17.4 degrees with
# chord/(dV*t0) = 1.0000 at every ring. Emit UV = (v, u).
#
# +0x18 is f16x4 RGBA vertex colour; alpha carries the mud edge fades (18.3%
# of aftermath's verts), so a consumer multiplies it in.
#
# PLANAR records are the one exception: some fills (all with t0 = t1 = 10)
# store u = world X and v = world Z exactly; those tile as (z/t0, x/t1).
# Detect with is_planar().
func vertices(rec: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var base := vb_start + int(rec["vb_off"])
	var n := int(rec["vb_size"]) / VTX_STRIDE
	for i in range(n):
		var o := base + i * VTX_STRIDE
		if o + VTX_STRIDE > data.size():
			break
		out.push_back(data.decode_float(o))            # world X
		out.push_back(data.decode_float(o + 4))        # world Z
		out.push_back(data.decode_float(o + 0x10))     # u: across, 0..1
		out.push_back(data.decode_float(o + 0x14))     # v: along, arc/Tiling0
		out.push_back(data.decode_half(o + 0x18))      # R
		out.push_back(data.decode_half(o + 0x1A))      # G
		out.push_back(data.decode_half(o + 0x1C))      # B
		out.push_back(data.decode_half(o + 0x1E))      # A - edge fade
	return out


# A planar record stores u = world X and v = world Z verbatim (R^2 = 1.00000
# on every one measured; 27 of dumbo's 433, 16 of aftermath's 255, all with
# Tiling0 = Tiling1 = 10). Everything else authors u across / v along.
static func is_planar(vs: PackedFloat32Array) -> bool:
	var n := vs.size() / 8
	if n == 0:
		return false
	for i in range(mini(n, 12)):
		if absf(vs[i * 8 + 2] - vs[i * 8]) >= 0.5 \
				or absf(vs[i * 8 + 3] - vs[i * 8 + 1]) >= 0.5:
			return false
	return true


# The decal asset GUID for a record, or an empty array.
#
# Prop-less records are POSITIONAL rather than broken: AssetSlot is the terrain
# layer-graph layer index (slot 2 = L02 cobblestone, slot 8 = L08 concretetile)
# and the surface is that layer's own material. They are real road either way,
# so a consumer should give them a neutral material rather than drop them.
func slot_guid(rec: Dictionary) -> PackedByteArray:
	var i := int(rec["asset_slot"])
	if i >= 0 and i < slots.size():
		return slots[i]
	return PackedByteArray()


# 16 raw bytes -> the dashed form the partition index is keyed by. Matches
# BF6Source._efix_guid exactly; the two MUST agree or every texture misses.
static func guid_str(b: PackedByteArray) -> String:
	if b.size() < 16:
		return ""
	return "%08x-%04x-%04x-%s-%s" % [b.decode_u32(0), b.decode_u16(4),
		b.decode_u16(6), b.slice(8, 10).hex_encode(), b.slice(10, 16).hex_encode()]


static func _all_zero(b: PackedByteArray) -> bool:
	for x in b:
		if x != 0:
			return false
	return true


func stats() -> Dictionary:
	return {"records": records.size(), "declared": record_count,
		"slots": slots.size(), "triangles": total_tris, "format": format,
		"chain_ok": chain_ok, "anchor_ok": anchor_ok,
		"vb_from_anchor": vb_from_anchor, "truncated_at": truncated_at,
		"vb_start": vb_start, "vb_size": vb_size}
