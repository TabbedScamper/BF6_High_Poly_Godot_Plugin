@tool
extends SceneTree
# CAN A PLACED OBJECT BE SKINNED WITH "Original map objects" OFF?
#
# That toggle decides `want.placements` for the read: with every map layer off,
# the placement walk is deliberately skipped, because skinning the props YOU
# placed does not need the map's own contents. The report is that it does need
# them - assets only take their real model once map objects is on - so run the
# same lookups both ways and print the difference.
#
#   ... probe_skin.gd -- MP_Aftermath acmodule_02 barrier_concrete_01 ...

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var keys: Array = []
	for i in range(1, args.size()):
		keys.append(str(args[i]).to_lower())
	if keys.is_empty():
		# a handful of ordinary SDK placeables
		keys = ["acmodule_02", "barrier_concrete_01", "crate_01", "dumpster_01"]

	for placements in [false, true]:
		print("=".repeat(74))
		print("placements=%s   (Original map objects %s)"
			% [placements, "ON" if placements else "OFF"])
		var gs = HighpolyGameSource.new()
		gs.log_fn = func(_s: String) -> void: pass
		gs.catalogue_mount = false
		if not gs.open_map(map, "", Callable(), {"placements": placements}):
			print("   open failed: %s" % str(gs.error))
			continue
		print("   walk rows %d   walk stats root '%s'"
			% [gs.walk.rows.size(), str(gs.walk.stats.get("root", ""))])
		# the catalogue is what a placeable is looked up in, and it is added on a
		# worker in the editor; do it here so both runs are compared fairly
		gs.upgrade_catalogue()
		print("   %-26s %-10s %-10s %s" % ["key", "has_object", "rows", "node"])
		for k in keys:
			var has: bool = gs.has_object(k)
			var rows: Array = gs.object_rows(k)
			var node = gs.object_node(k) if has else null
			var meshes := 0
			var surfaces := 0
			var dressed := 0          # surfaces carrying a material
			var textured := 0         # ...and a texture on it
			if node != null:
				var stack: Array = [node]
				while not stack.is_empty():
					var n: Node = stack.pop_back()
					for c in n.get_children():
						stack.append(c)
					if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
						continue
					meshes += 1
					var m: Mesh = (n as MeshInstance3D).mesh
					for s in range(m.get_surface_count()):
						surfaces += 1
						var mat = (n as MeshInstance3D).get_active_material(s)
						if mat == null:
							continue
						dressed += 1
						if _has_texture(mat):
							textured += 1
			print("   %-26s %-10s %-6d %s" % [k, str(has), rows.size(),
				("%d mesh, %d surf, %d dressed, %d textured"
					% [meshes, surfaces, dressed, textured])
				if node != null else "(none)"])
			if node != null:
				node.queue_free()
	quit(0)


# The props are drawn through prop_tint.gdshader, so a BaseMaterial3D-only check
# reports "no texture" for every one of them - including a crate that is
# textured perfectly well.
func _has_texture(mat) -> bool:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture != null
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		if sm.shader == null:
			return false
		for u in sm.shader.get_shader_uniform_list():
			if sm.get_shader_parameter(str((u as Dictionary).get("name", ""))) is Texture2D:
				return true
	return false
