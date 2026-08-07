@tool
extends RefCounted
class_name HighpolyOccluders

# The map's own occluders, placed as Godot occluders.
#
# BF6 ships 867 hand-authored occluders per map — 746 OccluderPlaneEntityData
# and 121 OccluderVolumeEntityData on Dumbo — oriented quads and boxes that the
# game uses to stop drawing what is behind a building. Godot has exactly the
# same idea and the same two shapes, so this is the level designer's own
# visibility work, reused, rather than something to re-derive.
#
# THERE ARE NO OCCLUDER MESHES. The OccluderMesh res type has no level-scoped
# entries at all — all 18 in the mount are frontend/hangar assets — so anyone
# looking for meshes concludes the game ships no occlusion data. It ships
# planes and boxes, and they are in occluders.json.
#
# NO BAKE STEP IS NEEDED, which is what makes this possible at runtime:
# OccluderInstance3D.bake_scene is not script-bound, but QuadOccluder3D and
# BoxOccluder3D are plain resources that can simply be constructed.
#
# owner = null throughout, like every other layer here, so nothing is written
# into the user's scene file.
#
# MEASURED, AND IT MAKES DUMBO SLOWER. All 867 place correctly and Godot's
# occlusion culling switches on, and the recorded flight goes from a 12.1 ms
# median to 21.9 / 22.4 / 26.2 across three runs — about 1.7x worse, repeatably.
#
# The reason is that Godot rasterises its occlusion buffer on the CPU every
# frame, and after the skyline merge this map only issues ~4,375 draw calls.
# There is not enough left to cull to pay for the culling. Before that fix, at
# 49,281 draws, the trade would very likely have gone the other way — the
# skyline work made this both unnecessary and counterproductive.
#
# So the layer stays, off, for the case where a map IS heavy enough to want it
# (and as the place to start if the draw count ever climbs again). It is not
# switched on by default, and nobody should assume the game shipping occluders
# means Godot wants them.

const GROUP := "_OCCLUDERS"

# rendering/occlusion_culling/use_occlusion_culling. Occluders do nothing at all
# unless this is on, and it is off by default — which would look exactly like
# "the occluders did not help" rather than "they were never consulted".
const SETTING := "rendering/occlusion_culling/use_occlusion_culling"


static func clear(root: Node) -> void:
	if root == null:
		return
	var g := root.get_node_or_null(GROUP)
	if g != null:
		g.free()


# -> a one-line status for the dock.
static func apply(root: Node, on: bool, records: Array) -> String:
	clear(root)
	if root == null:
		return "No scene"
	if not on:
		return "Occluders off"
	if records.is_empty():
		return "No occluder data for this map"

	var was: bool = bool(ProjectSettings.get_setting(SETTING, false))
	if not was:
		# Applied rather than merely reported: the layer is useless without it,
		# and a user who switched it on would otherwise see no change and
		# reasonably conclude the feature does nothing.
		ProjectSettings.set_setting(SETTING, true)

	var g := Node3D.new()
	g.name = GROUP
	root.add_child(g)
	g.owner = null

	var quads := 0
	var boxes := 0
	var skipped := 0
	for r in records:
		var rec := r as Dictionary
		if rec == null:
			continue
		var size: Array = rec.get("size", [])
		var pos: Array = rec.get("pos", [])
		var bas: Array = rec.get("basis", [])
		if size.size() < 3 or pos.size() < 3 or bas.size() < 9:
			skipped += 1
			continue
		# A degenerate occluder occludes nothing and still costs a node.
		if float(size[0]) < 0.5 or float(size[1]) < 0.5:
			skipped += 1
			continue

		var inst := OccluderInstance3D.new()
		var kind := str(rec.get("kind", "quad"))
		if kind == "box":
			var b := BoxOccluder3D.new()
			b.size = Vector3(float(size[0]), float(size[1]), float(size[2]))
			inst.occluder = b
			boxes += 1
		else:
			var q := QuadOccluder3D.new()
			q.size = Vector2(float(size[0]), float(size[1]))
			inst.occluder = q
			quads += 1
		# Nine floats, column-major, exactly as recorded. Authored orientations
		# go through no euler round trip here: a plane a degree off no longer
		# lies flat against the wall it was placed on, and at these sizes that
		# opens a gap the renderer can see through.
		inst.transform = Transform3D(
				Basis(Vector3(bas[0], bas[1], bas[2]),
					  Vector3(bas[3], bas[4], bas[5]),
					  Vector3(bas[6], bas[7], bas[8])),
				Vector3(pos[0], pos[1], pos[2]))
		g.add_child(inst)
		inst.owner = null

	return "Occluders: %d quad, %d box%s%s" % [
		quads, boxes,
		", %d skipped" % skipped if skipped > 0 else "",
		"  (occlusion culling switched on)" if not was else ""]


static func count(root: Node) -> int:
	var g := root.get_node_or_null(GROUP) if root != null else null
	return g.get_child_count() if g != null else 0
