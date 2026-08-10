@tool
extends SceneTree
# THE GROUND LAYER PALETTE, ENTRY BY ENTRY.
#
# The splat says MP_Aftermath paints 28 layers and only 5 come out textured, so
# 23 of them fail this test in terrain_surface:
#
#     if pal.albedo_of(li) == "":
#         continue
#
# albedo_of returns "" for exactly two reasons - the index is past the end of
# the palette, or the entry carries no a_cv/b_cv/c_cv texture. Those need
# completely different fixes, so print which it is for every entry.
#
#   ... probe_palette.gd -- MP_Aftermath

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   | %s" % s)
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("open failed: %s" % str(gs.error)); quit(1); return

	var pidx: Dictionary = gs.walk.gi if gs.walk != null else {}
	var pal := BF6TerrainLayers.new()
	if not pal.load(gs.src, gs.level, pidx):
		print("palette load FAILED: %s" % pal.error)
		quit(1)
		return

	print("")
	print("== palette for %s: %d entr(ies)" % [map, pal.layers.size()])
	print("%5s  %-38s %-30s %s" % ["idx", "albedo (a_cv/b_cv/c_cv)",
		"texture keys present", "tiling"])
	var with_alb := 0
	var empty := 0
	var key_hist := {}
	for i in range(pal.layers.size()):
		var d: Dictionary = pal.layers[i]
		var t: Dictionary = d.get("textures", {})
		var keys: Array = t.keys()
		keys.sort()
		for k in keys:
			key_hist[str(k)] = int(key_hist.get(str(k), 0)) + 1
		var alb := pal.albedo_of(i)
		if alb != "":
			with_alb += 1
		else:
			empty += 1
		# THE LINK, which albedo_of() does not follow. The palette parses one per
		# layer and nothing reads it; if an empty layer links to a textured one,
		# following it is the difference between painted ground and a flat
		# colour map over most of the map.
		var lk := int((d as Dictionary).get("link", -1))
		var lk_txt := ""
		if lk >= 0 and lk < pal.layers.size():
			var la := pal.albedo_of(lk)
			lk_txt = "link %d -> %s" % [lk, la.get_file() if la != "" else "(also empty)"]
		elif lk >= 0:
			lk_txt = "link %d (out of range)" % lk
		print("%5d  %-38s %-26s %7.3f  %s" % [i, alb.get_file().left(38),
			", ".join(PackedStringArray(keys.map(func(x): return str(x)))).left(26),
			pal.metres_per_repeat(i), lk_txt])
	print("")
	print("   %d of %d entries have an albedo; %d do not"
		% [with_alb, pal.layers.size(), empty])
	print("")
	print("== which texture slots the palette actually carries")
	var rows: Array = []
	for k in key_hist:
		rows.append([int(key_hist[k]), str(k)])
	rows.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for r in rows:
		print("   %5d  %s" % [int(r[0]), str(r[1])])
	quit(0)
