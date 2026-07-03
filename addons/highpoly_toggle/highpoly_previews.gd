@tool
extends Node
class_name HighpolyPreviews
# Swaps the SDK Object Library (scene-library addon) thumbnails to renders of
# the active tier's high/medium-poly assets. Icons are re-asserted on a slow
# timer because the library rebuilds its ItemList on filter/collection changes.
# Stock icons are remembered per item so dropping back to Low-Poly (or purging
# the downloaded models) restores the original thumbnails.

var tier: int = 0                    # HighpolyLib.Tier; LOW = leave stock icons
var _cache: Dictionary = {}          # asset_path -> Texture2D
var _pending: Dictionary = {}        # asset_path -> true
var _orig: Dictionary = {}           # proxy path -> stock Texture2D
var _ours: Dictionary = {}           # texture instance id -> true (icons we set)
var _swapped: bool = false
var _timer: Timer

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
	var ks := HighpolyLib.keys()
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
			var asset: String = HighpolyLib.asset_for(ks[key], tier)
			if asset == "": continue
			if _cache.has(asset):
				var cur: Texture2D = il.get_item_icon(i)
				if cur != _cache[asset]:
					if cur != null and not _ours.has(cur.get_instance_id()):
						_orig[str(md.path)] = cur   # remember the stock icon
					il.set_item_icon(i, _cache[asset])
					_swapped = true
			elif not _pending.has(asset):
				_pending[asset] = true
				EditorInterface.get_resource_previewer().queue_resource_preview(
					asset, self, "_on_preview", asset)

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

func _on_preview(_path: String, preview: Texture2D, _small: Texture2D, userdata: Variant) -> void:
	_pending.erase(str(userdata))
	if preview != null:
		_cache[str(userdata)] = preview
		_ours[preview.get_instance_id()] = true

func _on_stock(_path: String, preview: Texture2D, _small: Texture2D, userdata: Variant) -> void:
	_pending.erase(str(userdata))
	if preview != null:
		_orig[str(userdata)] = preview
