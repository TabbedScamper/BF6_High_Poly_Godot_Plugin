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

static func load_external_glb(user_path: String) -> PackedScene:
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
	var ps := PackedScene.new()
	if ps.pack(scene) != OK:
		scene.free()
		return null
	scene.free()
	return ps

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
