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
#   do NOT appear in the scene tree and CANNOT be selected. The only way to
#   point at one is spatially. So when the selection holds nothing of ours, this
#   falls back to whatever our overlay is drawing nearest the editor camera's
#   aim — which is the same "point at it" gesture the markers already use.
#
# The highlight is a material_overlay rather than a material swap: overlays draw
# as an extra unshaded pass and leave the real material completely alone, so a
# tagged prop still shows the bug you tagged it for.

const GROUP := "_HP_DIAGNOSE"        # meta key marking a node we tinted
const AIM_DIST := 25.0               # how far ahead of the camera to look
const AIM_RADIUS := 12.0             # and how wide

static var _tinted: Array = []       # [{node, overlay_was}]
static var _overlay: StandardMaterial3D = null


static func _red() -> StandardMaterial3D:
	if _overlay == null:
		_overlay = StandardMaterial3D.new()
		_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_overlay.albedo_color = Color(1.0, 0.1, 0.1, 0.45)
		_overlay.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Drawn on top of the thing it marks. Without this a tag on a prop
		# inside a building is invisible from outside it, which is exactly when
		# you want to find it again.
		_overlay.no_depth_test = true
		_overlay.render_priority = 20
	return _overlay


# Undo every tint. Restores the node's own material_overlay rather than
# clearing it, because a prop may legitimately have had one.
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
# THE ENTRY POINT.
#
# `note` is the user's own words about what is wrong. It is written at the top
# of the report so a log with several diagnoses in it still says which was
# which.
#
# -> a human-readable report, already emitted to the log.
# ---------------------------------------------------------------------------
static func run(root: Node, gs, mapctx, note: String) -> String:
	if root == null:
		return "Open a level scene first."
	var lines: Array = []
	lines.append("=== DIAGNOSE: %s ===" % (note if note.strip_edges() != "" else "(no note)"))

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
			+ "front of the camera. Select a placed prop, or aim at map "
			+ "geometry with Original map objects switched on.")

	var text := "\n".join(PackedStringArray(lines))
	for l in lines:
		HighpolyLog.info(str(l))
	return text


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


static func _describe(m: Mesh, gs, ind: String) -> String:
	var out: Array = []
	if gs == null or not gs.has_method("describe"):
		out.append("%s(no game source open — nothing to explain)" % ind)
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
