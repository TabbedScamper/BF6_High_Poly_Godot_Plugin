@tool
extends RefCounted
class_name BF6Bundle

# Bundles: the segment list, and the asset table naming what is in them.
# Ported from fb_bundle.py (CONTAINERS.md 5.5, 5.6, 6).
#
#     toc bundle record  ->  5.5 segment list   (which CAS, where, how big)
#     segment 0          ->  6   asset tables   (which name is which segment)
#     segment i+1        ->  the asset itself

const F_FNVFILE := 0x80

const SALT := 0x7065636E                # "pecn", XORed over the bundle magic
const MAGIC_STANDARD := 0xED1CEDB8
const MAGIC_KELVIN := 0xC3889333
const MAGIC_ENCRYPTED := 0xC3E5D5C3

static var last_error := ""


static func _be32(d: PackedByteArray, at: int) -> int:
	return (int(d[at]) << 24) | (int(d[at + 1]) << 16) \
			| (int(d[at + 2]) << 8) | int(d[at + 3])


static func _be16(d: PackedByteArray, at: int) -> int:
	return (int(d[at]) << 8) | int(d[at + 1])


# 5.5: the per-bundle blob -> Array of [chunk_id, cas_ix, offset, size]
static func read_segments(body: PackedByteArray, blob_off: int) -> Array:
	var flag_off := _be32(body, blob_off + 8)
	var flag_size := _be32(body, blob_off + 12)
	var data_off := _be32(body, blob_off + 16)
	var pos := blob_off + 32
	# 5.5: DataCount is conditional. If the data begins immediately after a
	# 32-byte header then DataCount == FlagSize; otherwise a 9th u32 carries
	# it. Every BF6 blob observed takes the 9-u32 form, but the cheap branch is
	# kept because the spec defines both and guessing costs nothing.
	var count := 0
	if blob_off + data_off == pos:
		count = flag_size
	else:
		count = _be32(body, pos)
		pos += 4

	var segs: Array = []
	var p := blob_off + data_off
	var last_id := -1
	var last_cas := -1
	for i in range(count):
		var fl := 0
		if i < flag_size:
			fl = int(body[blob_off + flag_off + i])
		if fl != 0:
			# 5.6: width chosen by the FnvFile bit
			if (fl & F_FNVFILE) != 0:
				last_id = _be32(body, p + 2)
				last_cas = _be16(body, p + 6)
				p += 8
			else:
				last_id = int(body[p + 2])
				last_cas = int(body[p + 3])
				p += 4
		elif last_id < 0:
			last_error = "segment %d reuses a CasFileId before one was set" % i
			return []
		var off := _be32(body, p)
		var size := _be32(body, p + 4)
		p += 8
		segs.append([last_id, last_cas, off, size])
	return segs


# 6: the index of a bundle's EBX, RES and chunk assets.
class Payload extends RefCounted:
	var raw := PackedByteArray()
	var magic := 0
	var little := false
	var total_count := 0
	var ebx: Array = []
	var res: Array = []
	var chunks: Array = []
	var strings_off := 0
	var ok := false
	var error := ""

	func _u32(at: int) -> int:
		return raw.decode_u32(at) if little else BF6Bundle._be32(raw, at)

	func _s32(at: int) -> int:
		var v := _u32(at)
		return v - 0x100000000 if v >= 0x80000000 else v

	func _u64(at: int) -> int:
		if little:
			return raw.decode_u64(at)
		return (BF6Bundle._be32(raw, at) << 32) | BF6Bundle._be32(raw, at + 4)

	func _str(name_off: int) -> String:
		# 6.4 describes these as size-prefixed with nameOffset pointing at the
		# size field. In BF6 they are PLAIN NUL-TERMINATED and nameOffset
		# points straight at the text.
		var at := strings_off + name_off
		if at < 0 or at >= raw.size():
			error = "string offset %d is outside the %d-byte payload" % [at, raw.size()]
			return ""
		var end := at
		while end < raw.size() and raw[end] != 0:
			end += 1
		return raw.slice(at, end).get_string_from_utf8()

	func parse(d: PackedByteArray) -> bool:
		raw = d
		if d.size() < 32:
			error = "payload too short"
			return false
		# 6.1: the magic is XOR-salted and its endianness is not declared —
		# read big-endian, and if the de-salted value is not one we know, the
		# body is little-endian. Everything after the magic follows whichever
		# way this comes out, so getting it wrong scrambles every count.
		var be := BF6Bundle._be32(d, 4) ^ BF6Bundle.SALT
		var known := [BF6Bundle.MAGIC_STANDARD, BF6Bundle.MAGIC_KELVIN,
				BF6Bundle.MAGIC_ENCRYPTED]
		if known.has(be):
			magic = be
			little = false
		else:
			var le := d.decode_u32(4) ^ BF6Bundle.SALT
			if not known.has(le):
				error = "bundle magic %08X/%08X is not a known value" % [be, le]
				return false
			magic = le
			little = true
		if magic == BF6Bundle.MAGIC_ENCRYPTED:
			error = "encrypted bundle; no decryption is defined"
			return false

		total_count = _s32(8)
		var ebx_count := _s32(12)
		var res_count := _s32(16)
		var chunk_count := _s32(20)
		# EVERY DECLARED OFFSET IS RELATIVE TO BYTE 4, not to the payload start
		# — i.e. to just after the TotalSize field. The spec calls
		# StringsOffset "absolute offset within the payload", which is four
		# bytes out, and the resulting names are garbage in a way that looks
		# like a table-walk bug rather than an origin bug.
		strings_off = _s32(24) + 4

		# 6.1: Standard carries an extra u32 at +0x20, so its header is 0x24.
		var pos := 0x24 if magic == BF6Bundle.MAGIC_STANDARD else 0x20
		# 6.2: Standard only — TotalCount x 20-byte SHA-1s, in asset order.
		if magic == BF6Bundle.MAGIC_STANDARD:
			pos += 20 * total_count

		for _i in range(ebx_count):
			ebx.append({"name": _str(_u32(pos)), "size": _u32(pos + 4)})
			pos += 8

		# 6.3 RES: four parallel arrays back to back, indexed jointly
		var base := pos
		var n := res_count
		var types_at := base + n * 8
		var meta_at := types_at + n * 4
		var rid_at := meta_at + n * 0x10
		for i in range(n):
			res.append({
				"name": _str(_u32(base + i * 8)),
				"size": _u32(base + i * 8 + 4),
				"type": _u32(types_at + i * 4),
				"meta": raw.slice(meta_at + i * 0x10, meta_at + (i + 1) * 0x10),
				"rid": _u64(rid_at + i * 8),
			})
		pos = rid_at + n * 8

		for _i in range(chunk_count):
			chunks.append({
				"id": raw.slice(pos, pos + 16).hex_encode(),   # plain LE guid
				"logical_offset": _u32(pos + 16),
				"logical_size": _u32(pos + 20),
			})
			pos += 24
		ok = true
		return true

	# Every asset in bundle order with its segment index. Entry i of the
	# combined EBX+RES+chunk sequence is segment i+1, because segment 0 is this
	# metadata payload.
	func assets() -> Array:
		var out: Array = []
		var i := 1
		for e in ebx:
			out.append(["ebx", e, i]); i += 1
		for r in res:
			out.append(["res", r, i]); i += 1
		for c in chunks:
			out.append(["chunk", c, i]); i += 1
		return out
