@tool
extends RefCounted
class_name BF6Atlas

# ATLASTEXTURE (RES 0x957C32B1): the flipbook sheets the FX sample.
#
# Smoke, sparks, muzzle flashes, splashes, blood, light cookies. The RES payload
# is a HEADER ONLY - no pixels and no per-frame rectangles - and the pixels live
# in a chunk the header names.
#
# The layout is the research repo's, verified there over 131 distinct atlases
# from four level mounts (findings/atlastexture-92-byte-header):
#
#   0x00 u8       flags, unread
#   0x02 u16      WIDTH            128..4096
#   0x04 u16      HEIGHT           128..2048
#   0x06 u8       mip count        6..10
#   0x07 u8       unread, always >= 0x06
#   0x10 16 bytes GUID of the pixel chunk
#   0x20 u32 x 8  per-mip byte size, descending by /4, unused slots 0
#   0x40 28 bytes zero on 131/131
#
# Two of those are a joint test rather than three guesses: mip[0] == w*h and
# mip[i] == mip[i-1]/4 only holds if the u16 offsets AND the one-byte-per-texel
# reading are all correct at once. One byte per texel is 8 bpp, i.e. block
# compressed with 16-byte blocks over 4x4 texels.
#
# THE GUID INDEXES A CHUNK AS RAW HEX, not as the dashed .NET text form
# (findings/atlastexture-guid-resolves-as-a-chunk). That is now the second
# resource in this reader where a 16-byte GUID does so - the terrain chunk
# directory is the other - so raw hex is the expectation and dashed is the
# exception.

const RES_TYPE := 0x957C32B1
const HEADER_SIZE := 92

# THE GRID IS AUTHORED, NOT IN THE FILENAME. Every AtlasTexture RES has a
# same-named EBX holding one AtlasTextureAsset instance with these fields
# (findings/atlastexture-grid-and-sixway-packing). The WxN in the filename is
# columns by TOTAL FRAMES and is a redundant label on data that is already here
# - and the names are inconsistently ordered, so parsing them fails on sheets
# the EBX reads fine.
const F_COLUMNS := 3460462605      # AnimationColumnCount
const F_FRAMES := 866427092        # AnimationFrameCount
const F_LEFTRIGHT := 2836644381    # LeftRightTiles


# The header, or an empty dictionary when this payload is not one.
static func parse(d: PackedByteArray) -> Dictionary:
	if d.size() < HEADER_SIZE:
		return {}
	var w := int(d.decode_u16(0x02))
	var h := int(d.decode_u16(0x04))
	var mips := int(d.decode_u8(0x06))
	if w <= 0 or h <= 0 or mips <= 0 or mips > 16:
		return {}
	var sizes: Array = []
	for i in range(8):
		var s := int(d.decode_u32(0x20 + i * 4))
		if s == 0:
			break
		sizes.append(s)
	# THE JOINT TEST. If the offsets or the bpp assumption are wrong this fails
	# immediately, which is the whole reason to check it rather than trust the
	# fields: a wrong width that still produces a plausible image is the error
	# that survives review.
	if sizes.is_empty() or sizes[0] != w * h:
		return {}
	return {
		"width": w, "height": h, "mips": mips, "sizes": sizes,
		"guid": d.slice(0x10, 0x20).hex_encode(),
		"total": _sum(sizes),
	}


static func _sum(a: Array) -> int:
	var t := 0
	for v in a:
		t += int(v)
	return t


# Mip 0's bytes, straight out of the chunk the header names.
#
# The chunk is the mip chain with a little slack - measured at 160 bytes on
# t_clasticsmoke_tg1_8x64_01_d, 11,184,800 against a chain of 11,184,640 - so
# mip 0 is taken from the FRONT and the slack is left where it is rather than
# guessed at.
static func mip0(src, hdr: Dictionary) -> PackedByteArray:
	if hdr.is_empty() or src == null:
		return PackedByteArray()
	var g := str(hdr["guid"])
	if not src.has_chunk(g):
		return PackedByteArray()
	var raw: PackedByteArray = src.get_chunk(g)
	var want := int(hdr["sizes"][0])
	if raw.size() < want:
		return PackedByteArray()
	return raw.slice(0, want)


# An Image for mip 0, in a given block format.
#
# THE FORMAT IS NOT SETTLED and this deliberately takes it as an argument. The
# research repo tried both 8 bpp candidates: BC7 gives rainbow noise and BC3
# gives clean, plausible smoke shapes in implausible colours, with the left and
# right halves tinted differently. Correct shapes under both says the offset and
# the dimensions are right; wrong colour under the one that decodes cleanly says
# the sheet is CHANNEL-PACKED rather than a picture.
static func image(src, hdr: Dictionary, fmt := Image.FORMAT_DXT5) -> Image:
	var bytes := mip0(src, hdr)
	if bytes.is_empty():
		return null
	return Image.create_from_data(int(hdr["width"]), int(hdr["height"]),
		false, fmt, bytes)


# The authored grid: {"cols", "frames", "rows", "lr"}, or empty.
static func grid(src, types, gi: Dictionary, name: String) -> Dictionary:
	var raw: PackedByteArray = src.get_ebx(name)
	if raw.is_empty():
		return {}
	var e := BF6Ebx.new(types, gi)
	if not e.parse(raw) or e.instance_offsets.is_empty():
		return {}
	var v = e.read_instance(0)
	if typeof(v) != TYPE_DICTIONARY or not v.has(F_COLUMNS):
		return {}
	var cols := maxi(1, int(v.get(F_COLUMNS, 1)))
	var frames := maxi(1, int(v.get(F_FRAMES, 1)))
	return {
		"cols": cols, "frames": frames,
		"rows": int(ceil(float(frames) / float(cols))),
		"lr": bool(v.get(F_LEFTRIGHT, false)),
	}


# The frame rectangle in the DECODED sheet, in pixels.
#
# LeftRightTiles doubles the sheet horizontally: the same frames twice, left and
# right, as the two signs of a six-way lightmap. Only the left half is the
# lighting base and only the left half's alpha is the density - measured against
# a sheet whose right alpha is entirely empty while the effect plainly renders.
# So the usable width is halved before the columns are divided out.
static func frame_rect(hdr: Dictionary, g: Dictionary, frame: int) -> Rect2i:
	if hdr.is_empty() or g.is_empty():
		return Rect2i()
	var usable := int(hdr["width"]) / (2 if bool(g["lr"]) else 1)
	var cw := usable / int(g["cols"])
	var chh := int(hdr["height"]) / maxi(1, int(g["rows"]))
	var idx := clampi(frame, 0, int(g["frames"]) - 1)
	@warning_ignore("integer_division")
	var r := idx / int(g["cols"])
	var c := idx % int(g["cols"])
	return Rect2i(c * cw, r * chh, cw, chh)


# The lighting base: the whole sheet, cropped to the left half when the atlas
# sets LeftRightTiles. Alpha is the density.
static func base_image(src, hdr: Dictionary, g: Dictionary,
		fmt := Image.FORMAT_DXT5) -> Image:
	var img := image(src, hdr, fmt)
	if img == null:
		return null
	if g.is_empty() or not bool(g.get("lr", false)):
		return img
	img.decompress()
	return img.get_region(Rect2i(0, 0, img.get_width() / 2, img.get_height()))
