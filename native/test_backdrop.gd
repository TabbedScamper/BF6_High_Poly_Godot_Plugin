extends SceneTree

# Is the skyline already in the walk, or does it need extracting separately?
#
# The packaged download splits a map into `props` and `backdrop`, and the
# backdrop is 1,247 MB of Dumbo's 1,292 MB map-specific payload — the second
# largest thing after the shared prop store. If those meshes are already among
# the walk's 48,126 rows then the skyline needs only CLASSIFICATION, and the
# reader gets the second-biggest chunk of the download nearly free. If they are
# not, it needs its own extraction path.
#
# That is a data question with a cheap answer, so it gets asked before anything
# is built on either assumption.
#
# Compares the packaged placements.json's `backdrop` list against the meshes the
# walk produces, and reports what the overlap actually is.
#
#   godot --headless --path <proj> --script test_backdrop.gd -- <placements.json> [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Walk := preload("res://bf6_walk.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var pj := ""
	var level := "mp_dumbo"
	var seen := false
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if not seen:
			pj = s
			seen = true
		else:
			level = s
	if pj == "":
		print("usage: test_backdrop.gd -- <placements.json> [level]")
		quit(2); return

	var f := FileAccess.open(pj, FileAccess.READ)
	if f == null:
		print("FAIL cannot read %s" % pj)
		quit(1); return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if not (d is Dictionary):
		print("FAIL placements.json is not an object")
		quit(1); return
	var bd: Array = (d as Dictionary).get("backdrop", [])
	var pr: Array = (d as Dictionary).get("props", [])
	print("packaged: %d backdrop entries, %d prop entries" % [bd.size(), pr.size()])
	if bd.is_empty():
		print("nothing to compare")
		quit(1); return

	# The packaged entries name a FILE STEM (or a glb), the walk names a
	# blueprint. Compare on the basename with any _mesh suffix removed, which is
	# the only spelling the two can share.
	var want := {}
	var bd_inst := 0
	for e in bd:
		var ed: Dictionary = e
		var nm := str(ed.get("mesh", ed.get("glb", ""))).to_lower()
		nm = nm.get_file()
		for suf in [".glb", ".ebx"]:
			if nm.ends_with(suf):
				nm = nm.substr(0, nm.length() - suf.length())
		if nm.ends_with("_mesh"):
			nm = nm.substr(0, nm.length() - 5)
		if nm != "":
			want[nm] = int(want.get(nm, 0)) + 1
		var xf = ed.get("xf", [])
		bd_inst += int((xf as Array).size() / 12) if xf is Array else 0
	print("          %d distinct backdrop meshes, %d instances" % [want.size(), bd_inst])

	var src = BF6Source.new()
	if not src.open():
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return
	var types = BF6Types.new()
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			types.open(c)
			break
	var w = BF6Walk.new(src, types)
	w.build_catalog()
	if not w.run_cached(level):
		print("FAIL walk"); quit(1); return

	var have := {}
	for r in w.rows:
		var nm2 := str((r as Dictionary)["mesh"]).to_lower().get_file()
		if nm2.ends_with(".ebx"):
			nm2 = nm2.substr(0, nm2.length() - 4)
		have[nm2] = int(have.get(nm2, 0)) + 1
	print("walk:     %d rows, %d distinct mesh names\n" % [w.rows.size(), have.size()])

	var hit := 0
	var hit_inst := 0
	var miss: Array = []
	for nm3 in want:
		if have.has(nm3):
			hit += 1
			hit_inst += int(want[nm3])
		else:
			miss.append(nm3)
	print("IN THE WALK   %d of %d backdrop meshes (%.1f%%), covering %d of %d "
		% [hit, want.size(), 100.0 * hit / maxf(1.0, float(want.size())),
		   hit_inst, bd_inst] + "packaged instances")
	print("MISSING       %d" % miss.size())
	for m in miss.slice(0, 15):
		print("   %s" % m)

	# Do the ones that ARE present resolve to geometry? A name appearing in the
	# walk is not the same as a MeshSet existing for it, and the skyline is
	# exactly where "the name is there but the mesh is not" would bite.
	# Indexed ONCE by basename. Scanning all 160,689 res names per mesh would be
	# ~16 million string builds to answer a question about a hundred names.
	var res_leaf := {}
	for rn in src.res.keys():
		res_leaf[str(rn).get_file()] = true
	var res_ok := 0
	for nm4 in want:
		if not have.has(nm4):
			continue
		if res_leaf.has(nm4 + "_mesh") or res_leaf.has(nm4):
			res_ok += 1
	print("\nRESOLVE       %d of the %d present also have a MeshSet" % [res_ok, hit])

	# HOW WOULD WE TELL THEM APART? Knowing the skyline is in the walk is only
	# useful if a rule separates it from the props, so this reports where those
	# rows come from. If backdrop rows share a scope or a source partition that
	# prop rows do not, that IS the classifier and it costs nothing.
	var bd_scope := {}
	var pr_scope := {}
	var bd_src := {}
	for r in w.rows:
		var nm5 := str((r as Dictionary)["mesh"]).to_lower().get_file()
		if nm5.ends_with(".ebx"):
			nm5 = nm5.substr(0, nm5.length() - 4)
		var sc := str((r as Dictionary).get("scope", ""))
		if want.has(nm5):
			bd_scope[sc] = int(bd_scope.get(sc, 0)) + 1
			var sr := str((r as Dictionary).get("src", ""))
			bd_src[sr] = int(bd_src.get(sr, 0)) + 1
		else:
			pr_scope[sc] = int(pr_scope.get(sc, 0)) + 1

	print("\nSCOPES carrying backdrop rows:")
	var bk: Array = bd_scope.keys()
	bk.sort_custom(func(p, q): return int(bd_scope[p]) > int(bd_scope[q]))
	for k in bk.slice(0, 8):
		# The count of PROP rows in the same scope is what decides whether the
		# scope is a classifier or merely a place the backdrop happens to live.
		print("   %-58s %5d backdrop, %5d other"
			% [str(k).left(58) if str(k) != "" else "(none)", int(bd_scope[k]),
			   int(pr_scope.get(k, 0))])
	print("\nSOURCE partitions carrying backdrop rows:")
	var sk: Array = bd_src.keys()
	sk.sort_custom(func(p, q): return int(bd_src[p]) > int(bd_src[q]))
	for k in sk.slice(0, 8):
		print("   %-58s %5d" % [str(k).left(58), int(bd_src[k])])

	# EVERY backdrop row comes from the level ROOT partition, which also carries
	# 51 rows that are not backdrop — so "from the level root" is 75% precise and
	# not yet a rule. MAP_LOADING 6.6 and this walker's own note both say vista
	# instancing sits directly in the level root as StaticModelGroups, so `kind`
	# is the obvious second half of the test.
	var root_src := ""
	if not sk.is_empty():
		root_src = str(sk[0])
	var by_kind := {}
	for r in w.rows:
		if str((r as Dictionary).get("src", "")) != root_src:
			continue
		var nm6 := str((r as Dictionary)["mesh"]).to_lower().get_file()
		if nm6.ends_with(".ebx"):
			nm6 = nm6.substr(0, nm6.length() - 4)
		var kd := str((r as Dictionary).get("kind", "?"))
		var key := "%s|%s" % [kd, "backdrop" if want.has(nm6) else "other"]
		by_kind[key] = int(by_kind.get(key, 0)) + 1
	print("\nRows from the level root, by kind:")
	var kk: Array = by_kind.keys()
	kk.sort()
	for k in kk:
		print("   %-22s %d" % [k, int(by_kind[k])])
	quit(0)
