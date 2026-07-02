@tool
extends RefCounted
class_name HighpolyLib
# Non-destructive, editor-only high-poly preview overlay.
# The low-poly proxy stays the SOURCE OF TRUTH (saved, exported); the high-poly
# is an owner=null overlay child (never saved). Toggle on/off at any time.
# Matching is by the instanced scene's FILE PATH (works for duplicates/renames),
# with a name-based fallback. Never raises errors: unmatched pieces are skipped.

const HP_DIR := "res://highpoly"
const HP_ROT := Vector3(-90, 0, 0)   # legacy OBJ assets are Z-up; GLB assets are Y-up
const HP_NODE := "_HIPOLY_PREVIEW"
# assets verified to share the proxy's pivot but whose AABBs legitimately differ
# (multi-part assemblies etc.) — trust identity placement, skip the fitter
const NOFIT := ["WreckTank_Abra01"]

static func keys() -> Dictionary:
	var d := {}
	var da := DirAccess.open(HP_DIR)
	if da == null: return d
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if da.current_is_dir() and not f.begins_with("."):
			var glb := "%s/%s/%s.glb" % [HP_DIR, f, f]
			var obj := "%s/%s/%s.obj" % [HP_DIR, f, f]
			if ResourceLoader.exists(glb): d[f] = glb
			elif ResourceLoader.exists(obj): d[f] = obj
		f = da.get_next()
	return d

static func _match_key(node: Node, ks: Dictionary) -> String:
	# 1) authoritative: the instanced proxy scene file (duplicate/rename-proof)
	var sfp := node.scene_file_path
	if sfp != "":
		var base := sfp.get_file().get_basename()
		if ks.has(base): return base
	# 2) fallback: node name with trailing digits stripped
	var n := String(node.name).split("@")[0]
	if ks.has(n): return n
	var m := n
	while m.length() > 0 and m[m.length() - 1] >= "0" and m[m.length() - 1] <= "9":
		m = m.substr(0, m.length() - 1)
		if ks.has(m): return m
	return ""

static func apply(root: Node, on: bool) -> int:
	if root == null: return 0
	var ks := keys()
	if ks.is_empty(): return 0
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Node3D:
			var k := _match_key(node, ks)
			if k != "":
				if _toggle(node as Node3D, on, ks[k]):
					count += 1
				continue   # don't descend into a swapped piece (its children are handled)
		for c in node.get_children():
			stack.append(c)
	return count

static func _set_proxy_visible(node: Node3D, vis: bool) -> void:
	# hide/show every visual under the proxy, skipping ALL overlay subtrees
	# (ours or a nested matched piece's) at any depth
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

static func _merged_aabb(root: Node, skip_name: String) -> AABB:
	# union of all GeometryInstance3D aabbs, in root-local space
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

# the 6 axis permutations as proper rotation bases (AABB size is sign-invariant)
static func _perm_bases() -> Array:
	var x := Vector3(1,0,0); var y := Vector3(0,1,0); var z := Vector3(0,0,1)
	var perms := [
		[x, y, z], [x, z, y], [y, x, z], [y, z, x], [z, x, y], [z, y, x],
	]
	var out: Array = []
	for p in perms:
		var b := Basis(p[0], p[1], p[2])
		if b.determinant() < 0.0:
			b = Basis(-p[0], p[1], p[2])              # fix handedness (mirror-free)
		out.append(b)
	return out

static func _fit_eval(pd: Vector3, rd: Vector3) -> Array:
	# -> [spread, mean_ratio] for proxy dims vs rotated overlay dims
	var ratios: Array = []
	for i in range(3):
		if pd[i] > 0.05 and rd[i] > 0.05:             # skip near-zero dims (flat panels)
			ratios.append(pd[i] / rd[i])
	if ratios.is_empty(): return [1.0, 1.0]           # nothing measurable -> assume fine
	var s := 0.0
	for r in ratios: s += r
	return [ratios.max() / ratios.min(), s / ratios.size()]

static func _fit_scale(node: Node3D, child: Node3D) -> bool:
	# CONSERVATIVE fit: the proxy's placement is the source of truth.
	#  - identity orientation wins unless it truly fails AND a rotation truly fits
	#  - no correction at all when identity fits at ~1:1 (pure inherited transform)
	#  - re-center only when a correction was applied; thin pieces align TOPS in Y
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
	if ident[0] > 1.35:                               # identity fails -> consider rotations
		for b in _perm_bases():
			var ev: Array = _fit_eval(pd, (b * hd).abs())
			if ev[0] < best_spread:
				best_spread = ev[0]; best_scale = ev[1]; best_basis = b; rotated = true
	if best_spread > 1.35: return false               # nothing fits -> wrong asset, keep proxy
	var need_scale: bool = best_scale < 0.9 or best_scale > 1.1
	if not rotated and not need_scale:
		return true                                   # fits as-is: inherit placement untouched
	var xf := child.transform
	if rotated:
		xf.basis = best_basis * xf.basis
	if need_scale:
		xf.basis = xf.basis.scaled(Vector3(best_scale, best_scale, best_scale))
	child.transform = xf
	var ha2 := _merged_aabb(child, "")
	var off := pa.get_center() - ha2.get_center()
	var thin: bool = min(pd.x, min(pd.y, pd.z)) < 0.15 * max(pd.x, max(pd.y, pd.z))
	if thin:                                          # floors/panels: keep surfaces flush
		off.y = pa.end.y - ha2.end.y
	child.position += off
	return true

static func _toggle(node: Node3D, on: bool, path: String) -> bool:
	var hp := node.get_node_or_null(HP_NODE)
	if on:
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
			if path.ends_with(".obj"):
				child.rotation_degrees = HP_ROT
			node.add_child(child)
			child.owner = null                   # editor-only: not saved, not exported
			if not (path.get_file().get_basename() in NOFIT) and not _fit_scale(node, child):
				node.remove_child(child)
				child.queue_free()
				return false                     # wrong-shaped asset: keep the proxy
		else:
			(hp as Node3D).visible = true
			hp.scene_file_path = ""              # clear legacy overlays too
		_set_proxy_visible(node, false)
		return true
	else:
		if hp and hp is Node3D: (hp as Node3D).visible = false
		_set_proxy_visible(node, true)
		return true
