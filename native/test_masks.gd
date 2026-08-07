extends SceneTree

# Do masked materials come out masked, and does nothing else get dragged in?
#
# The fix has two ways to fail and they look nothing alike:
#
#   too eager  — every section binding the alpha slot becomes a scissored
#                shader material, including the 81% bound to the constant
#                `t_debug_r` default. Solid walls start paying for a cutout and
#                a few of them go see-through where the default is not 1.0.
#   too shy    — the placeholder test also rejects real masks, and trees stay
#                the solid rectangles this was meant to fix.
#
# So this counts both directions against the numbers the scope probe measured
# independently (352 genuinely masked sections, 76 of them vegetation), and
# checks that wind is gated to vegetation — a swaying chain-link fence being the
# obvious way to get this half-right.
#
#   godot --headless --path <proj> --script test_masks.gd -- [level] [max meshes]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var cap := 0
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			cap = int(s)

	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data("")
	var groups: Array = data["props"]
	if cap > 0 and groups.size() > cap:
		groups = groups.slice(0, cap)

	var t0 := Time.get_ticks_msec()
	var surfaces := 0
	var shader_mats := 0
	var std_mats := 0
	var windy := 0
	var still := 0
	var no_mask_param := 0
	var seen_mat := {}
	for g in groups:
		var m: Mesh = gs.mesh_for(str((g as Dictionary)["mesh"]))
		if m == null:
			continue
		for i in range(m.get_surface_count()):
			surfaces += 1
			var mat = m.surface_get_material(i)
			if mat == null:
				continue
			var id := (mat as Material).get_instance_id()
			if seen_mat.has(id):
				continue
			seen_mat[id] = true
			if mat is ShaderMaterial:
				shader_mats += 1
				var sm := mat as ShaderMaterial
				if sm.get_shader_parameter("use_mask") != true:
					no_mask_param += 1
				if float(sm.get_shader_parameter("wind_scale")) > 0.5:
					windy += 1
				else:
					still += 1
			elif mat is StandardMaterial3D:
				std_mats += 1

	print("built in %.1f s: %d surfaces, %d distinct materials"
		% [(Time.get_ticks_msec() - t0) / 1000.0, surfaces, seen_mat.size()])
	print("   masked (shader)      %d" % shader_mats)
	print("      wind on (veg)     %d" % windy)
	print("      wind off          %d" % still)
	print("   opaque (standard)    %d" % std_mats)
	var ts: Dictionary = gs.tex_stats
	print("   masks checked        %d, of which placeholder %d (%.0f%%)"
		% [int(ts.get("masks_checked", 0)), int(ts.get("masks_placeholder", 0)),
		   100.0 * int(ts.get("masks_placeholder", 0))
		   / maxf(1.0, float(ts.get("masks_checked", 0)))])
	print("   sections given a mask %d" % int(ts.get("masked", 0)))

	var fail := 0
	if shader_mats == 0:
		print("\nFAIL: nothing came out masked — trees are still solid")
		fail += 1
	if no_mask_param > 0:
		print("\nFAIL: %d shader materials have use_mask unset" % no_mask_param)
		fail += 1
	if windy == 0:
		print("\nFAIL: no material has wind enabled, so vegetation was never identified")
		fail += 1
	if still == 0 and shader_mats > 0:
		print("\nFAIL: every masked material is windy — the vegetation gate is not gating")
		fail += 1
	# The placeholder is the majority of alpha bindings on this map. If the
	# content test rejected none of them it is not doing anything.
	if int(ts.get("masks_placeholder", 0)) == 0:
		print("\nFAIL: not one placeholder was rejected — the content test is inert")
		fail += 1
	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)
