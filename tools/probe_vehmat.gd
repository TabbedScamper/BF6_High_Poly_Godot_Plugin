@tool
extends SceneTree
const LibScript = preload("res://addons/highpoly_toggle/highpoly_lib.gd")
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	LibScript.game_source = gs
	for k in ["VEH_Abrams", "VEH_Marauder", "VEH_F22"]:
		var n = LibScript._instance_for(k, "vehicle://" + k)
		if n == null: print("%s: null" % k); continue
		for c in n.get_children():
			if not (c is MeshInstance3D): continue
			var am := (c as MeshInstance3D).mesh as ArrayMesh
			print("%s: %d surfaces" % [k, am.get_surface_count()])
			for i in range(am.get_surface_count()):
				var mat = am.surface_get_material(i)
				var sn := am.surface_get_name(i)
				var desc := "NO MATERIAL"
				if mat is StandardMaterial3D:
					var sm := mat as StandardMaterial3D
					desc = "Standard albedo=%s tex=%s" % [sm.albedo_color,
						"yes" if sm.albedo_texture != null else "NONE"]
				elif mat is ShaderMaterial:
					var shm := mat as ShaderMaterial
					var sh := shm.shader
					var parms := PackedStringArray()
					if sh != null:
						for u in sh.get_shader_uniform_list():
							var v = shm.get_shader_parameter(str(u["name"]))
							if v is Texture2D:
								parms.append("%s=%dx%d" % [str(u["name"]),
									(v as Texture2D).get_width(), (v as Texture2D).get_height()])
					desc = "Shader %s [%s]" % [
						"none" if sh == null else str(sh.resource_path).get_file(),
						", ".join(parms)]
				print("   surf %d  name '%s'  %s" % [i, sn, desc])
		n.queue_free()
	quit(0)
