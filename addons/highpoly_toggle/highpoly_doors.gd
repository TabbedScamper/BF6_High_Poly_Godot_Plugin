@tool
extends RefCounted
# Interactable doors: LEFT DOUBLE-CLICK a door in the viewport to swing it open /
# closed, exactly like in game. The registry marks door proxies with a
# `door` spec (open angle from the game's interactabledoorcontrol data), and
# the published door models bake the leaf under `doorleaf_*` nodes whose node
# ORIGIN IS THE GAME'S HINGE — so the swing is a plain local Y rotation.
# Editor-only, never saved: only the high-poly overlay's nodes rotate.

const OPEN_META := "hp_door_open"
const SWING_SECS := 0.45

static func door_spec(prox: String) -> Dictionary:
	var e: Variant = HighpolyStore.remote.get(prox)
	if e is Dictionary and (e as Dictionary).get("door") is Dictionary:
		return (e as Dictionary)["door"]
	return {}

static func _door_key(node: Node) -> String:
	var sfp := String(node.scene_file_path)
	if not sfp.begins_with("res://objects/"):
		return ""
	var base := sfp.get_file().get_basename()
	return base if not door_spec(base).is_empty() else ""

# ---------- picking ----------
static func _ray_hits_local_aabb(node: Node3D, origin: Vector3, dir: Vector3) -> float:
	# slab test in the node's local space; returns entry distance or -1
	var inv := node.global_transform.affine_inverse()
	var o := inv * origin
	var d := (inv.basis * dir).normalized()
	var ab := HighpolyLib._merged_aabb(node, HighpolyLib.HP_NODE)
	if ab.size.length() < 0.01:
		return -1.0
	ab = ab.grow(0.05)
	var tmin := -1e20
	var tmax := 1e20
	for i in range(3):
		if absf(d[i]) < 1e-8:
			if o[i] < ab.position[i] or o[i] > ab.end[i]:
				return -1.0
			continue
		var t1 := (ab.position[i] - o[i]) / d[i]
		var t2 := (ab.end[i] - o[i]) / d[i]
		tmin = maxf(tmin, minf(t1, t2))
		tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)

# find the nearest door instance under the cursor; "" message on success
static func click(camera: Camera3D, pos: Vector2, root: Node) -> Dictionary:
	if root == null or camera == null:
		return {}
	var origin := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var best: Node3D = null
	var best_t := 1e20
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HighpolyLib.HP_NODE or n.name == "_MAP_CONTEXT" \
				or n.name == HighpolyLib.COL_NODE:
			continue
		if n is Node3D and _door_key(n) != "":
			var t := _ray_hits_local_aabb(n as Node3D, origin, dir)
			if t >= 0.0 and t < best_t:
				best_t = t; best = n as Node3D
			continue
		for c in n.get_children():
			stack.append(c)
	if best == null:
		return {}
	return toggle(best)

# ---------- swing ----------
static func toggle(node: Node3D) -> Dictionary:
	var key := _door_key(node)
	var deg := float(door_spec(key).get("deg", 85.0))
	var hp := node.get_node_or_null(HighpolyLib.HP_NODE)
	var leaves: Array = []
	if hp != null:
		var stack: Array = [hp]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is Node3D and String(n.name).begins_with("doorleaf"):
				leaves.append(n)
			for c in n.get_children():
				stack.append(c)
	if leaves.is_empty():
		return {"node": node, "ok": false,
				"msg": "%s: switch it to High-Poly to swing the door" % key}
	var opening: bool = not bool(node.get_meta(OPEN_META, false))
	node.set_meta(OPEN_META, opening)
	for leaf in leaves:
		var l := leaf as Node3D
		if not l.has_meta("hp_rest_rot"):
			l.set_meta("hp_rest_rot", l.rotation)
		var rest: Vector3 = l.get_meta("hp_rest_rot")
		var target := rest
		if opening:
			target = rest + Vector3(0, deg_to_rad(deg), 0)
		var tw := l.create_tween()
		tw.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tw.tween_property(l, "rotation", target, SWING_SECS)
	return {"node": node, "ok": true,
			"msg": "%s %s" % [key, "opened" if opening else "closed"]}
