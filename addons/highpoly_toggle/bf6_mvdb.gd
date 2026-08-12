@tool
extends RefCounted
class_name BF6Mvdb

# MeshVariationDatabase: which textures a placement's variation actually binds.
#
# The placement walk says a prop is `com_metrobus_01` with variation hash
# 2575843486. This says what that hash MEANS — the Cairo livery rather than the
# default — and which texture assets to load for it. Without it every variant of
# a mesh renders identically, which is the "vehicle liveries look wrong" class of
# bug in its purest form.
#
# Ported from tools/mvdb_v2.py. The layout below is validated against BF6 retail
# through the exe's own reflection tables, and the field names are confirmed
# against the Frosty type DB rather than guessed:
#
#   Root  MeshVariationDatabase 4a3dfc2e (size 40), exactly one per file
#     +32  Entries: array of MeshVariationDatabaseEntry 9c47a6dc (stride 40)
#
#   Entry 9c47a6dc
#     +0   Materials: array of MeshVariationDatabaseMaterial e80ccb73 (stride 40)
#     +8   Mesh: PointerRef. The IMPORT's partition guid IS the mesh ebx guid.
#     +28  u32 VariationAssetNameHash — DJB2-x33-XOR of the lowercased OV asset
#          path. 0 means the default variation.
#
#   Material e80ccb73
#     +8   MaterialVariation: PointerRef, INTERNAL, a **SIGNED i32** relative
#          offset from the field position.
#
#   MeshMaterialVariation fa54dd43 (size 96)
#     +24  SurfaceShaderInstanceDataStruct, whose +24 is TextureParameters.
#
# THE ARRAY CONVENTION, which is not the obvious one: a field holds an i32
# RELATIVE offset at position `pos`, and the data begins at (pos + 4) + rel - 8,
# with the count as an i32 there and the elements after it.

const ROOT_TYPE := "4a3dfc2e-264a-f0eb-dc11-859c3bc1f373"

const ENTRIES_OFF := 32
const ENTRY_STRIDE := 40
const E_MATS := 0
const E_MESH := 8
const E_HASH := 28

const MAT_STRIDE := 40
const M_ENTRYREL := 8

# fa54dd43 +24 is the material struct; within it, ONLY +24 is
# TextureParameters. The exe's reflection proves +8/+16/+32/+48 are
# Conditional/Bool/VectorArray/Vector parameters with different strides, so
# scanning them risked binding a non-texture as a texture.
const FA_MAT_OFF := 24
const FA_PARAM_ARRAYS: Array = [24]
const TEX_PARAM_STRIDE := 16

const TEX_EXT: Array = ["_cs.ebx", "_nm.ebx", "_c.ebx", "_nsm.ebx", "_nmt.ebx",
	"_ca.ebx", "_mask.ebx"]

# Suffixes looked for by name convention, in the order the pipeline uses them.
const VST_SUFFIXES: Array = ["cs", "nea", "nm", "nmo", "a", "c", "nsm", "mask", "ca"]

var gi := {}                    # partition guid -> asset path
var _ov_by_hash := {}           # DJB2 of an ov_* asset path -> that path
var _vst := {}                  # "vst_<name>" -> path
var _t_by_dir := {}             # directory -> [[basename, path], ...]
var _indexed := false


func _init(guid_index := {}) -> void:
	gi = guid_index


# DJB2 x33 XOR over the lowercased path. This is the hash the entries carry, so
# it is the only way back from a variation hash to the asset that named it.
static func djb2(s: String) -> int:
	var h := 5381
	for b in s.to_lower().to_utf8_buffer():
		h = ((h * 33) ^ int(b)) & 0xFFFFFFFF
	return h


# ---------------------------------------------------------------------------
# BUILT ONCE, not per database.
#
# Both tables below are loop invariants over the guid index, and the Python
# original rebuilt them on EVERY call: across ~17k databases over a 450k-entry
# index that measured 2.03 s of pure waste each, about 9.6 hours per rebuild
# before any parsing happened at all.
# ---------------------------------------------------------------------------
func build_index() -> void:
	if _indexed:
		return
	_ov_by_hash.clear()
	_vst.clear()
	_t_by_dir.clear()
	for p in gi.values():
		var path := str(p)
		var low := path.to_lower()
		if not low.ends_with(".ebx"):
			continue
		var bn := low.get_file().substr(0, low.get_file().length() - 4)
		if bn.begins_with("ov_"):
			# Hashed WITHOUT the extension: the hash is of the asset path, and
			# an asset path has none.
			_ov_by_hash[djb2(path.replace("\\", "/").substr(0, path.length() - 4))] = path
		elif bn.begins_with("vst_"):
			_vst[bn] = path
		elif bn.begins_with("t_"):
			var dir := low.get_base_dir()
			if not _t_by_dir.has(dir):
				_t_by_dir[dir] = []
			(_t_by_dir[dir] as Array).append([bn, path])
	_indexed = true


static func _is_tex(path: String) -> bool:
	var p := path.to_lower()
	for e in TEX_EXT:
		if p.ends_with(e):
			return true
	var bn := p.get_file()
	return bn.begins_with("t_") or bn.begins_with("vst_")


# A RiffEbx array at field position `pos` -> [count, first element offset].
static func _array_at(d: PackedByteArray, pos: int) -> Array:
	if pos < 0 or pos + 4 > d.size():
		return [0, -1]
	var rel := int(d.decode_s32(pos))
	var ad := (pos + 4) + rel - 8
	if ad < 0 or ad + 4 > d.size():
		return [0, -1]
	var cnt := int(d.decode_s32(ad))
	# The upper bound is a sanity check, not a format rule: a wild rel offset
	# lands on arbitrary bytes and would otherwise be read as a huge count.
	if cnt <= 0 or cnt > 200000:
		return [0, -1]
	return [cnt, ad + 4]


# ---------------------------------------------------------------------------
# The name-convention half.
#
# GROUND TRUTH, and it is counter-intuitive: a variation's textures are NOT
# referenced by the database. Verified across the dump — 0 of 1,013
# meshvariationdb files contain the Cairo vst_/t_ texture partition guids, the
# OV asset itself is a ~326-byte stub of {NameHash, Name} with zero imports, and
# the mesh partition imports only its shader. Only ~44 of 7,191 variation
# entries carry explicit texture parameters at all.
#
# So the database gives (mesh, variation) and the textures are found by NAME:
# vst_<ov basename>_<suffix>. That is a convention, not a guarantee, which is
# why the weaker same-directory t_* guesses are marked with a trailing '?' —
# a caller can take the solid ones and leave the heuristics alone.
# ---------------------------------------------------------------------------
func convention_textures(ov_path: String) -> Dictionary:
	var out := {}
	var low := ov_path.to_lower()
	var ovdir := low.get_base_dir()
	var ovname := low.get_file()
	if ovname.ends_with(".ebx"):
		ovname = ovname.substr(0, ovname.length() - 4)
	for suffix in VST_SUFFIXES:
		var p = _vst.get("vst_%s_%s" % [ovname, suffix])
		if p != null:
			out["VST_" + str(suffix).to_upper()] = p
	var bare = _vst.get("vst_" + ovname)
	if bare != null and not out.has("VST_TEX"):
		out["VST_TEX"] = bare

	# The tail token, e.g. 'cairo' out of ov_com_metrobus_01_cairo. Required to
	# be alphabetic and reasonably long: a numeric or two-letter tail matches
	# far too much to be evidence of anything.
	var parts := ovname.split("_")
	var tail := str(parts[parts.size() - 1]) if parts.size() > 0 else ""
	var tail_ok := tail.length() >= 4 and _is_alpha(tail)
	if tail_ok:
		for pair in _t_by_dir.get(ovdir, []):
			var bn := str((pair as Array)[0])
			if bn.split("_").has(tail):
				var k := "T_%s?" % bn.split("_")[bn.split("_").size() - 1].to_upper()
				if not out.has(k):
					out[k] = (pair as Array)[1]
	return out


static func _is_alpha(s: String) -> bool:
	for c in s:
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z")):
			return false
	return true


# Texture parameters of one MeshMaterialVariation, at payload-relative offset io.
func _entry_params(e: BF6Ebx, io: int) -> Dictionary:
	var d: PackedByteArray = e.data
	var base: int = e.payload + io
	var params := {}
	for ao in FA_PARAM_ARRAYS:
		var arr := _array_at(d, base + FA_MAT_OFF + int(ao))
		var cnt: int = arr[0]
		var elem: int = arr[1]
		if elem < 0:
			continue
		for k in range(cnt):
			var eb: int = elem + k * TEX_PARAM_STRIDE
			if eb + TEX_PARAM_STRIDE > d.size():
				break
			var pref := int(d.decode_s64(eb))
			# Only IMPORT-valued parameters are textures; an internal ref here
			# is something else entirely.
			if pref == 0 or not (pref & 1):
				continue
			var idx := pref >> 1
			if idx < 0 or idx >= e.imports.size():
				continue
			var part := str((e.imports[idx] as Dictionary)["partition"])
			var tex := str(gi.get(part, part))
			if not _is_tex(tex):
				continue
			var noff := int(d.decode_s64(eb + 8))
			var name := _cstr(d, eb + 8 + noff)
			# Two parameters of the same name pointing at different textures is
			# real (channel-split maps); keep both rather than let one win.
			if params.has(name) and str(params[name]) != tex:
				name = "%s#%d" % [name, k]
			params[name] = tex
	return params


static func _cstr(d: PackedByteArray, at: int) -> String:
	if at < 0 or at >= d.size():
		return ""
	var e := at
	var stop: int = mini(d.size(), at + 256)
	var _f := d.find(0, e)
	e = stop if (_f < 0 or _f > stop) else _f
	return d.slice(at, e).get_string_from_utf8()


# ---------------------------------------------------------------------------
# -> { "<mesh partition guid>|<variation hash>": {param or convention key: path} }
#
# The key is a String rather than a tuple because GDScript dictionaries cannot
# key on an Array by value.
# ---------------------------------------------------------------------------
func resolve(e: BF6Ebx) -> Dictionary:
	build_index()
	var d: PackedByteArray = e.data
	var payload: int = e.payload

	var root := -1
	for i in range(e.instance_offsets.size()):
		if e.instance_type(i) == ROOT_TYPE:
			root = i
			break
	if root < 0:
		return {}

	# Membership test for "is this offset a real instance", so a bad relative
	# offset cannot be followed into the middle of unrelated bytes.
	var inst_set := {}
	for off in e.instance_offsets:
		inst_set[int(off)] = true

	var out := {}
	var ea := _array_at(d, payload + int(e.instance_offsets[root]) + ENTRIES_OFF)
	var ecnt: int = ea[0]
	var e0: int = ea[1]
	if e0 < 0:
		return {}
	for ei in range(ecnt):
		var eo: int = e0 + ei * ENTRY_STRIDE
		if eo + ENTRY_STRIDE > d.size():
			break
		var mq := int(d.decode_s64(eo + E_MESH))
		if not (mq & 1):
			continue                      # the mesh must be an import
		var midx := mq >> 1
		if midx < 0 or midx >= e.imports.size():
			continue
		var mesh_guid := str((e.imports[midx] as Dictionary)["partition"])
		var var_hash := int(d.decode_u32(eo + E_HASH))

		var params := {}
		var ma := _array_at(d, eo + E_MATS)
		var mcnt: int = ma[0]
		var m0: int = ma[1]
		if m0 >= 0:
			for k in range(mcnt):
				var vb: int = m0 + k * MAT_STRIDE
				if vb + MAT_STRIDE > d.size():
					break
				# SIGNED i32. Reading the full qword breaks on negative offsets:
				# the high dword is zero, so a -27,144 back-pointer reads as
				# 4,294,940,152 and resolves to nothing. Most of these point
				# backwards.
				var r := int(d.decode_s32(vb + M_ENTRYREL))
				if r == 0:
					continue
				var tgt: int = (vb + M_ENTRYREL) + r - payload
				if inst_set.has(tgt):
					params.merge(_entry_params(e, tgt), true)

		if var_hash != 0:
			var ov = _ov_by_hash.get(var_hash)
			if ov != null:
				params["__VariationName"] = ov
				# setdefault semantics: an explicit parameter from the database
				# always beats a name-convention guess.
				for kk in convention_textures(str(ov)):
					if not params.has(kk):
						params[kk] = convention_textures(str(ov))[kk]

		var key := "%s|%d" % [mesh_guid, var_hash]
		if out.has(key):
			(out[key] as Dictionary).merge(params, true)
		else:
			out[key] = params
	return out
