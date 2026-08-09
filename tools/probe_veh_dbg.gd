@tool
extends SceneTree
const LibScript = preload("res://addons/highpoly_toggle/highpoly_lib.gd")
func _init() -> void:
	print("use_legacy = ", LibScript.use_legacy)
	print("files under objects/gameplay/vehicles: ",
		DirAccess.get_files_at("res://objects/gameplay/vehicles").size())
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   ", s)
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	LibScript.game_source = gs
	print("vehicle_for(VEH_Abrams) = '", HighpolyVehicle.vehicle_for(gs, "VEH_Abrams"), "'")
	print("_asset_id(VEH_Abrams)   = '", LibScript._asset_id("VEH_Abrams"), "'")
	quit(0)
