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
# The gizmo is on the MeshInstance3D itself. A survey of a real level found
# 7050 of them carrying one and none on the instance roots above them, so this
# tracks the mesh, not the object it belongs to.
#
# The threshold is the mesh's OWN visibility_range_end, read back after the
# cull pass rather than taken from our own bookkeeping. An object can arrive
# with a range already authored into its .tscn, and then it culls — and leaves
# a wireframe — whether our cull is on or not. Reading the property covers both.
#
# Hiding a gizmo also stops it being click-selected. Acceptable ONLY because
# this follows the cull: an object you cannot see is one you were not going to
# click, and anything still drawn keeps its gizmo.
const GIZMO_MARGIN := 1.05         # hide slightly beyond the cull, never before

static var _managed: Array = []    # [{"n": MeshInstance3D, "d": float, "hid": bool}]
# What each mesh's visibility range was BEFORE we touched it. Restored instead
# of zeroed: some objects ship with a range authored in, and zeroing it would
# strip the author's own culling out of the user's scene.
static var _orig: Dictionary = {}  # instance id -> [end, margin, fade_mode]
static var _gizmos_seen := 0
static var _regrown := 0           # gizmos the editor rebuilt while still culled

static func managed_count() -> int: return _managed.size()
static func gizmos_seen() -> int: return _gizmos_seen

# A live snapshot, for when the one-shot line at startup is not enough: how many
# meshes are tracked, how many are currently beyond their range, and how many of
# those still have a gizmo attached (which should be none).
static func status(cam_pos: Vector3) -> String:
	var far := 0
	var stale := 0
	var live := 0
	for e in _managed:
		var mi = e["n"]
		if not is_instance_valid(mi): continue
		live += 1
		if bool(e["hid"]):
			far += 1
			if not (mi as Node3D).get_gizmos().is_empty(): stale += 1
			for c in e.get("co", []):
				if is_instance_valid(c) and not (c as Node3D).get_gizmos().is_empty():
					stale += 1
	var comps := 0
	for e in _managed:
		comps += (e.get("co", []) as Array).size()
	return ("%d mesh(es) culling (+%d collision nodes), %d past their range, %d "
		+ "STILL carrying a gizmo, %d rebuilt by the editor so far") 		% [live, comps, far, stale, _regrown]

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

# set_hidden() alone did not remove the wireframe — the plugin reported gizmos
# hidden while they stayed on screen. So the gizmo is REMOVED when the mesh is
# culled and rebuilt when it comes back. set_hidden is still called first: it is
# the cheaper operation and costs nothing if it does work.
static func _set_gizmos_hidden(n3: Node3D, hide: bool) -> int:
	var k := 0
	for g in n3.get_gizmos():
		if g is EditorNode3DGizmo:
			(g as EditorNode3DGizmo).set_hidden(hide)
			k += 1
	if hide:
		n3.clear_gizmos()
	else:
		n3.update_gizmos()          # ask the plugins to build it again
	return k

# Track a mesh that will cull, at whatever distance it actually culls at.
# The mesh is not the only thing drawing. A CollisionShape3D gizmo is a cyan
# wireframe of the same object, and CollisionShape3D is NOT a GeometryInstance3D
# — visibility_range cannot touch it. So culling the mesh leaves the collision
# outline standing in empty space, which is the wireframe that survived every
# previous attempt at this.
#
# Companions are found under the mesh's own parent: a placed object is
# typically StaticBody3D -> [CollisionShape3D, MeshInstance3D], so the parent's
# subtree holds the collision nodes belonging to this mesh and nothing else's.
static func _companions(mi: Node) -> Array:
	var out: Array = []
	var p := mi.get_parent()
	if p == null: return out
	var stack: Array = [p]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != mi and (n is CollisionShape3D or n is CollisionPolygon3D):
			out.append(n)
		for c in n.get_children():
			if c is MeshInstance3D: continue     # another mesh: its own business
			stack.append(c)
	return out

static func _record(mi: MeshInstance3D) -> void:
	var d := mi.visibility_range_end
	if d <= 0.0: return                # never culls, so its gizmo never hides
	# guard against duplicates when apply() runs for a single node
	for e in _managed:
		if e["n"] == mi:
			e["d"] = d
			return
	_managed.append({"n": mi, "d": d, "hid": false, "co": _companions(mi)})

static func tick_gizmos(cam_pos: Vector3) -> int:
	var changed := 0
	var dead := false
	for e in _managed:
		var mi = e["n"]
		if not is_instance_valid(mi) or not (mi is Node3D):
			dead = true
			continue                                    # scene closed under us
		var far: bool = (mi as Node3D).global_position.distance_to(cam_pos) 			> float(e["d"]) * GIZMO_MARGIN
		if far == bool(e["hid"]):
			# The editor rebuilds gizmos by itself — on a transform change, on
			# selection. One that is meant to be gone can therefore come back,
			# so a still-culled mesh is re-cleared rather than assumed clean.
			if far:
				if not (mi as Node3D).get_gizmos().is_empty():
					(mi as Node3D).clear_gizmos()
					_regrown += 1
				for c in e.get("co", []):
					if is_instance_valid(c) and not (c as Node3D).get_gizmos().is_empty():
						(c as Node3D).clear_gizmos()
						_regrown += 1
			continue                                    # already in that state
		_gizmos_seen += _set_gizmos_hidden(mi as Node3D, far)
		for c in e.get("co", []):
			if is_instance_valid(c):
				_gizmos_seen += _set_gizmos_hidden(c as Node3D, far)
		e["hid"] = far
		changed += 1
	if dead:
		var keep: Array = []
		for e in _managed:
			if is_instance_valid(e["n"]): keep.append(e)
		_managed = keep
	return changed

# When nothing on the tracked nodes carries a gizmo, the outline is drawn by
# something else — this reports which classes in the scene DO carry one, so the
# carrier can be identified instead of guessed at.
static func gizmo_carriers(root: Node) -> String:
	if root == null: return "no scene open"
	var by_class: Dictionary = {}
	var total := 0
	var nodes := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		if n is Node3D:
			var k: int = (n as Node3D).get_gizmos().size()
			if k > 0:
				total += k
				var c := n.get_class()
				by_class[c] = int(by_class.get(c, 0)) + k
		for c2 in n.get_children():
			stack.append(c2)
	if total == 0:
		return "%d nodes walked, NOT ONE carries an editor gizmo" % nodes
	var parts: Array = []
	for c in by_class:
		parts.append("%s x%d" % [c, int(by_class[c])])
	parts.sort()
	return "%d gizmo(s) across %d nodes: %s" % [total, nodes, ", ".join(parts)]

# Put every gizmo back. Leaving one hidden would make its object unclickable.
static func show_all_gizmos() -> void:
	for e in _managed:
		var mi = e["n"]
		if is_instance_valid(mi) and mi is Node3D:
			_set_gizmos_hidden(mi as Node3D, false)
		for c in e.get("co", []):
			if is_instance_valid(c):
				_set_gizmos_hidden(c as Node3D, false)
	_managed.clear()

# Hand a scene back exactly as we found it: every visibility range restored to
# whatever it was, every gizmo shown. Call before letting go of a scene —
# teardown, or opening a different one.
static func release(root: Node) -> void:
	show_all_gizmos()
	if root != null:
		var arr: Array = []
		_collect(root, arr)
		for mi in arr:
			_restore_range(mi)
	_orig.clear()

# Forget the tracking for the meshes in this pass only, showing their gizmos
# again first. apply() also runs for a single node when one is added, and
# clearing everything there would forget the rest of the scene.
static func _forget(arr: Array, clear_everything: bool) -> void:
	if clear_everything:
		show_all_gizmos()
		return
	var touched: Dictionary = {}
	for mi in arr:
		touched[(mi as Object).get_instance_id()] = true
	var keep: Array = []
	for e in _managed:
		var mi2 = e["n"]
		if not is_instance_valid(mi2): continue
		if touched.has((mi2 as Object).get_instance_id()):
			if bool(e["hid"]): _set_gizmos_hidden(mi2 as Node3D, false)
			continue
		keep.append(e)
	_managed = keep

# apply/refresh at render distance `r`; `on=false` clears the cull (full range).
static func apply(root: Node, r: float, on: bool) -> String:
	if root == null:
		return "No scene"
	var arr: Array = []
	_collect(root, arr)
	var n := 0
	_forget(arr, not on)
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
