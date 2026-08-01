@tool
extends EditorPlugin
# Low / High-poly interchange for Portal SDK level building.
# v1.5: zero model-management buttons. A background sync (highpoly_sync.gd)
# downloads the open scene's props first, then (in "full" scope) the rest of
# the library; overlays swap in automatically as models land; stale models and
# map data re-download themselves. The dock shows one progress bar + pause.

var dock: VBoxContainer
var dock_scroll: ScrollContainer   # panel wrapper: collapses the VBox's huge min height
var dock_root: Control             # panel root: scroller + the boot overlay
var win: Window                    # the floating tool panel itself
var tools_btn: Button              # "High-Poly Tools" in the 3D viewport toolbar
var _win_rect: Rect2i              # remembered across sessions; zero = never opened
var video: VideoStreamPlayer       # looping backdrop; paused whenever the panel is shut
var tint: ColorRect                # darkens the backdrop behind the controls
var border: Panel                  # the outline
var boot: Node                     # the running boot sequence, if one is playing
var tips: Control                  # hover descriptions, drawn inside the panel
var sections: Array = []           # collapsible sections, in dock order
var _vid_size := Vector2(480, 800) # encoded video size, for cover-scaling
var lbl: Label
var mode_btn: OptionButton
var ovr_chk: Button          # per-selection detail override (live, contextual label)
var _override: Array = []      # nodes currently carrying the override
# relative preloads: the plugin works from ANY folder under addons/ (users
# often drop the whole repo zip in, nesting the plugin one level deeper)
const PreviewsScript = preload("highpoly_previews.gd")
const MapContextScript = preload("highpoly_mapcontext.gd")
const SyncScript = preload("highpoly_sync.gd")
const HighpolyCollision = preload("highpoly_collision.gd")
const HighpolyDoors = preload("highpoly_doors.gd")
const HighpolyVariants = preload("highpoly_variants.gd")
const LightingScript = preload("highpoly_lighting.gd")
const PlacedCull = preload("highpoly_placedcull.gd")
const JobBarsScript = preload("highpoly_jobbars.gd")
const TipsScript = preload("highpoly_tips.gd")
const SectionScript = preload("highpoly_section.gd")
const SplashScript = preload("highpoly_splash.gd")
const Theme_ = preload("highpoly_theme.gd")
var previews: Node
var mapctx: Node
var sync: Node
var col_chk: Button          # Show collisions overlay
var iso_chk: Button          # Isolate selected: collision only (live w/ selection)
var col_pick: ColorPickerButton
var col_alpha: HSlider
var mapctx_on: Button        # Map Context enabled
var mapctx_objects: Button   # show original map objects
var mapctx_range: HSlider      # object render distance; 0 = objects off, 3500 = no culling
var mapctx_range_val: Label    # live "%dm" / "No Culling" readout next to the slider
var mapctx_maptile: Button   # project the maptile decal over SDK terrain+assets
var mapctx_fx: Button        # live GPU particles at the map's mined FX spawns
var mapctx_light: Button     # game lighting (sun/sky/fog from the real map VE)
var mapctx_gi: Button        # sub-toggle: SDFGI + SSAO (visible while lighting is on)
var mapctx_shadows: Button   # sub-toggle: sun shadows + overlay casting
var mapctx_maplights: Button # sub-toggle: the map's mined light entities
var mapctx_optimize: Button  # distance-cull the user's PLACED objects (their custom map content)
var mapctx_variant_row: HBoxContainer  # "Variant" gamemode dropdown (visible with objects)
var mapctx_variant: OptionButton
var mapctx_bar: ProgressBar    # background props-build progress (hidden when idle)
var mapctx_timer: Timer
# generation counter for Map Context toggles: every click supersedes the
# in-flight handler (which may be awaiting a long download). A superseded
# handler must NEVER apply its captured — now stale — checkbox state.
var _mapctx_gen := 0
var update_btn: Button         # "Update Plugin to vX.Y.Z" — hidden until a newer version exists
var banner: Label              # legacy-mode notice ("reorganization pending")
var progress: ProgressBar
var sync_lbl: Label
var job_box: VBoxContainer     # HighpolyJobBars: one stacked bar per in-flight
                               # download (typed by base, like mapctx/sync — the
                               # global class name isn't registered until a scan)
var pause_btn: Button
var check_btn: Button          # manual "Check for Updates" (forces a registry re-check)
var scope_btn: OptionButton    # sync scope: current scene only / all models
var _edited_root: Node = null  # tracks the active scene to detect tab switches
var _ready_names: Dictionary = {}   # models that landed since the last swap-in pass
var _swap_timer: Timer
# ---- storage section (dock) ----
var storage_lbl: Label         # disk usage summary (computed async)
var purge_maps: OptionButton   # downloaded maps eligible for purge
var storage_cache_chk: Button  # "Fast startup cache" (baked mesh sidecars)
var purge_btn: Button
var _storage_gen := 0          # supersedes an in-flight usage scan

# dropdown ids: 0 = Low-Poly, 1 = High-Poly grey, 2 = High-Poly textured
func _mode() -> int:
	if mode_btn == null: return HighpolyLib.Tier.LOW
	return HighpolyLib.Tier.LOW if mode_btn.get_selected_id() == 0 else HighpolyLib.Tier.HIGH

func _textured() -> bool:
	return mode_btn.get_selected_id() == 2 if mode_btn else true

# map-context detail follows the same dropdown (replaces the old "Textures"
# checkbox): 0 = flat SDK orange, 1 = grey clay high-poly, 2 = textured
func _mapctx_tex_mode() -> int:
	return mode_btn.get_selected_id() if mode_btn else 2

func _range_label(v: float) -> String:
	if int(v) <= 0: return "off"
	if int(v) >= 3500: return "No Culling"
	return "%dm" % int(v)

func _enter_tree() -> void:
	dock = VBoxContainer.new()
	dock.name = "HighPolyContent"   # tab title comes from the scroll wrapper

	# plugin self-update: hidden unless the registry advertises a newer version
	update_btn = Button.new()
	update_btn.visible = false
	update_btn.pressed.connect(_do_plugin_update)
	dock.add_child(_centred(update_btn))

	banner = Label.new()
	banner.visible = false
	banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	dock.add_child(banner)

	# ---- per-download bars, stacked above the sync bar (see _job_row) ----
	job_box = JobBarsScript.new()
	dock.add_child(job_box)

	# ---- sync progress (the whole "model management UI" in 1.5) ----
	progress = ProgressBar.new()
	progress.min_value = 0.0
	progress.max_value = 1.0
	progress.visible = false
	Theme_.bar(progress)
	dock.add_child(progress)
	sync_lbl = Label.new()
	sync_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sync_lbl.add_theme_font_size_override("font_size", Theme_.fs(12))
	dock.add_child(sync_lbl)
	pause_btn = Button.new()
	pause_btn.text = "Pause downloads"
	pause_btn.visible = false
	pause_btn.tooltip_text = "Pause/resume the background model sync (e.g. on a metered connection)."
	pause_btn.pressed.connect(func():
		sync.paused = not sync.paused
		pause_btn.text = "Resume downloads" if sync.paused else "Pause downloads")
	dock.add_child(_centred(pause_btn))

	check_btn = Button.new()
	check_btn.text = "Check for Updates"
	check_btn.tooltip_text = "Fetch the latest registry right now (normally automatic: on start + hourly). Handy right after a model fix is published."
	check_btn.pressed.connect(_check_updates_now)
	dock.add_child(_centred(check_btn))

	scope_btn = OptionButton.new()
	scope_btn.add_item("Download: current scene only", 0)
	scope_btn.add_item("Download: all models", 1)
	scope_btn.tooltip_text = "Current scene only: keep just the models your open scene uses (switching frees the rest from disk; they re-download on demand). All models: the whole library syncs in the background."
	scope_btn.item_selected.connect(func(_i): _scope_changed())
	dock.add_child(scope_btn)

	# From here down the panel is built into collapsible sections. `host` is
	# whichever section's content box is currently being filled, so the existing
	# build order — which several controls depend on — is untouched.
	var host: Node = _section("Detail Mode",
		"How the models in your scene are drawn. Low-Poly shows the SDK proxies you actually export; the High-Poly modes swap in the real game models as an editor-only overlay, with or without their textures.")

	mode_btn = OptionButton.new()
	mode_btn.add_item("Low-Poly (default)", 0)
	mode_btn.add_item("High-Poly — no textures", 1)
	mode_btn.add_item("High-Poly — textured", 2)
	mode_btn.selected = 0
	mode_btn.item_selected.connect(func(_i): _mode_changed())
	host.add_child(mode_btn)

	var detail_chips := _chip_row(host)
	ovr_chk = Theme_.chip(_override_label())
	ovr_chk.tooltip_text = "Per-object override of the Detail Mode above — follows your selection live while checked. In Low-Poly mode: selected objects show high-poly (work light, inspect in detail). In High-Poly mode: selected objects drop to their proxies (reclaim FPS in heavy areas). Uncheck to restore everything to the scene's mode."
	ovr_chk.toggled.connect(_override_toggled)
	detail_chips.add_child(ovr_chk)

	host = _section("Collision",
		"See what your objects actually collide with. Draws each object's real in-game collision volume over it, so you can spot where a shape does not match the model players will run into.")

	var col_chips := _chip_row(host)
	col_chk = Theme_.chip("Collisions")
	col_chk.tooltip_text = "Editor-only overlay (never saved). Draws each object's ACTUAL in-game collision in transparent red: the object's own geometry scaled uniformly from the X axis — an object scaled (10, 20, 20) collides as (10, 10, 10)."
	col_chk.toggled.connect(func(_v): _collision_changed())
	col_chips.add_child(col_chk)

	iso_chk = Theme_.chip("Isolate selected")
	iso_chk.disabled = true
	iso_chk.tooltip_text = "Selected object(s) show ONLY their collision; everything else keeps its model (plus collision). Follows the selection live. Needs \"Show collisions\" on."
	iso_chk.toggled.connect(_isolate_toggled)
	col_chips.add_child(iso_chk)

	var cc_row := HBoxContainer.new(); host.add_child(cc_row)
	var cc_lbl := Label.new(); cc_lbl.text = "Color"
	cc_row.add_child(cc_lbl)
	col_pick = ColorPickerButton.new()
	col_pick.edit_alpha = true
	col_pick.color = HighpolyCollision.get_color()
	col_pick.custom_minimum_size = Vector2(48, 0)
	col_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_pick.tooltip_text = "Collision overlay color (alpha included)."
	col_pick.color_changed.connect(func(c: Color):
		HighpolyCollision.set_color(c)
		col_alpha.set_value_no_signal(c.a))
	cc_row.add_child(col_pick)

	var ca_row := HBoxContainer.new(); host.add_child(ca_row)
	var ca_lbl := Label.new(); ca_lbl.text = "Alpha"
	ca_row.add_child(ca_lbl)
	col_alpha = HSlider.new()
	col_alpha.min_value = 0.05; col_alpha.max_value = 1.0; col_alpha.step = 0.05
	col_alpha.value = HighpolyCollision.get_color().a
	col_alpha.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_alpha.tooltip_text = "Collision overlay transparency."
	col_alpha.value_changed.connect(func(v: float):
		var c := HighpolyCollision.get_color()
		c.a = v
		HighpolyCollision.set_color(c)
		col_pick.color = c)
	ca_row.add_child(col_alpha)

	host = _section("Map Context",
		"Build inside the real map instead of the SDK's empty bowl: the surrounding terrain, the game's own object placements, its lighting and FX — all editor-only, none of it saved or exported.")

	var mc_chips := _chip_row(host)
	# sub-toggles of "Lighting", indented under the main row and only
	# visible while it is on
	var mc_sub := _chip_row(host, 14)
	mapctx_on = Theme_.chip("Whole map")
	mapctx_on.tooltip_text = "Editor-only overlay (never saved). Adds the real out-of-bounds terrain + surrounding landscape around the SDK's playable area, so you see the whole map instead of just the playable bowl."
	mapctx_on.toggled.connect(func(v: bool):
		# fast show/hide of the built terrain/backdrop/water layers — the full
		# rebuild also regenerated every map object. Falls back to the full
		# apply when nothing is built yet or the detail mode changed.
		if mapctx.set_context_shown(EditorInterface.get_edited_scene_root(),
				v, _mapctx_tex_mode()):
			lbl.text = "Map context " + ("shown" if v else "hidden")
			_save_mapctx_state()
			return
		_mapctx_changed())
	mc_chips.add_child(mapctx_on)

	mapctx_objects = Theme_.chip("Map objects")
	mapctx_objects.tooltip_text = "Also inject the game's original object placements (vehicles, props, antennas, chairs…). The distant terrain/landscape comes in with \"Show whole map\". Their look follows the Detail Mode dropdown; the Range slider is their render distance (0 = off)."
	mapctx_objects.toggled.connect(func(v: bool):
		# checkbox and Range slider are one control pair: turning objects ON
		# from a 0 range starts them at 100 m (slider 0 unchecks the box below)
		if v and mapctx_range != null and int(mapctx_range.value) == 0:
			mapctx_range.set_value_no_signal(100.0)
			if mapctx_range_val: mapctx_range_val.text = _range_label(100.0)
			mapctx.set_radius(100.0)
		# fast show/hide of an already-built props layer — a full rebuild
		# re-parses ~2k GLBs (reads as "redownloading"). Falls back to the
		# full apply when nothing is built yet or the detail mode changed.
		_variant_row_update(v)
		if mapctx.set_objects_shown(EditorInterface.get_edited_scene_root(),
				v, _mapctx_tex_mode()):
			lbl.text = "Map objects " + ("shown" if v else "hidden")
			_save_mapctx_state()
			return
		_mapctx_changed())
	mc_chips.add_child(mapctx_objects)

	# "Map variant": draw one gamemode's real gameplay layout (capture rings,
	# objectives, spawn clusters, zones + that mode's own gated props) — data
	# mined from the level's per-mode gameplay layers. Shown while "Original
	# map objects" is on and the map has gamemode data.
	mapctx_variant_row = HBoxContainer.new()
	mapctx_variant_row.visible = false
	var mv_lbl := Label.new(); mv_lbl.text = "  Variant"
	mapctx_variant_row.add_child(mv_lbl)
	mapctx_variant = OptionButton.new()
	mapctx_variant.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_variant.add_item("Off")
	mapctx_variant.tooltip_text = "Gamemode overlay: capture rings, objectives, spawn points, zone areas and the mode's own props (e.g. Rush barriers). Additive markers — BF6 modes share all scenery."
	mapctx_variant.item_selected.connect(func(_i):
		var _r := EditorInterface.get_edited_scene_root()
		var _mode := mapctx_variant.get_item_text(mapctx_variant.selected)
		lbl.text = HighpolyGamemode.apply(_r, mapctx.map_of(_r), _mode, mapctx) \
				+ " | " + mapctx.set_variant_layers(_mode)
		_save_mapctx_state())
	mapctx_variant_row.add_child(mapctx_variant)
	host.add_child(mapctx_variant_row)

	# background props-build progress: the objects layer builds incrementally
	# (a few meshes per frame, nearest first) so the editor never freezes —
	# this bar tracks meshes built / total, same style as the download bar
	mapctx_bar = ProgressBar.new()
	mapctx_bar.min_value = 0.0
	mapctx_bar.max_value = 1.0
	mapctx_bar.visible = false
	Theme_.bar(mapctx_bar)
	mapctx_bar.tooltip_text = "Building map objects in the background (nearest first)…"
	host.add_child(mapctx_bar)

	# (no "Textures" checkbox any more — the overlay's look follows the Detail
	# Mode dropdown: Low-Poly = flat SDK orange, High-Poly no textures = grey
	# clay, High-Poly textured = real textures. See _mapctx_tex_mode().)

	mapctx_maptile = Theme_.chip("Maptile")
	mapctx_maptile.button_pressed = true   # default CHECKED = current behaviour
	mapctx_maptile.tooltip_text = "Project the map-tile colour over the SDK terrain + assets. Turn off if it tints buildings/washes out real textures."
	mapctx_maptile.toggled.connect(func(v: bool):
		# instant ACTIVE add/remove (set_maptile) — no overlay rebuild, no
		# generation bump: a running props build keeps going, and the decal
		# can't outlive an uncheck via a superseded async re-apply
		lbl.text = mapctx.set_maptile(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	mc_chips.add_child(mapctx_maptile)

	mapctx_fx = Theme_.chip("FX")
	mapctx_fx.tooltip_text = "Live particles at the map's real FX spawn points (fires, smoke columns, electrical sparks — mined from the game data with authored rates/lifetimes and the real flipbook textures). Winter/Gauntlet-only FX stay off. Distance-faded per site."
	mapctx_fx.toggled.connect(func(v: bool):
		var _r := EditorInterface.get_edited_scene_root()
		lbl.text = HighpolyFx.apply(_r, mapctx.map_of(_r), v)
		_save_mapctx_state())
	mc_chips.add_child(mapctx_fx)

	mapctx_light = Theme_.chip("Lighting")
	mapctx_light.tooltip_text = "Editor-only (never saved). Light the scene like the real map: the game's actual sun direction/colour, sky gradient, ambient and haze — extracted from this map's VisualEnvironment data (e.g. Badlands' low golden sun). Replaces the editor's neutral preview sun/sky while on."
	mapctx_light.toggled.connect(func(v: bool):
		if mapctx_gi: mapctx_gi.visible = v
		if mapctx_shadows: mapctx_shadows.visible = v
		if mapctx_maplights: mapctx_maplights.visible = v
		_lighting_changed()
		_save_mapctx_state())
	mc_chips.add_child(mapctx_light)

	# sub-toggles: only shown while Game lighting is on; both act LIVE on the
	# injected rig/overlay (no rebuild) and are remembered per map
	mapctx_gi = Theme_.chip("Global illumination")
	mapctx_gi.button_pressed = true
	mapctx_gi.visible = false
	mapctx_gi.tooltip_text = "Bounced light + sky occlusion (SDFGI) and contact shadows (SSAO) — the editor equivalents of the game's GI + GTAO. Costs GPU; uncheck if the viewport feels heavy."
	mapctx_gi.toggled.connect(func(v: bool):
		lbl.text = LightingScript.set_gi(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_gi)

	mapctx_shadows = Theme_.chip("Shadows")
	mapctx_shadows.button_pressed = true
	mapctx_shadows.visible = false
	mapctx_shadows.tooltip_text = "Sun shadows from the map objects (grass never casts). Costs GPU; uncheck if the viewport feels heavy."
	mapctx_shadows.toggled.connect(func(v: bool):
		lbl.text = LightingScript.set_shadows(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_shadows)

	mapctx_maplights = Theme_.chip("Map lights")
	mapctx_maplights.button_pressed = false
	mapctx_maplights.visible = false
	mapctx_maplights.tooltip_text = "The map's real placed lights (3,700+ on Aftermath: street lights, interiors, signs), mined from the game data with their true colours/intensities/cones. Only lights near the camera render (200 m). Costs GPU."
	mapctx_maplights.toggled.connect(func(v: bool):
		var _r := EditorInterface.get_edited_scene_root()
		lbl.text = LightingScript.set_map_lights(_r,
				v and mapctx_light.button_pressed, mapctx.map_of(_r))
		_save_mapctx_state())
	mc_sub.add_child(mapctx_maplights)

	var mcr_row := HBoxContainer.new(); host.add_child(mcr_row)
	var mcr_lbl := Label.new(); mcr_lbl.text = "Range"
	mcr_row.add_child(mcr_lbl)
	mapctx_range = HSlider.new()
	mapctx_range.min_value = 0; mapctx_range.max_value = 3500
	mapctx_range.step = 100; mapctx_range.value = 800
	mapctx_range.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_range.tooltip_text = "Render distance for the overlay: map objects, the skyline/backdrop, FX and map lights all follow it (lights cap at 300 m for GPU safety). 0 turns \"Original map objects\" off; the far end (3500) disables culling entirely."
	mcr_row.add_child(mapctx_range)
	mapctx_range_val = Label.new(); mapctx_range_val.text = _range_label(800.0)
	mcr_row.add_child(mapctx_range_val)
	mapctx_range.value_changed.connect(func(v: float):
		mapctx_range_val.text = _range_label(v)
		var _rad := 1.0e9 if int(v) >= 3500 else v
		mapctx.set_radius(_rad)
		# lights + FX ride the same slider: lights capped at 300 m (the
		# clustered-lighting GPU budget), FX clamped to their class ranges
		var _rr := EditorInterface.get_edited_scene_root()
		LightingScript.lights_range = clampf(_rad, 0.0, 300.0)
		if _rr != null:
			HighpolyFx.set_range(_rr, _rad)
			if mapctx_optimize and mapctx_optimize.button_pressed:
				PlacedCull.apply(_rr, _rad, true)   # placed props ride the slider too
		if int(v) == 0 and mapctx_objects.button_pressed:
			mapctx_objects.button_pressed = false    # fires _mapctx_changed
		else:
			_save_mapctx_state())

	# Optimize placed objects: distance-cull the props the USER places (their custom
	# map content — not the backdrop) so a densely-built map stays fast. Near props
	# stay full-quality and fully selectable/editable; distant ones stop drawing.
	# Follows the Range slider. Editor-only — nothing hidden, export untouched.
	mapctx_optimize = Theme_.chip("Optimize placed")
	mapctx_optimize.button_pressed = true
	mapctx_optimize.tooltip_text = "Distance-cull the props YOU place (your custom map content) so a densely-built map stays fast — far ones stop drawing while near ones stay full-quality and fully editable. Follows the Range slider. Nothing is hidden or changed on export; turn it off for full range."
	mapctx_optimize.toggled.connect(func(on: bool):
		var _r := EditorInterface.get_edited_scene_root()
		var _rad := 800.0
		if mapctx_range:
			_rad = 1.0e9 if int(mapctx_range.value) >= 3500 else mapctx_range.value
		lbl.text = PlacedCull.apply(_r, _rad, on)   # visible feedback: "N culled at X m"
		_save_mapctx_state())
	mc_chips.add_child(mapctx_optimize)

	var td_row := HBoxContainer.new(); host.add_child(td_row)
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

	var shader_btn := Button.new()
	shader_btn.text = "Configure Shaders…"
	shader_btn.tooltip_text = "Live overlay shader settings: Water Animation, Flipbook Animations (smoke), Foliage Wind. Applied instantly, remembered across restarts."
	shader_btn.pressed.connect(_open_shader_dialog)
	host.add_child(_centred(shader_btn))

	host = _section("Storage",
		"What the plugin is keeping on disk, and how to get it back. Everything here re-downloads on demand, so purging is always safe.")

	storage_lbl = Label.new()
	storage_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	storage_lbl.add_theme_font_size_override("font_size", Theme_.fs(12))
	storage_lbl.text = "Measuring disk usage…"
	host.add_child(storage_lbl)

	var storage_chips := _chip_row(host)
	storage_cache_chk = Theme_.chip("Fast startup cache")
	storage_cache_chk.tooltip_text = "Save each built map-context mesh to disk so the overlay comes back in seconds after an editor/plugin restart, instead of re-processing every model for minutes. Updated models still swap in automatically (stale entries rebuild). Costs roughly the downloaded models' size again on disk; per-map Purge clears it too."
	var _es := EditorInterface.get_editor_settings()
	var _mc_on := bool(_es.get_project_metadata("highpoly_mapctx", "_mesh_cache", false))
	storage_cache_chk.set_pressed_no_signal(_mc_on)
	HighpolyMapContext.mesh_cache_enabled = _mc_on
	# Configure Shaders prefs persist project-wide (water/flipbook/wind)
	var _sp: Variant = _es.get_project_metadata("highpoly_mapctx", "_shaders", {})
	if _sp is Dictionary:
		for k in (_sp as Dictionary):
			HighpolyMapContext.shader_prefs[k] = _sp[k]
	storage_cache_chk.toggled.connect(func(v: bool):
		HighpolyMapContext.mesh_cache_enabled = v
		EditorInterface.get_editor_settings().set_project_metadata(
				"highpoly_mapctx", "_mesh_cache", v)
		lbl.text = "Fast startup cache " + ("on — meshes save as they build" if v
				else "off — existing cache files stay until purged"))
	storage_chips.add_child(storage_cache_chk)

	var purge_row := HBoxContainer.new(); host.add_child(purge_row)
	purge_maps = OptionButton.new()
	purge_maps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	purge_maps.tooltip_text = "Downloaded per-map data. Purging deletes the map's own data plus objects no other downloaded map uses; shared objects are kept. Everything re-downloads on demand."
	purge_row.add_child(purge_maps)
	purge_btn = Button.new()
	purge_btn.text = "Purge"
	purge_btn.tooltip_text = "Free the selected map's disk space (safe: re-downloads on demand)"
	purge_btn.pressed.connect(_purge_selected)
	purge_row.add_child(purge_btn)

	host = dock          # back to the panel itself: these two belong to no section
	lbl = Label.new()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(lbl)

	var ver_lbl := Label.new()
	ver_lbl.text = "v%s" % HighpolyUpdater.plugin_version()
	ver_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	dock.add_child(ver_lbl)

	# Dock the VBox inside a ScrollContainer. Raw, the ~40 stacked controls
	# give the VBox a multi-thousand-pixel MINIMUM height; that minimum
	# propagates through the dock containers into the editor's main layout and
	# pushes the bottom panel (Output, Object Library, ...) off-window on load
	# (verified: dock min was 3707 px in a 1360 px window). Wrapped, the dock
	# scrolls when its area is short instead of deforming the editor.
	dock_scroll = ScrollContainer.new()
	dock_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	dock_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Inset the controls off the panel edge. Only the scroller is inset — the
	# video, the tint and the outline stay full-bleed, so the border frames the
	# backdrop rather than the buttons.
	dock_scroll.offset_left = PANEL_PAD
	dock_scroll.offset_right = -PANEL_PAD
	dock_scroll.offset_top = PANEL_PAD_V
	dock_scroll.offset_bottom = -PANEL_PAD_V
	dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock_scroll.add_child(dock)
	# The panel root is a plain Control holding the scroller, so the boot
	# animation can be a SIBLING covering the whole panel. Inside the scroller it
	# would be sized and clipped by the panel's content instead of covering it.
	dock_root = Control.new()
	dock_root.name = "High-Poly"
	dock_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# white text on translucent white masks, over the darkened loop; set on the
	# panel root only, so anything undefined still falls through to the editor
	dock_root.theme = Theme_.build_ui_theme()
	dock_root.add_child(dock_scroll)
	_build_backdrop()
	_build_tool_window()
	# the boot sequence is started from the open path, not from visibility_changed:
	# that signal also fires on close, and every route to opening the panel goes
	# through the toolbar button's toggle anyway
	_restore_section_state.call_deferred()
	_adopt_tips.call_deferred()
	_first_run_open.call_deferred()
	_auto_perf_settings.call_deferred()
	_check_plugin_update.call_deferred()
	_refresh_storage.call_deferred()   # async walk; mapctx exists by deferred time

	previews = PreviewsScript.new()
	dock.add_child(previews)
	mapctx = MapContextScript.new()
	dock.add_child(mapctx)
	# the background props builder reports through the dock: live text in the
	# status label + a real progress bar (meshes built / total)
	mapctx.status_label = lbl
	mapctx.build_progress.connect(func(done: int, total: int):
		mapctx_bar.max_value = float(maxi(total, 1))
		mapctx_bar.value = float(done)
		mapctx_bar.visible = done < total)
	mapctx.build_finished.connect(func(_built: int):
		mapctx_bar.visible = false
		# sidecar-cached meshes load with the shader params they were SAVED
		# with — push the current Configure Shaders prefs over the fresh build
		var _sr := EditorInterface.get_edited_scene_root()
		if _sr != null: mapctx.apply_shader_prefs(_sr))
	# every map-context download (map data, props, maptile) gets its own bar
	mapctx.download_progress.connect(job_box.progress)
	mapctx.download_ended.connect(job_box.end)
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
		_lighting_guard()
		if mapctx: mapctx.tick()
		# gamemode markers self-heal: full overlay rebuilds (and whatever
		# else) can drop the _GAMEMODE node — if a variant is selected and
		# the node is gone, re-apply it (cheap: small JSON + a few dozen nodes)
		if mapctx_variant != null and mapctx_variant.selected > 0 \
				and mapctx_variant_row != null and mapctx_variant_row.visible:
			var _gr := EditorInterface.get_edited_scene_root()
			if _gr != null and _gr.get_node_or_null("_GAMEMODE") == null:
				var _gmode := mapctx_variant.get_item_text(mapctx_variant.selected)
				lbl.text = HighpolyGamemode.apply(_gr, mapctx.map_of(_gr), _gmode, mapctx)
				mapctx.set_variant_layers(_gmode)
		# map-lights culling: only lights near the editor camera render
		var _vp3 := EditorInterface.get_editor_viewport_3d(0)
		var _cam3 := _vp3.get_camera_3d() if _vp3 else null
		if _cam3:
			LightingScript.tick_lights(EditorInterface.get_edited_scene_root(),
					_cam3.global_position)
		# a CANCELLED props build (Map Context toggled off / new apply) ends
		# without a build_finished — hide the stale bar
		if mapctx_bar.visible and mapctx and mapctx.is_build_done():
			mapctx_bar.visible = false
		# collision overlays follow objects the user moves/rescales
		if col_chk.button_pressed or HighpolyCollision.has_isolation():
			HighpolyCollision.refresh_transforms())
	dock.add_child(mapctx_timer); mapctx_timer.start()
	_edited_root = EditorInterface.get_edited_scene_root()

	# every session starts safe: Low-Poly until a mode is chosen
	mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
	previews.tier = HighpolyLib.Tier.LOW

	# auto-overlay for pieces placed while a detail mode is active
	get_tree().node_added.connect(_on_node_added)
	# live isolation follows the editor selection
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# door toggling + variant cycling need viewport clicks even with nothing
	# edited/selected
	set_input_event_forwarding_always_enabled()

	_startup.call_deferred()

func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	var esel := EditorInterface.get_selection()
	if esel.selection_changed.is_connected(_on_selection_changed):
		esel.selection_changed.disconnect(_on_selection_changed)
	# disabling the plugin returns the scene to stock: overlays freed, proxies
	# shown — as if the plugin was never on
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		HighpolyCollision.release_isolation(HighpolyLib.Tier.LOW, true, false)
		HighpolyCollision.apply(r, false)                  # frees collision overlays
		if mapctx: mapctx.apply(r, false, false, false)    # frees _MAP_CONTEXT + maptile
		LightingScript.clear(r)                          # frees _GAME_LIGHTING
		HighpolyLib.apply(r, HighpolyLib.Tier.LOW, true)   # hide hi-poly overlays, show proxies
	HighpolyStore.save()
	if job_box: job_box.clear()   # no orphaned rows if a fetch outlives the panel
	if tools_btn:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, tools_btn)
		tools_btn.queue_free()
		tools_btn = null
	if win:
		win.queue_free()           # frees the panel root, scroller and VBox with it
		win = null
		dock_root = null
		dock_scroll = null

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
	_sync_scope_control()
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
	var gen := _mapctx_gen
	await mapctx.ensure_props(dock, map, func(s: String): lbl.text = s)
	if gen != _mapctx_gen:
		return                         # user toggled Map Context while props re-verified
	if mapctx.last_verify_updates > 0 and mapctx_objects.button_pressed:
		lbl.text = mapctx.apply(r, mapctx_on.button_pressed, true, _mapctx_tex_mode())

func _check_updates_now() -> void:
	if HighpolyLib.use_legacy:
		lbl.text = "Run the storage reorganization first (restart the editor)"
		return
	check_btn.disabled = true
	lbl.text = "Checking registry for updates…"
	await sync.check_now()
	# whatever the open scene needs jumps the queue, same as startup
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		sync.prioritize_scene(HighpolyLib.scene_keys(r))
		# self-heal the open map's package (new files download via ETag) and
		# sweep obsoleted cache artifacts — one button = full migration
		var _map: String = mapctx.map_of(r)
		if _map != "" and mapctx.has_data(_map):
			await mapctx.download_map(dock, _map, func(s: String): lbl.text = s)
		var _swept: int = mapctx.cleanup_stale(_map)
		if _swept > 0:
			lbl.text = "Update check done — %d stale cache file(s) removed" % _swept
			_refresh_storage()
	check_btn.disabled = false
	lbl.text = sync.status_text()
	# incremental map-context refresh: the background re-bake overwrites shared
	# prop GLBs (user://mapcontext/_props) file-by-file — re-parse and rebuild
	# JUST the changed meshes instead of a full overlay re-toggle. Re-fetch the
	# root: the scene may have changed/closed during the await above.
	var r2 := EditorInterface.get_edited_scene_root()
	if r2 != null and mapctx_objects != null and mapctx_objects.button_pressed \
			and mapctx.map_of(r2) != "":
		var n: int = mapctx.refresh_changed_props(r2)
		if n > 0:
			lbl.text = "%d object meshes refreshed" % n   # subset build: bar + progress follow
		elif n < 0:
			lbl.text = "Map objects still building — check again when it finishes"
	_refresh_storage()   # disk usage may have shifted (downloads / re-bake)

# ---------- the floating tool panel ----------
# The tools live in their own window rather than an editor dock. Level building
# needs the 3D viewport wide, and a right-hand dock permanently costs ~400px of
# it; a panel you open, move to a second monitor and close again costs nothing
# when it is shut. The launcher sits in the 3D viewport toolbar beside the SDK's
# own "Apply Texture" button, so both plugins are found in the same place.
const WIN_SIZE := Vector2i(440, 900)
const WIN_MIN := Vector2i(340, 380)
const WAVES := "res://addons/highpoly_toggle/waves.ogv"
const WAVES_META := "res://addons/highpoly_toggle/waves.json"
const TINT_DEFAULT := 0.72     # how far the backdrop dims once the controls are up
const PANEL_PAD := 16          # controls held off the outline, left/right
const PANEL_PAD_V := 12        # ...and top/bottom

# Toggles sit shoulder-to-shoulder in a wrapping row under their heading rather
# than one per line. Thirteen stacked checkboxes is mostly empty space, and a
# filled chip states "on" at a glance where a tick has to be read.
# Move every description off Godot's tooltip system and onto our own box.
# Deferred so it runs after the whole panel is built, and re-run cheaply if a
# control grows a description later (adopt() is idempotent).
func _adopt_tips() -> void:
	if tips == null or dock == null: return
	tips.adopt(dock)
	# scrolling moves the controls out from under a shown box
	var vs := dock_scroll.get_v_scroll_bar() if dock_scroll else null
	if vs and not vs.value_changed.is_connected(_tips_hide):
		vs.value_changed.connect(_tips_hide)

# Sized to its own text and centred, rather than stretched across the panel.
func _centred(b: Button) -> Button:
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return b

func _tips_hide(_v: float = 0.0) -> void:
	if tips: tips.hide_now()

func _chip_row(into: Node, indent := 0) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.alignment = FlowContainer.ALIGNMENT_CENTER
	f.add_theme_constant_override("h_separation", 6)
	f.add_theme_constant_override("v_separation", 6)
	if indent > 0:
		var m := MarginContainer.new()
		# inset both sides: a one-sided indent would push a centred row off centre
		m.add_theme_constant_override("margin_left", indent)
		m.add_theme_constant_override("margin_right", indent)
		m.add_child(f)
		into.add_child(m)
	else:
		into.add_child(f)
	return f

# One collapsible section, appended to the panel. Returns its content box so the
# controls that follow can be built straight into it.
func _section(section_title: String, description: String) -> Node:
	var sec = SectionScript.new()
	dock.add_child(sec)
	sec.setup(section_title, description)
	sec.opened_changed.connect(func(open: bool):
		_tips_hide()                    # the description answered its question
		_save_section_state()
		if open: _scroll_to.call_deferred(sec))
	sections.append(sec)
	return sec.content

# Reveal a freshly opened section rather than leaving it to unfold off-screen.
func _scroll_to(sec: Control) -> void:
	if dock_scroll == null or not is_instance_valid(sec): return
	await get_tree().process_frame
	if not is_instance_valid(sec): return
	dock_scroll.ensure_control_visible(sec)

func _save_section_state() -> void:
	var open_names: Array = []
	for sec in sections:
		if is_instance_valid(sec) and sec.is_open():
			open_names.append(sec.title_lbl.text)
	EditorInterface.get_editor_settings().set_project_metadata(
		"highpoly", "open_sections", open_names)

func _restore_section_state() -> void:
	var want: Variant = EditorInterface.get_editor_settings().get_project_metadata(
		"highpoly", "open_sections", ["Detail Mode"])
	if not (want is Array): return
	for sec in sections:
		if is_instance_valid(sec) and (want as Array).has(sec.title_lbl.text):
			sec.set_open(true, false)

# The panel is layered back-to-front:
#   bg      opaque, so the panel is legible with no video at all
#   video   the loop, cover-scaled and clipped
#   tint    darkens the loop; the boot sequence animates this 0 -> the palette's tint
#   scroll  the controls; the boot sequence fades this in
#   boot    the logo flash, on top of everything, then gone
#   border  the outline, always last so nothing paints over it
func _build_backdrop() -> void:
	var bg := ColorRect.new()
	bg.color = Theme_.col("splash_bg")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dock_root.add_child(bg)
	dock_root.move_child(bg, 0)

	if FileAccess.file_exists(WAVES):
		# built directly instead of load()ed: an editor plugin's assets can be
		# dropped in or replaced without waiting for a reimport, same as the
		# logo and the map tiles
		var vs := VideoStreamTheora.new()
		vs.file = WAVES
		video = VideoStreamPlayer.new()
		video.stream = vs
		video.expand = true          # fills the node; _fit_video sizes the node
		video.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if "loop" in video:
			video.loop = true
		else:
			video.finished.connect(func(): if video: video.play())
		dock_root.add_child(video)
		dock_root.move_child(video, 1)
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(WAVES_META)) \
			if FileAccess.file_exists(WAVES_META) else null
		if j is Dictionary:
			_vid_size = Vector2(float((j as Dictionary).get("width", 480)),
				float((j as Dictionary).get("height", 800)))

	tint = ColorRect.new()
	tint.color = Color(0, 0, 0, Theme_.num("tint", TINT_DEFAULT))
	tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dock_root.add_child(tint)
	dock_root.move_child(tint, 2)

	tips = TipsScript.new()
	dock_root.add_child(tips)

	border = Panel.new()
	border.set_anchors_preset(Control.PRESET_FULL_RECT)
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	border.add_theme_stylebox_override("panel", Theme_.panel_border())
	dock_root.add_child(border)

	dock_root.clip_contents = true      # the cover-scaled video overhangs
	dock_root.resized.connect(_fit_video)
	_fit_video()

# Cover, not contain: scale until the video covers the panel and let the excess
# spill past the edges. Letterboxing a backdrop would put bars inside the border.
func _fit_video() -> void:
	if video == null or dock_root == null: return
	if _vid_size.x <= 0.0 or _vid_size.y <= 0.0: return
	var s := maxf(dock_root.size.x / _vid_size.x, dock_root.size.y / _vid_size.y)
	video.size = _vid_size * s
	video.position = (dock_root.size - video.size) * 0.5

func _build_tool_window() -> void:
	win = Window.new()
	win.title = "High-Poly Tools"
	win.min_size = WIN_MIN
	win.size = WIN_SIZE
	# Stays above the editor when you click back into the viewport. It must not
	# be transient to do that: the platform display server rejects always-on-top
	# for a window that has a transient parent ("Transient windows can't become
	# on top of parent"), and transient on its own only raises the panel
	# alongside its parent, which is what let clicking the viewport bury it.
	win.transient = false
	win.always_on_top = true
	win.exclusive = false      # never blocks the editor: keep building while it is open
	win.hide()
	win.close_requested.connect(_close_tools)
	EditorInterface.get_base_control().add_child(win)
	win.add_child(dock_root)

	tools_btn = Button.new()
	tools_btn.text = "High-Poly Tools"
	tools_btn.flat = true
	tools_btn.toggle_mode = true      # the button IS the panel's open/closed state
	tools_btn.tooltip_text = "Open the High-Poly preview tools"
	tools_btn.toggled.connect(_set_tools_visible)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, tools_btn)

func _set_tools_visible(on: bool) -> void:
	if win == null: return
	if not on:
		if win.visible: _win_rect = Rect2i(win.position, win.size)
		win.hide()
		# a closed panel must not keep a video decoder running: this plugin
		# exists to buy back frame time, not to spend it on its own scenery
		if video: video.paused = true
		_stop_boot()
		return
	if video:
		if video.is_playing(): video.paused = false
		else: video.play()
	if _win_rect.size.x > 0 and _usable(_win_rect):
		win.position = _win_rect.position
		win.size = _win_rect.size
		win.show()
	else:
		win.popup_centered(WIN_SIZE)
	_maybe_play_splash()      # after show(): the sequence needs a visible panel

# Closing mid-sequence drops it. A hidden Window still processes, so left alone
# the boot would carry on animating a panel nobody can see, and the next open
# would find it already finished.
func _stop_boot() -> void:
	_tips_hide()
	if is_instance_valid(boot):
		boot.queue_free()
		boot = null

func _close_tools() -> void:
	# closing from the window's own X must not re-enter _set_tools_visible
	if tools_btn: tools_btn.set_pressed_no_signal(false)
	if win and win.visible: _win_rect = Rect2i(win.position, win.size)
	if win: win.hide()
	if video: video.paused = true
	_stop_boot()

# A remembered position is only good while that monitor still exists. Unplug a
# second screen and a restored panel would open onto coordinates nothing can
# reach, looking exactly like the button doing nothing.
func _usable(r: Rect2i) -> bool:
	var probe := r.position + Vector2i(mini(40, r.size.x / 2), 10)
	for i in range(DisplayServer.get_screen_count()):
		if DisplayServer.screen_get_usable_rect(i).has_point(probe): return true
	return false

# Open once on a project that has never seen the plugin, so the panel introduces
# itself instead of hiding behind a button nobody knows to press. After that the
# saved layout decides.
func _first_run_open() -> void:
	var es := EditorInterface.get_editor_settings()
	if bool(es.get_project_metadata("highpoly", "tools_seen", false)): return
	es.set_project_metadata("highpoly", "tools_seen", true)
	if tools_btn: tools_btn.button_pressed = true

# Godot hands plugins a slice of the editor layout file to persist into, so the
# panel comes back where it was left — including whether it was open.
func _get_window_layout(cfg: ConfigFile) -> void:
	if win == null: return
	if win.visible: _win_rect = Rect2i(win.position, win.size)
	cfg.set_value("HighPoly", "win_rect", _win_rect)
	cfg.set_value("HighPoly", "win_open", win.visible)

func _set_window_layout(cfg: ConfigFile) -> void:
	_win_rect = cfg.get_value("HighPoly", "win_rect", Rect2i())
	if tools_btn and bool(cfg.get_value("HighPoly", "win_open", false)):
		tools_btn.button_pressed = true      # fires _set_tools_visible

# Boot animation, played on every open.
func _maybe_play_splash() -> void:
	if win == null or not win.visible or dock_root == null: return
	# a fast close-and-reopen must not leave two sequences fighting over the
	# tint and the scroller's alpha
	if is_instance_valid(boot):
		boot.queue_free()
		boot = null
	var s = SplashScript.new()
	s.tint = tint
	s.ui = dock_scroll
	s.tint_max = Theme_.num("tint", TINT_DEFAULT)
	if s.setup(video != null):
		dock_root.add_child(s)
		dock_root.move_child(s, dock_root.get_child_count() - 2)   # under the border
		boot = s
	else:
		# nothing to play: make sure the panel is left in its finished state
		s.free()
		if tint: tint.color.a = Theme_.num("tint", TINT_DEFAULT)
		if dock_scroll: dock_scroll.modulate.a = 1.0

func _update_progress() -> void:
	if sync == null: return
	var busy: bool = sync.pending() > 0 or sync.bootstrapping
	progress.visible = busy
	pause_btn.visible = busy or sync.paused
	progress.value = sync.progress_ratio()
	sync_lbl.text = sync.status_text() if not HighpolyLib.use_legacy else ""

# ---------- storage (usage + per-map purge) ----------
func _human_size(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (bytes / 1073741824.0)
	if bytes >= 1048576:
		return "%d MB" % int(bytes / 1048576.0)
	return "%d KB" % maxi(1, int(bytes / 1024.0))

static func _fmt_n(n: int) -> String:
	var s := str(n)
	var out := ""
	for i in range(s.length()):
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return out

# Recompute the usage line + the purge dropdown. Async: walking GBs of files
# must never block the editor — dir_usage_async chunk-yields, and a newer scan
# supersedes this one via _storage_gen (checked after every await).
func _refresh_storage() -> void:
	_storage_gen += 1
	var gen := _storage_gen
	_reload_purge_options()
	storage_lbl.text = "Measuring disk usage…"
	var models: Array = await mapctx.dir_usage_async(HighpolyStore.MODELS_DIR)
	if gen != _storage_gen: return
	var props: Array = await mapctx.dir_usage_async(MapContextScript.PROPS_CACHE)
	if gen != _storage_gen: return
	var maps_bytes := 0
	var nmaps := 0
	for m in MapContextScript.downloaded_maps():
		var u: Array = await mapctx.dir_usage_async("%s/%s" % [MapContextScript.CACHE, m])
		if gen != _storage_gen: return
		maps_bytes += int(u[1])
		nmaps += 1
	var total := int(models[1]) + int(props[1]) + maps_bytes
	# library fractions from the live registry — COUNTS only: the manifest
	# carries no per-model byte sizes, so no invented "of X GB" totals
	var mtot := HighpolyStore.remote.size()
	var ptot := HighpolyStore.mesh_remote.size()
	var mpart := "models %s%s (%s)" % [_fmt_n(int(models[0])),
		("/%s" % _fmt_n(mtot)) if mtot > 0 else "", _human_size(int(models[1]))]
	var ppart := "map objects %s%s (%s)" % [_fmt_n(int(props[0])),
		("/%s" % _fmt_n(ptot)) if ptot > 0 else "", _human_size(int(props[1]))]
	storage_lbl.text = "Downloaded: %s — %s, %s, map data ×%d (%s)" % [
		_human_size(total), mpart, ppart, nmaps, _human_size(maps_bytes)]

func _reload_purge_options() -> void:
	if purge_maps == null: return
	var maps: Array = MapContextScript.downloaded_maps()
	purge_maps.clear()
	for m in maps:
		purge_maps.add_item(str(m))
	purge_maps.disabled = maps.is_empty()
	purge_btn.disabled = maps.is_empty()

func _purge_selected() -> void:
	if purge_maps.selected < 0: return
	var map := purge_maps.get_item_text(purge_maps.selected)
	purge_btn.disabled = true
	storage_lbl.text = "Sizing a %s purge…" % map
	var info: Dictionary = await mapctx.purge_info(map)
	purge_btn.disabled = false
	var open_map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var freed := int(info.get("map_bytes", 0)) + int(info.get("excl_bytes", 0))
	var excl_n: int = (info.get("excl", []) as Array).size()
	var txt := "Purge downloaded data for %s?\n\nFrees about %s: the map's own data (%s) plus %d objects only %s uses (%s)." % [
		map, _human_size(freed), _human_size(int(info.get("map_bytes", 0))),
		excl_n, map, _human_size(int(info.get("excl_bytes", 0)))]
	if int(info.get("shared", 0)) > 0:
		txt += "\n%d objects are shared with other downloaded maps and will be KEPT — purging never breaks another map." % int(info.get("shared", 0))
	if open_map == map:
		txt += "\n\nWARNING: this is the map you currently have OPEN — its Map Context overlay will be removed."
	txt += "\n\nPurging is always safe: everything re-downloads on demand."
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = txt
	dlg.ok_button_text = "Purge"
	dlg.confirmed.connect(func():
		_do_purge(map, info, open_map == map)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _do_purge(map: String, info: Dictionary, was_open: bool) -> void:
	if was_open:
		# drop the live overlay FIRST: cancels any running props build, detaches
		# the scatter and frees _MAP_CONTEXT + the maptile decal, so nothing
		# holds the files we are about to delete
		var r := EditorInterface.get_edited_scene_root()
		if r != null:
			lbl.text = mapctx.apply(r, false, false, false)
		if mapctx_on: mapctx_on.set_pressed_no_signal(false)
		if mapctx_objects: mapctx_objects.set_pressed_no_signal(false)
	storage_lbl.text = "Purging %s…" % map
	await mapctx.purge_map(map, info)
	lbl.text = "%s purged — about %s freed (re-downloads on demand)" % [map,
		_human_size(int(info.get("map_bytes", 0)) + int(info.get("excl_bytes", 0)))]
	_refresh_storage()

# ---------- plugin self-update ----------
func _check_plugin_update() -> void:
	HighpolyUpdater.check_plugin_update(dock, func(new_version: String, _notes: String):
		if new_version != "" and update_btn != null:
			update_btn.text = "Update Plugin to v%s" % new_version
			update_btn.tooltip_text = "A newer plugin version is available. One click downloads it over addons/highpoly_toggle; restart the editor afterwards."
			update_btn.visible = true)

func _do_plugin_update() -> void:
	update_btn.disabled = true
	# the updater fetches into memory, so there's no byte stream to track — show
	# an indeterminate row anyway, so this download isn't the one silent one
	const JOB := "Downloading plugin update"
	job_box.progress(JOB, 0, 0)
	var ok: bool = await HighpolyUpdater.update_plugin(dock, func(msg: String): lbl.text = msg)
	job_box.end(JOB)
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
		LightingScript.clear(old)                           # frees _GAME_LIGHTING + _MAP_LIGHTS
		HighpolyGamemode.clear(old)                         # frees _GAMEMODE markers
		HighpolyFx.clear(old)                               # frees _MAP_FX particles
		HighpolyCollision.release_isolation(HighpolyLib.Tier.LOW, true, false)
		HighpolyCollision.apply(old, false)                   # frees collision overlays
		HighpolyLib.apply(old, HighpolyLib.Tier.LOW, true)    # hide high-poly overlays, show proxies
	# reset the dock to default for the newly-active scene (programmatic, no rebuild)
	if mode_btn: mode_btn.select(mode_btn.get_item_index(HighpolyLib.Tier.LOW))
	if previews: previews.tier = HighpolyLib.Tier.LOW
	_override.clear()
	if ovr_chk:
		ovr_chk.set_pressed_no_signal(false)
		ovr_chk.text = _override_label()
	if mapctx_on: mapctx_on.set_pressed_no_signal(false)
	if mapctx_objects: mapctx_objects.set_pressed_no_signal(false)
	if mapctx_light: mapctx_light.set_pressed_no_signal(false)
	if mapctx_fx: mapctx_fx.set_pressed_no_signal(false)
	if mapctx_gi: mapctx_gi.visible = false
	if mapctx_shadows: mapctx_shadows.visible = false
	if mapctx_maplights: mapctx_maplights.visible = false
	if mapctx_variant_row: mapctx_variant_row.visible = false
	if col_chk: col_chk.set_pressed_no_signal(false)
	if iso_chk:
		iso_chk.set_pressed_no_signal(false)
		iso_chk.disabled = true
	_sync_maptile_control()   # the new scene may carry the SDK's own decal
	if lbl and old != null: lbl.text = "Scene changed — reset to Low-Poly"
	# the new scene's props move to the front of the download queue
	if r != null and sync != null and not HighpolyLib.use_legacy:
		sync.prioritize_scene(HighpolyLib.scene_keys(r))
	# fresh dock instance (editor start / plugin re-enable) — not a scene
	# switch: bring the overlay back the way this map had it
	if old == null and r != null:
		_restore_mapctx_state.call_deferred()

# ensure the map's prop meshes are in the shared cache (only when objects are
# shown), then apply. Prop meshes download once and are reused across maps.
func _apply_mapctx(r: Node, on: bool, objs: bool, tex: int, gen: int) -> void:
	if objs:
		await mapctx.ensure_props(dock, mapctx.map_of(r), func(s: String): lbl.text = s)
	if gen != _mapctx_gen:
		return              # user toggled again while props downloaded — stale state
	lbl.text = mapctx.apply(r, on, objs, tex)

func _mapctx_rebuild() -> void:
	# rebuild with current toggles, no re-download (e.g. terrain detail changed)
	if not mapctx_on.button_pressed: return
	var r := EditorInterface.get_edited_scene_root()
	if mapctx.map_of(r) == "": return
	lbl.text = mapctx.apply(r, true, mapctx_objects.button_pressed, _mapctx_tex_mode())

# "Game lighting": inject/remove the real map sun+sky+fog (highpoly_lighting.gd).
# Independent of the Map Context download (no map data needed — compiled-in table).
func _lighting_changed() -> void:
	var r := EditorInterface.get_edited_scene_root()
	var map: String = mapctx.map_of(r)
	if not mapctx_light.button_pressed:
		LightingScript.clear(r)
		lbl.text = "Game lighting off"
		return
	if map == "" or not LightingScript.has_data(map):
		mapctx_light.set_pressed_no_signal(false)
		if mapctx_gi: mapctx_gi.visible = false
		if mapctx_shadows: mapctx_shadows.visible = false
		lbl.text = "No lighting data for this scene" if map != "" else "Open an MP_… level scene first"
		return
	lbl.text = LightingScript.apply(r, map,
			mapctx_gi.button_pressed if mapctx_gi else true,
			mapctx_shadows.button_pressed if mapctx_shadows else true)
	if mapctx_maplights and mapctx_maplights.button_pressed:
		lbl.text += " | " + LightingScript.set_map_lights(r, true, map)

# grey the checkbox out when the open scene has no lighting data (called from
# the dock's 0.5 s timer — cheap: one dictionary lookup)
func _lighting_guard() -> void:
	if mapctx_light == null: return
	var map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var ok := map != "" and LightingScript.has_data(map)
	if mapctx_light.disabled == (not ok): return
	mapctx_light.disabled = not ok
	if not ok and mapctx_light.button_pressed:
		mapctx_light.set_pressed_no_signal(false)
		if mapctx_gi: mapctx_gi.visible = false
		if mapctx_shadows: mapctx_shadows.visible = false

# one-time baked-in performance settings: multi-threaded rendering (zero
# visual impact) + 2048 shadow atlas (negligible under the soft overcast sun).
# Applied ONCE per project — a user who reverts a setting is respected.
func _auto_perf_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	if bool(es.get_project_metadata("highpoly_mapctx", "_perf_applied", false)):
		return
	es.set_project_metadata("highpoly_mapctx", "_perf_applied", true)
	var changed := false
	if int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1)) != 2:
		ProjectSettings.set_setting("rendering/driver/threads/thread_model", 2)
		changed = true
	if int(ProjectSettings.get_setting(
			"rendering/lights_and_shadows/directional_shadow/size", 4096)) > 2048:
		ProjectSettings.set_setting(
				"rendering/lights_and_shadows/directional_shadow/size", 2048)
		changed = true
	if changed:
		ProjectSettings.save()
		banner.text = "Performance settings applied (multi-threaded rendering + shadow atlas) — restart the editor to activate them."
		banner.visible = true

# ---------- Configure Shaders dialog ----------
# Water Animation / Flipbook Animations / Foliage Wind — live uniforms on the
# overlay's shader materials (no rebuild), persisted project-wide.
func _open_shader_dialog() -> void:
	var d: Dictionary = HighpolyMapContext.shader_prefs
	var dlg := AcceptDialog.new()
	dlg.title = "Configure Shaders"
	dlg.ok_button_text = "Close"
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(340, 0)
	dlg.add_child(box)

	var apply := func():
		EditorInterface.get_editor_settings().set_project_metadata(
				"highpoly_mapctx", "_shaders", HighpolyMapContext.shader_prefs)
		lbl.text = mapctx.apply_shader_prefs(EditorInterface.get_edited_scene_root())

	var w_lbl := Label.new(); w_lbl.text = "Water Animation"
	box.add_child(w_lbl)
	var w_row := HBoxContainer.new(); box.add_child(w_row)
	var w_sl := HSlider.new()
	w_sl.min_value = 0.0; w_sl.max_value = 2.0; w_sl.step = 0.05
	w_sl.value = float(d.get("water", 1.0))
	w_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	w_sl.tooltip_text = "Ripple speed, as a multiplier on each water body's authored speed. 0 = still water, 1 = authored."
	w_row.add_child(w_sl)
	var w_val := Label.new(); w_val.text = "×%.2f" % w_sl.value
	w_row.add_child(w_val)
	w_sl.value_changed.connect(func(v: float):
		HighpolyMapContext.shader_prefs["water"] = v
		w_val.text = "×%.2f" % v
		apply.call())

	var f_lbl := Label.new(); f_lbl.text = "Flipbook Animations"
	box.add_child(f_lbl)
	var f_row := HBoxContainer.new(); box.add_child(f_row)
	var f_sl := HSlider.new()
	f_sl.min_value = 0.0; f_sl.max_value = 2.0; f_sl.step = 0.05
	f_sl.value = float(d.get("flip", 1.0))
	f_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f_sl.tooltip_text = "Animation speed of flipbook FX cards (the background smoke plumes). 0 = frozen frame."
	f_row.add_child(f_sl)
	var f_val := Label.new(); f_val.text = "×%.2f" % f_sl.value
	f_row.add_child(f_val)
	f_sl.value_changed.connect(func(v: float):
		HighpolyMapContext.shader_prefs["flip"] = v
		f_val.text = "×%.2f" % v
		apply.call())

	var wind_chk := CheckBox.new()
	wind_chk.text = "Foliage Wind"
	wind_chk.button_pressed = bool(d.get("wind", false))
	wind_chk.tooltip_text = "Subtle sway on leaves and grass (trunks stay put). Editor-only eye candy — the game does its own wind."
	box.add_child(wind_chk)
	var ws_row := HBoxContainer.new(); box.add_child(ws_row)
	var ws_lbl := Label.new(); ws_lbl.text = "  Strength"
	ws_row.add_child(ws_lbl)
	var ws_sl := HSlider.new()
	ws_sl.min_value = 0.02; ws_sl.max_value = 0.30; ws_sl.step = 0.01
	ws_sl.value = float(d.get("wind_str", 0.08))
	ws_sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ws_sl.editable = wind_chk.button_pressed
	ws_row.add_child(ws_sl)
	var ws_val := Label.new(); ws_val.text = "%.2fm" % ws_sl.value
	ws_row.add_child(ws_val)
	wind_chk.toggled.connect(func(v: bool):
		HighpolyMapContext.shader_prefs["wind"] = v
		ws_sl.editable = v
		apply.call())
	ws_sl.value_changed.connect(func(v: float):
		HighpolyMapContext.shader_prefs["wind_str"] = v
		ws_val.text = "%.2fm" % v
		apply.call())

	dlg.confirmed.connect(func(): dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

# populate/show the gamemode Variant dropdown while objects are on (only for
# maps that have gamemode_markers.json); hiding it clears the overlay
func _variant_row_update(objects_on: bool) -> void:
	if mapctx_variant_row == null: return
	var r := EditorInterface.get_edited_scene_root()
	var mds: Array = HighpolyGamemode.modes(mapctx.map_of(r)) if objects_on else []
	var show := objects_on and not mds.is_empty()
	mapctx_variant_row.visible = show
	if not show:
		HighpolyGamemode.clear(r)
		return
	var cur := mapctx_variant.get_item_text(mapctx_variant.selected) \
			if mapctx_variant.selected >= 0 else "Off"
	mapctx_variant.clear()
	mapctx_variant.add_item("Off")
	for m in mds:
		mapctx_variant.add_item(str(m))
	for i in range(mapctx_variant.item_count):
		if mapctx_variant.get_item_text(i) == cur:
			mapctx_variant.select(i)
			break

# remember the overlay setup per map so a plugin/editor restart brings it
# back automatically (see _restore_mapctx_state) instead of the user
# re-clicking + waiting out a full rebuild
func _save_mapctx_state() -> void:
	if mapctx == null or mapctx_on == null: return
	var map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	if map == "": return
	EditorInterface.get_editor_settings().set_project_metadata("highpoly_mapctx", map, {
		"on": mapctx_on.button_pressed,
		"objects": mapctx_objects.button_pressed,
		"range": mapctx_range.value if mapctx_range else 800.0,
		"maptile": mapctx_maptile.button_pressed if mapctx_maptile else true,
		"light": mapctx_light.button_pressed if mapctx_light else false,
		"gi": mapctx_gi.button_pressed if mapctx_gi else true,
		"shadows": mapctx_shadows.button_pressed if mapctx_shadows else true,
		"maplights": mapctx_maplights.button_pressed if mapctx_maplights else false,
		"optimize": mapctx_optimize.button_pressed if mapctx_optimize else true,
		"fx": mapctx_fx.button_pressed if mapctx_fx else false,
		"variant": mapctx_variant.get_item_text(mapctx_variant.selected)
				if mapctx_variant and mapctx_variant.selected >= 0 else "Off",
		"tex": _mapctx_tex_mode(),
	})

# Plugin/editor START only (not scene switches): put the overlay back the way
# this map had it — checkboxes, range, lighting, detail mode — and kick the
# normal background build. Updated models flow in via the standard staleness
# checks (registry refresh + GLB mtime vs sidecar), i.e. "Check for Updates"
# semantics without the clicks.
# The SDK has its own map-texture decal (3D toolbar -> Download/Apply Texture)
# and it SAVES into the level. When it's there, ours stands down so the ground
# isn't darkened twice — say so on the control instead of leaving a checkbox that
# looks broken. Also warn about the one real difference: theirs projects onto
# everything, high-poly models included.
func _sync_maptile_control() -> void:
	if mapctx_maptile == null or mapctx == null: return
	var theirs: Decal = mapctx.sdk_decal(EditorInterface.get_edited_scene_root())
	mapctx_maptile.disabled = theirs != null
	if theirs != null:
		mapctx_maptile.text = "Maptile decal (the SDK's is applied)"
		mapctx_maptile.tooltip_text = "This level already has the SDK's own map texture, applied from the 3D toolbar and saved in the scene, so the preview decal stays off — two would darken the ground twice.\n\nNote the SDK's decal projects onto EVERYTHING beneath it, including high-poly models that already have their real textures. Delete the '%s' node under Static to go back to the preview decal, which leaves them alone." % String(theirs.name)
	else:
		mapctx_maptile.text = "Maptile decal"
		mapctx_maptile.tooltip_text = "Project the map-tile colour over the SDK terrain + assets. Skips high-poly models and the extended terrain, which carry their own real textures. Turn off if it still tints something you'd rather see raw."

func _restore_mapctx_state() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		# plugin reloads orphan our owner=null overlay nodes ("FX won't
		# despawn") — sweep them all before restoring the saved state
		HighpolyFx.clear(r)
		HighpolyGamemode.clear(r)
		LightingScript.clear(r)
	var map: String = mapctx.map_of(r)
	if map == "": return
	var st: Variant = EditorInterface.get_editor_settings().get_project_metadata(
			"highpoly_mapctx", map, {})
	if not (st is Dictionary): return
	var d: Dictionary = st
	# placed-object optimization is independent of the backdrop overlay — restore it
	# even when the overlay itself was off (the user's props exist without a backdrop)
	if mapctx_optimize != null and r != null:
		var _opt := bool(d.get("optimize", true))
		mapctx_optimize.set_pressed_no_signal(_opt)
		PlacedCull.apply(r, float(d.get("range", 800.0)), _opt)
	if not (bool(d.get("on", false)) or bool(d.get("objects", false))):
		return                              # overlay was off — stay light
	if mapctx_range != null:
		mapctx_range.set_value_no_signal(clampf(float(d.get("range", 800.0)), 0.0, 3500.0))
		if mapctx_range_val: mapctx_range_val.text = _range_label(mapctx_range.value)
		mapctx.set_radius(1.0e9 if int(mapctx_range.value) >= 3500 else float(mapctx_range.value))
	if mapctx_maptile != null:
		mapctx_maptile.set_pressed_no_signal(bool(d.get("maptile", true)))
		HighpolyMapContext.maptile_enabled = mapctx_maptile.button_pressed
	_sync_maptile_control()
	mapctx_on.set_pressed_no_signal(bool(d.get("on", false)))
	mapctx_objects.set_pressed_no_signal(bool(d.get("objects", false)))
	if mapctx_gi: mapctx_gi.set_pressed_no_signal(bool(d.get("gi", true)))
	if mapctx_shadows: mapctx_shadows.set_pressed_no_signal(bool(d.get("shadows", true)))
	if mapctx_maplights: mapctx_maplights.set_pressed_no_signal(bool(d.get("maplights", false)))
	if mapctx_fx and bool(d.get("fx", false)):
		mapctx_fx.set_pressed_no_signal(true)
		lbl.text = HighpolyFx.apply(r, map, true)
	if bool(d.get("light", false)) and mapctx_light != null:
		mapctx_light.set_pressed_no_signal(true)
		if mapctx_gi: mapctx_gi.visible = true
		if mapctx_shadows: mapctx_shadows.visible = true
		if mapctx_maplights: mapctx_maplights.visible = true
		_lighting_changed()
	# gamemode variant overlay (dropdown lives under "Original map objects")
	_variant_row_update(bool(d.get("objects", false)))
	var _sv := str(d.get("variant", "Off"))
	if _sv != "Off" and mapctx_variant_row != null and mapctx_variant_row.visible:
		for i in range(mapctx_variant.item_count):
			if mapctx_variant.get_item_text(i) == _sv:
				mapctx_variant.select(i)
				lbl.text = HighpolyGamemode.apply(r, map, _sv, mapctx)
				mapctx.set_variant_layers(_sv)
				break
	lbl.text = "Restoring map overlay for %s…" % map
	var saved_tex := int(d.get("tex", 0))
	if mode_btn != null and saved_tex != mode_btn.get_selected_id():
		mode_btn.select(mode_btn.get_item_index(saved_tex))
		_mode_changed()          # re-applies the library AND rebuilds the overlay
	else:
		_mapctx_changed()

func _mapctx_changed() -> void:
	_save_mapctx_state()
	_mapctx_gen += 1
	var gen := _mapctx_gen
	var on := mapctx_on.button_pressed
	var objs := mapctx_objects.button_pressed
	var tex := _mapctx_tex_mode()
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
		if gen != _mapctx_gen:
			return          # a newer toggle owns the state now
		await _apply_mapctx(r, on, objs, tex, gen)
		return
	# not downloaded yet — prompt (per-map sized, obvious in context)
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Map data for %s isn't downloaded yet.\nDownload the terrain + object layout now? (~tens of MB, one time per map)" % map
	dlg.ok_button_text = "Download"
	dlg.cancel_button_text = "Cancel"
	dlg.confirmed.connect(func():
		_mapctx_gen += 1
		var gen2 := _mapctx_gen        # confirming the dialog is a fresh user action
		lbl.text = "Downloading map data…"
		var ok: bool = await mapctx.download_map(dock, map, func(s: String): lbl.text = s)
		if gen2 != _mapctx_gen:
			return                     # toggled again while the map downloaded
		if ok:
			await _apply_mapctx(r, mapctx_on.button_pressed,
					mapctx_objects.button_pressed, _mapctx_tex_mode(), gen2)
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
	# the scene-wide apply below re-uniforms everything, so overrides dissolve
	_override.clear()
	if ovr_chk:
		ovr_chk.set_pressed_no_signal(false)
		ovr_chk.text = _override_label()
	previews.tier = _mode()
	_apply_scene()
	# a mode switch rebuilds every preview — re-apply the placed-object cull so
	# your custom map content keeps distance-culling in the new detail mode
	_reapply_placed_cull()
	# whatever this scene needs but doesn't have yet: front of the queue, and
	# swapped in automatically as it lands (no prompt, no re-apply button)
	if _mode() != HighpolyLib.Tier.LOW and not HighpolyLib.use_legacy:
		var missing: Array = HighpolyLib.take_wanted()
		if not missing.is_empty():
			sync.prioritize_scene(missing)
			lbl.text += " — %d downloading in background" % missing.size()
	# the map-context overlay follows the same dropdown (orange / clay /
	# textured) — re-apply it so a mode change re-skins the visible overlay
	if (mapctx_on and mapctx_on.button_pressed) \
			or (mapctx_objects and mapctx_objects.button_pressed):
		_mapctx_changed()

func _apply_scene() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"; return
	var n := HighpolyLib.apply(r, _mode(), _textured())
	lbl.text = "%s: %d piece(s)" % [mode_btn.get_item_text(mode_btn.selected), n]

# current placed-object cull distance from the Range slider (mirrors the slider
# handler: the far end of the slider disables culling)
func _cull_radius() -> float:
	if mapctx_range == null: return 800.0
	return 1.0e9 if int(mapctx_range.value) >= 3500 else mapctx_range.value

# re-apply the placed-object distance-cull across the whole scene at the current
# range — only when "Optimize placed objects" is on. Called after anything that
# rebuilds the high-poly previews, so your placed content keeps culling.
func _reapply_placed_cull() -> void:
	if mapctx_optimize == null or not mapctx_optimize.button_pressed: return
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		PlacedCull.apply(r, _cull_radius(), true)

# ---------- per-selection detail override (live) ----------
func _override_label() -> String:
	return "Preview selected" if _mode() == HighpolyLib.Tier.LOW \
			else "Keep as Low-Poly"

func _override_toggled(pressed: bool) -> void:
	if pressed:
		_reoverride_selection()
	else:
		_release_override()

func _release_override() -> void:
	var n := 0
	for node in _override:
		if not is_instance_valid(node):
			continue
		n += HighpolyLib.apply(node, _mode(), _textured())   # back to the scene's mode
	_override.clear()
	if n > 0:
		lbl.text = "Override released: %d piece(s)" % n

# runs on toggle AND on every selection change while checked: the selection
# gets the opposite detail level of the scene; whatever leaves the selection
# returns to the scene's mode
func _reoverride_selection() -> void:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	var low_scene := _mode() == HighpolyLib.Tier.LOW
	var tier := HighpolyLib.Tier.HIGH if low_scene else HighpolyLib.Tier.LOW
	var tex := true if low_scene else _textured()
	for node in _override.duplicate():
		if not is_instance_valid(node):
			_override.erase(node)
			continue
		if not sel.has(node):
			HighpolyLib.apply(node, _mode(), _textured())
			_override.erase(node)
	var n := 0
	for s in sel:
		n += HighpolyLib.apply(s, tier, tex)
		if not _override.has(s):
			_override.append(s)
	lbl.text = ("%s: %d piece(s)" % [_override_label(), n]) if n > 0 \
			else "Override: select object(s) — follows the selection live"
	if not HighpolyLib.use_legacy:
		var missing: Array = HighpolyLib.take_wanted()
		if not missing.is_empty():
			sync.prioritize_scene(missing)

# ---------- viewport double-click: doors, then variant cycling ----------
# Double-clicking a door proxy swings it open/closed like in game. If no door
# was hit, a prop that ships variant models (police liveries, barn colours,
# destroyed shells, …) cycles base -> variants -> base instead — doors always
# win when a prop is both. Only consumed when something was actually hit, so
# normal click/drag selection and camera behavior stay untouched.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.double_click:
			var r := EditorInterface.get_edited_scene_root()
			var hit: Dictionary = HighpolyDoors.click(camera, mb.position, r)
			if hit.is_empty():
				hit = HighpolyVariants.click(camera, mb.position, r)
			if not hit.is_empty():
				lbl.text = str(hit.get("msg", ""))
				return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

# ---------- collision visualization ----------
func _collision_changed() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"
		col_chk.set_pressed_no_signal(false)
		return
	var on := col_chk.button_pressed
	iso_chk.disabled = not on
	if not on:
		# turning the overlay off while isolated would leave hidden objects with
		# no geometry at all — release the isolation first
		if HighpolyCollision.has_isolation():
			HighpolyCollision.release_isolation(_mode(), _textured(), false)
		iso_chk.set_pressed_no_signal(false)
	var n := HighpolyCollision.apply(r, on)
	lbl.text = ("Collision shown: %d object(s)" % n) if on else "Collision overlays removed"

func _isolate_toggled(pressed: bool) -> void:
	if pressed:
		_reisolate_selection()
	else:
		var n := HighpolyCollision.release_isolation(
			_mode(), _textured(), col_chk.button_pressed)
		lbl.text = "Isolation released: %d object(s)" % n

# runs on toggle AND on every selection change while isolating: selected
# objects go collision-only, deselected ones get their model back
func _reisolate_selection() -> void:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	var n := HighpolyCollision.reisolate(sel, _mode(), _textured())
	lbl.text = ("Isolated collision: %d object(s)" % n) if n > 0 \
			else "Isolate: select placed object(s) — follows the selection live"

func _on_selection_changed() -> void:
	if ovr_chk != null and ovr_chk.button_pressed:
		_reoverride_selection()
	if iso_chk != null and iso_chk.button_pressed and col_chk.button_pressed:
		_reisolate_selection()

# ---------- sync scope (replaces the Purge button) ----------
func _sync_scope_control() -> void:
	if scope_btn == null: return
	scope_btn.select(scope_btn.get_item_index(1 if HighpolyStore.scope() == "full" else 0))

func _scope_changed() -> void:
	var to_full: bool = scope_btn.get_selected_id() == 1
	if to_full:
		var missing: int = maxi(HighpolyStore.remote.size() - HighpolyStore.count(), 0)
		var dlg := ConfirmationDialog.new()
		dlg.dialog_text = ("Download the whole library?\n\n~%d model(s) still to fetch — this can take a while " +
				"on a slow connection. It runs quietly in the background (pause any time), " +
				"and the editor stays fully usable.") % missing
		dlg.ok_button_text = "Download all"
		dlg.cancel_button_text = "Cancel"
		dlg.confirmed.connect(func():
			HighpolyStore.set_scope("full")
			lbl.text = "Syncing the full library in the background…"
			await sync.check_now())
		dlg.canceled.connect(func():
			_sync_scope_control()      # snap back, nothing changed
			dlg.queue_free())
		EditorInterface.popup_dialog_centered(dlg)
		return
	# dropping to scene-only: prune everything the open scene doesn't use
	var r := EditorInterface.get_edited_scene_root()
	var keep := {}
	if r != null:
		for k in HighpolyLib.scene_keys(r):
			keep[k] = true
	var extra: int = HighpolyStore.count() - keep.size()
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "Keep only the current scene's models?\nFrees the rest from disk (roughly %d model(s)) — anything you need later re-downloads on demand." % maxi(extra, 0)
	dlg.ok_button_text = "Scene only"
	dlg.confirmed.connect(func():
		HighpolyStore.set_scope("scene")
		# drop overlays first so nothing references the files being removed
		var root := EditorInterface.get_edited_scene_root()
		if root != null and _mode() != HighpolyLib.Tier.LOW:
			HighpolyLib.apply(root, HighpolyLib.Tier.LOW, true)
		previews.clear_cache()
		var n := HighpolyStore.prune_keep(keep)
		if root != null and _mode() != HighpolyLib.Tier.LOW:
			_apply_scene()
		lbl.text = "Scene-only: freed %d model(s)" % n)
	dlg.canceled.connect(func():
		_sync_scope_control()      # snap the control back, nothing changed
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _on_node_added(node: Node) -> void:
	if not (node is Node3D): return
	if node.name == HighpolyLib.HP_NODE or node.name == HighpolyCollision.COL_NODE: return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root.is_ancestor_of(node): return
	if HighpolyLib.in_overlay(node): return
	# collision overlay for pieces placed while "Show collisions" is on
	if col_chk != null and col_chk.button_pressed \
			and String(node.scene_file_path).begins_with("res://objects/"):
		_collision_deferred.call_deferred(node)
	if _mode() == HighpolyLib.Tier.LOW: return
	if HighpolyLib.match_key_public(node) == "": return
	# defer: let the editor finish placing/naming/positioning the instance
	_swap_deferred.call_deferred(node)

func _collision_deferred(node: Node) -> void:
	if not is_instance_valid(node) or not (node is Node3D): return
	if col_chk == null or not col_chk.button_pressed: return
	HighpolyCollision.ensure_one(node as Node3D)

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
	# a piece placed while optimization is on should distance-cull right away, like
	# the rest of your map content (O(1): only this node's own meshes are touched)
	if mapctx_optimize != null and mapctx_optimize.button_pressed:
		PlacedCull.apply(node as Node3D, _cull_radius(), true)
