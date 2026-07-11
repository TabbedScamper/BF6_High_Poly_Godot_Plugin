@tool
extends RefCounted
class_name HighpolyLib
# Non-destructive, editor-only high-poly preview overlay.
# The low-poly proxy stays the SOURCE OF TRUTH (saved, exported); the overlay
# is an owner=null child `_HIPOLY_PREVIEW` (never saved).
#
# v1.5: models come from the user:// store (runtime-parsed GLBs — nothing in
# res://, nothing imported). A prop whose model isn't local yet keeps its proxy
# and is recorded in `wanted`; the dock hands those to the sync manager and
# swaps them in automatically as they land. `use_legacy` keeps the exact 1.4
# res://highpoly behavior alive for installs that haven't migrated yet.

const HP_ROT := Vector3(-90, 0, 0)   # legacy OBJ assets are Z-up; GLB assets are Y-up
const HP_NODE := "_HIPOLY_PREVIEW"
const COL_NODE := "_COLLISION_VIS"   # collision overlay (highpoly_collision.gd)
const LEGACY_DIR := "res://highpoly"
# Props whose proxy AABB legitimately disagrees with the real asset's shape
# (e.g. a wreck proxy that is just the hull) — skip the auto-fitter for these
# so it doesn't wrongly rescale or reject the overlay. Prefab-assembled models
# carry the same flag data-driven, via `nofit` in the store index.
const NOFIT := ["WreckTank_Abra01"]

enum Tier { LOW, MEDIUM, HIGH }      # MEDIUM retired in 1.4 (kept for compat)

static var use_legacy := false       # pre-migration installs: read res://highpoly
# props the current tier wants but the store doesn't have yet (drained by the
# dock into the sync queue after every apply pass)
static var wanted: Dictionary = {}

static func take_wanted() -> Array:
	var out := wanted.keys()
	wanted.clear()
	return out

static var _gray: StandardMaterial3D = null

static func gray_material() -> StandardMaterial3D:
	if _gray == null:
		_gray = StandardMaterial3D.new()
		_gray.albedo_color = Color(0.72, 0.72, 0.74)
		_gray.roughness = 0.9
	return _gray

# ---------- what can we overlay? ----------
# name -> true when the model is available locally, false when only the
# registry knows it (still matchable — it gets queued instead of skipped).
static func known() -> Dictionary:
	var d := {}
	if use_legacy:
		var da := DirAccess.open(LEGACY_DIR)
		if da != null:
			for f in da.get_directories():
				if not f.begins_with("."):
					d[f] = true
		return d
	for name in HighpolyStore.models().keys():
		d[name] = true
	for name in HighpolyStore.remote.keys():
		if not d.has(name):
			d[name] = false
	return d

static func _match_key(node: Node, ks: Dictionary) -> String:
	var sfp := node.scene_file_path
	if sfp != "":
		# only real placeable objects can be proxies. Instanced logic/gameplay
		# scenes (Sector, MCOM areas, FixedCamera, …) must never match a model
		# key — junk registry rows share their names, and a match here both
		# skips the node's subtree and hides its child geometry.
		if not sfp.begins_with("res://objects/"):
			return ""
		var base := sfp.get_file().get_basename()
		if ks.has(base): return base
	var n := String(node.name).split("@")[0]
	if ks.has(n): return n
	var m := n
	while m.length() > 0 and m[m.length() - 1] >= "0" and m[m.length() - 1] <= "9":
		m = m.substr(0, m.length() - 1)
		if ks.has(m): return m
	return ""

# A matched proxy's subtree may still contain USER-placed nodes (builders often
# parent props under buildings/groups so they move together). Those belong to
# the walk: collect every descendant owned by the edited scene root so the
# caller keeps walking them. Instance-internal geometry (owner = the instance)
# and owner=null overlays stay out.
static func _push_user_children(node: Node, stack: Array) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or node == scene_root: return
	var st: Array = []
	for c in node.get_children():
		if c.name != HP_NODE: st.append(c)
	while not st.is_empty():
		var c: Node = st.pop_back()
		if c.name == HP_NODE: continue
		if c.owner == scene_root:
			stack.append(c)          # user content: the main walk takes it from here
			continue
		for gc in c.get_children():
			st.append(gc)

static func match_key_public(node: Node) -> String:
	return _match_key(node, known())

# every proxy key present in a scene (used to feed the sync priority queue)
static func scene_keys(root: Node) -> Array:
	if root == null: return []
	var ks := known()
	var out: Dictionary = {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HP_NODE or n.name == "_MAP_CONTEXT" or n.name == COL_NODE:
			continue
		if n is Node3D:
			var k := _match_key(n, ks)
			if k != "":
				out[k] = true
				_push_user_children(n, stack)
				continue
		for c in n.get_children():
			stack.append(c)
	return out.keys()

# ---------- apply ----------
static func apply(root: Node, tier: Tier, textured: bool = true) -> int:
	if root == null: return 0
	var ks := known()
	if ks.is_empty(): return 0
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == HP_NODE or node.name == "_MAP_CONTEXT" or node.name == COL_NODE:
			continue                          # skip our overlays (esp. the huge map-context subtree)
		if node is Node3D:
			var k := _match_key(node, ks)
			if k != "":
				if apply_one(node as Node3D, k, tier, textured):
					count += 1
				_push_user_children(node, stack)   # user props nested under this one
				continue
		for c in node.get_children():
			stack.append(c)
	return count

# Apply only the props in `names` (the batched swap-in pass after downloads):
# touches matching nodes that don't already carry a current overlay.
static func apply_names(root: Node, names: Dictionary, tier: Tier, textured: bool) -> int:
	if root == null or names.is_empty() or tier == Tier.LOW: return 0
	var ks := known()
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == HP_NODE or node.name == "_MAP_CONTEXT" or node.name == COL_NODE:
			continue
		if node is Node3D:
			var k := _match_key(node, ks)
			if k != "":
				if names.has(k) and apply_one(node as Node3D, k, tier, textured):
					count += 1
				_push_user_children(node, stack)
				continue
		for c in node.get_children():
			stack.append(c)
	return count

# asset identity string: overlay rebuilds when it changes (tier switch, or a
# community fix bumping the model's hash)
static func _asset_id(key: String) -> String:
	if use_legacy:
		var high := "%s/%s/%s.glb" % [LEGACY_DIR, key, key]
		if ResourceLoader.exists(high): return high
		var obj := "%s/%s/%s.obj" % [LEGACY_DIR, key, key]
		if ResourceLoader.exists(obj): return obj
		return ""
	if HighpolyStore.has_model(key):
		return "store://%s#%s" % [key, HighpolyStore.hash_of(key)]
	return ""

static func _instance_for(key: String, id: String) -> Node3D:
	if id.begins_with("variant://"):
		var vs := variant_scene(id.trim_prefix("variant://"))
		return vs.instantiate() as Node3D if vs != null else null
	if id.begins_with("store://"):
		var ps := HighpolyStore.load_scene(key)
		return ps.instantiate() as Node3D if ps != null else null
	var res = load(id)
	if res is PackedScene:
		return (res as PackedScene).instantiate() as Node3D
	if res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res
		return mi
	return null

static func _nofit_for(key: String) -> bool:
	if key in NOFIT: return true
	if use_legacy:
		var side := "%s/%s/%s.json" % [LEGACY_DIR, key, key]
		if FileAccess.file_exists(side):
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
			return j is Dictionary and bool((j as Dictionary).get("nofit", false))
		return false
	return HighpolyStore.nofit(key)

static func apply_one(node: Node3D, key: String, tier: Tier, textured: bool) -> bool:
	if tier == Tier.LOW:
		var hp := node.get_node_or_null(HP_NODE)
		if hp and hp is Node3D: (hp as Node3D).visible = false
		_set_proxy_visible(node, true)
		return true
	var id := _asset_id(key)
	if id == "":
		wanted[key] = true                    # known to the registry, not local yet
		return false
	# per-instance variant selection (double-click cycling, highpoly_variants.gd):
	# the chosen variant GLB replaces the base model for this node only. A stale
	# selection whose file is gone falls back to the base silently.
	var vname := String(node.get_meta(VARIANT_META, ""))
	if vname != "":
		var vpath := variant_path(key, vname)
		if vpath != "":
			id = "variant://%s" % vpath
	var hp := node.get_node_or_null(HP_NODE)
	if hp != null and hp.get_meta("hp_asset", "") != id:
		node.remove_child(hp); hp.queue_free(); hp = null   # tier/model changed -> rebuild
	if hp == null:
		var child := _instance_for(key, id)
		if child == null: return false
		child.name = HP_NODE
		child.scene_file_path = ""           # anonymize: SDK level validator ignores us
		child.set_meta("hp_asset", id)
		if id.ends_with(".obj"):
			child.rotation_degrees = HP_ROT
		node.add_child(child)
		child.owner = null                   # editor-only: not saved, not exported
		# variants skip the fitter: they are published pre-aligned to the base
		# model's frame, and destroyed/partial variants LEGITIMATELY disagree
		# with the proxy AABB (the fitter would wrongly veto them)
		if not id.begins_with("variant://") \
				and not _nofit_for(key) and not _fit_scale(node, child):
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
	# When HIDING (overlay active), user-placed nodes nested under this proxy
	# are never touched — hiding a building's proxy must not vanish the props a
	# builder parented under it. When SHOWING (back to Low-Poly), restore
	# EVERYTHING — that also heals any geometry a pre-fix version wrongly hid.
	var scene_root: Node = EditorInterface.get_edited_scene_root() if not vis else null
	var stack: Array = []
	for c in node.get_children():
		if c.name != HP_NODE and c.name != COL_NODE:
			stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HP_NODE or n.name == COL_NODE:
			continue                       # never touch overlay geometry
		if scene_root != null and n.owner == scene_root:
			continue                       # user content under the proxy: leave it alone
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).visible = vis
		for c in n.get_children():
			stack.append(c)

# ---------- model variants (per-instance, cycled by highpoly_variants.gd) ----------
# Variant GLBs are full standalone models published NEXT TO the base model as
# <Proxy>__<variant>.glb — in the store (user://highpoly/models/) and/or the
# legacy/staging layout (res://highpoly/<Proxy>/). Discovery is a cheap
# directory glob cached per proxy; nothing reads variant metadata per node.

const VARIANT_META := "hp_variant"   # proxy-node meta: active variant ("" = base)

static var _store_var_scanned := false
static var _store_vars: Dictionary = {}   # proxy -> {variant: glb_path}
static var _var_disc: Dictionary = {}     # proxy -> {variant: glb_path} (merged, cached)
static var _var_scenes: Dictionary = {}   # glb_path -> PackedScene (null = parse failed)

# the flat store dir can hold thousands of files: scan it ONCE and bucket every
# "<Proxy>__<variant>.glb" by proxy, instead of re-globbing it per proxy
static func _scan_store_variants() -> void:
	if _store_var_scanned: return
	_store_var_scanned = true
	var da := DirAccess.open(HighpolyStore.MODELS_DIR)
	if da == null: return
	for f in da.get_files():
		if f.get_extension() != "glb": continue
		var base := f.get_basename()
		var i := base.find("__")
		if i <= 0: continue
		var vn := base.substr(i + 2)
		if vn == "": continue
		var prox := base.substr(0, i)
		var m: Dictionary = _store_vars.get(prox, {})
		m[vn] = "%s/%s" % [HighpolyStore.MODELS_DIR, f]
		_store_vars[prox] = m

static func variants_of(prox: String) -> Dictionary:
	if _var_disc.has(prox):
		return _var_disc[prox]
	_scan_store_variants()
	var found: Dictionary = {}
	# legacy/staging layout first; a store copy of the same variant wins below
	var da := DirAccess.open("%s/%s" % [LEGACY_DIR, prox])
	if da != null:
		var prefix := prox + "__"
		for f in da.get_files():
			if f.begins_with(prefix) and f.get_extension() == "glb":
				var vn := f.get_basename().substr(prefix.length())
				if vn != "":
					found[vn] = "%s/%s/%s" % [LEGACY_DIR, prox, f]
	var sv: Dictionary = _store_vars.get(prox, {})
	for vn in sv:
		found[vn] = sv[vn]
	_var_disc[prox] = found
	return found

static func variant_path(prox: String, vname: String) -> String:
	return str(variants_of(prox).get(vname, ""))

# runtime-parse a variant GLB exactly like the base models (the editor's
# GLTFDocument path yields non-rendering ImporterMeshInstance3D nodes;
# HighpolyStore.load_external_glb converts + compresses them correctly)
static func variant_scene(path: String) -> PackedScene:
	if _var_scenes.has(path):
		return _var_scenes[path]
	var ps := HighpolyStore.load_external_glb(path)
	_var_scenes[path] = ps
	return ps

static func in_overlay(node: Node) -> bool:
	var n := node
	while n != null:
		# HP_NODE = our high-poly overlay; _MAP_CONTEXT = the map-context overlay
		# (tens of thousands of owner=null nodes); COL_NODE = the collision
		# overlay. Detail Mode must ignore all of them.
		if n.name == HP_NODE or n.name == "_MAP_CONTEXT" or n.name == COL_NODE:
			return true
		n = n.get_parent()
	return false

# ---------- conservative auto-fit (identity-first) ----------

static func _merged_aabb(root: Node, skip_name: String) -> AABB:
	var out := AABB()
	var first := true
	var inv: Transform3D = (root as Node3D).global_transform.affine_inverse()
	var stack: Array = []
	for c in root.get_children():
		if c.name != skip_name and c.name != COL_NODE: stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == COL_NODE:
			continue                       # collision overlay must not skew the fit
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
