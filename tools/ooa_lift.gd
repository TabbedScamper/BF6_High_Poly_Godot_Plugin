@tool
extends SceneTree
# OOA LIFT (minimal): decrypt the DRM-wrapped type-schema sections of an EA
# bf6.exe so the schema can be read. Authorized Portal-editor tooling; the
# decryption is ported from rse-ooa-decrypt (GPL-3.0, BigApex), which a Portal
# team member already used for BF6.
#
# We never RUN the executable, only read its typeinfo/fieldinf sections as data,
# so this skips the whole PE reconstruction (entry point, imports, relocs,
# section-count) that the per-game .ooa parser exists for - the part most likely
# to differ on BF6. All we need:
#   content_id (fixed offset in .ooa) -> DLF licence -> section AES key,
#   then AES-128-CBC decrypt typeinfo and fieldinf, IV = the 16 bytes before
#   each section's raw data. Verified by entropy: 8.0 (ciphertext) -> ~3.4.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#       --script res://hp_test/ooa_lift.gd -- \
#       "C:/Program Files/EA Games/Battlefield 6/SP/bf6.exe" \
#       "C:/Program Files/EA Games/Battlefield 6/SP/bf6-unpacked.exe"

const SECTIONS := ["typeinfo", "fieldinf"]


# AES-128-CBC key for the DLF envelope itself (hardcoded in the tool, IV = 0).
static func _dlf_key() -> PackedByteArray:
	return PackedByteArray([65, 50, 114, 45, 208, 130, 239, 176,
		220, 100, 87, 197, 118, 104, 202, 9])


static func _zero_iv() -> PackedByteArray:
	var z := PackedByteArray(); z.resize(16); return z


func _entropy(d: PackedByteArray, off: int, n: int) -> float:
	n = mini(n, d.size() - off)
	if n <= 0:
		return -1.0
	var c := PackedInt32Array(); c.resize(256)
	for i in range(off, off + n):
		c[d[i]] += 1
	var h := 0.0
	for v in c:
		if v > 0:
			var p := float(v) / float(n)
			h -= p * (log(p) / log(2.0))
	return h


func _aes_cbc_dec(key: PackedByteArray, iv: PackedByteArray, buf: PackedByteArray) -> PackedByteArray:
	var a := AESContext.new()
	if a.start(AESContext.MODE_CBC_DECRYPT, key, iv) != OK:
		return PackedByteArray()
	var out := a.update(buf)     # buf length must be a multiple of 16
	a.finish()
	return out


# Find and decrypt the DLF, returning the 16-byte section key.
func _section_key(content_id: String) -> PackedByteArray:
	var pd := OS.get_environment("ProgramData")
	if pd == "":
		pd = "C:/ProgramData"
	var base := pd.replace("\\", "/") + "/Electronic Arts/EA Services/License/"
	for cand in [base + content_id + ".dlf", base + content_id + "_cached.dlf"]:
		if not FileAccess.file_exists(cand):
			continue
		var raw := FileAccess.get_file_as_bytes(cand)
		# The tool decrypts data[0x41..] first, falling back to the whole file.
		for start in [0x41, 0]:
			if start >= raw.size():
				continue
			var body := raw.slice(start, raw.size() - ((raw.size() - start) % 16))
			var dec := _aes_cbc_dec(_dlf_key(), _zero_iv(), body)
			var txt := dec.get_string_from_utf8()
			var tag := "<CipherKey>"
			var p := txt.find(tag)
			if p < 0:
				continue
			p += tag.length()
			var b64 := txt.substr(p, 24)
			var kb := Marshalls.base64_to_raw(b64)
			if kb.size() >= 16:
				print("  DLF: %s  key from <CipherKey>" % cand.get_file())
				return kb.slice(0, 16)
	return PackedByteArray()


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 1:
		print("need <ea bf6.exe> [out path]"); quit(1); return
	var exe := str(a[0])
	var out := str(a[1]) if a.size() > 1 else exe.get_basename() + "-unpacked.exe"

	if not FileAccess.file_exists(exe):
		print("no file at %s" % exe); quit(1); return
	var d := FileAccess.get_file_as_bytes(exe)
	print("read %d bytes" % d.size())

	# --- PE section table ---
	var pe := int(d.decode_u32(0x3c))
	var nsec := int(d.decode_u16(pe + 6))
	var optsz := int(d.decode_u16(pe + 20))
	var so := pe + 24 + optsz
	var secs := {}
	var ooa_off := -1
	for i in range(nsec):
		var o := so + i * 40
		var nm_b := d.slice(o, o + 8)
		while nm_b.size() > 0 and nm_b[nm_b.size() - 1] == 0:
			nm_b.resize(nm_b.size() - 1)
		var nm := nm_b.get_string_from_ascii()
		var rawsz := int(d.decode_u32(o + 16))
		var rawoff := int(d.decode_u32(o + 20))
		secs[nm] = {"rawoff": rawoff, "rawsz": rawsz}
		if nm == ".ooa":
			ooa_off = rawoff
	if ooa_off < 0:
		print("no .ooa section - is this actually an EA/OOA-wrapped exe?"); quit(1); return

	# --- content_id: UTF-16 string at .ooa + 0x42 (matches the tool) ---
	var cid_bytes := d.slice(ooa_off + 0x42, ooa_off + 0x42 + 0x200)
	var content_id := cid_bytes.get_string_from_utf16()
	content_id = content_id.strip_edges()
	# keep only up to the first NUL-equivalent break
	for stop in ["\u0000", "\r", "\n"]:
		var ix := content_id.find(stop)
		if ix >= 0:
			content_id = content_id.substr(0, ix)
	print("content_id: '%s'" % content_id)

	var key := _section_key(content_id)
	if key.is_empty():
		print("could not obtain the section key from any DLF for '%s'." % content_id)
		print("Looked in %ProgramData%/Electronic Arts/EA Services/License/.")
		quit(1); return

	# --- decrypt the schema sections ---
	var ok := 0
	for name in SECTIONS:
		if not secs.has(name):
			print("  %-10s not present" % name); continue
		var s = secs[name]
		var ro: int = s["rawoff"]; var rs: int = s["rawsz"]
		var before := _entropy(d, ro, 65536)
		var iv := d.slice(ro - 16, ro)
		var enc := d.slice(ro, ro + rs)
		if enc.size() % 16 != 0:
			print("  %-10s raw size %d not a multiple of 16, skipping" % [name, rs]); continue
		var dec := _aes_cbc_dec(key, iv, enc)
		if dec.size() != enc.size():
			print("  %-10s decrypt failed" % name); continue
		# padding quirk: a trailing block of 0x10 bytes becomes zeros
		var tail_all_10 := true
		for j in range(dec.size() - 16, dec.size()):
			if dec[j] != 0x10:
				tail_all_10 = false; break
		if tail_all_10:
			for j in range(dec.size() - 16, dec.size()):
				dec[j] = 0
		for j in range(dec.size()):
			d[ro + j] = dec[j]
		var after := _entropy(d, ro, 65536)
		var good := after < 6.0
		print("  %-10s entropy %.2f -> %.2f   %s"
			% [name, before, after, "OK (plain)" if good else "STILL HIGH - scheme differs"])
		if good:
			ok += 1

	if ok == 0:
		print("")
		print("No section decrypted to plausible plaintext. The BF6 .ooa scheme")
		print("differs from what this port assumes (key source or IV). This is")
		print("the point where dfanz0r's specific BF6 tweak matters.")
		quit(1); return

	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		print("could not write %s" % out); quit(1); return
	f.store_buffer(d); f.close()
	print("")
	print("WROTE %s  (%d/%d schema sections decrypted)" % [out, ok, SECTIONS.size()])
	print("Point BF6Types / gen_typedb --exe at it.")
	quit(0)
