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

# HOW FAST THEIR DISK IS, which no report has ever carried.
#
# A user's build took 15 minutes against 85 s measured here, and nothing in
# their log could separate "the plugin is slow" from "the game is on a drive
# that reads at 20 MB/s". The phase table gives wall time; wall time alone
# cannot tell those apart, and the division that can is free.
#
# Split into disk and decompress on purpose. Oodle is CPU and scales with core
# speed; the read is the drive. A machine slow at one is a different problem
# from a machine slow at the other, and lumping them gives a number that
# accuses whichever is innocent.
static var _n_reads := 0
static var _bytes_disk := 0      # compressed, as stored
static var _bytes_out := 0       # decompressed, as used
static var _us_disk := 0
static var _us_decomp := 0

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
		_bytes_out += raw.size()
		return raw
	if not CODEC_OODLE.has(codec):
		_err = "codec 0x%02X is not present in BF6 data" % codec
		return PackedByteArray()
	var _tz := Time.get_ticks_usec()
	var out: PackedByteArray = _oodle.decompress(raw, dsize)
	_us_decomp += Time.get_ticks_usec() - _tz
	_bytes_out += out.size()
	if out.size() != dsize:
		_err = "oodle returned %d, expected %d" % [out.size(), dsize]
		return PackedByteArray()
	return out


# Read one CAS reference. Empty return means failure — check last_error().
# Open .cas handles, path -> FileAccess. Guarded because a seek and the read
# that follows it are one operation on a shared handle: two threads interleaving
# there would hand each other the wrong bytes, silently.
var _fh := {}
var _fh_mx := Mutex.new()
const MAX_HANDLES := 192


# Caller must hold _fh_mx.
func _handle(path: String) -> FileAccess:
	var f = _fh.get(path)
	if f != null and (f as FileAccess).is_open():
		return f
	if _fh.size() >= MAX_HANDLES:
		# Not an LRU: with 157 files in the install this never runs, and a
		# real eviction policy would be untested code standing between every
		# read and its bytes.
		close_all()
	f = FileAccess.open(path, FileAccess.READ)
	if f != null:
		_fh[path] = f
	return f


# Drop every open handle. The engine would close them when this object is
# freed anyway; this exists so a caller that knows it is finished with the
# install can say so.
func close_all() -> void:
	_fh.clear()


func read(path: String, offset: int, size: int,
		allow_raw := false) -> PackedByteArray:
	var _td := Time.get_ticks_usec()
	# THE HANDLE STAYS OPEN. This used to open the file, seek, read and close
	# it on every single call, and the partition index calls it 228,971 times -
	# once per partition - which measured 20.4 s for 640 MB of 2.9 KB reads.
	# The open and close WERE the phase: the partitions are tiny, so almost
	# none of that time was spent moving bytes.
	#
	# The whole install is 157 .cas files, so every handle a session can want
	# fits in the cache at once and it never evicts in practice; the cap is
	# only there so a future layout with far more files degrades to the old
	# behaviour instead of exhausting file descriptors.
	_fh_mx.lock()
	var f := _handle(path)
	if f == null:
		_fh_mx.unlock()
		_err = "cannot open %s" % path
		return PackedByteArray()
	f.seek(offset)
	var buf := f.get_buffer(size)
	_fh_mx.unlock()
	_us_disk += Time.get_ticks_usec() - _td
	_bytes_disk += buf.size()
	_n_reads += 1
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


# What reading the install actually cost, as rates rather than as wall time.
#
# NOT A BENCHMARK, and it says so: these are small scattered reads out of the
# middle of large CAS files, so the figure lands well under any drive's
# sequential rating. Its value is comparative - the same workload on two
# machines - not absolute.
static func io_report() -> PackedStringArray:
	var out := PackedStringArray()
	if _n_reads == 0:
		return out
	var s_disk := _us_disk / 1e6
	var s_dec := _us_decomp / 1e6
	var mb_disk := _bytes_disk / 1048576.0
	var mb_out := _bytes_out / 1048576.0
	out.append("READING THE GAME INSTALL")
	out.append("  Small scattered reads, not a sequential benchmark, so this")
	out.append("  reads lower than any drive's rated speed. It is here to be")
	out.append("  compared against another machine doing the same work.")
	out.append("  %-24s %10d" % ["reads", _n_reads])
	out.append("  %-24s %10.1f MB in %6.1f s   %8.1f MB/s"
		% ["off the drive", mb_disk, s_disk,
		   mb_disk / maxf(s_disk, 0.001)])
	out.append("  %-24s %10.1f MB in %6.1f s   %8.1f MB/s"
		% ["decompressed (Oodle)", mb_out, s_dec,
		   mb_out / maxf(s_dec, 0.001)])
	out.append("  %-24s %10.2f KB" % ["average read size",
		float(_bytes_disk) / maxf(1.0, float(_n_reads)) / 1024.0])
	# The ladder is rough drive-class guidance, not something measured here.
	var rate := mb_disk / maxf(s_disk, 0.001)
	if rate < 40.0:
		out.append("  This is slow enough to be the whole story. A build that")
		out.append("  takes many minutes on a drive reading at this rate is")
		out.append("  waiting on the disk, not on the plugin. Check whether the")
		out.append("  game is installed on a mechanical drive, an external USB")
		out.append("  disk, or a network location, and whether a virus scanner")
		out.append("  is inspecting every read.")
	return out


# Called when a fresh source is mounted, so the rates describe THIS session's
# work rather than accumulating across every map ever opened.
static func io_reset() -> void:
	_n_reads = 0
	_bytes_disk = 0
	_bytes_out = 0
	_us_disk = 0
	_us_decomp = 0
