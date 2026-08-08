@tool
extends Object
class_name HighpolyMarkers
# Problem markers: a sphere you drop where something looks wrong, with a note
# saying what is wrong, and a log section that turns each one into an answerable
# question.
#
# The point is the LOG section, not the sphere. "A wall is missing here" is not
# actionable on its own; "a wall is missing at (13.2, 61.9, -386.4), where the
# package places 56 meshes and all 56 have files on disk" is, because it says
# which of the three possible failures it is:
#
#   the package places nothing here        -> the level traversal missed it
#   it places meshes with no file on disk  -> the build or the download dropped them
#   it places meshes and the files are all present -> it is a draw-side problem
#
# Markers are ORDINARY scene nodes, deliberately, unlike everything else this
# plugin adds. The rest of the overlay is owner=null so the SDK level file stays
# byte-identical, but a marker is your content: you want to drag it to line up
# with the hole, keep it across restarts, and see it in the Scene dock. So it is
# saved with the scene like anything else you place, and "Clear markers" removes
# every one it created.

const GROUP := "_HP_MARKERS"          # parent node holding all of them
const META := "hp_note"               # note text, on the marker node
const RADIUS := 14.0                  # how far out to look for expected meshes


static func _mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.25, 0.1)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# markers are for pointing at things you cannot see, so they must be visible
	# THROUGH whatever is or is not in front of them
	m.no_depth_test = true
	m.render_priority = 8
	return m


static func group_of(root: Node, make := false) -> Node3D:
	if root == null:
		return null
	var g := root.get_node_or_null(GROUP)
	if g == null and make:
		var n := Node3D.new()
		n.name = GROUP
		root.add_child(n)
		n.owner = root          # saved with the scene: these are the user's notes
		g = n
	return g as Node3D


# Where a new marker goes: straight ahead of the 3D viewport camera. Placing it
# at the camera itself would bury it in your own viewpoint, and there is no
# depth under the cursor to snap to (map-context props carry no collision), so
# it lands at a fixed distance and you drag it the rest of the way.
static func camera_point(dist := 12.0) -> Vector3:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return Vector3.ZERO
	var t := cam.global_transform
	return t.origin - t.basis.z * dist


static func add(root: Node, note: String, pos: Vector3) -> Node3D:
	var g := group_of(root, true)
	if g == null:
		return null
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	mi.mesh = sm
	mi.material_override = _mat()
	mi.name = _node_name(note, g)
	g.add_child(mi)
	mi.owner = root
	# global_position asserts when the node is not in a tree yet, which returns
	# identity and logs an engine error rather than failing loudly. The marker
	# group hangs directly off the level root, so the local position is the world
	# one whenever the root sits at the origin (every SDK level does).
	_set_world(mi, pos)
	mi.set_meta(META, note)
	# the note floats at the marker so a screenshot of the viewport carries it
	var lb := Label3D.new()
	lb.name = "Note"
	lb.text = note
	lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lb.no_depth_test = true
	lb.modulate = Color(1.0, 0.85, 0.6)
	lb.pixel_size = 0.006
	lb.position = Vector3(0, 0.9, 0)
	mi.add_child(lb)
	lb.owner = root
	return mi


static func _node_name(note: String, g: Node) -> String:
	var base := "MARK_" + note.strip_edges().substr(0, 40)
	base = base.replace(" ", "_")
	var out := ""
	for c in base:
		out += c if (c.is_valid_identifier() or c == "_" or c.to_lower() != c.to_upper()
			or c.is_valid_int()) else "_"
	if out.strip_edges() == "" or out == "MARK_":
		out = "MARK"
	var nm := out
	var i := 2
	while g.get_node_or_null(nm) != null:
		nm = "%s_%d" % [out, i]
		i += 1
	return nm


static func _set_world(n: Node3D, pos: Vector3) -> void:
	if n.is_inside_tree():
		n.global_position = pos
	else:
		n.position = pos


static func _world_of(n: Node3D) -> Vector3:
	return n.global_position if n.is_inside_tree() else n.position


static func list(root: Node) -> Array:
	"""[{node, pos: Vector3, note: String}] in scene order."""
	var g := group_of(root)
	var out: Array = []
	if g == null:
		return out
	for c in g.get_children():
		if c is Node3D:
			out.append({
				"node": c,
				"pos": _world_of(c as Node3D),
				"note": str(c.get_meta(META, String(c.name).replace("MARK_", "")
					.replace("_", " "))),
				# WHICH OBJECT the note was pinned to, when it was pinned to one.
				# Enter in the note box records this; Drop marker leaves it empty
				# because that note is about a PLACE.
				"target": str(c.get_meta("hp_note_target", "")),
			})
	return out


static func clear(root: Node) -> int:
	var g := group_of(root)
	if g == null:
		return 0
	var n := g.get_child_count()
	g.get_parent().remove_child(g)
	g.queue_free()
	return n


# Adopt spheres someone already placed by hand (the "Missing-Coordinates" node
# of golf balls this was built to replace). Their NAME becomes the note, which
# is where that information already lived.
static func import_from(root: Node, source_name: String) -> int:
	var src := root.get_node_or_null(source_name)
	if src == null:
		return 0
	var n := 0
	for c in src.get_children():
		if c is Node3D:
			var note := String(c.name).replace("_", " ").strip_edges()
			if add(root, note, _world_of(c as Node3D)) != null:
				n += 1
	return n


# ---------- the log section ----------
static func _placements(map: String) -> Array:
	var p := "user://mapcontext/%s/placements.json" % map
	if not FileAccess.file_exists(p):
		return []
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return []
	return (d as Dictionary).get("props", [])


static func _expected(props: Array, pt: Vector3, cache_dir: String) -> Dictionary:
	"""What the package puts within RADIUS of pt, and whether we hold the files."""
	var meshes: Dictionary = {}     # name -> instances nearby
	for e in props:
		var xf: Array = e.get("xf", [])
		var near := 0
		var i := 0
		while i + 11 < xf.size():
			var v := Vector3(xf[i + 9], xf[i + 10], xf[i + 11])
			if v.distance_to(pt) <= RADIUS:
				near += 1
			i += 12
		if near > 0:
			meshes[str(e.get("mesh", ""))] = near
	var missing: Array = []
	var inst := 0
	for m in meshes:
		inst += int(meshes[m])
		if not FileAccess.file_exists("%s/%s.glb" % [cache_dir, m]):
			missing.append(m)
	return {"meshes": meshes, "missing": missing, "instances": inst}


# What the overlay has actually BUILT at this point, right now. The expected
# lookup above reads files; this reads the live scene, and the pair together
# separate "we never built it" from "we built it and it is hidden" from "it is
# built, shown, and still not where you are looking".
static func _live(root: Node, pt: Vector3) -> Dictionary:
	var ctx := root.get_node_or_null("_MAP_CONTEXT")
	if ctx == null:
		return {}
	var vis := 0
	var hid := 0
	var inst := 0
	var branches: Dictionary = {}
	var stack: Array = [ctx]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is MultiMeshInstance3D):
			continue
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh == null:
			continue
		# Test the INSTANCE transforms, not get_aabb(). The visual AABB is owned
		# by the rendering server and comes back empty when it has not drawn the
		# node yet, which silently reports "nothing is built here" for a scene
		# that is fully built. The transforms are ours and are always correct.
		var mm := mmi.multimesh
		# global_transform asserts outside the tree; the overlay's group nodes sit
		# at the origin, so the local transform is the world one either way
		var gx := mmi.global_transform if mmi.is_inside_tree() else mmi.transform
		var near := 0
		for i in range(mm.instance_count):
			if (gx * mm.get_instance_transform(i)).origin.distance_to(pt) <= RADIUS:
				near += 1
		if near == 0:
			continue
		inst += near
		# effective visibility: this node AND every ancestor up to the context
		var shown := true
		var p: Node = mmi
		while p != null and p != ctx:
			if p is Node3D and not (p as Node3D).visible:
				shown = false
				var bn := String(p.name)
				branches[bn] = int(branches.get(bn, 0)) + 1
				break
			p = p.get_parent()
		if shown:
			vis += 1
		else:
			hid += 1
	return {"visible": vis, "hidden": hid, "instances": inst, "branches": branches}


static func report(root: Node, map: String) -> String:
	var marks := list(root)
	if marks.is_empty():
		return ""
	var props := _placements(map)
	var cache := "user://mapcontext/_props"
	var out := PackedStringArray()
	out.append("")
	out.append("".rpad(60, "-"))
	out.append("PROBLEM MARKERS: %d on %s" % [marks.size(), map])
	if props.is_empty():
		out.append("(no placements.json cached for this map, so the expected-mesh")
		out.append(" lookup below is empty rather than meaningful)")
	out.append("".rpad(60, "-"))
	for m in marks:
		var pt: Vector3 = m["pos"]
		var ex := _expected(props, pt, cache)
		var meshes: Dictionary = ex["meshes"]
		var missing: Array = ex["missing"]
		out.append("")
		out.append("· %s" % m["note"])
		# The object the note is ABOUT, which is the first thing anyone reading
		# this wants and was being collected and then thrown away.
		if str(m.get("target", "")) != "":
			out.append("    on        %s" % str(m["target"]))
		out.append("    at        (%.2f, %.2f, %.2f)" % [pt.x, pt.y, pt.z])
		out.append("    expected  %d mesh(es), %d instance(s) within %.0f m"
			% [meshes.size(), int(ex["instances"]), RADIUS])
		var live := _live(root, pt)
		if live.is_empty():
			out.append("    built     no _MAP_CONTEXT in the scene (layer is off)")
		else:
			var br: Dictionary = live["branches"]
			out.append("    built     %d group(s) reach here: %d shown, %d hidden%s"
				% [int(live["visible"]) + int(live["hidden"]), int(live["visible"]),
				   int(live["hidden"]),
				   ("   hidden under %s" % str(br)) if not br.is_empty() else ""])
		if meshes.is_empty():
			out.append("    VERDICT   the package places NOTHING here: the level")
			out.append("              traversal never reached this content")
		elif not missing.is_empty():
			out.append("    VERDICT   %d of those have NO file in the prop cache:"
				% missing.size())
			for n in missing.slice(0, 8):
				out.append("                %s" % n)
			if missing.size() > 8:
				out.append("                ... and %d more" % (missing.size() - 8))
		elif live.is_empty():
			out.append("    VERDICT   data is complete, but the map objects layer")
			out.append("              is not built: turn it on and save again")
		elif int(live["visible"]) + int(live["hidden"]) == 0:
			out.append("    VERDICT   data is complete and the layer is built, but")
			out.append("              NO group was built at this spot: a builder bug")
		elif int(live["visible"]) == 0:
			out.append("    VERDICT   built here but every group is HIDDEN: culling")
			out.append("              or a parent toggle, not missing data")
		else:
			out.append("    VERDICT   built here and shown (%d groups, %d instances)."
				% [int(live["visible"]), int(live["instances"])])
			out.append("              So the data and the draw are both fine and the")
			out.append("              gap is narrower than this 14 m radius: say which")
			out.append("              OBJECT is absent and I can name its mesh")
		# the nearest few by name, so a reader can tell WHAT should be there
		var names: Array = meshes.keys()
		names.sort()
		out.append("    nearby    %s" % ", ".join(
			PackedStringArray(names.slice(0, 6))))
		if names.size() > 6:
			out.append("              ... and %d more" % (names.size() - 6))
	out.append("")
	return "\n".join(out)
