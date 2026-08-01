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
const Log = preload("highpoly_log.gd")
const SKIP := ["_MAP_CONTEXT", "_MAP_FX", "_MAP_LIGHTS", "_WATER_CHUNKS", "_COLLISION_VIS"]

# ---------- what we changed, so it can be put back ----------
# visibility_range_end is a SERIALIZED property: a scene saved while the cull is
# on carries it into the .tscn. So whatever a mesh had before we touched it is
# remembered and restored when we let go of the scene.
#
static var _orig: Dictionary = {}  # instance id -> [end, margin, fade_mode]

static func _remember(mi: GeometryInstance3D) -> void:
	var id := mi.get_instance_id()
	if _orig.has(id): return           # first touch only: never overwrite
	_orig[id] = [mi.visibility_range_end, mi.visibility_range_end_margin,
		mi.visibility_range_fade_mode]

static func _restore_range(mi: GeometryInstance3D) -> void:
	var id := mi.get_instance_id()
	if not _orig.has(id): return
	var o: Array = _orig[id]
	mi.visibility_range_end = float(o[0])
	mi.visibility_range_end_margin = float(o[1])
	mi.visibility_range_fade_mode = int(o[2])
	_orig.erase(id)

# (The collision outlines used to be followed per-camera from here: cleared as
# an object went out of range, rebuilt as it came back. That churned
# update_gizmos() across hundreds of objects every time the camera moved and
# stuttered worse than the outlines it removed. They are simply switched off
# now — see highpoly_shapeviz.gd.)

static func release(root: Node) -> void:
	var blind := 0
	if root != null:
		var arr: Array = []
		_collect(root, arr)
		for mi in arr:
			if _orig.has(mi.get_instance_id()):
				_restore_range(mi)
			elif mi.visibility_range_end > 0.0:
				# Nothing remembered. The remembered values live in a static, and
				# statics are wiped every time the script is re-parsed — which
				# happens on every plugin reload. Restoring nothing would leave
				# the scene culled with the plugin disabled, which is worse than
				# the alternative: a scene where the cull is simply off.
				mi.visibility_range_end = 0.0
				mi.visibility_range_end_margin = 0.0
				mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
				blind += 1
	_orig.clear()
	if blind > 0:
		Log.warn(("Cleared the draw distance on %d object(s) without knowing what "
			+ "they started with — the plugin had been reloaded since it set them. "
			+ "If any of those shipped with their own draw distance, it is off now.")
			% blind)

static func apply(root: Node, r: float, on: bool) -> String:
	if root == null:
		return "No scene"
	var arr: Array = []
	_collect(root, arr)
	var n := 0
	for mi in arr:
		_remember(mi)                  # what it had before we touched it
		var ext: float = (mi as VisualInstance3D).get_aabb().get_longest_axis_size()
		if not on or ext > 600.0:
			# off, OR a big structural mesh (terrain / a large building you're
			# building on) — never distance-cull it, it'd vanish when you fly
			# away. Restored to what it had, NOT zeroed: an object can ship with
			# a range authored in, and zeroing would strip that from the scene.
			_restore_range(mi)
			continue
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
