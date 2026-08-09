@tool
extends SceneTree
# The marked tree: does it get materials from the walk's scope, and from the
# bundle that ships it?
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var res := "common/environment/generic/common/vegetation/londonplanetree_01/tr_com_londonplanetree_01_l_b_mesh"
	var walked := "game/glaciermp/levels/mp_aftermath/default_event"
	var ships: String = gs._scope_of(res)
	print("walk scope    : ", walked)
	print("shipping scope: ", ships, "\n")
	# the three state keys the diagnose reported
	for hex in ["24493504082ce316", "95745203d6265d69", "82edd800df1c5ba4"]:
		var k: int = hex.hex_to_int()
		var a = gs.material_for(k, walked, 0)
		var b = gs.material_for(k, ships, 0)
		print("  state %s   walk-scope: %-8s  shipping-scope: %s"
			% [hex, "MATERIAL" if a != null else "none",
			   "MATERIAL" if b != null else "none"])
	quit(0)
