@tool
extends RefCounted
class_name HighpolyCensus
# A STRUCTURAL census of what the frame budget is being spent on.
#
# highpoly_profiler.gd samples the frame over time and attributes it to a
# subsystem. This does the complementary half: one deep walk of the built
# scene that answers WHY a layer costs what it costs, in terms of the things
# the GPU actually charges for.
#
# DISTANCE CULLING IS DELIBERATELY OFF in this tool's world view. The range
# slider sits at maximum on purpose because the target is a steady 60 fps with
# EVERYTHING visible at once, so this counts everything that is visible in the
# tree and never quietly drops far geometry. It does report how many nodes
# WOULD have been range culled, purely as a check that culling really is off:
# a non zero number there means something is culling when it should not be.
#
# WHAT THIS MEASURES THAT NODE COUNTS DO NOT
#
#   surfaces          One draw call per surface, per instance batch. A
#                     MultiMesh with 4,000 instances and one surface is ONE
#                     call; a 2 instance node with five surfaces is five.
#                     Node counts are therefore close to meaningless.
#
#   distinct materials Godot binds a material per surface batch. 1,000 props
#                     sharing 4 materials and 1,000 props with 1,000 materials
#                     have the same node count, the same surface count and
#                     wildly different real cost, because the second one cannot
#                     be batched and pays a bind per surface. The ratio
#                     surfaces / distinct materials is the batching efficiency
#                     and it is printed for every layer.
#
#   distinct shaders  A material swap inside one shader is a uniform set
#                     rebind. A shader swap is a pipeline switch, which is the
#                     expensive one. Counted separately for that reason.
#
#   shadow casters    A casting surface is paid again once per shadow pass.
#                     The multiplier is NOT hardcoded here: it is derived from
#                     the shadowed DirectionalLight3D cascade counts actually
#                     present in the scene, so turning the sun's shadow off
#                     shows up in this report instead of being assumed away.
#
#   shadowed local lights
#                     Every shadow casting OmniLight3D is a cube map, six
#                     renders of everything inside its radius. SpotLight3D is
#                     one. These are counted per layer because a few thousand
#                     prop light fixtures with shadows left on outweighs every
#                     other line in the report combined.
#
#   sharing potential Identical meshes and identical materials that exist as
#                     separate resources. The saving is quoted in DRAW CALLS,
#                     not in resource count, because resource count is not what
#                     the frame is paying.
#
# COST MODEL, stated so it can be argued with
#
#   base calls   = surfaces, except for SHADOWS_ONLY nodes which draw none
#   overlay      = + surfaces again for any node with a material_overlay,
#                  because an overlay is a second full pass over the surface
#   shadow calls = casting surfaces x directional cascades in the scene
#   local shadow = shadowed omni x 6 + shadowed spot x 1, times the casters
#                  inside each radius, which is NOT resolved here (see the
#                  caveat printed with the light table)
#
# CAVEAT ON DUPLICATE DETECTION. Two resources count as identical when their
# stored properties match, with sub resources compared by resource path when
# they have one and by identity when they do not. Two separately generated
# textures with identical pixels therefore read as different. That makes the
# sharing numbers a LOWER BOUND on what could be shared, never an overstatement.

const Prof = preload("highpoly_profiler.gd")

# Injected roots, in attribution order. A node is charged to the FIRST root it
# sits under. Matched with contains(), not ==, because a plugin reload orphans
# the owner=null overlay and Godot auto renames the rebuilt twin to
# _MAP_CONTEXT2; a == test silently drops the entire orphan from the census.
const ROOTS := {
	"_SCATTER": "grass scatter",
	"_MAP_CONTEXT": "map context",
	"_MAP_FX": "fx",
	"_MAP_LIGHTS": "map lights",
	"_HP_PROP_LIGHTS": "prop light fixtures",
	"_GAME_LIGHTING": "game lighting",
	"_OCCLUDERS": "occluders",
	"_GAMEMODE": "gamemode markers",
	"_HP_MARKERS": "your notes",
	"_HIPOLY_PREVIEW": "high-poly overlays",
	"_COLLISION_VIS": "collision overlay",
}

# Children of the map context that earn their own row. Pooling these into one
# "scenery" line is what hid the fact that the skyline is nearly free to draw
# and ruinous to let cast.
const PARTS := {
	"Terrain": "terrain",
	"Roads": "roads",
	"Water": "water",
	"Backdrop": "skyline",
	"Props": "props",
	"_SCATTER": "grass scatter",
	"FXCards": "fx cards",
}

# Labels that are still "inside the map context", so a PARTS name found under
# them promotes. FXCards lives under Props or under Backdrop depending on which
# builder made it, so the promotion has to survive one level of nesting.
const PART_FAMILY := {
	"map context": true, "terrain": true, "roads": true, "water": true,
	"skyline": true, "props": true, "fx cards": true, "grass scatter": true,
}

# Fallback buckets for anything not under one of our roots.
const SDK_GEOM := "SDK level geometry"
const SDK_DECAL := "SDK decals"
const USER_PLACED := "your placed objects"

const BLANK := {
	"nodes": 0, "vis": 0, "hidden": 0,
	"mi": 0, "mmi": 0, "other_vi": 0,
	"inst": 0, "surf": 0, "tris": 0, "verts": 0, "uniq_verts": 0,
	"casters": 0, "caster_surf": 0, "shadows_only": 0, "overlay_surf": 0,
	"calls": 0,
	"lights": 0, "lights_shadow": 0, "omni_shadow": 0, "spot_shadow": 0,
	"dir": 0, "dir_shadow": 0,
	"particles": 0, "decals": 0, "probes": 0, "occluders": 0, "fog": 0,
	"std_surf": 0, "shader_surf": 0, "nomat_surf": 0,
	"alpha_surf": 0, "twosided_surf": 0,
	"range_culled": 0,
}


# ---------------------------------------------------------------------------
# THE WALK
#
# Iterative, never recursive: a map with 38,226 placements is deep enough and
# wide enough that a recursive walk is a needless stack risk, and the profiler
# already settled on this shape.
#
# `root` is passed in rather than read from EditorInterface so this runs
# headless against a synthetic tree, which is how it is tested.
# ---------------------------------------------------------------------------
static func take(root: Node) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var layers: Dictionary = {}
	var mats: Dictionary = {}          # material instance id -> record
	var meshes: Dictionary = {}        # mesh instance id -> record
	var shaders: Dictionary = {}       # shader instance id -> record
	var mergeable: Dictionary = {}     # layer + mesh fingerprint -> [refs, surf]
	var notes: Array = []

	if root == null:
		return {"layers": {}, "totals": BLANK.duplicate(), "materials": {},
			"meshes": {}, "shaders": {}, "dedup": {},
			"notes": ["no scene to census: open the level scene first"],
			"shadow_passes": 0, "ms": 0, "engine": {}}

	# Pass one exists only to find the shadow multiplier. It has to be known
	# before any casting surface is priced, and it lives in the lights, which
	# are scattered across three different roots.
	var cascades := _directional_cascades(root)

	var stack: Array = [[root, ""]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var layer: String = pair[1]
		var nm := String(n.name)

		# layer attribution
		if layer == "":
			for k in ROOTS:
				if nm.contains(k):
					layer = ROOTS[k]
					break
		elif PART_FAMILY.has(layer) and PARTS.has(nm):
			layer = PARTS[nm]

		# The SDK's own level geometry hangs UNDER a node whose name ends
		# _Assets or _Terrain, so testing only the node's own name puts the
		# parent in one bucket and every mesh it holds in another. The suffix
		# has to become the layer so it propagates to the children, otherwise
		# effectively all SDK geometry reads as "your placed objects".
		if layer == "":
			if nm.ends_with("_Assets") or nm.ends_with("_Terrain"):
				layer = SDK_GEOM
			elif nm.ends_with("_Decal"):
				layer = SDK_DECAL
		var bucket := layer
		if bucket == "":
			bucket = USER_PLACED
		if not layers.has(bucket):
			layers[bucket] = BLANK.duplicate()
			layers[bucket]["mat_ids"] = {}
			layers[bucket]["shader_ids"] = {}
			layers[bucket]["mesh_ids"] = {}
		var r: Dictionary = layers[bucket]
		r["nodes"] += 1

		if n is VisualInstance3D:
			if not (n as Node3D).is_visible_in_tree():
				r["hidden"] += 1
			else:
				_account(n, r, mats, meshes, shaders, mergeable, bucket, cascades)

		for c in n.get_children():
			stack.append([c, layer])

	# roll up
	var totals := BLANK.duplicate()
	var all_mats: Dictionary = {}
	var all_shaders: Dictionary = {}
	var all_meshes: Dictionary = {}
	for k in layers:
		var r: Dictionary = layers[k]
		for f in BLANK:
			totals[f] += int(r[f])
		for mid in (r["mat_ids"] as Dictionary):
			all_mats[mid] = true
		for sid in (r["shader_ids"] as Dictionary):
			all_shaders[sid] = true
		for hid in (r["mesh_ids"] as Dictionary):
			all_meshes[hid] = true
		r["distinct_mats"] = (r["mat_ids"] as Dictionary).size()
		r["distinct_shaders"] = (r["shader_ids"] as Dictionary).size()
		r["distinct_meshes"] = (r["mesh_ids"] as Dictionary).size()
		r.erase("mat_ids")
		r.erase("shader_ids")
		r.erase("mesh_ids")
	totals["distinct_mats"] = all_mats.size()
	totals["distinct_shaders"] = all_shaders.size()
	totals["distinct_meshes"] = all_meshes.size()

	if int(totals["range_culled"]) > 0:
		notes.append("%d visible node(s) are being distance culled by their own "
			% int(totals["range_culled"])
			+ "visibility_range. The range slider is supposed to be at maximum, "
			+ "so this is a bug to find, not a saving to bank.")

	var out := {
		"layers": layers,
		"totals": totals,
		"materials": mats,
		"meshes": meshes,
		"shaders": shaders,
		"dedup": _dedup(mats, meshes, mergeable),
		"shadow_passes": cascades,
		"notes": notes,
		"ms": Time.get_ticks_msec() - t0,
		"engine": _engine_counters(),
	}
	return out


# Charge one visible VisualInstance3D to its layer row.
static func _account(n: Node, r: Dictionary, mats: Dictionary,
		meshes: Dictionary, shaders: Dictionary, mergeable: Dictionary,
		bucket: String, cascades: int) -> void:
	# Lights, decals, probes, occluders and particles are VisualInstance3D but
	# NOT GeometryInstance3D. Reading cast_shadow off a null cast is what killed
	# the first version of the profiler's walk, so they are branched first.
	if n is Light3D:
		var l := n as Light3D
		r["lights"] += 1
		if l.shadow_enabled:
			r["lights_shadow"] += 1
		if l is OmniLight3D:
			if l.shadow_enabled:
				r["omni_shadow"] += 1
		elif l is SpotLight3D:
			if l.shadow_enabled:
				r["spot_shadow"] += 1
		elif l is DirectionalLight3D:
			r["dir"] += 1
			if l.shadow_enabled:
				r["dir_shadow"] += 1
		return
	if n is GPUParticles3D or n is CPUParticles3D:
		r["particles"] += 1
		return
	if n is Decal:
		r["decals"] += 1
		return
	if n is ReflectionProbe:
		r["probes"] += 1
		return
	if n is OccluderInstance3D:
		r["occluders"] += 1
		return
	if n is FogVolume:
		r["fog"] += 1
		return

	var gi := n as GeometryInstance3D
	if gi == null:
		r["other_vi"] += 1
		return

	var m: Mesh = null
	var cnt := 1
	if n is MultiMeshInstance3D:
		r["mmi"] += 1
		var mm := (n as MultiMeshInstance3D).multimesh
		if mm != null:
			m = mm.mesh
			cnt = mm.visible_instance_count
			if cnt < 0:
				cnt = mm.instance_count
	elif n is MeshInstance3D:
		r["mi"] += 1
		m = (n as MeshInstance3D).mesh
	else:
		r["other_vi"] += 1
		return
	if m == null or cnt <= 0:
		return

	# Observation only. Nothing is skipped for being range culled, because the
	# whole point of this exercise is the everything visible worst case.
	# The range test is only reached when a range is actually set, because it
	# asks EditorInterface for the viewport camera and this has to run headless.
	if gi.visibility_range_end > 0.0 or gi.visibility_range_begin > 0.0:
		if Prof._range_culled(gi):
			r["range_culled"] += 1

	var surf: int = m.get_surface_count()
	var cs := gi.cast_shadow
	var casts := cs != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var draws := cs != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY

	var tri := Prof._tris(m)
	var vert := _verts(m)

	r["vis"] += 1
	r["inst"] += cnt
	r["surf"] += surf
	r["tris"] += cnt * tri
	r["verts"] += cnt * vert
	r["uniq_verts"] += vert
	if casts:
		r["casters"] += 1
		r["caster_surf"] += surf
	if not draws:
		r["shadows_only"] += 1
	var overlay := gi.material_overlay != null
	if overlay:
		r["overlay_surf"] += surf
	r["calls"] += (surf if draws else 0) + (surf if overlay else 0) \
		+ (surf * cascades if casts else 0)

	# mesh registry, keyed by resource identity
	var hid := m.get_instance_id()
	if not meshes.has(hid):
		meshes[hid] = {"surf": surf, "tris": tri, "verts": vert,
			"refs": 0, "inst": 0, "fp": _mesh_fp(m),
			"name": String(m.resource_name), "path": String(m.resource_path)}
	meshes[hid]["refs"] += 1
	meshes[hid]["inst"] += cnt
	(r["mesh_ids"] as Dictionary)[hid] = true

	# The saving from merging two content identical meshes is only real if they
	# also sit in the same layer, so record the pair rather than the mesh.
	var mk := bucket + "|" + str(meshes[hid]["fp"]) + "|" + str(int(cs))
	if not mergeable.has(mk):
		mergeable[mk] = {"refs": 0, "surf": surf, "layer": bucket,
			"name": String(m.resource_name)}
	mergeable[mk]["refs"] += 1

	# materials, per surface, with the real precedence Godot uses
	for s in range(surf):
		var mat := _eff_material(gi, m, s)
		if mat == null:
			r["nomat_surf"] += 1
			continue
		var mid := mat.get_instance_id()
		if not mats.has(mid):
			var rec := {"cls": mat.get_class(), "surf_uses": 0, "node_uses": 0,
				"fp": _mat_fp(mat), "shader": 0, "alpha": false,
				"twosided": false, "name": String(mat.resource_name),
				"path": String(mat.resource_path)}
			if mat is ShaderMaterial:
				var sh := (mat as ShaderMaterial).shader
				if sh != null:
					rec["shader"] = sh.get_instance_id()
					if not shaders.has(rec["shader"]):
						shaders[rec["shader"]] = {
							"name": _shader_name(sh), "mats": 0,
							"modes": _render_modes(sh)}
					shaders[rec["shader"]]["mats"] += 1
					var modes: String = shaders[rec["shader"]]["modes"]
					rec["alpha"] = modes.contains("blend_add") \
						or modes.contains("blend_mix") or modes.contains("blend_sub") \
						or modes.contains("blend_mul") or modes.contains("depth_prepass_alpha")
					rec["twosided"] = modes.contains("cull_disabled")
			elif mat is BaseMaterial3D:
				var bm := mat as BaseMaterial3D
				rec["alpha"] = bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
				rec["twosided"] = bm.cull_mode == BaseMaterial3D.CULL_DISABLED
			mats[mid] = rec
		mats[mid]["surf_uses"] += 1
		(r["mat_ids"] as Dictionary)[mid] = true
		if int(mats[mid]["shader"]) != 0:
			(r["shader_ids"] as Dictionary)[int(mats[mid]["shader"])] = true
			r["shader_surf"] += 1
		else:
			r["std_surf"] += 1
		if bool(mats[mid]["alpha"]):
			r["alpha_surf"] += 1
		if bool(mats[mid]["twosided"]):
			r["twosided_surf"] += 1
	if surf > 0:
		var seen: Dictionary = {}
		for s2 in range(surf):
			var mt := _eff_material(gi, m, s2)
			if mt != null and not seen.has(mt.get_instance_id()):
				seen[mt.get_instance_id()] = true
				mats[mt.get_instance_id()]["node_uses"] += 1


# The precedence Godot actually applies, most specific first. Getting this
# wrong makes every material number a fiction: a plugin that sets
# material_override on a proxy has ONE material no matter what the mesh says.
static func _eff_material(gi: GeometryInstance3D, m: Mesh, s: int) -> Material:
	if gi.material_override != null:
		return gi.material_override
	var mi := gi as MeshInstance3D
	if mi != null:
		var o := mi.get_surface_override_material(s)
		if o != null:
			return o
	return m.surface_get_material(s)


# How many times a casting surface is re rendered, derived rather than assumed.
# The profiler hardcodes 4 cascades; if the sun's shadow is off, or it is set to
# one split, that constant silently invents cost that is not being paid.
static func _directional_cascades(root: Node) -> int:
	var total := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var d := n as DirectionalLight3D
		if d != null and d.shadow_enabled and d.is_visible_in_tree():
			match d.directional_shadow_mode:
				DirectionalLight3D.SHADOW_ORTHOGONAL:
					total += 1
				DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS:
					total += 2
				_:
					total += 4
		for c in n.get_children():
			stack.append(c)
	return total


# surface_get_array_len is ARRAYMESH ONLY and THROWS on a PrimitiveMesh rather
# than returning zero, exactly as documented on HighpolyProfiler._tris. One
# PlaneMesh, the water surface, is enough to abandon a whole scan.
static var _vert_cache: Dictionary = {}

static func _verts(m: Mesh) -> int:
	if m == null:
		return 0
	var key := m.get_instance_id()
	if _vert_cache.has(key):
		return int(_vert_cache[key])
	var v := 0
	var am := m as ArrayMesh
	if am != null:
		for s in range(am.get_surface_count()):
			v += am.surface_get_array_len(s)
	else:
		for s in range(m.get_surface_count()):
			var arr: Array = m.surface_get_arrays(s)
			if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null:
				v += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_vert_cache[key] = v
	return v


# ---------------------------------------------------------------------------
# FINGERPRINTS
#
# What makes two separate resources the same thing. Stored properties only, so
# runtime state and editor bookkeeping do not create false differences.
# Sub resources compare by path when they have one and by identity when they do
# not, which means two identically generated textures read as different. The
# sharing numbers are therefore a floor.
# ---------------------------------------------------------------------------
static var _mat_fp_cache: Dictionary = {}

static func _mat_fp(m: Material) -> int:
	var key := m.get_instance_id()
	if _mat_fp_cache.has(key):
		return int(_mat_fp_cache[key])
	var parts := PackedStringArray([m.get_class()])
	for p in m.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var pn := String(p["name"])
		if pn.begins_with("resource_"):
			continue
		parts.append(pn + "=" + _val_key(m.get(pn)))
	var h := "".join(parts).hash()
	_mat_fp_cache[key] = h
	return h


static var _mesh_fp_cache: Dictionary = {}

static func _mesh_fp(m: Mesh) -> int:
	var key := m.get_instance_id()
	if _mesh_fp_cache.has(key):
		return int(_mesh_fp_cache[key])
	var parts := PackedStringArray([m.get_class(),
		str(Prof._tris(m)), str(_verts(m)), str(m.get_aabb().size.snapped(Vector3.ONE * 0.001))])
	var am := m as ArrayMesh
	for s in range(m.get_surface_count()):
		var fmt := 0
		if am != null:
			fmt = am.surface_get_format(s)
		var sm := m.surface_get_material(s)
		parts.append("%d:%d:%s" % [s, fmt, "0" if sm == null else str(_mat_fp(sm))])
	var h := "".join(parts).hash()
	_mesh_fp_cache[key] = h
	return h


static func _val_key(v: Variant) -> String:
	if v is Resource:
		var res := v as Resource
		var rp := String(res.resource_path)
		return "R:" + (rp if rp != "" else str(res.get_instance_id()))
	if v is Object:
		return "O:" + str((v as Object).get_instance_id())
	return str(v)


static func _shader_name(sh: Shader) -> String:
	var p := String(sh.resource_path)
	if p != "":
		return p.get_file()
	var n := String(sh.resource_name)
	return n if n != "" else "shader#%d" % sh.get_instance_id()


# render_mode is not exposed as a property, so it is read out of the source
# once per shader. There are a handful of shaders in play, so this is cheap,
# and it is the only way to know whether a ShaderMaterial is a blended surface.
static var _mode_cache: Dictionary = {}

static func _render_modes(sh: Shader) -> String:
	var key := sh.get_instance_id()
	if _mode_cache.has(key):
		return String(_mode_cache[key])
	var modes := ""
	for line in sh.code.split("\n"):
		var l := String(line).strip_edges()
		if l.begins_with("render_mode"):
			modes += l + " "
		elif l.begins_with("void ") and modes != "":
			break
	_mode_cache[key] = modes
	return modes


# ---------------------------------------------------------------------------
# SHARING
#
# Everything here is quoted in draw calls, because "you have 900 duplicate
# materials" is not a budget, and "those duplicates are costing 3,400 binds a
# frame" is.
# ---------------------------------------------------------------------------
static func _dedup(mats: Dictionary, meshes: Dictionary,
		mergeable: Dictionary) -> Dictionary:
	var mat_groups: Dictionary = {}
	for mid in mats:
		var fp: int = int(mats[mid]["fp"])
		if not mat_groups.has(fp):
			mat_groups[fp] = {"n": 0, "surf": 0, "cls": mats[mid]["cls"],
				"name": mats[mid]["name"]}
		mat_groups[fp]["n"] += 1
		mat_groups[fp]["surf"] += int(mats[mid]["surf_uses"])
	var dup_mats := 0
	var dup_mat_surf := 0
	var worst_mat: Array = []
	for fp in mat_groups:
		var g: Dictionary = mat_groups[fp]
		if int(g["n"]) > 1:
			dup_mats += int(g["n"]) - 1
			dup_mat_surf += int(g["surf"])
			worst_mat.append(g)
	worst_mat.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))

	var mesh_groups: Dictionary = {}
	for hid in meshes:
		var fp2: int = int(meshes[hid]["fp"])
		if not mesh_groups.has(fp2):
			mesh_groups[fp2] = {"n": 0, "refs": 0, "surf": int(meshes[hid]["surf"]),
				"name": meshes[hid]["name"]}
		mesh_groups[fp2]["n"] += 1
		mesh_groups[fp2]["refs"] += int(meshes[hid]["refs"])
	var dup_meshes := 0
	var worst_mesh: Array = []
	for fp3 in mesh_groups:
		var g3: Dictionary = mesh_groups[fp3]
		if int(g3["n"]) > 1:
			dup_meshes += int(g3["n"]) - 1
			worst_mesh.append(g3)
	worst_mesh.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))

	# Draw calls recoverable by merging content identical meshes that already
	# sit in the same layer with the same shadow setting. Each extra node past
	# the first pays its surfaces again, so merging k nodes into one saves
	# (k - 1) x surfaces of base draw.
	var merge_calls := 0
	var merge_nodes := 0
	var merge_rows: Array = []
	for mk in mergeable:
		var g4: Dictionary = mergeable[mk]
		var refs := int(g4["refs"])
		if refs > 1:
			var saved := (refs - 1) * int(g4["surf"])
			merge_calls += saved
			merge_nodes += refs - 1
			merge_rows.append({"layer": g4["layer"], "name": g4["name"],
				"refs": refs, "surf": int(g4["surf"]), "saved": saved})
	merge_rows.sort_custom(func(a, b): return int(a["saved"]) > int(b["saved"]))

	return {
		"dup_materials": dup_mats,
		"dup_material_surfaces": dup_mat_surf,
		"material_content_groups": mat_groups.size(),
		"dup_meshes": dup_meshes,
		"mesh_content_groups": mesh_groups.size(),
		"merge_calls": merge_calls,
		"merge_nodes": merge_nodes,
		"top_materials": worst_mat.slice(0, 8),
		"top_meshes": worst_mesh.slice(0, 8),
		"top_merges": merge_rows.slice(0, 8),
	}


static func _engine_counters() -> Dictionary:
	return {
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"fps": int(Performance.get_monitor(Performance.TIME_FPS)),
	}


# ---------------------------------------------------------------------------
# REPORT
#
# Sorted by estimated draw calls, never alphabetically: the reason to read this
# is to find out which row to attack first.
# ---------------------------------------------------------------------------
static func report(root: Node) -> String:
	return "\n".join(lines(take(root)))


# Meshes and materials built in code carry no resource_name, so a name column
# would otherwise be a stack of blanks with nothing to tell the rows apart.
static func _label(v: Variant, fallback: String) -> String:
	var s := String(v).strip_edges()
	if s == "":
		s = "(unnamed %s)" % fallback
	return s.left(26)


static func lines(d: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var layers: Dictionary = d["layers"]
	var t: Dictionary = d["totals"]
	var casc: int = int(d["shadow_passes"])

	out.append("RENDER COST CENSUS   walked in %d ms" % int(d["ms"]))
	out.append("  everything visible, distance culling deliberately off")
	if layers.is_empty():
		out.append("  nothing to count")
		for n in (d["notes"] as Array):
			out.append("  NOTE: %s" % n)
		return out

	out.append("")
	out.append("SHADOW MULTIPLIER  %d directional cascade(s) in the scene" % casc)
	if casc == 0:
		out.append("  no shadowed directional light is present, so a casting surface")
		out.append("  costs nothing extra from the sun. Every shadow number below is 0")
		out.append("  by measurement, not by assumption.")
	else:
		out.append("  every casting surface is drawn %d extra time(s) per frame" % casc)

	# ---- the ranked table
	var keys: Array = layers.keys()
	keys.sort_custom(func(a, b): return int(layers[a]["calls"]) > int(layers[b]["calls"]))
	var est := 0
	out.append("")
	out.append("BY LAYER, ranked by estimated draw calls")
	for k in keys:
		var r: Dictionary = layers[k]
		if int(r["vis"]) == 0 and int(r["lights"]) == 0 and int(r["particles"]) == 0 \
				and int(r["decals"]) == 0:
			continue
		est += int(r["calls"])
		out.append("")
		out.append("  %-22s ~%7d calls   %6d surf   %6d node(s)   %8d inst"
			% [k, int(r["calls"]), int(r["surf"]), int(r["vis"]), int(r["inst"])])
		out.append("      geometry     %5.2fM tris drawn, %5.2fM verts drawn (%5.2fM unique)"
			% [float(r["tris"]) / 1e6, float(r["verts"]) / 1e6,
				float(r["uniq_verts"]) / 1e6])
		out.append("      nodes        %d MeshInstance3D, %d MultiMeshInstance3D"
			% [int(r["mi"]), int(r["mmi"])])
		if int(r["mmi"]) > 0:
			out.append("      multimesh    %.0f instances per node on average"
				% (float(r["inst"]) / maxf(1.0, float(r["mmi"]))))
		var dm := int(r.get("distinct_mats", 0))
		out.append("      materials    %d distinct over %d surfaces (%.1f surfaces per material)"
			% [dm, int(r["surf"]), float(r["surf"]) / maxf(1.0, float(dm))])
		out.append("      shaders      %d distinct, %d surface(s) on ShaderMaterial, %d on standard"
			% [int(r.get("distinct_shaders", 0)), int(r["shader_surf"]), int(r["std_surf"])])
		if int(r["nomat_surf"]) > 0:
			out.append("      no material   %d surface(s) carry none and fall back to the default"
				% int(r["nomat_surf"]))
		if int(r["alpha_surf"]) > 0 or int(r["twosided_surf"]) > 0:
			out.append("      raster       %d blended surface(s), %d two sided"
				% [int(r["alpha_surf"]), int(r["twosided_surf"])])
		out.append("      shadows      %d of %d node(s) cast, %d of %d surface(s), costing ~%d calls"
			% [int(r["casters"]), int(r["vis"]), int(r["caster_surf"]),
				int(r["surf"]), int(r["caster_surf"]) * casc])
		if int(r["overlay_surf"]) > 0:
			out.append("      overlay      %d surface(s) carry a material_overlay, a second full pass"
				% int(r["overlay_surf"]))
		if int(r["lights"]) > 0:
			out.append("      lights       %d total, %d with shadows on (%d omni, %d spot, %d directional)"
				% [int(r["lights"]), int(r["lights_shadow"]), int(r["omni_shadow"]),
					int(r["spot_shadow"]), int(r["dir_shadow"])])
		var extras := PackedStringArray()
		if int(r["particles"]) > 0:
			extras.append("%d particle system(s)" % int(r["particles"]))
		if int(r["decals"]) > 0:
			extras.append("%d decal(s)" % int(r["decals"]))
		if int(r["probes"]) > 0:
			extras.append("%d reflection probe(s)" % int(r["probes"]))
		if int(r["occluders"]) > 0:
			extras.append("%d occluder(s)" % int(r["occluders"]))
		if int(r["fog"]) > 0:
			extras.append("%d fog volume(s)" % int(r["fog"]))
		if extras.size() > 0:
			out.append("      also         %s" % ", ".join(extras))
		if int(r["hidden"]) > 0:
			out.append("      hidden       %d node(s) built but not visible, costing memory not frames"
				% int(r["hidden"]))

	# ---- lights, gathered, because this is the one that can dwarf everything
	out.append("")
	out.append("LIGHTS")
	out.append("  %d light(s), %d with shadows on"
		% [int(t["lights"]), int(t["lights_shadow"])])
	out.append("  shadow casting local lights: %d omni, %d spot"
		% [int(t["omni_shadow"]), int(t["spot_shadow"])])
	if int(t["omni_shadow"]) > 0 or int(t["spot_shadow"]) > 0:
		var faces := int(t["omni_shadow"]) * 6 + int(t["spot_shadow"])
		out.append("  that is %d shadow map render(s) per frame, each one redrawing every"
			% faces)
		out.append("  casting surface inside that light's radius. This census does NOT")
		out.append("  resolve which surfaces fall inside which radius, so this number is")
		out.append("  a count of passes, not of calls. It is still the largest single")
		out.append("  multiplier available in the scene.")

	# ---- sharing
	var dd: Dictionary = d["dedup"]
	out.append("")
	out.append("SHARING, what is duplicated that need not be")
	out.append("  %d distinct material(s) collapse to %d content group(s): %d are redundant copies"
		% [int(t.get("distinct_mats", 0)), int(dd["material_content_groups"]),
			int(dd["dup_materials"])])
	out.append("  %d distinct mesh(es) collapse to %d content group(s): %d are redundant copies"
		% [int(t.get("distinct_meshes", 0)), int(dd["mesh_content_groups"]),
			int(dd["dup_meshes"])])
	out.append("  merging content identical meshes that already share a layer and a")
	out.append("  shadow setting would remove %d node(s) and about %d draw call(s)"
		% [int(dd["merge_nodes"]), int(dd["merge_calls"])])
	for row in (dd["top_merges"] as Array):
		out.append("     %-16s %-26s %4d copies x %d surf, saving %d call(s)"
			% [row["layer"], _label(row["name"], "mesh"), int(row["refs"]),
				int(row["surf"]), int(row["saved"])])
	for row2 in (dd["top_materials"] as Array):
		out.append("     %-26s appears %d times as separate copies, %d surface(s)"
			% [_label(row2["name"], String(row2["cls"])), int(row2["n"]),
				int(row2["surf"])])

	# ---- totals and reconciliation
	var eng: Dictionary = d["engine"]
	out.append("")
	out.append("TOTAL  ~%d draw calls   %d surfaces   %d distinct materials   %d distinct shaders"
		% [est, int(t["surf"]), int(t.get("distinct_mats", 0)),
			int(t.get("distinct_shaders", 0))])
	out.append("       %.2fM triangles drawn, %.2fM vertices drawn"
		% [float(t["tris"]) / 1e6, float(t["verts"]) / 1e6])
	out.append("       %d of %d surface(s) cast shadows (%.0f%%), which is ~%d of the calls above"
		% [int(t["caster_surf"]), int(t["surf"]),
			100.0 * float(t["caster_surf"]) / maxf(1.0, float(t["surf"])),
			int(t["caster_surf"]) * casc])
	out.append("       %.1f surfaces per distinct material overall (higher batches better)"
		% (float(t["surf"]) / maxf(1.0, float(t.get("distinct_mats", 1)))))
	if int(eng.get("draws", 0)) > 0:
		out.append("       estimated %d calls vs the engine's %d (%.0f%%)"
			% [est, int(eng["draws"]), 100.0 * est / maxf(1.0, float(eng["draws"]))])
		if est < int(eng["draws"]) * 0.5 or est > int(eng["draws"]) * 2.0:
			out.append("       WARNING: the estimate and the engine disagree by more than 2x,")
			out.append("                so nothing in the split above should be acted on yet.")
	for n2 in (d["notes"] as Array):
		out.append("")
		out.append("NOTE: %s" % n2)
	return out
