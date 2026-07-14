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
	DirAccess.make_dir_recursive_absolute(ROOT)
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

static func thumb_path(name: String) -> String:
	return "%s/%s.png" % [THUMBS_DIR, name]

static func count() -> int:
	return models().size()

# scope of the background sync: "" = not chosen yet, "full" = whole library,
# "scene" = only what open scenes use
static func scope() -> String:
	_load()
	return str(_index.get("scope", ""))

static func set_scope(s: String) -> void:
	_load()
	_index["scope"] = s
	save()

# ---------- ingest ----------
# Record a model already on disk (migration) or write+record bytes (download).
static func record(name: String, h: String, nofit_flag: bool) -> void:
	_load()
	_index["models"][name] = {"hash": h, "nofit": nofit_flag}
	_dirty += 1
	save(false)
	_invalidate(name)

static func ingest_bytes(name: String, data: PackedByteArray, h: String, nofit_flag: bool) -> bool:
	DirAccess.make_dir_recursive_absolute(MODELS_DIR)
	var f := FileAccess.open(model_path(name), FileAccess.WRITE)
	if f == null: return false
	f.store_buffer(data)
	f.close()
	record(name, h, nofit_flag)
	return true

static func _invalidate(name: String) -> void:
	_scene_cache.erase(name)
	if FileAccess.file_exists(thumb_path(name)):
		DirAccess.remove_absolute(thumb_path(name))

static func clear_scene_cache() -> void:
	_scene_cache.clear()

# Content hash matching the registry's (publish.py: sha1(bytes)[:12]) — lets
# any local file be verified against a manifest hash without re-downloading.
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
static func compress_scene_textures(root: Node) -> void:
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
			_compress_material(m as BaseMaterial3D, swapped)
		# normal-mapped surfaces need TANGENTS or the renderer warns per draw
		# (runtime-parsed GLBs ship without them) — generate once at parse
		if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
			var mi2 := n as MeshInstance3D
			mi2.mesh = _ensure_tangents(mi2.mesh as ArrayMesh)
		for c in n.get_children():
			stack.append(c)

# Rebuild any surface that has a normal-mapped material but no tangent array.
# SurfaceTool.generate_tangents = MikkTSpace, one-time per model per session.
static func _ensure_tangents(mesh: ArrayMesh) -> ArrayMesh:
	var needs := false
	for i in range(mesh.get_surface_count()):
		var m := mesh.surface_get_material(i)
		if m is BaseMaterial3D and (m as BaseMaterial3D).normal_texture != null:
			var arr := mesh.surface_get_arrays(i)
			if arr[Mesh.ARRAY_TANGENT] == null and arr[Mesh.ARRAY_TEX_UV] != null \
					and arr[Mesh.ARRAY_NORMAL] != null:
				needs = true
				break
	if not needs:
		return mesh
	var out := ArrayMesh.new()
	for i in range(mesh.get_surface_count()):
		var m := mesh.surface_get_material(i)
		var arr := mesh.surface_get_arrays(i)
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
		models.erase(name)
		_invalidate(name)
	save()
	return n

# ---------- purge ----------
static func purge_all() -> int:
	_load()
	var n := 0
	for d in [MODELS_DIR, THUMBS_DIR]:
		var da := DirAccess.open(d)
		if da == null: continue
		for f in da.get_files():
			if DirAccess.remove_absolute("%s/%s" % [d, f]) == OK:
				n += 1
	_index["models"] = {}
	_scene_cache.clear()
	save()
	return n
