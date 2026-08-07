extends SceneTree

# Lights, FX and roads, from the install alone.
#
# These are the three layers the download path still owned after the props, the
# terrain and the water were moved across. Each has a shipped consumer that
# already knows how to draw it, so the only question this asks is whether the
# reader produces the same SHAPE of data from the game — and, where a Python
# miner exists to compare against, the same numbers.
#
#   godot --headless --path <proj> --script test_scenery.gd -- [level] [cache_dir]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var cache := "user://scenery_test"
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			cache = s

	var t0 := Time.get_ticks_msec()
	var gs = HighpolyGameSource.new()
	gs.build_materials = true
	if not gs.open_map(level):
		print("FAIL: open_map — %s" % gs.error)
		quit(1); return
	print("opened in %.1f s: %d placements, %d collected entities%s"
		% [(Time.get_ticks_msec() - t0) / 1000.0, gs.walk.rows.size(),
		   gs.walk.ents.size(),
		   "  (cached)" if gs.walk.stats.get("from_cache", false) else ""])
	for k in ["ent_xf_0xD6351EDE", "ent_xf_0x7B554EF5", "ent_xf_parent"]:
		if gs.walk.stats.has(k):
			print("   %-22s %d" % [k, gs.walk.stats[k]])

	var fail := 0

	# ---- lights ----------------------------------------------------------
	print("\n--- lights ---")
	var n_lights: int = gs.lights(cache)
	if n_lights == 0:
		print("FAIL: no lights")
		fail += 1
	else:
		var p := "%s/lights.json" % cache
		var d = JSON.parse_string(FileAccess.get_file_as_string(p))
		if not (d is Dictionary) or not (d as Dictionary).has("lights"):
			print("FAIL: lights.json is not the shape the light layer reads")
			fail += 1
		else:
			var all: Array = (d as Dictionary)["lights"]
			var by_type := {}
			var ylo := INF
			var yhi := -INF
			var spots := 0
			var with_dir := 0
			var bad := 0
			for L in all:
				var rec: Dictionary = L
				by_type[str(rec["type"])] = int(by_type.get(str(rec["type"]), 0)) + 1
				var pos: Array = rec["pos"]
				ylo = minf(ylo, float(pos[1]))
				yhi = maxf(yhi, float(pos[1]))
				if bool(rec["spot"]):
					spots += 1
					if rec.has("dir"):
						with_dir += 1
				# The fields the consumer indexes without checking. A missing one
				# is a crash in the editor, which is a poor place to find it.
				for k in ["pos", "spot", "radius", "color", "intensity", "unit",
						"layer"]:
					if not rec.has(k):
						bad += 1
			print("%d lights (%d spot, %d of those with a direction)"
				% [all.size(), spots, with_dir])
			print("   height range %.1f .. %.1f m" % [ylo, yhi])
			for k in by_type:
				print("   %-24s %d" % [k, by_type[k]])
			if bad > 0:
				print("FAIL: %d record(s) missing a field the consumer reads" % bad)
				fail += 1
			# A light at the world origin is the signature of a transform that
			# was never composed. A handful is plausible; thousands is the bug
			# the Python has, where BlueprintTransform is read off a type that
			# does not have one and every fixture lands on its holder.
			var at_origin := 0
			for L in all:
				var pos: Array = (L as Dictionary)["pos"]
				if absf(float(pos[0])) < 0.01 and absf(float(pos[2])) < 0.01:
					at_origin += 1
			print("   at the world origin: %d (%.1f%%)"
				% [at_origin, 100.0 * at_origin / maxi(all.size(), 1)])

	# ---- fx --------------------------------------------------------------
	print("\n--- fx ---")
	var n_fx: int = gs.fx(cache)
	if n_fx == 0:
		print("FAIL: no fx")
		fail += 1
	else:
		var d2 = JSON.parse_string(FileAccess.get_file_as_string("%s/fx.json" % cache))
		var all2: Array = (d2 as Dictionary)["fx"]
		var by_cls := {}
		var joined := 0
		for F in all2:
			var rec: Dictionary = F
			by_cls[str(rec["class"])] = int(by_cls.get(str(rec["class"]), 0)) + 1
			if str(rec["effect"]).begins_with("EG_"):
				joined += 1
		print("%d ambient points, %d event-triggered excluded"
			% [all2.size(), int((d2 as Dictionary).get("_triggered_excluded", 0))])
		print("   joined an emitter graph: %d (%.0f%%)"
			% [joined, 100.0 * joined / maxi(all2.size(), 1)])
		for k in by_cls:
			print("   %-10s %d" % [k, by_cls[k]])

	# ---- roads -----------------------------------------------------------
	print("\n--- roads ---")
	# The drape needs the heightfield, and terrain() is what composites it.
	var hm: Dictionary = gs.terrain(cache)
	if hm.is_empty():
		print("FAIL: no terrain, so nothing to drape the roads on")
		fail += 1
	else:
		var t1 := Time.get_ticks_msec()
		var m: Mesh = gs.roads()
		if m == null:
			print("FAIL: no roads")
			fail += 1
		else:
			print("%d surface(s), %d triangles, built in %d ms"
				% [m.get_surface_count(), int(gs.road_stats.get("drawn_triangles", 0)),
				   Time.get_ticks_msec() - t1])
			for k in ["records", "declared", "triangles", "chain_ok", "anchor_ok",
					"truncated_at"]:
				print("   %-14s %s" % [k, gs.road_stats.get(k, "?")])
			var aabb := m.get_aabb()
			print("   bounds  x %.0f..%.0f  y %.1f..%.1f  z %.0f..%.0f"
				% [aabb.position.x, aabb.end.x, aabb.position.y, aabb.end.y,
				   aabb.position.z, aabb.end.z])
			# The roads must sit ON the ground. A y range that spans the whole
			# map height says the drape sampled the grid wrong, and that looks
			# like a road network hanging in the air rather than an error.
			var span := aabb.size.y
			var terr_span: float = float(hm.get("scale", 256.0))
			print("   vertical span %.1f m against a %.0f m map" % [span, terr_span])
			var textured := 0
			for i in range(m.get_surface_count()):
				var mat = m.surface_get_material(i)
				# get_shader_parameter returns NULL for a parameter that was never
				# set, and bool(null) is not a constructor in GDScript — compare
				# against true instead of coercing.
				if mat is ShaderMaterial \
						and (mat as ShaderMaterial).get_shader_parameter("has_cv") == true:
					textured += 1
			print("   surfaces with a basecolor: %d of %d"
				% [textured, m.get_surface_count()])

	print("\n%s" % ("PASS" if fail == 0 else "FAIL (%d problem(s))" % fail))
	quit(0 if fail == 0 else 1)
