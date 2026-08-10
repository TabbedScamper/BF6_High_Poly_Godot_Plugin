@tool
extends SceneTree
# The heightfield read-back (#72), against the real install.
#
# terrain() twice into a scratch cache dir: the first call must composite and
# write height_game.r16 + height_game.json; the second must serve the file back
# with an identical metadata dictionary and identical grid bytes, and do it in
# a fraction of the time. Then the meta key is corrupted, and the third call
# must fall back to a full recomposite rather than serving stale heights.

const DIR := "user://hmcache_test"

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Tungsten"):
		print("no source"); quit(1); return
	# a clean scratch dir, so this never touches the user's real map cache
	if DirAccess.dir_exists_absolute(DIR):
		for f in DirAccess.get_files_at(DIR):
			DirAccess.remove_absolute("%s/%s" % [DIR, f])
	var t0 := Time.get_ticks_msec()
	var cold: Dictionary = gs.terrain(DIR)
	var t_cold := Time.get_ticks_msec() - t0
	var cold_bytes: PackedByteArray = (gs._hm["data"] as PackedByteArray).duplicate()
	t0 = Time.get_ticks_msec()
	var warm: Dictionary = gs.terrain(DIR)
	var t_warm := Time.get_ticks_msec() - t0
	var warm_bytes: PackedByteArray = gs._hm["data"]
	var fails := 0
	if cold.is_empty() or bool(cold.get("from_cache", false)):
		print("FAIL cold call did not composite: %s" % str(cold)); fails += 1
	if not bool(warm.get("from_cache", false)):
		print("FAIL warm call did not read back: %s" % str(warm)); fails += 1
	for k in ["file", "res", "world_min", "world_max", "base", "scale"]:
		if str(cold.get(k)) != str(warm.get(k)):
			print("FAIL meta %s: cold %s warm %s" % [k, cold.get(k), warm.get(k)])
			fails += 1
	if cold_bytes != warm_bytes:
		print("FAIL grid bytes differ: %d vs %d" % [cold_bytes.size(), warm_bytes.size()])
		fails += 1
	print("cold %d ms -> warm %d ms, %d bytes, res %s" % [t_cold, t_warm,
		warm_bytes.size(), str(warm.get("res"))])
	if t_warm * 5 > t_cold and t_cold > 2000:
		print("FAIL warm not meaningfully faster"); fails += 1
	# stale-key fallback: a changed install must recomposite, not serve the file
	var mf := FileAccess.open("%s/height_game.json" % DIR, FileAccess.WRITE)
	mf.store_string(JSON.stringify({"key": "not-the-install", "res": cold.get("res"),
		"world_min": cold.get("world_min"), "world_max": cold.get("world_max"),
		"scale": cold.get("scale")}))
	mf.close()
	var re: Dictionary = gs.terrain(DIR)
	if bool(re.get("from_cache", false)):
		print("FAIL stale key was served from cache"); fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
