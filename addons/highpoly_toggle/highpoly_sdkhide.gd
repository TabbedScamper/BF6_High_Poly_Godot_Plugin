@tool
extends RefCounted
class_name HighpolySdkHide
# Get the SDK's own stand-in geometry out of the way while ours is showing.
#
# Every SDK level ships two nodes the builder can toggle themselves: a single
# merged low-poly mesh of the buildings and props (MP_<map>_Assets) and a small
# slab of terrain (MP_<map>_Terrain). Both sit exactly where our own versions
# go, so leaving them on means z-fighting and doubled geometry.
#
# What the user had is remembered, in memory, keyed by instance id — NOT written
# to the node. set_meta() would be serialized into their .tscn, and this plugin
# does not modify saved scenes. The cost is that the memory is lost if the
# plugin reloads mid-session; the mitigation is that everything is restored on
# teardown, so there is no state left to remember.
#
# Keyed by instance id rather than node path because get_path() returns an EMPTY
# path for a node that is not currently in a tree — every entry would then
# collide on "" and the last one hidden would be the only one restored.
#
# Restoring puts back what was there, not "visible": someone who had already
# turned the SDK assets off does not want them switched on for them.

const ASSETS_SUFFIX := "_Assets"
const TERRAIN_SUFFIX := "_Terrain"

# instance id -> the visibility it had before we touched it
static var _saved: Dictionary = {}

# Node names vary by level, so match on the suffix rather than a built name;
# our own overlays are skipped by name so we can never hide ourselves.
static func find(root: Node, suffix: String) -> Array:
	var out: Array = []
	if root == null: return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var nm := String(n.name)
		if nm.begins_with("_HIPOLY") or nm == "_MAP_CONTEXT" or nm.begins_with("_GAME_"):
			continue
		if n is Node3D and nm.ends_with(suffix) and nm.begins_with("MP_"):
			out.append(n)
			continue                       # no need to walk inside a match
		for c in n.get_children():
			stack.append(c)
	return out

# hide = true  : remember the current state, then hide
# hide = false : put back whatever was remembered, and forget it
# Returns how many nodes it actually changed.
static func set_hidden(root: Node, suffix: String, hide: bool) -> int:
	var n := 0
	for node in find(root, suffix):
		var n3 := node as Node3D
		var key := n3.get_instance_id()
		if hide:
			if not _saved.has(key):
				_saved[key] = n3.visible   # first touch only: never overwrite
			if n3.visible:
				n3.visible = false
				n += 1
		else:
			if _saved.has(key):
				var was: bool = bool(_saved[key])
				if n3.visible != was:
					n3.visible = was
					n += 1
				_saved.erase(key)
	return n

# Everything back as it was — used when the plugin is switched off, and
# whenever the edited scene changes so a stale path cannot resurface.
static func restore_all(root: Node) -> void:
	if root != null:
		set_hidden(root, ASSETS_SUFFIX, false)
		set_hidden(root, TERRAIN_SUFFIX, false)
	_saved.clear()

# How many nodes we are holding the original state of. Nothing in the plugin
# reads it — the tests do, to assert that letting go of a scene leaves nothing
# behind, which is the invariant that stops a node being restored to a state
# that belongs to a scene that is already closed.
static func remembered() -> int: return _saved.size()
