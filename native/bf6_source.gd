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

const BF6Toc := preload("res://bf6_toc.gd")
const BF6Bundle := preload("res://bf6_bundle.gd")
const BF6Cas := preload("res://bf6_cas.gd")
const BF6Container := preload("res://bf6_container.gd")

var game := ""
var error := ""

var tocs: Array = []                 # BF6Toc
var chunks := {}                     # guid -> [toc_index, chunk record]
var ebx := {}                        # name -> [toc_index, bundle_off, seg, size]
var res := {}                        # name -> [toc_index, bundle_off, seg, size, type, rid]
var chunk_seg := {}                  # guid -> [toc_index, bundle_off, seg]
var stats := {}

var _cas: BF6Cas = null
var _loc = null
var _seg_cache := {}


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


func mount(level := "", progress := Callable()) -> bool:
	var t0 := Time.get_ticks_msec()
	var paths := _find_tocs(level)
	var opened := 0
	var failed := 0
	var collisions := 0
	for p in paths:
		var t := BF6Toc.new()
		if not t.load_from(p):
			continue
		var ti := tocs.size()
		tocs.append(t)
		for c in t.chunks:
			if not chunks.has(c["guid"]):
				chunks[c["guid"]] = [ti, c]
		for b in t.bundles:
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
				match kind:
					"ebx":
						var n: String = rec["name"]
						if ebx.has(n):
							if int(ebx[n][3]) != int(rec["size"]):
								collisions += 1
							continue
						ebx[n] = [ti, b["offset"], si, rec["size"]]
					"res":
						var rn: String = rec["name"]
						if res.has(rn):
							if int(res[rn][3]) != int(rec["size"]):
								collisions += 1
							continue
						res[rn] = [ti, b["offset"], si, rec["size"],
								rec["type"], rec["rid"]]
					_:
						if not chunk_seg.has(rec["id"]):
							chunk_seg[rec["id"]] = [ti, b["offset"], si]
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
	return opened > 0


func _segments(ti: int, bundle_off: int) -> Array:
	# read_segments walks every segment a bundle declares, and a level bundle
	# declares thousands. Parsing it once per ASSET made reading a bundle's
	# contents quadratic in its own size — 10.5 ms for a 2.7 KB EBX on the
	# Python side, nearly all of it re-walking a list just walked.
	var key := "%d:%d" % [ti, bundle_off]
	var segs = _seg_cache.get(key)
	if segs == null:
		segs = BF6Bundle.read_segments(tocs[ti].body, bundle_off)
		if _seg_cache.size() > 48:
			_seg_cache.clear()
		_seg_cache[key] = segs
	return segs


func _read_seg(seg: Array, allow_raw := false) -> PackedByteArray:
	var p: String = _loc.cas_path(int(seg[0]), int(seg[1]))
	if p == "":
		error = "no cas file for install chunk %d index %d" % [seg[0], seg[1]]
		return PackedByteArray()
	return _cas.read(p, int(seg[2]), int(seg[3]), allow_raw)


func _read_entry(e: Array) -> PackedByteArray:
	var segs := _segments(int(e[0]), int(e[1]))
	var si := int(e[2])
	if si >= segs.size():
		error = "segment %d past the bundle's %d segments" % [si, segs.size()]
		return PackedByteArray()
	return _read_seg(segs[si])


func get_ebx(name: String) -> PackedByteArray:
	var e = ebx.get(name.to_lower())
	if e == null:
		e = ebx.get(name)
	if e == null:
		error = "no ebx named %s" % name
		return PackedByteArray()
	var d := _read_entry(e)
	if d.size() != int(e[3]):
		error = "ebx %s: declared %d bytes, got %d" % [name, e[3], d.size()]
		return PackedByteArray()
	return d


func get_res(name: String) -> PackedByteArray:
	var e = res.get(name.to_lower())
	if e == null:
		e = res.get(name)
	if e == null:
		error = "no res named %s" % name
		return PackedByteArray()
	var d := _read_entry(e)
	if d.size() != int(e[3]):
		error = "res %s: declared %d bytes, got %d" % [name, e[3], d.size()]
		return PackedByteArray()
	return d


func res_info(name: String):
	var e = res.get(name.to_lower())
	if e == null:
		e = res.get(name)
	if e == null:
		return null
	return {"name": name, "size": e[3], "type": e[4], "rid": e[5]}


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
		var t: BF6Toc = tocs[int(e[0])]
		var loc := t.chunk_location(e[1])
		return _read_seg(loc)
	var s = chunk_seg.get(g)
	if s != null:
		return _read_entry(s)
	error = "chunk %s is in no chunk map and no bundle" % g.substr(0, 16)
	return PackedByteArray()


func has_chunk(guid_hex: String) -> bool:
	var g := guid_hex.to_lower()
	return chunks.has(g) or chunk_seg.has(g)


func last_error() -> String:
	return error
