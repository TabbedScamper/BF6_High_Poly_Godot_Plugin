extends SceneTree

# Does the same mesh, placed from two subworlds, actually get two different
# looks?
#
# map_data groups placements by (mesh, scope) because a section's shader state
# key is only unique within a scope, and folding two scopes together would dress
# half the placements from the wrong depot. That is the correct conservative
# choice and it has a price: mp_dumbo has 2,727 distinct meshes and 5,498
# groups, so on average every MeshSet is read from the CAS, parsed and turned
# into an ArrayMesh TWICE, and the whole-map build is 203 s.
#
# The price is only worth paying where the answer differs. If a mesh's sections
# resolve to the same textures in every scope that places it, that mesh can be
# built once — and this measures how often that is true rather than assuming it
# either way. A guess in either direction is expensive: assume they agree and
# props get dressed wrongly, assume they differ and the build stays at 2x.
#
#   godot --headless --path <proj> --script test_scopedup.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	for x in a:
		if str(x) != "":
			level = str(x)
			break

	var gs = HighpolyGameSource.new()
	gs.build_materials = false          # the textures are resolved by hand below
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data("")
	var groups: Array = data["props"]
	print("%d groups over %d placements" % [groups.size(), gs.walk.rows.size()])

	# mesh res name -> {scope: true}
	var scopes_of := {}
	for g in groups:
		var key := str((g as Dictionary)["mesh"])
		var parts := key.split("|")
		if parts.size() < 2:
			continue
		var m := str(parts[0])
		if not scopes_of.has(m):
			scopes_of[m] = {}
		(scopes_of[m] as Dictionary)[str(parts[1])] = true

	var multi := 0
	for m in scopes_of:
		if (scopes_of[m] as Dictionary).size() > 1:
			multi += 1
	print("meshes: %d distinct, %d placed from more than one scope"
		% [scopes_of.size(), multi])

	# For each multi-scope mesh, resolve every section's texture set in every
	# scope and compare. The comparison is on the RESOLVED SLOTS, not on the
	# state key: two scopes can spell the same look with different keys, and it
	# is the look that decides whether one mesh can serve both.
	var same := 0
	var differ := 0
	var unresolved := 0
	var checked := 0
	var examples: Array = []
	for m in scopes_of:
		var sc: Dictionary = scopes_of[m]
		if sc.size() < 2:
			continue
		checked += 1
		var sig_by_scope: Array = []
		for s in sc:
			sig_by_scope.append(_look_of(gs, str(m), str(s)))
		var first := str(sig_by_scope[0])
		var all_same := true
		for s2 in sig_by_scope:
			if str(s2) != first:
				all_same = false
				break
		if first == "?":
			unresolved += 1
		elif all_same:
			same += 1
		else:
			differ += 1
			if examples.size() < 6:
				examples.append("%s: %s" % [str(m).get_file(),
					" | ".join(PackedStringArray(sig_by_scope)).substr(0, 150)])

	print("\nof %d meshes placed from several scopes:" % checked)
	print("   identical look in every scope : %d" % same)
	print("   genuinely different           : %d" % differ)
	print("   nothing resolved in any scope : %d" % unresolved)
	if not examples.is_empty():
		print("\n   examples that differ:")
		for e in examples:
			print("      %s" % e)

	# What collapsing the identical ones would actually save.
	var saved := 0
	for m in scopes_of:
		var n: int = (scopes_of[m] as Dictionary).size()
		if n > 1:
			saved += n - 1
	print("\n%d of %d groups are repeats of a mesh already built (%.0f%%)"
		% [saved, groups.size(), 100.0 * saved / maxi(groups.size(), 1)])
	quit(0)


# A stable string for what one mesh looks like under one scope: every section's
# resolved slot -> texture, in section order. "?" when nothing resolved at all.
func _look_of(gs, res_name: String, scope: String) -> String:
	var d: PackedByteArray = gs.src.get_res(res_name)
	if d.is_empty():
		return "?"
	var ms := BF6MeshSet.new()
	var info := ms.parse(d)
	if info.is_empty():
		return "?"
	var chunk := PackedByteArray()
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return "?"
	var cid: PackedByteArray = (lods[0] as Dictionary).get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = gs.src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	var secs = ms.read_lod(d, 0, chunk, false)
	if not (secs is Array):
		return "?"
	var pair = gs._depot_for(scope)
	if pair == null:
		return "?"
	var dep = pair[0]
	var out: Array = []
	var any := false
	for s in secs:
		var k := int((s as Dictionary).get("state_key", 0))
		if k == 0 or not dep.key_to_record.has(k):
			out.append("-")
			continue
		var slots: Dictionary = dep.textures_for(k, pair[1])
		slots.erase("constants")
		var keys: Array = slots.keys()
		keys.sort()
		var bits: Array = []
		for sk in keys:
			bits.append("%s=%s" % [sk, str(slots[sk]).substr(0, 8)])
		out.append(",".join(PackedStringArray(bits)))
		any = true
	return ";".join(PackedStringArray(out)) if any else "?"
