@tool
extends RefCounted
# Variant cycling: LEFT DOUBLE-CLICK a high-poly prop that ships variant models
# (police liveries, barn colour schemes, destroyed shells, …) to cycle
# base -> variant1 -> variant2 -> … -> base. Doors take precedence: the dock
# only routes a double-click here when no door was hit.
#
# Discovery + loading live in HighpolyLib (variants_of / variant_path /
# variant_scene): a cheap directory glob next to the base model, cached per
# proxy. prop_variants.json is never consulted per node — it is read ONCE (if
# present) only to ORDER the cycle: variants that appear on the CURRENT map
# come first, the rest alphabetically.
#
# The active variant is remembered per INSTANCE (HighpolyLib.VARIANT_META node
# metadata), so two buses can wear different liveries, and Low-Poly ->
# High-Poly round trips restore the same variant. Each swap replaces the whole
# overlay subtree — variant GLBs are full standalone models (destroyed shells
# can differ in geometry).

const Doors = preload("highpoly_doors.gd")

static var _meta: Dictionary = {}     # prop_variants.json: proxy -> {variant: [levels lc]}
static var _meta_loaded := false

# ---------- ordering (prop_variants.json, read once) ----------
static func _load_meta() -> void:
	if _meta_loaded: return
	_meta_loaded = true
	var candidates := [
		"user://highpoly/prop_variants.json",
		"res://highpoly/prop_variants.json",
		# pipeline checkout sitting next to the SDK (dev layout)
		ProjectSettings.globalize_path("res://").path_join(
				"../../bf6-highpoly-pipeline/data/prop_variants.json"),
	]
	for p in candidates:
		if not FileAccess.file_exists(p): continue
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if not (j is Dictionary): continue
		for prox in (j as Dictionary):
			var rows: Variant = (j as Dictionary)[prox]
			if not (rows is Array): continue
			var m: Dictionary = {}
			for r in rows:
				if not (r is Dictionary): continue
				var vn := str((r as Dictionary).get("variant", ""))
				if vn == "": continue
				var lv: Variant = (r as Dictionary).get("levels",
						(r as Dictionary).get("maps", []))
				var low: Array = []
				if lv is Array:
					for l in lv:
						low.append(str(l).to_lower())
				m[vn] = low
			_meta[prox] = m
		return

# lowercase map token of the edited level, e.g. "mp_golmudrailway"
static func map_token(root: Node) -> String:
	if root == null: return ""
	var n := String(root.name)
	if n.begins_with("MP_"): return n.to_lower()
	for part in String(root.scene_file_path).split("/"):
		if part.begins_with("MP_"):
			return part.get_basename().to_lower()
	return ""

static func _on_map(levels: Array, map: String) -> bool:
	if map == "": return false
	for l in levels:
		var ls := String(l)
		if ls == map or ls.contains(map) or map.contains(ls):
			return true
	return false

# cycle order for a proxy: current-map variants first, then the rest, each
# group alphabetical (plain alphabetical when the metadata isn't available)
static func order(prox: String, map: String) -> PackedStringArray:
	_load_meta()
	var names: Array = HighpolyLib.variants_of(prox).keys()
	names.sort()
	if map != "" and _meta.has(prox):
		var vm: Dictionary = _meta[prox]
		var on_map: Array = []
		var rest: Array = []
		for n in names:
			var lv: Variant = vm.get(n, [])
			if lv is Array and _on_map(lv, map):
				on_map.append(n)
			else:
				rest.append(n)
		names = on_map + rest
	return PackedStringArray(names)

# ---------- picking (same slab test + walk as doors) ----------
static func _variant_key(node: Node) -> String:
	var sfp := String(node.scene_file_path)
	if not sfp.begins_with("res://objects/"):
		return ""
	var base := sfp.get_file().get_basename()
	return base if not HighpolyLib.variants_of(base).is_empty() else ""

# find the nearest variant-capable instance under the cursor and cycle it
static func click(camera: Camera3D, pos: Vector2, root: Node) -> Dictionary:
	if root == null or camera == null:
		return {}
	var origin := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var best: Node3D = null
	var best_key := ""
	var best_t := 1e20
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HighpolyLib.HP_NODE or n.name == "_MAP_CONTEXT" \
				or n.name == HighpolyLib.COL_NODE:
			continue
		if n is Node3D:
			var k := _variant_key(n)
			if k != "":
				var t := Doors._ray_hits_local_aabb(n as Node3D, origin, dir)
				if t >= 0.0 and t < best_t:
					best_t = t; best = n as Node3D; best_key = k
				continue
		for c in n.get_children():
			stack.append(c)
	if best == null:
		return {}
	return cycle(best, best_key)

# ---------- cycle ----------
# textured state of the existing overlay (grey preview uses a material override)
static func _hp_textured(hp: Node) -> bool:
	var stack: Array = [hp]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			return (n as GeometryInstance3D).material_override == null
		for c in n.get_children():
			stack.append(c)
	return true

static func cycle(node: Node3D, key: String) -> Dictionary:
	var hp := node.get_node_or_null(HighpolyLib.HP_NODE)
	if hp == null or not (hp is Node3D) or not (hp as Node3D).visible:
		return {"node": node, "ok": false,
				"msg": "%s: switch it to High-Poly to cycle variants" % key}
	var textured := _hp_textured(hp)
	var map := map_token(EditorInterface.get_edited_scene_root())
	var names := order(key, map)
	if names.is_empty():
		return {}
	# position in the ring [base, names...]
	var cur := String(node.get_meta(HighpolyLib.VARIANT_META, ""))
	var idx := 0
	if cur != "":
		var f := names.find(cur)
		idx = f + 1 if f >= 0 else 0
	var total := names.size() + 1
	var nxt := (idx + 1) % total
	var vname := "" if nxt == 0 else names[nxt - 1]
	node.set_meta(HighpolyLib.VARIANT_META, vname)
	# apply_one sees the changed asset id and replaces the WHOLE overlay subtree
	if not HighpolyLib.apply_one(node, key, HighpolyLib.Tier.HIGH, textured):
		node.set_meta(HighpolyLib.VARIANT_META, cur)  # bad file: stay on the working one
		HighpolyLib.apply_one(node, key, HighpolyLib.Tier.HIGH, textured)
		return {"node": node, "ok": false,
				"msg": "%s: variant '%s' failed to load" % [key, vname]}
	var disp := "base" if vname == "" else vname
	var msg := "%s: %s (%d/%d)" % [key, disp, nxt + 1, total]
	print("[highpoly] ", msg)
	return {"node": node, "ok": true, "msg": msg}
