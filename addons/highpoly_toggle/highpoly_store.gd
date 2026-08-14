@tool
extends RefCounted
class_name HighpolyStore
# The v1.5 model store: every downloaded model lives OUTSIDE res:// so the
# editor never scans, imports, or re-validates anything — launch cost is zero
# no matter how big the library gets. GLBs are parsed at runtime (GLTFDocument,
# same proven path Map Context uses) and cached as renderable PackedScenes for
# the session.
#
#   user://highpoly/store.json      index: schema + per-model {hash, nofit}
#   user://highpoly/models/<N>.glb  one file per SDK proxy name
#   user://highpoly/thumbs/<N>.png  object-library thumbnails (rendered locally)
#
# store.json is the single source of local truth (replaces the 1.4 per-prop
# sidecars). Currency is decided ONLY by comparing its hashes against the
# registry manifest — never by "the file exists".

const ROOT := "user://highpoly"
const MODELS_DIR := "user://highpoly/models"
const THUMBS_DIR := "user://highpoly/thumbs"
# Detail-Mode suffixes a thumbnail can be cached under (see thumb_path). The
# bare, unsuffixed name stays in the list of files to invalidate so thumbs
# written by earlier versions are still cleaned up rather than orphaned.
# _ctx entries are rendered from the map-context stand-in rather than the
# library copy, so they must invalidate independently: when the real model
# lands the stand-in's picture is wrong, and when a props.zip is refreshed the
# stand-in's picture is wrong the other way round.
# RETIRED: thumb_paths enumerates the thumbs folder instead, because a hand
# kept list of tags goes stale the moment a new one appears - which
# ICON_EPOCH did. Left as a comment rather than a const so nothing starts
# trusting it again.
#   was: ["clay", "tex", "clay_ctx", "tex_ctx"]

# ---------- the map context as a second source of geometry ----------
# "Original map objects" downloads the level's own meshes into this cache, keyed
# by GAME MESH name. The library is keyed by SDK PROXY name. The same object is
# therefore capable of being downloaded twice, once per store, and on Dumbo that
# is 1,055 of 2,595 map-restricted placeable entries (418 MB at the web tier).
#
# The two are bridged by the manifest: remote[proxy].glb is "godot/<GameMesh>.glb",
# so no second lookup table is needed.
#
# What the map-context copy IS: a distance-streaming bake. Multi-part meshes are
# merged into one and the texture policy is `mapweb` (half-res basecolor). It is
# the right thing to show instead of the SDK's white blockout, and the WRONG thing
# to leave in place once the user actually places and inspects the object -- so it
# is served as a stand-in that still queues the library copy behind it.
#
# Per-instance variation files carry a __v######## suffix and have no library
# equivalent. They can never be offered here because names are derived FROM the
# manifest rather than by scanning the directory for something that looks close.
const CTX_PROPS := "user://mapcontext/_props"

static var _ctx_names: Dictionary = {}     # lowercase game-mesh basename -> true
static var _ctx_scanned := false
static var _ctx_scenes: Dictionary = {}    # ctx path -> PackedScene (null = failed)

# One directory listing rather than a stat per lookup: _asset_id() runs per node
# on every apply pass, and the Object Library preview tick runs over thousands of
# rows every two seconds.
static func ctx_scan(force := false) -> void:
	if _ctx_scanned and not force: return
	_ctx_scanned = true
	_ctx_names.clear()
	if force:
		# A refreshed props.zip replaces geometry behind names we may already be
		# serving, so parsed scenes and their thumbnails both go stale.
		_ctx_scenes.clear()
		_drop_ctx_thumbs()
	var da := DirAccess.open(CTX_PROPS)
	if da == null: return
	for f in da.get_files():
		if f.ends_with(".glb"):
			_ctx_names[f.get_basename().to_lower()] = true

static func _drop_ctx_thumbs() -> void:
	var da := DirAccess.open(THUMBS_DIR)
	if da == null: return
	for f in da.get_files():
		if f.ends_with("_ctx.png"):
			DirAccess.remove_absolute("%s/%s" % [THUMBS_DIR, f])

# Map-context geometry for a PROXY name, or "" when there is none. Never returns
# a path for a proxy the library already holds: the library copy is the artefact
# the user actually gets when they place the item, so it always wins.
static func ctx_model_path(name: String) -> String:
	if has_model(name): return ""
	var e = remote.get(name)
	if not (e is Dictionary): return ""
	var gm := str((e as Dictionary).get("glb", "")).get_file().get_basename()
	if gm == "" or not _ctx_names.has(gm.to_lower()): return ""
	return "%s/%s.glb" % [CTX_PROPS, gm]

# Deliberately NOT _scene_cache: that is keyed by proxy name, so a map-context
# mesh parked in it would later be handed back AS the library model for the same
# name, and the upgrade to the real copy would silently never happen.
static func load_ctx_scene(path: String) -> PackedScene:
	if _ctx_scenes.has(path):
		return _ctx_scenes[path]
	var ps: PackedScene = null
	if FileAccess.file_exists(path):
		ps = load_external_glb(path)
	_ctx_scenes[path] = ps
	return ps
const INDEX_PATH := "user://highpoly/store.json"
const SCHEMA := 1
const FLUSH_EVERY := 25   # index writes are batched during bulk syncs

static var _index: Dictionary = {}       # {"schema", "scope", "models": {name: {hash, nofit}}}
static var _loaded := false
static var _dirty := 0
static var _scene_cache: Dictionary = {} # name -> PackedScene (null = parse failed)
# every model name the registry advertises (filled by the sync manager after
# the manifest fetch) — lets the overlay matcher recognize props we don't have
# locally yet, so they can be queued instead of silently skipped
static var remote: Dictionary = {}       # proxy name -> {glb, hash, nofit}
# the same registry keyed by GAME MESH name (derived from each entry's glb
# filename) — map context uses this to keep its shared prop meshes following
# the site: a model swapped on the site under the same name re-downloads here
static var mesh_remote: Dictionary = {}  # mesh name -> {glb, hash}

# ---------- fs ----------
# make_dir_recursive_absolute prints "Could not create directory" (dir_access.cpp)
# for every existing path component — during a bulk sync that's one noisy error
# per model (hundreds of them). Only create when the dir is actually missing so
# the Output log stays clean.
static func ensure_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)

# ---------- index ----------
static func _load() -> void:
	if _loaded: return
	_loaded = true
	_index = {"schema": SCHEMA, "scope": "", "models": {}}
	if FileAccess.file_exists(INDEX_PATH):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
		if j is Dictionary and (j as Dictionary).has("models"):
			_index = j

static func initialized() -> bool:
	return FileAccess.file_exists(INDEX_PATH)

static func save(force := true) -> void:
	_load()
	if not force and _dirty < FLUSH_EVERY:
		return
	_dirty = 0
	ensure_dir(ROOT)
	var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_index))
		f.close()

static func models() -> Dictionary:
	_load()
	return _index["models"]

static func has_model(name: String) -> bool:
	return models().has(name) and FileAccess.file_exists(model_path(name))

# index-only membership (no disk stat) — the bulk manifest diff runs on this,
# so checking 8k+ entries costs dictionary lookups, not filesystem calls
static func has_entry(name: String) -> bool:
	return models().has(name)

# ETag of the manifest we last diffed against: lets startup + hourly checks
# skip the whole download-and-diff when nothing was published in between
static func manifest_etag() -> String:
	_load()
	return str(_index.get("metag", ""))

static func set_manifest_etag(tag: String) -> void:
	_load()
	_index["metag"] = tag
	save()

static func hash_of(name: String) -> String:
	var e: Variant = models().get(name)
	return str((e as Dictionary).get("hash", "")) if e is Dictionary else ""

static func nofit(name: String) -> bool:
	var e: Variant = models().get(name)
	return bool((e as Dictionary).get("nofit", false)) if e is Dictionary else false

static func model_path(name: String) -> String:
	return "%s/%s.glb" % [MODELS_DIR, name]

# Every downloaded variant of one base model. Variants are stored as
# <proxy>__<label>.glb and kept out of the index on purpose, so anything that
# deletes a model has to sweep them explicitly or they are orphaned.
static func variant_files(name: String) -> Array:
	var out: Array = []
	var da := DirAccess.open(MODELS_DIR)
	if da == null: return out
	var prefix := name + "__"
	for f in da.get_files():
		if f.begins_with(prefix) and f.get_extension() == "glb":
			out.append("%s/%s" % [MODELS_DIR, f])
	return out

# Thumbnails are rendered per Detail Mode (clay in Low-Poly, textured in
# High-Poly), so the mode is part of the cache key. Keyed by name alone, the two
# renders shared one file and switching modes served the other mode's picture
# with nothing to signal it was stale -- which reads as "the model downloaded
# wrong" and costs an hour to chase.
static func thumb_path(name: String, mode: String = "") -> String:
	if mode == "":
		return "%s/%s.png" % [THUMBS_DIR, name]
	return "%s/%s__%s.png" % [THUMBS_DIR, name, mode]

# Every cached render of one model, whatever the mode. _invalidate() must delete
# ALL of them: a model that changes on disk invalidates its clay picture exactly
# as much as its textured one, and a per-mode file the invalidation does not know
# about is a stale thumbnail that never heals.
static func thumb_paths(name: String) -> Array:
	var out: Array = [thumb_path(name)]
	# BY WHAT IS ON DISK, not by a list of tags maintained somewhere else.
	#
	# THUMB_MODES was that list, and it could only be right until the next tag
	# appeared. ICON_EPOCH added one immediately: the modes became clay2 and
	# tex2 while the list still said clay and tex, so a model that changed on
	# disk would have kept its old picture with nothing to say why. A cached
	# file is named after the thing it is a picture of, so the file names on
	# disk are the authority on which files exist.
	var dir := DirAccess.open(THUMBS_DIR)
	if dir != null:
		var pre := "%s__" % name
		for f in dir.get_files():
			var fn := str(f)
			if fn.begins_with(pre) and fn.get_extension().to_lower() == "png":
				out.append("%s/%s" % [THUMBS_DIR, fn])
	return out

static func count() -> int:
	return models().size()

# ---------- ingest ----------
# Record a model already on disk (migration) or write+record bytes (download).
static func record(name: String, h: String, nofit_flag: bool) -> void:
	_load()
	_index["models"][name] = {"hash": h, "nofit": nofit_flag}
	_dirty += 1
	save(false)
	_invalidate(name)

# The model file is ALREADY on disk (streamed there by fetch_to_file); just
# check it is real and index it. Same bookkeeping as ingest_bytes without ever
# holding the file in memory.
static func ingest_downloaded(name: String, h: String, nofit_flag: bool) -> bool:
	var p := model_path(name)
	if not FileAccess.file_exists(p):
		return false
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var n := f.get_length()
	f.close()
	if n <= 0:
		DirAccess.remove_absolute(p)
		return false
	record(name, h, nofit_flag)
	return true


static func ingest_bytes(name: String, data: PackedByteArray, h: String, nofit_flag: bool) -> bool:
	ensure_dir(MODELS_DIR)
	var f := FileAccess.open(model_path(name), FileAccess.WRITE)
	if f == null: return false
	f.store_buffer(data)
	f.close()
	record(name, h, nofit_flag)
	return true

static func _invalidate(name: String) -> void:
	_scene_cache.erase(name)
	for tp in thumb_paths(name):
		if FileAccess.file_exists(tp):
			DirAccess.remove_absolute(tp)
	# The base model changed, so its variants are from the previous build. They
	# carry no hash in the manifest (only a name), so staleness cannot be
	# detected later — drop them and let the next double-click re-fetch, which is
	# the only moment their absence costs anything.
	for vp in variant_files(name):
		DirAccess.remove_absolute(vp)

static func file_hash(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return ""
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA1) != OK:
		f.close(); return ""
	while not f.eof_reached():
		ctx.update(f.get_buffer(1 << 20))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

# ---------- runtime GLB -> renderable PackedScene ----------
# GLTFDocument.generate_scene in the editor yields ImporterMeshInstance3D
# placeholders (they don't render); convert them to real MeshInstance3D so
# the packed scene works as a live overlay. Materials survive get_mesh().
static func load_scene(name: String) -> PackedScene:
	if _scene_cache.has(name):
		return _scene_cache[name]
	var ps: PackedScene = null
	var path := model_path(name)
	if FileAccess.file_exists(path):
		ps = load_external_glb(path)
	_scene_cache[name] = ps
	return ps

# GLTF WebP texture support. trimesh-exported GLBs (the whole dump-extracted
# prop cache: ~4,000 files) embed their basecolor as EXT/KHR_texture_webp —
# an extension Godot's GLTFDocument does not resolve, so every such texture
# silently dropped and the prop rendered flat white. Godot's Image decodes
# WebP natively; this extension just wires the mime type + the texture's
# extension-source indirection through. Registered once per session.
class _WebPTexExt extends GLTFDocumentExtension:
	func _get_supported_extensions() -> PackedStringArray:
		return PackedStringArray(["EXT_texture_webp", "KHR_texture_webp"])
	func _parse_image_data(_state: GLTFState, image_data: PackedByteArray,
			mime_type: String, ret_image: Image) -> Error:
		if mime_type == "image/webp":
			return ret_image.load_webp_from_buffer(image_data)
		# handle the standard mimes too: returning ERR_SKIP here still loads
		# them (core falls through to its own decoders) but logs a bogus
		# "glTF: Encountered error 45 when parsing image" per PNG/JPEG — the
		# error spam users saw on "Show whole map" was exactly that.
		if mime_type == "image/png":
			return ret_image.load_png_from_buffer(image_data)
		if mime_type == "image/jpeg":
			return ret_image.load_jpg_from_buffer(image_data)
		return ERR_SKIP
	func _parse_texture_json(_state: GLTFState, texture_json: Dictionary,
			ret_gltf_texture: GLTFTexture) -> Error:
		var ext: Dictionary = texture_json.get("extensions", {})
		var w: Dictionary = ext.get("EXT_texture_webp", ext.get("KHR_texture_webp", {}))
		if w.has("source"):
			ret_gltf_texture.src_image = int(w["source"])
		return OK

static var _webp_ext_registered := false

static func _ensure_webp_ext() -> void:
	if _webp_ext_registered: return
	_webp_ext_registered = true
	GLTFDocument.register_gltf_document_extension(_WebPTexExt.new(), true)

static func load_external_glb(user_path: String) -> PackedScene:
	_ensure_webp_ext()
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	# embed textures directly instead of routing them through the editor's
	# reimport system (which fails on user:// webp). Geometry is valid even
	# when a texture doesn't fully resolve, so we build regardless.
	st.set_handle_binary_image(GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED)
	doc.append_from_file(ProjectSettings.globalize_path(user_path), st)
	var scene := doc.generate_scene(st)
	if scene == null:
		return null
	_fix_importer_meshes(scene, scene)
	# A CORRUPT FILE IS DELETED, NOT TOLERATED. A truncated cache write can
	# leave a GLB that parses but carries a mesh surface with EMPTY vertex
	# data. Reading such a surface's arrays errors and hands back [], and
	# feeding that onward took a user's editor down with signal 11 - on every
	# preview build, same file, every session, which is what "it crashes very
	# often" looks like from the outside. These files are OUR derived cache
	# and rebuild from the install on demand, so deleting is the heal.
	if _scene_mesh_broken(scene):
		HighpolyLog.error(("%s parses but carries an empty mesh surface - the "
			+ "cached file is corrupt. It was deleted and rebuilds from your "
			+ "game install on demand.") % user_path.get_file())
		scene.free()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(user_path))
		return null
	compress_scene_textures(scene)
	var ps := PackedScene.new()
	if ps.pack(scene) != OK:
		scene.free()
		return null
	scene.free()
	return ps

# ---------- texture memory ----------
# The runtime GLTF path embeds textures UNCOMPRESSED: a 20 MB webp'd GLB
# balloons to hundreds of MB of raw RGBA in RAM + VRAM (Palace_01: 676 MB),
# and with the session scene-cache that adds up to editor-killing totals on
# big scenes. Recompress every texture to GPU-native S3TC right after parse —
# etcpak encode is milliseconds per texture, memory drops 4-8x in BOTH RAM
# and VRAM, and it happens once per model per session.
# SPLIT OUT SO IT CAN RUN ON A WORKER THREAD. Tangent generation is pure mesh
# maths (SurfaceTool -> ArrayMesh) and is safe off the main thread — verified.
# Texture compression is NOT: creating an ImageTexture off-thread HANGS the
# process, narrowed down one stage at a time (parse alone fine, +generate_scene
# fine, +PackedScene.pack fine, +compress_scene_textures hangs). So the prefetch
# runs this half on workers and leaves the textures to the main thread.
static func ensure_scene_tangents(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
			var mi := n as MeshInstance3D
			mi.mesh = _ensure_tangents(mi.mesh as ArrayMesh)
		for c in n.get_children():
			stack.append(c)


# MAIN THREAD ONLY (see ensure_scene_tangents). `tangents` is false when a
# prefetch worker has already done that half. `textures` is false in the Low
# video-memory mode, where the caller compresses at HALF resolution afterwards
# and compressing here first would make that impossible — a compressed image
# cannot be resized.
static func compress_scene_textures(root: Node, tangents := true, textures := true) -> void:
	var seen_mats: Dictionary = {}   # material RID -> true
	var swapped: Dictionary = {}     # old texture RID -> compressed ImageTexture
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mats: Array = []
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.material_override != null:
				mats.append(mi.material_override)
			if mi.mesh != null:
				for i in range(mi.mesh.get_surface_count()):
					mats.append(mi.mesh.surface_get_material(i))
					mats.append(mi.get_surface_override_material(i))
		elif n is ImporterMeshInstance3D:
			var im := (n as ImporterMeshInstance3D).mesh
			if im != null:
				for i in range(im.get_surface_count()):
					mats.append(im.get_surface_material(i))
		for m in mats:
			if m == null or not (m is BaseMaterial3D):
				continue
			var rid := (m as Material).get_rid()
			if seen_mats.has(rid):
				continue
			seen_mats[rid] = true
			if textures:
				_compress_material(m as BaseMaterial3D, swapped)
		# normal-mapped surfaces need TANGENTS or the renderer warns per draw
		# (runtime-parsed GLBs ship without them) — generate once at parse
		if tangents and n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
			var mi2 := n as MeshInstance3D
			mi2.mesh = _ensure_tangents(mi2.mesh as ArrayMesh)
		for c in n.get_children():
			stack.append(c)

# A cached GLB whose mesh carries a surface with no vertex data. An empty
# surface draws nothing, so a mesh that has one is a broken file, not a lean
# one - and reading its arrays is what crashed a user's editor (signal 11 in
# _ensure_tangents, godot-crash-2026-08-10_17-32-14.log). Checked through
# surface_get_array_len, which reads a stored count and never asks the
# rendering server to build arrays from the broken surface.
static func _scene_mesh_broken(root: Node) -> bool:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
			var am := (n as MeshInstance3D).mesh as ArrayMesh
			for i in range(am.get_surface_count()):
				if am.surface_get_array_len(i) <= 0:
					return true
		for c in n.get_children():
			stack.append(c)
	return false


# Rebuild any surface that has a normal-mapped material but no tangent array.
# SurfaceTool.generate_tangents = MikkTSpace, one-time per model per session.
#
# EVERY SURFACE READ IS GUARDED. surface_get_arrays on an empty-vertex
# surface errors and returns [] - a SIZE-ZERO array, not the 13-slot one -
# so the unguarded arr[Mesh.ARRAY_TANGENT] was an out-of-bounds read, and
# pushing the same [] into add_surface_from_arrays is the road that ended in
# signal 11. The loader deletes corrupt files before they get here, but this
# function is also reached through scenes that never went through the loader,
# so it must hold on its own.
static func _ensure_tangents(mesh: ArrayMesh) -> ArrayMesh:
	var needs := false
	for i in range(mesh.get_surface_count()):
		if mesh.surface_get_array_len(i) <= 0:
			continue
		var m := mesh.surface_get_material(i)
		if m is BaseMaterial3D and (m as BaseMaterial3D).normal_texture != null:
			var arr := mesh.surface_get_arrays(i)
			if arr.size() > Mesh.ARRAY_TANGENT and arr[Mesh.ARRAY_TANGENT] == null \
					and arr[Mesh.ARRAY_TEX_UV] != null \
					and arr[Mesh.ARRAY_NORMAL] != null:
				needs = true
				break
	if not needs:
		return mesh
	var out := ArrayMesh.new()
	for i in range(mesh.get_surface_count()):
		if mesh.surface_get_array_len(i) <= 0:
			continue               # an empty surface draws nothing; drop it
		var m := mesh.surface_get_material(i)
		var arr := mesh.surface_get_arrays(i)
		if arr.size() < Mesh.ARRAY_MAX or arr[Mesh.ARRAY_VERTEX] == null:
			continue               # unreadable surface: dropping beats crashing
		var has_nm: bool = m is BaseMaterial3D and (m as BaseMaterial3D).normal_texture != null
		if has_nm and arr[Mesh.ARRAY_TANGENT] == null and arr[Mesh.ARRAY_TEX_UV] != null \
				and arr[Mesh.ARRAY_NORMAL] != null:
			var st := SurfaceTool.new()
			st.create_from(mesh, i)
			st.generate_tangents()
			var fixed := st.commit_to_arrays()
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, fixed)
		else:
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1, m)
	return out

const _TEX_PROPS := [
	["albedo_texture", Image.COMPRESS_SOURCE_SRGB],
	["emission_texture", Image.COMPRESS_SOURCE_SRGB],
	["normal_texture", Image.COMPRESS_SOURCE_NORMAL],
	["metallic_texture", Image.COMPRESS_SOURCE_GENERIC],
	["roughness_texture", Image.COMPRESS_SOURCE_GENERIC],
	["ao_texture", Image.COMPRESS_SOURCE_GENERIC],
]

static func _compress_material(m: BaseMaterial3D, swapped: Dictionary) -> void:
	for p in _TEX_PROPS:
		var tex: Variant = m.get(p[0])
		if tex == null or not (tex is Texture2D):
			continue
		var rid: RID = (tex as Texture2D).get_rid()
		if swapped.has(rid):
			m.set(p[0], swapped[rid])
			continue
		var img: Image = (tex as Texture2D).get_image()
		if img == null or img.is_compressed():
			continue
		# S3TC needs 4-aligned dimensions; game textures are POT so odd sizes
		# are rare — leave those raw rather than resampling them
		if img.get_width() < 8 or img.get_height() < 8 \
				or img.get_width() % 4 != 0 or img.get_height() % 4 != 0:
			continue
		if not img.has_mipmaps():
			img.generate_mipmaps()
		if img.compress(Image.COMPRESS_S3TC, p[1]) != OK:
			continue
		var ct := ImageTexture.create_from_image(img)
		swapped[rid] = ct
		m.set(p[0], ct)

static func _fix_importer_meshes(n: Node, root: Node) -> void:
	for c in n.get_children().duplicate():
		if c is ImporterMeshInstance3D:
			var im := c as ImporterMeshInstance3D
			var mi := MeshInstance3D.new()
			mi.transform = im.transform
			if im.mesh != null:
				mi.mesh = im.mesh.get_mesh()
			var nm := String(im.name)
			var idx := im.get_index()
			# reparent grandchildren before the swap
			for gc in im.get_children().duplicate():
				im.remove_child(gc)
				mi.add_child(gc)
			n.remove_child(im)
			im.free()
			mi.name = nm
			n.add_child(mi)
			n.move_child(mi, idx)
			_set_owner_deep(mi, root)
			_fix_importer_meshes(mi, root)
		else:
			_fix_importer_meshes(c, root)

static func _set_owner_deep(n: Node, root: Node) -> void:
	if n != root:
		n.owner = root
	for c in n.get_children():
		_set_owner_deep(c, root)

# ---------- prune ----------
# Delete every stored model NOT in `keep` (proxy-name keyed). Used when the
# sync scope drops to "current scene only" — anything pruned re-downloads on
# demand, so this is the disk-space lever that replaced Purge.
static func prune_keep(keep: Dictionary) -> int:
	_load()
	var n := 0
	var models: Dictionary = _index["models"]
	for name in models.keys().duplicate():
		if keep.has(name):
			continue
		var p := model_path(name)
		if FileAccess.file_exists(p):
			if DirAccess.remove_absolute(p) == OK:
				n += 1
		# Variant models sit next to the base as <name>__<label>.glb and are
		# deliberately NOT in the index (discovery is a directory glob), so this
		# loop walked straight past them and left them on disk with nothing left
		# to reference them.
		for vp in variant_files(name):
			if DirAccess.remove_absolute(vp) == OK:
				n += 1
		models.erase(name)
		_invalidate(name)
	save()
	return n

