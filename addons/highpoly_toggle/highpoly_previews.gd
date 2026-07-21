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

var tier: int = 0                    # HighpolyLib.Tier; LOW = leave stock icons
var _cache: Dictionary = {}          # name -> Texture2D
var _pending: Dictionary = {}        # name (or legacy path) -> true
var _orig: Dictionary = {}           # proxy path -> stock Texture2D
var _ours: Dictionary = {}           # texture instance id -> true (icons we set)
var _swapped: bool = false
var _timer: Timer
var _queue: Array = []               # names waiting for a local render
var _busy := false

var _vp: SubViewport = null
var _cam: Camera3D = null

func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 2.0
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_timer.start()

func clear_cache() -> void:
	# downloaded models changed on disk (purge/update): drop stale previews
	_cache.clear()
	_pending.clear()
	_queue.clear()

# a specific model was re-downloaded: just its thumb goes stale
func invalidate(nm: String) -> void:
	_cache.erase(nm)
	_pending.erase(nm)

func _find_lists() -> Array:
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
	return out

func _refresh() -> void:
	if tier == HighpolyLib.Tier.LOW:
		if _swapped:
			_restore()
		return
	var ks := HighpolyLib.known()
	if ks.is_empty():
		if _swapped:
			_restore()
		return
	for il in _find_lists():
		for i in range(il.item_count):
			var md = il.get_item_metadata(i)
			if not (md is Dictionary) or not md.has("path"): continue
			var key: String = str(md.path).get_file().get_basename()
			if not ks.has(key): continue
			if not bool(ks[key]): continue     # registry-only: no local model yet
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
	var tp := HighpolyStore.thumb_path(nm)
	if FileAccess.file_exists(tp):
		var img := Image.load_from_file(ProjectSettings.globalize_path(tp))
		if img != null:
			_finish(nm, ImageTexture.create_from_image(img))
			return
	var ps := HighpolyStore.load_scene(nm)
	if ps == null:
		_pending.erase(nm)
		return
	_ensure_viewport()
	var inst := ps.instantiate() as Node3D
	if inst == null:
		_pending.erase(nm)
		return
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
