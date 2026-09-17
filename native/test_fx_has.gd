extends SceneTree

# DOES `has` SURVIVE THE CROSSING? A narrow check between the core and the builder.
#
# The build test found 45 distinct force vectors (so gravity and buoyancy land)
# but every emitter on one emission shape and none turbulent - while the raw
# parameter dump says 33 layers author SpawnScale and 198 author a non-zero
# RandomForce on that same level. Something between the core's bitmask and the
# builder's `_has` is losing fields, and this says which side.
#
# It compares, per named field: how many layers the CORE says authored it,
# against how many have a non-default value. A field the core never reports is a
# core problem; a field the core reports and the builder ignores is a builder
# problem.

func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: test_fx_has.gd -- <steam root> [level]"); quit(2); return
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0])):
		print("FAIL open"); quit(1); return
	var level := str(a[1]) if a.size() > 1 else "mp_isolated"
	var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
	var d: Dictionary = env.request("fx_layers")
	if d.is_empty():
		print("FAIL fx_layers: %s" % str(env.error)); quit(1); return
	var rows: Array = d.get("layers", [])
	var bits: Dictionary = d.get("has_bits", {})
	print("%s: %d layers, has_bits names %d" % [level, rows.size(), bits.size()])
	if bits.is_empty():
		print("FAIL the core sent no has_bits map"); quit(1); return

	# The shape of the mask as it actually arrives.
	var sample: Dictionary = rows[0]
	print("has (first layer) = %s   type=%s"
		% [str(sample.get("has")), type_string(typeof(sample.get("has")))])

	var want := ["base_size", "gravity", "buoyancy", "drag", "drag_min_mult",
		"spawn_speed", "spawn_speed_mult", "random_force", "local_force",
		"spawn_scale", "spawn_position", "outer_radius", "color0",
		"random_color_min", "flip_v_probability", "backlight_contrast",
		"opacity_over_life", "drag_over_life", "buoyancy_over_life"]
	var fails := 0
	print("%-22s %5s %8s" % ["field", "bit", "authored"])
	for f in want:
		if not bits.has(f):
			print("%-22s   --  NOT NAMED BY THE CORE" % f)
			fails += 1
			continue
		var bit := int(bits[f])
		var n := 0
		for r in rows:
			var w: Array = (r as Dictionary).get("has", [])
			var i := bit >> 5
			if i < w.size() and ((int(w[i]) >> (bit & 31)) & 1) != 0:
				n += 1
		print("%-22s %5d %8d" % [f, bit, n])
		if n == 0:
			fails += 1
	print("\n%s: %d field(s) the core reports on no layer"
		% ["FAIL" if fails else "PASS", fails])
	quit(1 if fails else 0)
