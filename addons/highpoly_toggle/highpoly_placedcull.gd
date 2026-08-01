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

# ---------- the collision outlines follow the cull ----------
# The blue wireframe left standing where a culled object used to be is its
# CollisionShape3D gizmo. CollisionShape3D is not a GeometryInstance3D, so
# visibility_range cannot touch it: the mesh goes, the outline stays.
#
# They live INSIDE the mesh's own subtree — the collision comes from the
# imported .glb, as a child of the Mesh node, not as a sibling. An earlier
# attempt searched the mesh's PARENT and found none, which is how a correct
# theory produced a wrong answer.
#
# The subtree walk happens once per apply, never per tick. A tick is one
# distance compare per mesh, and touches gizmos only when the state changes.
# Clearing a COLLISION gizmo does not affect click-selecting the object — that
# goes through the mesh — so this does not have the selection cost that made
# the earlier mesh-gizmo version a bad trade.
const GIZMO_MARGIN := 1.05         # hide slightly beyond the cull, never before

static var _managed: Array = []    # [{"n": mesh, "d": float, "hid": bool, "co": Array}]
static var _regrown := 0           # gizmos the editor rebuilt while still culled

static func managed_count() -> int: return _managed.size()

static func _collision_in(mi: Node) -> Array:
	var out: Array = []
	var stack: Array = mi.get_children()
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CollisionShape3D or n is CollisionPolygon3D or n is CollisionObject3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out

static func _set_hidden(n3: Node3D, hide: bool) -> void:
	for g in n3.get_gizmos():
		if g is EditorNode3DGizmo:
			(g as EditorNode3DGizmo).set_hidden(hide)
	if hide: n3.clear_gizmos()
	else: n3.update_gizmos()

static func _record(mi: MeshInstance3D) -> void:
	var d := mi.visibility_range_end
	if d <= 0.0: return                         # never culls, so nothing to follow
	for e in _managed:
		if e["n"] == mi:
			e["d"] = d
			return
	var co := _collision_in(mi)
	if co.is_empty(): return                    # nothing that would be left behind
	_managed.append({"n": mi, "d": d, "hid": false, "co": co})

static func tick_gizmos(cam_pos: Vector3) -> int:
	var changed := 0
	var dead := false
	for e in _managed:
		var mi = e["n"]
		if not is_instance_valid(mi):
			dead = true
			continue
		var far: bool = (mi as Node3D).global_position.distance_to(cam_pos) 			> float(e["d"]) * GIZMO_MARGIN
		if far == bool(e["hid"]):
			# the editor rebuilds gizmos by itself (a transform change, a
			# selection), so one that is meant to be gone can come back
			if far:
				for c in e["co"]:
					if is_instance_valid(c) and not (c as Node3D).get_gizmos().is_empty():
						(c as Node3D).clear_gizmos()
						_regrown += 1
			continue
		for c in e["co"]:
			if is_instance_valid(c): _set_hidden(c as Node3D, far)
		e["hid"] = far
		changed += 1
	if dead:
		var keep: Array = []
		for e in _managed:
			if is_instance_valid(e["n"]): keep.append(e)
		_managed = keep
	return changed

static func show_all_gizmos() -> void:
	for e in _managed:
		for c in e["co"]:
			if is_instance_valid(c): _set_hidden(c as Node3D, false)
	_managed.clear()

static func status(_cam := Vector3.ZERO) -> String:
	var far := 0
	var stale := 0
	var co := 0
	for e in _managed:
		co += (e["co"] as Array).size()
		if not bool(e["hid"]): continue
		far += 1
		for c in e["co"]:
			if is_instance_valid(c) and not (c as Node3D).get_gizmos().is_empty():
				stale += 1
	return ("%d object(s) with %d collision outline(s); %d past their range, "
		+ "%d outline(s) still showing, %d rebuilt by the editor") 		% [_managed.size(), co, far, stale, _regrown]

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

# Every colour the editor and the project can draw debug geometry with, filtered
# to the blue ones. The wireframes left behind by a culled object are not
# gizmos — that was measured — so the next question is which of Godot's own
# debug drawing they come from, and its colour setting is the way to name it.
static func blue_debug_settings() -> String:
	var hits: PackedStringArray = []
	var es := EditorInterface.get_editor_settings() if Engine.is_editor_hint() else null
	if es != null:
		for p in es.get_property_list():
			var n: String = p.get("name", "")
			if not (n.begins_with("editors/") or n.contains("debug")): continue
			var v: Variant = es.get(n)
			if v is Color and _is_blue(v as Color):
				hits.append("EDITOR  %s = %s" % [n, _hex(v as Color)])
	for p in ProjectSettings.get_property_list():
		var n: String = p.get("name", "")
		if not (n.begins_with("debug/") or n.contains("navigation")
				or n.contains("collision")): continue
		var v: Variant = ProjectSettings.get_setting(n)
		if v is Color and _is_blue(v as Color):
			hits.append("PROJECT %s = %s" % [n, _hex(v as Color)])
	if hits.is_empty(): return "no blue debug colour found in editor or project settings"
	return "
           ".join(hits)

# "neon blue": blue clearly dominant, and bright enough to read as neon
static func _is_blue(c: Color) -> bool:
	return c.b > 0.45 and c.b > c.r * 1.35 and c.a > 0.05

static func _hex(c: Color) -> String:
	return "#%02x%02x%02x a=%.2f" % [int(c.r * 255), int(c.g * 255), int(c.b * 255), c.a]

# What kinds of node the scene is actually made of — the wireframe belongs to
# one of them, and a class that draws itself without being a GeometryInstance3D
# is the shape of the answer.
static func class_census(root: Node, top := 12) -> String:
	if root == null: return "no scene open"
	var counts: Dictionary = {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var c := n.get_class()
		counts[c] = int(counts.get(c, 0)) + 1
		for k in n.get_children():
			stack.append(k)
	var pairs: Array = []
	for c in counts: pairs.append([int(counts[c]), c])
	pairs.sort_custom(func(a, b): return a[0] > b[0])
	var out: PackedStringArray = []
	for i in range(mini(top, pairs.size())):
		out.append("%s x%d" % [pairs[i][1], pairs[i][0]])
	return ", ".join(out)

# Hand a scene back exactly as we found it: every visibility range restored to
# whatever it was. Call before letting go of a scene —
# teardown, or opening a different one.
static func release(root: Node) -> void:
	show_all_gizmos()
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
	# forget only the meshes in THIS pass: apply() also runs for a single node
	# when one is added, and clearing everything there would forget the scene
	var touched: Dictionary = {}
	for mi in arr: touched[(mi as Object).get_instance_id()] = true
	var keep: Array = []
	for e in _managed:
		if not is_instance_valid(e["n"]): continue
		if touched.has((e["n"] as Object).get_instance_id()):
			for c in e["co"]:
				if is_instance_valid(c) and bool(e["hid"]): _set_hidden(c as Node3D, false)
			continue
		keep.append(e)
	_managed = keep
	for mi in arr:
		_remember(mi)                  # what it had before we touched it
		var ext: float = (mi as VisualInstance3D).get_aabb().get_longest_axis_size()
		if not on or ext > 600.0:
			# off, OR a big structural mesh (terrain / a large building you're
			# building on) — never distance-cull it, it'd vanish when you fly
			# away. Restored to what it had, NOT zeroed: an object can ship with
			# a range authored in, and zeroing would strip that from the scene.
			_restore_range(mi)
			_record(mi)                # it may still cull on its own terms
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
		_record(mi)
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
