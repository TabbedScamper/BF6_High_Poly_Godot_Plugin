@tool
extends RefCounted
class_name HighpolyShapeViz
# Godot's collision-shape outlines, off by default.
#
# Every placed object carries a CollisionShape3D whose editor gizmo draws a
# teal wireframe of its shape. On a built-up level that is thousands of extra
# wireframes drawn every frame, and it stutters. They are also what is left
# standing when an object is distance-culled, since CollisionShape3D is not a
# GeometryInstance3D and visibility_range cannot touch it.
#
# This clears them once and keeps them clear, rather than following the camera.
# The earlier distance-based version cleared and REBUILT gizmos as you flew —
# hundreds of update_gizmos() calls per second — which cost more than the
# outlines it was removing.
#
# Nothing here is saved: gizmos are editor-side only, and everything is put back
# when the plugin lets go of the scene.

const Log = preload("highpoly_log.gd")

# The editor rebuilds gizmos on its own — selecting a node, moving one, undo.
# A top-up pass catches those, on a slow cadence because it is only tidying.
const TOPUP_EVERY := 8             # ticks of the panel's half-second timer

static var _nodes: Array = []      # the collision nodes we are keeping clear
static var _hidden := false
static var _t := 0

static func is_hidden() -> bool: return _hidden
static func count() -> int: return _nodes.size()

static func _collect(root: Node) -> Array:
	var out: Array = []
	if root == null: return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionShape3D or n is CollisionPolygon3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

# hide = true  : clear every collision gizmo and keep them clear
# hide = false : hand them back to the editor to rebuild
static func apply(root: Node, hide: bool) -> int:
	_hidden = hide
	_nodes = _collect(root) if hide else _nodes
	var n := 0
	for c in _nodes:
		if not is_instance_valid(c): continue
		if hide:
			(c as Node3D).clear_gizmos()
		else:
			(c as Node3D).update_gizmos()
		n += 1
	if not hide:
		_nodes.clear()
	return n

# Cheap tidy-up: only every TOPUP_EVERY ticks, and only clears what came back.
static func tick() -> int:
	if not _hidden: return 0
	_t += 1
	if _t < TOPUP_EVERY: return 0
	_t = 0
	var back := 0
	var dead := false
	for c in _nodes:
		if not is_instance_valid(c):
			dead = true
			continue
		if not (c as Node3D).get_gizmos().is_empty():
			(c as Node3D).clear_gizmos()
			back += 1
	if dead:
		var keep: Array = []
		for c in _nodes:
			if is_instance_valid(c): keep.append(c)
		_nodes = keep
	return back

# A scene we have not seen yet (or one that grew) needs its new nodes clearing
# too — cheaper than re-walking on every tick.
static func rescan(root: Node) -> int:
	if not _hidden or root == null: return 0
	var found := _collect(root)
	var known: Dictionary = {}
	for c in _nodes:
		if is_instance_valid(c): known[(c as Object).get_instance_id()] = true
	var added := 0
	for c in found:
		if known.has((c as Object).get_instance_id()): continue
		_nodes.append(c)
		(c as Node3D).clear_gizmos()
		added += 1
	return added

static func release(root: Node) -> void:
	if _hidden and root != null:
		# put back everything in the scene, not just what we remember: the
		# remembered list lives in a static and is wiped on every plugin reload
		for c in _collect(root):
			(c as Node3D).update_gizmos()
	_nodes.clear()
	_hidden = false
	_t = 0
