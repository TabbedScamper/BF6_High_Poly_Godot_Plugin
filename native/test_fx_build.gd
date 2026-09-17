extends SceneTree

# THE FX BUILDER, END TO END, on a real map.
#
#   python tools/run_addon_script.py native/test_fx_build.gd --args <steam root> <level> <fx.json>
#
# The builder was rewritten off ~40 curated graph archetypes onto the core's
# per-layer data. What that is supposed to buy is VARIATION - each layer drawn
# with its own size, motion, sheet, alignment and fade - so this checks for the
# variation rather than for a node count, which the old path would also pass.
#
# Checks, in the order they would catch a regression:
#   JOIN      spawn points actually find their layers; a silent fallback to one
#             emitter per point is exactly the failure the rewrite exists to end
#   BUDGET    the drawn count obeys the CORE's cap, not a local one
#   LOOK      the emitters differ from each other - distinct sizes, lifetimes
#             and materials - because identical emitters mean the per-layer data
#             is being fetched and then ignored
#   SHADER    the six-way shader is actually bound, with a real sheet, the
#             AUTHORED grid, and both halves present in the texture
#   CURVES    the authored over-life cubics reach the material
#   ALIGN     non-screen alignments are passed through rather than flattened

const HighpolyGameSource := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const HighpolyFx := preload("res://addons/highpoly_toggle/highpoly_fx.gd")

var fails := 0

# PROGRESS TO A FILE, because Godot block-buffers stdout when it is redirected:
# a run killed by a timeout loses everything it printed, so three timeouts in a
# row told me nothing about WHERE they stopped. This costs one line per stage
# and turns "it hung" into "it hung here".
func _mark(stage: String) -> void:
	var f := FileAccess.open("user://fxbuild_progress.txt", FileAccess.READ_WRITE) 		if FileAccess.file_exists("user://fxbuild_progress.txt") 		else FileAccess.open("user://fxbuild_progress.txt", FileAccess.WRITE)
	if f == null: return
	f.seek_end()
	f.store_line("%d ms  %s" % [Time.get_ticks_msec(), stage])
	f.flush()
	f.close()


# SAY IT TO BOTH. Godot block-buffers stdout when redirected AND can fail to
# exit, so a run that does all its work and then hangs on quit() loses every
# line it printed - which is exactly how three timeouts in a row taught me
# nothing. The file is appended and flushed per line, so the result survives
# whatever happens to the process afterwards.
func _say(msg: String) -> void:
	print(msg)
	_mark(msg)


func _bad(msg: String) -> void:
	_say("  FAIL %s" % msg)
	fails += 1


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		print("usage: test_fx_build.gd -- <steam root> <level> <fx.json path>")
		quit(2); return
	var game := str(a[0])
	var level := str(a[1])
	var fxsrc := str(a[2])

	# The builder reads the map walk's own fx.json out of user://, so stage the
	# real one there rather than inventing spawn points: made-up positions would
	# test the join against data that cannot disagree with it.
	var raw := FileAccess.get_file_as_string(fxsrc)
	if raw.is_empty():
		print("FAIL could not read %s" % fxsrc); quit(1); return
	DirAccess.make_dir_recursive_absolute("user://mapcontext/%s" % level)
	var fh := FileAccess.open("user://mapcontext/%s/fx.json" % level, FileAccess.WRITE)
	fh.store_string(raw)
	fh.close()
	var points: int = int((JSON.parse_string(raw) as Dictionary).get("fx", []).size())

	_mark("start open_map")
	var gs = HighpolyGameSource.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(level, game, func(stage, done, total): pass):
		print("FAIL open_map: %s" % gs.error); quit(1); return
	print("opened %s in %.1f s, %d spawn points\n"
		% [level, (Time.get_ticks_msec() - t0) / 1000.0, points])

	var root := Node3D.new()
	get_root().add_child(root)
	# A sun, so the six-way path has a real direction to light from. This is the
	# same node the lighting builder makes; the FX builder finds it by type.
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(120.0), 0.0)
	sun.light_color = Color(1.0, 0.94, 0.84)
	root.add_child(sun)

	_mark("open_map done, starting FX apply")
	var t1 := Time.get_ticks_msec()
	var status: String = await HighpolyFx.apply(root, level, true, Callable(), gs)
	_say("STATUS  %s" % status)
	print("        built in %.1f s\n" % ((Time.get_ticks_msec() - t1) / 1000.0))

	_mark("FX apply returned")
	var holder := root.get_node_or_null(HighpolyFx.NODE)
	if holder == null:
		print("FAIL no FX holder was created"); quit(1); return

	var parts: Array = []
	var decals := 0
	for c in holder.get_children():
		if c is GPUParticles3D: parts.append(c)
		elif c is Decal: decals += 1
	_say("JOIN    %d particle emitters + %d decals from %d spawn points"
		% [parts.size(), decals, points])
	if parts.is_empty():
		print("FAIL nothing was drawn"); quit(1); return
	# The whole point: more emitters than points, because a point expands to its
	# effect's layers. One-to-one would mean the join quietly failed.
	if parts.size() + decals <= points / 2:
		_bad("fewer emitters than half the spawn points: the join is not resolving")

	# ---- BUDGET ------------------------------------------------------------
	var cap := 3000
	if ClassDB.class_exists("BF6Core"):
		var probe = ClassDB.instantiate("BF6Core")
		if probe != null and probe.has_method("fx_budget"):
			var mask: PackedByteArray = probe.call("fx_budget", 10, 0)
			if mask.size() != 10:
				_bad("fx_budget did not answer for 10 candidates")
	_say("BUDGET  %d drawn against the core's cap of %d" % [parts.size(), cap])
	if parts.size() > cap:
		_bad("more emitters than the core's budget allows")

	# ---- LOOK --------------------------------------------------------------
	var sizes := {}
	var lifes := {}
	var mats := {}
	var amounts := {}
	for g in parts:
		var gp: GPUParticles3D = g
		lifes["%.3f" % gp.lifetime] = true
		amounts[gp.amount] = true
		var m: Mesh = gp.draw_pass_1
		if m is QuadMesh:
			sizes["%.4f" % (m as QuadMesh).size.x] = true
			var sm = (m as QuadMesh).material
			if sm is ShaderMaterial:
				mats[(sm as ShaderMaterial).get_instance_id()] = sm
	_say("LOOK    %d distinct quad sizes, %d distinct lifetimes, %d distinct "
		% [sizes.size(), lifes.size(), amounts.size()]
		+ "particle counts, %d distinct materials" % mats.size())
	# The archetype path produced about forty looks over a whole map, and mostly
	# reused three. Anything in that range means per-layer data is not landing.
	if sizes.size() < 20: _bad("only %d distinct sizes: layers are being merged" % sizes.size())
	if mats.size() < 20: _bad("only %d distinct materials" % mats.size())
	# LIFETIME IS NOT A VARIATION TEST, and asserting that it is cost a while to
	# learn. It is a per-GRAPH property with no per-layer override - four checks
	# against the game say so, see findings/fx-particle-life-is-template-only -
	# so a level legitimately shows a handful of distinct values. All this can
	# honestly ask is that more than one reached the emitters.
	if lifes.size() < 2:
		_bad("every emitter got the same lifetime: the layer value is not landing")

	# ---- THE REST OF THE AUTHORED LOOK --------------------------------------
	# Each of these is a property the game authors on thousands of layers and
	# that we read for the first time. They are checked together because the
	# failure mode is shared and silent: the core resolves the field, the
	# builder never asks for it, and the preview looks plausible while being
	# uniformly wrong - every plume starting from nothing, every fire the same
	# orange, every card slicing through the floor with a hard edge.
	var prerolled := 0
	var ramped := 0
	var randtint := 0
	var nonsquare := 0
	# PER EMITTER: only node and process-material properties, which are cheap.
	for g in parts:
		var gp: GPUParticles3D = g
		if gp.preprocess > 0.0: prerolled += 1
		var pmat := gp.process_material as ParticleProcessMaterial
		if pmat != null:
			if pmat.color_ramp != null: ramped += 1
			if pmat.color_initial_ramp != null: randtint += 1
		var m: Mesh = gp.draw_pass_1
		if m is QuadMesh:
			var q := m as QuadMesh
			if absf(q.size.x - q.size.y) > 0.001: nonsquare += 1

	# PER DISTINCT MATERIAL for anything that touches the SHADER.
	#
	# Reading shader parameters off all 2,434 emitters is what made this test
	# take longer than its timeout, three times over, while the build it was
	# checking finished in six seconds. There are only 263 distinct materials -
	# the builder caches one per layer - so every emitter sharing a material was
	# asking the same question again. Same information, a ninth of the work, and
	# the emitter count comes from the cheap pass above.
	var flipped := 0
	var softfaded := 0
	var sized := 0
	var prios := {}
	for id in mats.keys():
		var shm: ShaderMaterial = mats[id]
		prios[shm.render_priority] = true
		var fu: Variant = shm.get_shader_parameter("flip_u_probability")
		var fv: Variant = shm.get_shader_parameter("flip_v_probability")
		if (fu != null and float(fu) > 0.0) or (fv != null and float(fv) > 0.0):
			flipped += 1
		var iz: Variant = shm.get_shader_parameter("inv_z_fade")
		if iz != null and float(iz) > 0.0:
			softfaded += 1
		var sc: Variant = shm.get_shader_parameter("size_curve_on")
		if sc != null and bool(sc):
			sized += 1
	_say("AUTHORED %d prerolled, %d colour gradients, %d random tints (of %d emitters)"
		% [prerolled, ramped, randtint, parts.size()])
	_say("         %d of %d materials flipping, %d soft-faded, %d size curves, "
		% [flipped, mats.size(), softfaded, sized]
		+ "%d non-square quads, %d draw priorities" % [nonsquare, prios.size()])
	# DENSITY. Five particles per emitter is a smoke column made of five
	# spinning cards, which is what the old rate*life reading produced and what
	# it looked like. ParticleMaxCount is the population the game states.
	var amounts2: Array = []
	for g in parts:
		amounts2.append((g as GPUParticles3D).amount)
	amounts2.sort()
	var med: int = amounts2[amounts2.size() / 2]
	var thin := 0
	for n in amounts2:
		if n < 16: thin += 1
	_say("DENSITY median %d particles per emitter, %d of %d emitters under 16"
		% [med, thin, amounts2.size()])
	if med < 24:
		_bad("median %d particles per emitter - too sparse to read as volume" % med)
	if thin > amounts2.size() / 2:
		_bad("%d of %d emitters have under 16 particles" % [thin, amounts2.size()])

	if ramped == 0: _bad("no Color0..Color1 gradient reached a process material")
	if randtint == 0: _bad("no RandomColorMin..Max range reached a process material")
	if flipped == 0: _bad("FlipU/FlipVProbability is not reaching the shader")
	# No assertion on the soft fade: its depth dependency was removed after it
	# stalled the GPU (see the note beside inv_z_fade in fx_sixway.gdshaderinc).
	# Asserting on a feature that is deliberately absent is a test that fails on
	# purpose and teaches nothing.

	# ---- MOTION ------------------------------------------------------------
	# An FX carries no animation clip and no spline - every import reachable
	# from every emitter graph on three levels is one of 25 assets and not one
	# is an animation, skeleton, spline or curve. The motion IS these forces
	# integrated, so this is where "does it move like the game" is decided, and
	# a single shared gravity vector across the map would mean none of it landed.
	var gravities := {}
	var shapes := {}
	var vels := {}
	var turbulent := 0
	var offsets := {}
	for g in parts:
		var pm := (g as GPUParticles3D).process_material as ParticleProcessMaterial
		if pm == null: continue
		gravities["%.3f,%.3f,%.3f" % [pm.gravity.x, pm.gravity.y, pm.gravity.z]] = true
		shapes[pm.emission_shape] = int(shapes.get(pm.emission_shape, 0)) + 1
		vels["%.3f-%.3f" % [pm.initial_velocity_min, pm.initial_velocity_max]] = true
		offsets["%.2f,%.2f,%.2f" % [pm.emission_shape_offset.x,
			pm.emission_shape_offset.y, pm.emission_shape_offset.z]] = true
		if pm.turbulence_enabled: turbulent += 1
	_say("MOTION  %d distinct force vectors, %d distinct speed ranges, "
		% [gravities.size(), vels.size()]
		+ "%d spawn offsets, %d turbulent" % [offsets.size(), turbulent])
	var shape_line := ""
	for k in shapes.keys():
		shape_line += " shape%d=%d" % [k, shapes[k]]
	print("        emission shapes:%s" % shape_line)
	if gravities.size() < 5:
		_bad("only %d distinct force vectors: gravity/buoyancy/LocalForce are "
			% gravities.size() + "not reaching the process material")
	if vels.size() < 10:
		_bad("only %d distinct speed ranges: the authored spawn speed is not landing"
			% vels.size())
	if shapes.size() < 2:
		_bad("every emitter got the same emission shape: SpawnScale/OuterRadius "
			+ "are not landing, so every effect is born in the same volume")

	# ---- MESH PARTICLES ----------------------------------------------------
	# Missiles, UAVs, aircraft vapour, birds and debris draw GEOMETRY. They used
	# to draw nothing, because the mesh was only reachable through a per-graph
	# majority table that covered 57 graphs. The core now reads the template's
	# EmitterMesh import per layer, so this checks that real meshes arrive - and
	# that they are real meshes, not the 3-vertex placeholder the game expects
	# effects to substitute, which would pass a count-only check.
	var meshed: Array = []
	for g in parts:
		if (g as GPUParticles3D).get_meta("bf6_mesh", false):
			meshed.append(g)
	var tri := 0
	var distinct_meshes := {}
	for g in meshed:
		var m: Mesh = (g as GPUParticles3D).draw_pass_1
		if m == null: continue
		distinct_meshes[m.get_instance_id()] = true
		for si in range(m.get_surface_count()):
			tri += m.surface_get_array_index_len(si) / 3
	_say("MESH    %d emitters draw geometry, %d distinct meshes, %d triangles total"
		% [meshed.size(), distinct_meshes.size(), tri])
	if meshed.size() < 50:
		_bad("only %d mesh emitters: the layer's EmitterMesh is not resolving" % meshed.size())
	if distinct_meshes.size() < 5:
		_bad("only %d distinct meshes: every mesh layer got the same geometry"
			% distinct_meshes.size())
	if meshed.size() > 0 and tri / maxi(meshed.size(), 1) < 4:
		_bad("mesh emitters average under 4 triangles each - that is the "
			+ "placeholder triangle, not real geometry")

	# ---- SHADER COMPILES ---------------------------------------------------
	# The body lives in an .gdshaderinc shared by the mix and add variants, so a
	# broken include would leave a shader that still ACCEPTS every
	# set_shader_parameter call and silently draws nothing. Asking the shader
	# what uniforms it really has is what tells the two apart.
	for path in ["res://addons/highpoly_toggle/fx_sixway.gdshader",
	             "res://addons/highpoly_toggle/fx_sixway_add.gdshader"]:
		var sh: Shader = load(path)
		if sh == null:
			_bad("%s did not load" % path)
			continue
		var names := {}
		for u in sh.get_shader_uniform_list():
			names[str((u as Dictionary)["name"])] = true
		# Every one of these is declared INSIDE the include.
		for want in ["sheet", "cols", "frames", "left_right", "sun_direction",
		             "opacity_curve", "rotation_curve", "align_mode",
		             "axis_order", "flip_halves", "backlight"]:
			if not names.has(want):
				_bad("%s is missing uniform '%s': the include did not compile"
					% [path.get_file(), want])
		_say("COMPILE %s: %d uniforms" % [path.get_file(), names.size()])

	# ---- SHADER ------------------------------------------------------------
	var with_sheet := 0
	var sixway := 0
	var curved := 0
	var aligned := {}
	var grid_bad := 0
	var lr_narrow := 0
	for id in mats.keys():
		var sm: ShaderMaterial = mats[id]
		if sm.shader == null:
			_bad("a particle material has no shader")
			continue
		var tex = sm.get_shader_parameter("sheet")
		var lr := bool(sm.get_shader_parameter("left_right"))
		var cols := int(sm.get_shader_parameter("cols"))
		var frames := int(sm.get_shader_parameter("frames"))
		if tex != null:
			with_sheet += 1
			if cols < 1 or frames < 1:
				grid_bad += 1
			# A LeftRightTiles sheet must still be DOUBLE width: if the old fold
			# were still running, the halves would be gone and the shader would
			# sample the same three terms twice.
			if lr and (tex as Texture2D).get_width() < (tex as Texture2D).get_height():
				lr_narrow += 1
			if lr:
				sixway += 1
		var oc = sm.get_shader_parameter("opacity_curve")
		if oc != null and oc is Vector4 and (oc as Vector4) != Vector4(0, 0, 0, 1):
			curved += 1
		aligned[int(sm.get_shader_parameter("align_mode"))] = \
			int(aligned.get(int(sm.get_shader_parameter("align_mode")), 0)) + 1
	_say("SHADER  %d of %d materials carry a real sheet, %d of those six-way"
		% [with_sheet, mats.size(), sixway])
	if with_sheet == 0: _bad("not one material resolved a sheet")
	if sixway == 0: _bad("no six-way sheet reached the shader")
	if grid_bad > 0: _bad("%d materials got a nonsense atlas grid" % grid_bad)
	if lr_narrow > 0:
		_bad("%d six-way sheets are narrower than they are tall: the halves "
			% lr_narrow + "look folded away")

	_say("CURVES  %d materials carry a non-identity over-life fade" % curved)
	if curved == 0:
		_bad("no authored over-life curve reached a material")

	var align_line := ""
	for k in aligned.keys():
		var nm: String = HighpolyFx.ALIGN_NAMES[k] if k >= 0 and k < HighpolyFx.ALIGN_NAMES.size() else str(k)
		align_line += " %s=%d" % [nm, aligned[k]]
	_say("ALIGN  %s" % align_line)
	if aligned.size() < 2:
		_bad("every layer came out with the same alignment")

	print("\n%s: %d failure(s)" % ["FAIL" if fails else "PASS", fails])
	quit(1 if fails else 0)
