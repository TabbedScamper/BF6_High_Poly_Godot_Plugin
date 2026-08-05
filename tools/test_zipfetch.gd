extends SceneTree

# Pulling individual props out of the published archive with Range requests,
# instead of downloading the archive and unpacking it.
#
# Runs against the LIVE bucket, because the thing being tested is an agreement
# with a server: that it honours Range, that its zip is laid out the way the
# index says, and that the bytes at those offsets are the file. A mock would
# assert my own assumptions back at me.
#
# What has to be true, in order:
#   1. two ranged reads produce a complete, parseable index
#   2. every entry is STORED and contiguous, so runs coalesce and need no inflate
#   3. planning turns N wanted props into a handful of runs, not N requests
#      (2,761 separate requests earns HTTP 429 from r2.dev; ~16 does not)
#   4. the bytes written are byte-identical to what the archive holds
#   5. what comes out parses as a real mesh
#
# MP_Capstone: the smallest archive, so the test is honest without being slow.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const ZipFetch = preload("res://addons/highpoly_toggle/highpoly_zipfetch.gd")
const BASE := "https://pub-45114dae448e4a059f488662e3d47b19.r2.dev"
const MAP := "MP_Capstone"
const N := 12

var fails := 0


func _init() -> void:
	await process_frame
	var host := Node.new()
	get_root().add_child(host)
	await process_frame

	var url := "%s/maps/%s/props.zip" % [BASE, MAP]
	var zf = ZipFetch.new(host, url)

	# ---- 1. the index ----------------------------------------------------
	var t := Time.get_ticks_msec()
	var entries: Array = await zf.read_index()
	var idx_ms := Time.get_ticks_msec() - t
	print("index: %d entries in %d ms" % [entries.size(), idx_ms])
	_check("the central directory read over Range", entries.size() > 0)
	if entries.is_empty():
		_done(); return

	# ---- 2. the shape the plan depends on --------------------------------
	var stored := 0
	var named := 0
	for e in entries:
		if int(e["method"]) == 0: stored += 1
		if str(e["name"]).ends_with(".glb"): named += 1
	_check("every entry is STORED, so no inflate is needed (%d/%d)"
		% [stored, entries.size()], stored == entries.size())
	_check("entries are named props (%d)" % named, named > 0)

	# ---- 3. planning -----------------------------------------------------
	entries.sort_custom(func(a, b): return int(a["off"]) < int(b["off"]))
	var want: Dictionary = {}
	var picked: Array = []
	# GLBS ONLY. This used to take the next N entries whatever they were, which
	# was the same thing back when an archive held nothing else. A published
	# archive now carries three files per prop — the glb, its .bctex textures
	# and its .geom.res bake — so a blind slice picked mostly sidecars and then
	# failed them for not starting with the glTF magic, which they have no
	# reason to. Four of twelve passed, and it had been red since the format
	# changed this morning.
	var present: Dictionary = {}
	for e in entries:
		present[str(e["name"])] = true
	for e in entries:
		if picked.size() >= N:
			break
		var nm := str(e["name"])
		if not nm.ends_with(".glb"):
			continue
		want[nm] = true
		picked.append(e)
		# AND ITS COMPANIONS, because that is what the client asks for. A prop
		# is three files now and they sit together in the archive, so asking
		# for glbs alone leaves a sidecar-shaped gap between each one and
		# nothing coalesces: 12 props became 12 requests. With the companions
		# they are one contiguous run, which is how Dumbo went from 2,735
		# ranged reads to 110.
		for c in [nm.get_basename() + ".bctex", nm + ".geom.res"]:
			if present.has(c):
				want[c] = true
	var runs: Array = ZipFetch.plan(entries, want)
	var bytes := 0
	for e in picked: bytes += int(e["csize"])
	print("plan: %d props (%.1f MB) -> %d ranged request(s)"
		% [want.size(), bytes / 1048576.0, runs.size()])
	_check("adjacent props coalesce instead of one request each",
		runs.size() < want.size())
	# every wanted entry has to appear in exactly one run, or props go missing
	var covered := {}
	for r in runs:
		for e in (r[2] as Array):
			covered[str(e["name"])] = true
	_check("the plan covers every wanted prop (%d of %d)"
		% [covered.size(), want.size()], covered.size() == want.size())

	# ---- 4. fetch and verify against the archive's own record -------------
	var dest := ProjectSettings.globalize_path("user://zipfetch")
	DirAccess.make_dir_recursive_absolute(dest)
	for e in picked:
		DirAccess.remove_absolute("%s/%s" % [dest, str(e["name"])])
	t = Time.get_ticks_msec()
	var written: int = await zf.fetch(runs, dest)
	var ms: int = maxi(1, Time.get_ticks_msec() - t)
	print("fetch: %d file(s) in %.1f s (%.0f MB/s)"
		% [written, ms / 1000.0, bytes / 1048576.0 / (ms / 1000.0)])
	_check("every wanted prop was written (%d of %d)" % [written, want.size()],
		written == want.size())

	var right_size := 0
	var glb := 0
	for e in picked:
		var p := "%s/%s" % [dest, str(e["name"])]
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		if f.get_length() == int(e["usize"]):
			right_size += 1
		f.seek(0)
		if f.get_32() == 0x46546C67:        # "glTF"
			glb += 1
		f.close()
	_check("each file is exactly the size the archive records (%d/%d)"
		% [right_size, picked.size()], right_size == picked.size())
	_check("and starts with the glTF magic (%d/%d)" % [glb, picked.size()],
		glb == picked.size())

	# ---- 5. and it is a usable prop --------------------------------------
	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.mesh_cache_enabled = false
	var parsed := 0
	for e in picked:
		var r = await mc._parse_prop_file("%s/%s" % [dest, str(e["name"])])
		if r is Array and r.size() > 0 and r[0] != null \
				and (r[0] as Mesh).get_surface_count() > 0:
			parsed += 1
	_check("every fetched prop parses into a mesh (%d/%d)"
		% [parsed, picked.size()], parsed == picked.size())

	# ---- a server that ignores Range must not be trusted ------------------
	# the fetch returns the whole object as HTTP 200 in that case, and buffering
	# gigabytes into RAM would be a far worse failure than falling back
	var bogus = ZipFetch.new(host, "%s/maps/NOPE_NotAMap/props.zip" % BASE)
	var none: Array = await bogus.read_index()
	_check("a missing archive indexes as empty rather than erroring",
		none.is_empty())

	_done()


func _done() -> void:
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
