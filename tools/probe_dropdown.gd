@tool
extends SceneTree
# What the Variant dropdown will offer, and what picking one shows.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable()):
		print("open failed"); quit(1); return
	var mc = HighpolyMapContext.new()
	mc.game_source = gs
	mc._data = gs.map_data("user://bench/aft3")
	var layers: Array = mc.available_layers()
	print("dropdown would offer %d entries besides Off:" % layers.size())
	for l in layers: print("   ", l)
	print("\nwhat each selection makes visible:")
	for m in ["Off", "winter_event", "rush", "domination"]:
		var act: Dictionary = mc._active_variant_layers(m)
		print("   %-16s -> %s" % [m, ", ".join(act.keys())])
	quit(0)
