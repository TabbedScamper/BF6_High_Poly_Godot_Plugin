@tool
extends Object
class_name HighpolyGmMine

# The gamemode marker miner, against the install.
#
# highpoly_gamemode.gd draws capture rings, objective boxes, spawn spheres and
# zone areas and has been complete the whole time. It reads
# gamemode_markers.json, produced by a miner that no longer exists (task #37).
# This rebuilds that file from the game rather than from a lost pipeline.
#
# TWO THINGS HAD TO BE MEASURED FIRST, and both overturned an assumption:
#
# 1. THE DEFAULT WALK NEVER VISITS THE MODE SUBWORLDS. Walking the level reaches
#    38,226 placements and none of a mode's gameplay entities. Walking
#    _layers_gameplay/<mode> AS A ROOT reaches them - 2,701 entities across the
#    modes on MP_Aftermath, against 0 from the level walk.
#
# 2. CapturePointEntityData IS NOT WHAT CONQUEST PLACES. Its type GUID collects
#    exactly zero, from the level walk and from the mode roots alike. Dumping
#    every instance type in the 25 conquest partitions and naming them through
#    the research tables gives what is actually there:
#
#      AlternateSpawnEntityData          137   the spawns
#      VolumeVectorShapeData               8   objective volumes
#      OBBData                             2   oriented bounding boxes
#      SpatialPrefabReferenceObjectData   60   the mode's own props
#      MeshMaterialVariation            2034   materials, not gameplay
#
#    Measured over every mode: 1,160 spawns, 259 volume shapes, 160 OBBs and 6
#    combat areas, each with a composed world transform.
#
# So a "capture point" in this data is a VOLUME, not a point entity, which is
# why looking for a point found nothing.

const OUT := "user://mapcontext/%s/gamemode_markers.json"

# type GUID -> what to draw. The renderer's own vocabulary: spawn, objective,
# capture, area.
const TYPES := {
	"f7fbc419-e145-394f-7086-b81c1935e8ab": "spawn",       # AlternateSpawnEntityData
	"9fc7ba2d-7564-b0a6-8a9c-61f3fd93e55d": "capture",     # VolumeVectorShapeData
	"c8e55f62-8409-c039-a6bb-fbd11cb03739": "objective",   # OBBData
	"e36c4110-716c-d05f-7615-8f7b8a5d620b": "area",        # CombatAreaEntityData
}

# Subworlds that are not a playable mode. telemetry_* is analytics volumes and
# would draw a second, wrong set of rings over the real ones.
const SKIP := ["telemetry_", "_ai", "_narrative", "generated/"]


# -> {modes: {name: {markers: [...], areas: [...]}}}, or {} when nothing mined.
static func mine(gs, level: String) -> Dictionary:
	if gs == null or gs.walk == null:
		return {}
	var pre := "%s/_layers_gameplay/" % _level_dir(gs, level)
	if pre == "/_layers_gameplay/":
		return {}
	var roots: Array = []
	for k in gs.src.ebx.keys():
		var s := str(k)
		if not s.begins_with(pre):
			continue
		var tail := s.substr(pre.length())
		var skip := false
		for bad in SKIP:
			if tail.findn(bad) >= 0:
				skip = true
				break
		if not skip:
			roots.append(s)
	roots.sort()
	# Ask the walk for these types for the duration of the mine, then put its
	# want list back: the level walk's own result is keyed on that list and a
	# changed one would invalidate its cache.
	var saved: Dictionary = gs.walk.want_types.duplicate()
	for g in TYPES:
		gs.walk.want_types[g] = str(TYPES[g])
	var modes := {}
	for r in roots:
		var mode := _mode_of(r.substr(pre.length()))
		if mode == "":
			continue
		var ref = gs.walk.resolve_name(r)
		if ref == null:
			continue
		gs.walk.ents.clear()
		gs.walk.walk(ref, BF6Walk.IDENT, {}, 0)
		if gs.walk.ents.is_empty():
			continue
		if not modes.has(mode):
			modes[mode] = {"markers": [], "areas": []}
		var m: Dictionary = modes[mode]
		for e in gs.walk.ents:
			var ent: Dictionary = e
			var kind := str(TYPES.get(str(ent.get("type", "")), ""))
			if kind == "":
				continue                      # a light, or a type we do not draw
			var p = _origin_of(ent)
			if p == null:
				continue
			var v: Vector3 = p
			if kind == "area":
				(m["areas"] as Array).append({
					"centroid": [v.x, v.y, v.z], "radius": 25.0})
			else:
				(m["markers"] as Array).append({
					"type": kind, "pos": [v.x, v.y, v.z], "label": ""})
	gs.walk.want_types = saved
	gs.walk.ents.clear()
	var out := {}
	for k in modes:
		var m: Dictionary = modes[k]
		if (m["markers"] as Array).is_empty() and (m["areas"] as Array).is_empty():
			continue
		out[k] = m
	return {} if out.is_empty() else {"modes": out}


# Write it where HighpolyGamemode.data_path expects. Returns how many modes.
static func mine_to_disk(gs, level: String, map: String) -> int:
	var d := mine(gs, level)
	if d.is_empty():
		return 0
	var p: String = OUT % map
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		HighpolyLog.warn("gamemode markers: could not write %s" % p)
		return 0
	f.store_string(JSON.stringify(d))
	f.close()
	var n := 0
	var mk := 0
	for k in (d["modes"] as Dictionary):
		n += 1
		mk += ((d["modes"][k] as Dictionary)["markers"] as Array).size()
		mk += ((d["modes"][k] as Dictionary)["areas"] as Array).size()
	HighpolyLog.info("gamemode markers: %d modes, %d markers, written to %s"
		% [n, mk, p.get_file()])
	return n


# The level's partition directory, from a resource the mount already has.
static func _level_dir(gs, level: String) -> String:
	var want := "/levels/%s/" % level.to_lower()
	for k in gs.src.ebx.keys():
		var s := str(k)
		var at := s.findn(want)
		if at >= 0:
			return s.substr(0, at + want.length() - 1)
	return ""


# "conquest/conquest" and "conquest/conquest0" are one mode; "winter_domination"
# is its own. The trailing digit is a variant of the same subworld, not a
# separate mode, and folding them keeps one entry per thing a user can pick.
static func _mode_of(tail: String) -> String:
	var first := tail.get_slice("/", 0)
	if first == "":
		return ""
	while first.length() > 1 and first[first.length() - 1].is_valid_int():
		first = first.substr(0, first.length() - 1)
	return first


# An entity's world position, from whichever transform the walk composed onto
# it. Returns null when it carries none - an entity with no placement is not a
# marker.
static func _origin_of(ent: Dictionary):
	for k in ["xf", "world", "transform"]:
		var v = ent.get(k)
		if v is Array and (v as Array).size() >= 4 and (v as Array)[3] is Vector3:
			return (v as Array)[3]
		if v is Array and (v as Array).size() >= 12:
			return Vector3(v[9], v[10], v[11])
	var p = ent.get("pos")
	if p is Vector3:
		return p
	return null
