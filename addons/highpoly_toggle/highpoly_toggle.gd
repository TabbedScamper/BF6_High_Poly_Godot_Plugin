@tool
extends EditorPlugin
# Low / High-poly interchange for Portal SDK level building.
# v1.5: zero model-management buttons. A background sync (highpoly_sync.gd)
# downloads the open scene's props first, then (in "full" scope) the rest of
# the library; overlays swap in automatically as models land; stale models and
# map data re-download themselves. The dock shows one progress bar + pause.

var dock: VBoxContainer
var lbl: Label
var mode_btn: OptionButton
# relative preloads: the plugin works from ANY folder under addons/ (users
# often drop the whole repo zip in, nesting the plugin one level deeper)
const PreviewsScript = preload("highpoly_previews.gd")
const TurboScript = preload("highpoly_turbo.gd")
const MapContextScript = preload("highpoly_mapcontext.gd")
const SyncScript = preload("highpoly_sync.gd")
var previews: Node
var turbo: Node
var mapctx: Node
var sync: Node
var mapctx_on: CheckBox        # Map Context enabled
var mapctx_objects: CheckBox   # show original map objects
var mapctx_tex: CheckBox       # show textures (else flat SDK green/orange)
var mapctx_timer: Timer
var update_btn: Button         # "Update Plugin → vX.Y.Z" — hidden until a newer version exists
var banner: Label              # legacy-mode notice ("reorganization pending")
var progress: ProgressBar
var sync_lbl: Label
var pause_btn: Button
var purge_btn: Button
var _edited_root: Node = null  # tracks the active scene to detect tab switches
var _ready_names: Dictionary = {}   # models that landed since the last swap-in pass
var _swap_timer: Timer

# dropdown ids: 0 = Low-Poly, 1 = High-Poly grey, 2 = High-Poly textured
func _mode() -> int:
	if mode_btn == null: return HighpolyLib.Tier.LOW
	return HighpolyLib.Tier.LOW if mode_btn.get_selected_id() == 0 else HighpolyLib.Tier.HIGH

func _textured() -> bool:
	return mode_btn.get_selected_id() == 2 if mode_btn else true

func _enter_tree() -> void:
	dock = VBoxContainer.new()
	dock.name = "High-Poly"

	# plugin self-update: hidden unless the registry advertises a newer version
	update_btn = Button.new()
	update_btn.visible = false
	update_btn.pressed.connect(_do_plugin_update)
	dock.add_child(update_btn)

	banner = Label.new()
	banner.visible = false
	banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	dock.add_child(banner)

	# ---- sync progress (the whole "model management UI" in 1.5) ----
	progress = ProgressBar.new()
	progress.min_value = 0.0
	progress.max_value = 1.0
	progress.visible = false
	dock.add_child(progress)
	sync_lbl = Label.new()
	sync_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sync_lbl.add_theme_font_size_override("font_size", 12)
	dock.add_child(sync_lbl)
	pause_btn = Button.new()
	pause_btn.text = "Pause downloads"
	pause_btn.visible = false
	pause_btn.tooltip_text = "Pause/resume the background model sync (e.g. on a metered connection)."
	pause_btn.pressed.connect(func():
		sync.paused = not sync.paused
		pause_btn.text = "Resume downloads" if sync.paused else "Pause downloads")
	dock.add_child(pause_btn)

	var title := Label.new()
	title.text = "Detail Mode"
	dock.add_child(title)

	mode_btn = OptionButton.new()
	mode_btn.add_item("Low-Poly (default)", 0)
	mode_btn.add_item("High-Poly — no textures", 1)
	mode_btn.add_item("High-Poly — textured", 2)
	mode_btn.selected = 0
	mode_btn.item_selected.connect(func(_i): _mode_changed())
	dock.add_child(mode_btn)

	var sel_hi := Button.new(); sel_hi.text = "Selected → Current Mode"
	sel_hi.pressed.connect(func(): _apply_selected(_mode()))
	dock.add_child(sel_hi)

	var sel_lo := Button.new(); sel_lo.text = "Selected → Low-Poly"
	sel_lo.pressed.connect(func(): _apply_selected(HighpolyLib.Tier.LOW))
	dock.add_child(sel_lo)

	var sepm := HSeparator.new(); dock.add_child(sepm)
	var mc_title := Label.new(); mc_title.text = "Map Context"
	dock.add_child(mc_title)

	mapctx_on = CheckBox.new()
	mapctx_on.text = "Show map context"
	mapctx_on.tooltip_text = "Editor-only overlay (never saved). Adds the real out-of-bounds terrain + surrounding landscape around the SDK's playable area."
	mapctx_on.toggled.connect(func(_v): _mapctx_changed())
	dock.add_child(mapctx_on)

	mapctx_objects = CheckBox.new()
	mapctx_objects.text = "Original map objects"
	mapctx_objects.tooltip_text = "Also inject the game's original object placements (vehicles, props, antennas, chairs…). The distant terrain/landscape comes in with \"Show map context\"."
	mapctx_objects.toggled.connect(func(_v): _mapctx_changed())
	dock.add_child(mapctx_objects)

	mapctx_tex = CheckBox.new()
	mapctx_tex.text = "Textures"
	mapctx_tex.tooltip_text = "On: real textures. Off: flat SDK study colours (green land, orange objects) that blend with the shipped terrain."
	mapctx_tex.toggled.connect(func(_v): _mapctx_changed())
	dock.add_child(mapctx_tex)

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

	var td_row := HBoxContainer.new(); dock.add_child(td_row)
	var td_lbl := Label.new(); td_lbl.text = "Terrain"
	td_row.add_child(td_lbl)
	var td := OptionButton.new()
	td.add_item("Full (1m)", 1)
	td.add_item("High (2m)", 2)
	td.add_item("Medium (4m)", 4)
	td.select(1)   # High is the default (near-native, performant)
	td.tooltip_text = "Terrain mesh detail, built locally from the full-accuracy heightmap. Full = native 1m (heaviest); built once per level, then cached."
	td.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	td_row.add_child(td)
	td.item_selected.connect(func(_i):
		mapctx.terrain_step = td.get_item_id(td.selected)
		_mapctx_rebuild())

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

	purge_btn = Button.new(); purge_btn.text = "Purge Local Models"
	purge_btn.tooltip_text = "Delete all downloaded preview models. Proxies and your scene are unaffected; the sync re-downloads what your scenes need."
	purge_btn.pressed.connect(_confirm_purge)
	dock.add_child(purge_btn)

	lbl = Label.new()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(lbl)

	var ver_lbl := Label.new()
	ver_lbl.text = "v%s" % HighpolyUpdater.plugin_version()
	ver_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	dock.add_child(ver_lbl)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	_check_plugin_update.call_deferred()

	previews = PreviewsScript.new()
	dock.add_child(previews)
	turbo = TurboScript.new()
	dock.add_child(turbo)
	turbo.refresh.call_deferred()
	mapctx = MapContextScript.new()
	dock.add_child(mapctx)
	sync = SyncScript.new()
	dock.add_child(sync)
	sync.model_ready.connect(_on_model_ready)
	sync.progress_changed.connect(_update_progress)
	sync.manifest_refreshed.connect(_on_manifest_refreshed)
	_swap_timer = Timer.new()
	_swap_timer.one_shot = true
	_swap_timer.wait_time = 0.5
	_swap_timer.timeout.connect(_swap_in_ready)
	dock.add_child(_swap_timer)
	mapctx_timer = Timer.new(); mapctx_timer.wait_time = 0.5
	mapctx_timer.timeout.connect(func():
		_check_scene_change()
		if mapctx: mapctx.tick())
	dock.add_child(mapctx_timer); mapctx_timer.start()
	_edited_root = EditorInterface.get_edited_scene_root()

	# every session starts safe: Low-Poly until a mode is chosen
	mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
	previews.tier = HighpolyLib.Tier.LOW

	# auto-overlay for pieces placed while a detail mode is active
	get_tree().node_added.connect(_on_node_added)

	_startup.call_deferred()

func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	HighpolyStore.save()
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()

# ---------- startup: migration -> scope -> sync ----------
func _startup() -> void:
	if HighpolyMigrate.needed():
		_show_migration_wizard()
		return
	if not HighpolyStore.initialized():
		HighpolyStore.save()          # fresh install: create the store marker
	if HighpolyStore.scope() == "":
		_show_scope_prompt()
		return
	_start_sync()

func _show_migration_wizard() -> void:
	var s: Dictionary = HighpolyMigrate.scan()
	var mb := int(s.model_bytes / 1048576.0)
	var freed := int(s.med_bytes / 1048576.0)
	var lines := [
		"High-Poly Preview 1.5 reorganizes its storage so the editor no longer",
		"imports every downloaded model (much faster startup + updates).",
		"",
		"• Move %d model(s) (%d MB) into the new cache — no re-download" % [s.models, mb],
		"• Delete %d editor import file(s) and %d retired medium-tier model(s) (frees ~%d MB)" % [s.import_files, s.med_files, freed],
	]
	if s.obj_only > 0:
		lines.append("• Re-download %d legacy model(s) in the current format" % s.obj_only)
	lines.append("• Map data re-checks itself automatically from now on")
	lines.append("")
	lines.append("Your scenes, the SDK proxies, and the Portal exporter are not affected.")
	var dlg := ConfirmationDialog.new()
	dlg.title = "High-Poly Preview — one-time reorganization"
	dlg.dialog_text = "\n".join(PackedStringArray(lines))
	dlg.ok_button_text = "Reorganize now"
	dlg.cancel_button_text = "Not yet"
	dlg.confirmed.connect(func():
		HighpolyLib.use_legacy = false
		banner.visible = false
		var res: Dictionary = await HighpolyMigrate.run(dock, func(m: String): sync_lbl.text = m)
		previews.clear_cache()
		if HighpolyStore.scope() == "":
			_show_scope_prompt(res.get("redownload", []))
		else:
			_start_sync(res.get("redownload", [])))
	dlg.canceled.connect(func():
		# fully usable legacy mode; the wizard re-offers next launch
		HighpolyLib.use_legacy = true
		banner.text = "Storage reorganization pending — model sync is paused until it runs (next editor start)."
		banner.visible = true
		purge_btn.visible = false
		lbl.text = "%d high-poly assets available (legacy layout)" % HighpolyLib.known().size()
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _show_scope_prompt(redownload: Array = []) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "High-Poly Preview — model downloads"
	dlg.dialog_text = "How should models download?\n\n" + \
		"Full library: everything syncs quietly in the background\n" + \
		"(one large download, small deltas afterwards). Best if you build a lot.\n\n" + \
		"As needed: only the models your open scenes use."
	dlg.ok_button_text = "Full library"
	dlg.cancel_button_text = "As needed"
	dlg.confirmed.connect(func():
		HighpolyStore.set_scope("full")
		_start_sync(redownload))
	dlg.canceled.connect(func():
		HighpolyStore.set_scope("scene")
		_start_sync(redownload)
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _start_sync(extra: Array = []) -> void:
	lbl.text = "%d models local" % HighpolyStore.count()
	await sync.start()
	if not extra.is_empty():
		sync.enqueue(extra, true)
	# prefetch whatever the open scene needs so switching to High-Poly is instant
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		sync.prioritize_scene(HighpolyLib.scene_keys(r))

# ---------- background sync -> auto swap-in ----------
func _on_model_ready(nm: String) -> void:
	_ready_names[nm] = true
	previews.invalidate(nm)
	_swap_timer.start()   # debounce: one scene walk per burst of downloads

func _swap_in_ready() -> void:
	var names := _ready_names
	_ready_names = {}
	if names.is_empty() or _mode() == HighpolyLib.Tier.LOW:
		return
	var r := EditorInterface.get_edited_scene_root()
	if r == null: return
	# pre-parse the GLBs a couple per frame (the expensive part), so the single
	# scene walk afterwards only instantiates cached scenes — no frame hitch
	var parsed := 0
	for nm in names.keys():
		HighpolyStore.load_scene(nm)
		parsed += 1
		if parsed % 2 == 0:
			await get_tree().process_frame
	var n := HighpolyLib.apply_names(r, names, _mode(), _textured())
	if n > 0:
		lbl.text = "%d piece(s) upgraded as models arrived" % n

# The sync manager adopted a NEW manifest (a model changed server-side, e.g. a
# site model swap under the same name): map-context prop meshes re-verify, and
# if any were actually replaced, the visible context rebuilds with them.
func _on_manifest_refreshed() -> void:
	mapctx.reset_props_verification()
	if mapctx_objects == null or not mapctx_objects.button_pressed: return
	var r := EditorInterface.get_edited_scene_root()
	if r == null: return
	var map: String = mapctx.map_of(r)
	if map == "": return
	await mapctx.ensure_props(dock, map, func(s: String): lbl.text = s)
	if mapctx.last_verify_updates > 0:
		lbl.text = mapctx.apply(r, mapctx_on.button_pressed, true, mapctx_tex.button_pressed)

func _update_progress() -> void:
	if sync == null: return
	var busy: bool = sync.pending() > 0 or sync.bootstrapping
	progress.visible = busy
	pause_btn.visible = busy or sync.paused
	progress.value = sync.progress_ratio()
	sync_lbl.text = sync.status_text() if not HighpolyLib.use_legacy else ""

# ---------- plugin self-update ----------
func _check_plugin_update() -> void:
	HighpolyUpdater.check_plugin_update(dock, func(new_version: String, _notes: String):
		if new_version != "" and update_btn != null:
			update_btn.text = "Update Plugin → v%s" % new_version
			update_btn.tooltip_text = "A newer plugin version is available. One click downloads it over addons/highpoly_toggle; restart the editor afterwards."
			update_btn.visible = true)

func _do_plugin_update() -> void:
	update_btn.disabled = true
	var ok: bool = await HighpolyUpdater.update_plugin(dock, func(msg: String): lbl.text = msg)
	if ok:
		update_btn.text = "Restart editor to finish update"
	else:
		update_btn.disabled = false

# When the user switches scene tabs, tear down our heavy owner=null overlays on
# the scene we're LEAVING (Map Context = tens of thousands of nodes; high-poly =
# thousands) and reset the dock to Low-Poly / Map Context off. Keeps every scene
# light so swapping tabs stays fast; the user re-enables per scene as needed.
func _check_scene_change() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == _edited_root: return
	var old := _edited_root
	_edited_root = r
	if old != null and is_instance_valid(old):
		if mapctx: mapctx.apply(old, false, false, false)     # frees _MAP_CONTEXT + maptile decal
		HighpolyLib.apply(old, HighpolyLib.Tier.LOW, true)    # hide high-poly overlays, show proxies
	# reset the dock to default for the newly-active scene (programmatic, no rebuild)
	if mode_btn: mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
	if previews: previews.tier = HighpolyLib.Tier.LOW
	if mapctx_on: mapctx_on.set_pressed_no_signal(false)
	if mapctx_objects: mapctx_objects.set_pressed_no_signal(false)
	if lbl and old != null: lbl.text = "Scene changed — reset to Low-Poly"
	# the new scene's props move to the front of the download queue
	if r != null and sync != null and not HighpolyLib.use_legacy:
		sync.prioritize_scene(HighpolyLib.scene_keys(r))

# ensure the map's prop meshes are in the shared cache (only when objects are
# shown), then apply. Prop meshes download once and are reused across maps.
func _apply_mapctx(r: Node, on: bool, objs: bool, tex: bool) -> void:
	if objs:
		await mapctx.ensure_props(dock, mapctx.map_of(r), func(s: String): lbl.text = s)
	lbl.text = mapctx.apply(r, on, objs, tex)

func _mapctx_rebuild() -> void:
	# rebuild with current toggles, no re-download (e.g. terrain detail changed)
	if not mapctx_on.button_pressed: return
	var r := EditorInterface.get_edited_scene_root()
	if mapctx.map_of(r) == "": return
	lbl.text = mapctx.apply(r, true, mapctx_objects.button_pressed, mapctx_tex.button_pressed)

func _mapctx_changed() -> void:
	var on := mapctx_on.button_pressed
	var objs := mapctx_objects.button_pressed
	var tex := mapctx_tex.button_pressed
	var r := EditorInterface.get_edited_scene_root()
	var rn := "<none>" if r == null else String(r.name)
	var map: String = mapctx.map_of(r)
	if not on and not objs:
		# neither terrain context nor objects — Textures can still drape the SDK's
		# shipped maptile over the default terrain (no download needed)
		lbl.text = mapctx.apply(r, false, false, tex); return
	if map == "":
		lbl.text = "Scene root is '%s' — open an MP_… level scene" % rn
		mapctx_on.set_pressed_no_signal(false)
		mapctx_objects.set_pressed_no_signal(false)
		return
	if mapctx.has_data(map):
		# already cached — download_map self-heals (ETag check) + tops up any
		# missing pieces (idempotent, offline-fast when complete), then apply
		lbl.text = "Loading %s…" % map
		await mapctx.download_map(dock, map, func(s: String): lbl.text = s)
		await _apply_mapctx(r, on, objs, tex)
		return
	# not downloaded yet — prompt (per-map sized, obvious in context)
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Map data for %s isn't downloaded yet.\nDownload the terrain + object layout now? (~tens of MB, one time per map)" % map
	dlg.ok_button_text = "Download"
	dlg.cancel_button_text = "Cancel"
	dlg.confirmed.connect(func():
		lbl.text = "Downloading map data…"
		var ok: bool = await mapctx.download_map(dock, map, func(s: String): lbl.text = s)
		if ok:
			await _apply_mapctx(r, on, objs, tex)
		else:
			mapctx_on.set_pressed_no_signal(false)
			mapctx_objects.set_pressed_no_signal(false)
			lbl.text = mapctx.apply(r, false, false, false))
	dlg.canceled.connect(func():
		mapctx_on.set_pressed_no_signal(false)
		mapctx_objects.set_pressed_no_signal(false)
		lbl.text = mapctx.apply(r, false, false, false)
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _mode_changed() -> void:
	previews.tier = _mode()
	_apply_scene()
	# whatever this scene needs but doesn't have yet: front of the queue, and
	# swapped in automatically as it lands (no prompt, no re-apply button)
	if _mode() != HighpolyLib.Tier.LOW and not HighpolyLib.use_legacy:
		var missing: Array = HighpolyLib.take_wanted()
		if not missing.is_empty():
			sync.prioritize_scene(missing)
			lbl.text += " — %d downloading in background" % missing.size()

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
	if not HighpolyLib.use_legacy:
		var missing: Array = HighpolyLib.take_wanted()
		if not missing.is_empty():
			sync.prioritize_scene(missing)

func _confirm_purge() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Delete ALL downloaded preview models?
Your scene and the low-poly proxies are not affected; the sync re-downloads what your scenes need."
	dlg.ok_button_text = "Purge"
	dlg.confirmed.connect(func():
		# drop overlays first so nothing references the files
		var r := EditorInterface.get_edited_scene_root()
		if r != null:
			HighpolyLib.apply(r, HighpolyLib.Tier.LOW, true)
		mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
		previews.tier = HighpolyLib.Tier.LOW
		previews.clear_cache()
		var n := HighpolyStore.purge_all()
		lbl.text = "Purged %d file(s)" % n)
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
	var k := HighpolyLib.match_key_public(node)
	if k == "": return
	if not HighpolyLib.apply_one(node as Node3D, k, _mode(), _textured()):
		# not local yet: a just-placed prop goes to the VERY front of the queue
		if not HighpolyLib.use_legacy and sync != null:
			HighpolyLib.take_wanted()
			sync.prioritize_one(k)
