extends SceneTree

# WHAT IS "THE ORANGE MATERIAL GODOT USES"?
#
#   godot --headless --path <SDK GodotProject> --script probe_sdk_material.gd
#
# The request is for low-poly carrier layouts "textured with the orange material
# godot uses". Before anything can be built to match it, the material has to be
# named precisely: whether it is a real StandardMaterial3D on the SDK's own
# object meshes, a shader, or simply what Godot draws when a mesh has no
# material at all. Those need different code to reproduce, and guessing which
# would mean shipping something that looks right on this machine only.
#
# The SDK ships no .glb sources - only pre-imported .scn scenes - so the answer
# is inside those, and this reads it rather than inferring it.

func _init() -> void:
	await process_frame
	# THE ORANGE LAYOUT the maps come in with: static/<MAP>_Assets.tscn, which
	# every level scene instances beside its terrain. That is the thing to match,
	# not the per-object library material.
	var samples := [
		"res://static/MP_Atoll_Assets.tscn",
		"res://static/MP_Isolated_Assets.tscn",
		"res://static/MP_Atoll_Terrain.tscn",
	]
	var checked := 0
	for path in samples:
		if path.ends_with("/"):
			continue
		if not ResourceLoader.exists(path):
			print("MISSING %s" % path)
			continue
		var ps: PackedScene = load(path)
		if ps == null:
			print("UNREADABLE %s" % path)
			continue
		var root: Node = ps.instantiate()
		print("\n== %s" % path)
		_walk(root, 0)
		root.queue_free()
		checked += 1
	if checked == 0:
		print("no SDK object scenes could be read from this project")
	quit(0)


func _walk(n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m: Mesh = mi.mesh
		print("%s%s  MeshInstance3D mesh=%s surfaces=%d"
			% [pad, n.name, "null" if m == null else m.get_class(),
			   0 if m == null else m.get_surface_count()])
		# material_override wins over the surface material, so report both -
		# "which one is orange" is the whole question.
		print("%s   override=%s" % [pad, _describe(mi.material_override)])
		if m != null:
			for i in range(m.get_surface_count()):
				print("%s   surface %d = %s" % [pad, i, _describe(m.surface_get_material(i))])
	else:
		print("%s%s  (%s)" % [pad, n.name, n.get_class()])
	for c in n.get_children():
		_walk(c, depth + 1)


func _describe(mat: Material) -> String:
	if mat == null:
		# This is a real answer, not a miss: a mesh with NO material is drawn by
		# Godot in its own default, and matching that means assigning nothing
		# rather than assigning a colour.
		return "none (Godot draws its own default)"
	if mat is StandardMaterial3D:
		var s := mat as StandardMaterial3D
		# THE TEXTURE IS THE QUESTION. A white albedo with an orange sheet looks
		# orange; a white albedo with nothing looks white. Reporting only the
		# colour would have answered "not orange" and been wrong about why.
		var tex := s.albedo_texture
		var tname := "none"
		if tex != null:
			tname = "%s %dx%d" % [tex.resource_path, tex.get_width(), tex.get_height()]
		return "StandardMaterial3D albedo=%s tex=%s metallic=%.2f roughness=%.2f shading=%d" \
			% [str(s.albedo_color), tname, s.metallic, s.roughness, s.shading_mode]
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		return "ShaderMaterial shader=%s" % (sm.shader.resource_path if sm.shader else "null")
	return "%s path=%s" % [mat.get_class(), mat.resource_path]
