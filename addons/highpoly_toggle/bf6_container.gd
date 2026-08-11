@tool
extends RefCounted
class_name BF6Container

# Container primitives: the DICE header, DbObject, finding the game, and
# joining a CasFileId to a file on disk. Ported from fb_container.py and the
# CasReader half of fb_cas.py.
#
# Every top-level container (layout.toc, every SuperBundle *.toc, every
# initfs_*) opens with a fixed 556-byte header carrying an RSA signature. The
# spec says a reader may verify and log but need not block on it, so this skips
# it and parses the payload.

const DICE_MAGIC := [0x00CED100, 0x01CED100]
const DICE_HEADER := 556          # 4 + 4 + 256 + 258 + 34

# 2.2 DbType
const T_END := 0
const T_ARRAY := 1
const T_OBJECT := 2
const T_NULL := 4
const T_BOOL := 6
const T_STRING := 7
const T_INT := 8
const T_LONG := 9
const T_FLOAT := 11
const T_DOUBLE := 12
const T_TIMESTAMP := 13
const T_GUID := 15
const T_SHA1 := 16
const T_MATRIX44 := 17
const T_VECTOR4 := 18
const T_BLOB := 19
const T_ATTACHMENT := 20
const T_TIMESPAN := 21

const ANONYMOUS := 0x80
const TYPE_MASK := 0x1F

static var last_error := ""


static func strip_dice_header(d: PackedByteArray) -> PackedByteArray:
	if d.size() >= 4 and DICE_MAGIC.has(d.decode_u32(0)):
		return d.slice(DICE_HEADER)
	return d                                   # no header is legal


# LEB128. Returns [value, new_pos].
static func read_varint(d: PackedByteArray, pos: int) -> Array:
	var val := 0
	var shift := 0
	while true:
		if pos >= d.size():
			last_error = "varint ran off the end of the buffer"
			return [0, pos]
		var b := int(d[pos])
		pos += 1
		val |= (b & 0x7F) << shift
		if (b & 0x80) == 0:
			return [val, pos]
		shift += 7
		if shift > 63:
			last_error = "varint wider than 64 bits"
			return [0, pos]
	return [0, pos]


static func _cstr(d: PackedByteArray, pos: int) -> Array:
	var end := pos
	while end < d.size() and d[end] != 0:
		end += 1
	return [d.slice(pos, end).get_string_from_utf8(), end + 1]


# One framed field (2.1): [type][name?][payload] -> [name, value, pos, ok]
static func read_field(d: PackedByteArray, pos: int) -> Array:
	if pos >= d.size():
		last_error = "field header past the end of the buffer"
		return [null, null, pos, false]
	var tb := int(d[pos])
	pos += 1
	var t := tb & TYPE_MASK
	var name = null
	# An End field carries no name even when the anonymous bit is clear.
	if (tb & ANONYMOUS) == 0 and t != T_END:
		var r := _cstr(d, pos)
		name = r[0]
		pos = int(r[1])

	match t:
		T_END:
			return [null, null, pos, true]
		T_OBJECT, T_ARRAY:
			# 2.3: a varint byte-size, then fields until it is spent or an End
			# byte turns up. The size alone suffices; both are honoured.
			var rv := read_varint(d, pos)
			var size := int(rv[0])
			pos = int(rv[1])
			var end := pos + size
			if end > d.size():
				last_error = "container claims %d bytes, %d remain" % [size, d.size() - pos]
				return [name, null, pos, false]
			if t == T_OBJECT:
				var obj := {}
				while pos < end:
					var f := read_field(d, pos)
					if not bool(f[3]):
						return [name, null, pos, false]
					pos = int(f[2])
					if f[0] == null:
						break                  # End
					obj[f[0]] = f[1]           # anonymous fields are dropped
				return [name, obj, end, true]
			var arr := []
			while pos < end:
				var f2 := read_field(d, pos)
				if not bool(f2[3]):
					return [name, null, pos, false]
				pos = int(f2[2])
				if f2[0] == null and f2[1] == null:
					break
				arr.append(f2[1])
			return [name, arr, end, true]
		T_NULL:
			return [name, null, pos, true]
		T_BOOL:
			return [name, d[pos] != 0, pos + 1, true]
		T_STRING:
			# length INCLUDES the trailing NUL, stripped on read (2.2)
			var rs := read_varint(d, pos)
			var ln := int(rs[0])
			pos = int(rs[1])
			return [name, d.slice(pos, pos + ln - 1).get_string_from_utf8(),
					pos + ln, true]
		T_INT:
			return [name, d.decode_s32(pos), pos + 4, true]
		T_LONG, T_TIMESTAMP:
			return [name, d.decode_s64(pos), pos + 8, true]
		T_FLOAT:
			return [name, d.decode_float(pos), pos + 4, true]
		T_DOUBLE:
			return [name, d.decode_double(pos), pos + 8, true]
		T_GUID:
			return [name, d.slice(pos, pos + 16).hex_encode(), pos + 16, true]
		T_SHA1, T_ATTACHMENT:
			return [name, d.slice(pos, pos + 20).hex_encode(), pos + 20, true]
		T_MATRIX44:
			return [name, d.slice(pos, pos + 64), pos + 64, true]
		T_VECTOR4:
			return [name, d.slice(pos, pos + 16), pos + 16, true]
		T_BLOB:
			var rb := read_varint(d, pos)
			var lb := int(rb[0])
			pos = int(rb[1])
			return [name, d.slice(pos, pos + lb), pos + lb, true]
		T_TIMESPAN:
			var rt := read_varint(d, pos)
			var raw := int(rt[0])
			return [name, (raw >> 1) ^ -(raw & 1), int(rt[1]), true]
	# 3, 5, 10 and 14 are defined by the format and never appear in BF6.
	# Guessing a payload width here would desynchronise everything after it.
	last_error = "DbType %d is not present in BF6 data (at 0x%X)" % [t, pos - 1]
	return [name, null, pos, false]


static func read_dbobject(d: PackedByteArray):
	var f := read_field(strip_dice_header(d), 0)
	return f[1] if bool(f[3]) else null


# --- finding the game -------------------------------------------------------
# The point of reading from the install is that it works without being told
# where the install is. A manual override stays available because no amount of
# guessing covers every machine.
const CANDIDATES := [
	"C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6",
	"C:/Program Files/EA Games/Battlefield 6",
	"C:/Program Files (x86)/EA Games/Battlefield 6",
]


static func find_game(explicit := "") -> String:
	if explicit != "":
		if FileAccess.file_exists(explicit.path_join("Data/layout.toc")):
			return explicit
		last_error = "no Data/layout.toc under %s" % explicit
		return ""
	# THE FOLDER THE USER ALREADY POINTED US AT COMES FIRST, and its absence
	# here was a real bug that failed silently. The panel's gate verifies a
	# path through HighpolyGameDir (registry-aware, and it remembers whatever
	# Locate... chose) and reports "Battlefield 6 detected". This function is
	# what the READER uses, and it knew nothing about that path: it searched a
	# fixed candidate list plus a hard-coded C: Steam vdf. An install neither
	# covers therefore PASSED the gate and failed every read, and the failure
	# path un-pressed the layer chip while writing nothing to the log. From
	# the outside: "it says detected, but the map cannot be found and the
	# buttons do nothing".
	var seen: Array = []
	var chosen := HighpolyGameDir.saved()
	if chosen != "":
		seen.append(chosen)
	seen.append_array(CANDIDATES)
	# Steam libraries can be on any drive; libraryfolders.vdf lists them. The
	# root comes from the registry so a Steam that is not on C: is followed
	# too; the literal path stays as the fallback.
	var vdf := ""
	var sroot := HighpolyGameDir.steam_root()
	if sroot != "" and FileAccess.file_exists(
			sroot.path_join("steamapps/libraryfolders.vdf")):
		vdf = sroot.path_join("steamapps/libraryfolders.vdf")
	elif FileAccess.file_exists(
			"C:/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"):
		vdf = "C:/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
	if vdf != "":
		var txt := FileAccess.get_file_as_string(vdf)
		var re := RegEx.create_from_string('"path"\\s+"([^"]+)"')
		for m in re.search_all(txt):
			var base: String = m.get_string(1).replace("\\\\", "/").replace("\\", "/")
			seen.append(base.path_join("steamapps/common/Battlefield 6"))
	for p in seen:
		if FileAccess.file_exists(String(p).path_join("Data/layout.toc")):
			return p
	last_error = ("could not find a Battlefield 6 installation. Looked at the "
		+ "folder set in the panel (%s), %d known locations and every Steam "
		+ "library. Set the path at the top of the panel.") % [
			chosen if chosen != "" else "none set", CANDIDATES.size()]
	return ""


# --- CasFileId -> a path on disk (5.6) --------------------------------------
class CasLocator extends RefCounted:
	var game := ""
	var by_index := {}          # persistentIndex (u32) -> install chunk

	func _init(game_dir: String) -> void:
		game = game_dir
		var raw := FileAccess.get_file_as_bytes(game.path_join("Data/layout.toc"))
		var lay = BF6Container.read_dbobject(raw)
		if typeof(lay) != TYPE_DICTIONARY:
			return
		var im = lay.get("installManifest")
		if typeof(im) != TYPE_DICTIONARY:
			return
		for c in (im.get("installChunks") if im.has("installChunks") else []):
			if typeof(c) != TYPE_DICTIONARY:
				continue
			var pi = c.get("persistentIndex")
			if typeof(pi) == TYPE_INT:
				# SIGNEDNESS, and it costs an afternoon to miss. persistentIndex
				# is a DbObject Integer, a SIGNED i32, while the TOC reads
				# InstallChunkId as an UNSIGNED u32 BE. Same bits, opposite
				# reading: id 3190413859 is the chunk whose persistentIndex
				# reads -1104553437. Without normalising, every lookup misses
				# and every bundle reports "no cas file".
				by_index[int(pi) & 0xFFFFFFFF] = c

	func cas_path(install_chunk_id: int, cas_index: int) -> String:
		var c = by_index.get(install_chunk_id & 0xFFFFFFFF)
		if c == null:
			return ""
		# The spec gives contentPath [/ installBundle] / cas_NN.cas. BF6 spells
		# the folder in `installBundle`, and content lives under Data/ or under
		# an Update package, so both are tried.
		var bundle := str(c.get("installBundle") if c.has("installBundle") else "")
		var leaf := bundle.path_join("cas_%02d.cas" % cas_index)
		var cands := [game.path_join("Data").path_join(leaf)]
		var upd := game.path_join("Update")
		var da := DirAccess.open(upd)
		if da != null:
			for pkg in da.get_directories():
				cands.append(upd.path_join(pkg).path_join("Data").path_join(leaf))
		for p in cands:
			if FileAccess.file_exists(p):
				return p
		return ""
