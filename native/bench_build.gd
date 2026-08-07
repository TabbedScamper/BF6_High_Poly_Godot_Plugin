extends SceneTree

# How long it takes to BUILD the scenery, and which tier the time goes to.
#
# Everything benched so far measured either the container reader (how fast game
# bytes become assets) or the renderer (how fast built geometry draws). The
# thing a user actually sits through is neither: it is the build — turning
# thousands of prop files into placed, LOD'd, textured meshes — and it was the
# one path with no numbers at all.
#
# The client can load a prop from three places, and they are NOT close in cost:
#
#   .glb              parse glTF, merge the nodes, generate LODs.   The fallback.
#   .glb.geom.res     the merged, tangent-generated mesh, shipped.  The fast one.
#   .glb.baked2.res   the same thing, but baked on THIS machine on a previous
#                     load. Identical to load; it just did not exist the first
#                     time, which is why the first load of a map is the slow one.
#
# So the interesting number is not "how slow is the build", it is the RATIO
# between those three over the same props — that is what says how much is being
# left on the table by shipping the wrong files.
#
#   godot --path <proj> --script bench_build.gd -- <props dir> [count] [reps]
#
# HEADLESS UNDERSTATES THE GLB TIER. With RendererDummy there is no GPU upload
# and no readback, and those are real costs the editor pays per surface. The
# ratio between tiers survives that (all three place the same surfaces); the
# absolute ms/prop does not. The editor's own figure — breadcrumbs report about
# 50 props/s, i.e. 20 ms/prop — is the one to trust for wall-clock, and this is
# the tool for deciding which tier to spend it on.

const SUFFIX_GEOM := ".geom.res"

# The local sidecar's name carries a generation AND the VRAM mode it was baked
# under (.baked5.res / .baked5f.res / .baked5l.res), because the three hold
# different pixels and must not serve each other. Hardcoding one of them is how
# this bench first reported "0 sidecars" against a directory holding 2,467 of
# them — so it DISCOVERS which is present instead of assuming.
const SUFFIX_SIDE_CANDIDATES := [".baked5.res", ".baked5f.res", ".baked5l.res"]

var _suffix_side := ""


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var dir := str(a[0]) if a.size() > 0 else ""
	var count := int(str(a[1])) if a.size() > 1 else 120
	var reps := int(str(a[2])) if a.size() > 2 else 3
	if dir == "":
		print("usage: bench_build.gd -- <props dir> [count] [reps]")
		quit(2); return

	var props := _pick(dir, count)
	if props.is_empty():
		print("no .glb props under %s" % dir); quit(1); return

	# What is actually on disk beside them. A tier with no files is not a slow
	# tier, it is an ABSENT one, and the two have to read differently or a
	# missing bake looks like a bake that did not help.
	# Whichever sidecar generation/mode this machine actually baked.
	for cand in SUFFIX_SIDE_CANDIDATES:
		for p in props:
			if FileAccess.file_exists(str(p) + cand):
				_suffix_side = cand
				break
		if _suffix_side != "":
			break

	var have := {"glb": props.size(), "geom": 0, "side": 0}
	for p in props:
		if FileAccess.file_exists(p + SUFFIX_GEOM):
			have["geom"] += 1
		if _suffix_side != "" and FileAccess.file_exists(p + _suffix_side):
			have["side"] += 1
	print("props dir   %s" % dir)
	print("sampled     %d prop(s), %d rep(s)" % [props.size(), reps])
	print("on disk     %d glb, %d %s, %d %s"
			% [have["glb"], have["geom"], SUFFIX_GEOM, have["side"],
			   _suffix_side if _suffix_side != "" else "(no sidecar)"])
	if int(have["geom"]) == 0:
		print("            ^ NO SHIPPED BAKE. Every prop falls through to the")
		print("              glTF parser, which is the slowest tier there is.")
	print("")

	var rows: Array = []
	rows.append(_time_tier("glb  (parse glTF + merge + LOD)", props, "", reps))
	if int(have["geom"]) > 0:
		rows.append(_time_tier("geom.res  (shipped bake)", props, SUFFIX_GEOM, reps))
	if int(have["side"]) > 0:
		rows.append(_time_tier("%s  (local sidecar)" % _suffix_side, props,
				_suffix_side, reps))

	print("")
	print("%-34s %10s %10s %10s %9s" % ["tier", "min ms/ea", "median", "MB/s", "surfaces"])
	for r in rows:
		if int(r["ok"]) == 0:
			print("%-34s   nothing loaded — tier unusable" % r["name"])
			continue
		print("%-34s %9.2f %10.2f %10.1f %9d"
				% [r["name"], r["min"], r["median"], r["mbs"], r["surf"]])

	# The number the user feels: this tier, times a whole map.
	if not rows.is_empty():
		print("")
		print("projected over a 2,761-prop map (parse only, no placement/draw)")
		for r in rows:
			if int(r["ok"]) == 0:
				continue
			print("  %-32s %8.1f s" % [r["name"], float(r["min"]) * 2761.0 / 1000.0])
		var base := float(rows[0]["min"])
		for i in range(1, rows.size()):
			var m := float(rows[i]["min"])
			if m > 0.0:
				print("  %-32s %8.2fx faster than glb"
						% [str(rows[i]["name"]).left(32), base / m])

	# Same {name, min_us} shape the reader bench writes, so bench.py's history
	# and comparison work on these rows without knowing anything about them.
	var results: Array = []
	for r in rows:
		if int(r["ok"]) == 0:
			continue
		results.append({"name": "build: " + str(r["name"]).split("  ")[0],
						"min_us": int(float(r["min"]) * 1000.0),
						"median_us": int(float(r["median"]) * 1000.0),
						"props": int(r["ok"]), "surfaces": int(r["surf"])})
	var f := FileAccess.open("res://bench_build.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"level": "props", "results": results,
				"sampled": props.size(), "have": have}))
		f.close()
	quit(0)


# Time one tier over the sample, reps times, reporting the MIN.
#
# Min, not mean: this is CPU-bound and the noise is one-sided — a slow sample
# means something else ran on the machine, it never means the loader got faster.
# The median rides along so an unstable run says so rather than quietly
# reporting its best luck.
func _time_tier(name: String, props: Array, suffix: String, reps: int) -> Dictionary:
	var out := {"name": name, "min": 0.0, "median": 0.0, "mbs": 0.0,
				"surf": 0, "ok": 0}
	var each: Array[float] = []
	var bytes := 0
	var surf := 0
	var ok := 0

	# WARM-UP, DISCARDED. Identical code measured cold then warm reported 10-20%
	# "improvements" that were the filesystem cache and nothing else. The first
	# pass exists to be thrown away.
	_pass(props, suffix)

	for r in range(maxi(1, reps)):
		var t0 := Time.get_ticks_usec()
		var res: Array = _pass(props, suffix)
		each.append((Time.get_ticks_usec() - t0) / 1000.0 / float(props.size()))
		ok = int(res[0])
		surf = int(res[1])
		bytes = int(res[2])

	# ASSERT THE WORK HAPPENED before trusting a timing. A stale cache once made
	# this harness report -97.9% "FASTER" because the read returned zero bytes
	# and the timer faithfully measured nothing.
	if ok == 0 or surf == 0:
		return out
	each.sort()
	out["min"] = each[0]
	out["median"] = each[each.size() / 2]
	out["ok"] = ok
	out["surf"] = surf
	out["mbs"] = (float(bytes) / 1048576.0) / maxf(0.001,
			each[0] * float(props.size()) / 1000.0)
	return out


# -> [loaded, surfaces, bytes]
func _pass(props: Array, suffix: String) -> Array:
	var ok := 0
	var surf := 0
	var bytes := 0
	for p in props:
		var m: Mesh = null
		if suffix == "":
			m = _from_glb(str(p))
			bytes += _size(str(p))
		else:
			var f := str(p) + suffix
			if not FileAccess.file_exists(f):
				continue
			# CACHE_MODE_REPLACE, matching the client. Without it the second rep
			# would hit Godot's resource cache and measure a dictionary lookup.
			m = ResourceLoader.load(f, "Mesh", ResourceLoader.CACHE_MODE_REPLACE)
			bytes += _size(f)
		if m == null:
			continue
		ok += 1
		surf += m.get_surface_count()
	return [ok, surf, bytes]


func _from_glb(path: String) -> Mesh:
	var b := FileAccess.get_file_as_bytes(path)
	if b.is_empty():
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(b, path.get_base_dir(), st) != OK:
		return null
	# ImporterMesh, not generate_scene: the scene path uploads every source mesh
	# to the GPU and exhausts the buffer pool at ~2,000 props in a real editor.
	# The client avoids it for that reason, so the bench has to as well or it
	# would be timing a path nothing runs.
	var im := ImporterMesh.new()
	var added := 0
	for gm in st.get_meshes():
		var src: ImporterMesh = gm.get_mesh()
		if src == null:
			continue
		for s in range(src.get_surface_count()):
			var arr: Array = src.get_surface_arrays(s)
			if arr.size() <= Mesh.ARRAY_INDEX or arr[Mesh.ARRAY_INDEX] == null:
				continue
			if (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() < 3:
				continue
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
					src.get_surface_material(s))
			added += 1
	if added == 0:
		return null
	# The client generates LODs on this path too. Leaving it out here would
	# flatter the glb tier against a .geom.res that already has them baked in.
	im.generate_lods(25.0, 60.0, [])
	return im.get_mesh()


func _size(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


# A deterministic spread across the directory rather than the first N. Props are
# named by prefix, so the first N are all the same KIND of object — sampling
# them would benchmark one building family and call it a map.
func _pick(dir: String, count: int) -> Array:
	var all: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return all
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.ends_with(".glb"):
			all.append(dir.path_join(f))
		f = d.get_next()
	d.list_dir_end()
	all.sort()
	if all.size() <= count:
		return all
	var out: Array = []
	var step := float(all.size()) / float(count)
	for i in range(count):
		out.append(all[int(i * step)])
	return out
