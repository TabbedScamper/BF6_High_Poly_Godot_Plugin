@tool
extends EditorPlugin
# Low / Medium / High-poly interchange for Portal SDK level building.
# - Mode selector drives the whole scene AND newly placed pieces (placement
#   stays the low-poly proxy; the visual overlay attaches automatically).
# - Object Library thumbnails render the active tier's asset.
# - Textured toggle swaps overlays to flat gray (geometry study mode).

var dock: VBoxContainer
var lbl: Label
var mode_btn: OptionButton
var tex_chk: CheckBox
const PreviewsScript = preload("res://addons/highpoly_toggle/highpoly_previews.gd")
const TurboScript = preload("res://addons/highpoly_toggle/highpoly_turbo.gd")
const MapContextScript = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
var previews: Node
var turbo: Node
var mapctx: Node
var mapctx_btn: OptionButton
var mapctx_timer: Timer

func _mode() -> int:
	return mode_btn.get_selected_id() if mode_btn else HighpolyLib.Tier.LOW

func _textured() -> bool:
	return tex_chk.button_pressed if tex_chk else true

func _enter_tree() -> void:
	dock = VBoxContainer.new()
	dock.name = "High-Poly"

	var title := Label.new()
	title.text = "Detail Mode"
	dock.add_child(title)

	mode_btn = OptionButton.new()
	mode_btn.add_item("Low-Poly (proxies)", HighpolyLib.Tier.LOW)
	mode_btn.add_item("Medium-Poly", HighpolyLib.Tier.MEDIUM)
	mode_btn.add_item("High-Poly", HighpolyLib.Tier.HIGH)
	mode_btn.item_selected.connect(func(_i): _mode_changed())
	dock.add_child(mode_btn)

	tex_chk = CheckBox.new()
	tex_chk.text = "Textured"
	tex_chk.button_pressed = true
	tex_chk.toggled.connect(func(_v): _mode_changed())
	dock.add_child(tex_chk)

	var apply_btn := Button.new(); apply_btn.text = "Re-apply Scene"
	apply_btn.pressed.connect(_apply_scene)
	dock.add_child(apply_btn)

	var sep := HSeparator.new(); dock.add_child(sep)

	var sel_hi := Button.new(); sel_hi.text = "Selected → Current Mode"
	sel_hi.pressed.connect(func(): _apply_selected(_mode()))
	dock.add_child(sel_hi)

	var sel_lo := Button.new(); sel_lo.text = "Selected → Low-Poly"
	sel_lo.pressed.connect(func(): _apply_selected(HighpolyLib.Tier.LOW))
	dock.add_child(sel_lo)

	var sep2 := HSeparator.new(); dock.add_child(sep2)

	var upd := Button.new(); upd.text = "Update Models"
	upd.tooltip_text = "Pull corrected models from the community registry (only props deployed locally)"
	upd.pressed.connect(func():
		previews.clear_cache()
		HighpolyUpdater.run(dock, func(msg: String): lbl.text = msg))
	dock.add_child(upd)

	var dl_all := Button.new(); dl_all.text = "Download Full Library"
	dl_all.tooltip_text = "One-time bulk install of every medium+high-poly model (multi-GB download). Update Models then only fetches changes."
	dl_all.pressed.connect(_confirm_bundle)
	dock.add_child(dl_all)

	var sepm := HSeparator.new(); dock.add_child(sepm)
	var mc_title := Label.new(); mc_title.text = "Map Context"
	dock.add_child(mc_title)

	mapctx_btn = OptionButton.new()
	mapctx_btn.add_item("Off", 0)
	mapctx_btn.add_item("Surroundings (keep SDK terrain)", 1)
	mapctx_btn.add_item("Full map objects", 2)
	mapctx_btn.add_item("Full map, textured", 3)
	mapctx_btn.tooltip_text = "Editor-only overlay (never saved). \"Surroundings\" keeps the SDK's playable terrain and adds the out-of-bounds landscape; \"Full map\" adds the real terrain + the game's original object placements."
	mapctx_btn.item_selected.connect(func(_i): _mapctx_changed())
	dock.add_child(mapctx_btn)

	var mcr_row := HBoxContainer.new(); dock.add_child(mcr_row)
	var mcr_lbl := Label.new(); mcr_lbl.text = "Range"
	mcr_row.add_child(mcr_lbl)
	var mcr := HSlider.new()
	mcr.min_value = 128; mcr.max_value = 4096; mcr.step = 64; mcr.value = 768
	mcr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mcr.tooltip_text = "How far from the camera to show map objects (like a render distance)."
	mcr_row.add_child(mcr)
	var mcr_val := Label.new(); mcr_val.text = "768m"
	mcr_row.add_child(mcr_val)
	mcr.value_changed.connect(func(v: float):
		mcr_val.text = "%dm" % int(v)
		mapctx.set_radius(v))

	var mc_reload := Button.new(); mc_reload.text = "Reload map data"
	mc_reload.tooltip_text = "Re-download any map pieces that didn't come in (e.g. throttled) and rebuild the current mode."
	mc_reload.pressed.connect(_mapctx_reload)
	dock.add_child(mc_reload)

	var sep3 := HSeparator.new(); dock.add_child(sep3)
	var turbo_title := Label.new(); turbo_title.text = "Turbo"
	dock.add_child(turbo_title)

	var dist_row := HBoxContainer.new(); dock.add_child(dist_row)
	var dist_lbl := Label.new(); dist_lbl.text = "Cull dist"
	dist_row.add_child(dist_lbl)
	var dist := HSlider.new()
	dist.min_value = 0; dist.max_value = 500; dist.step = 10
	dist.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dist.tooltip_text = "Hide geometry beyond this distance (0 = off). Renderer-native, never saved."
	dist_row.add_child(dist)
	var dist_val := Label.new(); dist_val.text = "off"
	dist_row.add_child(dist_val)
	dist.value_changed.connect(func(v: float):
		dist_val.text = "off" if v <= 0 else "%dm" % int(v)
		turbo.cull_distance = v
		turbo.apply_distance())

	var frus := CheckBox.new(); frus.text = "Cull behind camera (static map)"
	frus.tooltip_text = "Aggressively hides static map geometry outside your view so it skips shadow passes too"
	frus.toggled.connect(func(v: bool): turbo.set_frustum(v))
	dock.add_child(frus)

	var shad := CheckBox.new(); shad.text = "Static map shadows"
	shad.button_pressed = true
	shad.tooltip_text = "Uncheck to stop static scenery casting shadows (large editor FPS win)"
	shad.toggled.connect(func(v: bool):
		turbo.static_shadows = v
		turbo.apply_shadows())
	dock.add_child(shad)

	var purge := Button.new(); purge.text = "Purge Local Models"
	purge.tooltip_text = "Delete all downloaded preview models (res://highpoly). Proxies and your scene are unaffected; re-deploy or Update Models to get previews back."
	purge.pressed.connect(_confirm_purge)
	dock.add_child(purge)

	lbl = Label.new()
	lbl.text = "%d high-poly assets available" % HighpolyLib.keys().size()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(lbl)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

	previews = PreviewsScript.new()
	dock.add_child(previews)
	turbo = TurboScript.new()
	dock.add_child(turbo)
	turbo.refresh.call_deferred()
	mapctx = MapContextScript.new()
	dock.add_child(mapctx)
	mapctx_timer = Timer.new(); mapctx_timer.wait_time = 0.5
	mapctx_timer.timeout.connect(func(): if mapctx: mapctx.tick())
	dock.add_child(mapctx_timer); mapctx_timer.start()

	# every session starts safe: Low-Poly until a mode is chosen
	mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
	previews.tier = HighpolyLib.Tier.LOW

	# auto-overlay for pieces placed while a detail mode is active
	get_tree().node_added.connect(_on_node_added)

func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()

func _mapctx_reload() -> void:
	# explicit retry: OptionButton doesn't re-fire when you pick the same mode,
	# so this button force-downloads missing pieces and rebuilds the current mode
	var m := mapctx_btn.get_selected_id()
	var r := EditorInterface.get_edited_scene_root()
	var rn := "<none>" if r == null else String(r.name)
	var map: String = mapctx.map_of(r)
	print("[MapContext] Reload pressed — scene root='%s', detected map='%s', mode=%d" % [rn, map, m])
	if map == "":
		lbl.text = "Scene root is '%s' — open an MP_… level scene" % rn; return
	if m == 0:
		lbl.text = "Pick a Map Context mode first (dropdown)"; return
	print("[MapContext] before: " + mapctx.cache_status(map))
	lbl.text = "Reloading %s map data…" % map
	var ok: bool = await mapctx.download_map(dock, map, func(s: String): lbl.text = s)
	print("[MapContext] after:  " + mapctx.cache_status(map))
	if ok:
		var res: String = mapctx.apply(r, m)
		print("[MapContext] apply -> " + res)
		lbl.text = res
	else:
		lbl.text = "Could not fetch %s map data (see Output)" % map

func _mapctx_changed() -> void:
	var m := mapctx_btn.get_selected_id()
	var r := EditorInterface.get_edited_scene_root()
	var rn := "<none>" if r == null else String(r.name)
	var map: String = mapctx.map_of(r)
	print("[MapContext] mode changed -> id=%d, scene root='%s', map='%s'" % [m, rn, map])
	if m == 0 or map == "":
		if map == "" and m != 0:
			lbl.text = "Scene root is '%s' — open an MP_… level scene" % rn
		else:
			lbl.text = mapctx.apply(r, 0)
		return
	if mapctx.has_data(map):
		# already have the manifest — top up any missing pieces (idempotent,
		# offline-fast when complete), then apply
		print("[MapContext] have manifest; ensuring data complete then applying…")
		lbl.text = "Loading %s…" % map
		await mapctx.download_map(dock, map, func(s: String): lbl.text = s)
		var res: String = mapctx.apply(r, m)
		print("[MapContext] apply -> " + res)
		lbl.text = res; return
	# not downloaded yet — prompt
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Map data for %s isn't downloaded yet.\nDownload the terrain + object layout now? (~tens of MB, one time per map)" % map
	dlg.ok_button_text = "Download"
	dlg.cancel_button_text = "Cancel"
	dlg.confirmed.connect(func():
		lbl.text = "Downloading map data…"
		var ok: bool = await mapctx.download_map(dock, map, func(s: String): lbl.text = s)
		if ok:
			lbl.text = mapctx.apply(r, m)
		else:
			mapctx_btn.select(0)
			lbl.text = mapctx.apply(r, 0))
	dlg.canceled.connect(func():
		mapctx_btn.select(0)
		lbl.text = mapctx.apply(r, 0)
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _mode_changed() -> void:
	previews.tier = _mode()
	if _mode() == HighpolyLib.Tier.LOW:
		_apply_scene()
		return
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		_apply_scene()
		return
	# do we have everything this scene needs for the chosen tier?
	lbl.text = "Checking models…"
	HighpolyUpdater.scene_available(r, dock, func(n: int):
		if n <= 0:
			_apply_scene()                 # all present (or nothing downloadable) -> just apply
		else:
			_prompt_download(n))

func _prompt_download(n: int) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "%d model(s) for this scene aren't downloaded yet.\nDownload them now to preview at this detail level?" % n
	dlg.ok_button_text = "Download"
	dlg.cancel_button_text = "Stay Low-Poly"
	dlg.confirmed.connect(func():
		lbl.text = "Downloading…"
		var got: bool = await HighpolyUpdater.download_for_scene(dock, EditorInterface.get_edited_scene_root(),
			func(msg: String): lbl.text = msg)
		previews.clear_cache()
		if got:
			_apply_scene()
		else:
			_revert_low())
	dlg.canceled.connect(func():
		_revert_low()
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _revert_low() -> void:
	mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
	previews.tier = HighpolyLib.Tier.LOW
	_apply_scene()

func _apply_scene() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"; return
	var n := HighpolyLib.apply(r, _mode(), _textured())
	lbl.text = "%s: %d piece(s)" % [mode_btn.get_item_text(mode_btn.selected), n]

func _apply_selected(tier: int) -> void:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if sel.is_empty():
		lbl.text = "Nothing selected"; return
	var n := 0
	for s in sel:
		n += HighpolyLib.apply(s, tier, _textured())
	lbl.text = "Selected -> %d piece(s)" % n

func _confirm_bundle() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Download the FULL model library (every medium + high-poly model)?
This is a large one-time download (multiple GB). After it finishes, Update Models only fetches changes."
	dlg.ok_button_text = "Download"
	dlg.confirmed.connect(func():
		previews.clear_cache()
		await HighpolyUpdater.download_bundle(dock, func(msg: String): lbl.text = msg))
	dlg.canceled.connect(dlg.queue_free)
	EditorInterface.popup_dialog_centered(dlg)

func _confirm_purge() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Delete ALL downloaded preview models from res://highpoly?
Your scene and the low-poly proxies are not affected."
	dlg.ok_button_text = "Purge"
	dlg.confirmed.connect(func():
		# drop overlays first so nothing references the files
		var r := EditorInterface.get_edited_scene_root()
		if r != null:
			HighpolyLib.apply(r, HighpolyLib.Tier.LOW, true)
		mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
		previews.tier = HighpolyLib.Tier.LOW
		previews.clear_cache()
		var n := HighpolyLib.purge_all()
		EditorInterface.get_resource_filesystem().scan()
		lbl.text = "Purged %d model folder(s)" % n)
	dlg.canceled.connect(dlg.queue_free)
	EditorInterface.popup_dialog_centered(dlg)

func _on_node_added(node: Node) -> void:
	if _mode() == HighpolyLib.Tier.LOW: return
	if not (node is Node3D): return
	if node.name == HighpolyLib.HP_NODE: return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root.is_ancestor_of(node): return
	if HighpolyLib.in_overlay(node): return
	if HighpolyLib.match_key_public(node) == "": return
	# defer: let the editor finish placing/naming/positioning the instance
	_swap_deferred.call_deferred(node)

func _swap_deferred(node: Node) -> void:
	if not is_instance_valid(node) or not (node is Node3D): return
	if node.get_node_or_null(HighpolyLib.HP_NODE) != null: return
	var ks := HighpolyLib.keys()
	var k := HighpolyLib.match_key_public(node)
	if k == "": return
	HighpolyLib.apply_one(node as Node3D, ks[k], _mode(), _textured())
