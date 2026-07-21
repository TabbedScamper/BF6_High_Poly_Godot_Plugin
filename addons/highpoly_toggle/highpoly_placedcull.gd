@tool
extends Object
class_name HighpolyPlacedCull
# Distance-cull the user's OWN placed objects (their custom map content, NOT the
# map-context backdrop). A densely-built map stays fast because far props stop
# rendering, while every prop stays fully visible, selectable, and editable up
# close. Editor-only: it only sets visibility_range on the real nodes — nothing is
# ever hidden, and the saved/exported scene is untouched. Follows the Range slider.

# editor-only overlay subtrees to never descend into — that geometry is the
# backdrop/FX/preview the OTHER systems own, not the user's placed content.
const SKIP := ["_MAP_CONTEXT", "_MAP_FX", "_MAP_LIGHTS", "_HIPOLY_PREVIEW", "_WATER_CHUNKS"]

# apply/refresh at render distance `r`; `on=false` clears the cull (full range).
static func apply(root: Node, r: float, on: bool) -> String:
	if root == null:
		return "No scene"
	var arr: Array = []
	_collect(root, arr)
	var n := 0
	for mi in arr:
		var ext: float = (mi as VisualInstance3D).get_aabb().get_longest_axis_size()
		if not on or ext > 600.0:
			# off, OR a big structural mesh (terrain / large building the user is
			# building on) — never distance-cull it, it'd vanish when you fly away.
			mi.visibility_range_end = 0.0
			continue
		# smaller = culls closer; hard cull (no dither) so nothing flickers.
		var d: float = r if ext >= 12.0 else (r * 0.6 if ext >= 3.0 else r * 0.35)
		d = maxf(d, 40.0)   # keep props you're editing visible up close
		mi.visibility_range_end = d
		mi.visibility_range_end_margin = maxf(d * 0.1, 8.0)
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		n += 1
	if not on:
		return "Placed objects: full range"
	return "Placed objects optimized: %d culled at %d m" % [n, int(r)]

static func _collect(node: Node, arr: Array) -> void:
	if String(node.name) in SKIP:
		return
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		arr.append(node)
	for c in node.get_children():
		_collect(c, arr)
