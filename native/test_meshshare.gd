extends SceneTree

# Does sharing a built mesh between two scopes ever dress one of them wrongly?
#
# mesh_for now returns an already-built ArrayMesh when another scope wanted the
# same MeshSet and its materials came out identical. That is worth 61% of the
# parses on mp_dumbo, and it is exactly the kind of optimisation that is either
# free or produces a map where a few hundred props wear someone else's textures
# — and the second outcome is invisible unless you look for it, because every
# prop still has A material and every material still has A texture.
#
# So this builds EVERY group and checks the strong property directly: for each
# surface of the mesh handed back, the material on it must be the same object
# material_for gives for that group's own scope. Not "looks similar" — the same
# object, which after the content-keyed material cache means the same textures.
#
#   godot --headless --path <proj> --script test_meshshare.gd -- [level] [limit]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var limit := 0
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			limit = int(s)

	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data("")
	var groups: Array = data["props"]
	groups.append_array(data.get("backdrop", []))
	if limit > 0 and groups.size() > limit:
		groups = groups.slice(0, limit)
	print("building %d groups" % groups.size())

	var t0 := Time.get_ticks_msec()
	var built := 0
	var empty := 0
	var surfaces := 0
	var wrong := 0
	var unchecked := 0
	var examples: Array = []
	for g in groups:
		var key := str((g as Dictionary)["mesh"])
		var m: Mesh = gs.mesh_for(key)
		if m == null:
			empty += 1
			continue
		built += 1
		surfaces += m.get_surface_count()
		# THE CHECK. _keys_for holds the merge keys in surface order for this
		# MeshSet, so surface i must carry material_for(keys[i], this scope).
		var parts := key.split("|")
		var scope := str(parts[1]) if parts.size() > 1 else ""
		var kc := "%s#0" % str(parts[0])
		var keys = gs._keys_for.get(kc)
		if not (keys is Array) or (keys as Array).size() != m.get_surface_count():
			unchecked += 1
			continue
		for i in range(m.get_surface_count()):
			var want = gs.material_for(int((keys as Array)[i]), scope)
			var got = m.surface_get_material(i)
			if want != got:
				wrong += 1
				if examples.size() < 5:
					examples.append("%s surface %d: has %s, its scope wants %s"
						% [key, i,
						   "null" if got == null else str(got.get_instance_id()),
						   "null" if want == null else str(want.get_instance_id())])
	var ms := Time.get_ticks_msec() - t0

	print("\n%d built, %d with no geometry, %d surfaces, in %.1f s"
		% [built, empty, surfaces, ms / 1000.0])
	print("   parsed              %d" % int(gs.n_meshes))
	print("   served from another scope %d (%.0f%%)"
		% [int(gs.n_mesh_shared), 100.0 * gs.n_mesh_shared
		   / maxf(1.0, float(gs.n_meshes + gs.n_mesh_shared))])
	print("   sections %d -> surfaces %d (%.2fx merge)"
		% [int(gs.n_sections), int(gs.n_surfaces),
		   float(gs.n_sections) / maxf(1.0, float(gs.n_surfaces))])
	print("   read %.1f s, parse %.1f s, materials %.1f s"
		% [gs.t_res / 1e6, gs.t_parse / 1e6, gs.t_mat / 1e6])
	var ts: Dictionary = gs.tex_stats
	print("   textures: %d decoded, %d reused, %d failed; %d materials"
		% [int(ts.get("decoded", 0)), int(ts.get("reused", 0)),
		   int(ts.get("failed", 0)), int(ts.get("materials", 0))])

	print("\nsurfaces wearing the wrong scope's material: %d" % wrong)
	print("surfaces not checkable (key list length differs): %d group(s)" % unchecked)
	for e in examples:
		print("   %s" % e)
	print("\n%s" % ("PASS" if wrong == 0 else "FAIL"))
	quit(0 if wrong == 0 else 1)
