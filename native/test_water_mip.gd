extends SceneTree

# THE BOILING FIX: can the mesh carry what the shader samples?
#
#   python tools/run_addon_script.py native/test_water_mip.gd --args <steam> [level]
#
# Tsuru Reef (mp_isolated) boiled in the Godot preview and looked right in
# Unreal. The cause was not the wave data: it was that the vertex shader chose
# its displacement mip from the SCREEN footprint alone, which goes to mip 0 near
# the camera and pulls in waves shorter than the distance between two vertices.
# A wave the mesh cannot represent makes every vertex sample an unrelated phase,
# and with a moving camera that spatial aliasing becomes temporal churn.
#
# The fix floors the mip at the mesh's own Nyquist limit. This test asserts the
# arithmetic against the level's REAL cascades rather than against a fixture,
# because the whole point is what this particular map authors:
#
#   #0 tile 300 m  res 128 -> texel 2.34 m    coarser than the mesh, floor 0
#   #1 tile 67.6 m res  64 -> texel 1.06 m    coarser than the mesh, floor 0
#   #2 tile 43 m   res  32 -> texel 1.34 m    coarser than the mesh, floor 0
#   #3 tile 12 m   res 128 -> texel 0.094 m   TEN TIMES finer - this one boiled
#
# It also checks that the shader is actually TOLD the mesh subdivision, since a
# floor computed from a patch_quads the material never received is a floor of
# zero and no fix at all.

const NativeWater := preload("res://addons/highpoly_toggle/highpoly_native_water.gd")

var fails := 0

func _bad(m: String) -> void:
	print("  FAIL %s" % m)
	fails += 1


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: test_water_mip.gd -- <steam root> [level]"); quit(2); return
	var level := str(a[1]) if a.size() > 1 else "mp_isolated"
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0])):
		print("FAIL open"); quit(1); return
	var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
	var w: Dictionary = env.request("water")
	if w.is_empty():
		print("FAIL water: %s" % str(env.error)); quit(1); return
	var sims: Array = w.get("sims", w.get("simulations", []))
	if sims.is_empty():
		# Not every level authors an ocean; say which rather than passing blind.
		print("%s authors no water simulation - nothing to check" % level)
		quit(0); return

	# The finest draw-tree tile is 16 m across and carries PATCH_QUADS quads.
	var vertex_spacing: float = 16.0 / float(NativeWater.PATCH_QUADS)
	print("%s: %d cascade(s), preview mesh %.3f m between vertices"
		% [level, sims.size(), vertex_spacing])
	print("  %-3s %-9s %-6s %-10s %-11s %s" % ["#", "tile_m", "res", "texel_m", "floor_mip", "note"])

	var floored := 0
	for i in range(sims.size()):
		var s: Dictionary = sims[i]
		var tile := float(s.get("tile_dimension", 0.0))
		var res := int(s.get("resolution", 0))
		if tile <= 0.0 or res <= 0:
			_bad("cascade %d has no tile/resolution: %s" % [i, str(s)])
			continue
		var texel := tile / float(res)
		# The shader's floor, written the same way it is in the shader.
		var floor_mip: float = maxf(log(maxf(vertex_spacing / texel, 1.0)) / log(2.0), 0.0)
		var note := "coarser than the mesh, unaffected"
		if floor_mip > 0.0:
			floored += 1
			note = "FINER than the mesh - floored, this is the one that boiled"
		print("  %-3d %-9.3f %-6d %-10.4f %-11.2f %s" % [i, tile, res, texel, floor_mip, note])

	# The assertion that matters: the fix has to BITE on at least one cascade,
	# or it is not doing anything and the water will boil exactly as before.
	if floored == 0:
		_bad("the mip floor raises nothing on %s - either the cascades changed "
			% level + "or the floor is computed wrongly")

	# And the shader has to be given the subdivision, or its floor is always 0.
	var mat := ShaderMaterial.new()
	var sh: Shader = load("res://addons/highpoly_toggle/water_native.gdshader")
	if sh == null:
		_bad("water_native.gdshader did not load")
	else:
		mat.shader = sh
		var names := {}
		for u in sh.get_shader_uniform_list():
			names[str((u as Dictionary)["name"])] = true
		if not names.has("patch_quads"):
			_bad("water_native.gdshader has no patch_quads uniform, so the mip "
				+ "floor has no mesh spacing to work from")
		if not names.has("cascade_texel_m"):
			_bad("water_native.gdshader has no cascade_texel_m uniform")

	print("\n%s: %d failure(s)" % ["FAIL" if fails else "PASS", fails])
	quit(1 if fails else 0)
