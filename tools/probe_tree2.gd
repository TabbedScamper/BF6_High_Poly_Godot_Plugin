@tool
extends SceneTree
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var res := "common/environment/generic/common/vegetation/londonplanetree_01/tr_com_londonplanetree_01_l_b_mesh"
	var walked := "game/glaciermp/levels/mp_aftermath/default_event"
	var alt: String = gs._scope_of(res)
	var got := 0
	for hex in ["24493504082ce316", "95745203d6265d69", "82edd800df1c5ba4"]:
		var k := 0
		# parse the 64-bit key without hex_to_int, which cannot hold the high bit
		for ch in hex:
			k = (k << 4) | ("0123456789abcdef".find(ch))
		var m = gs._material_any(k, walked, alt, 0, PackedInt32Array())
		print("  %s -> %s" % [hex, "MATERIAL" if m != null else "none"])
		if m != null: got += 1
	print("\n%d of 3 surfaces now dress" % got)
	print("shipping-bundle rescues: %d, sibling rescues: %d"
		% [int(gs.tex_stats.get("scope_shipping",0)), int(gs.tex_stats.get("scope_sibling",0))])
	quit(0)
