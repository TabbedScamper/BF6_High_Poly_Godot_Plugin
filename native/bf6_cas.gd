@tool
extends RefCounted
class_name BF6Cas

# Read a CAS reference out of the game install, in GDScript.
#
# Ported from fb_cas.py, which has been proven byte-identical to the
# closed-source dump across 400 chunks and 600 meshsets. Only the Oodle call
# leaves GDScript, through the BF6Oodle extension.
#
# The block format (CONTAINERS.md 7) is two big-endian dwords followed by the
# payload:
#
#     d0 >> 24        flags
#     d0 & 0xFFFFFF   decompressed size
#     d1 >> 24        codec
#     (d1 >> 20) & 15 guard nibble, 7 on every BF6 segment
#     d1 & 0xFFFFF    compressed size
#
# TWO CASES THAT LOOK LIKE CORRUPTION AND ARE NOT, both learned the hard way on
# the Python side:
#
#   A bundle's segment 0 may be stored RAW, and the guard check failing is
#   exactly how a reader is meant to discover that. Hence allow_raw.
#
#   A reference may span SEVERAL blocks. Missing that made 42 of 82 barrack
#   prefab instances read empty on mp_tungsten — silently, because the first
#   block decodes perfectly well and the rest is simply never fetched. So a
#   reference whose first block does not account for the whole span is walked
#   to its end.

const GUARD := 7
const CODEC_NONE := 0x00
const CODEC_OODLE := [0x11, 0x15, 0x17, 0x19]
const MAX_BLOCKS := 4096          # a 4K BC7 texture is about 127

var _oodle = null
var _err := ""

func _init() -> void:
	if ClassDB.class_exists("BF6Oodle"):
		_oodle = ClassDB.instantiate("BF6Oodle")


func open(game_dir: String) -> bool:
	if _oodle == null:
		_err = "the BF6Oodle extension is not loaded"
		return false
	if not _oodle.open(game_dir):
		_err = str(_oodle.last_error())
		return false
	_err = ""
	return true


func last_error() -> String:
	return _err


static func _be32(b: PackedByteArray, at: int) -> int:
	return (int(b[at]) << 24) | (int(b[at + 1]) << 16) \
			| (int(b[at + 2]) << 8) | int(b[at + 3])


# -> {flags, dsize, codec, guard, csize}
static func block_header(b: PackedByteArray, pos: int) -> Dictionary:
	var d0 := _be32(b, pos)
	var d1 := _be32(b, pos + 4)
	return {
		"flags": (d0 >> 24) & 0xFF,
		"dsize": d0 & 0x00FFFFFF,
		"codec": (d1 >> 24) & 0xFF,
		"guard": (d1 >> 20) & 0x0F,
		"csize": d1 & 0x000FFFFF,
	}


func _one(buf: PackedByteArray, at: int, csize: int, dsize: int,
		codec: int) -> PackedByteArray:
	var raw := buf.slice(at, at + csize)
	if codec == CODEC_NONE:
		if raw.size() != dsize:
			_err = "uncompressed block is %d, declared %d" % [raw.size(), dsize]
			return PackedByteArray()
		return raw
	if not CODEC_OODLE.has(codec):
		_err = "codec 0x%02X is not present in BF6 data" % codec
		return PackedByteArray()
	var out: PackedByteArray = _oodle.decompress(raw, dsize)
	if out.size() != dsize:
		_err = "oodle returned %d, expected %d" % [out.size(), dsize]
		return PackedByteArray()
	return out


# Read one CAS reference. Empty return means failure — check last_error().
func read(path: String, offset: int, size: int,
		allow_raw := false) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_err = "cannot open %s" % path
		return PackedByteArray()
	f.seek(offset)
	var buf := f.get_buffer(size)
	f.close()
	if buf.size() < 8:
		_err = "CAS reference shorter than a block header"
		return PackedByteArray()

	var h := block_header(buf, 0)
	if int(h["guard"]) != GUARD:
		if allow_raw:
			return buf
		_err = "guard nibble %d != 7 at %s+%d" % [h["guard"],
				path.get_file(), offset]
		return PackedByteArray()

	if int(h["csize"]) == size - 8:
		return _one(buf, 8, int(h["csize"]), int(h["dsize"]), int(h["codec"]))

	var parts: Array[PackedByteArray] = []
	var pos := 0
	for _i in range(MAX_BLOCKS):
		if pos + 8 > buf.size():
			break
		var h2 := block_header(buf, pos)
		var cs2 := int(h2["csize"])
		if int(h2["guard"]) != GUARD or pos + 8 + cs2 > buf.size():
			break
		var part := _one(buf, pos + 8, cs2, int(h2["dsize"]), int(h2["codec"]))
		if part.is_empty():
			return PackedByteArray()
		parts.append(part)
		pos += 8 + cs2
	if parts.size() < 2:
		_err = "not a multi-block span at %s+%d" % [path.get_file(), offset]
		return PackedByteArray()
	var out := PackedByteArray()
	for p in parts:
		out.append_array(p)
	return out
