extends RefCounted
class_name BF6MeshSet      # see the note in bf6_ebx.gd on why these are named

# MeshSet geometry reader, in GDScript, reading the game's own bytes.
#
# The Python meshset_read.py has done this for the pipeline since the extractor
# started dying with EndOfStreamException on rail covers, grips, gadget
# projectiles and battle pickups. This is that reader ported, so Godot can turn
# a RES payload into a renderable mesh WITHOUT a 277 GB dump sitting between the
# game and the editor.
#
# Layout per formats/MESHSET_GEOMETRY.md in the shared research repo:
#   - the RES payload opens with a 16-byte leading header; EVERY stored offset
#     in the file is relative to that base, so absolute = stored + 16
#   - the MeshSet header carries LodOffsets[6], MeshType, LodCount, SectionCount
#   - each LOD record holds sectionCount/sectionOffset, index format, the
#     vertex/index buffer sizes and the geometry ChunkId
#   - each 368-byte section record holds material name, stride, primitive and
#     vertex counts, StartIndex, VertexOffset and two 100-byte geometry decls
#   - the chunk is [vertex buffer][index buffer]; vertex data is SoA per stream
#
# LOD RECORD SIZE IS READ, NOT ASSUMED. BF6 ships both 176-byte and 192-byte LOD
# records and hardcoding either misreads the other.
#
# PARITY WITH THE PYTHON IS THE POINT. Every other reader in this stack was
# accepted only after producing byte-identical output to its Python twin over a
# real corpus, and this one has to clear the same bar — the geometry it returns
# is what the whole overlay is made of, and a subtly wrong decode looks like a
# bad model rather than a bad reader.
#
#   parse(bytes)                -> Dictionary, header + lods + sections
#   read_lod(bytes, lod, chunk) -> Array of {material, verts, uvs, normals, idx}

const BASE := 16                  # every stored offset is relative to this
const SECTION_SIZE := 368
const DECL_SIZE := 100

# VertexElementUsage
const U_POS := 1
# BoneIndices. On a Rigid/Composite destructible this is the per-vertex
# DESTRUCTION PART index; on a Skinned mesh it is a skeleton bone id, which is a
# different and differently-sized space (MESHSET_GEOMETRY.md 5.2).
const U_BONE := 2
const U_NORMAL := 6
const U_UV0 := 33
const U_UV1 := 34
const U_UV4 := 37                    # TexCoord4 - the livery/ad unwrap slot
# SubMaterialIndex — the PER-VERTEX PALETTE SELECTOR. Engine enum value 51,
# which the research repo writes as 0x33 and which is NOT TexCoord0 (that is
# decimal 33 = 0x21, one line above). A UByte4 in a stream of its own; lane 0
# picks one of the eight entries of the 0xC2BB295A colour table, and the same
# lane is the tile-paint zone index. See DESTRUCTION.md 9.3.
const U_SUBMAT := 0x33

# VertexElementFormat -> byte size
const FMT_SIZE := {
	1: 4, 2: 8, 3: 12, 4: 16,          # Float / Float2 / Float3 / Float4
	5: 2, 6: 4, 7: 6, 8: 8,            # Half / Half2 / Half3 / Half4
	10: 4, 11: 4, 12: 4, 13: 4,        # Byte4 / Byte4N / UByte4 / UByte4N
	14: 2, 15: 4, 16: 6, 17: 8,        # Short..Short4
	18: 2, 19: 4, 20: 6, 21: 8,        # ShortN..Short4N
	22: 4, 23: 8, 24: 4, 25: 8,        # UShort2 / UShort4 / UShort2N / UShort4N
	50: 1,
}

var error := ""


# ---------------------------------------------------------------------------
# header
# ---------------------------------------------------------------------------

func parse(d: PackedByteArray) -> Dictionary:
	error = ""
	if d.size() < BASE + 0xA0:
		error = "too short to be a MeshSet (%d bytes)" % d.size()
		return {}
	var lod_stride := int(d.decode_u32(0))
	if lod_stride != 176 and lod_stride != 192:
		lod_stride = 176
	var h := BASE
	var lod_offs: Array[int] = []
	for i in range(6):
		lod_offs.append(int(d.decode_s64(h + 0x20 + i * 8)))
	var name := _cstr(d, int(d.decode_s64(h + 0x60)) + BASE)
	var mesh_type := d[h + 0x6C]
	var lod_count := int(d.decode_u16(h + 0x9C))
	var section_count := int(d.decode_u16(h + 0x9E))

	var lods: Array = []
	for li in range(mini(lod_count, 6)):
		var lo: int = lod_offs[li] + BASE
		if lo <= 0 or lo >= d.size() - lod_stride:
			continue
		var sec_count := int(d.decode_u32(lo + 0x08))
		var sec_off := int(d.decode_s64(lo + 0x0C)) + BASE
		var idx_fmt := int(d.decode_u32(lo + 0x54))
		var idx_size := int(d.decode_s32(lo + 0x58))
		var vtx_size := int(d.decode_s32(lo + 0x5C))
		var chunk := d.slice(lo + 0x74, lo + 0x84)
		var inline_off := int(d.decode_u32(lo + 0x84))
		var lname := _cstr(d, int(d.decode_s64(lo + 0x94)) + BASE)
		if sec_count > 4096 or sec_off <= 0 or sec_off >= d.size():
			continue
		lods.append({
			"index": li, "section_count": sec_count,
			"sections": _sections(d, sec_off, sec_count),
			"idx32": idx_fmt == 46, "index_size": idx_size,
			"vertex_size": vtx_size, "chunk_id": chunk,
			"name": lname, "inline_offset": inline_off,
		})
	return {"name": name, "mesh_type": mesh_type, "lod_count": lod_count,
			"section_count": section_count, "lod_stride": lod_stride,
			"lods": lods, "size": d.size()}


func _cstr(d: PackedByteArray, off: int) -> String:
	if off <= 0 or off >= d.size():
		return ""
	var e := d.find(0, off)
	if e < 0:
		e = d.size()
	return d.slice(off, e).get_string_from_ascii()


# 100-byte GeometryDeclaration -> {elements, streams}
func _decl(d: PackedByteArray, off: int) -> Dictionary:
	if off + DECL_SIZE > d.size():
		return {"elements": [], "streams": []}
	var els: Array = []
	for i in range(16):
		var p := off + i * 4
		els.append([d[p], d[p + 1], d[p + 2], d[p + 3]])   # usage, fmt, off, stream
	var strs: Array = []
	for i in range(16):
		var p := off + 64 + i * 2
		strs.append([d[p], d[p + 1]])                       # stride, classification
	var ne := d[off + 96]
	var ns := d[off + 97]
	return {"elements": els.slice(0, ne), "streams": strs.slice(0, ns)}


func _sections(d: PackedByteArray, off: int, count: int) -> Array:
	var out: Array = []
	for i in range(count):
		var p := off + i * SECTION_SIZE
		if p + SECTION_SIZE > d.size():
			break
		var mat := _cstr(d, int(d.decode_s64(p + 0x08)) + BASE)
		var bpv := d[p + 0x1A]                  # bonesPerVertex, after u16 count
		var decl := _decl(d, p + 0x64)
		if bpv > 0:
			# Skinned: the SECOND declaration adds the bone data and supersedes
			# the first, but only when it actually declares formats — an empty
			# one means the first is still the real thing.
			var d2 := _decl(d, p + 0xC8)
			var any := false
			for e in d2["elements"]:
				if int(e[1]) != 0:
					any = true
					break
			if any:
				decl = d2
		out.append({
			"index": i, "material": mat,
			# THE SHADER STATE KEY: the only link from a piece of geometry to
			# its textures. The ShaderBlockDepot holds no mesh guids and no
			# LOD/section tree — one blob is one material state — and the
			# binding lives here, inline on the section (the Frosty BF6 fork
			# reads it as `m_unknownHash1`). depot key table[state_key] -> the
			# record carrying this section's texture refs and constants.
			#
			# NOT the MVDB's SurfaceShaderGuid/Id: those name the shader ASSET
			# (nine distinct values across 4,454 entries) and appear nowhere in
			# the depot.
			"state_key": int(d.decode_u64(p + 0x130)),
			"material_id": int(d.decode_u16(p + 0x1C)),
			"stride": d[p + 0x1E],
			"prim_count": int(d.decode_u32(p + 0x20)),
			"start_index": int(d.decode_u32(p + 0x24)),
			"vertex_offset": int(d.decode_u32(p + 0x28)),
			"vertex_count": int(d.decode_u32(p + 0x2C)),
			"bones_per_vertex": bpv,
			"elements": decl["elements"], "streams": decl["streams"],
			# BOTH DECLARATIONS, because the BoneIndices element may live in
			# either one (MESHSET_GEOMETRY.md 5.1 says to search both) and the
			# choice above is about which one describes the POSITIONS.
			"decl0": _decl(d, p + 0x64), "decl1": _decl(d, p + 0xC8),
		})
	return out


# The MeshSet's own AxisAlignedBox at base+0x00 -> [min, max].
#
# Written by the game's own tools, which makes it an OUTSIDE ORACLE: the decode
# can be checked against it without the parse grading its own homework. The
# spec's size identity (VertexBufferSize == sum of vertexCount * stride) is NOT
# usable for this — it reports a mismatch on meshes the external extractor reads
# perfectly, so a correct parse would be rejected for being right.
func declared_box(d: PackedByteArray) -> Array:
	if d.size() < BASE + 32:
		return []
	return [Vector3(d.decode_float(BASE), d.decode_float(BASE + 4),
					d.decode_float(BASE + 8)),
			Vector3(d.decode_float(BASE + 16), d.decode_float(BASE + 20),
					d.decode_float(BASE + 24))]


# ---------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------

# Geometry for MeshSets that carry no chunk (ChunkId all zero).
#
# Those store the buffers inside the MeshSet itself, addressed by each LOD's
# InlineDataOffset. The offsets are relative to a common data base at the TAIL
# of the file, not to the file start: on smokegrenade_projectile the LOD offsets
# are 0 / 108528 / 163792 / 194432 and each equals the previous LOD's offset
# plus its own vertex+index sizes, so the base is recovered as
# filesize - (lastOffset + lastVertexSize + lastIndexSize).
func inline_buffer(d: PackedByteArray, info: Dictionary, L: Dictionary) -> PackedByteArray:
	var span := 0
	for x in info["lods"]:
		span = maxi(span, int(x["inline_offset"]) + int(x["vertex_size"])
				+ int(x["index_size"]))
	var base := d.size() - span
	if base < 0:
		error = "inline span %d exceeds file %d" % [span, d.size()]
		return PackedByteArray()
	var start: int = base + int(L["inline_offset"])
	return d.slice(start, start + int(L["vertex_size"]) + int(L["index_size"]))


static func chunk_forms(chunk_id: PackedByteArray) -> Array:
	"""Both spellings of a ChunkId.

	§4 of MESHSET_GEOMETRY.md: a LOD's ChunkId is stored plain, but chunk
	indexes are keyed reversed in places, so BOTH have to be tried. Forgetting
	it fails on a SUBSET of meshes rather than all of them, which is the worst
	kind of bug to find later.
	"""
	var fwd := chunk_id.hex_encode()
	var rev := PackedByteArray(chunk_id)
	rev.reverse()
	return [fwd, rev.hex_encode()]


# -> [{material, verts, uvs, normals, indices}] for renderable sections.
#
# `chunk` is the LOD's [vertex buffer][index buffer], which the caller fetches
# (the source knows how; this reader does not). Pass an empty array for an
# inline MeshSet and it will be recovered from the file itself.
# keep_all_uvs additionally emits "uv_all" per section - EVERY declared UV
# channel as its own PackedVector2Array, in declared order - for the object
# debugger, which lets a user flip a surface between channels live. Off by
# default because the build never needs more than the chosen channel and the
# copies are pure cost there.
func read_lod(d: PackedByteArray, lod := 0, chunk := PackedByteArray(),
		keep_shadow := false, keep_all_uvs := false) -> Array:
	error = ""
	var info := parse(d)
	if info.is_empty() or lod >= (info["lods"] as Array).size():
		return []
	var L: Dictionary = info["lods"][lod]

	var buf := chunk
	if buf.is_empty():
		buf = inline_buffer(d, info, L)
	var vsize := int(L["vertex_size"])
	var isize := int(L["index_size"])
	if buf.size() < vsize + isize:
		error = "geometry short: %d < %d+%d" % [buf.size(), vsize, isize]
		return []

	var idx32: bool = L["idx32"]
	var out: Array = []
	for s in L["sections"]:
		var vcount := int(s["vertex_count"])
		var pcount := int(s["prim_count"])
		if pcount == 0 or vcount == 0:
			continue
		var low := str(s["material"]).to_lower()
		if not keep_shadow and (low.contains("shadow") or low.contains("zonly")
				or low.contains("depth")):
			continue

		# EVERY UV channel, in declared order. BF6 props carry up to four: UV0
		# tiles across many units while a later channel is the per-object bake
		# unwrap that fits 0..1, and the material chain chooses between them.
		# Keeping only the first means a prop has no bake channel to find and is
		# textured with tiling coordinates whatever its material wanted —
		# stretched or repeated rather than missing, which is much harder to
		# spot than an absent texture.
		var voff := int(s["vertex_offset"])
		var streams: Array = s["streams"]
		var pos: PackedFloat32Array = PackedFloat32Array()
		var pos_comps := 0
		var nrm: PackedFloat32Array = PackedFloat32Array()
		var nrm_comps := 0
		var uv_sets: Array = []
		for el in s["elements"]:
			var usage := int(el[0])
			if usage == U_POS and pos.is_empty():
				var r := _read_attr(buf, voff, vcount, el, streams)
				if not r.is_empty():
					pos = r[0]
					pos_comps = r[1]
			elif usage == U_NORMAL and nrm.is_empty():
				var r2 := _read_attr(buf, voff, vcount, el, streams)
				if not r2.is_empty():
					nrm = r2[0]
					nrm_comps = r2[1]
			elif usage == U_UV0 or usage == U_UV1:
				var r3 := _read_attr(buf, voff, vcount, el, streams)
				if not r3.is_empty() and int(r3[1]) >= 2:
					uv_sets.append([r3[0], int(r3[1])])
		if pos.is_empty() or pos_comps < 3:
			continue

		var verts := PackedVector3Array()
		verts.resize(vcount)
		for i in range(vcount):
			var o := i * pos_comps
			verts[i] = Vector3(pos[o], pos[o + 1], pos[o + 2])

		# WHICH CHANNEL IS THE PRIMARY. Ported from the pipeline's fleet-proven
		# member_mesh.bake_uv_channel: the first channel BEYOND UV0 whose
		# coordinates fit 0..1 (0.05 tolerance) and are not degenerate is the
		# per-object bake unwrap the detail art is authored against; UV0 is
		# the tiling/weathering channel. Always taking channel 0 put the
		# delivery van's exterior and interior sheets on the tiling channel -
		# both channels fit 0..1 there but they are DIFFERENT unwraps
		# (measured max divergence 1.01), which read as "right textures,
		# wrong UVs" on a user marker. Car BODIES are untouched: their second
		# channel tiles, so the rule falls back to 0 exactly as before. The
		# whole prop fleet rendered through this rule and passed eyeball
		# review on the GLB pipeline, which is the measurement this port
		# stands on.
		var uvs := PackedVector2Array()
		if uv_sets.is_empty():
			uvs.resize(vcount)
		else:
			var upick := _bake_uv_channel(uv_sets, vcount)
			var src: PackedFloat32Array = uv_sets[upick][0]
			var c: int = uv_sets[upick][1]
			uvs.resize(vcount)
			for i in range(vcount):
				uvs[i] = Vector2(src[i * c], src[i * c + 1])

		# THE UNWRAP CHANNEL. UV0 tiles across many units; the unwrap is the
		# per-object 0..1 set that livery/ad art (a vehicle's *_unique sheet,
		# a trailer's billboard advert) is authored against. WHICH set that is
		# was cracked 2026-08-10: the section's SECOND 100-byte declaration
		# (declB) re-lists the canonical semantics and binds TexCoord4 to a
		# physical stream - its OWN stream when the mesh has a real unwrap,
		# or ALIASED onto TexCoord0's stream when it does not, in which case
		# the unwrap IS UV0. "The second declared UV set" is NOT the rule: on
		# the retail-sign class that set is an atlas slice and using it turns
		# the art 90 degrees. Godot has exactly one spare channel (UV2):
		#   - declB TC4 on its own stream  -> ship that set   (src "tc4")
		#   - declB TC4 aliased to TC0     -> unwrap is UV0   (src "uv0")
		#   - no TC4 in declB (or skinned) -> legacy second declared set
		var uv2 := PackedVector2Array()
		var uv2_src := ""
		var b_tc0: Array = []
		var b_tc4: Array = []
		for el4 in ((s["decl1"] as Dictionary)["elements"] as Array):
			if int(el4[0]) == U_UV0 and b_tc0.is_empty():
				b_tc0 = el4
			elif int(el4[0]) == U_UV4 and b_tc4.is_empty():
				b_tc4 = el4
		if not b_tc4.is_empty() and not b_tc0.is_empty():
			if int(b_tc4[3]) == int(b_tc0[3]) and int(b_tc4[2]) == int(b_tc0[2]):
				uv2_src = "uv0"
			else:
				var r4 := _read_attr(buf, voff, vcount, b_tc4, streams)
				if not r4.is_empty() and int(r4[1]) >= 2:
					var src4: PackedFloat32Array = r4[0]
					var c4 := int(r4[1])
					uv2.resize(vcount)
					for i in range(vcount):
						uv2[i] = Vector2(src4[i * c4], src4[i * c4 + 1])
					uv2_src = "tc4"
		if uv2_src == "" and uv_sets.size() > 1:
			var src2: PackedFloat32Array = uv_sets[1][0]
			var c2: int = uv_sets[1][1]
			uv2.resize(vcount)
			for i in range(vcount):
				uv2[i] = Vector2(src2[i * c2], src2[i * c2 + 1])
			uv2_src = "second"

		var normals := PackedVector3Array()
		if nrm_comps >= 3:
			normals.resize(vcount)
			for i in range(vcount):
				var o2 := i * nrm_comps
				normals[i] = Vector3(nrm[o2], nrm[o2 + 1], nrm[o2 + 2])

		var idx := _read_indices(buf, vsize, isize, idx32,
				int(s["start_index"]), pcount, vcount, voff)
		if idx.is_empty():
			continue

		# THE PER-VERTEX DESTRUCTION PART INDEX, when the mesh carries one.
		#
		# This is what lets a consumer hide the deflated tyre and the cracked
		# windscreen that are built into the intact car (DESTRUCTION.md 4). It is
		# read here rather than by the caller because only this function has the
		# vertex buffer and the stream layout to hand.
		var parts := _read_parts(buf, voff, vcount, s)
		# THE PER-VERTEX PALETTE ENTRY, when the mesh carries one. Read here for
		# the same reason `parts` is: only this function has the vertex buffer
		# and the stream table to hand.
		# [values, mask] — the mask has bit k set for every entry k the section
		# selects, and bit 8 for any value outside the table's eight. Folded here
		# because the caller wants the SET far more often than the values, and
		# building it a second time over 20 million vertices is the difference
		# between a scan and a cost.
		var pal := _read_sel(buf, voff, vcount, s)
		# state_key and material_id ride along: a caller that has decoded a
		# section still needs to know which depot record dresses it, and
		# re-parsing the file to find out would be absurd.
		var uv_all: Array = []
		if keep_all_uvs:
			for us in uv_sets:
				var sa: PackedFloat32Array = (us as Array)[0]
				var ca: int = (us as Array)[1]
				var pa := PackedVector2Array()
				pa.resize(vcount)
				for i in range(vcount):
					pa[i] = Vector2(sa[i * ca], sa[i * ca + 1])
				uv_all.append(pa)
		out.append({"material": s["material"], "verts": verts, "uvs": uvs,
					"uv2": uv2, "uv2_src": uv2_src, "uv_all": uv_all,
					"normals": normals, "indices": idx,
					"uv_sets": uv_sets.size(),
					"state_key": s.get("state_key", 0),
					"material_id": s.get("material_id", 0),
					"parts": parts,
					"pal": pal[0] if pal.size() == 2 else PackedByteArray(),
					"pal_mask": int(pal[1]) if pal.size() == 2 else 0})
	return out


# The BoneIndices element -> one part index per vertex, or an empty array.
#
# MESHSET_GEOMETRY.md 5.1, and three things in it are easy to get wrong:
#
#   SLOT 0 IS STORED LAST within the element, so the lane to read is
#   laneCount-1, not 0. Lane count comes from the format: UShort2 (22) and
#   UShort2N (24) are 2 lanes; Short4 (17), Short4N (21), UShort4 (23) and
#   UShort4N (25) are 4.
#
#   THE VALUE IS A DIRECT GLOBAL PART INDEX. The section's own u16 bone list is
#   the SET of part ids the section touches, not a palette to map through -
#   mapping through it corrupts exactly the vertices whose part id happens to
#   fall below the palette length, which is a partial and hard-to-spot
#   corruption. Measured against the authored part boxes, com_carsuv_01 goes
#   from 62.58% to 100.00% containment when the palette mapping is removed.
#
#   THE ELEMENT MAY BE IN EITHER DECLARATION, so both are searched.
#
# Read as RAW u16 rather than through _read_attr, which normalises the N
# formats and would turn part 17 into 0.00026.
func _read_parts(buf: PackedByteArray, base: int, count: int,
		s: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for which in ["decl0", "decl1"]:
		var dc = s.get(which)
		if not (dc is Dictionary):
			continue
		var els: Array = (dc as Dictionary)["elements"]
		var streams: Array = (dc as Dictionary)["streams"]
		for el in els:
			if int(el[0]) != U_BONE:
				continue
			var fmt := int(el[1])
			var lanes := 0
			if fmt == 22 or fmt == 24:
				lanes = 2
			elif fmt == 17 or fmt == 21 or fmt == 23 or fmt == 25:
				lanes = 4
			if lanes == 0:
				continue
			var off := int(el[2])
			var si := int(el[3])
			if si >= streams.size():
				continue
			var sstride := int(streams[si][0])
			if sstride == 0:
				continue
			var sbase := base
			for k in range(si):
				sbase += int(streams[k][0]) * count
			var lane_off := off + (lanes - 1) * 2
			if sbase + (count - 1) * sstride + lane_off + 2 > buf.size():
				continue
			out.resize(count)
			for i in range(count):
				var raw := int(buf.decode_u16(sbase + i * sstride + lane_off))
				# The 0x8000 remap is DECODED, UNVALIDATED - no sampled BF6 mesh
				# sets the bit. Masking it off is the safe reading either way.
				out[i] = raw & 0x7FFF
			return out
	return out


# The SubMaterialIndex element -> one palette entry per vertex, or an empty
# array when this section does not carry one.
#
# This is the selector DESTRUCTION.md 9.3 names for the eight-entry 0xC2BB295A
# colour table: without it a facade whose eight entries disagree has no way to
# say which of them a given vertex wants, and the whole table has to be thrown
# away. Measured on mp_dumbo: every renderable LOD0 section DECLARES the
# element, 3,520 of 7,900 can actually be read, and the values are 0..7 with 89%
# of vertices at entry 0.
#
# DECLARATION 0 FIRST, which is the opposite of _read_parts and is measured
# rather than stylistic. Both declarations name this element on those 3,520
# sections and agree on its stream, offset and stride everywhere they overlap;
# on the other 740 ONLY declaration 1 names it, and the stream it points at is
# not in the buffer, so reading it would be reading someone else's bytes. The
# bounds check is what rejects those, and trying decl0 first means the sections
# that CAN be read are not risked on the phantom.
#
# Format 12 is UByte4 and only lane 0 carries the entry — the other three lanes
# are zero on 99.9% of 20.1M sampled vertices.
func _read_sel(buf: PackedByteArray, base: int, count: int,
		s: Dictionary) -> Array:
	for which in ["decl0", "decl1"]:
		var dc = s.get(which)
		if not (dc is Dictionary):
			continue
		var els: Array = (dc as Dictionary)["elements"]
		var streams: Array = (dc as Dictionary)["streams"]
		for el in els:
			if int(el[0]) != U_SUBMAT or int(el[1]) != 12:
				continue
			var off := int(el[2])
			var si := int(el[3])
			if si >= streams.size():
				continue
			var sstride := int(streams[si][0])
			if sstride == 0:
				continue
			var sbase := base
			for k in range(si):
				sbase += int(streams[k][0]) * count
			if sbase + (count - 1) * sstride + off + 4 > buf.size():
				continue
			var out := PackedByteArray()
			out.resize(count)
			var mask := 0
			for i in range(count):
				var b := buf[sbase + i * sstride + off]
				out[i] = b
				mask |= 1 << (b if b < 8 else 8)
			return [out, mask]
	return []


func _read_indices(buf: PackedByteArray, vsize: int, isize: int, idx32: bool,
		start: int, prim_count: int, vcount: int, voff: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var stride := 4 if idx32 else 2
	var need := prim_count * 3
	var first := vsize + start * stride
	if first + need * stride > vsize + isize:
		return out

	var raw := PackedInt32Array()
	raw.resize(need)
	if idx32:
		for i in range(need):
			raw[i] = int(buf.decode_u32(first + i * 4))
	else:
		for i in range(need):
			raw[i] = int(buf.decode_u16(first + i * 2))

	# Spec 3.2: indices are normally section-local, but some LOD0s store
	# vertex-buffer-absolute values. Retry with VertexOffset removed, and only
	# keep the retry if it lands every index inside the section.
	var hi := 0
	for v in raw:
		hi = maxi(hi, v)
	if hi >= vcount and voff > 0:
		var ok := true
		for i in range(need):
			var v2 := raw[i] - voff
			if v2 < 0 or v2 >= vcount:
				ok = false
				break
		if ok:
			for i in range(need):
				raw[i] -= voff

	# Spec 3.3: the game winds CCW, Godot wants the opposite, so each triangle
	# is emitted with its last two indices swapped. Degenerate and
	# out-of-section triangles are dropped rather than clamped — a clamped index
	# makes a visible sliver that reads as a broken model.
	out.resize(need)
	var w := 0
	for t in range(prim_count):
		var a := raw[t * 3]
		var b := raw[t * 3 + 1]
		var c := raw[t * 3 + 2]
		if a < 0 or b < 0 or c < 0 or a >= vcount or b >= vcount or c >= vcount:
			continue
		if a == b or b == c or a == c:
			continue
		out[w] = a
		out[w + 1] = c
		out[w + 2] = b
		w += 3
	out.resize(w)
	return out


# Decode one vertex element across `count` vertices. -> [PackedFloat32Array,
# components] or [] when the element cannot be read.
#
# SoA PER STREAM: each stream's sub-buffer sits back to back from the section's
# VertexOffset, so a stream's base is the sum of every earlier stream's stride
# times the vertex count — NOT the section stride, which is the sum of all of
# them. Getting this wrong reads plausible-looking garbage rather than failing.
# The per-object bake channel, the pipeline's member_mesh.bake_uv_channel
# ported byte for byte in behaviour: first channel beyond UV0 fitting
# -0.05..1.05 on both axes with a span over 0.05 wins; anything else keeps
# UV0. The tolerance and the degenerate-span guard are the pipeline's own
# numbers - the whole prop fleet rendered through them.
static func _bake_uv_channel(uv_sets: Array, vcount: int) -> int:
	for k in range(1, uv_sets.size()):
		var src: PackedFloat32Array = (uv_sets[k] as Array)[0]
		var c: int = (uv_sets[k] as Array)[1]
		if src.size() < vcount * c:
			continue
		var lo_u := 1e20
		var hi_u := -1e20
		var lo_v := 1e20
		var hi_v := -1e20
		for i in range(vcount):
			var u := src[i * c]
			var v := src[i * c + 1]
			lo_u = minf(lo_u, u)
			hi_u = maxf(hi_u, u)
			lo_v = minf(lo_v, v)
			hi_v = maxf(hi_v, v)
		if lo_u >= -0.05 and hi_u <= 1.05 and lo_v >= -0.05 and hi_v <= 1.05 \
				and maxf(hi_u - lo_u, hi_v - lo_v) > 0.05:
			return k
	return 0


func _read_attr(buf: PackedByteArray, base: int, count: int, el: Array,
		streams: Array) -> Array:
	var fmt := int(el[1])
	var off := int(el[2])
	var si := int(el[3])
	if si >= streams.size():
		return []
	var sstride := int(streams[si][0])
	var size: int = FMT_SIZE.get(fmt, 0)
	if size == 0 or sstride == 0:
		return []
	var sbase := base
	for s in range(si):
		sbase += int(streams[s][0]) * count
	if sbase + (count - 1) * sstride + off + size > buf.size():
		return []

	var comps := _components(fmt)
	if comps == 0:
		return []
	var out := PackedFloat32Array()
	out.resize(count * comps)
	for i in range(count):
		var p := sbase + i * sstride + off
		var o := i * comps
		match fmt:
			1, 2, 3, 4:                                   # Float1..4
				for c in range(comps):
					out[o + c] = buf.decode_float(p + c * 4)
			5, 6, 7, 8:                                   # Half1..4
				for c in range(comps):
					out[o + c] = buf.decode_half(p + c * 2)
			14, 15, 16, 17:                               # Short1..4
				for c in range(comps):
					out[o + c] = float(buf.decode_s16(p + c * 2))
			18, 19, 20, 21:                               # ShortN family
				for c in range(comps):
					out[o + c] = float(buf.decode_s16(p + c * 2)) / 32767.0
			22, 23:                                       # UShort2 / UShort4
				for c in range(comps):
					out[o + c] = float(buf.decode_u16(p + c * 2))
			24, 25:                                       # UShort2N / UShort4N
				for c in range(comps):
					out[o + c] = float(buf.decode_u16(p + c * 2)) / 65535.0
			11, 13:                                       # Byte4N / UByte4N
				for c in range(comps):
					out[o + c] = float(buf[p + c]) / 255.0
			10, 12:                                       # Byte4 / UByte4
				for c in range(comps):
					out[o + c] = float(buf[p + c])
			_:
				return []
	return [out, comps]


func _components(fmt: int) -> int:
	match fmt:
		1, 5, 14, 18, 50: return 1
		2, 6, 15, 19, 22, 24: return 2
		3, 7, 16, 20: return 3
		4, 8, 10, 11, 12, 13, 17, 21, 23, 25: return 4
	return 0
