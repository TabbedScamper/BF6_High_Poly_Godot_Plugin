@tool
extends SceneTree

# Load EVERY script and shader in the addon, as a SET.
#
# --check-only --script parses ONE file in isolation and cannot see a caller and
# a callee drift apart, which is exactly how "Failed to load script
# highpoly_toggle.gd" got reported for a break that was really in water/
# mapcontext. load() resolves preloads and class_name references, so a missing
# or renamed function on the other side of a dependency shows up here.

func _init() -> void:
	var dir := "res://addons/highpoly_toggle/"
	var names := DirAccess.get_files_at(dir)
	names.sort()
	var bad := 0
	var n_gd := 0
	var n_sh := 0
	for f in names:
		if f.ends_with(".gd"):
			n_gd += 1
		elif f.ends_with(".gdshader"):
			n_sh += 1
		else:
			continue
		var r = ResourceLoader.load(dir + f, "", ResourceLoader.CACHE_MODE_REPLACE)
		if r == null:
			print("FAILED TO LOAD: ", f)
			bad += 1
			continue
		if r is Shader:
			# LOADING A SHADER PROVES NOTHING. A .gdshader referencing an
			# undefined symbol loads fine and reports no error, even under
			# --rendering-driver vulkan. Asking for the uniform list is what
			# forces the compile: the dummy renderer then prints "Shader
			# compilation failed" and the list comes back EMPTY.
			var u := (r as Shader).get_shader_uniform_list()
			if u.is_empty():
				print("SHADER COMPILE FAILED: ", f)
				bad += 1
			continue
		if f.ends_with(".gd") and r is GDScript:
			# load() can return a script object whose compile failed;
			# can_instantiate is false for @tool-less abstract cases too, so
			# check the reload result.
			var err := (r as GDScript).reload()
			if err != OK:
				print("RELOAD ERROR %d: %s" % [err, f])
				bad += 1
	print("checked %d scripts, %d shaders" % [n_gd, n_sh])
	if bad == 0:
		print("SET OK")
	else:
		print("SET BROKEN: %d file(s)" % bad)
	quit(1 if bad else 0)
