extends SceneTree

# The mining harness: boot Godot, read from the game, time every stage, repeat.
#
# A cold mount takes ~20 s and "make it faster" is not actionable until that
# number is broken into parts. So this measures each STAGE separately, and each
# stage is a thing you could actually change:
#
#   find_game        scanning for the install
#   layout           layout.toc -> the install-chunk map (DbObject)
#   toc_scan         walking the tree for .toc files
#   toc_parse        one big TOC: header + bundle map + chunk map
#   huffman          just the name decode inside that TOC
#   segments         read_segments over many bundles
#   payload          bundle payload parse over many bundles
#   mount            the whole thing end to end
#   cas_single       one single-block CAS reference
#   cas_multi        one multi-block reference (2.5 MB -> 2.76 MB)
#   oodle            decompression alone, no I/O, no parsing
#   get_res_*        a named lookup end to end
#
# REPORTING: min and median, never mean. These are CPU-bound and the noise is
# one-sided — a slow sample means something else ran, it never means the code
# got faster. The minimum is the closest thing to the true cost, and the median
# says whether the run was stable.
#
#   godot --headless --path <proj> --script bench.gd -- <game> [level] [filter] [repeat]
#
# Writes bench.json next to the project for the Python driver to diff.

const BF6Source := preload("res://bf6_source.gd")
const BF6Toc := preload("res://bf6_toc.gd")
const BF6Bundle := preload("res://bf6_bundle.gd")
const BF6Cas := preload("res://bf6_cas.gd")
const BF6Container := preload("res://bf6_container.gd")

var game := ""
var level := "mp_dumbo"
var filter := ""
var repeat := 3
var results: Array = []

# shared state so later benches can reuse earlier work
var _big_toc_path := ""
var _big_toc_raw := PackedByteArray()
var _src = null
var _cas_vectors: Array = []


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	game = str(args[0]) if args.size() > 0 else ""
	level = str(args[1]) if args.size() > 1 else "mp_dumbo"
	filter = str(args[2]) if args.size() > 2 else ""
	repeat = int(str(args[3])) if args.size() > 3 else 3

	if game == "":
		game = BF6Container.find_game()
	if game == "":
		print("no game install found")
		quit(1); return
	print("game   : %s" % game)
	print("level  : %s" % level)
	print("filter : %s" % ("<all>" if filter == "" else filter))
	print("repeat : %d\n" % repeat)

	_prepare()

	_bench("find_game", 1, func():
		return {"path_len": BF6Container.find_game().length()})

	_bench("layout", repeat, func():
		var loc = BF6Container.CasLocator.new(game)
		return {"install_chunks": loc.by_index.size()})

	_bench("toc_scan", repeat, func():
		var n := _count_tocs()
		return {"tocs": n})

	_bench("toc_parse", repeat, func():
		var t := BF6Toc.new()
		t.parse(_big_toc_raw)
		return {"bundles": t.bundles.size(), "chunks": t.chunks.size()})

	_bench("huffman", repeat, func():
		var t := BF6Toc.new()
		t.parse(_big_toc_raw)
		return {"names": t.names.size()})

	_bench("segments", repeat, func():
		var t := BF6Toc.new()
		t.parse(_big_toc_raw)
		var total := 0
		for b in t.bundles:
			total += BF6Bundle.read_segments(t.body, b["offset"]).size()
		return {"segments": total, "bundles": t.bundles.size()})

	_bench("payload", repeat, func():
		var t := BF6Toc.new()
		t.parse(_big_toc_raw)
		var loc = BF6Container.CasLocator.new(game)
		var cas = BF6Cas.new()
		cas.open(game)
		var n := 0
		var assets := 0
		for b in t.bundles:
			var segs := BF6Bundle.read_segments(t.body, b["offset"])
			if segs.is_empty():
				continue
			var p: String = loc.cas_path(int(segs[0][0]), int(segs[0][1]))
			if p == "":
				continue
			var meta := cas.read(p, int(segs[0][2]), int(segs[0][3]), true)
			var pay := BF6Bundle.Payload.new()
			if pay.parse(meta):
				n += 1
				assets += pay.ebx.size() + pay.res.size() + pay.chunks.size()
		return {"bundles": n, "assets": assets})

	_bench("mount", repeat, func():
		var s = BF6Source.new()
		s.open(game)
		s.mount(level)
		return {"ebx": s.ebx.size(), "res": s.res.size(),
				"bundles": int(s.stats.get("bundles_opened", 0))})

	# reads reuse one mounted source; mounting inside them would drown the
	# thing being measured
	if _src != null:
		# Names picked OUTSIDE the timed body. Choosing them inside meant
		# sorting 160,689 keys on every iteration, and the read stages reported
		# ~138 ms against Python's 0.68 ms — a measurement of the sort, not of
		# the read. The harness caught this on its own first run.
		var small := _pick_res(0)
		var large := _pick_res(1)
		var chunk := _pick_chunk()

		_bench("get_res_small", repeat * 20, func():
			var d: PackedByteArray = _src.get_res(small)
			return {"bytes": d.size()})

		_bench("get_res_large", repeat * 4, func():
			var d: PackedByteArray = _src.get_res(large)
			return {"bytes": d.size()})

		_bench("get_chunk", repeat * 8, func():
			var d: PackedByteArray = _src.get_chunk(chunk)
			return {"bytes": d.size()})

	for v in _cas_vectors:
		var kind: String = v["kind"]
		var cas = BF6Cas.new()
		cas.open(game)
		_bench("cas_" + kind, repeat * 2, func():
			var d: PackedByteArray = cas.read(str(v["path"]), int(v["offset"]),
					int(v["size"]), bool(v["allow_raw"]))
			return {"bytes": d.size()})

	_report()
	quit(0)


func _prepare() -> void:
	# the biggest level TOC, which is the one worth profiling
	var best := 0
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
			if not p.to_lower().contains("/levels/%s/" % level):
				continue
			var fa := FileAccess.open(p, FileAccess.READ)
			if fa == null:
				continue
			var sz := fa.get_length()
			fa.close()
			if sz > best:
				best = sz
				_big_toc_path = p
	if _big_toc_path != "":
		_big_toc_raw = FileAccess.get_file_as_bytes(_big_toc_path)
		print("profiling toc: %s (%.2f MB)\n"
				% [_big_toc_path.get_file(), _big_toc_raw.size() / 1048576.0])

	var s = BF6Source.new()
	if s.open(game) and s.mount(level):
		_src = s

	# a couple of real CAS references, one of each shape
	if _src != null:
		var t: BF6Toc = _src.tocs[_src.tocs.size() - 1]
		for b in t.bundles:
			if _cas_vectors.size() >= 2:
				break
			var segs := BF6Bundle.read_segments(t.body, b["offset"])
			if segs.size() < 2:
				continue
			for si in [0, 1]:
				var seg: Array = segs[si]
				var p: String = _src._loc.cas_path(int(seg[0]), int(seg[1]))
				if p == "" or int(seg[3]) < 4096:
					continue
				_cas_vectors.append({"kind": "raw" if si == 0 else "block",
						"path": p, "offset": int(seg[2]), "size": int(seg[3]),
						"allow_raw": si == 0})
				break


func _count_tocs() -> int:
	var n := 0
	var stack: Array = [game]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var da := DirAccess.open(dir)
		if da == null:
			continue
		for sub in da.get_directories():
			stack.append(dir.path_join(sub))
		for f in da.get_files():
			if f.ends_with(".toc"):
				n += 1
	return n


func _pick_res(which: int) -> String:
	# a small one and a large one, chosen deterministically so runs compare
	var names: Array = _src.res.keys()
	names.sort()
	var small := ""
	var large := ""
	var large_sz := 0
	for i in range(0, names.size(), max(1, names.size() / 400)):
		var n: String = names[i]
		var sz := int(_src.res[n][3])
		if small == "" and sz > 2048 and sz < 32768:
			small = n
		if sz > large_sz and sz < (8 << 20):
			large_sz = sz
			large = n
	return small if which == 0 else large


func _pick_chunk() -> String:
	var keys: Array = _src.chunks.keys()
	keys.sort()
	return str(keys[keys.size() / 2])


func _bench(name: String, times: int, body: Callable) -> void:
	if filter != "" and not name.contains(filter):
		return
	var samples: Array = []
	var info = null
	# One discarded warm-up. Comparing two runs of IDENTICAL code showed
	# 10-20% "improvements" on every parse stage, which was the OS filesystem
	# cache warming, not the code. Without this the harness reports wins that
	# did not happen.
	if times > 1:
		body.call()
	for i in range(times):
		var t0 := Time.get_ticks_usec()
		info = body.call()
		samples.append(Time.get_ticks_usec() - t0)
	samples.sort()
	var lo: int = samples[0]
	var mid: int = samples[samples.size() / 2]
	results.append({"name": name, "runs": times, "min_us": lo, "med_us": mid,
			"info": info})
	print("  %-16s min %9.2f ms   med %9.2f ms   x%-4d %s"
			% [name, lo / 1000.0, mid / 1000.0, times, info])


func _report() -> void:
	var out := {
		"game": game, "level": level,
		"godot": Engine.get_version_info().get("string", ""),
		"results": results,
	}
	var f := FileAccess.open("res://bench.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, " "))
		f.close()
	print("\nwrote bench.json (%d benchmark(s))" % results.size())
