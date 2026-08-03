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
# instance id -> [end, end_margin, fade_mode, begin, begin_margin]
# The BEGIN fields joined the record when the Low-Poly LOD handover started using
# them to gate the SDK proxy. They are serialized exactly like the end fields, so
# forgetting them would leave a proxy that never draws until you fly far enough
# away, saved into the .tscn, with the plugin off.
static var _orig: Dictionary = {}
# Nodes whose SDK proxy WE revealed for the LOD handover, so release() can put it
# back. Nothing else may hide it: apply_one() owns proxy visibility the rest of
# the time, and it hid this proxy when it built the overlay.
static var _revealed: Dictionary = {}   # node instance id -> true

static func _remember(mi: GeometryInstance3D) -> void:
	var id := mi.get_instance_id()
	if _orig.has(id): return           # first touch only: never overwrite
	_orig[id] = [mi.visibility_range_end, mi.visibility_range_end_margin,
		mi.visibility_range_fade_mode, mi.visibility_range_begin,
		mi.visibility_range_begin_margin]

static func _restore_range(mi: GeometryInstance3D) -> void:
	var id := mi.get_instance_id()
	if not _orig.has(id): return
	var o: Array = _orig[id]
	mi.visibility_range_end = float(o[0])
	mi.visibility_range_end_margin = float(o[1])
	mi.visibility_range_fade_mode = int(o[2])
	# length-tolerant: a record written before the begin fields existed restores
	# what it has rather than throwing
	if o.size() >= 5:
		mi.visibility_range_begin = float(o[3])
		mi.visibility_range_begin_margin = float(o[4])
	_orig.erase(id)

# (The collision outlines used to be followed per-camera from here: cleared as
# an object went out of range, rebuilt as it came back. That churned
# update_gizmos() across hundreds of objects every time the camera moved and
# stuttered worse than the outlines it removed. They are simply switched off
# now — see highpoly_shapeviz.gd.)

static func release(root: Node) -> void:
	var blind := 0
	if root != null:
		# Proxies revealed for the LOD handover go back under the overlay's
		# control FIRST. Left revealed, the SDK blockout and our model would both
		# be drawn once the ranges below are cleared, which reads as z-fighting.
		var pairs: Array = []
		_collect_pairs(root, pairs)
		for pair in pairs:
			_unreveal(pair[0])
		var arr: Array = []
		_collect(root, arr)
		for mi in arr:
			if _orig.has(mi.get_instance_id()):
				_restore_range(mi)
			elif mi.visibility_range_end > 0.0 or mi.visibility_range_begin > 0.0:
				# Nothing remembered. The remembered values live in a static, and
				# statics are wiped every time the script is re-parsed — which
				# happens on every plugin reload. Restoring nothing would leave
				# the scene culled with the plugin disabled, which is worse than
				# the alternative: a scene where the cull is simply off.
				mi.visibility_range_end = 0.0
				mi.visibility_range_end_margin = 0.0
				# begin included: a proxy left with begin set is INVISIBLE up
				# close, which is the more alarming of the two failures
				mi.visibility_range_begin = 0.0
				mi.visibility_range_begin_margin = 0.0
				mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
				blind += 1
	_orig.clear()
	_revealed.clear()
	if blind > 0:
		Log.warn(("Cleared the draw distance on %d object(s) without knowing what "
			+ "they started with: the plugin had been reloaded since it set them. "
			+ "If any of those shipped with their own draw distance, it is off now.")
			% blind)

static func apply(root: Node, r: float, on: bool) -> String:
	if root == null:
		return "No scene"
	var arr: Array = []
	_collect(root, arr)
	var n := 0
	for mi in arr:
		# A near-gate we have no record of is one WE set before a plugin reload:
		# nothing else in the editor writes visibility_range_begin, statics are
		# wiped on every re-parse, and the scene keeps the property. Clear it
		# before remembering, or the stale gate is recorded AS the original and
		# becomes permanent.
		#
		# This is the "prop vanishes but stays selectable" bug: the mesh is gated
		# so it cannot draw up close, while its node is still there to click.
		# Swept over EVERY mesh rather than only overlay pairs, because a proxy
		# whose overlay was freed on reload is not a pair any more and the LOD
		# pass would never reach it again.
		if not _orig.has(mi.get_instance_id()) and mi.visibility_range_begin > 0.0:
			mi.visibility_range_begin = 0.0
			mi.visibility_range_begin_margin = 0.0
		_remember(mi)                  # what it had before we touched it
		var ext: float = (mi as VisualInstance3D).get_aabb().get_longest_axis_size()
		if not on or ext > 600.0:
			# off, OR a big structural mesh (terrain / a large building you're
			# building on) — never distance-cull it, it'd vanish when you fly
			# away. Restored to what it had, NOT zeroed: an object can ship with
			# a range authored in, and zeroing would strip that from the scene.
			_restore_range(mi)
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
		n += 1
	var lod := _apply_lod(root, r, on)
	if not on:
		return "Placed objects: full range"
	if lod > 0:
		return "Placed objects optimized: %d culled at %d m · %d using the SDK model far out" \
			% [n, int(r), lod]
	return "Placed objects optimized: %d culled at %d m" % [n, int(r)]

# ---------- Low-Poly LOD handover ----------
# Near the camera, our accurate geometry. Past the handover, the SDK's own
# low-poly proxy, which is already in the scene and costs nothing to fetch: a
# free LOD1. Beyond the cull distance, nothing, exactly as before.
#
# The handover sits at HALF the object's cull distance, so the Range slider reads
# the way you would expect it to: at 400 m you get our detail out to 200 m, the
# SDK's blockout from 200 to 400, and nothing past 400. Anything beyond the range
# was already being culled, so the far half costs nothing it was not costing
# before -- it just stops being OUR expensive mesh while it is out there.
#
# Runs AFTER the flat pass on purpose. That pass has already given every mesh
# (overlay and proxy alike) end = d; this one overrides the two fields that make
# the pair hand over, so the rules compose instead of competing.
#
# Only in Low-Poly. In High-Poly the point is to look at the real models, and
# swapping them for blockouts at 40% of the range would defeat that.
static func _apply_lod(root: Node, r: float, on: bool) -> int:
	var pairs: Array = []
	_collect_pairs(root, pairs)
	var want := on and HighpolyLib.detail == HighpolyLib.Tier.LOW
	var count := 0
	for pair in pairs:
		var node: Node3D = pair[0]
		var hp: Node3D = pair[1]
		var ours: Array = []
		_collect(hp, ours)
		if ours.is_empty():
			continue
		var ext := 0.0
		for mi in ours:
			ext = maxf(ext, (mi as VisualInstance3D).get_aabb().get_longest_axis_size())
		# same exemption the flat pass uses: big structural meshes are never
		# distance-swapped, they would pop while you are building against them
		if not want or ext > 600.0:
			_unreveal(node)
			continue
		var d: float = r if ext >= 12.0 else (r * 0.6 if ext >= 3.0 else r * 0.35)
		d = maxf(d, 40.0)
		var h: float = maxf(d * 0.5, 40.0)
		if h >= d:
			# the whole visible band is inside the handover distance, so there is
			# no room for a far LOD. Leave the pair as the flat pass left it.
			_unreveal(node)
			continue
		var proxies: Array = []
		_collect_proxy(node, proxies)
		if proxies.is_empty():
			continue
		for mi in ours:
			mi.visibility_range_end = h
			mi.visibility_range_end_margin = maxf(h * 0.15, 8.0)
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		HighpolyLib._set_proxy_visible(node, true)
		_revealed[node.get_instance_id()] = true
		for mi in proxies:
			_remember(mi)
			mi.visibility_range_begin = h
			mi.visibility_range_begin_margin = maxf(h * 0.15, 8.0)
			mi.visibility_range_end = d
			mi.visibility_range_end_margin = maxf(d * 0.25, 40.0)
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		count += 1
	return count

# Put a proxy back under the overlay's control. Only touches nodes WE revealed:
# a proxy that was already visible belongs to apply_one(), which shows it when
# there is no overlay to draw instead.
static func _unreveal(node: Node3D) -> void:
	var id := node.get_instance_id()
	var known := _revealed.has(id)
	_revealed.erase(id)
	if not is_instance_valid(node): return
	# Only RE-HIDE what we know we revealed; apply_one owns proxy visibility
	# otherwise. But always clear the gate, record or not, for the reload case
	# above. Hiding without a record could hide a proxy that is legitimately the
	# only thing drawing.
	if known:
		HighpolyLib._set_proxy_visible(node, false)
	# Clear the near-gate as well as hiding it. Hidden and gated look identical
	# today, but the two are undone by different code paths -- switching to
	# High-Poly hides the proxy without touching ranges -- so a `begin` left
	# behind is a proxy that stays invisible up close the next time something
	# makes it visible. release() still restores the true original from _orig.
	var proxies: Array = []
	_collect_proxy(node, proxies)
	for mi in proxies:
		mi.visibility_range_begin = 0.0
		mi.visibility_range_begin_margin = 0.0

# node -> its live overlay, for every placed object carrying one
static func _collect_pairs(node: Node, out: Array) -> void:
	if String(node.name) in SKIP:
		return
	if node is Node3D:
		var hp := node.get_node_or_null(HighpolyLib.HP_NODE)
		if hp != null and hp is Node3D:
			out.append([node as Node3D, hp as Node3D])
	for c in node.get_children():
		if c.name != HighpolyLib.HP_NODE:
			_collect_pairs(c, out)

# The SDK proxy's own meshes: everything under `node` except our overlay and
# except content the USER parented there. Mirrors _set_proxy_visible's traversal,
# which is what decides visibility for these same meshes -- if the two walks
# disagreed, we would range-gate a mesh nothing ever makes visible.
static func _collect_proxy(node: Node3D, out: Array) -> void:
	var scene_root: Node = EditorInterface.get_edited_scene_root()
	var stack: Array = []
	for c in node.get_children():
		if c.name != HighpolyLib.HP_NODE and c.name != HighpolyLib.COL_NODE:
			stack.append(c)
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == HighpolyLib.HP_NODE or n.name == HighpolyLib.COL_NODE:
			continue
		if scene_root != null and n.owner == scene_root:
			continue                       # user content under the proxy
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		for c in n.get_children():
			stack.append(c)

static func _collect(node: Node, arr: Array) -> void:
	if String(node.name) in SKIP:
		return
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		arr.append(node)
	for c in node.get_children():
		_collect(c, arr)
