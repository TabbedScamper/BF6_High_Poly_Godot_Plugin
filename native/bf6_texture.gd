extends RefCounted

# Textures straight from the game: TextureResource header -> chunk -> Image.
#
# The other half of a prop. fb_texture.py does this for the pipeline through PIL
# and a temporary DDS file; this is the same parse with the tail cut off, because
# Godot takes block-compressed data directly:
#
#   Python   header -> chunk -> synthesize a DDS -> PIL decode -> RGBA pixels
#   here     header -> chunk -> Image.create_from_data(BCn blocks)
#
# That is not just shorter. The blocks go to the GPU still compressed, which is
# what the VRAM modes want anyway — decompressing to RGBA in order to re-compress
# on upload is work the pipeline only does because PIL cannot hold a BCn image.
#
# A BF6 texture is a small res payload plus one or two chunks:
#
#   header (the .Texture res)   format, w/h, mip count, per-mip byte sizes
#   guid at +40                 the embedded chunk
#   guid at +164                the streamed high-resolution chunk
#
# WHICH ONE HOLDS MIP0 IS A HEADER BIT, NOT A GUESS. Measured over 4,000 texture
# resources, the split is exact:
#
#   bit 0x10 of byte 21 SET     embedded = the chain MINUS mip0 (tail mips)
#                               streamed = mip0, exactly, on its own
#   bit 0x10 CLEAR              embedded = the whole chain from mip0
#                               streamed = absent
#
# The old dump-based decoder could not use that rule — it kept the two chunks in
# separate stores, so it decoded whatever it had and reached for the streamed one
# only when the result came back under 512 px, a size heuristic standing in for a
# header bit. From the game there is one mount holding both and no heuristic.
#
# READING THE WHOLE CHUNK MATTERS MORE HERE THAN ANYWHERE ELSE. A mip-chained
# texture read through its bundle segment comes back as the resident sub-range
# only — measured 4x and 64x short — which is exactly the shape of a texture that
# decodes to a plausible but WRONG size.

const HDR_MIN := 56

# BF6 texture format -> DXGI. The reference implementation's table, not a second
# opinion: a second opinion is how two decoders drift apart.
const FMT := {
	6: 61, 18: 28, 29: 28, 40: 10, 54: 71, 55: 72, 56: 74, 57: 75, 58: 75,
	59: 77, 60: 78, 61: 78, 62: 80, 63: 83, 64: 96, 65: 96, 66: 98, 67: 99,
}

# DXGI -> Godot. The sRGB codes map to the same format as their UNORM twin
# because Godot carries colour space on the texture, not in the pixel format;
# `srgb` in the returned dictionary keeps the distinction the caller needs.
const DXGI_GODOT := {
	61: Image.FORMAT_R8,
	28: Image.FORMAT_RGBA8,
	10: Image.FORMAT_RGBAH,
	71: Image.FORMAT_DXT1, 72: Image.FORMAT_DXT1,
	74: Image.FORMAT_DXT3, 75: Image.FORMAT_DXT3,
	77: Image.FORMAT_DXT5, 78: Image.FORMAT_DXT5,
	80: Image.FORMAT_RGTC_R,
	83: Image.FORMAT_RGTC_RG,
	96: Image.FORMAT_BPTC_RGBF,
	98: Image.FORMAT_BPTC_RGBA, 99: Image.FORMAT_BPTC_RGBA,
}

const SRGB := {72: true, 75: true, 78: true, 99: true}

var error := ""


# -> {} when it is too short to be a TextureResource.
func header(d: PackedByteArray) -> Dictionary:
	if d.size() < HDR_MIN:
		return {}
	var fmt := int(d.decode_s32(12))
	# WIDTH IS AT 22 AND HEIGHT AT 24, which is the opposite of what
	# fb_texture.py's variable names said for as long as it has existed. Its
	# output was still right, by two mistakes cancelling: it read w and h the
	# wrong way round and then wrote them into the DDS header's dwHeight and
	# dwWidth slots in that same order, un-swapping them.
	#
	# This port followed the NAMES and came out transposed on every non-square
	# texture — 257 of 800 in the comparison run, invisible on the square ones.
	#
	# Settled by the pixels rather than by reading the code: a BCn texture
	# decoded at transposed dimensions is not a rotated image, because the 4x4
	# blocks are then read in the wrong order and the result is spatially
	# incoherent. Decoding 60 real non-square textures both ways and taking the
	# smoother one voted 60-0 for this order.
	var w := int(d.decode_u16(22))
	var h := int(d.decode_u16(24))
	var slices := maxi(1, int(d.decode_u16(28)))
	var mipcount := int(d[30])
	var sizes: Array[int] = []
	if d.size() >= 120 and mipcount > 0:
		for i in range(mini(15, mipcount)):
			sizes.append(int(d.decode_u32(56 + 4 * i)))
	return {
		"format": fmt,
		"dxgi": FMT.get(fmt, 0),
		"width": w, "height": h,
		"slices": slices,
		"mipcount": mipcount,
		"mip_sizes": sizes,
		"streamflag": int(d[21]),          # bit 0x10: mip0 is NOT embedded
		"embedded": d.slice(40, 56).hex_encode(),
		"streamed": d.slice(164, 180).hex_encode() if d.size() >= 180 else "",
	}


# Which chunk holds mip0. The header says so; nothing is guessed.
func which_chunk(hdr: Dictionary) -> String:
	if (int(hdr["streamflag"]) & 0x10) != 0 and str(hdr["streamed"]) != "":
		return "streamed"
	return "embedded"


# Which mip the chunk actually starts at, and therefore its dimensions.
# -> [Vector2i(w, h), first-mip bytes]
#
# Header-exact first (b30 = mipCount, u32[15]@56 = per-mip byte sizes, u16@28 =
# slices; chunks are front-ordered largest-mip-first with no padding), then the
# reference implementation's fallbacks.
func dims_for(hdr: Dictionary, pix: PackedByteArray) -> Array:
	var w := int(hdr["width"])
	var h := int(hdr["height"])
	var dxgi := int(hdr["dxgi"])
	var sizes: Array = hdr["mip_sizes"]
	var slices := int(hdr["slices"])
	var mipcount := int(hdr["mipcount"])

	# The streamed chunk is mip0 ON ITS OWN, so it matches no suffix-sum of the
	# mip table. Stated up front rather than left to the fallback below, which
	# does reach the same answer but by coincidence of ordering.
	if not sizes.is_empty() and pix.size() == int(sizes[0]) * slices:
		return [Vector2i(w, h), pix]
	if mipcount > 0 and sizes.size() == mipcount:
		var all_set := true
		for s in sizes:
			if int(s) == 0:
				all_set = false
				break
		if all_set:
			for fm in range(mipcount):
				var tail := 0
				for i in range(fm, mipcount):
					tail += int(sizes[i])
				if tail * slices == pix.size():
					return [Vector2i(maxi(1, w >> fm), maxi(1, h >> fm)),
							pix.slice(0, int(sizes[fm]))]

	# THE FALLBACKS BELOW ASSUME A BLOCK FORMAT and are wrong for the handful of
	# textures that are not one. Inherited from the reference implementation and
	# kept deliberately, because changing it here would put the two readers out
	# of step on exactly the cases neither handles well.
	#
	# Seen on a real asset: meshemitter_kickupdust_leopard_body, DXGI 10
	# (R16G16B16A16_FLOAT), declared 6x8 with slices=2 and a 768-byte chunk. The
	# header-exact path misses because sizes[0] * slices is 1536, not 768, so it
	# falls through to these candidates and picks 12x16 by block arithmetic that
	# means nothing for an uncompressed format. Both readers agree on 12x16 —
	# they are wrong together — and decode() then refuses to build the image
	# rather than rendering 768 bytes as if they were 1536.
	#
	# Refusing is the right behaviour. Fixing the dimensions properly means
	# handling slices, which nothing upstream needs yet.
	var cands := [Vector2i(w, h), Vector2i(w / 2, h / 2),
				  Vector2i(w / 4, h / 4), Vector2i(w * 2, h * 2)]
	for c in cands:
		if c.x > 0 and c.y > 0 and _chain_size(c.x, c.y, dxgi) == pix.size():
			return [c, pix]
	for c in cands:
		if c.x > 0 and c.y > 0 and _level_size(c.x, c.y, dxgi) == pix.size():
			return [c, pix]
	var best := Vector2i(0, 0)
	for c in cands:
		if c.x > 0 and c.y > 0 and _level_size(c.x, c.y, dxgi) <= pix.size():
			if c.x * c.y > best.x * best.y:
				best = c
	if best.x > 0:
		return [best, pix]
	if (int(hdr["streamflag"]) & 0x10) != 0:
		return [Vector2i(w / 2, h / 2), pix]
	return [Vector2i(w, h), pix]


# Bytes per 4x4 block.
#
# DELIBERATELY NOT A COPY of the reference's bpp1(), which answers 8 for BC2 and
# BC3 as well as BC1 and BC4. Those are 16-byte formats, and 8 is wrong for them.
# It has never mattered there because the two functions using it are only
# reachable when the header-exact path above fails, and that path matched
# 4,000 of 4,000 sampled textures — so the wrong branch is essentially dead code.
# Copying a known-wrong constant into a new reader to preserve bug-for-bug parity
# would be the wrong trade: this is checked against the Python over a real
# corpus, and if the fallback ever fires the comparison will say so.
func _block_bytes(dxgi: int) -> int:
	return 8 if dxgi in [71, 72, 80] else 16


func _level_size(w: int, h: int, dxgi: int) -> int:
	return maxi(1, (w + 3) / 4) * maxi(1, (h + 3) / 4) * _block_bytes(dxgi)


func _chain_size(w: int, h: int, dxgi: int) -> int:
	var t := 0
	var cw := w
	var ch := h
	while true:
		t += _level_size(cw, ch, dxgi)
		if cw <= 1 and ch <= 1:
			break
		cw = maxi(1, cw / 2)
		ch = maxi(1, ch / 2)
	return t


# Both GUID spellings, as everywhere else chunks are addressed. A ChunkId is
# stored plain but indexed reversed in places, and forgetting it fails on a
# SUBSET of textures rather than all of them.
static func chunk_forms(guid_hex: String) -> Array:
	if guid_hex == "" or guid_hex == "0".repeat(32):
		return []
	var raw := PackedByteArray()
	for i in range(0, guid_hex.length(), 2):
		raw.append(guid_hex.substr(i, 2).hex_to_int())
	var rev := PackedByteArray(raw)
	rev.reverse()
	return [raw.hex_encode(), rev.hex_encode()]


# A texture as an Image at full resolution, read entirely from the game.
#
# `fetch` is a Callable taking a guid hex string and returning its bytes (empty
# when absent) — the source knows how to find a chunk, this reader does not.
#
# Tries the chunk the header nominates, then the other. The fallback is not a
# preference: if mip0's chunk is genuinely absent, decoding the tail mips gives a
# smaller but correct image, which beats returning nothing.
func decode(res: PackedByteArray, fetch: Callable) -> Dictionary:
	error = ""
	var hdr := header(res)
	if hdr.is_empty() or int(hdr["dxgi"]) == 0:
		error = "not a texture, or an unmapped format"
		return {}
	var gfmt: int = DXGI_GODOT.get(int(hdr["dxgi"]), -1)
	if gfmt < 0:
		error = "DXGI %d has no Godot format" % int(hdr["dxgi"])
		return {}

	var first := which_chunk(hdr)
	var order := [first, "embedded" if first == "streamed" else "streamed"]
	var why := ""                    # what actually went wrong, for the caller
	for which in order:
		var pix := PackedByteArray()
		for form in chunk_forms(str(hdr[which])):
			var got = fetch.call(str(form))
			if got is PackedByteArray and not (got as PackedByteArray).is_empty():
				pix = got
				break
		if pix.is_empty():
			continue
		var dd := dims_for(hdr, pix)
		var dim: Vector2i = dd[0]
		var top: PackedByteArray = dd[1]
		if dim.x <= 0 or dim.y <= 0:
			continue
		# create_from_data VALIDATES the length against the format, so a
		# mis-sized chunk fails here rather than rendering as garbage.
		var need := _level_size(dim.x, dim.y, int(hdr["dxgi"]))
		if gfmt == Image.FORMAT_R8:
			need = dim.x * dim.y
		elif gfmt == Image.FORMAT_RGBA8:
			need = dim.x * dim.y * 4
		elif gfmt == Image.FORMAT_RGBAH:
			need = dim.x * dim.y * 8
		if top.size() < need:
			# NOT the same failure as a missing chunk, and saying so matters:
			# this one means the dimensions were guessed wrong, which happens
			# when dims_for falls through to its block-format candidates on a
			# format that has no blocks. Reporting it as "chunk unavailable"
			# sends the next person looking in the mount for a chunk that is
			# sitting right there.
			why = ("%s chunk holds %d bytes, %dx%d of DXGI %d needs %d"
					% [which, top.size(), dim.x, dim.y, int(hdr["dxgi"]), need])
			continue
		# EVERY SLICE, not just the first. A cubemap is six faces in one chunk
		# and taking `need` bytes off the front yields face 0 — a perfectly
		# valid-looking image that is one sixth of the asset. This originally
		# returned exactly that and reported success, which is worse than
		# failing: the reflection volume would have looked like a texture that
		# was merely wrong rather than one that was five sixths missing.
		var slices := int(hdr["slices"])
		var images: Array[Image] = []
		for si in range(slices):
			var a := si * need
			if a + need > top.size():
				break
			var im := Image.create_from_data(dim.x, dim.y, false, gfmt,
					top.slice(a, a + need))
			if im == null:
				break
			images.append(im)
		if images.is_empty():
			why = "Image.create_from_data rejected %dx%d of DXGI %d" % [
					dim.x, dim.y, int(hdr["dxgi"])]
			continue
		return {"image": images[0], "images": images,
				"slices": images.size(), "width": dim.x, "height": dim.y,
				"dxgi": int(hdr["dxgi"]), "format": gfmt,
				"srgb": SRGB.has(int(hdr["dxgi"])), "chunk": which,
				"bytes": need}
	error = why if why != "" else "neither chunk was available"
	return {}
