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

# The one place a Light3D is built, shared with the level's own lights so a
# placed lamp and a level lamp cannot disagree about energy, cone or aim.
const LightScript = preload("highpoly_lighting.gd")

const HP_ROT := Vector3(-90, 0, 0)   # legacy OBJ assets are Z-up; GLB assets are Y-up
const HP_NODE := "_HIPOLY_PREVIEW"
# Render layer 19: "this geometry already has its real textures". Shared with the
# map-context props (highpoly_mapcontext.gd uses the same constant); layer 20
# (EXT_TERRAIN_LAYER) is the same tag for our extended terrain, roads and water.
#
# It was an opt-out from OUR map-tile decal, which excluded these layers in its
# cull_mask. That decal is gone (the SDK ships the feature and saves it into the
# user's scene). The SDK's own decal sets its own cull_mask and projects onto
# everything, so the layer does not opt out of theirs — the map context hides
# theirs while Extended Terrain is on instead.
# NOTE for render/PhotoMatch cameras: cull_mask must stay 0xFFFFF or anything on
# these layers silently vanishes from renders only.
const TEXTURED_LAYER := 1 << 18
const COL_NODE := "_COLLISION_VIS"   # collision overlay (highpoly_collision.gd)
const LEGACY_DIR := "res://highpoly"
# Props whose proxy AABB legitimately disagrees with the real asset's shape
# (e.g. a wreck proxy that is just the hull) — skip the auto-fitter for these
# so it doesn't wrongly rescale or reject the overlay. Prefab-assembled models
# carry the same flag data-driven, via `nofit` in the store index.
const NOFIT := ["WreckTank_Abra01"]
# Bump when the fitting RULE changes, so overlays carrying an older fit are
# rebuilt instead of kept. 1 = measure the object's own geometry only, not the
# props a builder parented under it.
const FIT_EPOCH := 1

# The open HighpolyGameSource, or null. Set by the plugin when it opens one, and
# the reason this library no longer needs a download: an object is assembled
# from the game's own prefab rather than fetched as a pre-baked GLB.
#
# Untyped and static: highpoly_gamesource preloads nothing from here, and typing
# it would make this module depend on the reader stack - which is exactly the
# dependency that stops the library being usable without one.
static var game_source = null

enum Tier { LOW, MEDIUM, HIGH }      # MEDIUM retired in 1.4 (kept for compat)

static var use_legacy := false       # pre-migration installs: read res://highpoly
# Current Detail Mode, mirrored from the dock's dropdown by _mode(). Read by
# HighpolySync._tier_for() to pick a rendition: Low-Poly renders clay, so it has
# no use for hq texture maps and pulls the small web copy of identical geometry.
# Statics are wiped on every plugin re-parse; the dock rewrites this on its first
# _mode() call, and LOW is the safe default because it is also the startup mode.
static var detail: Tier = Tier.LOW
static var _gray: StandardMaterial3D = null

static func gray_material() -> StandardMaterial3D:
	if _gray == null:
		_gray = StandardMaterial3D.new()
		_gray.albedo_color = Color(0.72, 0.72, 0.74)
		_gray.roughness = 0.9
	return _gray

# ---------- what can we overlay? ----------
# WHICH PROXIES THIS PLUGIN COULD OVERLAY, taken from the SDK's own objects
# folder.
#
# It used to be the downloaded model library plus every row of a published
# manifest, which made the set a property of a server. There is no library and
# no manifest now: the models come out of the player's own game. The right
# question is therefore "what can be PLACED", and the SDK answers it directly -
# res://objects is the catalogue it ships, and it is the user's own project
# rather than anything fetched.
#
# Whether a given one can actually be DRAWN is a separate question, asked of the
# install in _asset_id. Something the game has no prefab for simply keeps its SDK
# proxy, which is the honest outcome and what the user sees today anyway while a
# download is pending.
#
# Scanned once (10,883 scenes on this SDK) and kept. rescan() drops it.
const SDK_OBJECTS := "res://objects"
static var _sdk_keys: Dictionary = {}
static var _sdk_scanned := false

static func rescan_objects() -> void:
	_sdk_scanned = false
	_sdk_keys.clear()

static func known() -> Dictionary:
	if use_legacy:
		var d := {}
		var da := DirAccess.open(LEGACY_DIR)
		if da != null:
			for f in da.get_directories():
				if not f.begins_with("."):
					d[f] = true
		return d
	if not _sdk_scanned:
		_sdk_scanned = true
		_scan_objects(SDK_OBJECTS)
	return _sdk_keys


static func _scan_objects(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		var fn := str(f)
		# .remap turns up in exported projects; the basename is what matters
		if fn.get_extension().to_lower() == "tscn" or fn.ends_with(".tscn.remap"):
			_sdk_keys[fn.trim_suffix(".remap").get_basename()] = true
	for sub in da.get_directories():
		if not str(sub).begins_with("."):
			_scan_objects("%s/%s" % [dir, sub])

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
		# AN INSTANCE ANSWERS FOR ITSELF, AND IS NEVER GUESSED AT BY ITS NAME.
		#
		# This used to fall through to the node-name rules below when the scene's
		# own basename was not in known(). A node carrying scene_file_path IS a
		# placed instance of a known object; if we do not have that object, the
		# answer is "nothing", not "something with a similar name". Builders
		# rename constantly - a FiringRange_Floor_A called Elevator2NotDamaged is
		# the normal case, not an odd one - and the fall-through would dress it as
		# whatever asset its NEW name happened to look like, including after the
		# trailing-digit stripping below. That is a wrong model on the right
		# object: it flips, it is the wrong size, and the proxy underneath it
		# stays perfectly correct, which is exactly how it presents.
		return ""
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

# ---------- teardown ----------
# Put the scene back to stock: our overlays hidden, the SDK's own proxies shown.
#
# This used to be spelled `apply(root, Tier.LOW, true)`, which worked only for as
# long as Low-Poly happened to mean "draw nothing of ours". It does not any more:
# Low-Poly now draws our geometry as clay, so the old spelling would LEAVE the
# overlays in place at exactly the four moments that must not (plugin disable,
# reset, scene switch, scene-only prune). Those callers never wanted a tier, they
# wanted off, so they now say off.
#
# Deliberately no `known()` guard. apply() returns early when the registry is
# empty, which is right for applying and wrong for tearing down: after a purge
# there are no known models and the overlays still need removing.
static func restore(root: Node) -> int:
	if root == null: return 0
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == "_MAP_CONTEXT" or node.name == COL_NODE:
			continue
		if node is Node3D and node.get_node_or_null(HP_NODE) != null:
			_show_proxy_only(node as Node3D)
			count += 1
		for c in node.get_children():
			if c.name != HP_NODE:
				stack.append(c)
	return count

# Hide our overlay, reveal the SDK proxy underneath. The overlay is left parented
# rather than freed so that switching back does not re-instantiate and re-fit
# every model; teardown callers that need the files released free the subtree via
# the owner=null rule when the scene closes.
#
# Does NOT touch visibility_range. That property has exactly one owner, and it is
# HighpolyPlacedCull, which remembers what each mesh started with so an authored
# draw distance survives. A second writer here would clear ranges PlacedCull
# still believes it is holding, and strip authored values from the user's .tscn.
# Every teardown path already calls PlacedCull.release() before this.
static func _show_proxy_only(node: Node3D) -> void:
	var hp := node.get_node_or_null(HP_NODE)
	if hp != null and hp is Node3D:
		(hp as Node3D).visible = false
	_set_proxy_visible(node, true)

# ---------- apply ----------
# WHAT WOULD BE SWAPPED, without swapping any of it. -> [[Node3D, key], …]
#
# Split out of apply() so a caller can put a bar on the work. apply() itself
# cannot: it is one uninterrupted pass that builds an overlay per prop, the
# editor does not repaint until it returns, and a swap of a few thousand props is
# a hard freeze with nothing on screen. A caller that has the list up front knows
# the total, can do them a slice at a time and can yield a frame between slices.
#
# Deciding WHICH nodes to touch is cheap (a name match); building each overlay is
# not, and only the second half needs to be paced. The walk is identical to the
# one apply() used to do inline, including the order, so the two produce the same
# result on the same scene.
static func plan(root: Node) -> Array:
	var out: Array = []
	if root == null: return out
	var ks := known()
	if ks.is_empty(): return out
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == HP_NODE or node.name == "_MAP_CONTEXT" or node.name == COL_NODE:
			continue                          # skip our overlays (esp. the huge map-context subtree)
		if node is Node3D:
			var k := _match_key(node, ks)
			if k != "":
				out.append([node as Node3D, k])
				_push_user_children(node, stack)   # user props nested under this one
				continue
		for c in node.get_children():
			stack.append(c)
	return out


static func apply(root: Node, tier: Tier, textured: bool = true) -> int:
	var count := 0
	for e in plan(root):
		var pair: Array = e
		if apply_one(pair[0] as Node3D, str(pair[1]), tier, textured):
			count += 1
	return count

# Apply only the props in `names` (the batched swap-in pass after downloads):
# touches matching nodes that don't already carry a current overlay.
static func apply_names(root: Node, names: Dictionary, tier: Tier, textured: bool) -> int:
	# Gated on Tier.LOW again. While Low-Poly meant "our geometry, untextured"
	# this had to run in every mode or a just-downloaded model stayed invisible
	# until the user switched. Now Low-Poly means the SDK proxy, so swapping our
	# mesh in here would silently contradict the mode the user selected — and
	# with downloads switched off in Low-Poly there is nothing arriving to swap.
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
	# THE GAME FIRST. Every model this library ever shipped was assembled from a
	# pf_portal_<name> prefab IN THE GAME - the authoritative list of member
	# meshes and their transforms - and baked into a GLB ahead of time. The
	# reader can do that assembly here instead, so nothing has to be fetched to
	# see the object, and the composite case works: 1,066 members at 1,030
	# distinct transforms for a building, which single-mesh name matching could
	# never represent.
	if game_source != null and game_source.has_object(key):
		return "game://%s" % key
	return ""

static func _instance_for(key: String, id: String) -> Node3D:
	if id.begins_with("variant://"):
		var vs := variant_scene(id.trim_prefix("variant://"))
		return vs.instantiate() as Node3D if vs != null else null
	if id.begins_with("game://"):
		if game_source == null:
			return null
		var gkey := id.trim_prefix("game://")
		var gnode: Node3D = game_source.object_node(gkey)
		# THE FIXTURES INSIDE THE PREFAB, not only its meshes.
		#
		# A lamp used to arrive with its geometry and none of its lighting, which
		# is a stranger result than it sounds: the bulb is there, lit by nothing,
		# so the prop reads as broken rather than as unlit. The records come from
		# the same walk and the same builder the level's own lights use, so a
		# placed lamp and a level lamp are the same fixture.
		#
		# Capped inside attach_prop_lights: Forward+ stops at 512 clustered
		# lights in view, and a lined street would pass that without the builder
		# doing anything unreasonable.
		if gnode != null and game_source.has_method("object_lights"):
			var recs: Array = game_source.object_lights(gkey)
			if not recs.is_empty():
				LightScript.attach_prop_lights(gnode, recs)
		return gnode
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
	return false

static func apply_one(node: Node3D, key: String, tier: Tier, textured: bool) -> bool:
	# LOW MEANS THE SDK'S OWN PROXY. Not our mesh drawn plainly — the actual
	# thing that gets saved and exported.
	#
	# This was briefly changed to "our geometry, untextured" because a placed
	# asset in Low-Poly rendered as a solid white block and never improved. That
	# complaint was real, but it was about DISCOVERABILITY, not about the mode:
	# in Low-Poly the white block is correct, because the white block is what you
	# export. Answering it by drawing our mesh instead cost three things —
	#   * modes 0 and 1 became pixel-identical for placed objects, so one entry
	#     of a three-entry dropdown did nothing;
	#   * there was no way to see your real export while the plugin was on,
	#     which is the one thing this plugin promises not to disturb;
	#   * "Low-Poly" downloaded every model and drew every triangle, so the
	#     cheap-sounding default was the expensive one.
	# The panel now says plainly what this mode is showing instead (see
	# _mode_hint in highpoly_toggle.gd), which is what the original complaint
	# actually needed.
	if tier == Tier.LOW:
		_show_proxy_only(node)
		return false
	var id := _asset_id(key)
	if id == "":
		# The game has no prefab for this one, so the SDK proxy is the answer and
		# there is nothing to wait for. Any overlay still drawing came from an
		# earlier resolution that no longer holds, so take it down rather than
		# leave geometry up that nothing backs.
		if node.get_node_or_null(HP_NODE) != null:
			_show_proxy_only(node)
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
	# THE FITTER'S ANSWER IS BAKED INTO THE OVERLAY'S TRANSFORM, so an overlay
	# built under an older fitting rule keeps that older answer forever: the
	# asset id still matches, nothing rebuilds it, and the user updates the
	# plugin to no visible effect at all. That is exactly what happened after the
	# group-AABB fix - tower1's overlay was still carrying its 4.951 scale.
	# Bumping FIT_EPOCH retires every overlay fitted under the old rule, the same
	# way GEOM_EPOCH retires a geometry cache whose rule changed.
	if hp != null and (hp.get_meta("hp_asset", "") != id
			or int(hp.get_meta("hp_fit", -1)) != FIT_EPOCH):
		node.remove_child(hp); hp.queue_free(); hp = null   # tier/model/fit changed -> rebuild
	if hp == null:
		var child := _instance_for(key, id)
		if child == null: return false
		child.name = HP_NODE
		child.scene_file_path = ""           # anonymize: SDK level validator ignores us
		child.set_meta("hp_asset", id)
		child.set_meta("hp_fit", FIT_EPOCH)
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
	# Overlays follow the dock's Shadows sub-checkbox, exactly as map-context
	# props already do (highpoly_mapcontext, _build_mmi).
	#
	# They used to have no shadow handling at all, so every one defaulted to
	# casting. That cost nothing while Low-Poly drew no overlays. Once Low-Poly
	# started drawing them, switching lighting on added a shadow caster for every
	# placed object in one go, all of it landing in the directional shadow atlas
	# at a 1,500 m range -- enough to crash the editor outright on the
	# multi-threaded renderer this project ships with.
	var shadow: int = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if HighpolyLighting.cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var stack: Array = [hp]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			(n as GeometryInstance3D).cast_shadow = shadow
			(n as GeometryInstance3D).material_override = null if textured else gray_material()
			# Keep the map-tile decal OFF the high-poly overlay. The decal exists
			# to colour the SDK's own untextured terrain and grey proxy buildings;
			# projecting it over models that already carry their real game textures
			# just tints and washes them out. A Decal only affects layers in its
			# cull_mask, so moving the overlay to its own layer is the one way to
			# opt out that changes nothing about the models themselves.
			(n as GeometryInstance3D).layers = TEXTURED_LAYER
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

static var _var_disc: Dictionary = {}     # proxy -> {variant: glb_path} (merged, cached)
static var _var_scenes: Dictionary = {}   # glb_path -> PackedScene (null = parse failed)

# Forget what was discovered so a variant that arrived AFTER the first lookup
# becomes visible without reloading the plugin.
#
# Both caches are permanent statics and nothing used to clear them. The worse
# half was _var_disc: variants_of() caches its result PER PROXY including the
# empty one, so the first double-click on a prop whose variants had not
# downloaded yet poisoned that prop for the rest of the session. Downloading the
# variants then changed nothing, which reads as "variant cycling is broken".
static func forget_variants(prox: String = "") -> void:
	if prox == "":
		_var_disc.clear()
	else:
		_var_disc.erase(prox)

static func variants_of(prox: String) -> Dictionary:
	if _var_disc.has(prox):
		return _var_disc[prox]
	var found: Dictionary = {}
	var da := DirAccess.open("%s/%s" % [LEGACY_DIR, prox])
	if da != null:
		var prefix := prox + "__"
		for f in da.get_files():
			if f.begins_with(prefix) and f.get_extension() == "glb":
				var vn := f.get_basename().substr(prefix.length())
				if vn != "":
					found[vn] = "%s/%s/%s" % [LEGACY_DIR, prox, f]
	_var_disc[prox] = found
	return found

# A proxy has the variants that are staged beside it in the project. There is no
# registry to advertise any others: nothing is published and nothing is fetched.
static func declared_variants(_prox: String) -> Array:
	return []

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

# ---------- select-through ----------
#
# CLICKING A HIGH-POLY MODEL HAS TO SELECT THE PROXY UNDER IT.
#
# The overlay is owner = null, which is what keeps it out of the saved scene and
# out of the export. The cost of that is invisible until you try to work: Godot's
# viewport picking only ever selects nodes OWNED by the edited scene, so it skips
# the overlay entirely - and High-Poly hides the proxy's own meshes, so there is
# nothing behind it to hit either. The click lands on nothing and the object
# cannot be grabbed, moved or rotated at all. Only the Scene tree still worked.
#
# So the click is answered here instead: find which proxy's overlay is under the
# cursor and select THAT PROXY. The user then has the ordinary gizmo on the
# ordinary node, the overlay follows because it is a child, and nothing about the
# ownership rule changes.
#
# Done in GLOBAL space on purpose. Everything here has a world transform already
# and mixing local-space slab tests with parent scales is how the fitter's
# mirroring bugs happened.
static func _global_aabb(root: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D and (n as GeometryInstance3D).visible:
			var g := n as GeometryInstance3D
			var ab: AABB = g.global_transform * g.get_aabb()
			if first:
				out = ab; first = false
			else:
				out = out.merge(ab)
		for c in n.get_children():
			stack.append(c)
	return out


static func _ray_aabb(ab: AABB, o: Vector3, d: Vector3) -> float:
	if ab.size.length() < 0.001:
		return -1.0
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


# The nearest proxy whose OVERLAY is under the cursor, or null.
#
# Tested against the overlay rather than the proxy because the overlay is what
# the user can see and is aiming at: a high-poly model and its low-poly box are
# not the same shape, and picking a lamp post by the box around it would select
# things the user is not pointing at.
static func proxy_under(camera: Camera3D, pos: Vector2, root: Node) -> Node3D:
	if camera == null or root == null:
		return null
	var o := camera.project_ray_origin(pos)
	var d := camera.project_ray_normal(pos)
	var best: Node3D = null
	var best_t := 1e20
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D:
			var hp := n.get_node_or_null(HP_NODE)
			if hp != null and (hp as Node3D).visible:
				var t := _ray_aabb(_global_aabb(hp), o, d)
				if t >= 0.0 and t < best_t:
					best_t = t
					best = n as Node3D
		for c in n.get_children():
			# A proxy's overlay never contains another proxy, so not descending
			# into it keeps this off the thousands of nodes a high-poly model
			# has. _MAP_CONTEXT matters far more: it is the whole rebuilt map and
			# runs to six figures of nodes, none of them a placed proxy, so
			# walking it would put a visible hitch on every single click.
			if c.name != HP_NODE and c.name != COL_NODE and c.name != "_MAP_CONTEXT":
				stack.append(c)
	return best


# ---------- conservative auto-fit (identity-first) ----------

# AN OBJECT'S OWN GEOMETRY, NOT ITS GROUP'S.
#
# THE BUG THIS FIXES. Builders parent props under other props so they move
# together - a lift platform with five floor pieces on it - and _push_user_children
# has always known that. This did not: it merged EVERY descendant, so a node
# used as a group measured as the whole group. The fitter then compared six
# spread-out floor pieces against the one model this node actually is, decided
# the identity fit was hopeless, and picked whichever axis permutation made the
# numbers agree - standing the model on its edge and scaling it up 44% to fill
# the group's bounds. Measured live on the user's Elevator2NotDamaged, whose
# overlay carried basis X (-1.436, 0, 0), Y (0, 0, 1.436), Z (0, 1.436, 0):
# a Y/Z swap with X negated, which is _perm_bases() entry 1 times 1.436.
#
# It looks correct in Low-Poly for the same reason it is hard to spot: nothing
# touches the proxy, so only the overlay is wrong, and only on the minority of
# props a builder happens to have parented things under.
#
# User content is identified exactly as _set_proxy_visible identifies it, by
# being owned by the edited scene. Instance-internal geometry (the object's own
# Mesh, owned by the instance) is kept, which is the whole point.
static func _merged_aabb(root: Node, skip_name: String) -> AABB:
	var out := AABB()
	var first := true
	var inv: Transform3D = (root as Node3D).global_transform.affine_inverse()
	var scene_root: Node = EditorInterface.get_edited_scene_root()
	var stack: Array = []
	for c in root.get_children():
		if c.name != skip_name and c.name != COL_NODE: stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == COL_NODE or n.name == skip_name:
			continue                       # collision overlay must not skew the fit
		# A prop a builder parented under this one is a separate object that
		# happens to ride along. It is not part of what this node IS, and
		# measuring it is what stood the model on its edge. Its own subtree goes
		# with it.
		if scene_root != null and n.owner == scene_root:
			continue
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
