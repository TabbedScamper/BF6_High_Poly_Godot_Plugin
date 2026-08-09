@tool
extends Object
class_name HighpolyHlod

# BAKE A CELL'S PROPS INTO ONE MESH, so a distant cell costs one draw call
# instead of the ~40 MultiMeshes it holds today.
#
# WHY THIS AND NOT BATCHING. Grouping existing meshes cannot help: props have
# 7,053 DISTINCT meshes and a MultiMesh draws once per surface, so even a
# perfect regroup where every mesh appeared once would still cost ~7,053 draws
# against a 5,266 budget for the whole frame at 16.67 ms. The floor is the
# number of distinct meshes, and the only way under it is to stop having that
# many meshes - which means merging vertex data, not rearranging nodes.
#
# An earlier attempt batched overlays into shared MultiMeshes keyed by asset and
# made everything WORSE (q1 draws 18,766 -> 22,587), because a map-spanning
# MultiMesh has a map-spanning AABB and never frustum-culls. Everything here is
# per CELL for that reason: a baked cell keeps a cell-sized bound and culls
# exactly like the props it replaced.
#
# WHY BAKING IS AFFORDABLE AT ALL, given props carry 146 M vertices: that figure
# is INSTANCED. The distinct geometry is 47 M, and a coarse LOD of it is roughly
# 6 M - and this is paid ONCE per map into the same on-disk cache the geometry
# already uses, not on every build.
#
# DO NOT THREAD THIS. Cells are independent and one task per cell looks like
# free parallelism, so it will occur to whoever reads this next. It was tried,
# properly: only the ARITHMETIC on the worker, each task reading surface arrays
# and instance transforms and returning raw PackedArrays, with the ArrayMesh
# built on the main thread afterwards so resource CREATION never left it.
#
# The editor froze. The log's last line was "perfrun: phase hlod threaded", the
# heartbeat stopped at that phase and no report was written -
# WorkerThreadPool.wait_for_task_completion blocks the main thread and the tasks
# never finish. That test ran inside the REAL editor on a real map; two earlier
# attempts hung headless under --script inside SceneTree._init, which proved
# nothing either way because that context has no main loop, and I wrongly wrote
# one of them up as fact.
#
# The bake is therefore serial: 66 s for the 3 heaviest cells, 7.7 s for the
# next 9, cached to disk so a re-run costs nothing. Whether that needs to be
# faster is a real question and not an obvious yes - it is paid once per map,
# against a build that already costs 125 s here and 289 s on a user's machine.
# If it does, native is the route: native/build.bat already compiles one
# translation unit against gdextension_interface.h and MSVC is present.
#
# WHAT THIS FILE IS NOT, yet: the colour handling is a placeholder. Merging
# props that use 3,850 different materials into one surface needs their albedo
# baked into vertex colours, and this prototype writes a per-material constant
# rather than a sampled one. That makes the geometry and the COST honest while
# the appearance is not, which is the right order: if the cost does not work
# there is no point sampling anything.

# Vertex colour when a material's albedo cannot be read. Mid grey rather than
# white so a mistake looks obviously unfinished instead of blown out.
const FALLBACK_ALBEDO := Color(0.5, 0.5, 0.5)


# THE NATIVE MERGE, when the extension is there. Same work, same output, in C++.
#
# GDScript spends 33 s on the densest cell because each of its 65.9 M vertices
# costs an interpreted transform plus a Dictionary lookup, and that cannot be
# threaded (WorkerThreadPool deadlocks inside the editor). So the loop moves
# rather than multiplies.
#
# Everything crosses as ONE PackedByteArray in each direction. to_byte_array()
# and to_float32_array() are memcpys rather than loops, so the packing here is
# nearly free next to the merge, and it means the extension needs no
# PackedVector3Array marshalling - which would have meant hardcoding
# version-specific builtin method hashes and breaking on a Godot update.
#
# Falls back to the GDScript path when the extension is absent, so a user
# without the DLL gets a slower bake rather than no plugin.
static var _native = null
static var _native_tried := false

static func _oodle():
	if not _native_tried:
		_native_tried = true
		if ClassDB.class_exists("BF6Oodle"):
			var o = ClassDB.instantiate("BF6Oodle")
			if o != null and o.has_method("merge_cell"):
				_native = o
	return _native


static func bake_cell_native(mmis: Array, origin: Vector3,
		weld: float) -> Dictionary:
	var nat = _oodle()
	if nat == null:
		return {}
	var t0 := Time.get_ticks_usec()
	# header: 'BF6M', version, weld, origin xyz, chunk count
	var head := PackedInt32Array([0x4D364642, 1]).to_byte_array()
	head.append_array(PackedFloat32Array([weld, origin.x, origin.y,
		origin.z]).to_byte_array())
	var body := PackedByteArray()
	var chunks := 0
	for node in mmis:
		if not is_instance_valid(node) or not (node is MultiMeshInstance3D):
			continue
		var mmi := node as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null or mm.mesh == null or mm.instance_count <= 0:
			continue
		var mesh := mm.mesh
		var node_xf := mmi.global_transform
		# The node transform is folded into every instance here rather than
		# passed separately: the C++ side then has one matrix per instance and
		# no notion of a parent, which is one fewer thing to keep in step.
		var xf_f := PackedFloat32Array()
		for i in range(mm.instance_count):
			var xf := node_xf * mm.get_instance_transform(i)
			xf_f.append_array(PackedFloat32Array([
				xf.basis.x.x, xf.basis.x.y, xf.basis.x.z,
				xf.basis.y.x, xf.basis.y.y, xf.basis.y.z,
				xf.basis.z.x, xf.basis.z.y, xf.basis.z.z,
				xf.origin.x, xf.origin.y, xf.origin.z]))
		for s in range(mesh.get_surface_count()):
			var arr := mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var sv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if sv.is_empty():
				continue
			var sn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] \
				if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			if sn.size() != sv.size():
				sn = PackedVector3Array()
				sn.resize(sv.size())
				for i in range(sv.size()):
					sn[i] = Vector3.UP
			var si: PackedInt32Array = arr[Mesh.ARRAY_INDEX] \
				if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var col := _albedo_of(mesh.surface_get_material(s))
			var rgba := int(col.r * 255.0) | (int(col.g * 255.0) << 8) \
				| (int(col.b * 255.0) << 16) | (255 << 24)
			body.append_array(PackedInt32Array([sv.size(), si.size(),
				mm.instance_count, rgba]).to_byte_array())
			body.append_array(sv.to_byte_array())
			body.append_array(sn.to_byte_array())
			if si.size() > 0:
				body.append_array(si.to_byte_array())
			body.append_array(xf_f.to_byte_array())
			chunks += 1
	if chunks == 0:
		return {}
	head.append_array(PackedInt32Array([chunks]).to_byte_array())
	head.append_array(body)
	var res: PackedByteArray = nat.merge_cell(head)
	if res.size() < 8:
		return {}
	var vc := res.decode_u32(0)
	var ic := res.decode_u32(4)
	if vc == 0:
		return {}
	var o := 8
	var verts := res.slice(o, o + vc * 12).to_float32_array()
	o += vc * 12
	var norms := res.slice(o, o + vc * 12).to_float32_array()
	o += vc * 12
	var cols := res.slice(o, o + vc * 4)
	o += vc * 4
	var idx := res.slice(o, o + ic * 4).to_int32_array()
	var pv := PackedVector3Array(); pv.resize(vc)
	var pn := PackedVector3Array(); pn.resize(vc)
	var pc := PackedColorArray(); pc.resize(vc)
	for i in range(vc):
		pv[i] = Vector3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2])
		pn[i] = Vector3(norms[i * 3], norms[i * 3 + 1], norms[i * 3 + 2])
		pc[i] = Color8(cols[i * 4], cols[i * 4 + 1], cols[i * 4 + 2],
			cols[i * 4 + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_NORMAL] = pn
	arrays[Mesh.ARRAY_COLOR] = pc
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {
		"mesh": am, "verts": vc, "tris": int(ic / 3), "dropped_tris": 0,
		"ms": (Time.get_ticks_usec() - t0) / 1000.0, "sources": chunks,
		"native": true,
	}


# Merge every instance of every MultiMesh in `mmis` into one ArrayMesh, in the
# space of `origin` (the cell centre), so the result can be placed at that point
# and keep a tight local bound.
#
# Returns {mesh, verts, tris, ms, sources} or {} when there is nothing to bake.
static func bake_cell(mmis: Array, origin: Vector3, weld := 0.0) -> Dictionary:
	# WELDED WHILE MERGING, NOT AFTER.
	#
	# Measured: the 8 densest cells carry 143 M vertices between them, which is
	# ~98% of the map's instanced geometry. Merging those at full detail and
	# simplifying afterwards would need roughly 4.6 GB of intermediate vertex
	# data - worse than the memory problem this plugin already has. Snapping to
	# a grid and reusing the vertex already there means the intermediate is only
	# ever as big as the RESULT.
	#
	# Godot does not expose an ArrayMesh's LOD index arrays to GDScript, so a
	# coarse level cannot simply be read out; vertex clustering is the cheap
	# equivalent and is the classic answer for geometry seen from far away.
	# weld <= 0 keeps every vertex, which is what the full-detail probe measured.
	var t0 := Time.get_ticks_usec()
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_c := PackedColorArray()
	var out_i := PackedInt32Array()
	var sources := 0
	# snapped position -> index already emitted for it
	var wmap: Dictionary = {}
	var inv_w := 0.0 if weld <= 0.0 else 1.0 / weld
	for node in mmis:
		if not is_instance_valid(node) or not (node is MultiMeshInstance3D):
			continue
		var mmi := node as MultiMeshInstance3D
		var mm := mmi.multimesh
		if mm == null or mm.mesh == null or mm.instance_count <= 0:
			continue
		var mesh := mm.mesh
		var node_xf := mmi.global_transform
		for s in range(mesh.get_surface_count()):
			var arr := mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var sv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if sv.is_empty():
				continue
			var sn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] \
				if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var si: PackedInt32Array = arr[Mesh.ARRAY_INDEX] \
				if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var col := _albedo_of(mesh.surface_get_material(s))
			for inst in range(mm.instance_count):
				var xf := node_xf * mm.get_instance_transform(inst)
				# A parked instance (zero scale) contributes nothing, and adding
				# it would collapse triangles onto a point.
				if xf.basis.determinant() == 0.0:
					continue
				# remap[local vertex] -> index in the output stream
				var remap := PackedInt32Array()
				remap.resize(sv.size())
				for vi in range(sv.size()):
					var p := xf * sv[vi] - origin
					var nrm := (xf.basis * sn[vi]).normalized() \
						if vi < sn.size() else Vector3.UP
					var at := -1
					if inv_w > 0.0:
						# KEYED ON Vector4i, NOT A STRING.
						#
						# The first version built "%d,%d,%d,%d" per vertex. A
						# dense cell holds 18 M vertices, so across the probe's
						# passes that was over 100 million string allocations
						# and hashes - the run HUNG and the harness killed it at
						# 343 s. Godot hashes Vector4i natively with no
						# allocation, which is the same key for a fraction of
						# the cost.
						#
						# w is the colour, quantised to 5 bits per channel:
						# colour has to be part of the key or two props of
						# different colours weld into one vertex and smear
						# together, and colour is all that carries their
						# appearance once the textures are gone. 5 bits is far
						# finer than anything visible at the distance this is
						# drawn from.
						var k := Vector4i(
							int(round(p.x * inv_w)), int(round(p.y * inv_w)),
							int(round(p.z * inv_w)),
							(int(col.r * 31.0) << 10) | (int(col.g * 31.0) << 5)
								| int(col.b * 31.0))
						if wmap.has(k):
							at = int(wmap[k])
						else:
							at = out_v.size()
							wmap[k] = at
							out_v.append(p); out_n.append(nrm); out_c.append(col)
					else:
						at = out_v.size()
						out_v.append(p); out_n.append(nrm); out_c.append(col)
					remap[vi] = at
				if si.is_empty():
					for vi in range(sv.size()):
						out_i.append(remap[vi])
				else:
					for k2 in range(si.size()):
						out_i.append(remap[si[k2]])
			sources += 1
	if out_v.is_empty():
		return {}
	# DEGENERATES GO. Welding collapses two corners of a triangle onto one
	# vertex wherever detail was finer than the grid, and a zero-area triangle
	# still costs index bandwidth and a rasteriser reject for nothing. This is
	# where most of the saving actually lands on fine geometry.
	var dropped := 0
	if inv_w > 0.0 and not out_i.is_empty():
		var keep := PackedInt32Array()
		for t in range(0, out_i.size() - 2, 3):
			var a := out_i[t]; var b := out_i[t + 1]; var c := out_i[t + 2]
			if a == b or b == c or a == c:
				dropped += 1
				continue
			keep.append(a); keep.append(b); keep.append(c)
		out_i = keep
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out_v
	arrays[Mesh.ARRAY_NORMAL] = out_n
	arrays[Mesh.ARRAY_COLOR] = out_c
	arrays[Mesh.ARRAY_INDEX] = out_i
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {
		"mesh": am,
		"verts": out_v.size(),
		"tris": int(out_i.size() / 3),
		"dropped_tris": dropped,
		"ms": (Time.get_ticks_usec() - t0) / 1000.0,
		"sources": sources,
	}


# One material for every baked cell: colour comes from the vertex stream, so
# nothing here varies per prop and every baked cell can share this.
static var _baked_mat: StandardMaterial3D = null

static func baked_material() -> StandardMaterial3D:
	if _baked_mat == null:
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.9
		_baked_mat = m
	return _baked_mat


# Best effort albedo for a surface's material. ShaderMaterials (which is what
# props use - all 3,850 of their materials sit on 3 shaders) are asked for the
# usual albedo parameter names before giving up.
static func _albedo_of(m: Material) -> Color:
	if m is BaseMaterial3D:
		return (m as BaseMaterial3D).albedo_color
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		for n in ["albedo", "albedo_color", "base_color", "tint", "colour"]:
			var v = sm.get_shader_parameter(n)
			if v is Color:
				return v
	return FALLBACK_ALBEDO


# BAKE THE HEAVIEST CELLS AND PUT THEM IN THE SCENE, hiding the MultiMeshes
# they replace. Cached to disk, because the bake is expensive and the result
# never changes for a given map.
#
# WHY ONLY THE HEAVIEST FEW. The distribution is extremely skewed: the single
# densest cell carries 9,744 of the frame's 18,766 draw calls and bakes to ONE.
# Half the frame, from one cell, for 33 s of work. Baking all ~40 populated
# cells would take about 22 minutes single-threaded, which is unshippable even
# once; baking three takes ~100 s and captures most of the win. This is the
# pragmatic version, and it composes with a faster bake later rather than
# blocking on one.
#
# Returns what it did, so a caller can report it rather than claim it.
# THE PARENT IS DERIVED FROM THE CELLS, NOT PASSED IN. The first version asked
# the caller for it and was handed mapctx.get_parent(), which is a
# VBoxContainer - the map context is a Node living under the DOCK, not in the
# 3D scene, and the run died on the type check after a 125 s build and a 62 s
# flight. A baked cell belongs exactly where the MultiMeshes it replaces live,
# and those know their own parent.
static func bake_and_install(cells: Dictionary, n: int,
		weld: float, cache_dir: String, mark: Dictionary = {}) -> Dictionary:
	if n <= 0:
		return {}
	var order := _by_weight(cells)
	var parent: Node3D = null
	for e in order:
		for node in e["list"]:
			if is_instance_valid(node) and node is Node3D:
				var p := (node as Node3D).get_parent()
				if p is Node3D:
					parent = p as Node3D
					break
		if parent != null:
			break
	if parent == null:
		return {"error": "no Node3D parent found for any cell"}
	var made := 0
	var replaced := 0
	var saved_draws := 0
	var ms := 0.0
	for e in order:
		if made >= n:
			break
		var key := String(e["key"])
		var list: Array = e["list"]
		# The cell's own centre, so the baked mesh keeps a tight local bound and
		# frustum-culls like the props it stands in for. A map-spanning bound is
		# what made the earlier overlay batching slower than doing nothing.
		var centre := _centre_of(list)
		var path := "%s/hlod_%s_w%d.res" % [cache_dir, key.replace(",", "_"),
			int(weld * 100.0)]
		var mesh: Mesh = null
		if cache_dir != "" and ResourceLoader.exists(path):
			var got = ResourceLoader.load(path)
			if got is Mesh:
				mesh = got
		if mesh == null:
			var r := bake_cell(list, centre, weld)
			if r.is_empty():
				continue
			mesh = r["mesh"]
			ms += float(r["ms"])
			if cache_dir != "":
				ResourceSaver.save(mesh, path)
		var mi := MeshInstance3D.new()
		mi.name = "HLOD_%s" % key.replace(",", "_")
		mi.mesh = mesh
		mi.position = centre
		mi.material_override = baked_material()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		mi.owner = null
		for node in list:
			if is_instance_valid(node) and node is Node3D:
				var mm := (node as MultiMeshInstance3D).multimesh \
					if node is MultiMeshInstance3D else null
				if mm != null and mm.mesh != null:
					saved_draws += mm.mesh.get_surface_count()
				(node as Node3D).visible = false
				replaced += 1
		# Tell the distance cull to leave this cell alone, or it will switch
		# every one of those nodes back on at its next tick.
		mark[key] = true
		made += 1
	return {"cells": made, "replaced_nodes": replaced,
		"draws_saved": saved_draws - made, "bake_ms": ms}


# The two rankers, exposed so a caller can build the same job list this file
# builds for itself - a harness comparing two merge paths has to hand both of
# them the SAME cell or the comparison means nothing.
static func by_weight_public(cells: Dictionary) -> Array:
	return _by_weight(cells)


static func centre_public(list: Array) -> Vector3:
	return _centre_of(list)


static func _centre_of(list: Array) -> Vector3:
	var acc := Vector3.ZERO
	var k := 0
	for node in list:
		if is_instance_valid(node) and node is Node3D:
			acc += (node as Node3D).global_position
			k += 1
	return acc / maxf(float(k), 1.0)


static func _by_weight(cells: Dictionary) -> Array:
	var order: Array = []
	for key in cells:
		var list: Array = cells[key]
		if list.is_empty():
			continue
		var w := 0
		for node in list:
			if is_instance_valid(node) and node is MultiMeshInstance3D:
				var mm := (node as MultiMeshInstance3D).multimesh
				if mm != null and mm.mesh != null:
					w += mm.mesh.get_surface_count() * maxi(1, mm.instance_count)
		if w > 0:
			order.append({"key": key, "w": w, "list": list})
	order.sort_custom(func(a, b): return a["w"] > b["w"])
	return order


# MEASUREMENT ONLY. Bake the `n` cells furthest from `cam`, and report what it
# cost and what it would save, WITHOUT putting anything in the scene. The point
# is to find out whether the bake is affordable before any of it is wired up.
static func probe(cells: Dictionary, cam: Vector3, n: int,
		weld := 0.0) -> Dictionary:
	# RANKED BY WHAT A CELL COSTS, NOT BY HOW FAR IT IS.
	#
	# The first version of this sorted by distance from the camera, which picked
	# the cells at the corners of the map - 2 MultiMeshes and 1,747 vertices
	# each. Baking the emptiest cells in the level says nothing about whether
	# baking is affordable, and its 1.9x "saving" was measuring noise. The cells
	# worth baking are the ones carrying the draws, so rank by surface count.
	var order: Array = []
	for key in cells:
		var list: Array = cells[key]
		if list.is_empty():
			continue
		var c: Node = list[0]
		if not is_instance_valid(c) or not (c is Node3D):
			continue
		var w := 0
		for node in list:
			if is_instance_valid(node) and node is MultiMeshInstance3D:
				var mm := (node as MultiMeshInstance3D).multimesh
				if mm != null and mm.mesh != null:
					w += mm.mesh.get_surface_count() * maxi(1, mm.instance_count)
		order.append({"key": key, "w": w,
			"d": (c as Node3D).global_position.distance_to(cam), "list": list})
	order.sort_custom(func(a, b): return a["w"] > b["w"])
	var took := 0.0
	var verts := 0
	var tris := 0
	var dropped := 0
	var before := 0        # draws these cells cost now: one per MultiMesh surface
	var after := 0         # draws they would cost baked: one per cell
	var done := 0
	for e in order:
		if done >= n:
			break
		for node in e["list"]:
			if is_instance_valid(node) and node is MultiMeshInstance3D:
				var mm := (node as MultiMeshInstance3D).multimesh
				if mm != null and mm.mesh != null:
					before += mm.mesh.get_surface_count()
		var r := bake_cell(e["list"], Vector3.ZERO, weld)
		if r.is_empty():
			continue
		took += float(r["ms"])
		verts += int(r["verts"])
		tris += int(r["tris"])
		dropped += int(r.get("dropped_tris", 0))
		after += 1
		done += 1
	return {
		"cells": done, "ms": took, "verts": verts, "tris": tris,
		"dropped_tris": dropped, "weld": weld,
		"draws_before": before, "draws_after": after,
		"ms_per_cell": took / maxf(float(done), 1.0),
	}
