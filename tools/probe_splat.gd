@tool
extends SceneTree
# WHY MOST OF THE PAINTED GROUND IS MISSING.
#
# The ground is composited from the game's splat: per texel, up to four layer
# indices and their weights. Each layer that appears is turned into a "slice" -
# an albedo and a normal in a Texture2DArray - but ONLY if the layer palette can
# give it a texture name:
#
#     if pal.albedo_of(li) == "":
#         continue
#
# A layer that fails that test is dropped, and every texel painted with it falls
# back to the flat colour map. MP_Aftermath's cached layers.json lists five
# slices with layer indices reaching 36, which says the map paints many more
# layers than five and most of them are being skipped.
#
# Forced into a SCRATCH cache dir, so the user's own ground cache is untouched.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var scratch := "user://_splatprobe/%s" % map
	DirAccess.make_dir_recursive_absolute(scratch)

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   | %s" % s)
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("open failed: %s" % str(gs.error)); quit(1); return

	print("")
	print("== compositing the ground for %s (forced, into a scratch dir)" % map)
	var t := Time.get_ticks_msec()
	var meta: Dictionary = gs.terrain_surface(scratch, true, Callable())
	print("   %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))
	if meta.is_empty():
		print("   terrain_surface returned NOTHING - that is the whole failure")
		quit(1)
		return

	var layers: Array = meta.get("layers", [])
	print("")
	print("== the %d slice(s) that made it, by ground covered" % layers.size())
	var kept := 0
	for l in layers:
		var d: Dictionary = l
		kept += int(d.get("texels", 0))
		print("   layer %-4d %-40s %9d texels   %.1f m per repeat" % [
			int(d.get("layer", -1)), str(d.get("albedo", "")),
			int(d.get("texels", 0)), float(d.get("metres_per_repeat", 0.0))])
	print("")
	print("   texels covered by a textured slice: %d" % kept)
	print("   (the log line above says how many layers the map paints in total,")
	print("    and what percentage of ground ended up with no slice at all)")
	quit(0)
