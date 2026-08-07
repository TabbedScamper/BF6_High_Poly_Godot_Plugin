extends SceneTree

# The rest of the chain: placement -> depot -> texture guid -> Image.
#
# Everything up to the depot is verified against Python. What is NOT verified,
# and cannot be by comparing to Python, is whether the pieces JOIN over a real
# map: which depot holds a given section's key, whether a texture's file guid
# resolves to an asset, and whether that asset decodes. Each is a coverage
# question, and a low number on any one of them means textured props with holes.
#
# DEPOT SCOPING IS THE RISKY PART. A StateKey is unique only within a scope, so
# a global lookup across every depot in the mount will happily bind a
# confidently WRONG texture — the shared research repo states the rule as:
# widen to ANCESTORS ONLY, never a sibling subworld. So the search here walks up
# from the placing bundle's own directory and stops, and the report says how far
# it had to go. If most sections resolve only at the level root, the scoping is
# not doing what it claims.
#
#   godot --headless --path <proj> --script test_textures.gd -- <level> [meshes]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Walk := preload("res://bf6_walk.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6Texture := preload("res://bf6_texture.gd")

const SHADERSTATE := "_win32_shaderstate/"

var src
var _depot_dirs := {}          # bundle dir (lower) -> depot res name
var _depot_cache := {}         # depot res name -> [BF6Depot, bytes]


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var want := 40
	var seen := false
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if s.is_valid_int():
			want = int(s)
		elif not seen:
			level = s
			seen = true

	src = BF6Source.new()
	if not src.open():
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return
	var types = BF6Types.new()
	var exe := ""
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			exe = c
			break
	if exe == "" or not types.open(exe):
		print("FAIL types: %s" % types.error); quit(1); return

	var w = BF6Walk.new(src, types)
	w.build_catalog()

	# Depot bundle index: "<bundle>_win32_shaderstate/shaderblockdepot_N" ->
	# "<bundle>", where <bundle> is the BUNDLE ASSET path, not its directory.
	for rn in src.res.keys():
		var n := str(rn)
		var at := n.find(SHADERSTATE)
		if at > 0 and n.find("shaderblockdepot", at) > 0:
			_depot_dirs[n.substr(0, at)] = n
	print("DEPOTS    %d bundles carry one" % _depot_dirs.size())

	# Handed to the walk BEFORE it runs, so each row records the depot scope it
	# was placed under. This is the fix for the 45% of sections that resolved
	# nowhere: their depot belongs to the subworld that mounted the prefab, which
	# is an ancestor in the WALK GRAPH and has no path relationship to the
	# partition the placement sits in.
	for d in _depot_dirs:
		w.scope_index[str(d)] = str(d)
	if not w.run_cached(level):
		print("FAIL walk"); quit(1); return
	var gi: Dictionary = w.gi
	var scoped := 0
	for r in w.rows:
		if str((r as Dictionary).get("scope", "")) != "":
			scoped += 1
	print("%d rows, %d partition guids, %d rows carry a depot scope (%.1f%%)\n"
		% [w.rows.size(), gi.size(), scoped,
		   100.0 * scoped / maxf(1.0, float(w.rows.size()))])

	# THE MOST-PLACED MESHES, not the first ones the walk happens to emit.
	#
	# Taking rows in walk order sampled the gameplay layers the traversal visits
	# first — combat areas, key events, killcam props — which have no art depot
	# and reported 12.1% coverage for a chain that was working. A coverage number
	# is only meaningful over the geometry the map is actually made of, so this
	# weights by instance count.
	var counts := {}
	var first_src := {}
	for r in w.rows:
		var row: Dictionary = r
		var mp := str(row["mesh"]).to_lower()
		if mp.ends_with(".ebx"):
			mp = mp.substr(0, mp.length() - 4)
		var res_name := ""
		for cand in [mp + "_mesh", mp]:
			if src.res.has(cand):
				res_name = cand
				break
		if res_name == "":
			continue
		counts[res_name] = int(counts.get(res_name, 0)) + 1
		if not first_src.has(res_name):
			first_src[res_name] = str(row["src"])
	var ranked: Array = counts.keys()
	ranked.sort_custom(func(x, y): return int(counts[x]) > int(counts[y]))
	var top := {}
	for i in range(mini(want, ranked.size())):
		top[ranked[i]] = true
	print("SAMPLE    %d meshes, %d..%d placements each"
		% [top.size(), int(counts[ranked[0]]),
		   int(counts[ranked[mini(want, ranked.size()) - 1]])])

	# PER (MESH, PLACING BUNDLE), not one representative bundle per mesh.
	#
	# This is the distinction the shared research repo has open as
	# `sbd-placing-bundle-rule-contested`: the original "zero miss" measurement
	# used one bundle per mesh, but most meshes are placed from several, and a
	# StateKey only has to exist in the scope that placed it. Keeping each
	# placement's OWN bundle is the measurement that settles it.
	var per_mesh := {}
	for r in w.rows:
		var row2: Dictionary = r
		var mp2 := str(row2["mesh"]).to_lower()
		if mp2.ends_with(".ebx"):
			mp2 = mp2.substr(0, mp2.length() - 4)
		var rn2 := ""
		for cand in [mp2 + "_mesh", mp2]:
			if src.res.has(cand):
				rn2 = cand
				break
		if rn2 == "" or not top.has(rn2):
			continue
		# Keyed on the row's own SCOPE now, not its src: the scope is what the
		# depot lookup will actually use, so that is the axis worth sampling.
		var sc := str(row2.get("scope", ""))
		per_mesh["%s|%s" % [rn2, sc]] = [rn2, str(row2["src"]), sc]
	print("          %d distinct (mesh, placing bundle) pairs" % per_mesh.size())

	var ms := BF6MeshSet.new()
	var sec_total := 0
	var sec_hit := 0
	var depth_hist := {}
	var tex_refs := 0
	var tex_named := 0
	var tex_res := 0
	var unnamed: Array = []
	var no_res: Array = []
	var want_tex := {}                    # res name -> true, for the decode pass

	var no_chain := 0
	var key_absent := 0
	for pair_key in per_mesh:
		var pr: Array = per_mesh[pair_key]
		var res_name := str(pr[0])
		var md: PackedByteArray = src.get_res(res_name)
		if md.is_empty():
			continue
		var info := ms.parse(md)
		if info.is_empty():
			continue
		var lods: Array = info.get("lods", [])
		if lods.is_empty():
			continue
		# THE WALK'S SCOPE FIRST, then path ancestry as a fallback so the two can
		# be told apart in the histogram: depth 0 is the scope the walk recorded,
		# anything deeper is the old directory guess still doing the work.
		var chain: Array = []
		if str(pr[2]) != "":
			chain.append(str(pr[2]))
		for d in _scope_chain(str(pr[1])):
			if not chain.has(d):
				chain.append(d)
		for s in (lods[0] as Dictionary).get("sections", []):
			var sec: Dictionary = s
			var key := int(sec["state_key"])
			sec_total += 1
			var found := -1
			var dep = null
			var dbytes := PackedByteArray()
			for di in range(chain.size()):
				var pair = _depot(str(chain[di]))
				if pair == null:
					continue
				if (pair[0] as BF6Depot).key_to_record.has(key):
					found = di
					dep = pair[0]
					dbytes = pair[1]
					break
			depth_hist[found] = int(depth_hist.get(found, 0)) + 1
			if found < 0:
				# THE TWO WAYS TO MISS ARE DIFFERENT PROBLEMS. An empty chain
				# means no depot was found anywhere above this placement — a
				# scoping/naming gap on our side. A searched chain that did not
				# hold the key is the real "key absent in scope" number, and is
				# the one worth reporting to anyone else.
				if chain.is_empty():
					no_chain += 1
				else:
					key_absent += 1
				continue
			sec_hit += 1
			var tex: Dictionary = dep.textures_for(key, dbytes)
			tex.erase("constants")
			for slot in tex:
				tex_refs += 1
				var g := str(tex[slot])
				var asset = gi.get(g)
				if asset == null:
					if unnamed.size() < 5:
						unnamed.append("%s %s" % [slot, g])
					continue
				tex_named += 1
				var an := str(asset)
				if an.to_lower().ends_with(".ebx"):
					an = an.substr(0, an.length() - 4)
				if src.res.has(an.to_lower()):
					tex_res += 1
					want_tex[an.to_lower()] = true
				elif no_res.size() < 5:
					no_res.append(an)

	print("\nSECTIONS  %d of %d found a depot in scope (%.1f%%)"
		% [sec_hit, sec_total, 100.0 * sec_hit / maxf(1.0, float(sec_total))])
	var keys: Array = depth_hist.keys()
	keys.sort()
	for d in keys:
		print("   %-22s %d" % ["not found" if int(d) < 0
			else ("own bundle" if int(d) == 0 else "ancestor +%d" % int(d)),
			int(depth_hist[d])])
	print("   of the misses: %d had NO depot on any ancestor, %d were searched "
		% [no_chain, key_absent] + "and the key was absent")

	print("\nTEXTURE REFS  %d total" % tex_refs)
	print("   guid -> asset   %d (%.1f%%)"
		% [tex_named, 100.0 * tex_named / maxf(1.0, float(tex_refs))])
	print("   asset -> res    %d (%.1f%%)"
		% [tex_res, 100.0 * tex_res / maxf(1.0, float(tex_refs))])
	for u in unnamed:
		print("      unresolved guid: %s" % u)
	for n in no_res:
		print("      no res for: %s" % n)

	# ---- decode ------------------------------------------------------------
	var tex := BF6Texture.new()
	var names: Array = want_tex.keys()
	var n_try: int = mini(40, names.size())
	var dec_ok := 0
	var dec_bad := 0
	var px := 0
	var t0 := Time.get_ticks_msec()
	for i in range(n_try):
		var td: PackedByteArray = src.get_res(str(names[i]))
		if td.is_empty():
			dec_bad += 1
			continue
		var img := tex.decode(td, func(form): return src.get_chunk(str(form)))
		if img.is_empty():
			dec_bad += 1
			if dec_bad <= 4:
				print("      decode failed %s: %s"
					% [str(names[i]).get_file(), tex.error])
			continue
		dec_ok += 1
		px += int(img["width"]) * int(img["height"])
	print("\nDECODE    %d of %d sampled, %d failed, %.1f ms each, %.1f Mpx total"
		% [dec_ok, n_try, dec_bad,
		   float(Time.get_ticks_msec() - t0) / maxf(1.0, float(n_try)),
		   px / 1048576.0])

	var ok: bool = sec_total > 0 and float(sec_hit) / float(sec_total) > 0.85 \
		and tex_refs > 0 and float(tex_res) / float(tex_refs) > 0.85 \
		and dec_ok > 0 and float(dec_ok) / maxf(1.0, float(n_try)) > 0.85
	print("\n%s" % ("PASS — the chain joins end to end"
		if ok else "FAIL — see the coverage above"))
	quit(0 if ok else 1)


# Placing bundle first, then its ANCESTORS, nearest first. Never a sibling: a
# StateKey is unique only within a scope, and a sibling subworld that happens to
# carry the same key would bind the wrong texture with no sign anything is wrong.
func _scope_chain(src_ebx: String) -> Array:
	var p := src_ebx.to_lower()
	if p.ends_with(".ebx"):
		p = p.substr(0, p.length() - 4)
	var out: Array = []
	var dir := p.get_base_dir()
	while dir != "" and dir.contains("/"):
		# A DEPOT IS NAMED AFTER ITS BUNDLE ASSET, NOT ITS DIRECTORY. The res is
		# "<bundle>_win32_shaderstate/shaderblockdepot_<n>", and a bundle asset
		# lives at "<dir>/<dir name>.ebx" with its members beside it in "<dir>/".
		# So the depot for everything in ".../strikepoint/" is keyed
		# ".../strikepoint/strikepoint" — appending the directory's own name.
		#
		# Matching on the bare directory found 0 of 273 sections while 15,391
		# depots were indexed, which is what sent me to print the strings rather
		# than keep adjusting the rule.
		var leaf := dir.get_file()
		if leaf != "" and _depot_dirs.has(dir + "/" + leaf):
			out.append(dir + "/" + leaf)
		if _depot_dirs.has(dir):
			out.append(dir)
		dir = dir.get_base_dir()
	return out


func _depot(dir: String):
	if _depot_cache.has(dir):
		return _depot_cache[dir]
	var name = _depot_dirs.get(dir)
	if name == null:
		_depot_cache[dir] = null
		return null
	var b: PackedByteArray = src.get_res(str(name))
	if b.is_empty():
		_depot_cache[dir] = null
		return null
	var d = BF6Depot.new()
	if not d.parse(b):
		_depot_cache[dir] = null
		return null
	_depot_cache[dir] = [d, b]
	return _depot_cache[dir]
