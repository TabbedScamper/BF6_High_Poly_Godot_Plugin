@tool
extends RefCounted
class_name BF6Walk

# The level placement walk, in GDScript, reading the player's own install.
#
# This is the last piece between the plugin and the game. bf6_source turns an
# install into named assets, bf6_ebx turns an asset into instances, bf6_meshset
# and bf6_texture turn a resource into a mesh and an image — and this says WHICH
# mesh goes WHERE. Until now that answer came from placements.json, shipped in a
# download beside 6.6 GB of extracted geometry and textures. It does not have to.
#
# Ported from tools/walk_level.py, which is proven: it produces the 2,761 prop
# placements the packaged Dumbo build is made of, and four miners (occluders,
# lights, water, decals) subclass it. Every hard-won correction in that file is
# carried over here rather than rediscovered, and each one is commented where it
# lands, because all of them were silent failures that looked like working code.
#
# The traversal (MAP_LOADING 6.5), role-driven rather than heuristic:
#
#     level root -> Objects
#                -> subworld reference (BundleName names the subworld asset:
#                   the one point where the graph depends on the catalogue
#                   rather than on PointerRefs)
#                -> layers -> prefabs -> StaticModelGroups
#
# and worldTransform = parentTransform * localTransform composes at exactly one
# place, a placement's BlueprintTransform. Column-basis, parent on the left.

const IDENT: Array = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(0, 0, 0)]

# ---- roles (MAP_LOADING 6.1) ----
const LEVEL_ROOT := "cb061cf4-33fa-1cd8-9141-58775a0185ef"
const SUBWORLD := {
	"3df930ad-14d3-3e01-ddab-1a00db057512": true,
	"ed4cdd26-d851-1f81-f9ab-7de7cf169895": true,
	"0fecf1ad-ca05-c320-dfc7-29f971a5cdee": true,
}
const LAYER := "0fbe0ea1-e9a1-ab07-9b80-84e6e894a792"
const SMG_TYPE := "2e5723ed-effe-ff86-2c68-26573e1011a6"
const SPATIAL_PREFAB := "fc194913-9d82-6611-507c-3345a01b1a05"
const PREFAB := "95b26088-8ba2-4b04-b5e5-bf50499f8777"
const SUBWORLD_REF := "53a303b0-6696-5565-b274-3a25591f19b5"

# ---- fields ----
const F_OBJECTS := 0x5A6115B2
const F_DATAREFS := 0xCDA4739B
const F_SUBWORLD_COMPONENTS := 0x5E00055A
const F_BUNDLENAME := 0x095E926D
const F_BP_TRANSFORM := 0x7B554EF5
const F_BLUEPRINT := 0x6B831B88
const F_EXCLUDED := 0x4CD269A8
const F_SMG_MEMBERS := 0xA43BD992
const F_SMG_XFORMS := 0xEBF4D386
# MEASURED, not taken from the spec's naming. The type DB calls 0x1B4A547C
# `MeshAsset` and 0xB608BEEE `MemberType`, but on retail mp_dumbo it is
# 0xB608BEEE that carries the blueprint path while 0x1B4A547C is present and
# null on every member sampled. Read the measured one first, fall back to the
# spec one, and the walk is right under either naming.
const F_SMG_BLUEPRINT := 0xB608BEEE
const F_SMG_MESHASSET := 0x1B4A547C
const F_SMG_ENABLED := 0xFB410D18
const F_SMG_VISIBLE := 0x8F8D9F78
const F_SMG_OBJVAR := 0xE2FFCC45      # InstanceObjectVariation, PER INSTANCE

# LinearTransform members, in the order the exe's own type info declares them
# (offsets 0/16/32/48 of a 64-byte struct, four Vec3s padded to Vec4).
# ADDRESSED BY NAME HASH, NEVER BY SORTED ORDER: sorting these hashes
# numerically yields forward, trans, up, right, which silently transposed every
# placement in the map into a matrix whose "basis" held a translation.
const F_LT_RIGHT := 0xC478CC3B        # offset 0
const F_LT_UP := 0xBF151EF9           # offset 16
const F_LT_FORWARD := 0x695D12A4      # offset 32
const F_LT_TRANS := 0xBC4B07B4        # offset 48
const LT_MEMBERS: Array = [F_LT_RIGHT, F_LT_UP, F_LT_FORWARD, F_LT_TRANS]

# ---------------------------------------------------------------------------
# WHERE A LIGHT FIXTURE'S PLACEMENT ACTUALLY LIVES.
#
# A *LightEntityData carries its own `Transform` (0xD6351EDE), and reading that
# instead of `BlueprintTransform` is already the difference between a fixture at
# its holder's origin and one in the right place. It is not enough, and the
# measurement says so: on mp_dumbo 6,848 of 7,878 collected lights (86.9%) have
# an IDENTITY `Transform`, so they land exactly on their holder's origin anyway.
# That is the "light at the base of the lamp post" symptom, quantified.
#
# The reason is the authoring model. Light fixtures ship as ObjectBlueprints
# (bf455610-...), and in one the light entity is not a placed object at all: it
# is reachable only through the blueprint's PropertyConnections and its own
# Transform is left identity. The placement sits on a SEPARATE component in the
# owning object's `Components` array, and that component points BACK at the
# light through field 0x11F57ECA — typed as an integer by the reflection tables
# and holding an ordinary internal PointerRef (see BF6Ebx.int_pointer).
#
# lf_com_streetlight_02 is the clean example. The PbrSpotLightEntityData sits at
# identity; its component sits at (3.890, 9.923, -0.002) — 9.9 m up the pole and
# 3.9 m out along the arm, which is the lamp head — and aims down. Reading the
# entity alone puts a street lamp's light on the pavement at the foot of its own
# pole, and it looks plausible enough on a map to survive.
#
# The join is exact rather than positional: measured on mp_dumbo every component
# resolves to one light entity and every light in an ObjectBlueprint fixture is
# resolved by exactly one component, so nothing is paired by order or by guess.
const LIGHT_XF_COMPONENT := "dcac04fc-2a7a-e798-1382-328a95b9484a"
const F_COMPONENT_LIGHT := 0x11F57ECA
const F_TRANSFORM := 0xD6351EDE

const LT_GUID := "06ce1d10-9a4e-fc64-2a9f-a9d482576ffa"
const K_VEC_X := 956422932
const K_VEC_Y := 1123815262
const K_VEC_Z := 849976220

# Dev and marketing subworlds (MAP_LOADING 6.4). 'glacierflow/' is ours and is a
# CONTENT choice rather than a correctness one: a level genuinely references the
# frontend flow scenes — mp_dumbo's graph names Flow_PauseMenu and PauseMenu as
# subworlds — so the engine really does mount the pause menu alongside the map.
# Expanding them adds 178 rows of soldier-customization hangar parked at
# y = -738, below the playable map. That is menu furniture, not map geometry.
const SKIP_SUBWORLD: Array = ["_autotests", "_tools", "marketing", "glacierflow/"]

# Destruction STATE-BRANCH types (DESTRUCTION.md 8). Walking THROUGH one of
# these puts the branch in destruction state, so everything below it is an
# alternate or an effect and never the intact mesh.
#
# We used to walk straight through them, and it cost geometry twice over.
# lf_com_streetlight_02 is the clean example: its only Blueprint references are
# four destruction effects and one transition spawn (the wreck). So the walk
# emitted the destroyed twin and the break effects as scenery — and because
# those rows made the target look productive, the leaf fallback that would have
# emitted the intact PREFAB never fired. The 1,406-triangle street light was
# never placed at all, 395 times.
const DESTRUCTION_BRANCH := {
	"464ab605-1fb8-3d21-202f-f3feb43dffb9": true,  # DestructionEffectReferenceObjectData
	"591bcc82-5380-7cbd-543e-faabbc873c09": true,  # ...Template
	"ef0c40ad-226b-f6fe-04dd-7b26c26350a2": true,  # DestructionTransitionSpawnReferenceObjectData
	"96e64a4c-c7e1-644c-dedb-499e51d965c2": true,  # ...Template
	"570f0b4f-fcd0-d977-580e-d409f464c6f1": true,  # DestructionProcess
	"e788769d-af38-c1e6-d413-10cffb99e5f8": true,  # DestructionProcessData
	"643b508d-7f3e-af14-3022-033b9ced8d79": true,  # Class_0a6b45b4
	"b3120863-e2a0-5eb4-4523-a3f4dc814e20": true,  # Class_a8cf23c0
	"a0e4f0a2-5007-928a-20de-1f613062529c": true,  # EdgeModelsBaseData
	"0f86bea6-d792-51ab-8d91-b724ea871296": true,  # EdgeModelsData
}

const MAX_DEPTH := 24

var src: BF6Source = null
var types = null                       # bf6_types.gd reader
var rows: Array = []                   # [{mesh, xf, src, kind, var}]
var stats := {}

# ---------------------------------------------------------------------------
# ENTITIES THE CALLER WANTS, collected on the same pass.
#
# Lights, and anything else that is placed rather than drawn, live at leaves of
# exactly this traversal — a light inherits the composed world transform of
# whichever prefab or layer holds it, so mining it means walking the level. The
# Python does that by SUBCLASSING the walker (lights_mine, occluders_mine,
# water_mine and decals_mine all do), which works there and would be a poor fit
# here: four subclasses means four walks, and one walk of mp_dumbo is 50 s.
#
# So the walk collects instead. `want_types` maps a type guid to a tag, and
# every matching instance is recorded with its world transform and the fields in
# `want_fields`. Nothing is collected unless a caller asks, so a plain placement
# walk behaves exactly as it did.
#
# TYPE GUIDS COME IN PAIRS in the SDK tables — two spellings of the same type,
# one of them byte-swapped in the first three groups. Register both; which one a
# given EBX uses is not something to guess at.
var want_types := {}                   # dashed type guid -> tag
var want_fields: Array = []            # field name hashes to keep
# Keep EVERY field of a collected entity instead of the `want_fields` list.
#
# For lights the list is right: the caller knows it wants Colour and Intensity
# and naming them keeps 3,874 records small. The gamemode miner cannot use it,
# because the fields it needs — a polygon's Points, an OBB's HalfExtents — have
# no known name hash. The C# type dump in the research corpus names them by
# NameHashAttribute, and NOT ONE of those values matches the hashes this walk
# already uses (checked against Members, Transform, Blueprint and Objects: zero
# overlap), so that table cannot supply them either. The type GUIDs in the same
# dump DO match, which is how the types were identified in the first place.
#
# So the miner identifies fields by SHAPE — the array of Vec3 is the polygon,
# the lone Vec3 is the half-extents — and that needs the fields present. Off by
# default; a placement walk is untouched.
var want_all_fields := false
var ents: Array = []                   # [{tag, type, xf, f: {hash: value}}]
var _want_hex := {}                    # type guid hex -> tag, resolved lazily
var by_name := {}                      # lowercased asset name -> "<name>.ebx"
var gi := {}                           # partition guid -> "<name>.ebx"


func _init(source: BF6Source = null, types_reader = null) -> void:
	src = source
	types = types_reader


func _bump(k: String, n := 1) -> void:
	stats[k] = int(stats.get(k, 0)) + n


# ---------------------------------------------------------------------------
# maths
# ---------------------------------------------------------------------------
# A transform here is FOUR Vector3s — three basis rows then the translation —
# not a Transform3D. Godot's Basis is orthonormal-friendly and its operators
# assume a column convention; these matrices are the game's, row-basis, and
# frequently non-uniform. Keeping them as plain rows means the composition below
# is the spec's formula written out, with nothing to misread.
static func vec_of(d) -> Vector3:
	if not (d is Dictionary):
		return Vector3.ZERO
	return Vector3(float(d.get(K_VEC_X, 0.0)), float(d.get(K_VEC_Y, 0.0)),
			float(d.get(K_VEC_Z, 0.0)))


static func is_lt(v) -> bool:
	return v is Dictionary and str((v as Dictionary).get("__type", "")) == LT_GUID


# The inverse of BF6Types.guid_str, so a guid constant written the way the rest
# of this file writes them can still be compared against raw type bytes without
# formatting a string per instance.
static func raw_guid(s: String) -> PackedByteArray:
	var h := s.replace("-", "")
	var out := PackedByteArray()
	if h.length() != 32:
		return out
	out.resize(16)
	out.encode_u32(0, h.substr(0, 8).hex_to_int())
	out.encode_u16(4, h.substr(8, 4).hex_to_int())
	out.encode_u16(6, h.substr(12, 4).hex_to_int())
	for i in range(8):
		out[8 + i] = h.substr(16 + i * 2, 2).hex_to_int()
	return out


static func lt_to_mat(t) -> Array:
	if not (t is Dictionary):
		return IDENT
	var out: Array = []
	for k in LT_MEMBERS:
		if not (t as Dictionary).has(k):
			return IDENT
		out.append(vec_of((t as Dictionary)[k]))
	return out


# a * b, column-basis: rows 0..2 are the basis, row 3 the translation.
static func matmul(a: Array, b: Array) -> Array:
	var out: Array = []
	for i in range(3):
		var r: Vector3 = b[i]
		out.append(Vector3(
			r.x * (a[0] as Vector3).x + r.y * (a[1] as Vector3).x + r.z * (a[2] as Vector3).x,
			r.x * (a[0] as Vector3).y + r.y * (a[1] as Vector3).y + r.z * (a[2] as Vector3).y,
			r.x * (a[0] as Vector3).z + r.y * (a[1] as Vector3).z + r.z * (a[2] as Vector3).z))
	var t: Vector3 = b[3]
	out.append(Vector3(
		t.x * (a[0] as Vector3).x + t.y * (a[1] as Vector3).x + t.z * (a[2] as Vector3).x + (a[3] as Vector3).x,
		t.x * (a[0] as Vector3).y + t.y * (a[1] as Vector3).y + t.z * (a[2] as Vector3).y + (a[3] as Vector3).y,
		t.x * (a[0] as Vector3).z + t.y * (a[1] as Vector3).z + t.z * (a[2] as Vector3).z + (a[3] as Vector3).z))
	return out


# ---------------------------------------------------------------------------
# THE PACKED-BOOL UNPACK, and why an array of `true` was reading as garbage.
#
# InstanceEnabled and Visible are FLAT BYTE arrays (DESTRUCTION.md 6.1), but the
# exe's reflection tables carry no element type for an array of a primitive: the
# field's flags say category=Array/type=Array for every array alike, and elemVA
# is 0. With nothing to dispatch on, the deserializer falls back to a 4-byte
# stride, so element i is read from elem + i*4 and the read runs four times past
# the end of the array.
#
# The damage was invisible rather than loud. Measured on mp_dumbo, Visible came
# back as [16843009, ...] — 0x01010101, four `true` bytes packed into one int —
# followed by whatever bytes followed the array, and 5,762 SMG instances were
# judged not-visible from that garbage and dropped. Building facades were among
# them, which is how rooms ended up with their windows and fittings but no walls.
#
# The count in the array header IS correct, so the first ceil(n/4) values hold
# all n real bytes. Unpack them back.
static func flat_bools(arr) -> Array:
	if not (arr is Array) or (arr as Array).is_empty():
		return arr if arr is Array else []
	var a: Array = arr
	var n := a.size()
	var all_bool := true
	for v in a:
		if typeof(v) != TYPE_BOOL:
			all_bool = false
			break
	if all_bool:
		return a                        # already decoded correctly
	var out: Array = []
	for i in range(int((n + 3) / 4)):
		var v = a[i]
		if typeof(v) != TYPE_INT:
			return a                    # not the packed form; leave it alone
		for k in range(4):
			out.append(bool((int(v) >> (8 * k)) & 0xFF))
	return out.slice(0, n)


# ---------------------------------------------------------------------------
# catalogue
# ---------------------------------------------------------------------------
# Asset name -> ebx ref, for the BundleName bridge, plus the partition index the
# import resolution needs. Both come straight out of the mount, so nothing here
# depends on a dump or a shipped tsv.
func build_catalog(progress := Callable()) -> void:
	by_name.clear()
	# Snapshot: iterating the live member races the catalogue republish.
	var t_ebx: Dictionary = src.snap_ebx()
	for name in t_ebx.keys():
		var n := str(name)
		var ref := n + ".ebx"
		var low := n.to_lower()
		# Keys lowercased because resolve_name lowercases its query; the ref
		# keeps the true name so the read is exact.
		if not by_name.has(low):
			by_name[low] = ref
		var leaf := low.get_file()
		if not by_name.has(leaf):
			by_name[leaf] = ref
	gi = src.partition_index(progress)
	stats["catalog"] = by_name.size()
	stats["guid_index"] = gi.size()


func resolve_name(name: String):
	if name == "":
		return null
	var n := name.replace("\\", "/").to_lower()
	if by_name.has(n):
		return by_name[n]
	var leaf := n.get_file()
	if by_name.has(leaf):
		return by_name[leaf]
	if by_name.has(n + ".ebx"):
		return by_name[n + ".ebx"]
	return null


func open_ebx(ref: String):
	var nm := ref
	if nm.to_lower().ends_with(".ebx"):
		nm = nm.substr(0, nm.length() - 4)
	var tr := Time.get_ticks_usec()
	var data := src.get_ebx(nm)
	t_read += Time.get_ticks_usec() - tr
	if data.is_empty():
		_bump("missing_partition")
		return null
	var tp := Time.get_ticks_usec()
	# One layout cache for the whole walk, not one per partition — see the note
	# on BF6Ebx._init.
	var e := BF6Ebx.new(types, gi, _layouts)
	var ok := e.parse(data)
	t_parse += Time.get_ticks_usec() - tp
	if not ok:
		_bump("parse_fail")
		return null
	# Deliberately NOT cached on success: a level's partitions are visited once
	# each thanks to the cycle guard, and holding every parsed EBX for a whole
	# map is hundreds of megabytes for no reuse.
	return e


# ---------------------------------------------------------------------------
# StaticModelGroup (MAP_LOADING 6.6)
# ---------------------------------------------------------------------------
func emit_smg(inst: Dictionary, parent: Array, source_ref: String) -> void:
	var members = inst.get(F_SMG_MEMBERS)
	if not (members is Array):
		return
	for m in members:
		if not (m is Dictionary):
			continue
		var md: Dictionary = m
		var bp = md.get(F_SMG_BLUEPRINT)
		if bp == null:
			bp = md.get(F_SMG_MESHASSET)
		var path := ""
		if bp is Dictionary:
			path = str((bp as Dictionary).get("path", ""))
		if path == "" or path == "<not indexed>":
			_bump("smg_unresolved")
			continue

		var xf = md.get(F_SMG_XFORMS)
		var enabled: Array = flat_bools(md.get(F_SMG_ENABLED))
		var visible: Array = flat_bools(md.get(F_SMG_VISIBLE))
		# PER-INSTANCE ObjectVariation (DESTRUCTION.md 6.1). Measured on Dumbo,
		# 158 of 230 vehicle members carry one and it varies WITHIN a member — so
		# the mesh a placement wants is (name, variation), not name alone.
		var ovar = md.get(F_SMG_OBJVAR)

		if not (xf is Array) or (xf as Array).is_empty():
			# no instance transforms: one row at the bare parent, if visible
			if _visible_at(enabled, visible, 0):
				rows.append({"mesh": path, "xf": parent, "src": source_ref,
					"kind": "smg0", "var": _var_of(ovar, 0), "scope": _scope})
			continue
		var lst: Array = xf
		for i in range(lst.size()):
			if not is_lt(lst[i]):
				continue
			if not _visible_at(enabled, visible, i):
				_bump("smg_hidden")
				continue
			rows.append({"mesh": path,
				"xf": matmul(parent, lt_to_mat(lst[i])),
				"src": source_ref, "kind": "smg",
				"var": _var_of(ovar, i), "scope": _scope})


static func _var_of(ovar, i: int):
	# A truncated array means trailing defaults, i.e. no variation.
	if not (ovar is Array) or i >= (ovar as Array).size():
		return null
	var v = (ovar as Array)[i]
	if not (v is Dictionary):
		return null
	var p := str((v as Dictionary).get("path", ""))
	return p if p != "" and p != "<not indexed>" else null


# Missing entries default to VISIBLE (DESTRUCTION.md 6).
static func _visible_at(enabled: Array, visible: Array, i: int) -> bool:
	if i < enabled.size() and not bool(enabled[i]):
		return false
	if i < visible.size() and not bool(visible[i]):
		return false
	return true


# ---------------------------------------------------------------------------
# traversal (MAP_LOADING 6.5)
# ---------------------------------------------------------------------------
# Where the walk's time goes, split so the three costs are separable: reading
# and decompressing the partition, parsing its header, and decoding instances.
# They want completely different fixes and the total says nothing about which.
var t_read := 0
var t_parse := 0
var t_decode := 0
var n_instances := 0

# Called as (placements_found, instances_seen) every few thousand instances, so
# a caller can show the walk moving. Left unset costs one is_valid() per 8,192.
var progress := Callable()
var n_skipped := 0

# EVERY field visit() looks at. If a type declares none of these, visiting an
# instance of it cannot do anything: the SMG branch needs Members, the transform
# composition needs BlueprintTransform, the subworld bridge needs BundleName, the
# recursion needs Blueprint, and the descent needs one of the three child arrays.
# Miss one and the walk silently loses geometry, so this list and visit() have to
# be kept in step BY HAND — nothing here can check that automatically. What can
# be checked is the outcome, and test_walk.gd does: it runs the walk with
# `skip_types` off and on and requires the two to produce identical rows. A
# field dropped from this list shows up there as missing placements.
const WALK_FIELDS: Array = [F_SMG_MEMBERS, F_BP_TRANSFORM, F_EXCLUDED,
	F_BUNDLENAME, F_BLUEPRINT, F_OBJECTS, F_DATAREFS, F_SUBWORLD_COMPONENTS]

# Off makes the walk decode every instance, which is the reference behaviour.
var skip_types := true

# THE FIELDS A TOP-LEVEL INSTANCE IS DECODED FOR. Everything the traversal
# reads off an instance, and nothing else: WALK_FIELDS is what visit() looks
# at, F_TRANSFORM and want_xf_fields are how a collected entity is placed, and
# want_fields is whatever the caller asked to keep. Handed to
# BF6Ebx.read_instance so the other fields are never decoded at all.
#
# EMPTY WHEN want_all_fields IS SET, which turns the filter off completely -
# that caller (the gamemode miner) reads inst.keys(), so a filtered instance
# would hand it a subset and it would silently mine less than it did before.
#
# Rebuilt per run rather than cached across runs: want_fields and
# want_all_fields are set by the caller between construction and run().
var _decode_want := {}
# An empty _decode_want means "decode everything", which is also what
# want_all_fields asks for - so the built/not-built state needs its own flag
# rather than being inferred from the dictionary being empty.
var _want_built := false


func _build_decode_want() -> void:
	_want_built = true
	_decode_want = {}
	if want_all_fields:
		return
	for h in WALK_FIELDS:
		_decode_want[int(h)] = true
	for h in want_xf_fields:
		_decode_want[int(h)] = true
	_decode_want[F_TRANSFORM] = true
	for h in want_fields:
		if h is int:
			_decode_want[int(h)] = true

# partition asset path (lower, no .ebx) -> an opaque scope id the caller cares
# about. Left empty makes every row's `scope` "", i.e. the walk behaves exactly
# as it did before. The caller fills it with the bundles that own a depot.
var scope_index := {}
var _scope := ""
var _cur_part := ""                    # partition a collected entity came from

var _type_matters_cache := {}          # type guid hex -> bool
var _layouts := {}                     # type guid hex -> layout, shared by every partition


func _type_matters(dz, i: int) -> bool:
	if not skip_types:
		return true
	var tb: PackedByteArray = dz.instance_type_bytes(i)
	if tb.is_empty():
		return false                    # no type, nothing to decode
	var k := tb.hex_encode()
	var hit = _type_matters_cache.get(k)
	if hit != null:
		return hit
	# A WANTED TYPE ALWAYS MATTERS, checked before the field test rather than
	# after. A PbrSpotLightEntityData declares Transform, Color and Intensity and
	# not one field the traversal itself reads, so the field test correctly says
	# "this instance cannot affect the walk" — and skipping it would drop every
	# light on the map while the placements stayed perfect, which is the kind of
	# failure that looks like the collector is broken.
	if not want_types.is_empty():
		var tag = _want_hex.get(k)
		if tag == null:
			tag = want_types.get(BF6Types.guid_str(tb), "")
			_want_hex[k] = tag
		if str(tag) != "":
			_type_matters_cache[k] = true
			return true
	# Resolved ONCE per type across the whole map, not once per instance: there
	# are a few thousand types against 268,587 instances.
	var lay: Dictionary = types.layout_full(tb)
	var yes := false
	if not lay.is_empty():
		for fld in lay.get("fields", []):
			if WALK_FIELDS.has(int((fld as Dictionary)["nameHash"])):
				yes = true
				break
	_type_matters_cache[k] = yes
	return yes


func walk(ref, parent: Array, guard: Dictionary, depth := 0) -> void:
	if depth > MAX_DEPTH or ref == null:
		return
	# The object walker enters here rather than through run(), so the decode
	# set is built on first use as well as at the start of a run.
	if not _want_built:
		_build_decode_want()
	var key := str(ref).to_lower()
	if guard.has(key):
		_bump("cycle")
		return
	var dz = open_ebx(str(ref))
	if dz == null:
		return
	var sub_guard := guard.duplicate()
	sub_guard[key] = true
	_bump("partitions")

	# THE SCOPE A PLACEMENT INHERITS, tracked down the recursion.
	#
	# A section's shader state key is looked up in a ShaderBlockDepot, and a key
	# is only unique within a scope. The obvious reading — the depot beside the
	# partition that holds the placement — is wrong, and measurably so: a prop's
	# `src` is the PREFAB it sits in, somewhere under game/.../props, while its
	# depot belongs to the SUBWORLD that mounted the prefab. Those have no path
	# relationship at all.
	#
	# Measured on Dumbo: matching by directory ancestry resolved 54.7% of
	# sections, and 213 of the 214 absent keys (99.5%) turned up in another
	# subworld's depot of the same level — the one that actually placed them.
	# The single remaining miss is a Shadow material, which no depot carries.
	#
	# So scope is inherited: entering a partition that owns a depot makes it the
	# scope for everything below, and each row records the scope it was placed
	# under. The walk is the only thing that knows this, because the walk is what
	# did the mounting.
	var scope := _scope
	if not scope_index.is_empty():
		var bare := key.trim_suffix(".ebx")
		if scope_index.has(bare):
			scope = str(scope_index[bare])
	var prev_scope := _scope
	_scope = scope
	# WHICH PARTITION a collected entity came out of. The scope above is the
	# subworld that owns the depot, which is deliberately NOT the partition —
	# and the partition is the only thing that names a gamemode object ("...
	# conquest_capturepoint_a"), so a label has nowhere else to come from.
	var prev_part := _cur_part
	_cur_part = key.trim_suffix(".ebx")

	# THE SPATIAL COMPONENTS THAT CARRY A LIGHT'S PLACEMENT, resolved before the
	# instance loop because a component sits AFTER the light it places (in
	# lf_com_streetlight_02 the light is instance 10 and its component is 29), so
	# there is nothing to look up yet by the time the light is visited.
	#
	# Costs one PackedByteArray compare per instance and a decode only for the
	# handful that match, and runs only when a caller asked for entities at all —
	# a plain placement walk does none of it.
	var prev_xf: Dictionary = _light_xf
	_light_xf = {}
	if not want_types.is_empty():
		for i in range(dz.instance_offsets.size()):
			if dz.instance_type_bytes(i) != _light_xf_guid:
				continue
			var target := int(dz.int_pointer(i, F_COMPONENT_LIGHT))
			if target < 0:
				_bump("light_component_unlinked")
				continue
			# ONE FIELD. This reads the component's Transform and nothing
			# else, and it runs for every light on the map.
			var ci = dz.read_instance(i, 0, _XF_ONLY)
			if not (ci is Dictionary):
				continue
			var clt = (ci as Dictionary).get(F_TRANSFORM)
			if is_lt(clt):
				_light_xf[target] = lt_to_mat(clt)

	for i in range(dz.instance_offsets.size()):
		n_instances += 1
		# THE ONLY PLACE THIS WALK CAN REPORT FROM. The traversal is recursive and
		# has no outer loop to count, but every instance the level contains passes
		# through here — 268,587 of them on mp_dumbo, which is the ~100 s a cold
		# read spends with nothing to show. Reported by placements FOUND rather
		# than instances seen: there is no honest denominator (nothing knows how
		# many instances a level has until the walk ends), and "21,400 found and
		# climbing" says more than a percentage that was invented.
		if progress.is_valid() and (n_instances & 8191) == 0:
			progress.call(rows.size(), n_instances)
		# CAN THIS INSTANCE POSSIBLY MATTER? visit() reads exactly the fields in
		# WALK_FIELDS, so an instance whose type declares NONE of them is a
		# provable no-op — not a heuristic, an equivalence. Decoding it means
		# building a Dictionary of every field of every nested struct and then
		# throwing it away.
		#
		# This is where the walk's time is: reading and decompressing all 11,748
		# partitions costs 1.6 s and parsing their headers 0.6 s, against ~102 s
		# decoding 268,587 instances.
		if not _type_matters(dz, i):
			n_skipped += 1
			continue
		# TIMED AROUND read_instance ALONE. Wrapping the loop instead counted
		# nested walk() calls inside their own parents' windows and reported
		# 598 s of decoding inside a 104 s walk.
		var td := Time.get_ticks_usec()
		var inst = dz.read_instance(i, 0, _decode_want)
		t_decode += Time.get_ticks_usec() - td
		if not (inst is Dictionary):
			_bump("inst_fail")
			continue
		_cur_inst = i
		visit(inst, parent, str(ref), sub_guard, depth)
	# Restored on the way out: a sibling branch must not inherit the scope a
	# subworld set for its own subtree.
	_scope = prev_scope
	_cur_part = prev_part
	_light_xf = prev_xf


# The transform fields a collected entity might carry, tried in order.
#
# A light is a SpatialEntityData and its own placement is `Transform`
# (0xD6351EDE), NOT the `BlueprintTransform` (0x7B554EF5) a prefab reference
# uses. The Python miner reads BlueprintTransform, which a light does not have,
# so every light there lands at its holder's origin — near enough to look right
# on a map and wrong by a room's width in a building. Both are tried, and which
# one fired is counted, so the difference is a measurement rather than a claim.
var want_xf_fields: Array = [F_TRANSFORM, F_BP_TRANSFORM]

# instance index of the light -> the local matrix its spatial component carries,
# rebuilt per partition by walk(). Empty for a walk that collects nothing.
const _XF_ONLY := {F_TRANSFORM: true}

var _light_xf := {}
var _light_xf_guid: PackedByteArray = raw_guid(LIGHT_XF_COMPONENT)
# The instance visit() is currently on, which is what joins a collected light to
# its component. visit() takes a decoded Dictionary and a Dictionary has no
# index; nothing else in the traversal needs one.
var _cur_inst := -1


func _collect(tag: String, inst: Dictionary, parent: Array) -> void:
	var world := parent
	var which := "parent"
	# THE COMPONENT WINS when there is one. It is the entity's placement; the
	# entity's own Transform in that authoring model is identity, so on the data
	# this is not a preference but the only non-empty answer. Counted separately
	# so a build where the two disagree is visible rather than silently resolved.
	var comp = _light_xf.get(_cur_inst)
	if comp is Array:
		world = matmul(parent, comp)
		which = "component"
		var own = inst.get(F_TRANSFORM)
		if is_lt(own) and (lt_to_mat(own)[3] as Vector3).length() > 0.001:
			_bump("ent_xf_component_and_own")
	else:
		for h in want_xf_fields:
			var lt = inst.get(int(h))
			if is_lt(lt):
				world = matmul(parent, lt_to_mat(lt))
				which = "0x%08X" % int(h)
				break
	_bump("ent_xf_%s" % which)
	var f := {}
	var fields: Array = inst.keys() if want_all_fields else want_fields
	for h in fields:
		if not (h is int):
			continue                    # "__type", which is carried separately
		var v = inst.get(int(h))
		if v != null:
			# Vec3-shaped values are flattened here rather than at the consumer:
			# the walk's cache is a store_var of this array, and a nested
			# Dictionary of hash keys survives the round trip but reads as noise
			# on the far side.
			f[int(h)] = vec_of(v) if _is_vec(v) else v
	# The scope is carried for the same reason a placement carries it: anything
	# whose appearance comes from a ShaderBlockDepot — an environment decal
	# volume resolves its texture through a state key — needs the depot of the
	# subworld that mounted it, and only the walk knows which that was.
	ents.append({"tag": tag, "type": str(inst.get("__type", "")),
		"xf": world, "f": f, "scope": _scope, "src": _cur_part})


static func _is_vec(v) -> bool:
	return v is Dictionary and (v as Dictionary).has(K_VEC_X) \
		and (v as Dictionary).has(K_VEC_Y)


func visit(inst: Dictionary, parent: Array, ref: String, guard: Dictionary,
		depth: int) -> void:
	# Destruction state branch: stop. Everything below is an alternate or an
	# effect, and emitting it both ships wreckage as scenery AND suppresses the
	# leaf row that would have placed the intact prop.
	if DESTRUCTION_BRANCH.has(str(inst.get("__type", ""))):
		_bump("destruction_branch")
		return

	# A COLLECTED ENTITY. Recorded, then processed normally — a light is a leaf
	# in practice but nothing here depends on that, and a type that both carries
	# a wanted payload and holds children would otherwise lose the children.
	#
	# Placed AFTER the destruction check on purpose: a light that only exists in
	# a destroyed state is not lighting the intact map. The count is reported so
	# that choice is visible rather than assumed.
	if not want_types.is_empty():
		var tag = want_types.get(str(inst.get("__type", "")))
		if tag != null:
			_collect(str(tag), inst, parent)

	# A StaticModelGroup anywhere — including directly in the level root, which
	# is where backdrop and vista instancing lives.
	if inst.get(F_SMG_MEMBERS) is Array:
		emit_smg(inst, parent, ref)
		_bump("smg")
		return

	var local = inst.get(F_BP_TRANSFORM)
	var world: Array = matmul(parent, lt_to_mat(local)) if is_lt(local) else parent

	if inst.get(F_EXCLUDED):
		_bump("excluded")
		return

	# Subworld reference: the BundleName string names the subworld asset. This is
	# the one point where the graph depends on the catalogue rather than on
	# PointerRefs.
	var bn = inst.get(F_BUNDLENAME)
	if bn is String and str(bn) != "":
		var low := str(bn).to_lower()
		for s in SKIP_SUBWORLD:
			if low.contains(s):
				_bump("subworld_skipped")
				return
		var sub = resolve_name(str(bn))
		if sub != null:
			_bump("subworld")
			walk(sub, world, guard, depth + 1)
		else:
			_bump("subworld_unresolved")
		return

	# A placement pointing at another partition: recurse with the composed
	# transform. This is the step the old heuristic walker approximated.
	var bp = inst.get(F_BLUEPRINT)
	var tgt := ""
	if bp is Dictionary:
		tgt = str((bp as Dictionary).get("path", ""))
	if tgt != "" and tgt != "<not indexed>":
		if tgt.to_lower().ends_with(".ebx"):
			# RECURSE, BUT DO NOT LET A TARGET THAT YIELDS NOTHING VANISH.
			# Only SMG members ever emitted a row, so a placement pointing at a
			# blueprint whose geometry is a plain mesh asset was walked and
			# silently forgotten: measured on Dumbo, 1,381 of 1,407 target
			# partitions produced zero rows across 26,537 visits, and among them
			# are nongroupable_autogen building parts, debris piles and street
			# lights — real geometry, individually placed rather than instanced.
			# Emit those as leaf rows and let mesh resolution decide; an FX graph
			# simply fails to resolve and is reported as a drop, which is visible
			# rather than silent.
			var before := rows.size()
			walk(tgt, world, guard, depth + 1)
			if rows.size() == before:
				rows.append({"mesh": tgt, "xf": world, "src": ref,
					"kind": "leaf", "var": null, "scope": _scope})
				_bump("leaf_emitted")
		else:
			rows.append({"mesh": tgt, "xf": world, "src": ref,
				"kind": "ref", "var": null, "scope": _scope})
		return

	for f in [F_OBJECTS, F_DATAREFS, F_SUBWORLD_COMPONENTS]:
		var arr = inst.get(f)
		if arr is Array:
			for child in arr:
				if child is Dictionary:
					visit(child, world, ref, guard, depth)


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
# `level_rel` is the level's asset path, e.g. "game/<studio>/levels/mp_dumbo".
# Resolution tries the full path then the bare leaf, the same two-step
# resolve_name does, because a mount catalogues both.
# ---------------------------------------------------------------------------
# THE RESULT, CACHED. This is what makes the reader usable rather than merely
# correct.
#
# Cold, from nothing but the install, a Dumbo map costs 88 s: 16 s mounting,
# 19 s indexing partition guids, 53 s walking. The first two already cache; this
# is the third and largest, and without it every scene open pays the walk again.
#
# Keyed on the TOC signature, so a game patch invalidates it in step with the
# other two, AND on VERSION, because a change to the traversal changes the rows
# it produces — a cache surviving that would serve yesterday's map with today's
# code, which is the worst of both.
# 2: rows carry `scope`, the depot scope inherited down the walk. A v1 cache has
# no such field, and serving one would silently give every row an empty scope —
# which fails open into "no textures" rather than into an error.
# 3: the walk can carry collected entities (lights and anything else placed
#    rather than drawn) beside the rows. A v2 cache has none, and serving one
#    would give a map its props and no lights with nothing to say so.
# 4: a collected light's transform comes from its spatial component when it has
#    one. A v3 cache has 86.9% of Dumbo's lights sitting on their holder's
#    origin, which is not an error anything downstream can detect.
const VERSION := 4


func cache_path(level_rel: String) -> String:
	var sig := src.signature() if src != null else ""
	if sig == "":
		return ""
	var leaf := level_rel.replace("\\", "/").rstrip("/").get_file()
	return "user://bf6_walk_%s_v%d_%s.idx" % [leaf, VERSION, sig]


# WHICH COLLECTORS THIS CACHE WAS BUILT WITH. Two callers can want the same
# level and different entities — a bare placement walk asks for none — and a
# cache written by the first would silently satisfy the second. Cheaper than a
# cache file per collector set, and it fails towards re-walking rather than
# towards missing data.
func _want_sig() -> String:
	if want_types.is_empty():
		return ""
	var tags := {}
	for k in want_types:
		tags[str(want_types[k])] = true
	var lst: Array = tags.keys()
	lst.sort()
	return ",".join(PackedStringArray(lst))


func load_cached(level_rel: String) -> bool:
	var p := cache_path(level_rel)
	if p == "" or not FileAccess.file_exists(p):
		return false
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var d = f.get_var()
	f.close()
	if typeof(d) != TYPE_DICTIONARY or not (d as Dictionary).has("rows"):
		return false
	var r = (d as Dictionary)["rows"]
	if not (r is Array) or (r as Array).is_empty():
		return false            # an empty cache is indistinguishable from a failed walk
	if str((d as Dictionary).get("want", "")) != _want_sig():
		return false            # built for a different set of collectors
	rows = r
	var e = (d as Dictionary).get("ents", [])
	ents = e if e is Array else []
	stats = (d as Dictionary).get("stats", {})
	stats["from_cache"] = true
	return true


func save_cache(level_rel: String) -> void:
	var p := cache_path(level_rel)
	if p == "" or rows.is_empty():
		return
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return                  # a cache that cannot be written is not an error
	f.store_var({"rows": rows, "ents": ents, "stats": stats,
		"want": _want_sig()})
	f.close()


# Cache, or walk and cache. The catalogue still has to be built either way —
# resolve_name and the partition index are wanted by everything downstream, and
# both are cheap once warm.
func run_cached(level_rel: String) -> bool:
	if load_cached(level_rel):
		return true
	if not run(level_rel):
		return false
	# WHAT THE WALK DECODED. `want` prunes top-level fields only, so a wanted
	# struct field still decodes its whole subtree through the unfiltered
	# reader. If nested dwarfs top-level, that blind spot is the walk's cost
	# and pushing the filter down is the fix; if not, the cost is elsewhere
	# and the decoder should be left alone.
	print("BF6Walk: decode - %s" % BF6Ebx.decode_counts())
	# A FINGERPRINT OF THE PLACEMENTS THEMSELVES, and nothing else.
	#
	# The .idx cache is not usable as an oracle: save_cache stores `stats`
	# beside the rows, and stats carries per-run counters, so two identical
	# walks write different bytes. (PackedScene had the same trap - see the
	# terrain tile cache.) Row COUNTS are not enough either: a transposed basis
	# moves every prop on the map while leaving every count untouched.
	#
	# So this hashes the mesh path and the twelve transform floats of every
	# row, in row order. It changes if any placement moves and does not change
	# for anything else.
	var _ctx := HashingContext.new()
	_ctx.start(HashingContext.HASH_SHA256)
	for r in rows:
		var rd: Dictionary = r
		_ctx.update(str(rd.get("mesh", "")).to_utf8_buffer())
		var m = rd.get("xf")
		if m is Array:
			var fb := PackedFloat64Array()
			for v in m:
				if v is Vector3:
					fb.append(v.x); fb.append(v.y); fb.append(v.z)
			_ctx.update(fb.to_byte_array())
	print("BF6Walk: placements fingerprint %s (%d rows)"
		% [_ctx.finish().hex_encode().substr(0, 32), rows.size()])
	save_cache(level_rel)
	return true


func run(level_rel: String) -> bool:
	rows.clear()
	ents.clear()
	stats.clear()
	# Forced, not lazy: a caller may set want_fields between two runs of the
	# same walker, and a set built for the previous run would quietly decode
	# the wrong fields for this one.
	_build_decode_want()
	# Zeroed here so the numbers describe THIS walk, not everything the editor
	# has decoded since it opened.
	BF6Ebx.reset_counts()
	var rel := level_rel.replace("\\", "/").rstrip("/")
	var leaf := rel.get_file()
	var start = resolve_name("%s/%s" % [rel, leaf])
	if start == null:
		start = resolve_name(rel)
	if start == null:
		start = resolve_name(leaf)
	if start == null and not rel.contains("/"):
		# A BARE LEVEL NAME. The catalogue knows which studio owns a level, so a
		# caller should not have to. Anchored on '/levels/<leaf>/<leaf>' rather
		# than a substring: a loose match would happily pick a neighbouring level
		# whose name merely CONTAINS this one.
		var tails: Array = ["/levels/%s/%s" % [leaf.to_lower(), leaf.to_lower()]]
		# The SDK names a scene by its display name and the game files the
		# level under an mp_ id: Portal_Sand is game/glacierportal/levels/
		# mp_portal_sand. Still anchored - the prefixed spelling of THIS
		# level, not a substring that could pick a neighbour.
		if not leaf.to_lower().begins_with("mp_"):
			tails.append("/levels/mp_%s/mp_%s" % [leaf.to_lower(), leaf.to_lower()])
		for tail in tails:
			var hits: Array = []
			for k in by_name.keys():
				if str(k).ends_with(str(tail)):
					hits.append(str(k))
			hits.sort()
			if not hits.is_empty():
				start = by_name[hits[0]]
				stats["resolved_via"] = hits[0]
				break
	if start == null:
		stats["error"] = "could not resolve the level root for %s" % level_rel
		return false
	stats["root"] = start
	walk(start, IDENT, {}, 0)
	stats["rows"] = rows.size()
	stats["ents"] = ents.size()
	stats["ms_read"] = int(t_read / 1000)
	stats["ms_parse"] = int(t_parse / 1000)
	stats["ms_decode"] = int(t_decode / 1000)
	stats["instances"] = n_instances
	stats["instances_skipped"] = n_skipped
	return not rows.is_empty()
