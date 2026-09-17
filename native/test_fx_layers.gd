extends SceneTree

# Per-layer FX through the binding: the data the Godot builder should be using
# instead of ~40 curated graph archetypes.
#
# The claim being tested is that per-layer data is worth the work. If the layers
# resolved to a handful of looks, the archetype table would be a fair summary
# and none of this would be needed - so the DISTINCT look count is the assertion,
# not the row count.

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_fx_layers.gd -- <Steam BF6 root> [level]")
		quit(2); return
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(args[0])):
		print("FAIL open"); quit(1); return
	var level := str(args[1]) if args.size() > 1 else "mp_subsurface"
	var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
	var d: Dictionary = env.request("fx_layers")
	if d.is_empty():
		print("FAIL fx_layers: %s" % str(env.error)); quit(1); return
	var rows: Array = d.get("layers", [])
	print("%s: %d layer(s)  note=%s effects=%d placements=%d" % [level, rows.size(), str(d.get("reader_note","")), int(d.get("stat_effects",0)), int(d.get("stat_placements",0))])
	if rows.is_empty():
		print("FAIL no layers"); quit(1); return

	var looks := {}
	var lighting := {}
	var aligns := {}
	var curves := 0
	var lit := 0
	var smin := 1e30
	var smax := -1e30
	for r in rows:
		var e: Dictionary = r
		var key := "%.3f|%.3f|%.3f|%.3f|%d|%d" % [
			float(e.get("base_size",0.0)), float(e.get("opacity",0.0)),
			float(e.get("drag",0.0)), float(e.get("rotation_speed",0.0)),
			int(e.get("lighting_model",-1)), int(e.get("alignment",-1))]
		looks[key] = true
		lighting[int(e.get("lighting_model",-1))] = int(lighting.get(int(e.get("lighting_model",-1)),0)) + 1
		aligns[int(e.get("alignment",-1))] = int(aligns.get(int(e.get("alignment",-1)),0)) + 1
		var has := int(e.get("has",0))
		# bit 4 = opacity-over-life, bit 18 = sun light scale (see bf6_core.h)
		if has & (1 << 4): curves += 1
		if has & (1 << 18): lit += 1
		var bs := float(e.get("base_size",0.0))
		if bs > 0.0:
			smin = minf(smin, bs); smax = maxf(smax, bs)
	print("   distinct looks: %d of %d" % [looks.size(), rows.size()])
	print("   lighting models: %s" % str(lighting))
	print("   alignments: %s" % str(aligns))
	print("   opacity-over-life authored on %d, sun-light scale on %d" % [curves, lit])
	print("   base size %.2f .. %.2f" % [smin, smax])
	var fail := 0
	if looks.size() < 8:
		print("   FAIL too few distinct looks for per-layer data to matter"); fail += 1
	if curves == 0:
		print("   FAIL no over-life curves came through"); fail += 1
	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(1 if fail else 0)
