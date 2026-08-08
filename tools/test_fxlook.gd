@tool
extends SceneTree

# What every FX emitter on a map ACTUALLY ends up looking like.
#
# test_fxsheets proves the flipbooks decode. This proves the other half: that
# the decoded sheet reaches a material, and that the material a spawn point gets
# is one that can draw. It builds the real material through _build_mats for
# every distinct (class, graph) pair the map's fx.json uses, and prints the
# handful of numbers that decide the look - texture, colour, quad size, blend,
# flipbook grid - so a wrong one is visible as a number rather than as a shape
# in a viewport.
#
#   godot --headless --path <proj> --script test_fxlook.gd [MAP]

const REAL_USER := "C:/Users/mwalt/AppData/Roaming/Godot/app_userdata/Battlefield\u2122 Portal Project"


func _init() -> void:
	var map := "MP_Aftermath"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		map = args[0]

	var fxp := "%s/mapcontext/%s/fx.json" % [REAL_USER, map]
	if not FileAccess.file_exists(fxp):
		print("no fx.json at %s" % fxp)
		quit(1)
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(fxp))
	if not (d is Dictionary):
		print("fx.json unreadable")
		quit(1)
		return

	var gs = HighpolyGameSource.new()
	if not gs.open_map(map):
		print("could not open the game source for %s" % map)
		quit(1)
		return
	HighpolyFx._load_params()
	var n_sheets := HighpolyFx._prime_sheets(gs)
	print("map %s: %d sheets decoded\n" % [map, n_sheets])

	# every distinct (class, graph) the map actually spawns, with counts
	var pairs := {}
	for f in d.get("fx", []):
		if not (f is Dictionary):
			continue
		if str(f.get("source_class", "base")).begins_with("seasonal"):
			continue
		var cls := str(f.get("class", ""))
		if not HighpolyFx.CLASS_FALLBACK.has(cls):
			cls = "other"
		var key := "%s|%s" % [cls, str(f.get("effect", ""))]
		pairs[key] = int(pairs.get(key, 0)) + 1

	var rows: Array = []
	for k in pairs.keys():
		rows.append([int(pairs[k]), k])
	rows.sort_custom(func(a, b): return a[0] > b[0])

	print("%-6s %-9s %-34s %-11s %-22s %-9s %-7s %s"
		% ["count", "class", "graph", "sheet", "colour", "quad", "blend", "grid"])
	var untextured := 0
	var textured := 0
	var suspect: Array = []
	for row in rows:
		var cnt: int = row[0]
		var parts: PackedStringArray = str(row[1]).split("|")
		var cls: String = parts[0]
		var effect: String = parts[1]
		var gp: Variant = HighpolyFx._params.get(effect.to_upper())
		var cfg: Array = HighpolyFx._build_mats(cls, gp)
		var pm: ParticleProcessMaterial = cfg[0]
		var qm: QuadMesh = cfg[1]
		var dm := qm.material as StandardMaterial3D
		var tex: Texture2D = dm.albedo_texture if dm != null else null
		var sheet := ""
		if gp is Dictionary:
			sheet = str((gp as Dictionary).get("sheet", "")).get_file().get_basename()
		if tex != null:
			textured += cnt
		else:
			untextured += cnt
		var c: Color = pm.color
		print("%-6d %-9s %-34s %-11s (%.2f,%.2f,%.2f,%.2f) %-9s %-7s %dx%d"
			% [cnt, cls, effect.substr(0, 34), ("yes" if tex else "-"),
			   c.r, c.g, c.b, c.a,
			   "%.2f" % qm.size.x, str(dm.blend_mode),
			   dm.particles_anim_h_frames, dm.particles_anim_v_frames])

		# what "looks broken" would be, stated as numbers
		if qm.size.x <= 0.001:
			suspect.append("%s: quad size %.4f" % [effect, qm.size.x])
		if qm.size.x > 200.0:
			suspect.append("%s: quad size %.1f m" % [effect, qm.size.x])
		if c.a <= 0.001:
			suspect.append("%s: alpha %.3f" % [effect, c.a])
		if c.r > 1.001 or c.g > 1.001 or c.b > 1.001:
			suspect.append("%s: colour out of range %s" % [effect, c])
		# green means g above BOTH others. The first version of this test asked
		# for max(g-r, g-b) and duly reported orange (1.0, 0.55, 0.2) as a green
		# cast four times, because g-b alone is 0.35.
		if c.g - maxf(c.r, c.b) > 0.25:
			suspect.append("%s: green cast %s" % [effect, c])
		if sheet != "" and tex == null:
			suspect.append("%s: names sheet %s but has no texture" % [effect, sheet])

	print("\nspawn points: %d textured, %d untextured" % [textured, untextured])
	if suspect.is_empty():
		print("nothing suspect")
	else:
		print("SUSPECT:")
		for s in suspect:
			print("  " + str(s))
	quit(0)
