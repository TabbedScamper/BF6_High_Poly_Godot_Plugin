extends SceneTree

# MP_Aftermath's props.zip is 3.25 GB, and its ranged fetch failed outright:
#
#   19262 of 19262 entries needed (3321 MB), 134 ranged read(s)
#   ERROR  FAILED: Downloading the level's scenery (1/2)
#   WARN   ranged fetch delivered -1 of 19262, falling back to the archive
#
# Python's zipfile saturates a field at 2 GB, NOT 4 GB. So 7,239 of those
# entries store 0xFFFFFFFF as their offset and put the real one in a ZIP64
# extra field. The reader took the placeholder literally, every one of them
# claimed to start at byte 4294967295, they coalesced into a single run past
# the end of the file, and the empty response failed the whole fetch.
#
# The archive-level guard did not catch it because the archive-level fields
# were still real: at 3.25 GB the central directory offset fits in 32 bits.
# Only the per-entry offsets had spilled.
#
# So the fixture here is the shape that actually shipped, not the easy one:
# an entry BELOW the 2 GB line with real fields, and one above it saturated,
# in a directory whose own offsets are perfectly ordinary.

const ZipFetch = preload("res://addons/highpoly_toggle/highpoly_zipfetch.gd")

var fails := 0


func _init() -> void:
	# ---- an ordinary entry, nothing saturated ----------------------------
	var cd := PackedByteArray()
	cd.append_array(_cd_entry("under_2gb.glb", 0x40000000, 1000, 1000, false))
	# ---- and one past 2 GB, offset in the extra field --------------------
	var big := 0x9A000000          # 2.6 GB, over the line Python saturates at
	cd.append_array(_cd_entry("over_2gb.glb", big, 2000, 2000, true))

	var got: Array = ZipFetch._parse_cd(cd)
	_check("both entries parse (%d)" % got.size(), got.size() == 2)
	if got.size() != 2:
		_done(); return

	_check("the entry below 2 GB is unaffected (off %d)" % int(got[0]["off"]),
		int(got[0]["off"]) == 0x40000000)

	# THE REGRESSION. This read 4294967295 before, which is past the end of a
	# 3.25 GB file, so its range request came back empty and failed everything.
	_check("the entry past 2 GB resolves to its REAL offset (%d, not %d)"
		% [int(got[1]["off"]), 0xFFFFFFFF], int(got[1]["off"]) == big)
	_check("and its sizes survive (csize %d)" % int(got[1]["csize"]),
		int(got[1]["csize"]) == 2000)

	# A saturated field with no extra to resolve it is unreadable, not
	# something to guess at: the whole index is rejected so the caller falls
	# back to the archive instead of fetching from a made-up offset.
	var broken := _cd_entry("no_extra.glb", 0, 10, 10, true)
	broken = _strip_extra(broken)
	_check("a saturated entry with no ZIP64 extra rejects the whole index",
		(ZipFetch._parse_cd(broken) as Array).is_empty())

	_done()


func _done() -> void:
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


# One central-directory record. When `sat` is set the 32-bit offset carries the
# 0xFFFFFFFF placeholder and the real value goes in a 0x0001 extra field, which
# is exactly what Python writes for an entry past 2 GB.
func _cd_entry(name: String, off: int, csize: int, usize: int,
		sat: bool) -> PackedByteArray:
	var nm := name.to_utf8_buffer()
	var extra := PackedByteArray()
	if sat:
		extra.resize(4 + 8)
		extra.encode_u16(0, 0x0001)
		extra.encode_u16(2, 8)          # offset only: the sizes stayed real
		extra.encode_u64(4, off)
	var b := PackedByteArray()
	b.resize(46)
	b.encode_u32(0, 0x02014B50)
	b.encode_u16(10, 0)                 # STORED
	b.encode_u32(20, csize)
	b.encode_u32(24, usize)
	b.encode_u16(28, nm.size())
	b.encode_u16(30, extra.size())
	b.encode_u16(32, 0)
	b.encode_u32(42, 0xFFFFFFFF if sat else off)
	b.append_array(nm)
	b.append_array(extra)
	return b


func _strip_extra(rec: PackedByteArray) -> PackedByteArray:
	var nlen := rec.decode_u16(28)
	var out := rec.slice(0, 46 + nlen)
	out.encode_u16(30, 0)
	return out


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
