@tool
extends RefCounted
class_name BF6Toc

# SuperBundle TOC: the index of everything in a Battlefield 6 archive.
# Ported from fb_toc.py (CONTAINERS.md 5).
#
# Two things about this format bite immediately:
#
#   EVERYTHING IS BIG-ENDIAN, unlike layout.toc next to it, which is not.
#   EVERY OFFSET IS RELATIVE TO BYTE 556, the end of the DICE header, so the
#   payload is sliced off once and all offsets index straight into it.
#
# BF6 uses "merged" TOCs: the .toc carries the whole index — bundle metadata,
# the loose-chunk map, and per-bundle CAS segment lists — and there are no
# separate .sb files.

const INLINE := 1 << 30
const IN_MEMORY := 1 << 31
const SIZE_MASK := 0x3FFFFFFF

const F_FILE := 0x01
const F_FNVFILE := 0x80

var source_path := ""
var body := PackedByteArray()
var ok := false
var error := ""

var bundle_hash_keys_off := 0
var bundle_value_off := 0
var bundle_count := 0
var chunk_hash_keys_off := 0
var chunk_value_off := 0
var chunk_count := 0
var names_off := 0
var data_off := 0
var data_count := 0
var flags := 0

var base_bundles := false
var base_chunks := false
var compressed_names := false

var name_count := 0
var huff_nodes := 0
var huff_off := 0

var names := {}             # start BIT offset -> string
var bundles: Array = []     # {name, offset, size, inline, in_memory}
var chunks: Array = []      # {guid, flags, data_pos}
var _by_guid := {}


static func _be32(d: PackedByteArray, at: int) -> int:
	return (int(d[at]) << 24) | (int(d[at + 1]) << 16) \
			| (int(d[at + 2]) << 8) | int(d[at + 3])


static func _be16(d: PackedByteArray, at: int) -> int:
	return (int(d[at]) << 8) | int(d[at + 1])


static func _be64(d: PackedByteArray, at: int) -> int:
	return (_be32(d, at) << 32) | _be32(d, at + 4)


func load_from(path: String) -> bool:
	source_path = path
	var raw := FileAccess.get_file_as_bytes(path)
	if raw.is_empty():
		error = "cannot read %s" % path
		return false
	return parse(raw)


func parse(raw: PackedByteArray) -> bool:
	body = BF6Container.strip_dice_header(raw)
	if body.size() < 48:
		error = "too short to hold an SbTocHeader"
		return false
	bundle_hash_keys_off = _be32(body, 0)
	bundle_value_off = _be32(body, 4)
	bundle_count = _be32(body, 8)
	chunk_hash_keys_off = _be32(body, 12)
	chunk_value_off = _be32(body, 16)
	chunk_count = _be32(body, 20)
	var unk1 := _be32(body, 24)
	var unk2 := _be32(body, 28)
	names_off = _be32(body, 32)
	data_off = _be32(body, 36)
	data_count = _be32(body, 40)
	flags = _be32(body, 44)

	base_bundles = (flags & 0x01) != 0
	base_chunks = (flags & 0x02) != 0
	compressed_names = (flags & 0x04) != 0

	# 5.1: UnkOffset1 == UnkOffset2 == DataOffset in every BF6 TOC observed,
	# and the spec says a reader may reject files where they differ. Rejecting
	# is right: their independent meaning is unconfirmed, so a file that
	# disagrees is one this reader has never seen and would be guessing at.
	if unk1 != data_off or unk2 != data_off:
		error = "UnkOffset1/2 (0x%X/0x%X) differ from DataOffset (0x%X)" \
				% [unk1, unk2, data_off]
		return false

	if compressed_names:
		if body.size() < 60:
			error = "CompressedNames set but the header is short"
			return false
		name_count = _be32(body, 0x30)
		huff_nodes = _be32(body, 0x34)
		huff_off = _be32(body, 0x38)
		if not _huffman_names():
			return false

	if not _read_bundles():
		return false
	_read_chunks()
	ok = true
	return true


# 5.2: i32 BE consumed in PAIRS; the last pair built is the root.
func _huffman_names() -> bool:
	# A TOC CAN SET CompressedNames AND CARRY NO NAMES. The HRES detail
	# packages under Update/ do exactly that: tens of thousands of chunks and
	# zero bundles, so an empty tree. Treating that as corruption rejects a
	# file the game mounts happily.
	if huff_nodes == 0 or bundle_count == 0:
		return true
	if huff_nodes % 2 != 0:
		error = "HuffmanTreeNodeCount %d is odd" % huff_nodes
		return false
	var nodes: Array = []
	for i in range(0, huff_nodes, 2):
		var a := _be32(body, huff_off + i * 4)
		var b := _be32(body, huff_off + (i + 1) * 4)
		# stored as signed
		if a >= 0x80000000: a -= 0x100000000
		if b >= 0x80000000: b -= 0x100000000
		nodes.append([a, b])
	var root := nodes.size() - 1
	var total_bits := name_count * 32
	var pos := 0
	for _n in range(bundle_count):
		if pos >= total_bits:
			break
		var start := pos
		var s := ""
		while true:
			var node := root
			var sym := 0
			while true:
				# consecutive 32-bit BE words, bits LSB-first within each word
				var w := _be32(body, names_off + (pos >> 5) * 4)
				var bit := (w >> (pos & 31)) & 1
				pos += 1
				var v: int = nodes[node][bit]
				if v < 0:
					sym = -v - 1
					break
				node = v
			if sym == 0:                       # NUL terminates the string
				break
			s += char(sym)
		names[start] = s
	return true


func name_at(off: int) -> String:
	if compressed_names:
		return str(names.get(off, ""))
	var at := names_off + off
	var end := body.find(0, at)
	if end < 0:
		end = body.size()
	return body.slice(at, end).get_string_from_utf8()


func _read_bundles() -> bool:
	for i in range(bundle_count):
		var o := bundle_value_off + i * 16
		if o + 16 > body.size():
			error = "bundle map runs past the end of the toc"
			return false
		var name_off := _be32(body, o)
		var size := _be32(body, o + 4)
		var offset := _be64(body, o + 8)
		# removed-bundle sentinel
		if size == 0xFFFFFFFF and offset == -1:
			continue
		bundles.append({
			"name": name_at(name_off),
			"offset": offset,
			"size": size & SIZE_MASK,
			"inline": (size & INLINE) != 0,
			"in_memory": (size & IN_MEMORY) != 0,
		})
	return true


func _read_chunks() -> void:
	for i in range(chunk_count):
		var o := chunk_value_off + i * 20
		if o + 20 > body.size():
			break
		var value := _be32(body, o + 16)
		if value == 0xFFFFFFFF:
			continue                            # removed-chunk sentinel
		var fl := (value >> 24) & 0xFF
		if (fl & (F_FILE | F_FNVFILE)) == 0:
			continue                            # no CAS record; nothing to read
		# 5.4: the chunk map stores the guid REVERSED
		var g := body.slice(o, o + 16)
		g.reverse()
		chunks.append({
			"guid": g.hex_encode(),
			"flags": fl,
			"data_pos": value & 0x00FFFFFF,
		})


# 5.4: where a chunk's FULL data lives -> [install_chunk_id, cas_index, off, size]
#
# THIS IS NOT THE SAME DATA AS THE BUNDLE'S CHUNK SEGMENT. A bundle's chunk
# entry carries a logicalOffset/logicalSize sub-range — the part the engine
# needs resident — so reading a chunk through its bundle segment gives a
# fraction of it. Measured against the reference dump, those came back 4x and
# 64x too small on exactly the chunks that stream. The loose-chunk map is whole.
#
# DataPosition is in 4-BYTE UNITS relative to DataOffset, not bytes.
func chunk_location(ch: Dictionary) -> Array:
	var pos: int = data_off + int(ch["data_pos"]) * 4
	var chunk_id := 0
	var cas_ix := 0
	if (int(ch["flags"]) & F_FNVFILE) != 0:
		chunk_id = _be32(body, pos + 2)
		cas_ix = _be16(body, pos + 6)
		pos += 8
	else:
		chunk_id = int(body[pos + 2])
		cas_ix = int(body[pos + 3])
		pos += 4
	var off := _be32(body, pos)
	var size := _be32(body, pos + 4)
	return [chunk_id, cas_ix, off, size]


func chunk_by_guid() -> Dictionary:
	if _by_guid.is_empty():
		for c in chunks:
			_by_guid[c["guid"]] = c
	return _by_guid
