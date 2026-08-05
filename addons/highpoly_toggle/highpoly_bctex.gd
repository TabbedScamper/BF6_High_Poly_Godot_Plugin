@tool
extends RefCounted
class_name HighpolyBcTex

# Textures shipped BESIDE the mesh instead of inside it.
#
# A backdrop costs 308 ms to parse and 94.6 s across a Dumbo skyline, all on the
# main thread, and it cannot be moved: generate_scene segfaults on these assets
# whether or not the textures are still in the file. What CAN move is the
# texture work — but inside a glb it is not separable, because Godot decodes
# embedded images during append_from_buffer whatever HANDLE_BINARY_* says
# (EMBED 39.0 ms against DISCARD 40.5 ms over 60 props). The images have to
# physically leave the file.
#
# With them gone the same parse is 113 ms, 37% of what it was, and the other
# 63% becomes ours to schedule. Decoding on a worker measures 4.71x over 3,000
# real backdrop textures, with no hang and no crash.
#
# THE SIDECAR CARRIES ORIGINAL BYTES BY DEFAULT. Block-compressing everything
# grows the download 32%, because BC is fixed-rate and webp is not. Shipping the
# original bytes costs nothing and still buys the whole split: the expensive
# part was never the format, it was that the decode sat trapped inside the glTF
# parse. Blocks are a per-texture upgrade applied only where they are no larger.
#
# SPLIT IN TWO ON PURPOSE:
#   decode()  pure Image work, safe on a worker, and the reason this exists
#   bind()    creates GPU textures and touches materials — main thread only
#
# Format, little-endian, written by tools/bc_encode.gd:
#   "BCTX" u32 version  u32 count
#   count x { u16 w, u16 h, u8 fmt, u8 flags, u16 pad, u32 stored, u32 raw }
#   u32 json_len, json { "materials": { name: { slot: image_index } } }
#   payloads back to back, each zstd'd, in header order, empty entries skipped

const MAGIC := 0x58544342
const VERSION := 1
const F_MIPS := 1
const F_ORIGINAL := 2
const EXT := ".bctex"

const SLOT_MAP := {
	"albedo": BaseMaterial3D.TEXTURE_ALBEDO,
	"normal": BaseMaterial3D.TEXTURE_NORMAL,
	"roughness": BaseMaterial3D.TEXTURE_ROUGHNESS,
	"metallic": BaseMaterial3D.TEXTURE_METALLIC,
	"emission": BaseMaterial3D.TEXTURE_EMISSION,
	"ao": BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION,
}


static func path_for(glb_path: String) -> String:
	return glb_path.get_basename() + EXT


static func exists(glb_path: String) -> bool:
	return FileAccess.file_exists(path_for(glb_path))


# WORKER SAFE. Produces Images and nothing else — no Node, no ImageTexture, no
# RenderingServer, because those are what kill a worker. Image on its own does
# not: proven over 3,000 textures. Returns {} on anything unexpected, and every
# caller falls back to the glb.
static func decode(bctex_path: String) -> Dictionary:
	var raw := FileAccess.get_file_as_bytes(bctex_path)
	if raw.size() < 16 or raw.decode_u32(0) != MAGIC:
		return {}
	if int(raw.decode_u32(4)) != VERSION:
		return {}
	var count := int(raw.decode_u32(8))
	if count < 0 or count > 65535:
		return {}
	if raw.size() < 12 + count * 16 + 4:
		return {}

	var heads: Array = []
	for i in range(count):
		var o := 12 + i * 16
		heads.append({
			"w": int(raw.decode_u16(o)), "h": int(raw.decode_u16(o + 2)),
			"fmt": int(raw.decode_u8(o + 4)), "flags": int(raw.decode_u8(o + 5)),
			"dup": int(raw.decode_u16(o + 6)),
			"stored": int(raw.decode_u32(o + 8)), "raw": int(raw.decode_u32(o + 12)),
		})
	var jat := 12 + count * 16
	var jlen := int(raw.decode_u32(jat))
	if jlen < 0 or jat + 4 + jlen > raw.size():
		return {}
	var meta: Variant = JSON.parse_string(
		raw.slice(jat + 4, jat + 4 + jlen).get_string_from_utf8())
	if not (meta is Dictionary):
		return {}
	return _read_images(raw, heads, jat + 4 + jlen, meta as Dictionary)


static func _read_images(raw: PackedByteArray, heads: Array, at: int,
		meta: Dictionary) -> Dictionary:
	var images: Array = []
	for h in heads:
		# A SHARED IMAGE, stored once and referenced by index. glTF lists an
		# entry per reference and a backdrop points hundreds of materials at the
		# same few atlases, so without this the sidecar carries the same pixels
		# thousands of times — measured at 43.8 MB for a 28.9 MB set.
		var dup: int = int(h.get("dup", 0xFFFF))
		if dup != 0xFFFF:
			images.append(images[dup] if dup < images.size() else null)
			continue
		var stored: int = int(h["stored"])
		if stored <= 0:
			images.append(null)     # a recorded gap: keeps indices lined up
			continue
		if at + stored > raw.size():
			return {}
		var blob := raw.slice(at, at + stored).decompress(int(h["raw"]),
			FileAccess.COMPRESSION_ZSTD)
		at += stored
		if blob.size() != int(h["raw"]):
			images.append(null)
			continue
		var img: Image = null
		if int(h["flags"]) & F_ORIGINAL:
			# the encoder kept the source bytes because blocks would have been
			# larger; decoding them HERE is still off the main thread, which is
			# the win — the format was never the point
			img = Image.new()
			if img.load_webp_from_buffer(blob) != OK \
					and img.load_png_from_buffer(blob) != OK \
					and img.load_jpg_from_buffer(blob) != OK:
				img = null
		else:
			img = Image.create_from_data(int(h["w"]), int(h["h"]),
				(int(h["flags"]) & F_MIPS) != 0, int(h["fmt"]), blob)
		images.append(img)
	return {"images": images, "materials": meta.get("materials", {})}


# Also worker safe, and kept separate so a main-thread caller can skip it: this
# is the expensive half, and it is exactly what should not run there.
static func compress_decoded(decoded: Dictionary) -> void:
	if decoded.is_empty():
		return
	var images: Array = decoded.get("images", [])
	var normals := _normal_indices(decoded.get("materials", {}))
	for i in range(images.size()):
		var img := images[i] as Image
		if img == null or img.is_compressed():
			continue
		if img.get_width() < 4 or img.get_height() < 4:
			continue
		img.compress(Image.COMPRESS_S3TC,
			Image.COMPRESS_SOURCE_NORMAL if normals.has(i)
				else Image.COMPRESS_SOURCE_GENERIC)


# MAIN THREAD. Turns the decoded Images into GPU textures and hangs them on the
# materials the stripped glb came back with. Returns how many textures landed.
static func bind(root: Node, decoded: Dictionary) -> int:
	if root == null or decoded.is_empty():
		return 0
	var images: Array = decoded.get("images", [])
	var mats: Dictionary = decoded.get("materials", {})
	if images.is_empty() or mats.is_empty():
		return 0

	var cache: Dictionary = {}
	var n := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		for c in x.get_children():
			stack.append(c)
		for m in _materials_of(x):
			var bm := m as BaseMaterial3D
			if bm == null:
				continue
			var slots: Variant = mats.get(bm.resource_name)
			if not (slots is Dictionary):
				continue
			for slot in (slots as Dictionary).keys():
				if not SLOT_MAP.has(slot):
					continue
				var idx := int((slots as Dictionary)[slot])
				if idx < 0 or idx >= images.size() or images[idx] == null:
					continue
				var tex: Texture2D = cache.get(idx)
				if tex == null:
					tex = ImageTexture.create_from_image(images[idx] as Image)
					if tex == null:
						continue
					cache[idx] = tex
				bm.set_texture(SLOT_MAP[slot], tex)
				_enable_slot(bm, str(slot))
				n += 1
	return n


# A stripped glb carries no texture references, so Godot never switches these
# features on. Assigning a normal map to a material with normal_enabled false
# renders exactly as if there were no normal map — silently, and the prop still
# looks plausible, which is the sort of wrong that survives a review.
static func _enable_slot(bm: BaseMaterial3D, slot: String) -> void:
	match slot:
		"normal":
			bm.normal_enabled = true
		"emission":
			bm.emission_enabled = true
		"ao":
			bm.ao_enabled = true
			bm.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		"roughness":
			bm.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		"metallic":
			bm.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE


static func _normal_indices(mats: Dictionary) -> Dictionary:
	var out := {}
	for k in mats.keys():
		var slots: Variant = mats[k]
		if slots is Dictionary and (slots as Dictionary).has("normal"):
			out[int((slots as Dictionary)["normal"])] = true
	return out


# generate_scene yields ImporterMeshInstance3D in the editor and MeshInstance3D
# outside it. A walker that knows only one of them sees an empty scene, which
# has already produced two confidently wrong measurements in this project.
static func _materials_of(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.material_override != null:
			out.append(mi.material_override)
		if mi.mesh != null:
			for i in range(mi.mesh.get_surface_count()):
				out.append(mi.mesh.surface_get_material(i))
				out.append(mi.get_surface_override_material(i))
	elif n is ImporterMeshInstance3D:
		var im := (n as ImporterMeshInstance3D).mesh
		if im != null:
			for i in range(im.get_surface_count()):
				out.append(im.get_surface_material(i))
	var keep: Array = []
	for m in out:
		if m != null:
			keep.append(m)
	return keep
