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

	# THE ITERATION STAGE. The cold sweep is uniform, so 1,500 bundles measure
	# the same rate as 18,533 and take a second instead of twenty. This is what
	# you run while changing the sweep; it reports a PROJECTION, and the name
	# says so, because a projection confirmed by nothing is a guess with a
	# decimal point.
	_bench("mount_rate", repeat, func():
		var s = BF6Source.new()
		s.open(game)
		s.mount(level, Callable(), false, 1500)
		return {"bundles_per_sec": s.stats.get("bundles_per_sec"),
				"projected_full_ms": s.stats.get("projected_full_ms")})

	# The real cold number, once, to keep the projection honest.
	if filter == "" or filter == "mount_cold":
		_bench("mount_cold", 1, func():
			var s = BF6Source.new()
			s.open(game)
			s.mount(level, Callable(), false)
			return {"ebx": s.ebx.size(), "res": s.res.size(),
					"bundles": int(s.stats.get("bundles_opened", 0))})

	_bench("mount_cached", repeat, func():
		var s = BF6Source.new()
		s.open(game)
		s.mount(level)
		return {"ebx": s.ebx.size(), "res": s.res.size(),
				"cached": s.stats.get("from_cache", false)})

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

		# A read that FAILS is instant, so a broken reader benchmarks as a huge
		# win. A stale index cache did exactly that here: every lookup returned
		# zero bytes and the harness reported -97% on get_res_small. Anything
		# measuring a read now asserts it actually got the bytes.
		var want_small := int(_src.res[small][4])
		var probe: PackedByteArray = _src.get_res(small)
		if probe.size() != want_small:
			print("  ABORT: get_res returned %d bytes, expected %d (%s)"
					% [probe.size(), want_small, _src.error])
			print("  the reader is broken; timings would be meaningless")
			quit(1)
			return

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

	_mm_build_bench()
	await _render_bench()
	_report()
	quit(0)


# HOW A MULTIMESH IS FILLED. The plugin calls set_instance_transform() in a
# GDScript loop, 44,925 times per map. Every per-instance accessor makes the
# multimesh "local": it allocates a full CPU float mirror and, if the GPU buffer
# was already written, reads it BACK from the GPU. Assigning the buffer once
# never allocates that mirror.
#
# Same 44,925 transforms, same layout, both ways.
func _mm_build_bench() -> void:
	if filter != "" and not filter.begins_with("mm_"):
		return
	var n := 44925
	# the plugin's stored form: 12 floats, basis ROWS then origin
	var src := PackedFloat32Array()
	src.resize(n * 12)
	for i in range(n):
		var o := i * 12
		src[o] = 1.0; src[o+4] = 1.0; src[o+8] = 1.0
		src[o+9] = float(i % 300) * 3.0
		src[o+10] = 0.0
		src[o+11] = float(i / 300) * 3.0
	var mesh := BoxMesh.new()

	_bench("mm_set_transform", 1, func():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = n
		for i in range(n):
			var o := i * 12
			var t := Transform3D()
			t.basis.x = Vector3(src[o+0], src[o+3], src[o+6])
			t.basis.y = Vector3(src[o+1], src[o+4], src[o+7])
			t.basis.z = Vector3(src[o+2], src[o+5], src[o+8])
			t.origin = Vector3(src[o+9], src[o+10], src[o+11])
			mm.set_instance_transform(i, t)
		return {"instances": n})

	_bench("mm_buffer", 1, func():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = n
		# row-major 3x4. Derived from the stored layout, not guessed:
		# basis.x = (a0,a3,a6), .y = (a1,a4,a7), .z = (a2,a5,a8), so row 0 is
		# (basis.x.x, basis.y.x, basis.z.x, origin.x) = (a0, a1, a2, a9).
		var buf := PackedFloat32Array()
		buf.resize(n * 12)
		for i in range(n):
			var o := i * 12
			buf[o+0] = src[o+0]; buf[o+1] = src[o+1]; buf[o+2] = src[o+2]; buf[o+3] = src[o+9]
			buf[o+4] = src[o+3]; buf[o+5] = src[o+4]; buf[o+6] = src[o+5]; buf[o+7] = src[o+10]
			buf[o+8] = src[o+6]; buf[o+9] = src[o+7]; buf[o+10] = src[o+8]; buf[o+11] = src[o+11]
		mm.buffer = buf
		return {"instances": n})

	# The two must agree, or the faster one is just wrong faster.
	var a := MultiMesh.new()
	a.transform_format = MultiMesh.TRANSFORM_3D
	a.mesh = mesh
	a.instance_count = 3
	for i in range(3):
		var o := i * 12
		var t := Transform3D()
		t.basis.x = Vector3(src[o+0], src[o+3], src[o+6])
		t.basis.y = Vector3(src[o+1], src[o+4], src[o+7])
		t.basis.z = Vector3(src[o+2], src[o+5], src[o+8])
		t.origin = Vector3(src[o+9], src[o+10], src[o+11])
		a.set_instance_transform(i, t)
	var b := MultiMesh.new()
	b.transform_format = MultiMesh.TRANSFORM_3D
	b.mesh = mesh
	b.instance_count = 3
	var bb := PackedFloat32Array()
	bb.resize(36)
	for i in range(3):
		var o := i * 12
		bb[o+0] = src[o+0]; bb[o+1] = src[o+1]; bb[o+2] = src[o+2]; bb[o+3] = src[o+9]
		bb[o+4] = src[o+3]; bb[o+5] = src[o+4]; bb[o+6] = src[o+5]; bb[o+7] = src[o+10]
		bb[o+8] = src[o+6]; bb[o+9] = src[o+7]; bb[o+10] = src[o+8]; bb[o+11] = src[o+11]
	b.buffer = bb
	var same := true
	for i in range(3):
		if not a.get_instance_transform(i).is_equal_approx(b.get_instance_transform(i)):
			same = false
	print("  %-18s buffer layout matches set_instance_transform: %s"
			% ["mm_equivalence", same])
	if not same:
		print("     the buffer packing is WRONG — every prop would be mis-oriented")


# RENDERING STAGES. Everything left to decide — MultiMesh against direct
# RenderingServer instances, occluders, how far mesh_lod_threshold can go — is
# a rendering change, and the reader benchmarks say nothing about any of it.
#
# So: build the SAME geometry two ways in a real viewport and read the engine's
# own counters. The question that matters is not frame time in isolation, it is
# DRAW CALLS, because the engine merges plain MeshInstance3Ds that share
# mesh+material+LOD into one instanced call and never merges MultiMesh.
#
# Runs headless. There is no GPU in a headless run, so frame TIME here is not
# a frame rate — it is CPU-side cull, sort and render-list construction, which
# happens to be exactly the term the MultiMesh question turns on.
func _render_bench() -> void:
	if filter != "" and not filter.begins_with("render"):
		return
	# HEADLESS CANNOT MEASURE THIS. --headless installs RendererDummy, which
	# draws nothing and reports every counter as zero — the first run of this
	# stage returned draw_calls 0 for all three strategies with identical frame
	# times, which reads like "no difference" and actually means "no renderer".
	# bench.py runs the render pass in a windowed Godot for this reason.
	if DisplayServer.get_name() == "headless":
		print("  (render stages skipped: headless has no renderer and reports"
				+ " zero for every counter — run bench.py --render)")
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	var mat := StandardMaterial3D.new()
	mesh.material = mat

	# One layout per strategy, same 8,000 boxes in the same places.
	var n := 8000
	var placements: Array[Transform3D] = []
	var side := int(ceil(sqrt(float(n))))
	for i in range(n):
		var x := float(i % side) * 3.0
		var z := float(i / side) * 3.0
		placements.append(Transform3D(Basis(), Vector3(x, 0.0, z)))

	var root := Node3D.new()
	get_root().add_child(root)
	var cam := Camera3D.new()
	cam.current = true
	# ADD FIRST, THEN AIM. look_at() needs the node in the tree — called before
	# add_child it errors with "Node not inside tree" and leaves the camera at
	# the origin, so the benchmark silently measures a different view than the
	# one it describes.
	root.add_child(cam)
	cam.position = Vector3(side * 1.5, 120.0, side * 1.5 + 200.0)
	cam.look_at(Vector3(side * 1.5, 0.0, side * 1.5))
	cam.far = 4000.0

	# A) one MultiMesh per CELL, which is what the plugin does today
	var a := Node3D.new()
	root.add_child(a)
	var per_cell := 64
	var cells := int(ceil(float(n) / float(per_cell)))
	for c in range(cells):
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		var lo := c * per_cell
		var hi := mini(lo + per_cell, n)
		mm.instance_count = hi - lo
		var buf := PackedFloat32Array()
		buf.resize((hi - lo) * 12)
		var w := 0
		for i in range(lo, hi):
			var t := placements[i]
			# row-major 3x4: basis rows interleaved with origin components
			buf[w] = t.basis.x.x; buf[w+1] = t.basis.y.x; buf[w+2] = t.basis.z.x; buf[w+3] = t.origin.x
			buf[w+4] = t.basis.x.y; buf[w+5] = t.basis.y.y; buf[w+6] = t.basis.z.y; buf[w+7] = t.origin.y
			buf[w+8] = t.basis.x.z; buf[w+9] = t.basis.y.z; buf[w+10] = t.basis.z.z; buf[w+11] = t.origin.z
			w += 12
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		a.add_child(mmi)
	await _settle()
	var ra := await _counters()
	ra["strategy"] = "multimesh_cells"
	ra["nodes"] = cells
	_record("render_multimesh", ra)
	a.queue_free()
	await _settle()

	# B) one MeshInstance3D per prop — the merge path
	var b := Node3D.new()
	root.add_child(b)
	for i in range(n):
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = placements[i]
		b.add_child(mi)
	await _settle()
	var rb := await _counters()
	rb["strategy"] = "meshinstance_nodes"
	rb["nodes"] = n
	_record("render_meshinstance", rb)
	b.queue_free()
	await _settle()

	# C) direct RenderingServer instances — no nodes at all
	var rs := RenderingServer
	var scenario := root.get_world_3d().scenario
	var rids: Array[RID] = []
	for i in range(n):
		var inst := rs.instance_create2(mesh.get_rid(), scenario)
		rs.instance_set_transform(inst, placements[i])
		rids.append(inst)
	await _settle()
	var rc := await _counters()
	rc["strategy"] = "rs_instances"
	rc["nodes"] = 0
	_record("render_rs_direct", rc)
	for r in rids:
		rs.free_rid(r)
	root.queue_free()


func _settle() -> void:
	# Counters are per-frame and the first frame after a scene change is not
	# representative; let it stabilise before reading.
	for _i in range(6):
		await process_frame


func _counters() -> Dictionary:
	var vp := get_root()
	var t0 := Time.get_ticks_usec()
	for _i in range(10):
		await process_frame
	var per_frame := (Time.get_ticks_usec() - t0) / 10.0
	return {
		"draw_calls": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"objects": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_OBJECTS_IN_FRAME),
		"primitives": vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,
				Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME),
		"frame_us": int(per_frame),
	}


func _record(name: String, info: Dictionary) -> void:
	results.append({"name": name, "runs": 1,
			"min_us": int(info.get("frame_us", 0)),
			"med_us": int(info.get("frame_us", 0)), "info": info})
	print("  %-18s %s" % [name, info])


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
