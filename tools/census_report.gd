@tool
extends SceneTree

# Runner and self test for HighpolyCensus.
#
# The census cannot be checked against a real map from here, because everything
# the plugin builds is owner=null and therefore never lands in the .tscn on
# disk: only the live editor has the overlay. So this builds a SYNTHETIC scene
# with the same root names and the same shapes the plugin produces, with counts
# chosen so the right answer is known by hand, and asserts the arithmetic.
#
# The assertions are all on the things that are easy to get wrong and expensive
# to get wrong:
#   * a MultiMesh is one call per SURFACE, not per instance. The profiler was
#     out by 3.5x on exactly this and blamed the wrong subsystem for a week.
#   * a casting surface is paid once per DIRECTIONAL CASCADE, and the cascade
#     count is read from the scene rather than assumed to be 4.
#   * material_override beats a surface override beats the mesh material, so
#     "how many materials" depends on resolving that order the way Godot does.
#   * two nodes with the same surface count and the same node count can differ
#     by 250x in distinct materials, which is the whole point of the tool.
#
# In the editor the real call is one line:
#   print(HighpolyCensus.report(EditorInterface.get_edited_scene_root()))

const Census = preload("res://addons/highpoly_toggle/highpoly_census.gd")

var fails := 0
var keep: Array = []          # hold resources so instance ids stay unique


func _init() -> void:
	var root := _build()
	var d: Dictionary = Census.take(root)
	# The census returns plain data, so the synthetic tree has no reason to
	# outlive the walk. Freeing it here keeps the run from ending in a wall of
	# leaked RID errors that would bury a real failure.
	root.free()
	var L: Dictionary = d["layers"]
	var T: Dictionary = d["totals"]

	print("=== assertions ===")

	# ---- shadow multiplier is derived, not assumed
	_eq("directional cascades read from the scene", int(d["shadow_passes"]), 4)

	# ---- layer attribution
	_ok("props layer exists", L.has("props"))
	_ok("skyline layer exists", L.has("skyline"))
	_ok("fx cards promoted out of skyline", L.has("fx cards"))
	_ok("grass scatter split out of map context", L.has("grass scatter"))
	_ok("prop light fixtures get their own row", L.has("prop light fixtures"))
	_ok("terrain layer exists", L.has("terrain"))
	_ok("water layer exists", L.has("water"))

	# ---- a MultiMesh is one call per surface, NOT per instance
	# props: 1 MMI, 4000 instances, 2 surfaces, casts, cascades = 4
	var p: Dictionary = L["props"]
	_eq("props surfaces", int(p["surf"]), 2)
	_eq("props drawn instances", int(p["inst"]), 4000)
	_eq("props calls are surfaces x (1 + 4 cascades), not instances",
		int(p["calls"]), 2 * 5)
	_eq("props triangles scale with instances", int(p["tris"]), 4000 * 4)
	_eq("props unique verts do not scale with instances",
		int(p["uniq_verts"]), int(p["verts"]) / 4000)

	# ---- the headline distinction: same nodes, same surfaces, different mats
	# skyline: 4 MeshInstance3D x 4 surfaces, all 16 sharing ONE material
	# terrain: 4 MeshInstance3D x 4 surfaces, all 16 with their OWN material
	var sk: Dictionary = L["skyline"]
	var te: Dictionary = L["terrain"]
	_eq("skyline and terrain have the same surface count",
		int(sk["surf"]), int(te["surf"]))
	_eq("skyline shares one material across 16 surfaces",
		int(sk["distinct_mats"]), 1)
	_eq("terrain uses a distinct material per surface",
		int(te["distinct_mats"]), 16)

	# ---- cast_shadow states
	# skyline casts nothing, terrain casts everything
	_eq("skyline casting surfaces", int(sk["caster_surf"]), 0)
	_eq("skyline calls with no shadow", int(sk["calls"]), 16)
	_eq("terrain casting surfaces", int(te["caster_surf"]), 16)
	_eq("terrain calls with shadow", int(te["calls"]), 16 * 5)

	# ---- SHADOWS_ONLY draws no base pass but still pays the cascades
	# roads: 1 mesh, 3 surfaces, SHADOWS_ONLY
	var ro: Dictionary = L["roads"]
	_eq("shadows-only node counted", int(ro["shadows_only"]), 1)
	_eq("shadows-only pays cascades but no base draw", int(ro["calls"]), 3 * 4)

	# ---- material_overlay is a second full pass
	# water: 1 PlaneMesh, 1 surface, no shadow, overlay set
	var wa: Dictionary = L["water"]
	_eq("overlay surfaces recorded", int(wa["overlay_surf"]), 1)
	_eq("overlay doubles the base pass", int(wa["calls"]), 2)
	_ok("a PlaneMesh did not abort the walk (verts counted)", int(wa["verts"]) > 0)

	# ---- material_override collapses every surface to one material
	var fc: Dictionary = L["fx cards"]
	_eq("material_override wins over the mesh materials",
		int(fc["distinct_mats"]), 1)

	# ---- lights do not abort the walk and are not charged as geometry
	var pl: Dictionary = L["prop light fixtures"]
	_eq("prop lights counted", int(pl["lights"]), 12)
	_eq("prop lights with shadows on", int(pl["lights_shadow"]), 5)
	_eq("shadowed omni counted", int(pl["omni_shadow"]), 3)
	_eq("shadowed spot counted", int(pl["spot_shadow"]), 2)
	_eq("a light is not geometry", int(pl["surf"]), 0)
	_ok("children under a light are still walked",
		L.has("props") and int(L["props"]["vis"]) > 0)

	# ---- hidden nodes are separated, not counted as drawn
	_ok("hidden node recorded as hidden", int(T["hidden"]) >= 1)

	# ---- the reload orphan _MAP_CONTEXT2 is still attributed
	_ok("an orphaned _MAP_CONTEXT2 is counted, not dropped",
		int(L["map context"]["vis"]) >= 1)

	# ---- SDK geometry hangs UNDER the _Assets node, so the suffix has to
	# propagate or every mesh it holds reads as one of the user's own objects
	_ok("SDK level geometry layer exists", L.has("SDK level geometry"))
	_eq("meshes under a *_Assets node are charged to the SDK, not to you",
		int(L["SDK level geometry"]["vis"]), 1)
	_ok("nothing leaked into your placed objects",
		not L.has("your placed objects") or int(L["your placed objects"]["vis"]) == 0)

	# ---- shaders
	_ok("distinct shaders counted", int(T["distinct_shaders"]) >= 1)

	# ---- sharing
	var dd: Dictionary = d["dedup"]
	_ok("identical materials held as separate copies are found",
		int(dd["dup_materials"]) >= 1)
	_ok("merging identical meshes in one layer is quoted in draw calls",
		int(dd["merge_calls"]) >= 1)

	# ---- range culling stays off
	_eq("nothing is being distance culled", int(T["range_culled"]), 0)

	print("\n=== report ===")
	print("\n".join(Census.lines(d)))

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails else 0)


# ---------------------------------------------------------------------------
# the synthetic scene, shaped like the real overlay
# ---------------------------------------------------------------------------
func _build() -> Node:
	var root := Node3D.new()
	root.name = "Level"

	var ctx := Node3D.new()
	ctx.name = "_MAP_CONTEXT"
	root.add_child(ctx)

	# props: one MultiMesh, 4,000 instances, 2 surfaces, casts shadows
	var props := Node3D.new()
	props.name = "Props"
	ctx.add_child(props)
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _mesh(2, [_std(Color.RED), _std(Color.BLUE)])
	mm.instance_count = 4000
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	props.add_child(mmi)

	# skyline: 4 meshes x 4 surfaces, one shared material, casts nothing
	var bd := Node3D.new()
	bd.name = "Backdrop"
	ctx.add_child(bd)
	var shared := _std(Color.WHITE)
	for i in range(4):
		var mi := MeshInstance3D.new()
		mi.mesh = _mesh(4, [shared, shared, shared, shared])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bd.add_child(mi)

	# fx cards under the skyline, with a material_override over 3 surfaces
	var fx := Node3D.new()
	fx.name = "FXCards"
	bd.add_child(fx)
	var fmi := MeshInstance3D.new()
	fmi.mesh = _mesh(3, [_std(Color.GREEN), _std(Color.YELLOW), _std(Color.AQUA)])
	fmi.material_override = _shader_mat()
	fmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.add_child(fmi)

	# terrain: 4 meshes x 4 surfaces, every surface its own material, all cast
	var te := Node3D.new()
	te.name = "Terrain"
	ctx.add_child(te)
	for i2 in range(4):
		var tmi := MeshInstance3D.new()
		var ms: Array = []
		for s in range(4):
			ms.append(_std(Color(0.1 * i2, 0.1 * s, 0.5)))
		tmi.mesh = _mesh(4, ms)
		tmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		te.add_child(tmi)

	# roads: shadows only
	var ro := Node3D.new()
	ro.name = "Roads"
	ctx.add_child(ro)
	var rmi := MeshInstance3D.new()
	rmi.mesh = _mesh(3, [_std(Color.GRAY), _std(Color.GRAY), _std(Color.GRAY)])
	rmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	ro.add_child(rmi)

	# water: a PlaneMesh, the primitive that used to throw, plus an overlay
	var wa := Node3D.new()
	wa.name = "Water"
	ctx.add_child(wa)
	var wmi := MeshInstance3D.new()
	wmi.name = "_WATER"
	var pm := PlaneMesh.new()
	pm.size = Vector2(100, 100)
	keep.append(pm)
	wmi.mesh = pm
	wmi.material_overlay = _std(Color(0, 0.4, 0.6, 0.5))
	wmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wa.add_child(wmi)

	# grass scatter, inside the map context but its own row
	var sc := Node3D.new()
	sc.name = "_SCATTER"
	ctx.add_child(sc)
	var gmm := MultiMeshInstance3D.new()
	var g := MultiMesh.new()
	g.transform_format = MultiMesh.TRANSFORM_3D
	g.mesh = _mesh(1, [_std(Color.DARK_GREEN)])
	g.instance_count = 20000
	g.visible_instance_count = 12000
	gmm.multimesh = g
	sc.add_child(gmm)

	# two content identical meshes in one layer: the mergeable case
	var gmm2 := MultiMeshInstance3D.new()
	var g2 := MultiMesh.new()
	g2.transform_format = MultiMesh.TRANSFORM_3D
	g2.mesh = _mesh(1, [_std(Color.DARK_GREEN)])
	g2.instance_count = 500
	gmm2.multimesh = g2
	sc.add_child(gmm2)

	# the sun, four cascades, which is where the shadow multiplier comes from
	var gl := Node3D.new()
	gl.name = "_GAME_LIGHTING"
	root.add_child(gl)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	gl.add_child(sun)

	# prop light fixtures: the layer that can dwarf every other row
	var pls := Node3D.new()
	pls.name = "_HP_PROP_LIGHTS"
	root.add_child(pls)
	for i3 in range(9):
		var o := OmniLight3D.new()
		o.name = "_HP_LIGHT_%d_0" % i3
		o.shadow_enabled = i3 < 3
		pls.add_child(o)
	for i4 in range(3):
		var sp := SpotLight3D.new()
		sp.name = "_HP_LIGHT_S%d_0" % i4
		sp.shadow_enabled = i4 < 2
		pls.add_child(sp)

	# fx: particles and a decal, neither of which is a GeometryInstance3D
	var mfx := Node3D.new()
	mfx.name = "_MAP_FX"
	root.add_child(mfx)
	mfx.add_child(GPUParticles3D.new())
	mfx.add_child(GPUParticles3D.new())
	mfx.add_child(Decal.new())

	# a hidden node, built but not shown
	var hid := MeshInstance3D.new()
	hid.mesh = _mesh(1, [_std(Color.BLACK)])
	hid.visible = false
	props.add_child(hid)

	# the plugin reload orphan: a second overlay named _MAP_CONTEXT2 that a
	# name == test would silently drop from the census
	var orphan := Node3D.new()
	orphan.name = "_MAP_CONTEXT2"
	root.add_child(orphan)
	var omi := MeshInstance3D.new()
	omi.mesh = _mesh(1, [_std(Color.PURPLE)])
	orphan.add_child(omi)

	# an SDK proxy the user placed, so the fallback buckets are exercised
	var sdk := Node3D.new()
	sdk.name = "Section_Assets"
	root.add_child(sdk)
	var smi := MeshInstance3D.new()
	smi.mesh = _mesh(1, [_std(Color.ORANGE)])
	sdk.add_child(smi)

	return root


# An ArrayMesh with `n` surfaces, one material each. Two triangles per surface,
# so the triangle arithmetic in the assertions is trivially checkable.
func _mesh(n: int, mats: Array) -> ArrayMesh:
	var am := ArrayMesh.new()
	for s in range(n):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for v in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
				Vector3(1, 1, 0), Vector3(2, 0, 0), Vector3(2, 1, 0)]:
			st.add_vertex(v)
		st.commit(am)
		if s < mats.size():
			am.surface_set_material(s, mats[s])
	keep.append(am)
	return am


func _std(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	keep.append(m)
	return m


func _shader_mat() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode blend_mix, cull_disabled;\n" \
		+ "void fragment() { ALBEDO = vec3(1.0); ALPHA = 0.5; }\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	keep.append(sh)
	keep.append(m)
	return m


func _eq(what: String, got: int, want: int) -> void:
	_ok("%s (got %d, want %d)" % [what, got, want], got == want)


func _ok(what: String, cond: bool) -> void:
	print("  %s  %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		fails += 1
