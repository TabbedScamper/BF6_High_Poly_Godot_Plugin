@tool
extends SceneTree
# Virtual slices end to end: the v6 bake carries the computed layers' authored
# tiling/smoothness, the idx raster actually uses the 32..63 id space, and the
# shader (with virt uniforms) parses.
func _init() -> void:
	var fails := 0
	var consts: Dictionary = (load("res://addons/highpoly_toggle/highpoly_mapcontext.gd") as GDScript).get_script_constant_map()
	var sh := Shader.new()
	sh.code = str(consts["TERRAIN_SHADER"])
	print("terrain shader uniforms: %d" % sh.get_shader_uniform_list().size())
	if sh.get_shader_uniform_list().size() < 20:
		print("FAIL shader did not parse")
		fails += 1
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath"):
		print("no source"); quit(1); return
	var meta: Dictionary = gs.terrain_surface("user://v86", true)
	if meta.is_empty():
		print("FAIL bake"); quit(1); return
	var vrows: Array = meta.get("virtual", [])
	print("splat_v %s, %d slices, %d virtual layers" % [str(meta.get("splat_v")),
		int(meta.get("slices", 0)), vrows.size()])
	for i in range(mini(6, vrows.size())):
		var r: Dictionary = vrows[i]
		print("  virt %2d: layer=%s m/repeat=%.1f smooth=%s" % [32 + i,
			str(r.get("layer")), float(r.get("metres_per_repeat", 0.0)),
			str(r.get("smoothness"))])
	if int(meta.get("splat_v", 0)) != 6 or vrows.is_empty():
		print("FAIL no virtual rows at v6")
		fails += 1
	var idx := Image.load_from_file(ProjectSettings.globalize_path("user://v86/splat/idx.png"))
	idx.convert(Image.FORMAT_RGBA8)
	var d := idx.get_data()
	var hist := {}
	for i in range(0, d.size(), 4 * 401):
		hist[int(d[i])] = int(hist.get(int(d[i]), 0)) + 1
	var virt_share := 0
	var tot := 0
	var unresolved := 0
	for k in hist:
		tot += int(hist[k])
		if int(k) >= 32 and int(k) < 64:
			virt_share += int(hist[k])
		elif int(k) == 255:
			unresolved += int(hist[k])
	print("slot-0 sampled: %.1f%% virtual ids, %.1f%% unresolved 255"
		% [100.0 * virt_share / maxi(1, tot), 100.0 * unresolved / maxi(1, tot)])
	if virt_share == 0:
		print("FAIL the raster never uses the virtual id space")
		fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
