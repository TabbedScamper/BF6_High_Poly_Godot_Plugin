@tool
class_name HighpolyRoadDraws
extends RefCounted
# Road paint and ground decals as the Unreal add-on draws them, from the shared
# core (environment product "decal_draws", bf6_level_decal_draws): the same
# records, styles, drape and compositing order, one mesh per draw.
#
# ORDER. Unreal sets each component's translucent sort priority to the draw's
# sort key (band 0/2000/4000/6000 + draw index). Godot's render_priority only
# spans -128..127, so the band takes the priority (-100 fill .. -97 marking,
# under the water's 1 and 2) and the draw index takes sorting_offset, which is
# large enough that camera distance never reorders two draws in one band.

const SHADER := preload("road_draw.gdshader")
const DETAIL_TEXTURE_MAX := 1024      # Unreal GPreviewTextureMax
const MARKING_TEXTURE_MAX := 16384    # Unreal GMarkingTextureMax
const SORT_OFFSET_PER_DRAW := 1000.0

static func _load_shader() -> Shader:
	return SHADER


# Worker-thread half: meshes and materials, no nodes. {} when the core cannot
# provide draws, which leaves the caller's own roads in charge.
static func prepare(env: Object) -> Dictionary:
	if env == null or not env.has_method("request"): return {}
	var data: Dictionary = env.call("request", "decal_draws", 0)
	if data.is_empty() or not bool(data.get("present", 0)): return {}
	var positions_bytes: PackedByteArray = data.get("positions", PackedByteArray())
	var uvs_bytes: PackedByteArray = data.get("uvs", PackedByteArray())
	var colors_bytes: PackedByteArray = data.get("colors", PackedByteArray())
	var shader := _load_shader()
	if shader == null: return {}
	var textures := {}
	var texture_for := func(id: int, max_dim: int) -> Texture2D:
		if id < 0: return null
		var key := "%d@%d" % [id, max_dim]
		if textures.has(key): return textures[key]
		var item: Dictionary = env.call("request", "texture:%d" % max_dim, id)
		var tex: Texture2D = null
		if not item.is_empty():
			var img: Image = BF6Environment.texture_image(item)
			if img != null: tex = ImageTexture.create_from_image(img)
		textures[key] = tex
		return tex
	var out: Array = []
	var flipped := 0
	var kept := 0
	for row in data.get("draws", []):
		var d: Dictionary = row
		var n := int(d.vertex_count)
		var first := int(d.first)
		if n < 3: continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = positions_bytes.slice(first * 12, (first + n) * 12).to_vector3_array()
		arr[Mesh.ARRAY_TEX_UV] = uvs_bytes.slice(first * 8, (first + n) * 8).to_vector2_array()
		arr[Mesh.ARRAY_COLOR] = colors_bytes.slice(first * 16, (first + n) * 16).to_color_array()
		# WOUND THE WAY GODOT DRAWS, WHICH IS NOT HOW THE GAME STORES IT.
		#
		# The core hands back a triangle list in the game's own space. Taken
		# verbatim, every road marking faced DOWN: generate_normals takes the
		# normal from the winding and the shader culls back faces, so the paint
		# was invisible from above, lit from underneath, and its normal map came
		# out inverted. The Unreal add-on never sees this because its
		# game-to-Unreal conversion swaps two axes, which reverses the winding on
		# the way in.
		#
		# GODOT'S FRONT FACE IS CLOCKWISE, which is the opposite of the
		# right-hand rule this test first used. (Mesh: "Godot uses clockwise
		# winding order for front faces of triangle primitive modes", and
		# SurfaceTool.generate_normals assumes the same.) So a triangle whose
		# right-hand-rule normal points UP is FRONT-facing downward here: it is
		# culled when you look down at it, lit from underneath, and its generated
		# normal points into the ground.
		#
		# Getting this backwards the first time reported "0 of 189 re-wound,
		# all already facing up" while every marking on the map was upside down -
		# a test that confirmed the bug and called it clean.
		#
		# Still decided per draw rather than by a constant, so a wall marking
		# (net Y near zero) is not flipped on a coin toss and a future change of
		# convention in the core corrects itself.
		var vtx: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var up_sum := 0.0
		for t in range(0, vtx.size() - 2, 3):
			up_sum += (vtx[t + 1] - vtx[t]).cross(vtx[t + 2] - vtx[t]).y
		if up_sum > 0.0:
			var uvw: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var cow: PackedColorArray = arr[Mesh.ARRAY_COLOR]
			for t in range(0, vtx.size() - 2, 3):
				var p := vtx[t + 1]; vtx[t + 1] = vtx[t + 2]; vtx[t + 2] = p
				var q := uvw[t + 1]; uvw[t + 1] = uvw[t + 2]; uvw[t + 2] = q
				var c := cow[t + 1]; cow[t + 1] = cow[t + 2]; cow[t + 2] = c
			arr[Mesh.ARRAY_VERTEX] = vtx
			arr[Mesh.ARRAY_TEX_UV] = uvw
			arr[Mesh.ARRAY_COLOR] = cow
			flipped += 1
		else:
			kept += 1
		# Every corner is its own vertex, as in the Unreal description, so the
		# normals are per face; tangents follow the UVs.
		var st := SurfaceTool.new()
		st.create_from_arrays(arr)
		st.generate_normals()
		st.generate_tangents()
		var mesh := st.commit()
		var max_dim := MARKING_TEXTURE_MAX if int(d.marking) != 0 else DETAIL_TEXTURE_MAX
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var albedo: Texture2D = texture_for.call(int(d.albedo), max_dim)
		var normal: Texture2D = texture_for.call(int(d.normal), max_dim)
		var opacity: Texture2D = texture_for.call(int(d.opacity), max_dim)
		if albedo != null:
			mat.set_shader_parameter("albedo_sheet", albedo)
			mat.set_shader_parameter("has_albedo", true)
		if normal != null:
			mat.set_shader_parameter("normal_sheet", normal)
			mat.set_shader_parameter("has_normal", true)
		if opacity != null:
			mat.set_shader_parameter("opacity_sheet", opacity)
			mat.set_shader_parameter("has_opacity", true)
		var tint: Array = d.get("tint", [1, 1, 1])
		mat.set_shader_parameter("tint", Vector3(float(tint[0]), float(tint[1]), float(tint[2])))
		mat.set_shader_parameter("opacity_scale", float(d.opacity_scale))
		var sel: Array = d.get("mask_select", [1, 0, 0, 0])
		mat.set_shader_parameter("mask_select", Vector4(float(sel[0]), float(sel[1]), float(sel[2]), float(sel[3])))
		mat.set_shader_parameter("mip_bias", float(d.mip_bias))
		mat.render_priority = -100 + int(d.band) / 2000
		out.append({"mesh": mesh, "material": mat, "draw_index": int(d.draw_index),
			"sort_key": int(d.sort_key), "band": int(d.band)})
	# Counted so the fix is checkable: "all of them flipped" is the expected
	# answer for this content, and a run that reports a mix is telling you the
	# convention is not uniform after all.
	print("BF6 road decals: %d draw(s) re-wound to face up, %d already facing up "
		% [flipped, kept]
		+ "(Godot front faces are CLOCKWISE; a right-hand-rule normal pointing "
		+ "up means the face points down)")
	return {"draws": out, "stats": data.get("stats", {}),
		"rewound": flipped, "already_up": kept}


# Main-thread half: one MeshInstance3D per draw under a "Roads" node.
static func build(prepared: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Roads"
	for item in prepared.get("draws", []):
		var d: Dictionary = item
		var mi := MeshInstance3D.new()
		mi.name = "RoadMesh_%d" % int(d.draw_index)
		mi.mesh = d.mesh
		mi.material_override = d.material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.sorting_offset = float(d.draw_index) * SORT_OFFSET_PER_DRAW
		mi.sorting_use_aabb_center = false
		root.add_child(mi)
	return root
