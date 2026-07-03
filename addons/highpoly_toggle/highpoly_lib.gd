@tool
extends RefCounted
class_name HighpolyLib
# Non-destructive, editor-only high-poly preview overlay.
# The low-poly proxy stays the SOURCE OF TRUTH (saved, exported); the overlay
# is an owner=null child `_HIPOLY_PREVIEW` (never saved). Tiers:
#   LOW    = proxy only (overlays hidden)
#   MEDIUM = <Name>_med.glb if present, else falls back to <Name>.glb
#   HIGH   = <Name>.glb
# "textured" off = flat-gray material override on the overlay (no extra files).

const HP_DIR := "res://highpoly"
const HP_ROT := Vector3(-90, 0, 0)   # legacy OBJ assets are Z-up; GLB assets are Y-up
const HP_NODE := "_HIPOLY_PREVIEW"
const NOFIT := ["WreckTank_Abra01"]

enum Tier { LOW, MEDIUM, HIGH }

static var _gray: StandardMaterial3D = null

static func gray_material() -> StandardMaterial3D:
	if _gray == null:
		_gray = StandardMaterial3D.new()
		_gray.albedo_color = Color(0.72, 0.72, 0.74)
		_gray.roughness = 0.9
	return _gray

static func keys() -> Dictionary:
	# name -> {high: path or "", med: path or ""}
	var d := {}
	var da := DirAccess.open(HP_DIR)
	if da == null: return d
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if da.current_is_dir() and not f.begins_with("."):
			var high := "%s/%s/%s.glb" % [HP_DIR, f, f]
			var med := "%s/%s/%s_med.glb" % [HP_DIR, f, f]
			var obj := "%s/%s/%s.obj" % [HP_DIR, f, f]
			var e := {"high": "", "med": ""}
			if ResourceLoader.exists(high): e.high = high
			elif ResourceLoader.exists(obj): e.high = obj
			if ResourceLoader.exists(med): e.med = med
			if e.high != "" or e.med != "":
				d[f] = e
		f = da.get_next()
	return d

static func asset_for(entry: Dictionary, tier: Tier) -> String:
	if tier == Tier.MEDIUM:
		return entry.med if entry.med != "" else entry.high
	return entry.high if entry.high != "" else entry.med

static func _match_key(node: Node, ks: Dictionary) -> String:
	var sfp := node.scene_file_path
	if sfp != "":
		var base := sfp.get_file().get_basename()
		if ks.has(base): return base
	var n := String(node.name).split("@")[0]
	if ks.has(n): return n
	var m := n
	while m.length() > 0 and m[m.length() - 1] >= "0" and m[m.length() - 1] <= "9":
		m = m.substr(0, m.length() - 1)
		if ks.has(m): return m
	return ""

static func match_key_public(node: Node) -> String:
	return _match_key(node, keys())

static func apply(root: Node, tier: Tier, textured: bool = true) -> int:
	if root == null: return 0
	var ks := keys()
	if ks.is_empty(): return 0
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == HP_NODE:
			continue
		if node is Node3D:
			var k := _match_key(node, ks)
			if k != "":
				if apply_one(node as Node3D, ks[k], tier, textured):
					count += 1
				continue
		for c in node.get_children():
			stack.append(c)
	return count

static func apply_one(node: Node3D, entry: Dictionary, tier: Tier, textured: bool) -> bool:
	if tier == Tier.LOW:
		var hp := node.get_node_or_null(HP_NODE)
		if hp and hp is Node3D: (hp as Node3D).visible = false
		_set_proxy_visible(node, true)
		return true
	var path := asset_for(entry, tier)
	if path == "": return false
	var hp := node.get_node_or_null(HP_NODE)
	if hp != null and hp.get_meta("hp_asset", "") != path:
		node.remove_child(hp); hp.queue_free(); hp = null   # tier changed -> rebuild
	if hp == null:
		if not ResourceLoader.exists(path): return false
		var res = load(path)
		if res == null: return false
		var child: Node3D = null
		if res is PackedScene:
			child = (res as PackedScene).instantiate() as Node3D
		elif res is Mesh:
			var mi := MeshInstance3D.new(); mi.mesh = res; child = mi
		if child == null: return false
		child.name = HP_NODE
		child.scene_file_path = ""           # anonymize: SDK level validator ignores us
		child.set_meta("hp_asset", path)
		if path.ends_with(".obj"):
			child.rotation_degrees = HP_ROT
		node.add_child(child)
		child.owner = null                   # editor-only: not saved, not exported
		var key := path.get_file().get_basename().trim_suffix("_med")
		if not (key in NOFIT) and not _fit_scale(node, child):
			node.remove_child(child); child.queue_free()
			return false                     # wrong-shaped asset: keep the proxy
		hp = child
	(hp as Node3D).visible = true
	_set_textured(hp, textured)
	_set_proxy_visible(node, false)
	return true

static func _set_textured(hp: Node, textured: bool) -> void:
	var stack: Array = [hp]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).material_override = null if textured else gray_material()
		for c in n.get_children():
			stack.append(c)

static func _set_proxy_visible(node: Node3D, vis: bool) -> void:
	var stack: Array = []
	for c in node.get_children():
		if c.name != HP_NODE:
			stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HP_NODE:
			continue                       # never touch overlay geometry
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).visible = vis
		for c in n.get_children():
			stack.append(c)

static func purge_all() -> int:
	# delete every downloaded preview asset under res://highpoly
	var removed := 0
	var da := DirAccess.open(HP_DIR)
	if da == null: return 0
	for sub in da.get_directories():
		var dir := "%s/%s" % [HP_DIR, sub]
		for f in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute("%s/%s" % [dir, f])
		if DirAccess.remove_absolute(dir) == OK:
			removed += 1
	return removed

static func in_overlay(node: Node) -> bool:
	var n := node
	while n != null:
		if n.name == HP_NODE: return true
		n = n.get_parent()
	return false

# ---------- conservative auto-fit (identity-first) ----------

static func _merged_aabb(root: Node, skip_name: String) -> AABB:
	var out := AABB()
	var first := true
	var inv: Transform3D = (root as Node3D).global_transform.affine_inverse()
	var stack: Array = []
	for c in root.get_children():
		if c.name != skip_name: stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			var g := n as GeometryInstance3D
			var ab: AABB = (inv * g.global_transform) * g.get_aabb()
			if first: out = ab; first = false
			else: out = out.merge(ab)
		for c in n.get_children():
			stack.append(c)
	return out

static func _perm_bases() -> Array:
	var x := Vector3(1,0,0); var y := Vector3(0,1,0); var z := Vector3(0,0,1)
	var perms := [[x,y,z],[x,z,y],[y,x,z],[y,z,x],[z,x,y],[z,y,x]]
	var out: Array = []
	for p in perms:
		var b := Basis(p[0], p[1], p[2])
		if b.determinant() < 0.0:
			b = Basis(-p[0], p[1], p[2])
		out.append(b)
	return out

static func _fit_eval(pd: Vector3, rd: Vector3) -> Array:
	# ignore dimensions that are tiny in absolute terms OR relative to the
	# object (a door's thickness measuring 0.17 vs 0.26 must not veto the
	# match when width/height agree perfectly)
	var pmax: float = max(pd.x, max(pd.y, pd.z))
	var thin: float = max(0.05, 0.12 * pmax)
	var ratios: Array = []
	for i in range(3):
		if pd[i] > thin and rd[i] > thin:
			ratios.append(pd[i] / rd[i])
	if ratios.is_empty(): return [1.0, 1.0]
	var s := 0.0
	for r in ratios: s += r
	return [ratios.max() / ratios.min(), s / ratios.size()]

static func _fit_scale(node: Node3D, child: Node3D) -> bool:
	var pa := _merged_aabb(node, HP_NODE)
	var ha := _merged_aabb(child, "")
	var pd := pa.size
	var hd := ha.size
	if pd.length() < 0.02 or hd.length() < 0.02: return true
	var ident: Array = _fit_eval(pd, hd)
	var best_spread: float = ident[0]
	var best_scale: float = ident[1]
	var best_basis := Basis()
	var rotated := false
	if ident[0] > 1.35:
		for b in _perm_bases():
			var ev: Array = _fit_eval(pd, (b * hd).abs())
			if ev[0] < best_spread:
				best_spread = ev[0]; best_scale = ev[1]; best_basis = b; rotated = true
	if best_spread > 1.35: return false
	var need_scale: bool = best_scale < 0.9 or best_scale > 1.1
	if not rotated and not need_scale:
		return true
	var xf := child.transform
	if rotated:
		xf.basis = best_basis * xf.basis
	if need_scale:
		xf.basis = xf.basis.scaled(Vector3(best_scale, best_scale, best_scale))
	child.transform = xf
	var ha2 := _merged_aabb(child, "")
	var off := pa.get_center() - ha2.get_center()
	var thin: bool = min(pd.x, min(pd.y, pd.z)) < 0.15 * max(pd.x, max(pd.y, pd.z))
	if thin:
		off.y = pa.end.y - ha2.end.y
	child.position += off
	return true
