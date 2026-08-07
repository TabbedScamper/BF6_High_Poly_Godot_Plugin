@tool
extends RefCounted
class_name BF6Source

# Ask for an asset by name, get its bytes — straight out of the player's
# install. Ported from fb_mount.py and fb_source.py.
#
#     var src := BF6Source.new()
#     src.open("")                      # find the game
#     src.mount("mp_dumbo")
#     var bytes := src.get_res("game/glaciermp/levels/mp_dumbo/.../staticmodel")
#
# MOUNT ORDER decides name collisions and is not cosmetic. 6,953 names are
# carried by two bundles at different sizes; all of those conflicts are
# base-vs-DLC, and MAP_LOADING 4.2 says base mounts FIRST and wins. Sorting
# paths alphabetically already produced that because "Data" < "Update", which
# is right by accident — so the order is explicit here instead.

# These four are GLOBAL CLASSES (class_name BF6Toc, BF6Bundle, BF6Cas,
# BF6Container), so nothing has to be preloaded to reach them — and preloading
# them by a res:// root path was a hidden requirement that the file sit at the
# project root. True in the bare test project, false in the plugin, where the
# whole stack lives under addons/highpoly_toggle: the addon failed to parse with
# "Preload file res://bf6_toc.gd does not exist" the moment it was packaged.

var game := ""
var error := ""

# EVERYTHING IS STORED AS A RESOLVED CAS COORDINATE — [chunk_id, cas_ix,
# offset, size] — not as a reference back into a parsed TOC.
#
# The first version cached the index but kept toc_index/bundle_offset in it, so
# a cache hit still had to re-parse all 88 TOCs to have their bodies resident
# for chunk_location() and read_segments(). That left a "cached" mount at 4.4 s
# against 21.5 s cold: better, and still paying for work the cache was supposed
# to remove. Resolving at build time means a warm mount touches no .toc file at
# all.
var tocs: Array = []                 # BF6Toc, only populated on a cold mount
var chunks := {}                     # guid -> [chunk_id, cas_ix, off, size]
var ebx := {}                        # name -> [chunk_id, cas_ix, off, size, declared]
var res := {}                        # name -> [..., declared, type, rid]
var chunk_seg := {}                  # guid -> [chunk_id, cas_ix, off, size]
var stats := {}

var _cas: BF6Cas = null
var _loc = null
var _path_cache := {}


func open(game_dir := "") -> bool:
	game = BF6Container.find_game(game_dir)
	if game == "":
		error = BF6Container.last_error
		return false
	_cas = BF6Cas.new()
	if not _cas.open(game):
		error = _cas.last_error()
		return false
	_loc = BF6Container.CasLocator.new(game)
	if _loc.by_index.is_empty():
		error = "layout.toc named no install chunks"
		return false
	return true


# base before DLC (3.6, 4.2). A rule that works by alphabet breaks when a
# folder is renamed, so it is spelled out.
static func _mount_key(p: String) -> String:
	var low := p.to_lower().replace("\\", "/")
	return ("1" if low.contains("/update/") else "0") + low


static func _is_level(p: String) -> bool:
	return p.to_lower().replace("\\", "/").contains("/levels/")


func _find_tocs(level: String) -> Array:
	var shared: Array = []
	var lvl: Array = []
	var want := "/levels/%s/" % level.to_lower()
	var stack: Array = [game]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var da := DirAccess.open(dir)
		if da == null:
			continue
		for sub in da.get_directories():
			stack.append(dir.path_join(sub))
		for f in da.get_files():
			if not f.ends_with(".toc"):
				continue
			var p := dir.path_join(f)
			if _is_level(p):
				if level != "" and p.to_lower().replace("\\", "/").contains(want):
					lvl.append(p)
			else:
				shared.append(p)
	shared.sort_custom(func(a, b): return _mount_key(a) < _mount_key(b))
	lvl.sort_custom(func(a, b): return _mount_key(a) < _mount_key(b))
	# the level goes LAST: it may not displace a global it depends on
	return shared + lvl


# The index is the whole cost of a mount: reading segment 0 of all 18,533
# bundles takes ~21 s, against ~0.25 ms for any single asset read afterwards.
# Nothing in it is user-specific, so it is built once and cached.
#
# KEYED ON EVERY MOUNTED TOC's SIZE AND MTIME. A game patch rewrites TOCs, and
# a stale index would resolve names to byte ranges that have moved — which does
# not fail loudly, it returns the wrong asset. Cheap to check, impossible to
# get wrong.
# BUMP THIS WHENEVER THE STORED SHAPE CHANGES. The signature covers the game's
# TOCs, which catches a patched install — it cannot catch a changed READER. A
# v1 cache written with toc_index/bundle_offset entries loaded perfectly well
# into the resolved-coordinate version and every lookup silently returned zero
# bytes, which the benchmark showed as a 97% speed-up. Data versioning without
# code versioning is a way to make a bug look like a win.
const CACHE_VERSION := 2


func _signature(paths: Array) -> String:
	var parts := PackedStringArray()
	for p in paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		parts.append("%s|%d|%d" % [p, f.get_length(),
				FileAccess.get_modified_time(p)])
		f.close()
	parts.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(parts).to_utf8_buffer())
	return ctx.finish().hex_encode().substr(0, 16)


func _cache_path(level: String, sig: String) -> String:
	return "user://bf6_index_%s_v%d_%s.idx" % [
			level if level != "" else "shared", CACHE_VERSION, sig]


func _load_cache(p: String) -> bool:
	if not FileAccess.file_exists(p):
		return false
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var d = f.get_var()
	f.close()
	if typeof(d) != TYPE_DICTIONARY or not d.has("ebx"):
		return false
	ebx = d["ebx"]
	res = d["res"]
	chunks = d["chunks"]
	chunk_seg = d["chunk_seg"]
	stats = d["stats"]
	stats["from_cache"] = true
	return true


func _save_cache(p: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return                      # a cache that cannot be written is not an error
	f.store_var({"ebx": ebx, "res": res, "chunks": chunks,
			"chunk_seg": chunk_seg, "stats": stats})
	f.close()


# bundle_limit stops the sweep after N bundles and reports the RATE.
#
# A cold mount takes ~21 s, which makes it a miserable thing to iterate on: you
# change one line and wait most of a minute to learn whether it helped. But the
# sweep is a uniform loop, so a bounded sample measures the same thing — bundles
# per second — in a second or two, and the projection is just arithmetic.
#
# It is a PROJECTION, and reported as one. Use it to steer, then confirm the
# real number with an unbounded run before believing it.
func mount(level := "", progress := Callable(), use_cache := true,
		bundle_limit := 0) -> bool:
	var t0 := Time.get_ticks_msec()
	var paths := _find_tocs(level)

	# The TOCs still have to be PARSED even on a cache hit: chunk_location()
	# reads the loose-chunk record straight out of toc.body, so the bodies must
	# be resident. That is ~100 ms per big toc rather than the 21 s bundle
	# sweep, and it is why the cache stores the index but not the parse.
	var sig := ""
	# Remembered for the partition index, which caches under the same identity:
	# it is derived from these exact TOCs, so it must go stale with them.
	_sig = ""
	_level = level
	if use_cache:
		sig = _signature(paths)
		_sig = sig
		if _load_cache(_cache_path(level, sig)):
			stats["ms"] = Time.get_ticks_msec() - t0
			return true

	var opened := 0
	var failed := 0
	var collisions := 0
	var total_bundles := 0
	for p in paths:
		if bundle_limit > 0 and opened >= bundle_limit:
			break
		var t := BF6Toc.new()
		if not t.load_from(p):
			continue
		total_bundles += t.bundles.size()
		tocs.append(t)
		# Resolve the loose-chunk map NOW, while this toc's body is resident.
		for c in t.chunks:
			if not chunks.has(c["guid"]):
				chunks[c["guid"]] = t.chunk_location(c)
		for b in t.bundles:
			if bundle_limit > 0 and opened >= bundle_limit:
				break
			var segs := BF6Bundle.read_segments(t.body, b["offset"])
			if segs.is_empty():
				failed += 1
				continue
			var meta := _read_seg(segs[0], true)
			if meta.is_empty():
				failed += 1
				continue
			var pay := BF6Bundle.Payload.new()
			if not pay.parse(meta):
				failed += 1
				continue
			opened += 1
			for a in pay.assets():
				var kind: String = a[0]
				var rec: Dictionary = a[1]
				var si: int = a[2]
				if si >= segs.size():
					continue
				var seg: Array = segs[si]
				match kind:
					"ebx":
						var n: String = rec["name"]
						if ebx.has(n):
							if int(ebx[n][4]) != int(rec["size"]):
								collisions += 1
							continue
						ebx[n] = [seg[0], seg[1], seg[2], seg[3], rec["size"]]
					"res":
						var rn: String = rec["name"]
						if res.has(rn):
							if int(res[rn][4]) != int(rec["size"]):
								collisions += 1
							continue
						res[rn] = [seg[0], seg[1], seg[2], seg[3],
								rec["size"], rec["type"], rec["rid"]]
					_:
						if not chunk_seg.has(rec["id"]):
							chunk_seg[rec["id"]] = seg
		if progress.is_valid():
			progress.call(tocs.size(), paths.size(), ebx.size())
	stats = {
		"ms": Time.get_ticks_msec() - t0,
		"tocs": tocs.size(),
		"bundles_opened": opened,
		"bundles_failed": failed,
		"ebx": ebx.size(),
		"res": res.size(),
		"chunks_loose": chunks.size(),
		"chunks_bundle_local": chunk_seg.size(),
		"size_disagreements": collisions,
	}
	if bundle_limit > 0:
		var ms: int = int(stats["ms"])
		stats["sampled"] = true
		stats["bundles_per_sec"] = int(1000.0 * opened / max(ms, 1))
		# NO PROJECTED TOTAL. There was one, and it was wrong by 2x: a
		# 1,500-bundle sample projected 43.6 s against a real cold mount of
		# 21.5 s. The sample is not representative in absolute terms — it
		# carries the whole fixed setup cost (the tree walk and the TOC parses)
		# against a fraction of the bundles, and mount order front-loads the
		# large shared TOCs.
		#
		# The RATE is still exactly what iteration needs, because the question
		# being asked is "did my change make the sweep faster", and that
		# comparison is valid whether or not the absolute number is. Confirm
		# with mount_cold before believing any total.
		return opened > 0
	if use_cache and opened > 0 and sig != "":
		_save_cache(_cache_path(level, sig))
	return opened > 0


# Every entry is already a CAS coordinate, so a read is a path join and a
# seek — no TOC body, no segment-list walk, nothing cached to go stale.
func _read_seg(seg: Array, allow_raw := false) -> PackedByteArray:
	var key := int(seg[0]) * 1000 + int(seg[1])
	var p = _path_cache.get(key)
	if p == null:
		p = _loc.cas_path(int(seg[0]), int(seg[1]))
		_path_cache[key] = p
	if p == "":
		error = "no cas file for install chunk %d index %d" % [seg[0], seg[1]]
		return PackedByteArray()
	return _cas.read(p, int(seg[2]), int(seg[3]), allow_raw)


func get_ebx(name: String) -> PackedByteArray:
	var e = ebx.get(name.to_lower())
	if e == null:
		e = ebx.get(name)
	if e == null:
		error = "no ebx named %s" % name
		return PackedByteArray()
	var d := _read_seg(e)
	if d.size() != int(e[4]):
		error = "ebx %s: declared %d bytes, got %d" % [name, e[4], d.size()]
		return PackedByteArray()
	return d


func get_res(name: String) -> PackedByteArray:
	var e = res.get(name.to_lower())
	if e == null:
		e = res.get(name)
	if e == null:
		error = "no res named %s" % name
		return PackedByteArray()
	var d := _read_seg(e)
	if d.size() != int(e[4]):
		error = "res %s: declared %d bytes, got %d" % [name, e[4], d.size()]
		return PackedByteArray()
	return d


func res_info(name: String):
	var e = res.get(name.to_lower())
	if e == null:
		e = res.get(name)
	if e == null:
		return null
	return {"name": name, "size": e[4], "type": e[5], "rid": e[6]}


# ---------------------------------------------------------------------------
# PARTITION GUID -> EBX NAME: the one index that cannot come from metadata.
#
# An EBX import names its target by PARTITION GUID, and that GUID lives inside
# the target's own payload, in the EFIX fixup. It appears in no TOC and in no
# bundle table, so there is nothing to look it up in — the engine builds the
# index by reading every catalogued EBX header once, and so must we.
#
# This is what guid_index_<map>.tsv used to be, and that file was built by
# walking a 277 GB dump. Replacing it is the whole point: with this, a placement
# walk needs the player's install and nothing else. No dump, no download.
#
# ITERATED IN BUNDLE ORDER, which is not cosmetic. Entries that sit together in
# a bundle read from the same CAS region, and touching them in catalogue order
# instead measured about 15x worse in the Python original.
#
# '.ebx' is appended deliberately. The traversal decides whether an import is a
# PARTITION to recurse into or a RESOURCE to emit by testing for that suffix, so
# handing back bare names would silently turn every recursion into a leaf.
var _pidx = null
var _sig := ""
var _level := ""


func partition_index(progress := Callable()) -> Dictionary:
	if _pidx != null:
		return _pidx
	var cp := _pidx_cache_path()
	if cp != "" and FileAccess.file_exists(cp):
		var f := FileAccess.open(cp, FileAccess.READ)
		if f != null:
			var d = f.get_var()
			f.close()
			if typeof(d) == TYPE_DICTIONARY and not (d as Dictionary).is_empty():
				_pidx = d
				return _pidx

	var names: Array = ebx.keys()
	names.sort_custom(func(a, b):
		var ea: Array = ebx[a]
		var eb: Array = ebx[b]
		if int(ea[0]) != int(eb[0]):
			return int(ea[0]) < int(eb[0])
		if int(ea[1]) != int(eb[1]):
			return int(ea[1]) < int(eb[1])
		return int(ea[2]) < int(eb[2]))

	var out := {}
	var done := 0
	for name in names:
		var g := _efix_guid(_read_seg(ebx[name]))
		# First name wins, so the result is stable across runs rather than
		# dependent on iteration order.
		if g != "" and not out.has(g):
			out[g] = str(name) + ".ebx"
		done += 1
		if progress.is_valid() and done % 2000 == 0:
			progress.call(done, names.size(), out.size())
	_pidx = out
	if cp != "":
		var wf := FileAccess.open(cp, FileAccess.WRITE)
		if wf != null:
			wf.store_var(out)
			wf.close()
	return _pidx


# A partition's own GUID, out of its EFIX fixup.
#
# Deliberately NOT done by handing the bytes to the deserializer: this is a
# RIFF chunk walk and a 16-byte read, while BF6Ebx is the layer ABOVE this one —
# it needs the type tables out of the exe, and a source that cannot index itself
# without them would be a circular dependency for no gain. Twelve lines is the
# cheaper answer.
func _efix_guid(raw: PackedByteArray) -> String:
	if raw.size() < 12 or raw.slice(0, 4).get_string_from_ascii() != "RIFF":
		return ""
	var o := 12
	while o + 8 <= raw.size():
		var cid := raw.slice(o, o + 4).get_string_from_ascii()
		var sz := int(raw.decode_u32(o + 4))
		if cid == "EFIX":
			var s := o + 8
			if s + 16 > raw.size():
				return ""
			# .NET Guid mixed-endian, matching BF6Ebx.guid_str: first three
			# groups little-endian, last eight bytes as they lie. The two MUST
			# agree — this index is looked up with keys that reader produces.
			return "%08x-%04x-%04x-%s-%s" % [raw.decode_u32(s),
				raw.decode_u16(s + 4), raw.decode_u16(s + 6),
				raw.slice(s + 8, s + 10).hex_encode(),
				raw.slice(s + 10, s + 16).hex_encode()]
		o += 8 + sz
		if o % 2 == 1:
			o += 1
	return ""


# Keyed on the same TOC signature as the segment index: this is derived from
# those exact files, so it has to go stale when they do (a game patch).
# The mounted TOCs' identity: name, size and mtime of every one, hashed. Anything
# derived from this mount must key its own cache on this, so a game patch
# invalidates the lot rather than leaving one stale layer behind the others.
func signature() -> String:
	return _sig


func _pidx_cache_path() -> String:
	if _sig == "":
		return ""
	return "user://bf6_pidx_%s_v%d_%s.idx" % [
			_level if _level != "" else "shared", CACHE_VERSION, _sig]


# A chunk's FULL data, from whichever of the two sources holds it.
#
# These are not a preference and a fallback for the same bytes. The loose-chunk
# map holds the WHOLE chunk, which is what anything with a mip chain needs —
# read one through its bundle segment instead and only the resident sub-range
# comes back (measured 4x and 64x short). But a bundle-local chunk appears in
# no TOC chunk map at all — 199 of mp_dumbo's 400 — and for those the segment
# IS the chunk.
func get_chunk(guid_hex: String) -> PackedByteArray:
	var g := guid_hex.to_lower()
	var e = chunks.get(g)
	if e != null:
		return _read_seg(e)
	var s = chunk_seg.get(g)
	if s != null:
		return _read_seg(s)
	error = "chunk %s is in no chunk map and no bundle" % g.substr(0, 16)
	return PackedByteArray()


func has_chunk(guid_hex: String) -> bool:
	var g := guid_hex.to_lower()
	return chunks.has(g) or chunk_seg.has(g)


func last_error() -> String:
	return error
