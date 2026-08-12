@tool
extends RefCounted

# NO class_name: this file can arrive through the staged lane, which copies
# scripts in and re-enables the plugin without a filesystem rescan, so a global
# class registered here may not resolve when the code using it parses. Callers
# do load(PATH).new().

# PROPS AS DIRECT RENDERINGSERVER INSTANCES, instead of MultiMeshes.
#
# WHY, measured at real scale (1,400 groups / 16,782 real instances):
#     rs_instances       33.30 ms/frame   22 ms build       0 nodes
#     meshinstance_nodes 36.86 ms         77 ms build  16,782 nodes
#     multimesh_cells    39.77 ms         56 ms build  18,941 nodes
# MultiMesh is the SLOWEST of the three while drawing about a seventh of the
# primitives, so the cost being paid is CPU per-object, not GPU. Draw calls are
# the wrong metric here: MultiMesh actually issues fewer of them (18,941 against
# 20,488), because this map's 2,761 distinct prop meshes share almost nothing
# that batching could exploit. A synthetic 8,000-box test said the opposite and
# was misleading; at 400 groups the three were tied, so any measurement of this
# has to be taken at scale.
#
# It is 16%, and 33.30 ms is 30 fps. This is a step toward the 16.67 ms budget,
# not a way of reaching it.
#
# THE THREE HAZARDS, all of which this file exists to contain:
#
# 1. RIDs ARE NOT REFERENCE COUNTED. Nothing frees them when the plugin
#    reloads, the scene closes or the layer is rebuilt. The map context's
#    teardown is a sweep over child NODES by name, and a direct instance is not
#    a node, so it would miss every one of them - a leak that grows with each
#    rebuild until the editor dies. free_all() is the only thing standing
#    between this design and that, so it is called from teardown, from
#    _notification, and again on the next build before anything is created.
#
# 2. THE MESH MUST STAY REFERENCED. instance_set_base takes the mesh's RID, not
#    the Mesh object, and the server does not hold the resource alive. Drop the
#    last GDScript reference and the mesh frees underneath a live instance. The
#    _meshes array exists for no other reason.
#
# 3. THEY ARE INVISIBLE TO EVERYTHING THAT WALKS THE TREE. Picking, the fault
#    markers, the census, the profiler and the cell merge all find props by
#    walking for GeometryInstance3D nodes. None of them can see these. Which is
#    why the flag that turns this on is OFF, and must stay off until the picker
#    is taught to consult groups() below - the fault-marker workflow is the main
#    way faults on this map get diagnosed and it must not be traded for 16%.

# key -> {mesh: Mesh, rids: Array[RID], visible: bool, aabb: AABB}
var _groups := {}
# Every mesh handed to us, held so hazard 2 cannot happen.
var _meshes: Array = []
var _scenario := RID()
var n_instances := 0


func set_scenario(world: World3D) -> void:
	_scenario = world.scenario if world != null else RID()


func has_scenario() -> bool:
	return _scenario.is_valid()


# One group of instances sharing a mesh. `xf` is the flat 12-float-per-instance
# layout the placement walk already produces, so nothing has to repack it.
func add_group(key: String, mesh: Mesh, xf: Array, layers: int,
		cast_shadow: bool) -> int:
	if mesh == null or not _scenario.is_valid():
		return 0
	var mrid := mesh.get_rid()
	if not mrid.is_valid():
		return 0
	_meshes.append(mesh)                       # hazard 2
	var rids: Array = []
	var xforms: Array = []
	var box := mesh.get_aabb()
	var whole := AABB()
	var count := int(xf.size() / 12)
	for i in range(count):
		var t := _xform(xf, i * 12)
		# KEPT, because picking needs them and the server will not give them
		# back - there is no exposed instance_get_transform. One Transform3D per
		# instance is under a megabyte across a whole map, which is nothing
		# beside what the props themselves cost.
		xforms.append(t)
		var rid := RenderingServer.instance_create2(mrid, _scenario)
		RenderingServer.instance_set_transform(rid, t)
		RenderingServer.instance_set_layer_mask(rid, layers)
		RenderingServer.instance_geometry_set_cast_shadows_setting(rid,
			RenderingServer.SHADOW_CASTING_SETTING_ON if cast_shadow
			else RenderingServer.SHADOW_CASTING_SETTING_OFF)
		rids.append(rid)
		var ib := t * box
		whole = ib if i == 0 else whole.merge(ib)
	n_instances += count
	var item := {"mesh": mesh, "rids": rids, "xforms": xforms, "aabb": whole}
	if _groups.has(key):
		# Same cell, another mesh: keep both, and grow the bound.
		var g: Dictionary = _groups[key]
		(g["items"] as Array).append(item)
		(g["rids"] as Array).append_array(rids)
		g["aabb"] = (g["aabb"] as AABB).merge(whole)
	else:
		_groups[key] = {"items": [item], "rids": rids, "visible": true,
			"aabb": whole}
	return count


# The proxy node for one item of a group: it carries the mesh so material
# passes, the census and the cell merge all still find what they expect, and
# draws NOTHING because its layer mask is 0. The RS instances do the drawing.
#
# This is what keeps the rest of the plugin working when props stop being
# MultiMeshes: the scene tree still describes the scene, only the drawing moved.
func make_proxy(key: String, item_index: int) -> MeshInstance3D:
	var g = _groups.get(key)
	if g == null or item_index >= (g["items"] as Array).size():
		return null
	var item: Dictionary = (g["items"] as Array)[item_index]
	var mi := MeshInstance3D.new()
	mi.name = "RSProps_%s_%d" % [key.replace(",", "_"), item_index]
	mi.mesh = item["mesh"]
	mi.layers = 0                    # drawn by the server, not by this node
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("rs_key", key)
	mi.set_meta("rs_xf", item["xforms"])
	# VISIBILITY FOLLOWS THE NODE, so every existing path that hides props -
	# the distance cull, the layer toggles, the build hiding the whole Props
	# node - hides these instances too without knowing they exist. Node3D emits
	# this for an ancestor's change as well as its own, which is what makes it
	# cover the build case.
	mi.visibility_changed.connect(func():
		_sync_visible(item, mi.is_visible_in_tree()))
	# AND SO DOES LIFETIME. This is the hazard that can kill an editor: RIDs are
	# not reference counted, and the teardown that discards props is a sweep
	# over child NODES by name - it would free this proxy and leak every
	# instance behind it, once per rebuild, forever. Freeing them here means the
	# existing teardown is correct BECAUSE it frees the proxy.
	mi.tree_exited.connect(func(): _free_item(item))
	return mi


func _sync_visible(item: Dictionary, on: bool) -> void:
	for rid in (item["rids"] as Array):
		if (rid as RID).is_valid():
			RenderingServer.instance_set_visible(rid, on)


# Frees one item's instances and empties its list, so a second call - a node
# freed twice, a teardown after a manual free - cannot double-free a RID.
func _free_item(item: Dictionary) -> void:
	var rids: Array = item["rids"]
	for rid in rids:
		if (rid as RID).is_valid():
			RenderingServer.free_rid(rid)
	n_instances -= (item["xforms"] as Array).size()
	rids.clear()


func item_count(key: String) -> int:
	var g = _groups.get(key)
	return (g["items"] as Array).size() if g is Dictionary else 0


# The cull's other half. A hidden instance costs nothing to draw but is still
# there, which is the point - this is visibility, not teardown.
func set_group_visible(key: String, on: bool) -> void:
	var g = _groups.get(key)
	if g == null or bool(g["visible"]) == on:
		return
	g["visible"] = on
	for rid in (g["rids"] as Array):
		RenderingServer.instance_set_visible(rid, on)


func group_keys() -> Array:
	return _groups.keys()


# For the picker, the census and anything else that used to walk the tree.
# Returns {meshes, rids, visible, aabb} or {} - a direct instance has no node to
# find, so this dictionary is the only way to know it exists.
func group(key: String) -> Dictionary:
	var g = _groups.get(key)
	return g if g is Dictionary else {}


# THE ONLY THING PREVENTING A LEAK. Every path that discards props has to reach
# this: the layer rebuild, the scene close, the plugin reload. RIDs outlive
# GDScript objects, so "the map context was freed" does not free them.
func free_all() -> void:
	for key in _groups.keys():
		for rid in ((_groups[key] as Dictionary)["rids"] as Array):
			if (rid as RID).is_valid():
				RenderingServer.free_rid(rid)
	_groups.clear()
	_meshes.clear()
	n_instances = 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		free_all()


# BASIS ROWS, TRANSPOSED - copied from the map context's own _xform rather than
# rewritten, because the 12 floats are basis ROWS and reading them as columns
# silently rotates every prop on the map. Two readers of one layout have to
# agree, and the way to guarantee that is to keep them identical.
static func _xform(a: Array, o: int) -> Transform3D:
	var t := Transform3D()
	t.basis.x = Vector3(a[o + 0], a[o + 3], a[o + 6])
	t.basis.y = Vector3(a[o + 1], a[o + 4], a[o + 7])
	t.basis.z = Vector3(a[o + 2], a[o + 5], a[o + 8])
	t.origin = Vector3(a[o + 9], a[o + 10], a[o + 11])
	return t
