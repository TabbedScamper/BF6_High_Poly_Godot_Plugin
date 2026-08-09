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


# ---------------------------------------------------------------------------
# THE SAME PIXELS, ONCE PER MAP INSTEAD OF ONCE PER PROP.
#
# The `dup` field above dedups images WITHIN one sidecar, and bind()'s cache
# dedups them within one prop. Nothing dedups them ACROSS props, and props are
# where the repetition is: measured over Dumbo's 2,693 sidecars there are 12,087
# stored payloads holding 3,486 distinct textures — 4.0x, 3.4 GB of the 4.5 GB a
# build reads being a re-copy. One 1024x512 atlas is stored 252 times.
#
# Every one of those copies was separately zstd-decompressed, decoded, block-
# compressed (the expensive half) and uploaded to the GPU as its own texture.
# That is why a build spent 15.6 s in the worker prefetch and most of a further
# 19.7 s binding, and why the scene asks for 14.5 GB of texture memory.
#
# Keyed on a hash of the STORED (still compressed) bytes, so the check happens
# before any of the expensive work rather than after it. The dimensions and
# format go into the key too: identical bytes read as different formats are
# different images, and a silent wrong-texture bug is far worse than a miss.
#
# Two pools, with deliberately different lifetimes:
#   _pool      Image, CPU side. Only useful while a build is running, and worth
#              several GB, so the build drops it at the end (release_images).
#   _tex_pool  ImageTexture, GPU side. THIS is the video-memory saving, and it
#              has to outlive the build because the textures stay on screen.
#              Cleared when the map context is torn down.
#
# The lock is held only around the dictionary, never around a decode. Two
# workers racing on the same unseen texture both decode it and the second
# overwrites the first — duplicated work in a rare case, which is much cheaper
# than serialising every worker behind one mutex.
static var _pool: Dictionary = {}          # key -> Image (decoded, maybe compressed)
static var _tex_pool: Dictionary = {}      # key -> ImageTexture
static var _pool_mx := Mutex.new()
static var _pool_hits := 0
static var _pool_misses := 0


static func _pool_get(key: String) -> Variant:
	_pool_mx.lock()
	var v: Variant = _pool.get(key)
	if v != null:
		_pool_hits += 1
	else:
		_pool_misses += 1
	_pool_mx.unlock()
	return v


static func _pool_put(key: String, img: Image) -> void:
	if img == null:
		return
	_pool_mx.lock()
	_pool[key] = img
	_pool_mx.unlock()


# Drop the CPU-side images. The GPU textures they were uploaded to are held by
# _tex_pool and by the materials themselves, so this frees several GB of system
# memory without anything disappearing from the screen.
static func release_images() -> void:
	_pool_mx.lock()
	_pool.clear()
	_pool_mx.unlock()


static func release_all() -> void:
	_pool_mx.lock()
	_pool.clear()
	_tex_pool.clear()
	_pool_hits = 0
	_pool_misses = 0
	_pool_mx.unlock()


# Bytes for one image, from its dimensions and format.
#
# NEVER get_data(): that returns a COPY, so measuring a few thousand images
# would allocate a second copy of every one of them - which is the failure this
# measurement exists to find. Block-compressed sizes are exact; anything else
# falls back to 4 bytes per pixel, which over-reports rather than flatters.
static func _img_bytes(w: int, h: int, fmt: int) -> int:
	var px := maxi(1, w) * maxi(1, h)
	match fmt:
		Image.FORMAT_DXT1, Image.FORMAT_RGTC_R:
			return px / 2                     # 4 bpp of a block, 0.5 B/px
		Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGTC_RG, \
		Image.FORMAT_BPTC_RGBA:
			return px                         # 1 B/px
		Image.FORMAT_L8, Image.FORMAT_R8:
			return px
		Image.FORMAT_LA8, Image.FORMAT_RG8:
			return px * 2
		Image.FORMAT_RGB8:
			return px * 3
		_:
			return px * 4


# WHAT THE SHARED POOLS HOLD, which nothing outside this file could see.
#
# HighpolyGameSource.cache_stats() reports its own caches and knows nothing
# about these two, so every memory report we have ever produced was blind to
# the largest single holder in the plugin: _pool keeps a CPU Image and
# _tex_pool a GPU texture for the SAME key, and on a full Dumbo build that is
# thousands of textures held twice.
#
# Reported in bytes as well as counts, because "3,486 textures" does not tell
# anyone whether that is a rounding error or several gigabytes.
static func pool_stats() -> Dictionary:
	_pool_mx.lock()
	var img_bytes := 0
	for k in _pool.keys():
		var im = _pool[k]
		if im is Image:
			img_bytes += _img_bytes((im as Image).get_width(),
				(im as Image).get_height(), int((im as Image).get_format()))
	var tex_bytes := 0
	for k in _tex_pool.keys():
		var tx = _tex_pool[k]
		if tx is Texture2D:
			# The texture's own format is not reachable without a readback, so
			# this is the 4 B/px upper bound by the same convention as above.
			tex_bytes += (tx as Texture2D).get_width() \
				* (tx as Texture2D).get_height() * 4
	var d := {"images": _pool.size(), "textures": _tex_pool.size(),
		"image_mb": snappedf(img_bytes / 1048576.0, 0.1),
		"texture_mb_est": snappedf(tex_bytes / 1048576.0, 0.1),
		"hits": _pool_hits, "misses": _pool_misses}
	_pool_mx.unlock()
	return d


static func _key_for(stored: PackedByteArray, h: Dictionary, compress: bool,
		is_normal: bool) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(stored)
	# The header goes in as well as the payload. Two payloads that hash alike
	# but are declared at different sizes or formats are different images, and
	# the compress flag changes what is actually in the pooled Image.
	#
	# AND THE NORMAL FLAG. A normal map is compressed as BC5 and everything else
	# as BC1/BC3, so the same bytes bound as a normal in one prop and as an
	# albedo in another are two different pooled images. Sharing them would put
	# a two-channel encode on a colour map — visible, and untraceable to here.
	return "%s|%d|%d|%d|%d|%d|%d" % [ctx.finish().hex_encode(), int(h["w"]),
		int(h["h"]), int(h["fmt"]), int(h["flags"]),
		1 if compress else 0, 1 if is_normal else 0]


static func path_for(glb_path: String) -> String:
	return glb_path.get_basename() + EXT


static func exists(glb_path: String) -> bool:
	return FileAccess.file_exists(path_for(glb_path))


# WORKER SAFE. Produces Images and nothing else — no Node, no ImageTexture, no
# RenderingServer, because those are what kill a worker. Image on its own does
# not: proven over 3,000 textures. Returns {} on anything unexpected, and every
# caller falls back to the glb.
#
# `compress` moved IN HERE from the caller's separate compress_decoded() pass so
# that a pooled image is a FINISHED one. With the two split, a shared image
# could be handed to one prop and then block-compressed in place while another
# thread was still reading it — the pool has to hold something nobody needs to
# mutate again.
static func decode(bctex_path: String, compress := false) -> Dictionary:
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
	return _read_images(raw, heads, jat + 4 + jlen, meta as Dictionary, compress)


static func _read_images(raw: PackedByteArray, heads: Array, at: int,
		meta: Dictionary, compress := false) -> Dictionary:
	var images: Array = []
	# Parallel to `images`, so bind() can reach the shared GPU texture for an
	# image without knowing anything about where the pixels came from. Empty
	# string for a gap or a within-sidecar duplicate.
	var keys: Array = []
	var normals: Dictionary = _normal_indices(meta.get("materials", {})) \
		if compress else {}
	for hi in range(heads.size()):
		var h: Dictionary = heads[hi]
		# A SHARED IMAGE, stored once and referenced by index. glTF lists an
		# entry per reference and a backdrop points hundreds of materials at the
		# same few atlases, so without this the sidecar carries the same pixels
		# thousands of times — measured at 43.8 MB for a 28.9 MB set.
		var dup: int = int(h.get("dup", 0xFFFF))
		if dup != 0xFFFF:
			images.append(images[dup] if dup < images.size() else null)
			keys.append(keys[dup] if dup < keys.size() else "")
			continue
		var stored: int = int(h["stored"])
		if stored <= 0:
			images.append(null)     # a recorded gap: keeps indices lined up
			keys.append("")
			continue
		if at + stored > raw.size():
			return {}
		var packed := raw.slice(at, at + stored)
		at += stored

		# THE POOL CHECK GOES BEFORE THE EXPENSIVE WORK, not after it. Hashing
		# the still-compressed bytes costs a fraction of the zstd decompress,
		# image decode and block compress it skips on a hit — and on this map
		# three quarters of the payloads are hits.
		var as_normal := normals.has(hi)
		var key := _key_for(packed, h, compress, as_normal)
		var hit: Variant = _pool_get(key)
		if hit is Image:
			images.append(hit)
			keys.append(key)
			continue

		var blob := packed.decompress(int(h["raw"]), FileAccess.COMPRESSION_ZSTD)
		if blob.size() != int(h["raw"]):
			images.append(null)
			keys.append("")
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
		if compress:
			_compress_one(img, as_normal)
		_pool_put(key, img)
		images.append(img)
		keys.append(key)
	return {"images": images, "keys": keys,
		"materials": meta.get("materials", {})}


# Also worker safe, and kept separate so a main-thread caller can skip it: this
# is the expensive half, and it is exactly what should not run there.
static func _compress_one(img: Image, is_normal: bool) -> void:
	if img == null or img.is_compressed():
		return
	if img.get_width() < 4 or img.get_height() < 4:
		return
	# NORMAL MAPS GET BC5 (two channels), not BC1/BC3 — see the note on
	# compress_decoded below; the reason is the same and so is the branch.
	img.compress(Image.COMPRESS_S3TC,
		Image.COMPRESS_SOURCE_NORMAL if is_normal
			else Image.COMPRESS_SOURCE_GENERIC)


# Superseded on the prop and skyline paths, which now pass compress=true to
# decode() so the pooled image is finished and nobody mutates a shared one.
# Kept because it is the safe thing for any caller holding images that did NOT
# come out of the pool; on pooled ones every is_compressed() guard below hits.
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

	var keys: Array = decoded.get("keys", [])
	var cache: Dictionary = {}
	var n := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		for c in x.get_children():
			stack.append(c)
		for m in _materials_of(x):
			n += _bind_material(m, images, mats, cache, keys)
	return n


# MAIN THREAD, same as bind(), but for meshes that never came from a scene.
#
# A prop loaded from a shipped .geom.res is a list of Meshes, not a node tree —
# there is nothing to walk. The material names are the same ones bc_strip wrote,
# so the sidecar still matches; only the way we reach the materials differs.
static func bind_meshes(meshes: Array, decoded: Dictionary) -> int:
	if meshes.is_empty() or decoded.is_empty():
		return 0
	var images: Array = decoded.get("images", [])
	var mats: Dictionary = decoded.get("materials", {})
	if images.is_empty() or mats.is_empty():
		return 0

	var keys: Array = decoded.get("keys", [])
	var cache: Dictionary = {}
	var n := 0
	for m in meshes:
		var mesh := m as Mesh
		if mesh == null:
			continue
		for i in range(mesh.get_surface_count()):
			n += _bind_material(mesh.surface_get_material(i), images, mats,
					cache, keys)
	return n


# The texture cache is passed in rather than made here so one prop's shared
# atlases are uploaded ONCE across all its surfaces. Uploading per surface is
# the mistake that made an earlier version measure 1.8x instead of 4.3x.
static func _bind_material(m: Material, images: Array, mats: Dictionary,
		cache: Dictionary, keys: Array = []) -> int:
	var bm := m as BaseMaterial3D
	if bm == null:
		return 0
	var slots: Variant = mats.get(bm.resource_name)
	if not (slots is Dictionary):
		return 0
	var n := 0
	for slot in (slots as Dictionary).keys():
		if not SLOT_MAP.has(slot):
			continue
		var idx := int((slots as Dictionary)[slot])
		if idx < 0 or idx >= images.size() or images[idx] == null:
			continue
		var tex: Texture2D = cache.get(idx)
		if tex == null:
			# THE MAP-WIDE POOL FIRST. `cache` only spans this one prop, so
			# without this every prop sharing an atlas uploaded its own copy —
			# 12,087 uploads of 3,486 distinct textures on Dumbo, and the 14.5 GB
			# of texture memory that comes with them. An ImageTexture is a plain
			# Resource and is safe to hang on any number of materials.
			var key: String = str(keys[idx]) if idx < keys.size() else ""
			if key != "":
				_pool_mx.lock()
				tex = _tex_pool.get(key)
				_pool_mx.unlock()
			if tex == null:
				tex = ImageTexture.create_from_image(images[idx] as Image)
				if tex == null:
					continue
				if key != "":
					_pool_mx.lock()
					_tex_pool[key] = tex
					_pool_mx.unlock()
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
