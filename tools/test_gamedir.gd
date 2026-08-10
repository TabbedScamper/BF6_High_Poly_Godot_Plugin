@tool
extends SceneTree
# The registry-based Steam root and the autodetect that rides on it,
# against this machine's real Steam and real install.
func _init() -> void:
	var root := HighpolyGameDir._steam_root()
	print("steam root: '%s'" % root)
	var found := HighpolyGameDir.autodetect()
	print("autodetect: '%s'" % found)
	var v: Dictionary = HighpolyGameDir.verify(found)
	print("verified: %s (%s)" % [str(v["ok"]), str(v["why"])])
	var fails := 0
	if root == "":
		print("FAIL registry found no Steam root on a machine that has Steam")
		fails += 1
	if found == "" or not bool(v["ok"]):
		print("FAIL autodetect no longer finds the install")
		fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
