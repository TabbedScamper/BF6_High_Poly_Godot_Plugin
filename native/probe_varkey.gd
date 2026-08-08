extends SceneTree

# WHICH STRING IS THE VARIATION HASH TAKEN OVER?
#
# SHADERS.md §5.2 gives the rule as
#
#     variationStateKey = sectionStateKey + variationAssetNameHash
#
# with `variationAssetNameHash` = "djb2-lower of the ObjectVariation asset path".
# "Asset path" is the part that has to be pinned down: with or without the
# `.ebx`, full path or leaf. Guessing wrong produces a key that resolves nothing,
# which is indistinguishable from the rule being wrong.
#
# The test does not need an oracle. `com_bannerpole_01` has NO depot record for
# its base state key at all, so the only key that CAN dress it is a derived one —
# whichever candidate string produces a hit is the answer, and the others cannot
# produce a hit by luck across many meshes.
#
#   godot --headless --path native/_testproj --script probe_varkey.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6MVDB := preload("res://bf6_mvdb.gd")


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return

	# every distinct (mesh, variation, scope) whose BASE key resolves nothing —
	# these are the ones that must be dressed by a derived key or not at all
	var cands := {}
	for r in gs.walk.rows:
		var rd: Dictionary = r
		if rd.get("var") == null:
			continue
		var k := "%s|%s|%s" % [str(rd["mesh"]), str(rd["var"]), str(rd.get("scope", ""))]
		if not cands.has(k):
			cands[k] = rd

	var forms := {
		"path as recorded": func(p): return p,
		"path minus .ebx": func(p): return str(p).trim_suffix(".ebx"),
		"leaf": func(p): return str(p).get_file(),
		"leaf minus .ebx": func(p): return str(p).get_file().trim_suffix(".ebx"),
		"path with / -> \\": func(p): return str(p).replace("/", "\\"),
	}
	var hits := {}
	for f in forms.keys():
		hits[f] = 0
	var base_ok := 0
	var tested := 0
	var samples: Array = []

	for k in cands.keys():
		if tested >= 400:
			break
		var rd: Dictionary = cands[k]
		var pair = gs._depot_for(str(rd.get("scope", "")))
		if pair == null:
			continue
		var dep: BF6Depot = pair[0]
		var res: String = gs.resolve_mesh(str(rd["mesh"]))
		if res == "":
			continue
		var secs := _keys(gs, res)
		if secs.is_empty():
			continue
		var any_base := false
		for key in secs:
			if dep.key_to_record.has(int(key)):
				any_base = true; break
		if any_base:
			base_ok += 1
			continue                      # already dressed; tells us nothing
		tested += 1
		var ov := str(rd["var"])
		for f in forms.keys():
			var s: String = (forms[f] as Callable).call(ov)
			var vh := BF6MVDB.djb2(s)
			var hit := false
			for key in secs:
				# GDScript's int is signed 64-bit two's complement, so `+` gives
				# the same bit pattern the spec's u64 add would — and the depot
				# is keyed on exactly that pattern.
				if dep.key_to_record.has(int(key) + vh):
					hit = true; break
			if hit:
				hits[f] = int(hits[f]) + 1
				if str(f) == "path minus .ebx" and samples.size() < 6:
					samples.append("%s + %s" % [str(rd["mesh"]).get_file(), s.get_file()])

	print("\n(mesh, variation, scope) groups: %d" % cands.size())
	print("of those, base key already resolves: %d" % base_ok)
	print("tested (base resolves NOTHING, so a derived key is the only hope): %d\n"
		% tested)
	var order: Array = forms.keys()
	order.sort_custom(func(x, y): return int(hits[x]) > int(hits[y]))
	for f in order:
		print("   %-22s resolves %4d of %d  (%.1f%%)"
			% [str(f), int(hits[f]), tested,
			   100.0 * float(hits[f]) / float(maxi(1, tested))])
	for s in samples:
		print("\n      e.g. %s" % s)
	quit(0)


var _c := {}


func _keys(gs, res_name: String) -> Array:
	if _c.has(res_name):
		return _c[res_name]
	var out: Array = []
	var d: PackedByteArray = gs.src.get_res(res_name)
	if not d.is_empty():
		var ms = BF6MeshSet.new()
		var info: Dictionary = ms.parse(d)
		var lods: Array = info.get("lods", [])
		if not lods.is_empty():
			var chunk := PackedByteArray()
			var cid: PackedByteArray = (lods[0] as Dictionary).get("chunk_id",
				PackedByteArray())
			if not cid.is_empty():
				for form in BF6MeshSet.chunk_forms(cid):
					chunk = gs.src.get_chunk(str(form))
					if not chunk.is_empty():
						break
			var secs = ms.read_lod(d, 0, chunk, false)
			if secs is Array:
				for s in secs:
					out.append(int((s as Dictionary).get("state_key", 0)))
	_c[res_name] = out
	return out
