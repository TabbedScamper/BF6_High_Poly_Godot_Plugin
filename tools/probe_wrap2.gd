@tool
extends SceneTree
# Body vs member: does the wrap go only on the shell now?
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	for nm in ["com_carsuv_01_mesh", "com_carsuv_01_door_frontright_mesh",
			"com_metrobus_01_wreck_roof_mesh", "com_truckpickup_01_door_frontright_mesh",
			"com_vanparamedicus_01_mesh"]:
		gs._dress_name = nm
		print("  %-42s body=%s" % [nm, gs._is_body_member()])
	quit(0)
