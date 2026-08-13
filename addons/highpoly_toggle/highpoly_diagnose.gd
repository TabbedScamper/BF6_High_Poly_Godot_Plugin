@tool
extends RefCounted
class_name HighpolyDiagnose

# DIAGNOSE SELECTION: tag one prop, in red, with everything that decided how it
# looks written into the log.
#
# The reporting problem this solves. "That tree looks wrong" is not actionable,
# and neither is a screenshot: a prop can look wrong because the mesh never
# resolved, because its scope found no depot, because the depot had no record
# for its shader state, because the record binds no albedo, or because its alpha
# mask was rejected as a placeholder — and all five draw the same flat white or
# solid quad. This walks that chain for one object and says which link gave the
# answer.
#
# WORKS ON BOTH KINDS OF THING, which is most of the code here:
#
#   PLACED PROPS are real scene nodes with owners, so the editor can select
#   them. What matters for those is the library key, whether an overlay was
#   built, and which asset id it resolved to (game:// straight out of the
#   install, or nothing at all).
#
#   ORIGINAL MAP ASSETS are our own overlay, injected with owner = null, so they
#   do NOT appear in the scene tree and the editor's own picker will not select
#   them. Three ways to point at one, in increasing order of precision:
#
#     1. camera aim      — run() with nothing selected, the original behaviour
#     2. PICK MODE       — click it in the viewport, our own raycast (pick())
#     3. TAB DRILLING    — once picked, step down into the group: the whole
#                          batch -> one instance -> one surface (step())
#
# WHY WE HAVE TO PICK IT OURSELVES. The editor's click-select resolves a click
# to a node owned by the edited scene, and every node we inject is deliberately
# owner-less so it never saves into the user's .tscn. That is not a limitation
# to work around by giving them owners — owners would put ~4,000 nodes of
# read-from-the-install geometry into their saved scene file. So the plugin does
# its own ray/triangle intersection against its own overlay instead, through
# _forward_3d_gui_input, exactly like the door double-click already does.
#
# WHY TAB DRILLING EXISTS. A car is ONE instance of ONE mesh inside a MultiMesh
# batch of forty cars. Its windows are not a node, not an instance, and not
# selectable by any amount of clicking: they are a SURFACE of that mesh, with
# their own shader state, their own depot record and their own textures. Since a
# surface is the exact granularity at which everything goes wrong (glass drawn
# opaque, one material white, a cutout rejected), the tool has to be able to
# address one. So a pick lands on the object and Tab steps inward to the part,
# the way Revit tabs into a group.
#
# The highlight is a separate drawn node rather than a material swap, so the
# thing you tagged still shows the bug you tagged it for.

const GROUP := "_HP_DIAGNOSE"        # meta key marking a node we tinted
const AIM_DIST := 25.0               # how far ahead of the camera to look
const AIM_RADIUS := 12.0             # and how wide

const HL_NODE := "_HP_DIAG_FOCUS"    # the highlight node's name
const TRI_BUDGET := 400000           # triangles a single click may ray-test
const BIG_SURFACE := 300000          # a surface bigger than this is AABB-only

static var _tinted: Array = []       # [{node, was}]
static var _overlay: StandardMaterial3D = null        # bright red: a CONFIRMED pick
static var _overlay_soft: StandardMaterial3D = null   # light red: hover / Tab preview

# Revit-style two-stage selection. Hovering (and Tab-cycling) shows a thing
# LIGHT red; a left click CONFIRMS it BRIGHT red. Only a confirmed focus is a
# selection: notes pin to it, and hover stops replacing it until Escape.
static var _confirmed := false

# The current focus: what a pick landed on and how deep Tab has gone.
#   {node, mesh, inst, levels: Array[Dictionary], idx: int, point: Vector3}
static var _focus: Dictionary = {}
static var _hl: Node = null           # the drawn highlight, so it can be freed

# Triangle soup per mesh, built on demand for ray tests. Bounded, because a
# terrain tile is megabytes of it and the picker must not grow without limit.
static var _soup_cache: Dictionary = {}
static var _soup_order: Array = []
const SOUP_KEEP := 12


static func _red(hard := true) -> StandardMaterial3D:
	if hard:
		if _overlay == null:
			_overlay = _make_red(Color(1.0, 0.05, 0.05, 0.6))
		return _overlay
	if _overlay_soft == null:
		_overlay_soft = _make_red(Color(1.0, 0.45, 0.45, 0.3))
	return _overlay_soft


static func _make_red(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Drawn on top of the thing it marks. Without this a tag on a prop
	# inside a building is invisible from outside it, which is exactly when
	# you want to find it again.
	m.no_depth_test = true
	m.render_priority = 20
	return m


# Undo every tint and drop the focus highlight. Restores each node's own
# material_overlay rather than clearing it, because a prop may have had one.
static func clear() -> int:
	var n := 0
	for e in _tinted:
		var d: Dictionary = e
		var node = d["node"]
		if node != null and is_instance_valid(node) and node is GeometryInstance3D:
			(node as GeometryInstance3D).material_overlay = d["was"]
			(node as Node).remove_meta(GROUP)
			n += 1
	_tinted.clear()
	if not _focus.is_empty():
		n += 1
	_drop_highlight()
	_focus = {}
	_confirmed = false
	return n


static func _tint(node: Node) -> void:
	if not (node is GeometryInstance3D):
		return
	var gi := node as GeometryInstance3D
	if gi.has_meta(GROUP):
		return
	_tinted.append({"node": gi, "was": gi.material_overlay})
	gi.set_meta(GROUP, true)
	gi.material_overlay = _red()


# ---------------------------------------------------------------------------
# PICKING
#
# Two phases, because the one-phase versions are both wrong:
#
#   AABB only is wrong because a terrain tile's box is a 128 m slab that a ray
#   enters long before it reaches the car standing on it, so the terrain wins
#   every click aimed at anything sitting on the ground.
#
#   Triangles only is wrong because there are millions of them and this runs in
#   GDScript on the click.
#
# So: box-test everything to get candidates and their entry distances, sort by
# entry distance, then ray-test triangles in that order and stop as soon as a
# real hit is nearer than the next candidate's box could possibly be. In
# practice that tests one or two objects per click.
# ---------------------------------------------------------------------------

# -> {} on a miss, else {node, mesh, inst, surf, point, dist}
#
# hover_mode changes two things, both because hovering runs per mouse move
# where a click runs once:
#   - candidates whose box CONTAINS the camera are dropped. The terrain tile,
#     the roads mesh and the water plane all enclose the viewpoint, so they
#     sort first at distance zero and starve the budget before the prop under
#     the cursor is ever triangle-tested - which read as "hover does not work
#     on map objects" while clicks (5x the budget) still resolved.
#   - a mesh too big to triangle-test inside the budget is not tested AT ALL
#     (no soup is built for it, which is the expensive part); it previews by
#     its box through the fallback instead. Big things still highlight, they
#     just do it cheaply.
static func pick(camera: Camera3D, pos: Vector2, root: Node,
		tri_budget := TRI_BUDGET, hover_mode := false) -> Dictionary:
	if camera == null or root == null:
		return {}
	var o := camera.project_ray_origin(pos)
	var d := camera.project_ray_normal(pos)

	# ---- phase 1: boxes ----
	var cands: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and not (n as Node3D).visible:
			continue                          # never pick what is not drawn
		if String(n.name) == HL_NODE:
			continue                          # nor our own highlight
		for c in n.get_children():
			stack.append(c)
		if not (n is GeometryInstance3D) or not (n as Node3D).is_inside_tree():
			continue
		var gi := n as GeometryInstance3D
		var gx: Transform3D = (gi as Node3D).global_transform
		# A GROUP DRAWN BY THE RENDERING SERVER. The node is a proxy: it carries
		# the mesh so every other tree walk still finds it, draws nothing (layer
		# mask 0), and keeps one transform per instance in meta. Without this
		# branch those props would be unpickable and the fault markers would
		# quietly stop working on them.
		if gi is MeshInstance3D and gi.has_meta("rs_xf"):
			var rmesh: Mesh = (gi as MeshInstance3D).mesh
			var rxf: Array = gi.get_meta("rs_xf")
			if rmesh != null and not rxf.is_empty():
				var rb: AABB = rmesh.get_aabb()
				for i in range(rxf.size()):
					var ti := _ray_box(o, d, (gx * (rxf[i] as Transform3D)) * rb)
					if ti >= 0.0:
						cands.append({"node": gi, "mesh": rmesh, "inst": i,
							"t": ti, "rs": true})
			continue
		if gi is MultiMeshInstance3D:
			var mm: MultiMesh = (gi as MultiMeshInstance3D).multimesh
			if mm == null or mm.mesh == null:
				continue
			# One box around the whole batch first. Batches are built per world
			# cell, so this rejects almost every one of them outright.
			if _ray_box(o, d, gx * _batch_box(mm)) < 0.0:
				continue
			var mb: AABB = mm.mesh.get_aabb()
			for i in range(mm.instance_count):
				var t := _ray_box(o, d, (gx * mm.get_instance_transform(i)) * mb)
				if t >= 0.0:
					cands.append({"node": gi, "mesh": mm.mesh, "inst": i, "t": t})
		elif gi is MeshInstance3D:
			var msh: Mesh = (gi as MeshInstance3D).mesh
			if msh == null:
				continue
			var t2 := _ray_box(o, d, gx * msh.get_aabb())
			if t2 >= 0.0:
				cands.append({"node": gi, "mesh": msh, "inst": -1, "t": t2})
	if hover_mode:
		# _ray_box returns exactly 0.0 only when the ray STARTS inside the
		# box, so this drops the camera-enclosing mega-meshes and nothing else.
		cands = cands.filter(func(c): return float((c as Dictionary)["t"]) > 0.0)
	if cands.is_empty():
		return {}
	cands.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))

	# ---- phase 2: triangles, nearest box first ----
	# [remaining triangles, "did we have to skip anything"]. The second entry is
	# what makes the fallback below safe.
	var budget: Array = [tri_budget, false]
	var best: Dictionary = {}
	var best_t := 1e20
	for c in cands:
		var cd: Dictionary = c
		if float(cd["t"]) > best_t:
			break                          # every remaining box is behind the hit
		if budget[0] <= 0:
			budget[1] = true
			break
		var gi2: GeometryInstance3D = cd["node"]
		var mesh: Mesh = cd["mesh"]
		if hover_mode and _tri_estimate(mesh) > HOVER_MESH_CAP:
			# Too big to test per mouse move. Marking the budget as short lets
			# the box fallback answer for it, so it still previews. Testing it
			# would also build its triangle soup, and expanding a building's
			# indices is the hitch this exists to avoid.
			budget[1] = true
			continue
		var xf: Transform3D = (gi2 as Node3D).global_transform
		if bool(cd.get("rs", false)):
			# The instance transform lives in meta for an RS-drawn group; there
			# is no MultiMesh to ask.
			var rl: Array = gi2.get_meta("rs_xf")
			xf = xf * (rl[int(cd["inst"])] as Transform3D)
		elif int(cd["inst"]) >= 0:
			xf = xf * (gi2 as MultiMeshInstance3D).multimesh \
				.get_instance_transform(int(cd["inst"]))
		var inv := xf.affine_inverse()
		# Deliberately NOT normalised: leaving the direction in the object's own
		# scale keeps t in world units, so hits on differently-scaled instances
		# stay comparable.
		var hit := _hit_mesh(mesh, inv * o, inv.basis * d, budget)
		if hit.is_empty():
			continue
		var t3 := float(hit["t"])
		if t3 < best_t:
			best_t = t3
			best = {"node": gi2, "mesh": mesh, "inst": int(cd["inst"]),
				"surf": int(hit["surf"]), "dist": t3, "point": o + d * t3}
	if best.is_empty():
		# Nothing resolved to a triangle. ONLY fall back to the nearest box when
		# something was genuinely left untested — otherwise this is a real miss
		# and must stay one. Falling back unconditionally looks harmless and is
		# not: the camera stands inside the terrain tile's box, so that box is
		# always a candidate at distance zero, and every click on empty sky would
		# come back "you picked the terrain".
		if not bool(budget[1]):
			return {}
		var c0: Dictionary = cands[0]
		best = {"node": c0["node"], "mesh": c0["mesh"], "inst": int(c0["inst"]),
			"surf": -1, "dist": float(c0["t"]), "point": o + d * float(c0["t"])}
	return best


# The box around every instance in a batch, computed once and kept.
#
# NOT MultiMesh.get_aabb(), which asks the rendering server for it. That is the
# obvious call and it is a trap: under the dummy renderer (a headless run, which
# is how this file is tested) it comes back empty, and an empty box rejects the
# whole batch, so every click silently falls through to the terrain behind it.
# Deriving it from the mesh and the instance transforms costs one pass per batch
# and gives the same answer no matter what is drawing.
static var _box_cache: Dictionary = {}

static func _batch_box(mm: MultiMesh) -> AABB:
	var key := "%d:%d" % [mm.get_instance_id(), mm.instance_count]
	if _box_cache.has(key):
		return _box_cache[key]
	var mb: AABB = mm.mesh.get_aabb()
	var out := AABB()
	for i in range(mm.instance_count):
		var b := mm.get_instance_transform(i) * mb
		out = b if i == 0 else out.merge(b)
	if _box_cache.size() > 4096:
		_box_cache.clear()
	_box_cache[key] = out
	return out


# Slab test against a world-space box. -> entry distance, or -1 on a miss.
# Returns 0 when the ray starts inside, which is what we want: the camera is
# often inside the terrain's box.
static func _ray_box(o: Vector3, d: Vector3, box: AABB) -> float:
	var tmin := -1e20
	var tmax := 1e20
	for i in range(3):
		if absf(d[i]) < 1e-9:
			if o[i] < box.position[i] or o[i] > box.end[i]:
				return -1.0
			continue
		var t1 := (box.position[i] - o[i]) / d[i]
		var t2 := (box.end[i] - o[i]) / d[i]
		tmin = maxf(tmin, minf(t1, t2))
		tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)


# Nearest triangle in one mesh, in that mesh's own space. -> {} or {t, surf}
static func _hit_mesh(mesh: Mesh, lo: Vector3, ld: Vector3, budget: Array) -> Dictionary:
	var out: Dictionary = {}
	var best := 1e20
	var soup: Array = _soup(mesh)
	var ll := ld.length_squared()
	if ll < 1e-12:
		return {}
	for s in range(soup.size()):
		var tris: PackedVector3Array = soup[s]
		var cnt := int(tris.size() / 3)
		if cnt == 0:
			continue
		if cnt > BIG_SURFACE:
			budget[1] = true               # untested: the box may have to answer
			continue
		if budget[0] <= 0:
			budget[1] = true
			break
		budget[0] -= cnt
		var i := 0
		while i < tris.size():
			var h = Geometry3D.ray_intersects_triangle(
				lo, ld, tris[i], tris[i + 1], tris[i + 2])
			if h != null:
				var t: float = ((h as Vector3) - lo).dot(ld) / ll
				if t >= 0.0 and t < best:
					best = t
					out = {"t": t, "surf": s}
			i += 3
	return out


# Per-surface triangle soup, index-expanded so the ray loop is a flat walk.
static func _soup(mesh: Mesh) -> Array:
	var id := mesh.get_instance_id()
	if _soup_cache.has(id):
		return _soup_cache[id]
	var out: Array = []
	for s in range(mesh.get_surface_count()):
		var tris := PackedVector3Array()
		var ok := true
		if mesh is ArrayMesh:
			ok = (mesh as ArrayMesh).surface_get_primitive_type(s) \
				== Mesh.PRIMITIVE_TRIANGLES
		if ok:
			var arr: Array = mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ix = arr[Mesh.ARRAY_INDEX]
			if ix == null or (ix as PackedInt32Array).is_empty():
				tris = v
			else:
				var idx: PackedInt32Array = ix
				tris.resize(idx.size())
				for k in range(idx.size()):
					tris[k] = v[idx[k]]
		out.append(tris)
	_soup_cache[id] = out
	_soup_order.append(id)
	while _soup_order.size() > SOUP_KEEP:
		_soup_cache.erase(_soup_order.pop_front())
	return out


# How many triangles a mesh carries, WITHOUT building its soup: the index
# lengths are surface metadata, so this is a handful of integer reads however
# big the mesh is. Cached because hover asks about the same meshes every move.
static var _tri_est_cache: Dictionary = {}

static func _tri_estimate(mesh: Mesh) -> int:
	var id := mesh.get_instance_id()
	if _tri_est_cache.has(id):
		return _tri_est_cache[id]
	var n := 0
	if mesh is ArrayMesh:
		var am := mesh as ArrayMesh
		for s in range(am.get_surface_count()):
			var ix := am.surface_get_array_index_len(s)
			n += int((ix if ix > 0 else am.surface_get_array_len(s)) / 3)
	else:
		# A primitive mesh is tiny; call it small rather than pay for arrays.
		n = 12 * mesh.get_surface_count()
	if _tri_est_cache.size() > 4096:
		_tri_est_cache.clear()
	_tri_est_cache[id] = n
	return n


# ---------------------------------------------------------------------------
# FOCUS: what the pick landed on, and how far Tab has drilled into it
# ---------------------------------------------------------------------------

# Build the ladder for a hit, outermost first. A MultiMesh batch has three
# rungs (batch / instance / surface); a plain MeshInstance has two, because its
# batch and its instance are the same thing and a rung that changes nothing is
# a rung that makes Tab feel broken.
static func _levels(hit: Dictionary) -> Array:
	var gi: GeometryInstance3D = hit["node"]
	var mesh: Mesh = hit["mesh"]
	var inst := int(hit["inst"])
	var lv: Array = []
	var many := inst >= 0 and gi is MultiMeshInstance3D \
		and (gi as MultiMeshInstance3D).multimesh.instance_count > 1
	if many:
		lv.append({"kind": "batch", "inst": -1, "surf": -1})
	lv.append({"kind": "object", "inst": inst, "surf": -1})
	# The surface that was actually clicked comes first, so one Tab from the
	# object lands on the part under the cursor. The rest follow in index order,
	# which turns Tab into "cycle the parts of this thing" — the way you find a
	# window you cannot manage to click.
	var order: Array = []
	var hs := int(hit["surf"])
	if hs >= 0:
		order.append(hs)
	for s in range(mesh.get_surface_count()):
		if s != hs:
			order.append(s)
	for s in order:
		lv.append({"kind": "surface", "inst": inst, "surf": int(s)})
	return lv


# Take a hit and make it the focus. -> the focus dictionary (empty on failure).
# A fresh focus is always UNCONFIRMED (light red): confirming is the click's
# job, so a hover that lands on something new cannot inherit selected status.
static func focus_on(hit: Dictionary, root: Node) -> Dictionary:
	if hit.is_empty():
		return {}
	var lv := _levels(hit)
	var idx := 0
	for i in range(lv.size()):
		if str((lv[i] as Dictionary)["kind"]) == "object":
			idx = i
			break
	_focus = {"node": hit["node"], "mesh": hit["mesh"], "inst": int(hit["inst"]),
		"levels": lv, "idx": idx, "point": hit["point"]}
	_confirmed = false
	_apply_focus(root)
	return _focus


# Hover: the light-red preview. Re-picks under the cursor as the mouse moves
# and focuses UNCONFIRMED, so Tab can cycle a thing's parts before any click.
# Two rules keep it honest:
#   - it never replaces a CONFIRMED focus (that is what confirming means), and
#   - landing on the SAME object keeps the current ladder depth, so hovering
#     in place does not undo the Tab steps just taken on it.
# The triangle budget is a fraction of a click's because this runs on mouse
# moves; the box phase still rejects almost everything before a triangle is
# ever tested. -> true when the highlight changed.
const HOVER_TRI_BUDGET := 80000
# A single mesh bigger than this is never triangle-tested on a hover: it
# previews by its bounding box instead (see pick's hover_mode). Clicks keep
# testing it properly with the full budget.
const HOVER_MESH_CAP := 40000

static func hover(camera: Camera3D, pos: Vector2, root: Node) -> bool:
	if _confirmed:
		return false
	var hit := pick(camera, pos, root, HOVER_TRI_BUDGET, true)
	if hit.is_empty():
		if _focus.is_empty():
			return false
		_drop_highlight(root)
		_focus = {}
		return true
	if has_focus() and _focus.get("node") == hit.get("node") \
			and int(_focus.get("inst", -2)) == int(hit.get("inst", -3)):
		return false
	focus_on(hit, root)
	return true


# The click that turns a hover into a selection: same focus, bright red.
static func confirm(root: Node) -> bool:
	if not has_focus():
		return false
	_confirmed = true
	_apply_focus(root)
	return true


# Escape from a confirmed selection back to hovering, keeping the focus.
static func unconfirm(root: Node) -> void:
	_confirmed = false
	if has_focus():
		_apply_focus(root)


static func is_confirmed() -> bool:
	return _confirmed and has_focus()


# ---------------------------------------------------------------------------
# HIDE / UNHIDE: get an asset out of the way of the thing behind it.
#
# Right click (or H) on the highlighted object hides it at the current focus
# level: a batch or a single object goes node-invisible, one MultiMesh
# instance is zero-scaled out of its batch (there is no per-instance
# visibility in Godot; the original transform is what gets remembered).
#
# THE RESTORE DATA LIVES IN SCENE METADATA, NOT IN THESE STATICS. A live
# plugin reload wipes every static in this file, and a zero-scaled instance
# with no record would be hidden until the next rebuild with nothing able to
# say why. Metas ride on the nodes themselves, and since everything hideable
# here is owner-less overlay, they can never be saved into the user's .tscn.
#
# OWNED NODES ARE REFUSED. Hiding writes `visible`, and on a node the scene
# owns that change would serialize into the user's file on the next save -
# the one thing this plugin must never do. Their own content hides from the
# scene tree, where the editor tracks it properly.
# ---------------------------------------------------------------------------

const HIDDEN_VIS := "hp_pick_hidden"          # meta: node hidden by pick mode
const HIDDEN_INSTS := "hp_pick_hidden_insts"  # meta: {inst: original Transform3D}

# -> the user-facing message; "" only when there is no focus to hide.
static func hide_focus(root: Node) -> String:
	if not has_focus():
		return ""
	var gi: GeometryInstance3D = _focus["node"]
	if (gi as Node).owner != null:
		return "That is your own scene content - hide it from the scene tree instead."
	var lv: Dictionary = (_focus["levels"] as Array)[int(_focus["idx"])]
	var kind := str(lv["kind"])
	var inst := int(lv["inst"])
	var what := ""
	if kind != "batch" and inst >= 0 and gi is MultiMeshInstance3D \
			and (gi as MultiMeshInstance3D).multimesh != null:
		var mm := (gi as MultiMeshInstance3D).multimesh
		var held: Dictionary = gi.get_meta(HIDDEN_INSTS) \
			if gi.has_meta(HIDDEN_INSTS) else {}
		if not held.has(inst):
			held[inst] = mm.get_instance_transform(inst)
			# Zero basis so nothing rasterises, origin dropped far below the
			# map so even a degenerate artifact cannot sit where it was.
			mm.set_instance_transform(inst,
				Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -1e5, 0)))
			gi.set_meta(HIDDEN_INSTS, held)
		what = "instance %d of %s" % [inst, String(gi.name)]
	else:
		gi.set_meta(HIDDEN_VIS, true)
		(gi as Node3D).visible = false
		what = String(gi.name)
	# The focus pointed at something that is no longer there; drop it so the
	# next hover picks whatever stood behind it.
	_drop_highlight(root)
	_focus = {}
	_confirmed = false
	return "Hidden: %s. Unhide brings everything back." % what


# Restore everything pick mode hid, by sweeping the scene for the metas -
# which also finds things hidden before a plugin reload. Returns
# {nodes, insts, gated} where gated names the invisible ancestor groups still
# keeping a restored object off screen (a switched-off layer chip).
static func unhide_all(root: Node) -> Dictionary:
	var nodes := 0
	var insts := 0
	var gated: Array = []
	if root == null:
		return {"nodes": 0, "insts": 0, "gated": gated}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.has_meta(HIDDEN_VIS):
			if n is Node3D:
				(n as Node3D).visible = true
			n.remove_meta(HIDDEN_VIS)
			nodes += 1
			_note_gate(n, gated)
		if n.has_meta(HIDDEN_INSTS) and n is MultiMeshInstance3D:
			var mm := (n as MultiMeshInstance3D).multimesh
			var held: Dictionary = n.get_meta(HIDDEN_INSTS)
			for k in held.keys():
				if mm != null and int(k) >= 0 and int(k) < mm.instance_count:
					mm.set_instance_transform(int(k), held[k])
					insts += 1
			n.remove_meta(HIDDEN_INSTS)
			_note_gate(n, gated)
	return {"nodes": nodes, "insts": insts, "gated": gated}


# The layer check: the object is restored, but is it actually ON SCREEN, or
# does a switched-off layer above it still hide it? Names the first invisible
# ancestor so the caller can point at the chip that controls it.
static func _note_gate(n: Node, gated: Array) -> void:
	var p: Node = n
	while p != null:
		if p is Node3D and not (p as Node3D).visible:
			var nm := String(p.name)
			if not gated.has(nm):
				gated.append(nm)
			return
		p = p.get_parent()


# Tab / Shift-Tab. delta +1 drills in, -1 steps out. -> true if it moved.
static func step(delta: int, root: Node) -> bool:
	if _focus.is_empty():
		return false
	var lv: Array = _focus["levels"]
	var i := int(_focus["idx"]) + delta
	if i < 0 or i >= lv.size():
		return false
	_focus["idx"] = i
	_apply_focus(root)
	return true


static func has_focus() -> bool:
	return not _focus.is_empty() and is_instance_valid(_focus.get("node"))


static func focus_node() -> Node:
	return _focus.get("node") if has_focus() else null


# Everything the object debugger needs to adopt the current focus: the
# overlay node, the shared mesh, the instance index and the focused thing's
# world transform. A copy, so the debugger cannot mutate the ladder.
static func focus_info() -> Dictionary:
	if not has_focus():
		return {}
	return {"node": _focus["node"], "mesh": _focus["mesh"],
		"inst": int(_focus["inst"]), "xform": _focus_xform()}


# Where the pick actually LANDED, in world space - the clicked point when the
# ray recorded one, else the focused instance's own origin. This is what lets
# a dropped marker sit on the ONE clicked instance instead of the middle of a
# MultiMesh batch of look-alikes.
static func focus_point() -> Vector3:
	if not has_focus():
		return Vector3.INF
	var p: Variant = _focus.get("point")
	if p is Vector3 and (p as Vector3).is_finite():
		return p
	return _focus_xform().origin


# The transform of whatever the focus currently addresses.
static func _focus_xform() -> Transform3D:
	var gi: GeometryInstance3D = _focus["node"]
	var xf: Transform3D = (gi as Node3D).global_transform
	var lv: Dictionary = (_focus["levels"] as Array)[int(_focus["idx"])]
	var inst := int(lv["inst"])
	if inst >= 0 and gi is MultiMeshInstance3D:
		xf = xf * (gi as MultiMeshInstance3D).multimesh.get_instance_transform(inst)
	return xf


# Both by reference and by name, deliberately. The reference is the normal path;
# the name sweep catches a highlight left behind by a live code reload, which
# resets every static in this file and would otherwise strand a red node in the
# scene with nothing holding it.
static func _drop_highlight(root: Node = null) -> void:
	# REMOVED FROM THE TREE FIRST, not just queue_free()d. queue_free defers to
	# the end of the frame, so the old highlight is still a child when the next
	# one is added — and Godot then renames the new node to keep names unique.
	# Everything that looks the highlight up by name gets the stale one, and one
	# Tab step appears to do nothing.
	if _hl != null and is_instance_valid(_hl):
		if _hl.get_parent() != null:
			_hl.get_parent().remove_child(_hl)
		_hl.queue_free()
	_hl = null
	var r := root
	if r == null and Engine.is_editor_hint():
		r = EditorInterface.get_edited_scene_root()
	if r == null:
		return
	for c in r.get_children():
		if String(c.name).begins_with(HL_NODE):
			r.remove_child(c)
			c.queue_free()


# Draw the focus. A separate node, not a tint, for two reasons: a tint on a
# MultiMeshInstance lights up all forty cars when you picked one, and no tint of
# any kind can address a single surface.
static func _apply_focus(root: Node) -> void:
	_drop_highlight(root)
	if not has_focus() or root == null:
		return
	var gi: GeometryInstance3D = _focus["node"]
	var mesh: Mesh = _focus["mesh"]
	var lv: Dictionary = (_focus["levels"] as Array)[int(_focus["idx"])]
	var kind := str(lv["kind"])
	var node: GeometryInstance3D = null
	if kind == "batch" and gi is MultiMeshInstance3D:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = (gi as MultiMeshInstance3D).multimesh   # shared, not copied
		node = mmi
	else:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh if int(lv["surf"]) < 0 else _one_surface(mesh, int(lv["surf"]))
		node = mi
	if node == null or (node is MeshInstance3D and (node as MeshInstance3D).mesh == null):
		return
	node.name = HL_NODE
	node.material_override = _red(_confirmed)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(node)
	node.owner = null                       # never saved into the user's scene
	_hl = node
	(node as Node3D).global_transform = (gi as Node3D).global_transform \
		if kind == "batch" else _focus_xform()


# One surface lifted out of a mesh, so the highlight can be a car's glass and
# nothing else.
static func _one_surface(mesh: Mesh, s: int) -> Mesh:
	if s < 0 or s >= mesh.get_surface_count():
		return mesh
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(s))
	return am


# ---------------------------------------------------------------------------
# LABELS AND REPORTS
# ---------------------------------------------------------------------------

# One line for the dock: what is focused and what Tab would do next.
static func focus_label(gs) -> String:
	if not has_focus():
		return "Pick mode: click any object, including original map geometry."
	var gi: GeometryInstance3D = _focus["node"]
	var mesh: Mesh = _focus["mesh"]
	var lv: Dictionary = (_focus["levels"] as Array)[int(_focus["idx"])]
	var kind := str(lv["kind"])
	var name := _mesh_name(mesh, gs)
	var total := mesh.get_surface_count()
	var body := ""
	match kind:
		"batch":
			var n := (gi as MultiMeshInstance3D).multimesh.instance_count
			body = "whole batch, %d instance(s)" % n
		"object":
			body = "one object" if int(lv["inst"]) < 0 \
				else "instance %d" % int(lv["inst"])
		_:
			body = "part %d of %d%s" % [int(lv["surf"]) + 1, total,
				_surface_tag(mesh, int(lv["surf"]), gs)]
	var depth := "  [Tab] deeper" if int(_focus["idx"]) < (_focus["levels"] as Array).size() - 1 else ""
	var up := "  [Shift+Tab] out" if int(_focus["idx"]) > 0 else ""
	var state := "PICKED " if _confirmed else ""
	var next := "  [note + Enter pins here]" if _confirmed else "  [click to confirm]"
	return "%s%s: %s%s%s%s" % [state, name, body, depth, up, next]


static func _mesh_name(mesh: Mesh, gs) -> String:
	if gs != null and gs.has_method("describe"):
		var d: Dictionary = gs.describe(mesh)
		if bool(d["found"]) and str(d["mesh"]) != "":
			return str(d["mesh"]).get_file()
	return "(mesh not built by the install reader)"


# What a surface most likely IS, named from the texture it binds — which is the
# only honest name for it, since the game does not label parts. "glass_cv" on a
# car surface is the window, and that is how you know you tabbed to the right
# part without having to read the whole report.
static func _surface_tag(mesh: Mesh, s: int, gs) -> String:
	if gs == null or not gs.has_method("describe") or s < 0:
		return ""
	var d: Dictionary = gs.describe(mesh)
	if not bool(d["found"]):
		return ""
	for sd in d["surfaces"]:
		var sr: Dictionary = sd
		if int(sr["index"]) != s:
			continue
		var slots: Dictionary = sr["slots"]
		for k in ["basecolor", "basecolor_veg"]:
			if slots.has(k):
				return "  (%s)" % str(slots[k]).get_basename()
		if not bool(sr["record"]):
			return "  (no depot record, drawn white)"
		return "  (%s)" % str(sr["state_key"])
	return ""


# The focused thing's identity as ONE line: enough to find it again in the
# game files (mesh res name, depot scope, shader state key, variation) and in
# the scene (instance index, world position). This is what a pinned note
# carries, so a complaint in a saved log names the exact object rather than
# "over there" - and a reader can take the mesh/scope/state straight to the
# install to diagnose it.
static func provenance(gs) -> String:
	if not has_focus():
		return ""
	var mesh: Mesh = _focus["mesh"]
	var lv: Dictionary = (_focus["levels"] as Array)[int(_focus["idx"])]
	var parts: Array = []
	if gs != null and gs.has_method("describe"):
		var d: Dictionary = gs.describe(mesh)
		if bool(d.get("found", false)):
			parts.append("mesh=%s" % str(d["mesh"]))
			parts.append("scope=%s" % str(d["scope"]))
			if int(d.get("variation", 0)) != 0:
				parts.append("var=%d" % int(d["variation"]))
			var s := int(lv["surf"])
			if s >= 0:
				for sd in d.get("surfaces", []):
					if int((sd as Dictionary)["index"]) == s:
						parts.append("surface=%d" % s)
						parts.append("state=%s" % str((sd as Dictionary)["state_key"]))
						break
	if parts.is_empty():
		parts.append("mesh=(not built by the install reader)")
	if int(lv["inst"]) >= 0:
		parts.append("inst=%d" % int(lv["inst"]))
	parts.append("at=%s" % str(_focus_xform().origin))
	var strs := PackedStringArray()
	for p in parts:
		strs.append(str(p))
	return " ".join(strs)


# ---------------------------------------------------------------------------
# THE ENTRY POINT.
#
# `note` is the user's own words about what is wrong. It is written at the top
# of the report so a log with several diagnoses in it still says which was
# which.
#
# Order of preference: an active pick focus (the most precise thing the user can
# point at), then a selected placed prop, then camera aim.
#
# -> a human-readable report, already emitted to the log.
# ---------------------------------------------------------------------------
static func run(root: Node, gs, mapctx, note: String) -> String:
	if root == null:
		return "Open a level scene first."
	var lines: Array = []
	lines.append("=== DIAGNOSE: %s ===" % (note if note.strip_edges() != "" else "(no note)"))

	# 0. a picked focus, if pick mode found one
	if has_focus():
		lines.append(_focus_report(gs))
		var text0 := "\n".join(PackedStringArray(lines))
		for l in lines:
			HighpolyLog.info(str(l))
		return text0

	# 1. a placed prop, if one is selected
	var placed: Array = []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is Node3D and root.is_ancestor_of(n):
			placed.append(n)
	var did := false
	for n in placed:
		var rep := _placed(n as Node3D, gs)
		if rep != "":
			lines.append(rep)
			did = true

	# 2. our overlay, aimed at rather than selected
	var meshes := _aimed(root, mapctx)
	if not meshes.is_empty():
		lines.append("\n-- original map assets under the camera aim --")
		for m in meshes:
			lines.append(_overlay_mesh(m, gs))
		did = true

	if not did:
		lines.append("Nothing of ours is selected and nothing of ours is in "
			+ "front of the camera. Turn Pick mode on and click the object, "
			+ "select a placed prop, or aim at map geometry with Original map "
			+ "objects switched on.")

	var text := "\n".join(PackedStringArray(lines))
	for l in lines:
		HighpolyLog.info(str(l))
	return text


# The report for a picked focus. Says WHERE it is and WHAT it is before the
# resolution chain, because a picked object has no name in the scene tree to
# refer to afterwards.
static func _focus_report(gs) -> String:
	var gi: GeometryInstance3D = _focus["node"]
	var mesh: Mesh = _focus["mesh"]
	var lv: Dictionary = (_focus["levels"] as Array)[int(_focus["idx"])]
	var kind := str(lv["kind"])
	var out: Array = []
	out.append("\n-- picked: %s --" % _mesh_name(mesh, gs))
	out.append("   focus level      %s" % kind)
	out.append("   overlay node     %s" % str((gi as Node).get_path()))
	out.append("   drawn as         %s" % ("MultiMesh instance %d of %d"
		% [int(lv["inst"]), (gi as MultiMeshInstance3D).multimesh.instance_count]
		if gi is MultiMeshInstance3D else "single MeshInstance3D"))
	out.append("   world position   %s" % str(_focus_xform().origin))
	out.append("   clicked point    %s" % str(_focus["point"]))
	out.append("   surfaces         %d" % mesh.get_surface_count())
	# a picked prop may be a placed one, whose library key matters too
	var owner_prop := _placed_ancestor(gi)
	if owner_prop != null:
		out.append("   part of placed prop %s (key %s)"
			% [String(owner_prop.name), HighpolyLib.match_key_public(owner_prop)])
	# the chain, narrowed to the focused surface when there is one
	if kind == "surface":
		out.append(_describe(mesh, gs, "   ", int(lv["surf"])))
	else:
		out.append(_describe(mesh, gs, "   "))
	return "\n".join(PackedStringArray(out))


# Is this overlay geometry hanging under a prop the user placed?
static func _placed_ancestor(n: Node) -> Node3D:
	var p: Node = n
	while p != null:
		if String(p.name) == HighpolyLib.HP_NODE:
			var par := p.get_parent()
			return par as Node3D if par is Node3D else null
		p = p.get_parent()
	return null


# A prop the user placed: what the library made of it.
static func _placed(node: Node3D, gs) -> String:
	var key := HighpolyLib.match_key_public(node)
	if key == "":
		return ""
	_tint(node)
	for c in node.get_children():
		_tint(c)
	var hp := node.get_node_or_null(HighpolyLib.HP_NODE)
	var out: Array = []
	out.append("\n-- placed prop: %s --" % String(node.name))
	out.append("   library key      %s" % key)
	out.append("   scene path       %s" % str(node.get_path()))
	out.append("   position         %s" % str(node.global_transform.origin))
	out.append("   overlay built    %s" % ("yes" if hp != null else "NO"))
	if hp == null:
		# The three reasons, in the order they fail, so the log says which.
		if HighpolyLib.game_source == null:
			out.append("   -> nothing has read the install yet, so the library "
				+ "has no model to offer. Switch to a High-Poly mode or turn "
				+ "Map Context on once.")
		elif not HighpolyLib.game_source.has_object(key):
			out.append("   -> the install has no pf_portal_%s prefab, so this "
				% key + "prop has no assembled model. It stays the SDK proxy.")
		else:
			out.append("   -> the game has this object but no overlay was "
				+ "built. That is a bug worth reporting.")
		return "\n".join(PackedStringArray(out))
	if hp.has_meta("hp_asset"):
		out.append("   asset id         %s" % str(hp.get_meta("hp_asset")))
	var meshes: Array = []
	_collect(hp, meshes)
	out.append("   meshes in overlay %d" % meshes.size())
	for m in meshes:
		out.append(_describe(m, gs, "   "))
	return "\n".join(PackedStringArray(out))


# Our own overlay geometry, found by where the camera is looking.
static func _aimed(root: Node, mapctx) -> Array:
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d() \
		if EditorInterface.get_editor_viewport_3d(0) != null else null
	if cam == null:
		return []
	var pt: Vector3 = cam.global_transform.origin \
		- cam.global_transform.basis.z * AIM_DIST
	var ctx := root.get_node_or_null(HighpolyMapContext.NODE)
	if ctx == null:
		return []
	var best: Array = []
	var stack: Array = [ctx]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is GeometryInstance3D):
			continue
		var gi := n as GeometryInstance3D
		var mesh: Mesh = null
		var xs: Array = []
		var gx: Transform3D = (gi as Node3D).global_transform \
			if gi.is_inside_tree() else (gi as Node3D).transform
		if gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			var mm := (gi as MultiMeshInstance3D).multimesh
			mesh = mm.mesh
			for i in range(mm.instance_count):
				xs.append(gx * mm.get_instance_transform(i))
		elif gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			mesh = (gi as MeshInstance3D).mesh
			xs.append(gx)
		if mesh == null:
			continue
		for x in xs:
			if (x as Transform3D).origin.distance_to(pt) <= AIM_RADIUS:
				_tint(gi)
				if not best.has(mesh):
					best.append(mesh)
				break
	return best


static func _overlay_mesh(m: Mesh, gs) -> String:
	return _describe(m, gs, "   ")


# `only` limits the report to one surface index — what Tab drilling produces.
static func _describe(m: Mesh, gs, ind: String, only := -1) -> String:
	var out: Array = []
	if gs == null or not gs.has_method("describe"):
		out.append("%s(no game source open, nothing to explain)" % ind)
		return "\n".join(PackedStringArray(out))
	var d: Dictionary = gs.describe(m)
	if not bool(d["found"]):
		out.append("%smesh not built by the install reader (SDK or cached "
			% ind + "geometry), so there is no resolution chain to show")
		return "\n".join(PackedStringArray(out))
	out.append("%smesh   %s" % [ind, str(d["mesh"])])
	out.append("%sscope  %s" % [ind, str(d["scope"]).get_file()])
	if int(d["variation"]) != 0:
		out.append("%svariation hash %d" % [ind, int(d["variation"])])
	for sd in d["surfaces"]:
		var s: Dictionary = sd
		if only >= 0 and int(s["index"]) != only:
			continue
		out.append("%s  surface %d  state %s  %s"
			% [ind, int(s["index"]), str(s["state_key"]), str(s["key_used"])])
		out.append("%s    depot %s, record %s, material %s"
			% [ind, str(s["depot"]) if str(s["depot"]) != "" else "MISSING",
			   "yes" if bool(s["record"]) else "NO", str(s["material"])])
		if not (s["slots"] as Dictionary).is_empty():
			var names: Array = []
			for k in (s["slots"] as Dictionary).keys():
				names.append("%s=%s" % [str(k), str((s["slots"] as Dictionary)[k])])
			names.sort()
			out.append("%s    binds %s" % [ind, ", ".join(names)])
		if (s["slots"] as Dictionary).has("alpha"):
			out.append("%s    cutout: %s, threshold %.3f"
				% [ind, "honoured" if bool(s["masked"]) else "REJECTED",
				   float(s["cut"])])
		# The colour question. Most painted props ship a neutral grey sheet and
		# take their colour from a shader constant, so the texture list alone
		# does not explain what is on screen.
		if s.has("tint"):
			out.append("%s    tint: %s" % [ind, str(s["tint"])])
		if s.has("carpaint"):
			out.append("%s    carpaint: %s" % [ind, str(s["carpaint"])])
		if str(s["note"]).strip_edges() != "":
			out.append("%s    -> %s" % [ind, str(s["note"]).strip_edges()])
	return "\n".join(PackedStringArray(out))


static func _collect(n: Node, into: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var m := (n as MeshInstance3D).mesh
		if not into.has(m):
			into.append(m)
	elif n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
		var m2 := (n as MultiMeshInstance3D).multimesh.mesh
		if m2 != null and not into.has(m2):
			into.append(m2)
	for c in n.get_children():
		_collect(c, into)
