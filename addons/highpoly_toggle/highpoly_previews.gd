@tool
extends Node
class_name HighpolyPreviews
# Swaps the SDK Object Library (scene-library addon) thumbnails to renders of
# the high-poly models while a detail mode is active. Icons are re-asserted on
# a slow timer because the library rebuilds its ItemList on filter/collection
# changes; stock icons are remembered per item so dropping back to Low-Poly
# restores the originals.
#
# v1.5: models live in user:// (un-imported), which EditorResourcePreview
# can't render — so thumbnails are rendered locally in an off-screen
# SubViewport (one at a time, lazily, only for visible items) and cached to
# user://highpoly/thumbs/<Name>.png. A model update invalidates its thumb via
# the store. Legacy (pre-migration) installs keep the editor previewer.

const THUMB_SIZE := 128

var tier: int = 0                    # HighpolyLib.Tier, mirrored from the dock
var textured: bool = true            # dock's "High-Poly textured" vs grey
# Icons follow the Detail Mode rather than switching off in Low-Poly, so the one
# remaining reason to put the stock icons back is the plugin letting go entirely.
var active: bool = true
var _tag: String = "tex"             # render the cache currently holds
var _cache: Dictionary = {}          # name -> Texture2D
var _pending: Dictionary = {}        # name (or legacy path) -> true
var _orig: Dictionary = {}           # proxy path -> stock Texture2D
var _ours: Dictionary = {}           # texture instance id -> true (icons we set)
var _swapped: bool = false
var _gs_id: int = 0                  # the game source the cached icons came from
var _timer: Timer
var _queue: Array = []               # names waiting for a local render
var _busy := false

var _vp: SubViewport = null
var _cam: Camera3D = null

# ---------- second source of local geometry: the map-context prop cache ----------
# "Original map objects" downloads the level's own meshes into
# user://mapcontext/_props, keyed by GAME MESH name. The library is keyed by SDK
# PROXY name and lives in user://highpoly/models. Those are different stores, so
# a prop whose geometry was already pulled down by the map context still showed
# the SDK's stock icon: the thumbnail only appeared once the item was DROPPED into
# a scene, which is what finally fetched the library copy.
#
# The two are bridged by the manifest itself. HighpolyStore.remote[proxy].glb is
# "godot/<GameMesh>.glb", so the game-mesh name for any proxy is already known
# without a second lookup table.
#
# Measured on this install: 202 proxies renderable from the library, 1,077 more
# already on disk via the map context and showing a stock icon for no reason.
#
# The index and the resolver moved to HighpolyStore once the overlay needed them
# too (ctx:// stand-ins). One scan, one rule about which store wins, shared.

# The map context finished downloading meshes: re-scan so their proxies stop
# showing stock icons without waiting for the user to place one.
func rescan_context() -> void:
	HighpolyStore.ctx_scan(true)
	_cache.clear()
	_pending.clear()
	_queue.clear()

# THE GAME FIRST, exactly as the library resolves a placed prop.
#
# An icon should be a picture of what dropping the item actually produces, and
# what it produces now is assembled from the install. This used to know two
# sources: a downloaded model, and there are no downloads any more, or a
# map-context bake, which exists only for props the open level happens to
# contain. Everything else showed the SDK's white blockout, including every
# object the install can assemble perfectly well.
#
# -> "game" when the install can build it, else a path, else "".
func _source_for(nm: String) -> String:
	if HighpolyLib.game_source != null and HighpolyLib.game_source.has_object(nm):
		return "game"
	return _local_glb(nm)


# Which store a picture came from, so a render from one is never served as the
# other. The map-context bake is a distance-streaming copy (merged parts,
# half-res basecolor) and must not masquerade as the assembled model.
func _tag_suffix(nm: String, src: String) -> String:
	if src == "game":
		return "_game"
	if src == HighpolyStore.model_path(nm):
		return ""
	return "_ctx"


# Local geometry we can render for this proxy, or "" if there is none.
func _local_glb(nm: String) -> String:
	# CALLED PER ITEM, PER 2 s TICK, and it stats the disk. Timed separately
	# because a file_exists() for every entry in the Object Library twice a
	# minute is the kind of cost that hides inside a loop nobody suspects.
	HighpolyProfile.begin("previews: _source_for (disk stat per item)")
	var r := _source_for_body(nm)
	HighpolyProfile.end("previews: _source_for (disk stat per item)")
	return r


func _source_for_body(nm: String) -> String:
	var p := HighpolyStore.model_path(nm)
	if FileAccess.file_exists(p):
		return p
	return HighpolyStore.ctx_model_path(nm)

func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 2.0
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_timer.start()

# The plugin is letting go: put the SDK's own icons back, now, before this node
# is freed. Low-Poly used to double as "icons off", so teardown got the stock
# icons back for free by resetting the dropdown. Low-Poly is a real render now,
# so switching off has to be said explicitly or the Object Library keeps showing
# our thumbnails with the plugin disabled.
func shutdown() -> void:
	active = false
	if _swapped:
		_restore()

func clear_cache() -> void:
	# downloaded models changed on disk (purge/update): drop stale previews
	_cache.clear()
	_pending.clear()
	_queue.clear()

# a specific model was re-downloaded: just its thumb goes stale
func invalidate(nm: String) -> void:
	_cache.erase(nm)
	_pending.erase(nm)

# SUSPECT IN THE 2-SECOND STALL. Fitting frame time against draw calls on a
# worst-case flight leaves 48 residual outliers of 70-145 ms that rendering does
# not explain, spaced about 2 s apart - and this runs on a 2 s timer and walks
# the WHOLE editor tree looking for ItemLists. Timed separately from the rest of
# _refresh so the walk can be convicted or cleared on its own, rather than the
# whole refresh being blamed for whichever part is actually slow.
func _find_lists() -> Array:
	HighpolyProfile.begin("previews: walk the editor tree for ItemLists")
	var r := _find_lists_body()
	HighpolyProfile.end("previews: walk the editor tree for ItemLists")
	return r


# The ItemLists we found last time, and when we last went looking.
#
# MEASURED: the full-tree search below costs 28.8 ms on average and peaked at
# 31.19 ms, and it ran every 2 s forever - 979 ms of a 69.5 s run, and the
# single biggest instrumented cost in the plugin. It showed up as a rhythmic
# lag spike. find_children() on the editor root walks the ENTIRE editor UI, and
# the answer almost never changes.
var _lists_cache: Array = []
var _lists_found_at := 0

# How long to wait before searching again when the last search found NOTHING.
# A hit is validated cheaply and reused indefinitely, but a miss has nothing to
# validate, so it needs a clock or a closed Object Library would put the full
# walk back on every tick.
const LISTS_RETRY_MS := 10000


func _find_lists_body() -> Array:
	# Reuse while every cached list is still alive and still populated. This is
	# a handful of pointer checks against a walk of the whole editor tree.
	if not _lists_cache.is_empty():
		var ok := true
		for il in _lists_cache:
			if not is_instance_valid(il) or il.item_count == 0:
				ok = false
				break
		if ok:
			return _lists_cache
		_lists_cache = []
	# A miss is rate limited: nothing found means nothing to validate, and
	# searching every 2 s for something that is not there is what this fixes.
	if _lists_cache.is_empty() and _lists_found_at > 0 \
			and Time.get_ticks_msec() - _lists_found_at < LISTS_RETRY_MS:
		return _lists_cache
	_lists_found_at = Time.get_ticks_msec()
	var out: Array = []
	for il in get_tree().root.find_children("*", "ItemList", true, false):
		if il.item_count == 0:
			continue
		# folder rows (FX/SFX) sit first, so scan a few items for a real asset
		for i in range(mini(il.item_count, 6)):
			var md = il.get_item_metadata(i)
			if md is Dictionary and md.has("path"):
				out.append(il)
				break
	_lists_cache = out
	return out

# Which render the current Detail Mode wants. Low-Poly draws our geometry in
# clay, so its thumbnails are clay too: the icon in the Object Library now shows
# what dropping the item will actually put in the scene, in either mode.
func _mode_tag() -> String:
	return "clay" if (tier == HighpolyLib.Tier.LOW or not textured) else "tex"

func _refresh() -> void:
	# The whole 2 s tick, so the tree walk above can be compared against what
	# the rest of the refresh costs instead of guessing which half matters.
	HighpolyProfile.begin("previews: 2 s refresh")
	_refresh_body()
	HighpolyProfile.end("previews: 2 s refresh")


func _refresh_body() -> void:
	if not active:
		if _swapped:
			_restore()
		return
	# A mode switch changes what every icon should look like. The in-memory cache
	# is keyed by name only, so it is dropped wholesale rather than served across
	# modes; the on-disk cache IS per mode, so this costs a PNG read, not a
	# re-render of the whole library.
	var tag := _mode_tag()
	if tag != _tag:
		_tag = tag
		_cache.clear()
		_pending.clear()
		_queue.clear()
	# THE INSTALL OPENING IS ALSO A CHANGE OF WHAT AN ICON SHOULD BE.
	#
	# The in-memory cache is keyed by NAME, so it cannot tell a picture rendered
	# from a map-context bake apart from one assembled out of the game. Before
	# the install is read the bake is the best available answer; the moment it is
	# read it stops being. Without this the browser keeps serving the half-res
	# distance copy for the rest of the session, and only the props the level
	# happens to contain have an icon at all.
	var gsid: int = HighpolyLib.game_source.get_instance_id() \
		if HighpolyLib.game_source != null else 0
	if gsid != _gs_id:
		_gs_id = gsid
		_cache.clear()
		_pending.clear()
		_queue.clear()
	HighpolyStore.ctx_scan()
	var ks := HighpolyLib.known()
	if ks.is_empty():
		if _swapped:
			_restore()
		return
	# THE REMAINING 2-SECOND STALL. With the editor-tree walk cached out, what is
	# left of this tick is 432.4 ms over 33 calls - 13.1 ms every 2 s, peaking at
	# 19.5 ms - and it is now the largest recurring cost in the plugin. Timed as
	# a whole before blaming any part of it, because the last two things I was
	# sure about here were both wrong.
	HighpolyProfile.begin("previews: per-item icon pass")
	for il in _find_lists():
		for i in range(il.item_count):
			var md = il.get_item_metadata(i)
			if not (md is Dictionary) or not md.has("path"): continue
			var key: String = str(md.path).get_file().get_basename()
			if not ks.has(key): continue
			# `ks[key]` is false for registry-only proxies, but that only means the
			# LIBRARY has not got it. The map context may already hold the same
			# geometry, so ask for any local source rather than trusting that flag.
			# ks[key] only says the SDK ships this proxy. Whether we can DRAW it
			# is a different question, and the renderer is about to ask it, so
			# ask it here rather than queue work that cannot finish.
			# ASKED ONLY WHEN THERE IS NO THUMBNAIL YET. _source_for stats the
			# disk, and it ran for every item on every 2 s tick - a measured
			# 2,272 calls and 77.7 ms per run - including for items whose
			# picture was already made and needed no source at all. An item in
			# the cache is drawable by definition: its thumbnail was rendered
			# from that source in the first place.
			if not _cache.has(key) and _source_for(key) == "": continue
			if _cache.has(key):
				var cur: Texture2D = il.get_item_icon(i)
				if cur != _cache[key]:
					if cur != null and not _ours.has(cur.get_instance_id()):
						_orig[str(md.path)] = cur   # remember the stock icon
					il.set_item_icon(i, _cache[key])
					_swapped = true
			elif not _pending.has(key):
				_pending[key] = true
				if HighpolyLib.use_legacy:
					EditorInterface.get_resource_previewer().queue_resource_preview(
						"%s/%s/%s.glb" % [HighpolyLib.LEGACY_DIR, key, key],
						self, "_on_editor_preview", key)
				else:
					_queue.append(key)
	HighpolyProfile.end("previews: per-item icon pass")
	_render_next()

func _restore() -> void:
	var missing := false
	for il in _find_lists():
		for i in range(il.item_count):
			var cur: Texture2D = il.get_item_icon(i)
			if cur == null or not _ours.has(cur.get_instance_id()):
				continue                           # not an icon we swapped
			var md = il.get_item_metadata(i)
			if not (md is Dictionary) or not md.has("path"): continue
			var p := str(md.path)
			if _orig.has(p):
				il.set_item_icon(i, _orig[p])
			else:
				missing = true                     # regenerate the stock preview
				if not _pending.has(p):
					_pending[p] = true
					EditorInterface.get_resource_previewer().queue_resource_preview(
						p, self, "_on_stock", p)
	_swapped = missing                             # retry next tick until clean

func _on_editor_preview(_path: String, preview: Texture2D, _small: Texture2D, userdata: Variant) -> void:
	_pending.erase(str(userdata))
	if preview != null:
		_cache[str(userdata)] = preview
		_ours[preview.get_instance_id()] = true

func _on_stock(_path: String, preview: Texture2D, _small: Texture2D, userdata: Variant) -> void:
	_pending.erase(str(userdata))
	if preview != null:
		_orig[str(userdata)] = preview

# ---------- local thumbnail renders (store models) ----------
func _ensure_viewport() -> void:
	if _vp != null: return
	_vp = SubViewport.new()
	_vp.size = Vector2i(THUMB_SIZE, THUMB_SIZE)
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.2
	_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.4
	_vp.add_child(fill)
	_cam = Camera3D.new()
	_vp.add_child(_cam)

func _render_next() -> void:
	if _busy or _queue.is_empty(): return
	_busy = true
	var nm: String = _queue.pop_front()
	await _render_one(nm)
	_busy = false
	_render_next.call_deferred()

func _render_one(nm: String) -> void:
	# disk cache first (thumbs survive editor restarts; store invalidates on update)
	# The tag records WHICH STORE the picture came from as well as the mode.
	# Without the _ctx half, a stand-in render and the real library render share
	# one file: place an item, the library copy arrives, and the icon keeps
	# showing the half-res distance bake with nothing to say it is stale.
	var src0 := _source_for(nm)
	var tag := _mode_tag() + _tag_suffix(nm, src0)
	var tp := HighpolyStore.thumb_path(nm, tag)
	if FileAccess.file_exists(tp):
		var img := Image.load_from_file(ProjectSettings.globalize_path(tp))
		if img != null:
			_finish(nm, ImageTexture.create_from_image(img))
			return
	# Deliberately NOT HighpolyStore.load_scene(): that caches under the proxy
	# name, so a map-context mesh loaded through it would be served later as the
	# library model for the same name. Thumbnails are cached as PNGs anyway, so
	# there is nothing to gain by holding the scene.
	var src := src0
	if src == "":
		_pending.erase(nm)
		return
	var inst: Node3D = null
	if src == "game":
		# The same call the library makes for a placed prop, so the icon and the
		# thing you drop are built by one path and cannot disagree about what the
		# object looks like.
		inst = HighpolyLib.game_source.object_node(nm)
	else:
		var ps: PackedScene = HighpolyStore.load_scene(nm) \
			if src == HighpolyStore.model_path(nm) \
			else HighpolyStore.load_ctx_scene(src)
		if ps != null:
			inst = ps.instantiate() as Node3D
	if inst == null:
		_pending.erase(nm)
		return
	_ensure_viewport()
	# Skin the render the same way the scene will be skinned, so the icon is a
	# picture of what dropping this item actually produces.
	if _mode_tag() == "clay":
		var stack: Array = [inst]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is GeometryInstance3D:
				(n as GeometryInstance3D).material_override = HighpolyLib.gray_material()
			for c in n.get_children():
				stack.append(c)
	_vp.add_child(inst)
	var ab := _merged_aabb(inst)
	if ab.size.length() < 0.001:
		_vp.remove_child(inst); inst.free()
		_pending.erase(nm)
		return
	var center := ab.get_center()
	var radius: float = ab.size.length() * 0.5
	var dir := Vector3(1.0, 0.7, 1.3).normalized()
	_cam.position = center + dir * (radius * 2.2)
	_cam.look_at(center)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	_vp.remove_child(inst)
	inst.free()
	if img == null:
		_pending.erase(nm)
		return
	HighpolyStore.ensure_dir(HighpolyStore.THUMBS_DIR)
	img.save_png(ProjectSettings.globalize_path(tp))
	_finish(nm, ImageTexture.create_from_image(img))

func _finish(nm: String, tex: Texture2D) -> void:
	_pending.erase(nm)
	if tex != null:
		_cache[nm] = tex
		_ours[tex.get_instance_id()] = true

func _merged_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var g := n as VisualInstance3D
			var ab: AABB = g.global_transform * g.get_aabb()
			if first: out = ab; first = false
			else: out = out.merge(ab)
		for c in n.get_children():
			stack.append(c)
	return out
