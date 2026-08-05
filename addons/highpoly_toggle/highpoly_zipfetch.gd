@tool
extends RefCounted
class_name HighpolyZipFetch

# Pull only the props a user is actually missing, straight out of the published
# archive, without downloading the archive.
#
# WHY. ensure_props() works out exactly which props are absent and then
# downloads the whole per-map props.zip regardless — 1.71 GB for Dumbo — writes
# it to disk, and unpacks it as a second stage. Because user://mapcontext/_props
# is ONE cache shared by every map, the second map a user opens is mostly props
# they already have. Measured across all 24 published archives: 27.93 GB shipped
# against 16.77 GB of unique props, so 41% of what a user downloads walking the
# map list is bytes already on their disk. After Dumbo, the next map re-fetches
# between 10% and 53% of itself.
#
# HOW. A zip's central directory sits at the end of the file and lists every
# entry's offset and size, so two Range requests (~0.2-0.7 MB) buy a complete
# index. Every published archive stores its entries UNCOMPRESSED and in one
# contiguous run — verified across 8 maps, zero gaps, no zip64 — which means a
# ranged read IS the glb, with no inflate step, and the props a client wants
# form RUNS of adjacent bytes.
#
# COALESCING is what makes it viable. Asking for 2,761 individual entries earns
# HTTP 429 from r2.dev and pays a TLS handshake per file (measured: 4.1 MB/s).
# Asking for ~16-34 big runs does not: measured 118 MB/s against 36 MB/s for the
# single stream it replaces, on COLD maps, one method per map so nothing was
# warm at the CDN edge. The single stream is also erratic — one cold map served
# it at 8.4 MB/s — where the ranged runs came in at 116/118/120.
#
# It also deletes the unpack stage outright (28 s on Dumbo) and the 1.71 GB
# temp file, because the bytes arriving ARE the files.
#
# FALLS BACK. Everything here is an optimisation over a path that already works.
# Anything unexpected — no Range support, a server that ignores it, a zip we
# cannot read, a compressed entry — returns a failure and the caller downloads
# the archive the old way.

const WORKERS := 8              # 8 saturated the link; 16 earned 429s
const CHUNK := 16 * 1048576     # per request; x WORKERS is the peak RAM held
const TAIL := 128 * 1024        # enough to find the end-of-central-directory
const SIG_EOCD := 0x06054B50
const SIG_CD := 0x02014B50
const SIG_LOCAL := 0x04034B50
const SIG_EOCD64 := 0x06064B50
const SIG_EOCD64_LOC := 0x07064B50
const Z64_EXTRA := 0x0001       # the ZIP64 extended information extra field
const U32_MAX := 0xFFFFFFFF

var _host: Node = null
var _url := ""
var _runs: Array = []           # [[start, end, [entry, ...]], ...]
var _next := 0
var _done_bytes := 0
var _failed := false
var _dest := ""
var _written := 0
var _progress := Callable()


func _init(host: Node, url: String) -> void:
	_host = host
	_url = url


# ---------------------------------------------------------------------------
# index: two ranged reads -> every entry's name, offset and size
# Returns [] when the archive cannot be indexed this way, which is not an error,
# only a reason to use the old path.
func read_index() -> Array:
	var total := await _size()
	if total <= 0:
		return []
	var tail := await _range(maxi(0, total - TAIL), total - 1)
	if tail.size() < 22:
		return []
	var eocd := _rfind_sig(tail, SIG_EOCD)
	if eocd < 0:
		return []
	var cd_size := int(tail.decode_u32(eocd + 12))
	var cd_off := int(tail.decode_u32(eocd + 16))

	# ZIP64. This used to give up here, on the grounds that no archive had ever
	# needed it and the whole-archive fallback covered the day one did. Both
	# halves of that turned out to be wrong.
	#
	# Python's zipfile saturates a field at 2 GB, not 4 GB, so MP_Aftermath's
	# 3.25 GB props.zip writes 0xFFFFFFFF as the offset of all 7,239 entries
	# past that mark and puts the real value in a ZIP64 extra field. The check
	# here only looked at the ARCHIVE-level fields, which were still real, so
	# the parse walked straight past it and produced 7,239 entries all claiming
	# to start at byte 4294967295. They coalesced into a single run beyond the
	# end of the file, its range request came back empty, and the whole fetch
	# failed with -1.
	#
	# The fallback did then cover it, in the sense that it pulled the archive
	# whole: 3.3 GB in one stream, which is the thing the ranged path exists to
	# avoid, and which stalled outright for the user who reported it.
	if cd_off == U32_MAX or cd_size == U32_MAX:
		var loc := _rfind_sig(tail, SIG_EOCD64_LOC)
		if loc < 0 or loc + 16 > tail.size():
			return []
		var at := int(tail.decode_u64(loc + 8))
		var e64 := await _range(at, at + 55)
		if e64.size() < 56 or e64.decode_u32(0) != SIG_EOCD64:
			return []
		cd_size = int(e64.decode_u64(40))
		cd_off = int(e64.decode_u64(48))
	if cd_size <= 0 or cd_off <= 0:
		return []
	var cd := await _range(cd_off, cd_off + cd_size - 1)
	if cd.size() < cd_size:
		return []
	return _parse_cd(cd)


static func _parse_cd(cd: PackedByteArray) -> Array:
	var out: Array = []
	var i := 0
	while i + 46 <= cd.size():
		if cd.decode_u32(i) != SIG_CD:
			break
		var method := cd.decode_u16(i + 10)
		var csize := cd.decode_u32(i + 20)
		var usize := cd.decode_u32(i + 24)
		var nlen := cd.decode_u16(i + 28)
		var elen := cd.decode_u16(i + 30)
		var clen := cd.decode_u16(i + 32)
		var off := int(cd.decode_u32(i + 42))
		# Any of these three may be a 0xFFFFFFFF placeholder for a real 64-bit
		# value in the extra field, and an entry past 2 GB routinely is.
		if usize == U32_MAX or csize == U32_MAX or off == U32_MAX:
			var z := _zip64(cd, i + 46 + nlen, elen, usize == U32_MAX,
				csize == U32_MAX, off == U32_MAX)
			if z.is_empty():
				return []          # saturated with no extra to resolve it
			usize = int(z.get("usize", usize))
			csize = int(z.get("csize", csize))
			off = int(z.get("off", off))
		out.append({
			"name": cd.slice(i + 46, i + 46 + nlen).get_string_from_utf8(),
			"off": off, "csize": csize, "usize": usize,
			"method": method, "nlen": nlen,
		})
		i += 46 + nlen + elen + clen
	return out


# The ZIP64 extended information extra field, 0x0001.
#
# ONLY THE SATURATED FIELDS ARE PRESENT, in a fixed order: uncompressed size,
# compressed size, local header offset. There is no tagging inside the record —
# which of the three is there is decided entirely by which of the 32-bit fields
# held 0xFFFFFFFF, so the caller has to say, and reading them in the wrong
# order silently yields a plausible number that points nowhere.
static func _zip64(cd: PackedByteArray, at: int, elen: int,
		want_usize: bool, want_csize: bool, want_off: bool) -> Dictionary:
	var end: int = mini(at + elen, cd.size())
	var p := at
	while p + 4 <= end:
		var id := cd.decode_u16(p)
		var sz := cd.decode_u16(p + 2)
		if id != Z64_EXTRA:
			p += 4 + sz
			continue
		var q := p + 4
		var stop: int = mini(q + sz, end)
		var out: Dictionary = {}
		if want_usize:
			if q + 8 > stop: return {}
			out["usize"] = cd.decode_u64(q); q += 8
		if want_csize:
			if q + 8 > stop: return {}
			out["csize"] = cd.decode_u64(q); q += 8
		if want_off:
			if q + 8 > stop: return {}
			out["off"] = cd.decode_u64(q)
		return out
	return {}


# Group the wanted entries into contiguous byte runs, each capped at CHUNK.
# `wanted` is a Dictionary of entry name -> true.
static func plan(entries: Array, wanted: Dictionary) -> Array:
	var pick: Array = []
	for e in entries:
		if wanted.has(str(e["name"])):
			pick.append(e)
	pick.sort_custom(func(a, b): return int(a["off"]) < int(b["off"]))
	var runs: Array = []
	var cur: Array = []
	var s := 0
	var e_end := 0
	for it in pick:
		# the slack covers the local header, whose extra field can be longer
		# than the central directory's copy of it
		var lo: int = int(it["off"])
		var hi: int = lo + 30 + int(it["nlen"]) + 512 + int(it["csize"])
		if cur.is_empty():
			s = lo; e_end = hi; cur = [it]
		elif lo <= e_end + 4096 and (hi - s) <= CHUNK:
			# adjacent (or near enough that pulling the gap beats a request)
			e_end = maxi(e_end, hi)
			cur.append(it)
		else:
			runs.append([s, e_end, cur])
			s = lo; e_end = hi; cur = [it]
	if not cur.is_empty():
		runs.append([s, e_end, cur])
	return runs


# ---------------------------------------------------------------------------
# fetch: pull every run in parallel, slicing entries straight out to disk.
# Returns the number of files written, or -1 if the caller should fall back.
func fetch(runs: Array, dest_dir: String, progress := Callable()) -> int:
	if runs.is_empty():
		return 0
	_runs = runs
	_next = 0
	_done_bytes = 0
	_failed = false
	_dest = dest_dir
	_written = 0
	_progress = progress
	var n: int = mini(WORKERS, runs.size())
	var live := [n]
	for i in range(n):
		_worker(live)
	while live[0] > 0:
		if _host == null or not _host.is_inside_tree():
			return -1
		await _host.get_tree().process_frame
	return -1 if _failed else _written


func _worker(live: Array) -> void:
	while true:
		if _failed:
			break
		var k := _next
		_next += 1
		if k >= _runs.size():
			break
		var run: Array = _runs[k]
		var blob := await _range(int(run[0]), int(run[1]))
		if blob.is_empty():
			_failed = true
			break
		if not _slice(blob, int(run[0]), run[2] as Array):
			_failed = true
			break
		_done_bytes += blob.size()
		if _progress.is_valid():
			_progress.call(_done_bytes, _written)
	live[0] -= 1


# Cut each entry out of the run and write it. The LOCAL header is authoritative
# for where the data starts: its extra field can be a different length from the
# central directory's, and trusting the directory's copy silently shifts every
# byte of the file.
func _slice(blob: PackedByteArray, base: int, entries: Array) -> bool:
	for e in entries:
		var rel: int = int(e["off"]) - base
		if rel < 0 or rel + 30 > blob.size():
			return false
		if blob.decode_u32(rel) != SIG_LOCAL:
			return false
		var nlen := blob.decode_u16(rel + 26)
		var elen := blob.decode_u16(rel + 28)
		var start := rel + 30 + nlen + elen
		var csize: int = int(e["csize"])
		if start + csize > blob.size():
			return false
		var data := blob.slice(start, start + csize)
		if int(e["method"]) != 0:
			# every published archive is STORED; a compressed one is a pipeline
			# change we have not seen, so hand it back to the old path rather
			# than guess at the framing
			return false
		var p := "%s/%s" % [_dest, str(e["name"])]
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			return false
		f.store_buffer(data)
		f.close()
		_written += 1
	return true


# ---------------------------------------------------------------------------
func _size() -> int:
	var http := HTTPRequest.new()
	_host.add_child(http)
	http.use_threads = true
	var err := http.request(_url, _ua(), HTTPClient.METHOD_HEAD)
	if err != OK:
		http.queue_free()
		return 0
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return 0
	for h in (res[2] as PackedStringArray):
		var s := str(h)
		if s.to_lower().begins_with("content-length:"):
			return int(s.split(":")[1].strip_edges())
	return 0


func _range(a: int, b: int) -> PackedByteArray:
	for attempt in range(4):
		var http := HTTPRequest.new()
		_host.add_child(http)
		http.use_threads = true          # off the main thread, like the big one
		var hdr := _ua()
		hdr.append("Range: bytes=%d-%d" % [a, b])
		var err := http.request(_url, hdr)
		if err != OK:
			http.queue_free()
		else:
			var res: Array = await http.request_completed
			http.queue_free()
			var code := int(res[1])
			# 206 is what we asked for. A 200 means the server ignored Range and
			# is sending the WHOLE archive — bail rather than buffer gigabytes.
			if code == 206:
				return res[3]
			if code == 200:
				return PackedByteArray()
		if _host == null or not _host.is_inside_tree():
			return PackedByteArray()
		await _host.get_tree().create_timer(0.4 * pow(2, attempt)).timeout
	return PackedByteArray()


static func _ua() -> PackedStringArray:
	return PackedStringArray([
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)"])


static func _rfind_sig(b: PackedByteArray, sig: int) -> int:
	var i := b.size() - 4
	while i >= 0:
		if b.decode_u32(i) == sig:
			return i
		i -= 1
	return -1
