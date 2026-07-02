@tool
extends Node
class_name HighpolyPreviews
# Swaps the SDK Object Library (scene-library addon) thumbnails to renders of
# the active tier's high/medium-poly assets. Icons are re-asserted on a slow
# timer because the library rebuilds its ItemList on filter/collection changes.

var tier: int = 0                    # HighpolyLib.Tier; LOW = leave stock icons
var _cache: Dictionary = {}          # asset_path -> Texture2D
var _pending: Dictionary = {}        # asset_path -> true
var _timer: Timer

func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 2.0
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_timer.start()

func _find_lists() -> Array:
	var out: Array = []
	for il in get_tree().root.find_children("*", "ItemList", true, false):
		if il.item_count > 0:
			var md = il.get_item_metadata(0)
			if md is Dictionary and md.has("path"):
				out.append(il)
	return out

func _refresh() -> void:
	if tier == HighpolyLib.Tier.LOW:
		return
	var ks := HighpolyLib.keys()
	if ks.is_empty(): return
	for il in _find_lists():
		for i in range(il.item_count):
			var md = il.get_item_metadata(i)
			if not (md is Dictionary) or not md.has("path"): continue
			var key: String = str(md.path).get_file().get_basename()
			if not ks.has(key): continue
			var asset: String = HighpolyLib.asset_for(ks[key], tier)
			if asset == "": continue
			if _cache.has(asset):
				if il.get_item_icon(i) != _cache[asset]:
					il.set_item_icon(i, _cache[asset])
			elif not _pending.has(asset):
				_pending[asset] = true
				EditorInterface.get_resource_previewer().queue_resource_preview(
					asset, self, "_on_preview", asset)

func _on_preview(_path: String, preview: Texture2D, _small: Texture2D, userdata: Variant) -> void:
	_pending.erase(str(userdata))
	if preview != null:
		_cache[str(userdata)] = preview
