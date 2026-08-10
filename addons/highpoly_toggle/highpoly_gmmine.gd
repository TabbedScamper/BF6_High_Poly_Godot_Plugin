@tool
extends Object
class_name HighpolyGmMine

# The gamemode miner, against the install.
#
# It produces the file highpoly_gamemode.gd rebuilds a mode from: every spawn,
# capture volume, objective box and combat area of every mode on the map, each
# with a full world transform and, for a volume, its actual polygon.
#
# THREE THINGS HAD TO BE MEASURED FIRST, and each overturned an assumption:
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
#
#    So a "capture point" in this data is a VOLUME, not a point entity, which is
#    why looking for a point found nothing.
#
# 3. FIELD NAMES CANNOT BE LOOKED UP, so fields are identified BY SHAPE. Three
#    separate tables were tried and all three are in a different hash space from
#    the one bf6_ebx.gd keys fields by:
#
#      data/ebx_typehashes.tsv                    type names only, no fields
#      research/.../DumpedTypes_*.cs              NameHashAttribute: zero of
#                                                 Members/Transform/Blueprint/
#                                                 Objects matches
#      bf6-weapon-previewer/data/fieldname_dict   same, zero matches
#
#    The type GUIDs in those dumps DO match, which is how the types above were
#    identified, and the C# dump gives each type's OWN declared fields. That is
#    enough: within one type's own fields every value we want has a distinct
#    shape, so the array-of-Vec3 is Points, the lone Vec3 is HalfExtents, the
#    lone int is Team. No hash needed, and nothing to go stale.
#
#    The offsets in those dumps are NOT usable - the two dumps disagree with
#    each other (Points at 32 in one, 40 in the other), so they are different
#    engine versions and neither can be assumed to be this one.

const OUT := "user://mapcontext/%s/gamemode_markers.json"
const SCHEMA := 2

# type GUID -> the kind of thing it is.
const TYPES := {
	"f7fbc419-e145-394f-7086-b81c1935e8ab": "spawn",       # AlternateSpawnEntityData
	"9fc7ba2d-7564-b0a6-8a9c-61f3fd93e55d": "volume",      # VolumeVectorShapeData
	"c8e55f62-8409-c039-a6bb-fbd11cb03739": "obb",         # OBBData
	"e36c4110-716c-d05f-7615-8f7b8a5d620b": "combat",      # CombatAreaEntityData
}

# Subworlds that are not a playable mode. telemetry_* is analytics volumes and
# would draw a second, wrong set of zones over the real ones.
const SKIP := ["telemetry_", "_ai", "_narrative", "generated/"]

# What a volume IS is not in the volume - VolumeVectorShapeData is the same type
# for a capture zone, a deploy area and a combat boundary. The partition that
# holds it says which, so the role comes from the name. Ordered: the first
# substring that matches wins, so "hq_combat" reads as combat, not HQ.
const ROLES := [
	["combatarea", "combat"], ["combat_", "combat"], ["playablearea", "combat"],
	["capture", "capture"], ["flag", "capture"], ["controlpoint", "capture"],
	["objective", "objective"], ["mcom", "objective"], ["bomb", "objective"],
	["hq", "hq"], ["deploy", "hq"], ["base", "hq"],
	["sector", "sector"],
]


# -> {v, modes: {name: {objects: [...]}}}, or {} when nothing mined.
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

	# Ask the walk for these types, and for every field of them, for the
	# duration of the mine - then put both back. The level walk's own result is
	# keyed on that want list and a changed one would invalidate its cache.
	var saved: Dictionary = gs.walk.want_types.duplicate()
	var saved_all: bool = gs.walk.want_all_fields
	for g in TYPES:
		gs.walk.want_types[g] = str(TYPES[g])
	gs.walk.want_all_fields = true

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
			modes[mode] = {"objects": []}
		var objs: Array = (modes[mode] as Dictionary)["objects"]
		for e in gs.walk.ents:
			var o := _object_of(e as Dictionary)
			if not o.is_empty():
				objs.append(o)

	gs.walk.want_types = saved
	gs.walk.want_all_fields = saved_all
	gs.walk.ents.clear()

	var out := {}
	for k in modes:
		var m: Dictionary = modes[k]
		if not (m["objects"] as Array).is_empty():
			out[k] = m
	if out.is_empty():
		return {}
	for k in out:
		_name_objects(k, (out[k] as Dictionary)["objects"] as Array)
	return {"v": SCHEMA, "modes": out}


# One collected entity -> one buildable object, or {} to drop it.
static func _object_of(ent: Dictionary) -> Dictionary:
	var kind := str(ent.get("tag", ""))
	if kind == "":
		return {}
	var xf = ent.get("xf")
	if not (xf is Array) or (xf as Array).size() < 4:
		return {}
	var f: Dictionary = ent.get("f", {}) if ent.get("f") is Dictionary else {}
	var src := str(ent.get("src", ""))
	var o := {"kind": kind, "src": src.get_file(), "xf": _flat(xf as Array)}

	match kind:
		"volume", "combat":
			var pts := _points_of(f)
			if pts.is_empty():
				# A combat area entity carries no polygon of its own - the shape
				# is a separate VolumeVectorShapeData beside it. Keeping the
				# entity anyway would draw a zero-size volume, so drop it and
				# let the shape it points at be the one that builds.
				return {}
			o["points"] = pts
			o["height"] = _height_of(f)
			o["kind"] = "combat" if kind == "combat" else _role_of(src)
		"obb":
			var hx := _vec3_of(f)
			# HalfExtents, so the OBBVolume size is twice it.
			o["size"] = [hx.x * 2.0, hx.y * 2.0, hx.z * 2.0]
		"spawn":
			o["team"] = _int_of(f)
	return o


# Points is the only array-of-Vec3 any of these types declares, so no name is
# needed to find it. Returned in the shape's own space; the builder puts them in
# the world with the transform beside them.
static func _points_of(f: Dictionary) -> Array:
	for h in f:
		var v = f[h]
		if not (v is Array) or (v as Array).is_empty():
			continue
		var a := v as Array
		if not (a[0] is Dictionary) or not (a[0] as Dictionary).has(BF6Walk.K_VEC_X):
			continue
		var out: Array = []
		for e in a:
			if e is Dictionary and (e as Dictionary).has(BF6Walk.K_VEC_X):
				var p: Vector3 = BF6Walk.vec_of(e)
				out.append([p.x, p.y, p.z])
		return out
	return []


# HalfExtents: the only Vec3-valued field OBBData declares (its other own field
# is the LinearTransform, which the walk already consumed as the world xf).
static func _vec3_of(f: Dictionary) -> Vector3:
	for h in f:
		if f[h] is Vector3:
			return f[h]
	return Vector3(0.5, 0.5, 0.5)


# Team: the only int AlternateSpawnEntityData declares (Priority is a float,
# Enabled a bool). Bools are ints in some decodes, so anything outside the team
# range is not it.
static func _int_of(f: Dictionary) -> int:
	for h in f:
		var v = f[h]
		if v is int and int(v) > 0 and int(v) < 128:
			return int(v)
	return 0


# THE ONE VALUE THAT CANNOT BE RESOLVED BY SHAPE ALONE. VolumeVectorShapeData
# declares Height, and the VectorShapeData it inherits from declares Tension -
# both floats, and this walk hands back fields keyed by a hash we cannot name.
#
# Tension is a curve parameter that authoring leaves at its 0.5 default, so a
# float of exactly 0.5 is discarded and a single survivor is the height. When
# that does not decide it, 0 is returned, which is PolygonVolume's own value for
# "infinite height" - the right answer for a capture zone regardless.
static func _height_of(f: Dictionary) -> float:
	var cand: Array = []
	for h in f:
		var v = f[h]
		if v is float and not is_equal_approx(float(v), 0.5):
			cand.append(float(v))
	return maxf(float(cand[0]), 0.0) if cand.size() == 1 else 0.0


static func _role_of(src: String) -> String:
	var low := src.to_lower()
	for r in ROLES:
		if low.findn(str(r[0])) >= 0:
			return str(r[1])
	return "capture"


static func _flat(m: Array) -> Array:
	var out: Array = []
	for i in range(4):
		var v: Vector3 = m[i]
		out.append_array([v.x, v.y, v.z])
	return out


# ---------- names ----------
#
# "Flag A" and "Flag A Spawn" are what a person calls these, and nothing in the
# data spells that out. What the data does give is which partition each object
# came out of, and a mode keeps one capture zone per partition - so the zones
# are lettered in a stable order and every spawn takes the letter of the zone it
# is nearest to. Sorting by position, not by walk order, keeps the letters the
# same across runs and across machines.
static func _name_objects(mode: String, objs: Array) -> void:
	var caps: Array = []
	for o in objs:
		if str((o as Dictionary).get("kind", "")) == "capture":
			caps.append(o)
	caps.sort_custom(func(a, b):
		var pa: Vector3 = _origin(a)
		var pb: Vector3 = _origin(b)
		return pa.x < pb.x if not is_equal_approx(pa.x, pb.x) else pa.z < pb.z)
	for i in range(caps.size()):
		(caps[i] as Dictionary)["label"] = "Flag %s" % _letter(i)

	var n := {}
	for o in objs:
		var d := o as Dictionary
		var kind := str(d.get("kind", ""))
		if kind == "capture":
			continue
		if kind == "spawn":
			var near = _nearest(caps, _origin(d))
			d["label"] = ("%s Spawn" % str((near as Dictionary)["label"])) \
				if near != null else "Spawn Point"
			continue
		var pretty := kind.capitalize()
		n[kind] = int(n.get(kind, 0)) + 1
		d["label"] = "%s %d" % [pretty, int(n[kind])]
	# the mode prefixes every label, so it reads "Domination: Flag A" in the
	# viewport without each label having to carry the mode itself
	for o in objs:
		(o as Dictionary)["mode"] = mode


static func _letter(i: int) -> String:
	return char("A".unicode_at(0) + i) if i < 26 else "%d" % (i + 1)


static func _origin(o) -> Vector3:
	var d := o as Dictionary
	if d.has("points"):
		# a volume's transform is its holder's; the polygon is what is in the
		# world, so its centroid is the honest position to letter and match on
		var pts: Array = d["points"]
		if not pts.is_empty():
			var c := Vector3.ZERO
			for p in pts:
				c += Vector3(p[0], p[1], p[2])
			return _apply(d["xf"], c / float(pts.size()))
	var xf: Array = d.get("xf", [])
	return Vector3(xf[9], xf[10], xf[11]) if xf.size() >= 12 else Vector3.ZERO


static func _apply(xf: Array, p: Vector3) -> Vector3:
	if xf.size() < 12:
		return p
	return Vector3(
		xf[0] * p.x + xf[3] * p.y + xf[6] * p.z + xf[9],
		xf[1] * p.x + xf[4] * p.y + xf[7] * p.z + xf[10],
		xf[2] * p.x + xf[5] * p.y + xf[8] * p.z + xf[11])


static func _nearest(caps: Array, p: Vector3):
	var best = null
	var bd := INF
	for c in caps:
		var d := _origin(c).distance_squared_to(p)
		if d < bd:
			bd = d
			best = c
	return best


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
	var by := {}
	for k in (d["modes"] as Dictionary):
		n += 1
		for o in ((d["modes"][k] as Dictionary)["objects"] as Array):
			var kd := str((o as Dictionary).get("kind", "?"))
			by[kd] = int(by.get(kd, 0)) + 1
	HighpolyLog.info("gamemode markers: %d modes, %s, written to %s"
		% [n, str(by), p.get_file()])
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
