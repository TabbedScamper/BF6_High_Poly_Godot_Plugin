extends SceneTree
# Live shared-reader/consumer regression. The exported Visible field is not
# a water-rendering gate. An invalid map is the negative control.

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var game := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--game="): game = arg.substr(7)
	var core: Object = ClassDB.instantiate("BF6Core")
	if core == null or not core.call("open", game):
		quit(1)
		return
	var failures := 0
	for level in ["mp_aftermath", "mp_tungsten", "mp_not_a_real_map_control"]:
		var env := BF6Environment.new(core, level)
		# Read metadata only, without textures or a second terrain decode.
		var data := env.request("water")
		var rows: Array = data.get("surfaces", [])
		var summary: Array = []
		for row in rows:
			summary.append({"visible":row.get("visible"), "height":row.get("height"),
				"center":row.get("center"), "size":row.get("size"), "is_ocean":row.get("is_ocean")})
		print("WATER_RAW " + JSON.stringify({"level":level,"surfaces":summary,"error":env.error}))
		if level == "mp_not_a_real_map_control":
			if not rows.is_empty(): failures += 1
			continue
		if rows.is_empty():
			failures += 1
			continue
		# Exercise the actual Godot consumer with the shared reader's packet.
		env.water = data
		var gs := HighpolyGameSource.new()
		gs.level = level
		gs.src = BF6Source.new()
		gs.src.game = game
		gs._native_core_game = game
		gs._native_environment = env
		var surfaces := gs.water()
		if surfaces.size() != rows.size(): failures += 1
		print("WATER_CONSUMER " + JSON.stringify({"level":level,"raw":rows.size(),"placed":surfaces.size()}))
	print("FAILURES ", failures)
	quit(0 if failures == 0 else 1)
