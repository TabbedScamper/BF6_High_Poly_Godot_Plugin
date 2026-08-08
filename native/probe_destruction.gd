extends SceneTree

# THE TWIN-PAIR CULL, checked before it is wired to anything.
#
# The destruction overlays are not separate placements — `dc_` rows are 0 on
# this map, so the DESTRUCTION.md §8 branch stop is already doing its job. The
# deflated tyre, the cracked windscreen and the crushed panel are built INTO the
# intact mesh, tagged per vertex, and the game hides them at spawn.
#
# DESTRUCTION.md §4.3 gives the rule:
#
#   a part is hidden at spawn IFF HealthStateIndex != 0
#   AND an intact (state 0) twin exists for the same PartComponentIndex
#
# The "and" is load-bearing. Culling every non-zero state removes legitimate
# static geometry — pieces whose damaged look IS their authored look.
#
# Four things have to line up and each can fail silently, so each is counted:
#   1. the prop EBX carries PhysicsPartInfos (0x5B95359C) at all
#   2. the MeshSet is Composite or Rigid, not Skinned — a Skinned mesh's
#      BoneIndices is a skeleton bone id, a different space entirely (§4.4)
#   3. the per-vertex part ids decode into the table's range
#   4. the twin-pair rule actually selects something
#
#   godot --headless --path native/_testproj --script probe_destruction.gd -- [level] [pattern]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")
const BF6Ebx := preload("res://bf6_ebx.gd")

const F_PHYSICS_PART_INFOS := 0x5B95359C
const F_HEALTH_STATE := 0x97C633FB
const F_PART_COMPONENT := 0x0723904B
const MESHTYPE_RIGID := 0
const MESHTYPE_SKINNED := 1
const MESHTYPE_COMPOSITE := 2


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var pat := ""
	if a.size() > 0 and str(a[0]) != "": level = str(a[0])
	if a.size() > 1: pat = str(a[1]).to_lower()

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return

	# one row per distinct mesh
	var meshes := {}
	for r in gs.walk.rows:
		var nm := str((r as Dictionary)["mesh"])
		if pat != "" and not nm.to_lower().get_file().contains(pat):
			continue
		if not meshes.has(nm):
			meshes[nm] = true

	var tally := {"no_table": 0, "skinned": 0, "no_parts": 0, "no_twins": 0,
		"culls": 0, "mismatch": 0}
	var shown := 0
	var tri_total := 0
	var tri_culled := 0
	var names: Array = meshes.keys()
	names.sort()
	for nm in names:
		var res: String = gs.resolve_mesh(str(nm))
		if res == "":
			continue

		# The table lives on the OWNING PROP, not the mesh: mesh `X_mesh` is
		# owned by prop `X` in the same folder.
		var info := _parts_table(gs, str(nm))
		if info.is_empty():
			tally["no_table"] = int(tally["no_table"]) + 1
			continue

		var d: PackedByteArray = gs.src.get_res(res)
		if d.is_empty():
			continue
		var ms = BF6MeshSet.new()
		var mi: Dictionary = ms.parse(d)
		if mi.is_empty():
			continue
		var mtype := int(mi.get("mesh_type", -1))
		if mtype == MESHTYPE_SKINNED:
			# §4.4: BoneIndices here is a skeleton bone, not a part. Indexing the
			# part table with it is a category error.
			tally["skinned"] = int(tally["skinned"]) + 1
			continue

		var hidden: Dictionary = info["hidden"]
		if hidden.is_empty():
			tally["no_twins"] = int(tally["no_twins"]) + 1
			continue

		var chunk := PackedByteArray()
		var cid: PackedByteArray = ((mi["lods"] as Array)[0] as Dictionary).get(
			"chunk_id", PackedByteArray())
		if not cid.is_empty():
			for form in BF6MeshSet.chunk_forms(cid):
				chunk = gs.src.get_chunk(str(form))
				if not chunk.is_empty():
					break
		var secs = ms.read_lod(d, 0, chunk, false)
		if not (secs is Array) or (secs as Array).is_empty():
			continue

		var n_parts: int = int(info["count"])
		var tagged := 0
		var untagged := 0
		var oor := 0
		var tris := 0
		var cut := 0
		var seen := {}
		for s in secs:
			var sd: Dictionary = s
			var pv: PackedInt32Array = sd.get("parts", PackedInt32Array())
			var ix: PackedInt32Array = sd["indices"]
			tris += ix.size() / 3
			if pv.is_empty():
				untagged += 1
				continue
			tagged += 1
			for i in range(0, ix.size(), 3):
				var p0 := int(pv[ix[i]]) if ix[i] < pv.size() else -1
				if p0 < 0:
					continue
				seen[p0] = true
				if p0 >= n_parts:
					oor += 1
				elif hidden.has(p0):
					cut += 1
		tri_total += tris
		tri_culled += cut
		if oor > 0:
			tally["mismatch"] = int(tally["mismatch"]) + 1
		if tagged == 0:
			tally["no_parts"] = int(tally["no_parts"]) + 1
			continue
		if cut > 0:
			tally["culls"] = int(tally["culls"]) + 1
		if shown < 18 and (cut > 0 or oor > 0):
			var ks: Array = seen.keys()
			ks.sort()
			print("\n%s" % str(nm).get_file())
			print("   MeshType %d, %d parts in the table, %d hidden by the twin rule"
				% [mtype, n_parts, hidden.size()])
			print("   sections tagged %d / untagged %d, part ids present %s"
				% [tagged, untagged, str(ks.slice(0, 14))])
			print("   triangles %d, of which tagged hidden: %d (%.1f%%)"
				% [tris, cut, 100.0 * float(cut) / float(maxi(1, tris))])
			if oor > 0:
				print("   %d triangles carry a part id past the end of the table"
					% oor)
			shown += 1

	print("\n--- over %d distinct meshes ---" % names.size())
	print("no PhysicsPartInfos on the owning prop: %d" % int(tally["no_table"]))
	print("Skinned (culling disabled by §4.4):     %d" % int(tally["skinned"]))
	print("table present but no twin pairs:        %d" % int(tally["no_twins"]))
	print("table + twins but no per-vertex tags:   %d" % int(tally["no_parts"]))
	print("part id past the end of the table:      %d" % int(tally["mismatch"]))
	print("meshes with geometry to cull:           %d" % int(tally["culls"]))
	print("triangles: %d total, %d hidden (%.2f%%)"
		% [tri_total, tri_culled, 100.0 * float(tri_culled) / float(maxi(1, tri_total))])
	quit(0)


# The owning prop's PhysicsPartInfos -> {count, hidden:{partIndex:true}}.
func _parts_table(gs, mesh_path: String) -> Dictionary:
	var prop := str(mesh_path)
	if prop.to_lower().ends_with(".ebx"):
		prop = prop.substr(0, prop.length() - 4)
	var raw: PackedByteArray = gs.src.get_ebx(prop + ".ebx")
	if raw.is_empty():
		raw = gs.src.get_ebx(prop)
	if raw.is_empty():
		return {}
	var e = BF6Ebx.new(gs.types, gs.walk.gi)
	if not e.parse(raw):
		return {}
	for i in range(e.instance_offsets.size()):
		var inst = e.read_instance(i)
		if not (inst is Dictionary):
			continue
		var t = (inst as Dictionary).get(F_PHYSICS_PART_INFOS)
		if not (t is Array) or (t as Array).is_empty():
			continue
		var rows: Array = t
		# state 0 exists for this PartComponentIndex?
		var intact := {}
		for r in rows:
			if not (r is Dictionary):
				continue
			if int((r as Dictionary).get(F_HEALTH_STATE, -1)) == 0:
				intact[int((r as Dictionary).get(F_PART_COMPONENT, -1))] = true
		var hidden := {}
		for k in range(rows.size()):
			var rd = rows[k]
			if not (rd is Dictionary):
				continue
			var st := int((rd as Dictionary).get(F_HEALTH_STATE, 0))
			var pc := int((rd as Dictionary).get(F_PART_COMPONENT, -1))
			if st != 0 and intact.has(pc):
				hidden[k] = true
		return {"count": rows.size(), "hidden": hidden}
	return {}
