@tool
extends RefCounted
# (no class_name: the dock preloads this script explicitly, same as the other
# plugin modules — a fresh global class isn't registered until an editor
# rescan, which a just-updated plugin can't rely on)
# Editor-only visualization of the game's ACTUAL collision for placed objects.
#
# BF6 collision follows the object's geometry but scales UNIFORMLY from the X
# axis: an object scaled (10, 20, 20) collides as if scaled (10, 10, 10). The
# overlay duplicates the low-poly proxy's own meshes under an owner=null child
# `_COLLISION_VIS` (never saved, nothing stored on disk — mesh resources are
# shared, not copied) with a transparent red material, and forces the WORLD
# scale uniform to X. Being a child, it would inherit the proxy's non-uniform
# scale — so its local basis is the compensation  parent_inv * (R * sx)  that
# lands it at exactly uniform-X in world space, whatever the object's
# rotation, mirroring, or parent scales.

const COL_NODE := "_COLLISION_VIS"
# tiny uniform inflate so an unscaled object's collision (identical geometry)
# doesn't z-fight its own proxy surfaces
const EPS := 1.002

static var _tracked: Array = []    # object nodes carrying an overlay (transform refresh)
static var _isolated: Array = []   # nodes whose visuals "Isolate" is hiding

static var _red: StandardMaterial3D = null

static func red_material() -> StandardMaterial3D:
	if _red == null:
		_red = StandardMaterial3D.new()
		_red.albedo_color = Color(1.0, 0.08, 0.08, 0.45)
		_red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _red

# one shared material -> every overlay recolors instantly
static func set_color(c: Color) -> void:
	red_material().albedo_color = c

static func get_color() -> Color:
	return red_material().albedo_color

# any placed SDK object counts — collision doesn't care whether a high-poly
# model exists for it
static func _is_object(n: Node) -> bool:
	return n is Node3D and String(n.scene_file_path).begins_with("res://objects/")

# ---------- overlay lifecycle ----------

# the proxy's own render meshes, transforms relative to the object root.
# Skips our overlays and user-placed children nested under the object.
static func _proxy_meshes(node: Node3D) -> Array:
	var scene_root := EditorInterface.get_edited_scene_root()
	var inv := node.global_transform.affine_inverse()
	var out: Array = []
	var stack: Array = []
	for c in node.get_children():
		if c.name != HighpolyLib.HP_NODE and c.name != COL_NODE:
			stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HighpolyLib.HP_NODE or n.name == COL_NODE:
			continue
		if scene_root != null and n.owner == scene_root:
			continue                     # user content under the proxy, not its geometry
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append([(n as MeshInstance3D).mesh, inv * (n as MeshInstance3D).global_transform])
		for c in n.get_children():
			stack.append(c)
	return out

static func _update_transform(node: Node3D, col: Node3D) -> void:
	var b := node.global_transform.basis
	var sx := b.x.length()
	if sx < 1e-6:
		return
	# world target: rotation (handedness preserved) at uniform X scale
	var w := b.orthonormalized() * Basis.from_scale(Vector3.ONE * (sx * EPS))
	col.transform = Transform3D(b.inverse() * w, Vector3.ZERO)

static func ensure_one(node: Node3D) -> bool:
	var col := node.get_node_or_null(COL_NODE)
	if col == null:
		var meshes := _proxy_meshes(node)
		if meshes.is_empty():
			return false
		var c := Node3D.new()
		c.name = COL_NODE
		for pair in meshes:
			var mi := MeshInstance3D.new()
			mi.mesh = pair[0]
			mi.transform = pair[1]
			mi.material_override = red_material()
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			c.add_child(mi)
		node.add_child(c)
		c.owner = null                   # editor-only: not saved, not exported
		col = c
		if not _tracked.has(node):
			_tracked.append(node)
	_update_transform(node, col as Node3D)
	(col as Node3D).visible = true
	return true

static func remove_one(node: Node3D) -> void:
	var col := node.get_node_or_null(COL_NODE)
	if col != null:
		node.remove_child(col)
		col.queue_free()
	_tracked.erase(node)

# walk the scene: create (on) or remove (off) collision overlays for every
# placed object. Same overlay-skipping and nested-user-content rules as the
# high-poly walk.
static func apply(root: Node, on: bool) -> int:
	if root == null:
		return 0
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == HighpolyLib.HP_NODE or node.name == "_MAP_CONTEXT" \
				or node.name == COL_NODE:
			continue
		if _is_object(node):
			if on:
				if ensure_one(node as Node3D):
					count += 1
			else:
				remove_one(node as Node3D)
				count += 1
			HighpolyLib._push_user_children(node, stack)
			continue
		for c in node.get_children():
			stack.append(c)
	if not on:
		_tracked.clear()
	return count

# cheap periodic pass: follow objects the user moved/rescaled since the
# overlay was built (a few matrix ops per tracked object)
static func refresh_transforms() -> void:
	var alive: Array = []
	for node in _tracked:
		if not is_instance_valid(node):
			continue
		var col: Node = (node as Node3D).get_node_or_null(COL_NODE)
		if col == null:
			continue
		_update_transform(node as Node3D, col as Node3D)
		alive.append(node)
	_tracked = alive

# ---------- isolate: collision only for the selection ----------

# collect the placed objects inside a selection (a selected node may BE an
# object or a group containing many)
static func _objects_in(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		var stack: Array = [n]
		while not stack.is_empty():
			var c: Node = stack.pop_back()
			if c.name == HighpolyLib.HP_NODE or c.name == "_MAP_CONTEXT" \
					or c.name == COL_NODE:
				continue
			if _is_object(c):
				if not out.has(c):
					out.append(c)
				continue
			for gc in c.get_children():
				stack.append(gc)
	return out

# give one object its model back (whatever the current detail mode shows)
static func _restore_one(node: Node3D, tier: int, textured: bool) -> void:
	var restored := false
	if tier != HighpolyLib.Tier.LOW:
		var k := HighpolyLib.match_key_public(node)
		if k != "":
			restored = HighpolyLib.apply_one(node, k, tier, textured)
	if not restored:
		HighpolyLib._set_proxy_visible(node, true)
		var hp: Node = node.get_node_or_null(HighpolyLib.HP_NODE)
		if hp != null and hp is Node3D:
			(hp as Node3D).visible = false

# live isolation: the SELECTED objects show collision only; everything that
# left the selection gets its model back (its overlay stays — the global
# toggle is on while isolating). Call again on every selection change.
static func reisolate(selection: Array, tier: int, textured: bool) -> int:
	var target := _objects_in(selection)
	for node in _isolated.duplicate():
		if not is_instance_valid(node):
			_isolated.erase(node)
			continue
		if not target.has(node):
			_restore_one(node as Node3D, tier, textured)
			_isolated.erase(node)
	var n := 0
	for node in target:
		if not ensure_one(node as Node3D):
			continue
		HighpolyLib._set_proxy_visible(node as Node3D, false)
		var hp: Node = node.get_node_or_null(HighpolyLib.HP_NODE)
		if hp != null and hp is Node3D:
			(hp as Node3D).visible = false
		if not _isolated.has(node):
			_isolated.append(node)
		n += 1
	return n

# restore ALL isolated objects to whatever the current detail mode shows.
# keep_overlay=false also removes their collision (global toggle is off).
static func release_isolation(tier: int, textured: bool, keep_overlay: bool) -> int:
	var n := 0
	for node in _isolated:
		if not is_instance_valid(node):
			continue
		_restore_one(node as Node3D, tier, textured)
		if not keep_overlay:
			remove_one(node as Node3D)
		n += 1
	_isolated.clear()
	return n

static func has_isolation() -> bool:
	return not _isolated.is_empty()
