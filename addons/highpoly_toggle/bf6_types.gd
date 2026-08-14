extends RefCounted
class_name BF6Types      # see the note in bf6_ebx.gd on why these are named

# Frostbite type layouts, read out of the game's own executable.
#
# EBX payloads are not self-describing: an instance is a bare struct, and making
# sense of it needs the type's field list — name hashes, offsets and field types.
# That metadata lives in the exe's `typeinfo` section, which means the placement
# walk cannot work from the container alone.
#
# This is typesdk.py ported. SAFE: the file is read, never the running process.
# Layout per FrostyToolsuite FrostbiteVersion 7 (2023+), type names stripped.
#
# THE SEARCH IS NATIVE FOR A REASON. Resolving one type means locating its
# 16-byte GUID inside a 5.3 MB section, and a level traversal resolves hundreds.
# Measured: 3.2 s per scan in a GDScript loop against 29.6 ms native, over the
# whole 169 MB file — 108x. Without BF6Oodle.find() the only affordable option
# would be shipping a pre-generated type database, i.e. putting a downloaded
# file back in the middle of a plugin built to read the install.
#
#   open(exe_path)                  load and parse the PE
#   layout(guid_bytes)              one type's own fields
#   layout_full(guid_bytes)         plus every inherited field
#   resolve(type_va)                a field's type: guid, enum, array element

const MAX_SUPER_DEPTH := 12

var error := ""
var image_base := 0
var sections: Array = []          # [name, virtual_addr, virtual_size, raw_off, raw_size]
var data := PackedByteArray()

var _oo = null
# WAS THE `typeinfo` SECTION FOUND, and how big. Reported rather than merely
# warned about: without a section the lookup falls back to scanning the whole
# executable, which is slower AND can match a guid-shaped run of bytes in
# unrelated data, so layouts come back wrong instead of missing. That is one of
# the few states that would empty every EBX-dependent feature at once while
# leaving meshes, textures and terrain perfect, and until now the only notice of
# it was a push_warning that never reached the session log.
var ti_found := false
var ti_size := 0
var _ti_off := 0                  # `typeinfo` section bounds, for the search
var _ti_end := 0
var _layout_cache := {}
var _full_cache := {}
var _find_calls := 0
var _fallback_calls := 0


# Where the game keeps its executables. The SP and MP builds carry DIFFERENT
# type databases, so which one is loaded is a real choice and not a fallback —
# picking the wrong one resolves types to the wrong layouts rather than failing.
static func exe_candidates(game_dir: String) -> Array:
	return [game_dir.path_join("SP/bf6.exe"), game_dir.path_join("bf6.exe")]


func open(exe_path: String) -> bool:
	error = ""
	if not FileAccess.file_exists(exe_path):
		error = "no exe at %s" % exe_path
		return false
	_oo = ClassDB.instantiate("BF6Oodle")
	if _oo == null or not _oo.has_method("find"):
		error = ("the BF6Oodle extension is missing find() — an old build of "
				+ "bf6_oodle.windows.x86_64.dll is loaded")
		return false

	data = FileAccess.get_file_as_bytes(exe_path)
	if data.size() < 0x40:
		error = "%s is too small to be a PE" % exe_path
		return false
	var pe := int(data.decode_u32(0x3C))
	if pe <= 0 or pe + 24 > data.size():
		error = "no PE header"
		return false
	var nsec := int(data.decode_u16(pe + 6))
	var optsz := int(data.decode_u16(pe + 20))
	var opt := pe + 24
	image_base = int(data.decode_u64(opt + 24))
	var so := opt + optsz
	sections.clear()
	for i in range(nsec):
		var o := so + i * 40
		if o + 40 > data.size():
			break
		var nm := data.slice(o, o + 8)
		while nm.size() > 0 and nm[nm.size() - 1] == 0:
			nm.resize(nm.size() - 1)
		sections.append([nm.get_string_from_ascii(),
				int(data.decode_u32(o + 12)), int(data.decode_u32(o + 8)),
				int(data.decode_u32(o + 20)), int(data.decode_u32(o + 16))])

	var ti := section("typeinfo")
	ti_found = not ti.is_empty()
	ti_size = int(ti[4]) if ti_found else 0
	if ti.is_empty():
		# Not fatal: the search falls back to the whole file, which is slower
		# but correct. Said out loud because a silent 30x slowdown reads as
		# "the plugin is slow" rather than "this exe is laid out differently".
		push_warning("bf6_types: no `typeinfo` section; searching the whole exe")
		_ti_off = 0
		_ti_end = data.size()
	else:
		_ti_off = int(ti[3])
		_ti_end = int(ti[3]) + int(ti[4])
	return true


func section(name: String) -> Array:
	for s in sections:
		if str(s[0]) == name:
			return s
	return []


# Virtual address -> file offset, or -1.
#
# A VA WITH THE HIGH BIT SET ARRIVES NEGATIVE. GDScript's int is signed 64-bit,
# so decode_u64 on such a value returns it minus 2**64 where Python would return
# the huge positive. Both are the same bytes and both are junk — a valid image
# is based around 0x140000000, and these are uninitialised pointers in inherited
# field lists.
#
# Both readers reject them, from opposite directions: Python's huge positive
# lands in no section, this one fails `sva <= rva` because rva is enormously
# negative. Verified equal on 957 fields. Anyone tightening these comparisons
# should keep that symmetry — clamping a negative VA to zero here would make it
# look like a valid low address instead of an invalid one.
func offset_of(va: int) -> int:
	var rva := va - image_base
	for s in sections:
		var sva := int(s[1])
		var span: int = maxi(int(s[2]), int(s[4]))
		if sva <= rva and rva < sva + span:
			var fo: int = int(s[3]) + (rva - sva)
			if fo < data.size():
				return fo
	return -1


static func guid_str(b: PackedByteArray) -> String:
	if b.size() < 16:
		return ""
	return "%08x-%04x-%04x-%s-%s" % [b.decode_u32(0), b.decode_u16(4),
			b.decode_u16(6), b.slice(8, 10).hex_encode(),
			b.slice(10, 16).hex_encode()]


# ---------------------------------------------------------------------------
# type layouts
# ---------------------------------------------------------------------------

# One type's own layout, anchored on its GUID.
#
# Layout at the guid's file offset `fo`:
#   nameHash u32 @ fo-8, flags u16 @ fo-4, size u16 @ fo-2, guid[16] @ fo,
#   align u8 @ +32, fieldCount u16 @ +34, signature u32 @ +36,
#   superClass u64 @ +40, pFieldInfos u64 @ +48 (class) or +88 (struct)
# FieldInfo, stride 24: nameHash u32 @ +0, flags u16 @ +4, offset u32 @ +8,
#   typeVA u64 @ +16
#
# CACHED, and it has to be: every instance read walks its whole superclass
# chain, so the same handful of types would otherwise be rescanned millions of
# times over one traversal. The scan is a pure function of the guid.
func layout(guid: PackedByteArray) -> Dictionary:
	var key := guid.hex_encode()
	if _layout_cache.has(key):
		return _copy(_layout_cache[key])
	var lay := _layout_uncached(guid)
	_layout_cache[key] = lay
	return _copy(lay)


func _layout_uncached(guid: PackedByteArray) -> Dictionary:
	_find_calls += 1
	var fo: int = _oo.find(data, guid, _ti_off, _ti_end)
	if fo < 0:
		# Outside the section too: guid bytes can appear anywhere, but a type
		# that is genuinely elsewhere is better found than missed.
		#
		# COUNTED, because this costs about 30x the section search — the whole
		# 169 MB rather than 5.3 MB — and a reader that quietly took this path
		# every time would look like the native search was not worth having.
		_fallback_calls += 1
		fo = _oo.find(data, guid, 0, -1)
	if fo < 8 or fo + 56 > data.size():
		return {}

	var flags := int(data.decode_u16(fo - 4))
	var type_enum := (flags >> 5) & 0x1F     # 2=Struct 3=Class 4=Array 8=Enum
	var field_count := int(data.decode_u16(fo + 34))
	var pf_off := 48 if type_enum == 3 else 88
	var p_fields := int(data.decode_u64(fo + pf_off))

	var fields: Array = []
	var fo_pf := offset_of(p_fields) if p_fields > image_base else -1
	if fo_pf >= 0:
		for i in range(field_count):
			var b := fo_pf + i * 24
			if b + 24 > data.size():
				break
			var foff := int(data.decode_u32(b + 8))
			# 0xFFFF is the "no serialized slot" sentinel, NOT an offset. These
			# fields exist on the runtime class but are never written to the EBX
			# payload, and reading one lands at base + 65535. On
			# lf_com_streetlight_02 that is 22 of a type's 43 fields, and the
			# first to land past the end of the file killed the whole instance —
			# taking the intact street light's blueprint reference with it, 395
			# times. The ones that landed INSIDE the file were worse: they
			# returned whatever bytes were there, silently.
			if foff >= 0xFFFF:
				continue
			var ff := int(data.decode_u16(b + 4))
			fields.append({
				"nameHash": int(data.decode_u32(b)),
				"flags": ff, "offset": foff,
				"typeVA": int(data.decode_u64(b + 16)),
				"ftype_enum": (ff >> 5) & 0x1F,
				"fcategory": (ff >> 1) & 0xF,
			})
	return {
		"guid": guid_str(guid), "guid_raw": guid,
		"nameHash": int(data.decode_u32(fo - 8)),
		"flags": flags, "size": int(data.decode_u16(fo - 2)),
		"align": data[fo + 32], "type_enum": type_enum,
		"fieldCount": field_count, "signature": int(data.decode_u32(fo + 36)),
		"fields": fields, "superClassVA": int(data.decode_u64(fo + 40)),
	}


# Layout including inherited fields.
func layout_full(guid: PackedByteArray, depth := 0) -> Dictionary:
	var key := guid.hex_encode()
	if depth == 0 and _full_cache.has(key):
		return _copy(_full_cache[key])
	var lay := _layout_full_uncached(guid, depth)
	if depth == 0:
		_full_cache[key] = lay
		return _copy(lay)
	return lay


func _layout_full_uncached(guid: PackedByteArray, depth: int) -> Dictionary:
	var lay := layout(guid)
	if lay.is_empty() or depth > MAX_SUPER_DEPTH:
		return lay
	var sva := int(lay.get("superClassVA", 0))
	if sva <= image_base:
		return lay
	var sg := _guid_at_typeinfo(sva)
	if sg.is_empty() or sg == guid or _all_zero(sg):
		return lay
	var sup := layout_full(sg, depth + 1)
	if sup.is_empty():
		return lay
	# DEDUP BY nameHash, which is the field's identity. Keying on offset was
	# wrong twice over: it silently dropped any superclass field sharing a slot
	# with a subclass one, and because unserialized fields all carried the same
	# 0xFFFF sentinel it collapsed every one of them into a single entry.
	var have := {}
	for f in lay["fields"]:
		have[int(f["nameHash"])] = true
	for f in sup["fields"]:
		var nh := int(f["nameHash"])
		if not have.has(nh):
			have[nh] = true
			lay["fields"].append(f)
	return lay


# va -> TypeInfo struct; its first u64 is a typeInfoDataOffset, guid at +8.
func _guid_at_typeinfo(va: int) -> PackedByteArray:
	var o := offset_of(va)
	if o < 0 or o + 8 > data.size():
		return PackedByteArray()
	var tido := int(data.decode_u64(o))
	if tido <= image_base:
		return PackedByteArray()
	var od := offset_of(tido)
	if od < 0 or od + 24 > data.size():
		return PackedByteArray()
	return data.slice(od + 8, od + 24)


# A field's typeVA -> {guid, guid_raw, flags, te, cat, elemVA}.
func resolve(type_va: int) -> Dictionary:
	var o := offset_of(type_va)
	if o < 0 or o + 8 > data.size():
		return {}
	var tido := int(data.decode_u64(o))
	if tido <= image_base:
		return {}
	var od := offset_of(tido)
	if od < 0 or od + 24 > data.size():
		return {}
	var flags := int(data.decode_u16(od + 4))
	var guid := data.slice(od + 8, od + 24)
	var te := (flags >> 5) & 0x1F
	var elem_va := 0
	if te == 0x04:
		# Array: the element type pointer. Its offset varies for anonymous
		# arrays, so try the known slots and take the first that dereferences to
		# a plausible TypeInfoData.
		for k in [48, 40, 56, 32, 24]:
			if od + k + 8 > data.size():
				continue
			var cand := int(data.decode_u64(od + k))
			if cand > image_base and not _type_guid_only(cand).is_empty():
				elem_va = cand
				break
	return {"guid": guid_str(guid), "guid_raw": guid, "flags": flags,
			"te": te, "cat": (flags >> 1) & 0xF, "elemVA": elem_va}


# Does typeVA dereference to a TypeInfoData with a sane type enum?
func _type_guid_only(type_va: int) -> PackedByteArray:
	var o := offset_of(type_va)
	if o < 0 or o + 8 > data.size():
		return PackedByteArray()
	var tido := int(data.decode_u64(o))
	if tido <= image_base:
		return PackedByteArray()
	var od := offset_of(tido)
	if od < 0 or od + 24 > data.size():
		return PackedByteArray()
	var te := (int(data.decode_u16(od + 4)) >> 5) & 0x1F
	# struct / class / cstring / enum / string / guid / resref
	if te in [0x02, 0x03, 0x07, 0x08, 0x06, 0x15, 0x17]:
		return data.slice(od + 8, od + 24)
	return PackedByteArray()


func stats() -> Dictionary:
	return {"sections": sections.size(), "bytes": data.size(),
			"searches": _find_calls, "fallbacks": _fallback_calls,
			"cached": _layout_cache.size(),
			"cached_full": _full_cache.size()}


func _all_zero(b: PackedByteArray) -> bool:
	for x in b:
		if x != 0:
			return false
	return true


# Callers MUTATE what they get back (layout_full appends inherited fields to
# `fields`), so a cached entry is never handed out directly.
func _copy(lay: Dictionary) -> Dictionary:
	if lay.is_empty():
		return {}
	var out := lay.duplicate()
	var fs: Array = []
	for f in lay["fields"]:
		fs.append((f as Dictionary).duplicate())
	out["fields"] = fs
	return out
