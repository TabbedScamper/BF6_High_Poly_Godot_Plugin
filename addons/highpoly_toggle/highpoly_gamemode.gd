@tool
extends Object
class_name HighpolyGamemode
# "Map variant" overlay: draws one gamemode's real gameplay layout on the map —
# capture rings, objectives, spawn clusters, zone areas, and the mode's own
# gated props (Rush barriers, Sabotage van...) — from gamemode_markers.json
# (decoded from the level's _Layers_Gameplay per-mode SubWorlds; see
# data/mined/<MAP>/gamemode_mine). Everything owner=null, editor-only.
#
# NOTE (data honesty): modes share all scenery in BF6 — these are ADDITIVE
# gameplay markers, not prop swaps. AI cover annotations (the bulk of every
# mode file) are intentionally NOT drawn.

const NODE := "_GAMEMODE"

const COLORS := {
	"capture": Color(1.0, 0.55, 0.1),
	"objective": Color(0.9, 0.15, 0.15),
	"spawn": Color(0.2, 0.85, 0.3),
	"flag": Color(1.0, 0.55, 0.1),
	"other": Color(0.7, 0.7, 0.75),
	"area": Color(1.0, 0.85, 0.2),
}

static func data_path(map: String) -> String:
	return "user://mapcontext/%s/gamemode_markers.json" % map

static func modes(map: String) -> Array:
	var p := data_path(map)
	if not FileAccess.file_exists(p):
		return []
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary) or not (d.get("modes") is Dictionary):
		return []
	return (d["modes"] as Dictionary).keys()

static func clear(root: Node) -> void:
	if root == null: return
	for c in root.get_children():
		if String(c.name).contains(NODE):   # orphan-proof (see HighpolyFx.clear)
			root.remove_child(c)
			c.queue_free()

# mapctx = the live HighpolyMapContext instance (resolves gated-prop meshes
# from the shared cache); may be null (props are skipped then).
static func apply(root: Node, map: String, mode: String, mapctx: Object = null) -> String:
	if root == null:
		return "No scene open"
	clear(root)
	if mode == "" or mode == "Off":
		return "Map variant off"
	var p := data_path(map)
	if not FileAccess.file_exists(p):
		return "No gamemode data for %s" % map
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return "gamemode_markers.json unreadable"
	var md: Dictionary = (d.get("modes", {}) as Dictionary).get(mode, {})
	if md.is_empty():
		return "No data for mode %s" % mode

	var gm := Node3D.new()
	gm.name = NODE
	root.add_child(gm)
	gm.owner = null

	var drawn := 0
	var skipped := 0
	for mk in md.get("markers", []):
		if not (mk is Dictionary): continue
		var t := str(mk.get("type", "other"))
		if t == "annotation":
			skipped += 1
			continue                     # AI cover/nav points — pure clutter
		var pos: Array = mk.get("pos", [0, 0, 0])
		var v := Vector3(pos[0], pos[1], pos[2])
		var col: Color = COLORS.get(t, COLORS["other"])
		var n := _marker_gizmo(t, col, mk)
		n.position = v
		gm.add_child(n); _unown(n)
		drawn += 1

	for ar in md.get("areas", []):
		if not (ar is Dictionary): continue
		var c: Array = ar.get("centroid", [0, 0, 0])
		var ring := _ring(maxf(float(ar.get("radius", 10.0)), 2.0), COLORS["area"], 0.35)
		ring.position = Vector3(c[0], c[1] + 1.0, c[2])
		gm.add_child(ring); _unown(ring)
		drawn += 1

	var props_ok := 0
	if mapctx != null:
		for gp in md.get("gated_props", []):
			if not (gp is Dictionary): continue
			var mesh: Mesh = mapctx._mesh_for(str(gp.get("mesh", "")))
			if mesh == null: continue
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			var b: Array = gp.get("basis", [])
			var xf := Transform3D()
			if b.size() == 3:
				xf.basis = Basis(Vector3(b[0][0], b[1][0], b[2][0]),
						Vector3(b[0][1], b[1][1], b[2][1]),
						Vector3(b[0][2], b[1][2], b[2][2]))
			var pp: Array = gp.get("pos", [0, 0, 0])
			xf.origin = Vector3(pp[0], pp[1], pp[2])
			mi.transform = xf
			gm.add_child(mi); _unown(mi)
			props_ok += 1

	return "%s: %d markers, %d zones+props (%d AI annotations hidden)" % [
		mode, drawn, props_ok, skipped]

static func _unown(n: Node) -> void:
	n.owner = null
	for c in n.get_children():
		_unown(c)

static func _marker_gizmo(t: String, col: Color, mk: Dictionary) -> Node3D:
	var g := Node3D.new()
	var r: Variant = mk.get("radius", null)
	match t:
		"capture", "flag":
			var ring := _ring(float(r) if r != null else 12.0, col, 0.8)
			g.add_child(ring)
			var pole := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.12; cm.bottom_radius = 0.12; cm.height = 9.0
			pole.mesh = cm
			pole.material_override = _mat(col)
			pole.position.y = 4.5
			g.add_child(pole)
		"objective":
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new(); bm.size = Vector3(1.6, 1.6, 1.6)
			box.mesh = bm
			box.material_override = _mat(col)
			box.position.y = 0.8
			g.add_child(box)
		"spawn":
			var s := MeshInstance3D.new()
			var sm := SphereMesh.new(); sm.radius = 0.6; sm.height = 1.2
			s.mesh = sm
			s.material_override = _mat(col)
			s.position.y = 0.8
			g.add_child(s)
		_:
			var o := MeshInstance3D.new()
			var om := SphereMesh.new(); om.radius = 0.45; om.height = 0.9
			o.mesh = om
			o.material_override = _mat(col)
			o.position.y = 0.6
			g.add_child(o)
	var lb := str(mk.get("label", "") if mk.get("label") != null else "")
	if lb != "" and t != "spawn":
		var l := Label3D.new()
		l.text = lb.replace("gem_", "").replace("_", " ").to_upper()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.font_size = 64
		l.pixel_size = 0.02
		l.modulate = col
		l.position.y = 10.5 if t in ["capture", "flag"] else 3.0
		g.add_child(l)
	return g

static func _ring(radius: float, col: Color, thickness: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = maxf(radius - thickness, 0.2)
	tm.outer_radius = radius
	mi.mesh = tm
	mi.material_override = _mat(col, 0.85)
	return mi

static func _mat(col: Color, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = false
	return m
