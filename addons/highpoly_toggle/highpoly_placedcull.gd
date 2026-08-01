@tool
extends Object
class_name HighpolyPlacedCull
# Distance-cull the user's OWN placed objects (their custom map content, NOT the
# map-context backdrop). A densely-built map stays fast because far props stop
# rendering, while every prop stays fully visible, selectable, and editable up
# close. Follows the Range slider.
#
# NOT free of consequence, despite appearances: visibility_range_end is a real
# serialized property, and a scene saved while the cull is on carries it into
# the .tscn (verified — it shows up as "visibility_range_end = 480.0"). So it
# MUST be cleared when the plugin lets go of a scene: on teardown, and when a
# different scene is opened. Left behind, the culling keeps running with the
# plugin disabled, which also leaves the editor gizmos of culled objects drawn
# with nothing inside them.

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
# stops drawing and its wireframe carries on — the neon-blue outline left
# hanging in empty space.
#
# The gizmo does NOT live on the MeshInstance3D. A placed object is an
# instanced .tscn, and the editor builds gizmos for the node the user actually
# placed — the instance root. Hiding gizmos on the meshes inside it therefore
# does nothing at all, which is why the first attempt at this changed nothing
# on screen. We track the ROOT, and the distance we use is the furthest cull
# distance of the meshes under it, so a root only goes dark once everything it
# owns has.
#
# Hiding a gizmo also stops it being click-selected. Acceptable ONLY because
# this follows the cull: an object you cannot see is one you were not going to
# click, and anything still drawn keeps its gizmo.
const GIZMO_MARGIN := 1.05         # hide slightly beyond the cull, never before

static var _managed: Array = []    # [{"n": Node3D root, "d": float, "hid": bool}]
static var _by_root: Dictionary = {}   # instance id -> index into _managed
# Diagnostics: get_gizmos() only returns gizmos the editor actually built. If
# this stays zero while objects are being culled, the outline is not a per-node
# gizmo and no amount of set_hidden() will touch it.
static var _gizmos_seen := 0

static func managed_count() -> int: return _managed.size()
static func gizmos_seen() -> int: return _gizmos_seen

# The node the user placed: the nearest ancestor belonging to the edited scene.
# Falls back to the mesh itself when there is no such ancestor.
static func _placed_root(mi: Node) -> Node3D:
	# EditorInterface only exists inside the editor; outside it (tests, a
	# headless run) every mesh is simply its own root, which is the same
	# behaviour with no grouping.
	var scene: Node = EditorInterface.get_edited_scene_root() 		if Engine.is_editor_hint() else null
	# Guarded rather than folded into the loop below: with scene == null the
	# test "owner == scene" is true for every node built in code, and every mesh
	# in the scene would collapse onto one shared root.
	if scene == null:
		return mi as Node3D
	var n: Node = mi
	while n != null and n != scene:
		# the NEAREST owned ancestor is the object the user placed; walking on
		# past it would group separate objects under a common parent
		if n is Node3D and n.owner == scene:
			return n as Node3D
		n = n.get_parent()
	return mi as Node3D

static func _set_gizmos_hidden(n3: Node3D, hide: bool) -> int:
	var k := 0
	for g in n3.get_gizmos():
		if g is EditorNode3DGizmo:
			(g as EditorNode3DGizmo).set_hidden(hide)
			k += 1
	return k

# Record one placed root at the furthest distance any of its meshes culls at.
static func _record(mi: Node3D, d: float) -> void:
	var root := _placed_root(mi)
	var id := root.get_instance_id()
	if _by_root.has(id):
		var e = _managed[int(_by_root[id])]
		e["d"] = maxf(float(e["d"]), d)
		return
	_by_root[id] = _managed.size()
	_managed.append({"n": root, "d": d, "hid": false})

static func tick_gizmos(cam_pos: Vector3) -> int:
	var changed := 0
	var dead := false
	for e in _managed:
		var n3 = e["n"]
		if not is_instance_valid(n3) or not (n3 is Node3D):
			dead = true
			continue                                    # scene closed under us
		var far: bool = (n3 as Node3D).global_position.distance_to(cam_pos) 			> float(e["d"]) * GIZMO_MARGIN
		if far == bool(e["hid"]):
			continue                                    # already in that state
		_gizmos_seen += _set_gizmos_hidden(n3 as Node3D, far)
		e["hid"] = far
		changed += 1
	if dead:
		_rebuild_index()
	return changed

static func _rebuild_index() -> void:
	var keep: Array = []
	_by_root.clear()
	for e in _managed:
		var n3 = e["n"]
		if not is_instance_valid(n3): continue
		_by_root[(n3 as Object).get_instance_id()] = keep.size()
		keep.append(e)
	_managed = keep

# Put every gizmo back. Called when the cull is switched off, and on teardown —
# leaving one hidden would make an object permanently unclickable.
static func show_all_gizmos() -> void:
	for e in _managed:
		var n3 = e["n"]
		if is_instance_valid(n3) and n3 is Node3D:
			_set_gizmos_hidden(n3 as Node3D, false)
	_managed.clear()
	_by_root.clear()

# Forget the entries for the roots in this pass only, showing their gizmos
# again first. apply() is also called for a single node when one is added, and
# clearing everything there would forget the rest of the scene.
static func _forget(arr: Array, clear_everything: bool) -> void:
	if clear_everything:
		show_all_gizmos()
		return
	var touched: Dictionary = {}
	for mi in arr:
		touched[_placed_root(mi).get_instance_id()] = true
	var keep: Array = []
	for e in _managed:
		var n3 = e["n"]
		if not is_instance_valid(n3): continue
		if touched.has((n3 as Object).get_instance_id()):
			if bool(e["hid"]): _set_gizmos_hidden(n3 as Node3D, false)
			continue
		keep.append(e)
	_managed = keep
	_by_root.clear()
	for i in range(_managed.size()):
		_by_root[(_managed[i]["n"] as Object).get_instance_id()] = i

# Hand a scene back exactly as we found it: the cull off, every gizmo shown.
# Call before letting go of a scene — teardown, or opening a different one.
static func release(root: Node) -> void:
	show_all_gizmos()
	if root != null:
		apply(root, 0.0, false)

# apply/refresh at render distance `r`; `on=false` clears the cull (full range).
static func apply(root: Node, r: float, on: bool) -> String:
	if root == null:
		return "No scene"
	var arr: Array = []
	_collect(root, arr)
	var n := 0
	# Drop stale entries for the objects in THIS pass only. apply() is also
	# called for a single node when one is added to the scene, and clearing the
	# whole list there would forget every other object we are managing.
	_forget(arr, not on)
	for mi in arr:
		var ext: float = (mi as VisualInstance3D).get_aabb().get_longest_axis_size()
		if not on or ext > 600.0:
			# off, OR a big structural mesh (terrain / a large building you're
			# building on) — never distance-cull it, it'd vanish when you fly away.
			# all three, not just the distance: the margin and the fade mode are
			# serialized too, so clearing only the distance still leaves our
			# fingerprints in the user's .tscn
			mi.visibility_range_end = 0.0
			mi.visibility_range_end_margin = 0.0
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
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
		_record(mi, d)
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
