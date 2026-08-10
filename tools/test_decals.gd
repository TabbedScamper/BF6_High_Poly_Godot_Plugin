@tool
extends SceneTree
# The two-family TerrainDecals reader (#98) against the real install.
# Tungsten regression is by NUMBERS, not family (both walks converge there):
# 613 records, 47,789 triangles, matching every session log. Badlands verifies
# the fixed family (628/628 per its study); Dumbo is the props-first baseline.

func one(level: String) -> Dictionary:
	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		return {"error": "no source"}
	var rn := BF6Decals.find_res(gs.src, gs.level)
	if rn == "":
		return {"error": "no TerrainDecals res"}
	var d := BF6Decals.new()
	d.parse(gs.src.get_res(rn))
	var st := d.stats()
	gs.src = null
	return st

func _init() -> void:
	var fails := 0
	var t: Dictionary = one("MP_Tungsten")
	print("tungsten: %s" % str(t))
	if int(t.get("records", 0)) != 613 or int(t.get("triangles", 0)) != 47789:
		print("FAIL tungsten regression numbers"); fails += 1
	var b: Dictionary = one("MP_Badlands")
	print("badlands: %s" % str(b))
	if b.get("format", "") != "fixed-header" \
			or int(b.get("records", 0)) != int(b.get("declared", -1)):
		print("FAIL badlands"); fails += 1
	var du: Dictionary = one("MP_Dumbo")
	print("dumbo: %s" % str(du))
	if int(du.get("records", 0)) == 0 or not bool(du.get("chain_ok", false)):
		print("FAIL dumbo"); fails += 1
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
