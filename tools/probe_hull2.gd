@tool
extends SceneTree
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var k := 7778057341684822587
	var sc := "ob_veh_tank_abrams_base_j4mejr_bundle_3p"
	print("depot_for(%s) = %s" % [sc, "found" if gs._depot_for(sc) != null else "NULL"])
	var pal := PackedInt32Array([0, 1])
	print("material_for(no pal)   = ", gs.material_for(k, sc, 0))
	print("material_for(pal 0,1)  = ", gs.material_for(k, sc, 0, pal))
	print("no_key count = ", int(gs.tex_stats.get("no_key", 0)))
	# and is that scope in the list _dress would try?
	var scopes = HighpolyVehicle._scopes_for(gs, "abrams")
	print("scopes tried: %d, includes it: %s" % [scopes.size(), scopes.has(sc)])
	quit(0)
