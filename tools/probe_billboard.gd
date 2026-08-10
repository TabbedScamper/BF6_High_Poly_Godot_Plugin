@tool
extends SceneTree
# DOES THIS PROP CARRY AN OBJECT VARIATION, AND DOES IT SURVIVE?
#
# "The billboard is meant to have a custom picture" is a claim about a
# variation: the sign mesh is shared and the picture on it comes from an
# ObjectVariation that swaps the material. Three things can go wrong and they
# need different fixes, so name which:
#
#   the row carries no variation   the walk dropped it
#   it carries one, _variation_live returns 0   the depot has no record for
#                                   key+hash, so we treat the variation as
#                                   changing nothing and draw the base sign
#   it survives                     the variation is applied and the picture is
#                                   a texture problem, not a variation one

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var want := str(args[1]).to_lower() if args.size() > 1 else "com_billboard_sign"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("open failed: ", gs.error); quit(1); return

	var n := 0
	var with_var := 0
	var survived := 0
	print("%-34s %-22s %-11s %-11s %s" % ["mesh", "scope", "var hash",
		"lives?", "ObjectVariation"])
	for r in gs.walk.rows:
		var row: Dictionary = r
		var mesh := str(row.get("mesh", "")).get_file().to_lower()
		if mesh.findn(want) < 0:
			continue
		n += 1
		if n > 24:
			continue
		var res_name: String = gs.resolve_mesh(str(row.get("mesh", "")))
		var scope := str(row.get("scope", ""))
		var ov = row.get("var")
		var vh: int = gs._var_hash(ov)
		var live: int = gs._variation_live(scope, vh, res_name)
		if vh != 0:
			with_var += 1
		if live != 0:
			survived += 1
		print("%-34s %-22s %-11s %-11s %s" % [mesh.left(34), scope.get_file().left(22),
			("0x%08X" % vh) if vh != 0 else "(none)",
			("0x%08X" % live) if live != 0 else "NO - base look",
			str(ov).get_file() if ov != null else "-"])
	print("")
	print("%d placement(s); %d carry a variation; %d of those survive the depot"
		% [n, with_var, survived])

	# and what the section keys look up to, which is what a picture really is
	for r in gs.walk.rows:
		var row: Dictionary = r
		if str(row.get("mesh", "")).get_file().to_lower().findn(want) < 0:
			continue
		var res_name: String = gs.resolve_mesh(str(row.get("mesh", "")))
		var scope := str(row.get("scope", ""))
		print("")
		print("section keys of %s in scope %s:" % [res_name.get_file(), scope.get_file()])
		for k in gs._section_keys(res_name):
			print("   key %s" % ("0x%016X" % int(k) if int(k) >= 0 else str(k)))
		var gkey := "%s|%s|%d" % [res_name, scope,
			gs._variation_live(scope, gs._var_hash(row.get("var")), res_name)]
		var m: Mesh = gs.mesh_for(gkey)
		if m == null:
			print("   (no mesh built)")
			break
		print("   %d surface(s)" % m.get_surface_count())
		for i in range(m.get_surface_count()):
			var mat := m.surface_get_material(i)
			# MOST OF THESE ARE ShaderMaterial, NOT BaseMaterial3D. The props are
			# drawn through prop_tint.gdshader, so a BaseMaterial3D-only check
			# reports "(no albedo)" for every one of them - including a plain
			# cardboard box that is textured perfectly well. Checked against that
			# control before believing anything here.
			print("   surface %d  %s" % [i, _describe_mat(mat)])
		break
	quit(0)


func _describe_mat(mat) -> String:
	if mat == null:
		return "(no material)"
	if mat is BaseMaterial3D:
		var t := (mat as BaseMaterial3D).albedo_texture
		return "StandardMaterial3D  %s" % _tex(t)
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var sh := sm.shader
		var bits := PackedStringArray()
		if sh != null:
			for u in sh.get_shader_uniform_list():
				var nm := str((u as Dictionary).get("name", ""))
				var v = sm.get_shader_parameter(nm)
				if v is Texture2D:
					bits.append("%s=%s" % [nm, _tex(v)])
			if bits.is_empty():
				bits.append("no texture parameter set")
		return "ShaderMaterial(%s)  %s" % [
			sh.resource_path.get_file() if sh != null else "?",
			", ".join(bits)]
	return str(mat)


func _tex(t) -> String:
	if t == null:
		return "(none)"
	var nm: String = t.resource_name if t.resource_name != "" else \
		(t.resource_path.get_file() if t.resource_path != "" else "(unnamed)")
	return "%s %dx%d" % [nm, t.get_width(), t.get_height()]
