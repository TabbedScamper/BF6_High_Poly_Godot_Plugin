@tool
extends Object
class_name HighpolyPlacedCull
# Distance-cull the user's OWN placed objects (their custom map content, NOT the
# map-context backdrop). A densely-built map stays fast because far props stop
# rendering, while every prop stays fully visible, selectable, and editable up
# close. Editor-only: it only sets visibility_range on the real nodes — nothing is
# ever hidden, and the saved/exported scene is untouched. Follows the Range slider.

# Editor-only overlay subtrees to never descend into. We deliberately do NOT skip
# _HIPOLY_PREVIEW: that owner=null subtree holds the VISIBLE high-poly meshes of the
# user's placed SDK objects (the low-poly proxy underneath is hidden while preview
# is on), so it MUST be culled together with them — exactly like the prototype did.
# We only skip the backdrop, FX, lights, water and the collision debug overlay,
# because those systems own their own distance handling.
const SKIP := ["_MAP_CONTEXT", "_MAP_FX", "_MAP_LIGHTS", "_WATER_CHUNKS", "_COLLISION_VIS"]

# ---------- gizmos follow the cull ----------
# visibility_range only culls the MESH. An editor gizmo is a separate render
# instance and is never distance-culled, so past the cull distance the mesh
# stops drawing and its wireframe carries on — which is the neon-blue outline
# left hanging in empty space.
#
# Hiding a gizmo also stops it being click-selected, which is only acceptable
# BECAUSE this follows the cull: an object you cannot see is one you were never
# going to click. Anything still drawn keeps its gizmo and stays selectable.
#
# Ticked on the panel's existing half-second timer rather than per frame: the
# distance at which a wireframe winks out does not need frame accuracy, and
# this walks every managed object.
const GIZMO_MARGIN := 1.05         # hide slightly beyond the cull, never before

static var _managed: Array = []    # [{"n": MeshInstance3D, "d": float, "hid": bool}]

static func tick_gizmos(cam_pos: Vector3) -> int:
	var changed := 0
	var live: Array = []
	for e in _managed:
		var mi = e["n"]
		if not is_instance_valid(mi) or not (mi is Node3D):
			continue                                    # scene closed under us
		live.append(e)
		var far: bool = mi.global_position.distance_to(cam_pos) > float(e["d"]) * GIZMO_MARGIN
		if far == bool(e["hid"]):
			continue                                    # already in that state
		for g in (mi as Node3D).get_gizmos():
			if g is EditorNode3DGizmo:
				(g as EditorNode3DGizmo).set_hidden(far)
		e["hid"] = far
		changed += 1
	if live.size() != _managed.size():
		_managed = live                                 # drop the freed ones
	return changed

# Put every gizmo back. Called when the cull is switched off, and on teardown —
# leaving one hidden would make an object permanently unclickable.
static func show_all_gizmos() -> void:
	for e in _managed:
		var mi = e["n"]
		if is_instance_valid(mi) and mi is Node3D:
			for g in (mi as Node3D).get_gizmos():
				if g is EditorNode3DGizmo:
					(g as EditorNode3DGizmo).set_hidden(false)
	_managed.clear()

# apply/refresh at render distance `r`; `on=false` clears the cull (full range).
static func apply(root: Node, r: float, on: bool) -> String:
	if root == null:
		return "No scene"
	var arr: Array = []
	_collect(root, arr)
	var n := 0
	show_all_gizmos()          # forget the previous pass before recording this one
	for mi in arr:
		var ext: float = (mi as VisualInstance3D).get_aabb().get_longest_axis_size()
		if not on or ext > 600.0:
			# off, OR a big structural mesh (terrain / a large building you're
			# building on) — never distance-cull it, it'd vanish when you fly away.
			mi.visibility_range_end = 0.0
			continue           # never culled, so its gizmo is never hidden
		# smaller = culls closer; keep props you're editing visible up close.
		var d: float = r if ext >= 12.0 else (r * 0.6 if ext >= 3.0 else r * 0.35)
		d = maxf(d, 40.0)
		mi.visibility_range_end = d
		if ext >= 12.0:
			# larger objects (walls, buildings): smooth fade-out. Same big-object
			# treatment as the backdrop cull that ran flicker-free ("super smooth").
			mi.visibility_range_end_margin = maxf(d * 0.25, 40.0)
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		else:
			# small props: hard hysteresis cull — dither-fade flickers on small objects.
			mi.visibility_range_end_margin = maxf(d * 0.1, 8.0)
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		# remember what we culled and how far, so the gizmo tick has no work to
		# do beyond one distance compare per object
		_managed.append({"n": mi, "d": d, "hid": false})
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
