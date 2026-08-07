extends RefCounted
# Named, like the rest of the stack. Without this the only way to reach it is
# preload("res://bf6_ebx.gd"), which ties every consumer to the file sitting at
# the project root — true in the test project and false in the plugin, where it
# lives under addons/. A global class works from either.
class_name BF6Ebx

# RIFF-EBX: the container parse and the value deserializer, driven by the type
# layouts in bf6_types.gd.
#
# ebx.py and ebx_deser.py ported together, because one is unusable without the
# other. Layout per FrostyToolsuite/FrostySdk/IO/RiffEbx (FrostbiteVersion
# >= 2021).
#
# An EBX partition is RIFF with three chunks: EBXD (the instance data), EFIX
# (the fixup table — type guids, instance offsets, imports) and EBXX. The data
# is a flat block of bare structs; nothing in it says what any instance IS. The
# EFIX names each instance's type, and the exe's type database says what fields
# that type has and where. All three are needed before a single value can be
# read, which is why this arrives last of the readers.
#
#   parse(bytes)                    -> the EFIX tables
#   read_instance(i)                -> {nameHash: value} for instance i
#
# Several of the comments below record bugs that cost real placements. They are
# kept verbatim from the Python because every one of them is a mistake that
# produced PLAUSIBLE output — the kind this port could silently reintroduce.

# The type reader is INJECTED rather than preloaded. It holds a 169 MB exe and a
# layout cache, and every consumer in a level walk has to share one — a preload
# here would invite a second instance per partition and re-read the executable
# for each.

# Element stride by type enum, for arrays. Kept beside the scalar cases
# in _decode deliberately: an array element and a lone field of the same type
# must be read the same way, and once were not.
const ELEM_SIZE := {
	0x0A: 1,                       # Bool — flat bytes, NOT u32
	0x0B: 1, 0x0C: 1,              # Int8 / Uint8
	0x0D: 2, 0x0E: 2,              # Int16 / Uint16
	0x0F: 4, 0x10: 4, 0x08: 4,     # Int32 / Uint32 / enum
	0x11: 8, 0x12: 8,              # Int64 / Uint64
	0x13: 4, 0x14: 8,              # Float32 / Float64
}

const MAX_DEPTH := 6
const MAX_ARRAY := 100000

var error := ""
var data := PackedByteArray()
var payload := 0
var partition_guid := ""
var type_guids: Array = []
var type_signatures: Array = []
var exported_instance_count := 0
var instance_offsets: Array = []
var imports: Array = []              # [{partition, instance}]
var resource_refs: Array = []

var _types = null                    # bf6_types.gd
var _guid_index := {}                # import partition guid -> ebx name
var _inst_map := {}                  # payload offset -> instance index
var _inst_type := {}                 # instance index -> type guid bytes
var _lay_cache := {}


# `layout_cache` is accepted from the caller so it can OUTLIVE one partition.
#
# Type layouts are global — a type has the same fields wherever it appears — but
# this cache used to be per-EBX, so a map that opens 11,748 partitions resolved
# and re-copied the same layouts once per partition. layout_full() hands back a
# deep copy on every call, so that is not just a lookup being repeated, it is a
# fields array being duplicated tens of thousands of times.
#
# Passing one in rather than making it static keeps it tied to the types reader
# that filled it: two readers over different executables have different layouts
# for the same guid, and a static cache would silently serve one to the other.
func _init(types_reader = null, guid_index := {}, layout_cache := {}) -> void:
	_types = types_reader
	_guid_index = guid_index
	_lay_cache = layout_cache


static func guid_str(b: PackedByteArray) -> String:
	# .NET Guid mixed-endian: first three groups little-endian, last 8 as-is.
	if b.size() < 16:
		return ""
	return "%08x-%04x-%04x-%s-%s" % [b.decode_u32(0), b.decode_u16(4),
			b.decode_u16(6), b.slice(8, 10).hex_encode(),
			b.slice(10, 16).hex_encode()]


func riff_chunks(d: PackedByteArray) -> Dictionary:
	if d.size() < 12 or d.slice(0, 4).get_string_from_ascii() != "RIFF":
		return {}
	var out := {}
	var o := 12
	while o + 8 <= d.size():
		var cid := d.slice(o, o + 4).get_string_from_ascii()
		var sz := int(d.decode_u32(o + 4))
		out[cid] = [o + 8, sz]
		o += 8 + sz
		if o % 2 == 1:
			o += 1
	return out


func parse(d: PackedByteArray) -> bool:
	error = ""
	data = d
	var chunks := riff_chunks(d)
	if not chunks.has("EBXD") or not chunks.has("EFIX"):
		error = "not a RIFF-EBX partition"
		return false
	var ebxd: Array = chunks["EBXD"]
	payload = _align_up(int(ebxd[0]), 16)

	var s := int((chunks["EFIX"] as Array)[0])
	partition_guid = guid_str(d.slice(s, s + 16))
	s += 16

	var n := int(d.decode_u32(s)); s += 4
	type_guids.clear()
	for i in range(n):
		type_guids.append(d.slice(s, s + 16))
		s += 16
	n = int(d.decode_u32(s)); s += 4
	type_signatures.clear()
	for i in range(n):
		type_signatures.append(int(d.decode_u32(s)))
		s += 4

	exported_instance_count = int(d.decode_u32(s)); s += 4
	n = int(d.decode_u32(s)); s += 4
	instance_offsets.clear()
	for i in range(n):
		instance_offsets.append(int(d.decode_u32(s)))
		s += 4
	# pointer offsets, resource-ref offsets: read to advance, and the latter is
	# needed for resource_refs below.
	n = int(d.decode_u32(s)); s += 4
	s += n * 4                                        # pointer_offsets
	n = int(d.decode_u32(s)); s += 4
	var res_off: Array = []
	for i in range(n):
		res_off.append(int(d.decode_u32(s)))
		s += 4

	n = int(d.decode_u32(s)); s += 4
	imports.clear()
	for i in range(n):
		var pg := d.slice(s, s + 16); s += 16
		var ig := d.slice(s, s + 16); s += 16
		imports.append({"partition": guid_str(pg), "instance": guid_str(ig)})

	# The remaining tables are not needed here; the EBXD block is what matters.
	var dstart := int(ebxd[0])
	var dsize := int(ebxd[1])
	resource_refs.clear()
	for off in res_off:
		if dstart + int(off) + 8 <= d.size():
			resource_refs.append(int(d.decode_u64(dstart + int(off))))

	_inst_map.clear()
	_inst_type.clear()
	for i in range(instance_offsets.size()):
		var off: int = instance_offsets[i]
		_inst_map[off] = i
		var p := payload + off
		if p + 2 <= d.size():
			var tr := int(d.decode_u16(p))
			_inst_type[i] = type_guids[tr] if tr < type_guids.size() else null
		else:
			_inst_type[i] = null
	return true


# The instance GUID for instance `i`, or "" when it has none.
#
# EBX_RIFF.md 5: the GUID is the 16 bytes immediately BEFORE the instance's
# image start, and only the first ExportedInstanceCount instances carry one —
# internal instances have no identity and are not addressable from another
# partition. The network registry names placements by (partition, instance), so
# this is what makes a placement matchable against it.
func instance_guid(i: int) -> String:
	if i >= exported_instance_count or i >= instance_offsets.size():
		return ""
	var off: int = payload + int(instance_offsets[i])
	if off < 16 or off > data.size():
		return ""
	return guid_str(data.slice(off - 16, off))


func instance_type(i: int) -> String:
	var g = _inst_type.get(i)
	return guid_str(g) if g != null else ""


# The RAW type guid, for callers that want to look a layout up rather than
# compare a string. instance_type() formats one every call, and a caller doing
# that per instance across a map pays for a quarter of a million string builds
# it then only uses as a dictionary key.
func instance_type_bytes(i: int) -> PackedByteArray:
	var g = _inst_type.get(i)
	return g if g != null else PackedByteArray()


func read_instance(idx: int, depth := 0) -> Dictionary:
	if idx < 0 or idx >= instance_offsets.size():
		return {}
	var g = _inst_type.get(idx)
	if g == null:
		return {}
	return _read_struct(g, payload + int(instance_offsets[idx]), depth)


func _layout(guid: PackedByteArray) -> Dictionary:
	var k := guid.hex_encode()
	if not _lay_cache.has(k):
		_lay_cache[k] = _types.layout_full(guid)
	return _lay_cache[k]


func _read_struct(guid: PackedByteArray, base: int, depth: int) -> Dictionary:
	var lay := _layout(guid)
	if lay.is_empty() or depth > MAX_DEPTH:
		return {}
	var out := {"__type": guid_str(guid)}
	for fld in lay["fields"]:
		var pos: int = base + int(fld["offset"])
		# A FIELD THAT LANDS OUTSIDE THE FILE MUST NOT COST THE WHOLE INSTANCE.
		# An instance is usually many fields and the one being looked for is
		# rarely the broken one. Losing a streetlight because a SIBLING field
		# was unreadable is how 395 placements went missing while every step
		# still reported success.
		if pos < 0 or pos + 8 > data.size():
			out[int(fld["nameHash"])] = null
			continue
		out[int(fld["nameHash"])] = _decode(pos, int(fld["typeVA"]), depth)
	return out


func _decode(pos: int, type_va: int, depth: int):
	var rt: Dictionary = _types.resolve(type_va)
	if rt.is_empty():
		return null
	var te := int(rt["te"])
	match te:
		0x04: return _read_array(pos, int(rt["elemVA"]), depth)
		0x03, 0x01: return _pointer_ref(pos)          # Class / DbObject
		0x02: return _read_struct(rt["guid_raw"], pos, depth + 1)
		0x07: return _cstring(pos)
		0x17: return {"resref": int(data.decode_u64(pos))}
		0x06:
			var e := pos
			while e < data.size() and e < pos + 32 and data[e] != 0:
				e += 1
			return data.slice(pos, e).get_string_from_ascii()
		0x15: return {"guid": data.slice(pos, pos + 16).hex_encode()}
		0x0A: return data[pos] != 0
		0x0B: return int(data.decode_s8(pos))
		0x0C: return int(data[pos])
		0x0D: return int(data.decode_s16(pos))
		0x0E: return int(data.decode_u16(pos))
		0x0F: return int(data.decode_s32(pos))
		0x10, 0x08: return int(data.decode_u32(pos))
		0x11: return int(data.decode_s64(pos))
		0x12: return int(data.decode_u64(pos))
		0x13: return data.decode_float(pos)
		0x14: return data.decode_double(pos)
	return {"te": te, "raw": int(data.decode_u32(pos))}


func _pointer_ref(pos: int):
	# THE RELATIVE OFFSET IS A SIGNED 32-BIT VALUE in an 8-byte slot, the upper
	# half zero. Read 8 bytes wide and every NEGATIVE offset — a reference to an
	# instance earlier in the payload — zero-extends into a huge positive number
	# that lands nowhere, so the ref silently resolves to null instead of
	# erroring.
	#
	# Most references point backward, so that lost nearly all of them:
	#   gameplay.ebx   517 of 533 negative -> 16 resolved (3%)
	#   mil_hemtt_01   298 of 303 negative ->  4 resolved (1%)
	#   mp_dumbo.ebx    49 of  50 negative ->  1 resolved (2%)
	# Reading signed instead: 885 of 886, every partition.
	#
	# It hid because the level walk never needs an internal ref — it recurses
	# through blueprint IMPORTS, which take the `idx & 1` branch and were always
	# right. Only a rule following one SPECIFIC edge noticed, and then it looked
	# like missing data rather than a bad read.
	var idx := int(data.decode_s32(pos))
	if idx == 0:
		return null
	if idx & 1:
		var i := idx >> 1
		if i < 0 or i >= imports.size():
			return null
		var imp: Dictionary = imports[i]
		return {"import": imp["partition"],
				"path": _guid_index.get(imp["partition"], "<not indexed>")}
	var inst_off := (pos + idx) - payload
	var ii = _inst_map.get(inst_off)
	return {"instance": ii,
			"type": instance_type(ii) if ii != null else null}


func _cstring(pos: int) -> String:
	var off := int(data.decode_s64(pos))
	if off == -1:
		return ""
	var loc := pos + off
	if loc < 0 or loc >= data.size():
		return ""
	var e := loc
	var stop: int = mini(data.size(), loc + 512)
	while e < stop and data[e] != 0:
		e += 1
	return data.slice(loc, e).get_string_from_ascii()


func _read_array(pos: int, elem_va: int, depth: int) -> Array:
	var aoff := int(data.decode_s32(pos))
	var array_data := (pos + 4) + aoff - 8
	if array_data < 0 or array_data + 4 > data.size():
		return []
	var count := int(data.decode_s32(array_data))
	if count < 0 or count > MAX_ARRAY:
		return []
	var elem := array_data + 4
	var rt: Dictionary = _types.resolve(elem_va) if elem_va != 0 else {}
	var te := int(rt["te"]) if not rt.is_empty() else 0x10
	var items: Array = []

	if te == 0x02:
		var lay := _layout(rt["guid_raw"])
		if lay.is_empty():
			return []
		var sz := _align_up(int(lay["size"]), maxi(1, int(lay.get("align", 1))))
		for i in range(count):
			items.append(_read_struct(rt["guid_raw"], elem + i * sz, depth + 1))
	elif te == 0x03 or te == 0x01:
		for i in range(count):
			items.append(_pointer_ref(elem + i * 8))
	elif te == 0x07:
		for i in range(count):
			items.append(_cstring(elem + i * 8))
	else:
		# ELEMENT STRIDE FOLLOWS THE ELEMENT TYPE. This once read every
		# non-struct, non-pointer, non-string array as 4-byte u32, which is
		# right for ints and wrong for everything narrower. A bool array is flat
		# bytes, so a 4-byte stride reads element i from elem+i*4 and runs four
		# times past the end of the array into whatever follows. The values that
		# come back are plausible and meaningless.
		#
		# Cost, measured on mp_dumbo: StaticModelGroup `Visible` is a bool
		# array, so 5,762 instances were judged not-visible from garbage and
		# dropped — building facades among them, which is why rooms had their
		# windows and fittings but no walls.
		var sz: int = ELEM_SIZE.get(te, 4)
		for i in range(count):
			var p := elem + i * sz
			if p + sz > data.size():
				break
			items.append(_scalar(p, te))
	return items


func _scalar(p: int, te: int):
	match te:
		0x0A: return data[p] != 0
		0x0B: return int(data.decode_s8(p))
		0x0C: return int(data[p])
		0x0D: return int(data.decode_s16(p))
		0x0E: return int(data.decode_u16(p))
		0x0F: return int(data.decode_s32(p))
		0x11: return int(data.decode_s64(p))
		0x12: return int(data.decode_u64(p))
		0x13: return data.decode_float(p)
		0x14: return data.decode_double(p)
	return int(data.decode_u32(p))


func _align_up(v: int, a: int) -> int:
	return ((v + a - 1) & ~(a - 1)) if a != 0 else v
