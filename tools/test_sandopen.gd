@tool
extends SceneTree
# The plugin's own open path, given the SDK's scene name for the sand map -
# the mp_ alias must resolve the level root that "portal_sand" alone cannot.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("Portal_Sand"):
		print("FAIL: ", gs.error)
		quit(1)
		return
	print("opened as level '%s', walk rows %d, via %s" % [gs.level,
		gs.walk.rows.size() if gs.walk != null else -1,
		str(gs.walk.stats.get("resolved_via", "direct")) if gs.walk != null else "?"])
	var t := gs.terrain("user://sandtest")
	print("terrain: %s" % ("OK res %s" % str(t.get("res", t.get("size", "?"))) if not t.is_empty() else "EMPTY"))
	print("ALL OK" if not t.is_empty() else "FAILED")
	quit(0 if not t.is_empty() else 1)
