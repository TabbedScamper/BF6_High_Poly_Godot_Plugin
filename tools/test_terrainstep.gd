extends SceneTree
# The stride is derived from the source resolution so the mesh weight stays put
# whatever the game turns out to hold.
const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
var fails: Array = []
func ck(c: bool, w: String) -> void:
	print(("  ok   " if c else "  FAIL ") + w)
	if not c: fails.append(w)
func _initialize() -> void:
	ck(MC._step_for({"res": 4097}) == 2, "4097 source keeps the stride at 2, exactly as today")
	ck(MC._step_for({"res": 8193}) == 4, "a source twice as fine strides twice as far: same mesh, real samples")
	ck(MC._step_for({"res": 2049}) == 1, "a coarser source takes every sample rather than inventing any")
	ck(MC._step_for({}) == 2, "a level with no metadata falls back to today's behaviour")
	ck(MC._step_for({"res": 1}) >= 1, "a degenerate source never strides by zero")
	var verts := int((8193 - 1) / MC._step_for({"res": 8193})) + 1
	ck(abs(verts - MC.TERRAIN_VERTS_PER_SIDE) <= 1, "the budget is what is actually held: %d" % verts)
	print("\n%s  (%d failure(s))" % ["PASS" if fails.is_empty() else "FAILED", fails.size()])
	quit(0 if fails.is_empty() else 1)
