extends SceneTree

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var gs := HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath", "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6", Callable(), {"placements":false}):
		push_error(gs.error); quit(1); return
	var resource := "common/environment/generic/common/props/carsedan_01/backdrop/bd_com_carsedan_01_mesh"
	var scope := gs._scope_of(resource)
	var pair = gs._depot_for(scope)
	if pair == null:
		push_error("No exact resource depot: " + scope); quit(1); return
	var state := (0xec75cbac << 32) | 0xa6cfa3bc
	var slots: Dictionary = pair[0].textures_for(state, pair[1])
	var guid := str(slots.get("normal", ""))
	var name := str(gs.walk.gi.get(guid, ""))
	var correct := name.ends_with("/t_com_carsedan_01_unique_nmo.ebx")
	var wrong_slot := str(BF6Depot.SLOT_NAME.get(0xec35b353, "")) != "normal"
	print(JSON.stringify({"scope":scope,"normal":name,"real_normal":correct,
		"subsurface_control_rejected":wrong_slot,"vehicle":BF6Depot.SLOT_NAME.get(0xec35a74c),
		"props":BF6Depot.SLOT_NAME.get(0xec35a757),"character":BF6Depot.SLOT_NAME.get(0xec35a68c)}))
	quit(0 if correct and wrong_slot else 1)
