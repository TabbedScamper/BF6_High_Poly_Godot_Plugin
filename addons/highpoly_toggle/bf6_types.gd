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
var file_size := 0                # the executable's size on disk
var data_short := false           # the read came back smaller than the file
# TYPE LOOKUPS THAT FOUND NOTHING, anywhere in the executable. A lookup already
# falls back from the typeinfo section to the whole file, so a miss means the
# type's id is genuinely absent from these bytes - the database and the level
# data disagree. This is the number that says so out loud instead of letting it
# surface as a map with no objects in it.
var n_miss := 0

# ---------------------------------------------------------------------------
# type database: read the schema from a generated file, not the executable
# ---------------------------------------------------------------------------
# The type schema (which fields a type has, at what offsets) is a property of
# the GAME BUILD, not the storefront: Steam and EA ship the same build, so the
# same table at the same virtual addresses. Steam leaves it plain on disk; EA
# wraps the executable in Origin DRM, so on an EA install this reader finds only
# ciphertext and every map comes back empty while meshes and terrain read fine.
#
# The escape is to stop reading the schema from each user's executable at all.
# Generated ONCE from a readable build, the schema serves every install. That is
# how Frosty works - it never reads types from the user's exe, it ships a profile.
#
# Two maps make it self-contained, because the decoder navigates the type graph
# two ways: by guid (layout_full) and by virtual address (resolve). Both are
# build-constant, so both replay verbatim against an EA install. NO DECRYPTION is
# involved: the file is generated from a plain Steam executable and read as data.
var _db_active := false                # serving from a database, not `data`
var _db_layouts := {}                  # guid_hex -> resolved layout_full dict
var _db_resolved := {}                 # type_va (int) -> resolve() dict
var _rec := false                      # record every answer, to build a database
var _db_meta := {}                     # exe_size, ti_size, entropy of the source
var from_db := false                   # diagnostics: this is a generated database
var lifted := false                    # the exe's DRM was decrypted in memory
var lift_note := ""                    # why a lift did or did not happen
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

	# HOW BIG IS IT ON DISK, asked BEFORE the read rather than trusted after.
	var fh := FileAccess.open(exe_path, FileAccess.READ)
	if fh != null:
		file_size = int(fh.get_length())
		fh.close()
	data = FileAccess.get_file_as_bytes(exe_path)
	if data.size() < 0x40:
		error = "%s is too small to be a PE" % exe_path
		return false
	# A SHORT READ IS AN ERROR, NOT A SMALLER DATABASE. Every type lookup is a
	# byte scan of this buffer, so a partial read does not fail: it silently
	# resolves nothing, every instance becomes "a type I cannot describe", and
	# the map opens with terrain and textures perfect and no objects at all. On
	# a 176 MB read that is exactly the shape of a machine short on memory, and
	# nothing here checked it. Better a named failure than a plausible empty map.
	if file_size > 0 and data.size() < file_size:
		error = ("only %d of %d bytes of %s could be read, so the type database "
			+ "is incomplete. This usually means the machine was short of "
			+ "memory. Close some applications and try again.") % [
				data.size(), file_size, exe_path.get_file()]
		data_short = true
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

	# SEAMLESS DRM LIFT. EA App builds wrap the executable in Origin DRM, so the
	# type sections read as ciphertext on disk and the whole map comes back empty.
	# When the type table looks encrypted, decrypt it IN MEMORY using the user's
	# own licence file, so everything below reads plain bytes exactly as on a
	# Steam install - no database, no shipped file, no manual step. Reads only
	# what the user already owns: their own executable, their own licence. Static
	# file work, never the running game.
	if ti_found and _looks_encrypted():
		lifted = _lift_in_memory()
	return true


# IS THE TYPE TABLE READABLE BYTES, OR CIPHERTEXT?
#
# When lookups miss on a fully-read file, there are only two candidates left: the
# ids are genuinely absent, or the region holding them is encrypted or packed on
# disk and only decrypted when the game runs. Those are indistinguishable from
# any count, and identical from the outside - a game that boots perfectly while
# this reader finds nothing.
#
# Shannon entropy separates them outright. Our own type table measures about 3.4
# bits per byte with roughly two thirds zero bytes, because it is structured
# records with padding. Encrypted or compressed data sits near 8.0 with almost no
# zeros. The only genuinely opaque region in our executable is the 0.22 MB
# anti-tamper stub at 7.96, so the difference is not subtle.
#
# ON DEMAND, never at open. A healthy install must not pay for a diagnostic it
# will never print, and a megabyte is enough to be decisive.
func ti_entropy(sample := 1048576) -> Dictionary:
	# In database mode there is no `data` to measure; report the source build's
	# figure so diagnostics read as the plain schema they actually describe.
	if _db_active:
		return {"bits": float(_db_meta.get("entropy", 3.4)),
			"zeros": float(_db_meta.get("zeros", 65.0)), "sampled": 0}
	var start: int = _ti_off
	var count: int = mini(sample, maxi(0, _ti_end - _ti_off))
	if count <= 0 or start + count > data.size():
		return {}
	var counts := PackedInt32Array()
	counts.resize(256)
	for i in range(start, start + count):
		counts[data[i]] += 1
	var h := 0.0
	for c in counts:
		if c > 0:
			var p := float(c) / float(count)
			h -= p * (log(p) / log(2.0))
	return {"bits": h, "zeros": 100.0 * float(counts[0]) / float(count),
		"sampled": count}


func section(name: String) -> Array:
	for s in sections:
		if str(s[0]) == name:
			return s
	return []


# ---------------------------------------------------------------------------
# in-memory OOA lift (EA / Origin DRM)
# ---------------------------------------------------------------------------
# Ported from rse-ooa-decrypt (GPL-3.0, BigApex) and dfanz0r's BF6 port, run in
# Godot's own AES. Authorized Portal-editor work; each user decrypts only their
# own owned copy with their own licence, and the running game is never touched.

# Is the type table ciphertext? Plain schema is ~3.4 bits/byte; encrypted ~8.0.
func _looks_encrypted() -> bool:
	var e: Dictionary = ti_entropy(65536)
	return float(e.get("bits", 0.0)) > 7.5


func _aes_cbc(key: PackedByteArray, iv: PackedByteArray, buf: PackedByteArray) -> PackedByteArray:
	var a := AESContext.new()
	if a.start(AESContext.MODE_CBC_DECRYPT, key, iv) != OK:
		return PackedByteArray()
	var out := a.update(buf)          # length must be a multiple of 16
	a.finish()
	return out


# The DLF licence gives the per-section AES key. It lives beside the game's other
# EA Services data, is itself AES-CBC with a fixed key, and carries the real key
# as base64 inside a <CipherKey> tag.
func _section_key(content_id: String) -> PackedByteArray:
	var dlf_key := PackedByteArray([65, 50, 114, 45, 208, 130, 239, 176,
		220, 100, 87, 197, 118, 104, 202, 9])
	var zero := PackedByteArray(); zero.resize(16)
	var pd := OS.get_environment("ProgramData")
	if pd == "":
		pd = "C:/ProgramData"
	var base := pd.replace("\\", "/") + "/Electronic Arts/EA Services/License/"
	for cand in [base + content_id + ".dlf", base + content_id + "_cached.dlf"]:
		if not FileAccess.file_exists(cand):
			continue
		var raw := FileAccess.get_file_as_bytes(cand)
		for start in [0x41, 0]:
			if start >= raw.size():
				continue
			var body := raw.slice(start, raw.size() - ((raw.size() - start) % 16))
			var txt := _aes_cbc(dlf_key, zero, body).get_string_from_utf8()
			var tag := "<CipherKey>"
			var p := txt.find(tag)
			if p < 0:
				continue
			var kb := Marshalls.base64_to_raw(txt.substr(p + tag.length(), 24))
			if kb.size() >= 16:
				return kb.slice(0, 16)
	return PackedByteArray()


# Decrypt, in `data`, every section the .ooa metadata lists as encrypted. The map
# needs more than the schema pair: the type graph reaches into .data (and the
# reflection code lives in .text/ctr), so decrypting only typeinfo/fieldinf leaves
# the walk unable to descend. Decrypt them all.
func _lift_in_memory() -> bool:
	var ooa := section(".ooa")
	if ooa.is_empty():
		lift_note = "encrypted but no .ooa section - cannot lift"
		return false
	var ooa_off := int(ooa[3])
	# content_id: UTF-16 at .ooa + 0x42
	var cid := data.slice(ooa_off + 0x42, ooa_off + 0x42 + 0x200).get_string_from_utf16()
	for stop in ["\u0000", "\r", "\n"]:
		var ix := cid.find(stop)
		if ix >= 0:
			cid = cid.substr(0, ix)
	cid = cid.strip_edges()
	var key := _section_key(cid)
	if key.is_empty():
		lift_note = ("this is an EA (DRM) install and the licence file for '%s' "
			% cid + "was not found under %ProgramData%/Electronic Arts/EA "
			+ "Services/License/. Run the game once so EA writes it, then reopen.")
		return false
	# enc_blocks: count at .ooa+0x4EE, blocks from 0x4F0 stride 0x30, VA*0x100.
	var cnt := int(data[ooa_off + 0x4EE])
	if cnt < 1 or cnt > 10:
		lift_note = "unexpected enc_blocks count %d" % cnt
		return false
	var done := 0
	for i in range(cnt):
		var bva := int(data.decode_u32(ooa_off + 0x4F0 + i * 0x30)) * 0x100
		for s in sections:
			if int(s[1]) != bva:
				continue
			var ro := int(s[3]); var rs := int(s[4])
			if rs % 16 != 0 or ro < 16 or ro + rs > data.size():
				break
			var iv := data.slice(ro - 16, ro)
			var dec := _aes_cbc(key, iv, data.slice(ro, ro + rs))
			if dec.size() != rs:
				break
			# padding quirk: a trailing all-0x10 block decrypts to zeros
			var all10 := true
			for j in range(rs - 16, rs):
				if dec[j] != 0x10:
					all10 = false; break
			if all10:
				for j in range(rs - 16, rs):
					dec[j] = 0
			# Splice natively - a 145 MB byte-by-byte loop is far too slow.
			data = data.slice(0, ro) + dec + data.slice(ro + rs)
			done += 1
			break
	if not _looks_encrypted():
		lift_note = "decrypted %d DRM section(s) in memory" % done
		return true
	lift_note = "attempted the DRM lift but the type table is still encrypted"
	return false


# Turn recording on before a walk, so every layout and resolve this reader hands
# out is captured. Call once on a reader opened against a READABLE executable.
func record() -> void:
	_rec = true


# Write the recorded schema. Small: a few thousand types, not the 176 MB exe.
# entropy/zeros are carried so an install reading this file can report the source
# build's figures rather than a meaningless measurement of a database.
func save_db(path: String) -> bool:
	var e: Dictionary = ti_entropy()
	var blob := {
		"schema": 1,
		"layouts": _db_layouts,
		"resolved": _db_resolved,
		"meta": {"exe_size": file_size, "ti_size": ti_size,
			"entropy": float(e.get("bits", 3.4)),
			"zeros": float(e.get("zeros", 65.0)),
			"types": _db_layouts.size(), "resolved_n": _db_resolved.size()},
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		error = "could not write %s" % path
		return false
	f.store_var(blob)
	f.close()
	return true


# Serve the schema from a generated file instead of an executable. After this the
# reader answers layout_full/resolve without ever touching `data`, so it works on
# an install whose executable it cannot read - the whole point.
func open_db(path: String) -> bool:
	error = ""
	if not FileAccess.file_exists(path):
		error = "no type database at %s" % path
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		error = "could not read %s" % path
		return false
	var blob = f.get_var()
	f.close()
	if typeof(blob) != TYPE_DICTIONARY or not (blob as Dictionary).has("layouts"):
		error = "%s is not a type database" % path
		return false
	var d: Dictionary = blob
	_db_layouts = d.get("layouts", {})
	# store_var writes integer keys back as ints; guard against a float key drift
	# by rebuilding the resolved map with integer keys.
	_db_resolved = {}
	for k in (d.get("resolved", {}) as Dictionary):
		_db_resolved[int(k)] = (d["resolved"] as Dictionary)[k]
	_db_meta = d.get("meta", {})
	_db_active = true
	from_db = true
	ti_found = true
	ti_size = int(_db_meta.get("ti_size", 0))
	file_size = int(_db_meta.get("exe_size", 0))
	return true


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
		n_miss += 1
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
	# SERVED FROM THE DATABASE. The stored dict is already fully resolved (super
	# fields folded in), so there is nothing to compute and no `data` to read.
	# An absent key is an unknown type, which the walk counts and fails open on,
	# exactly as an executable miss would.
	if _db_active:
		return _copy(_db_layouts[key]) if _db_layouts.has(key) else {}
	if depth == 0 and _full_cache.has(key):
		return _copy(_full_cache[key])
	var lay := _layout_full_uncached(guid, depth)
	if depth == 0:
		_full_cache[key] = lay
		# RECORDED. Only the depth-0, super-folded result is stored, because that
		# is exactly what a consumer receives; nested calls are already folded in.
		if _rec and not lay.is_empty():
			_db_layouts[key] = _copy(lay)
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
	# SERVED FROM THE DATABASE. type_va is a build-constant address, valid on any
	# install of the same build, so a value recorded from Steam resolves an EA
	# install unchanged. An absent va is a type outside the recorded set.
	if _db_active:
		return _copy(_db_resolved[type_va]) if _db_resolved.has(type_va) else {}
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
	var out := {"guid": guid_str(guid), "guid_raw": guid, "flags": flags,
			"te": te, "cat": (flags >> 1) & 0xF, "elemVA": elem_va}
	if _rec:
		_db_resolved[type_va] = _copy(out)
	return out


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
	# GUARD "fields": layout dicts carry a fields array to deep-copy, but a
	# resolve() dict does not. Without this guard, _copy on a resolve result
	# read lay["fields"] as null and produced an empty dict - which is exactly
	# how a generated database ended up with 43 present-but-empty resolve
	# entries, so every array/nested decode failed and the walk could not
	# descend, on an install that had already decrypted perfectly.
	if lay.has("fields"):
		var fs: Array = []
		for f in lay["fields"]:
			fs.append((f as Dictionary).duplicate())
		out["fields"] = fs
	return out
