@tool
extends Object
class_name HighpolyGamemode
# Rebuild one of the game's own gamemodes out of REAL Portal objects.
#
# This drew coloured orbs and torus rings. It now instances the SDK's own
# scenes - CapturePoint, SpawnPoint, PolygonVolume, CombatArea, OBBVolume - at
# the positions the game ships, with the volumes carrying their actual polygons
# and the capture points wired to their spawns. What lands in the Scene dock is
# a working Portal layout you can edit, not a picture of one.
#
# OWNERSHIP IS DELIBERATE AND SPLIT.
#
# The gameplay objects are OWNED by the edited scene. Everything else this
# plugin adds is owner=null so the SDK level file stays byte-identical, and that
# is right for a preview - but this is not a preview. You asked for the modes
# rebuilt INTO Portal: you want to drag a flag, delete a spawn, keep the result
# and deploy it. So these are your content and they save with your level.
#
# The Label3D over each object is NOT owned. It is a reading aid, and a
# Label3D is not a Portal type - baking one into the level file would put a node
# the deploy validator has never seen into every save. They are rebuilt each
# time a mode is shown, which costs nothing.
#
# One node per mode, named for the mode, holding that mode's objects. Selecting
# another mode hides this one rather than destroying it, so switching back is
# instant and anything you edited is still there. If you deleted it, selecting
# it again builds it fresh from the mined data - and if that data is gone too,
# the caller re-mines from the install.

const SCHEMA := 2                     # must match HighpolyGmMine.SCHEMA
const NODE := "_GAMEMODE"             # legacy overlay name, still cleared
const META := "hp_gamemode"           # mode key, on the per-mode node
const LABELS := "_HP_LABELS"          # unowned label group inside a mode node

# Which SDK scene each mined kind becomes.
#
# A NOTE ON THE SPAWNS, because the obvious mapping is the wrong one. The game
# type is AlternateSpawnEntityData and AI_Spawner.tscn is the scene whose export
# is literally `AlternateSpawns`, so it looks like the match. It is not: in
# Portal, AlternateSpawns is an Array[SpawnPoint], so the thing the game data
# holds ONE of is a SpawnPoint, and AI_Spawner is the container that would hold
# a list of them. These entities cluster around capture points and carry a Team,
# which is what CapturePoint.InfantrySpawnPoints_TeamN is for - so each becomes
# a SpawnPoint and gets wired into the flag it belongs to.
const POLYGON := "res://addons/bf_portal/portal_tools/types/PolygonVolume/PolygonVolume.tscn"

const SCENES := {
	"capture":   "res://objects/gameplay/conquest/CapturePoint.tscn",
	"combat":    "res://objects/gameplay/common/CombatArea.tscn",
	"hq":        "res://objects/gameplay/common/HQ_PlayerSpawner.tscn",
	"objective": "res://objects/gameplay/rush/MCOM.tscn",
	"spawn":     "res://objects/entities/SpawnPoint.tscn",
	"obb":       "res://addons/bf_portal/portal_tools/types/OBBVolume/OBBVolume.tscn",
	# A ZONE IS THE POLYGON, not something holding one. Too large to be a
	# capture zone and with no combat-area entity claiming it, so what the data
	# supports is exactly a shape in a place - a sector, a deploy area, a
	# boundary. Building it as a bare PolygonVolume states that and nothing
	# more; drop a CapturePoint on it yourself if you know better.
	"zone":      POLYGON,
}

# Which export on the owning scene takes the polygon, per kind.
const AREA_PROP := {
	"capture": "CaptureArea", "combat": "CombatVolume", "hq": "HQArea",
}

const COLORS := {
	"capture": Color(1.0, 0.55, 0.1), "objective": Color(0.9, 0.15, 0.15),
	"spawn": Color(0.2, 0.85, 0.3), "combat": Color(1.0, 0.85, 0.2),
	"hq": Color(0.35, 0.7, 1.0), "zone": Color(0.55, 0.75, 0.95),
	"obb": Color(0.9, 0.15, 0.15), "other": Color(0.7, 0.7, 0.75),
}

# Modes whose one-word key does not capitalize into the name people use.
const PRETTY := {
	"teamdeathmatch": "Team Deathmatch", "kingofthehill": "King of the Hill",
	"strikepoint": "Strike Point", "battleroyale": "Battle Royale",
	"squaddeathmatch": "Squad Deathmatch", "frontline": "Frontline",
}


static func data_path(map: String) -> String:
	return "user://mapcontext/%s/gamemode_markers.json" % map


static func modes(map: String) -> Array:
	var d := _read(map)
	if d.is_empty() or int(d.get("v", 1)) < SCHEMA:
		return []
	return (d["modes"] as Dictionary).keys()


# Is there a file on disk this can actually build from? A v1 file is a list of
# origins written for the orb overlay - present, parseable, and missing every
# value a real object needs - so the miner has to treat it as absent.
static func usable(map: String) -> bool:
	var d := _read(map)
	return not d.is_empty() and int(d.get("v", 1)) >= SCHEMA


static func _read(map: String) -> Dictionary:
	var p := data_path(map)
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary) or not ((d as Dictionary).get("modes") is Dictionary):
		return {}
	return d as Dictionary


static func pretty(mode: String) -> String:
	return str(PRETTY.get(mode, mode.capitalize()))


# The data key behind whatever the dropdown is showing.
#
# The prop-layer gating downstream (set_variant_layers) treats the string it is
# given AS a layer name and matches it literally, so handing it "Team
# Deathmatch" would silently stop gating the layers that "teamdeathmatch"
# gates. Everything past the UI runs on keys; this is the one place that
# converts.
static func key_for(map: String, root: Node, mode: String) -> String:
	return _key_of(_read(map), root, mode)


# The data key for whatever spelling came in: the key itself, the shown name, or
# - when the data has been re-mined away under a node that is still in the tree
# - the mode a built node remembers.
static func _key_of(d: Dictionary, root: Node, mode: String) -> String:
	if mode == "" or mode == "Off":
		return mode
	var ms: Dictionary = d.get("modes", {}) if not d.is_empty() else {}
	if ms.has(mode):
		return mode
	for k in ms:
		if pretty(str(k)) == mode:
			return str(k)
	for k in built(root):
		if str(k) == mode or pretty(str(k)) == mode:
			return str(k)
	return mode


# ---------- the scene side ----------

# Every per-mode node in the scene, mode key -> node.
static func built(root: Node) -> Dictionary:
	var out := {}
	if root == null:
		return out
	for c in root.get_children():
		if c is Node3D and c.has_meta(META):
			out[str(c.get_meta(META))] = c
	return out


# Is this node part of a rebuilt mode?
#
# The panel reacts to every node added to the scene - it skins dragged-in props
# and, with "Show collisions" on, builds a collision overlay for anything under
# res://objects/. Building a mode adds a few hundred nodes that all match that
# test, so without this each one would be treated as a prop you had just placed
# by hand. A capture point is not scenery and has no high-poly twin to fetch.
static func in_gamemode(n: Node) -> bool:
	var p := n
	while p != null:
		if p.has_meta(META):
			return true
		p = p.get_parent()
	return false


# Hide every mode and drop the old orb overlay. Nothing you own is deleted:
# "off" means stop showing it, not throw your work away.
static func clear(root: Node) -> void:
	if root == null:
		return
	for c in root.get_children():
		if String(c.name).contains(NODE):     # the overlay this replaced
			root.remove_child(c)
			c.queue_free()
	for k in built(root):
		(built(root)[k] as Node3D).visible = false


static func apply(root: Node, map: String, mode_in: String, _mapctx: Object = null) -> String:
	if root == null:
		return "No scene open"
	for c in root.get_children():
		if String(c.name).contains(NODE):
			root.remove_child(c)
			c.queue_free()
	var d := _read(map)
	# The dropdown shows "Team Deathmatch" and the data is keyed
	# "teamdeathmatch". Resolve either spelling here, once, so every caller -
	# the dropdown, the settings snapshot that stores the shown text, the heal
	# pass - can keep passing whichever one it already has.
	var mode := _key_of(d, root, mode_in)
	var have := built(root)
	if mode == "" or mode == "Off":
		for k in have:
			(have[k] as Node3D).visible = false
		return "Map variant off"

	# Already in the tree: show it, hide the rest. Instant, and whatever you
	# changed in it is still exactly as you left it.
	for k in have:
		(have[k] as Node3D).visible = (k == mode)
	if have.has(mode):
		var n := have[mode] as Node3D
		_relabel(n, mode)
		return "%s: shown, %d object(s) already in the scene" % [
			pretty(mode), _count(n)]

	if d.is_empty():
		return "No gamemode data for %s" % map
	var md: Dictionary = (d["modes"] as Dictionary).get(mode, {})
	if md.is_empty():
		return "No data for mode %s" % mode
	if int(d.get("v", 1)) < SCHEMA:
		return "Gamemode data for %s is the old marker format - re-mine it" % map
	return _build(root, mode, (md.get("objects", []) as Array))


static func _count(n: Node) -> int:
	var c := 0
	for ch in n.get_children():
		if String(ch.name) != LABELS:
			c += 1
	return c


static func _build(root: Node, mode: String, objs: Array) -> String:
	var gm := Node3D.new()
	gm.name = _unique(root, pretty(mode).replace(" ", ""))
	root.add_child(gm)
	gm.owner = root
	gm.set_meta(META, mode)

	# capture points first: a spawn is wired into the flag it belongs to, so the
	# flags have to exist before the spawns are placed
	var caps := {}                        # label -> the CapturePoint node
	var made := 0
	var failed := {}
	for o in objs:
		if str((o as Dictionary).get("kind", "")) != "capture":
			continue
		var n := _make(gm, root, o as Dictionary, failed)
		if n != null:
			made += 1
			caps[str((o as Dictionary).get("label", ""))] = n

	for o in objs:
		var od := o as Dictionary
		var kind := str(od.get("kind", ""))
		if kind == "capture":
			continue
		var n := _make(gm, root, od, failed)
		if n == null:
			continue
		made += 1
		if kind == "spawn":
			_wire_spawn(caps, od, n)

	_relabel(gm, mode)
	var msg := "%s: %d object(s) built" % [pretty(mode), made]
	if not failed.is_empty():
		msg += "  (skipped %s)" % str(failed)
	return msg


static func _unique(root: Node, base: String) -> String:
	var nm := base
	var i := 2
	while root.get_node_or_null(nm) != null:
		nm = "%s%d" % [base, i]
		i += 1
	return nm


# One mined object -> one instanced SDK scene, placed and set up.
static func _make(gm: Node3D, root: Node, o: Dictionary, failed: Dictionary) -> Node3D:
	var kind := str(o.get("kind", ""))
	var path := str(SCENES.get(kind, ""))
	if path == "":
		failed[kind] = int(failed.get(kind, 0)) + 1
		return null
	var ps: PackedScene = load(path)
	if ps == null:
		# The scene is part of the SDK, so a miss means this project is not a
		# Portal project - say which file rather than building nothing quietly.
		failed[path.get_file()] = int(failed.get(path.get_file(), 0)) + 1
		return null
	var n := ps.instantiate() as Node3D
	if n == null:
		failed[kind] = int(failed.get(kind, 0)) + 1
		return null
	var label := str(o.get("label", kind))
	n.name = _node_name(gm, label)
	gm.add_child(n)
	n.owner = root

	var xf := _xf(o.get("xf", []))
	if o.has("points"):
		# A VOLUME'S TRANSFORM IS ITS HOLDER'S, NOT ITS OWN. VolumeVectorShapeData
		# declares no transform - it inherits none - so the walk gives it the
		# transform of whatever placed it, and the polygon it carries is in that
		# space. The thing that is actually in the world is the polygon, so put
		# the node at the polygon's own centre and give it the points relative to
		# that. PolygonVolume also requires its points to lie in the XZ plane and
		# forces its own rotation to Y only, so the points go in as world XZ.
		var pts := _world_points(o["points"] as Array, xf)
		var c := _centre(pts)
		if path == POLYGON:
			# the node IS the volume, so there is no child to wire
			_fill_polygon(n, pts, c, float(o.get("height", 0.0)), kind)
			if n.is_inside_tree():
				n.global_position = c
			else:
				n.position = c
			return n
		# global_position asserts when the node is not in a tree yet and quietly
		# returns identity; the mode node hangs off the level root, which sits at
		# the origin in every SDK level, so the local position is the world one
		# either way
		if n.is_inside_tree():
			n.global_position = c
		else:
			n.position = c
		var poly := _polygon(root, pts, c, float(o.get("height", 0.0)), kind)
		if poly != null:
			n.add_child(poly)
			poly.owner = root
			var prop := str(AREA_PROP.get(kind, ""))
			# set() on a missing property is silent, so check first: a wrong
			# name here would leave the flag with no capture area and no sign
			if prop != "" and _has_prop(n, prop):
				n.set(prop, poly)
	else:
		n.transform = xf
	if o.has("size") and _has_prop(n, "size"):
		var s: Array = o["size"]
		n.set("size", Vector3(s[0], s[1], s[2]))
		if _has_prop(n, "color"):
			n.set("color", _tint(kind))
	return n


static func _has_prop(n: Object, prop: String) -> bool:
	for p in n.get_property_list():
		if str((p as Dictionary).get("name", "")) == prop:
			return true
	return false


static func _polygon(root: Node, pts: Array, centre: Vector3, height: float,
		kind: String) -> Node3D:
	var ps: PackedScene = load(POLYGON)
	if ps == null:
		return null
	var v := ps.instantiate() as Node3D
	if v == null:
		return null
	v.name = "Area"
	_fill_polygon(v, pts, centre, height, kind)
	return v


static func _fill_polygon(v: Node3D, pts: Array, centre: Vector3, height: float,
		kind: String) -> void:
	var flat := PackedVector2Array()
	for p in pts:
		flat.append(Vector2((p as Vector3).x - centre.x, (p as Vector3).z - centre.z))
	v.set("points", flat)
	v.set("height", maxf(height, 0.0))
	v.set("color", _tint(kind))


static func _tint(kind: String) -> Color:
	var c: Color = COLORS.get(kind, COLORS["other"])
	return Color(c.r, c.g, c.b, 0.42)


static func _world_points(pts: Array, xf: Transform3D) -> Array:
	var out: Array = []
	for p in pts:
		out.append(xf * Vector3(p[0], p[1], p[2]))
	return out


static func _centre(pts: Array) -> Vector3:
	if pts.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	var lo := INF
	for p in pts:
		c += p as Vector3
		lo = minf(lo, (p as Vector3).y)
	c /= float(pts.size())
	# the polygon has to sit ON the ground, and its points are required to be
	# coplanar in XZ, so the node takes the lowest point's height
	return Vector3(c.x, lo, c.z)


static func _xf(a) -> Transform3D:
	if not (a is Array) or (a as Array).size() < 12:
		return Transform3D()
	var f: Array = a
	return Transform3D(
		Vector3(f[0], f[1], f[2]), Vector3(f[3], f[4], f[5]),
		Vector3(f[6], f[7], f[8]), Vector3(f[9], f[10], f[11]))


# Put the spawn in the flag's list for its team. The export is a typed
# Array[SpawnPoint]; reading the property back gives an array that already
# carries that type, which is why it is read-append-write rather than built
# from scratch - an untyped array assigned here is rejected at runtime.
static func _wire_spawn(caps: Dictionary, o: Dictionary, n: Node3D) -> void:
	var label := str(o.get("label", ""))
	var flag := label.replace(" Spawn", "")
	var cp = caps.get(flag)
	if cp == null:
		return
	var team := int(o.get("team", 0))
	var prop := "InfantrySpawnPoints_Team%d" % (2 if team == 2 else 1)
	if not _has_prop(cp, prop):
		return
	var arr = cp.get(prop)
	if not (arr is Array):
		return
	arr.append(n)
	cp.set(prop, arr)


static func _node_name(gm: Node, label: String) -> String:
	var base := label.replace(" ", "_")
	var out := ""
	for c in base:
		out += c if (c == "_" or c.to_lower() != c.to_upper() or c.is_valid_int()) else "_"
	if out.strip_edges() == "":
		out = "Object"
	var nm := out
	var i := 2
	while gm.get_node_or_null(nm) != null:
		nm = "%s_%d" % [out, i]
		i += 1
	return nm


# ---------- the floating names ----------
#
# "Domination: Flag A" over the flag, "Domination: Flag A Spawn" over each of
# its spawns. Not owned (see the header), so they are rebuilt whenever a mode is
# shown and never reach the level file.
static func _relabel(gm: Node3D, mode: String) -> void:
	var old := gm.get_node_or_null(LABELS)
	if old != null:
		gm.remove_child(old)
		old.queue_free()
	var host := Node3D.new()
	host.name = LABELS
	gm.add_child(host)
	host.owner = null
	var title := pretty(mode)
	for c in gm.get_children():
		if not (c is Node3D) or String(c.name) == LABELS:
			continue
		var kind := _kind_of(c as Node3D)
		var l := Label3D.new()
		l.text = "%s: %s" % [title, String(c.name).replace("_", " ")]
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.font_size = 48
		l.pixel_size = 0.012
		l.modulate = COLORS.get(kind, COLORS["other"])
		host.add_child(l)
		l.owner = null
		# a flag's name rides above its pole; a spawn's sits just over head
		# height, where it does not hide the marker it is naming
		var at := (c as Node3D).position
		l.position = at + Vector3(0, 9.0 if kind == "capture" else 2.2, 0)


static func _kind_of(n: Node3D) -> String:
	var p := String(n.scene_file_path).get_file().get_basename().to_lower()
	match p:
		"capturepoint": return "capture"
		"combatarea": return "combat"
		"hq_playerspawner": return "hq"
		"polygonvolume": return "zone"
		"mcom": return "objective"
		"spawnpoint": return "spawn"
		"obbvolume": return "obb"
	return "other"
