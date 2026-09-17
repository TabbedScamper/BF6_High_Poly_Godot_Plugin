extends SceneTree

# EXPORT EVERY CARRIER LAYOUT AS A FLAT ORANGE glTF.
#
#   python tools/run_addon_script.py native/export_carrier_layouts.gd \
#       --args <steam root> <level> <output dir> [lod]
#
# Runs the real exporter rather than a copy of it, so what this writes is what
# the dock button writes. Reports triangles and file size per layout, because
# those are the two numbers that decide whether a layout is usable in an editor
# viewport at all - carrierstrike is 22.4 million triangles at LOD 0.

const Export := preload("res://addons/highpoly_toggle/highpoly_carrierexport.gd")
const HighpolyGameSource := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		print("usage: export_carrier_layouts.gd -- <steam> <level> <out dir> [lod]")
		quit(2); return
	var level := str(a[1])
	var out_dir := str(a[2])
	var lod := int(a[3]) if a.size() > 3 else Export.DEFAULT_LOD

	var gs = HighpolyGameSource.new()
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(level, str(a[0]), func(_s, _d, _t): pass):
		print("FAIL open_map: %s" % gs.error); quit(1); return
	print("opened %s in %.1f s" % [level, (Time.get_ticks_msec() - t0) / 1000.0])

	# One folder per map, named as the SDK names it, so Tsuru's Conquest and
	# Wake's Conquest stop overwriting each other - they share a layer name and
	# a flat output directory silently kept only the last one written.
	var pretty: String = Export.map_display_name(level)
	out_dir = out_dir.path_join(Export.safe_folder(pretty))
	print("map: %s -> %s" % [level, out_dir])

	var colour := Export.blockout_colour(level)
	print("blockout colour: %s  (LOD %d)" % [str(colour), lod])
	var mat := Export._material(colour)

	var groups: Dictionary = Export.layouts(gs)
	if groups.is_empty():
		print("no carrier layouts on %s" % level); quit(0); return

	var keys := groups.keys()
	keys.sort()
	print("\n%-40s %8s %10s %12s %10s" % ["layout", "meshes", "instances", "triangles", "file"])
	var failures := 0
	for k in keys:
		var stats := {}
		var name := "Carrier_Layout_%s" % str(k).capitalize().replace(" ", "")
		var root: Node3D = Export.build_layout(gs, name, groups[k], mat, lod, stats)
		get_root().add_child(root)
		var fname: String = Export.layout_file_name(str(k))
		var err: String = Export.export_layout(root, out_dir, fname)
		var size := 0
		if err == "":
			var f := FileAccess.open(out_dir.path_join(fname), FileAccess.READ)
			if f != null:
				size = f.get_length()
				f.close()
		print("%-40s %8d %10d %12s %9s %s"
			% [fname, int(stats.get("meshes", 0)), int(stats.get("instances", 0)),
			   _commas(int(stats.get("triangles", 0))),
			   "%.1f MB" % (size / 1048576.0) if size > 0 else "-", err])
		if err != "": failures += 1
		if int(stats.get("missing", 0)) > 0:
			print("%40s %d mesh(es) did not resolve" % ["", int(stats["missing"])])
		root.queue_free()
		await process_frame

	print("\n%s: %d layout(s) failed to write" % ["FAIL" if failures else "PASS", failures])
	quit(1 if failures else 0)


func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0: out = "," + out
	return out
