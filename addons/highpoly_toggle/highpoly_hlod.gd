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
# WHAT THIS FILE IS NOT, yet: the colour handling is a placeholder. Merging
# props that use 3,850 different materials into one surface needs their albedo
# baked into vertex colours, and this prototype writes a per-material constant
# rather than a sampled one. That makes the geometry and the COST honest while
# the appearance is not, which is the right order: if the cost does not work
# there is no point sampling anything.

# Vertex colour when a material's albedo cannot be read. Mid grey rather than
# white so a mistake looks obviously unfinished instead of blown out.
const FALLBACK_ALBEDO := Color(0.5, 0.5, 0.5)


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
						# Colour is part of the key: welding two props of
						# different colour into one vertex would smear them
						# together, and the colour is the only thing carrying
						# their appearance once the textures are gone.
						var k := "%d,%d,%d,%d" % [
							int(round(p.x * inv_w)), int(round(p.y * inv_w)),
							int(round(p.z * inv_w)), int(col.to_rgba32())]
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
