@tool
extends SceneTree
# The police SUV surface 0: does the carpaint material now carry the livery?
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var scope := "game/glaciermp/levels/mp_aftermath/sub_art_03_park"
	var hex := "a565f8eed080a2dd"
	var k := 0
	for ch in hex: k = (k << 4) | ("0123456789abcdef".find(ch))
	var m = gs.material_for(k, scope, 3431496371)
	print("material  : ", m)
	if m is StandardMaterial3D:
		var sm := m as StandardMaterial3D
		print("albedo col: ", sm.albedo_color)
		print("albedo tex: ", "NONE" if sm.albedo_texture == null
			else "%dx%d" % [sm.albedo_texture.get_width(), sm.albedo_texture.get_height()])
	print("carpaint  : ", int(gs.tex_stats.get("carpaint", 0)),
		"  with a wrap: ", int(gs.tex_stats.get("carpaint_wrap", 0)))
	quit(0)
