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
const ProfilerScript = preload("highpoly_profiler.gd")
const MapContextScript = preload("highpoly_mapcontext.gd")
const SyncScript = preload("highpoly_sync.gd")
const HighpolyCollision = preload("highpoly_collision.gd")
const HighpolyDoors = preload("highpoly_doors.gd")
const HighpolyVariants = preload("highpoly_variants.gd")
const LightingScript = preload("highpoly_lighting.gd")
const PlacedCull = preload("highpoly_placedcull.gd")
const TipsScript = preload("highpoly_tips.gd")
const JobsScript = preload("highpoly_jobs.gd")
const SdkHide = preload("highpoly_sdkhide.gd")
const ShapeViz = preload("highpoly_shapeviz.gd")
const Log = preload("highpoly_log.gd")
const SectionScript = preload("highpoly_section.gd")
const SplashScript = preload("highpoly_splash.gd")
const Theme_ = preload("highpoly_theme.gd")
var previews: Node
var profiler: Node          # performance recorder (highpoly_profiler.gd)
var perf_btn: Button       # its start/stop button
var mapctx: Node
var sync: Node
var col_chk: Button          # Show collisions overlay
var shape_chk: Button        # Godot's own collision outlines (off by default)
var iso_chk: Button          # Isolate selected: collision only (live w/ selection)
var col_pick: ColorPickerButton
var col_alpha: HSlider
var mapctx_on: Button        # Map Context enabled
var mapctx_objects: Button   # show original map objects (lives under Detail Mode)
var mapctx_backdrop: Button  # show the distant skyline / out-of-bounds vista
var mapctx_water: Button     # show the level's rivers / harbour / sea
var _detail_chips: Node      # Detail Mode's chip row (hosts "Original map objects")
var mapctx_range: HSlider      # object render distance; 0 = objects off, 3500 = no culling
var mapctx_range_val: Label    # live "%dm" / "No Culling" readout next to the slider
var mapctx_maptile: Button   # project the maptile decal over SDK terrain+assets
var mapctx_fx: Button        # live GPU particles at the map's mined FX spawns
var mapctx_light: Button     # game lighting (sun/sky/fog from the real map VE)
var mapctx_gi: Button        # sub-toggle: SDFGI + SSAO (visible while lighting is on)
var mapctx_shadows: Button   # sub-toggle: sun shadows + overlay casting
var mapctx_maplights: Button # sub-toggle: the map's mined light entities
var mapctx_fill_row: HBoxContainer   # "Interior light" slider row (with the shadow controls)
var mapctx_fill: HSlider             # ambient held back from sky visibility, 0-60%
var mapctx_fill_val: Label
var mapctx_batch: OptionButton  # scenery batching grain (cell size)
var mapctx_optimize: Button  # distance-cull the user's PLACED objects (their custom map content)
var mapctx_variant_row: HBoxContainer  # "Variant" gamemode dropdown (visible with objects)
var mapctx_variant: OptionButton
var mapctx_timer: Timer
# generation counter for Map Context toggles: every click supersedes the
# in-flight handler (which may be awaiting a long download). A superseded
# handler must NEVER apply its captured — now stale — checkbox state.
var _mapctx_gen := 0
var update_btn: Button         # "Update Plugin to vX.Y.Z" — hidden until a newer version exists
var banner: Label              # legacy-mode notice ("reorganization pending")
var sync_lbl: Label
var jobs: Node                 # HighpolyJobs: the download queue
var job_row: VBoxContainer     # the one universal bar, in the Check-for-Updates slot
var job_bar: ProgressBar
var job_pct: Label             # "45%  1/2"
var job_what: Label            # what is downloading right now
var log_view: RichTextLabel
var log_count: Label
                               # download (typed by base, like mapctx/sync — the
                               # global class name isn't registered until a scan)
var pause_btn: Button
var check_btn: Button          # manual "Check for Updates" (forces a registry re-check)
var scope_btn: OptionButton    # sync scope: current scene only / all models
var quality_btn: OptionButton  # texture tier for the library: web / full in-game
var _edited_root: Node = null  # tracks the active scene to detect tab switches
var _ready_names: Dictionary = {}   # models that landed since the last swap-in pass
var _swap_timer: Timer
# ---- storage section (dock) ----
var storage_lbl: Label         # disk usage summary (computed async)
var purge_maps: OptionButton   # downloaded maps eligible for purge
var storage_cache_chk: Button  # "Fast startup cache" (baked mesh sidecars)
var purge_btn: Button
var _storage_gen := 0          # supersedes an in-flight usage scan

# Dropdown ids. These are PERSISTED per map (as "tex" in _save_mapctx_state), so
# they are never renumbered: MODE_LIGHT was added after the other three and took
# the next free id rather than the slot it occupies in the list. Ordering in the
# list is by cost; ordering by id is history.
#
# Each rung answers two questions that used to be tangled into one:
#
#   id  entry                             your placed pieces   the level around them
#   0   Low-Poly — what you export        SDK proxies          nothing, no download
#   3   Low-Poly + Minimal Downloads      SDK proxies          real, untextured
#   1   High-Poly (no textures)           real, clay           real, untextured
#   2   High-Poly (full textures)         real, textured       real, textured
#
# So the ONLY difference between rung 3 and rung 1 is whether the pieces you
# placed are swapped for real models. The surroundings are identical, and that is
# the point of the light rung: the real level to build inside, without pulling a
# high-poly model for every object in your own map.
#
# The three non-zero ids double as the map-context texture mode (0 flat SDK
# orange / 1 clay / 2 textured) — see _mapctx_tex_mode, which is why MODE_GREY
# and MODE_TEX keep the values they do.
# The mappings themselves live in highpoly_modes.gd, as pure functions of the id.
# An EditorPlugin cannot be constructed outside a running editor, so anything
# defined in THIS file is untestable — and this is the area where a wrong answer
# is silent (a rung that quietly downloads gigabytes, or repaints a map the wrong
# colour). Splitting them out is what makes them checkable.
const Modes = preload("highpoly_modes.gd")
const MODE_SDK := Modes.SDK
const MODE_LIGHT := Modes.LIGHT
const MODE_GREY := Modes.GREY
const MODE_TEX := Modes.TEX

# Mirrors the answer onto HighpolyLib.detail on every read. HighpolySync has to
# know the detail mode to choose a rendition (_tier_for), and it has no path to
# this dock. Writing the mirror HERE rather than in the handful of places that
# change the dropdown means it cannot go stale: every consumer of the mode goes
# through this function, so the mirror is refreshed by the same call that reads it.
func _mode() -> int:
	if mode_btn == null: return HighpolyLib.Tier.LOW
	var t: int = Modes.tier(mode_btn.get_selected_id())
	HighpolyLib.detail = t
	return t

func _textured() -> bool:
	return Modes.textured(mode_btn.get_selected_id()) if mode_btn else true

# True on every rung except the one that fetches nothing at all. Everything the
# Map Context section offers costs a download, so this is the single gate they
# all share — see _gate/_locked.
func _ctx_allowed() -> bool:
	return mode_btn != null and Modes.downloads(mode_btn.get_selected_id())

# Say what the current mode is SHOWING, in the status line.
#
# Low-Poly draws the SDK's own proxies, so a placed asset is a plain white
# block — correct, because that block is what gets exported. Without saying so,
# it reads as the plugin being broken: that exact complaint is what caused
# Low-Poly to be quietly changed into "our geometry, untextured" once before,
# which cost the mode its meaning. The answer is a sentence, not a redefinition.
func _mode_hint() -> String:
	match (mode_btn.get_selected_id() if mode_btn else MODE_SDK):
		MODE_SDK:
			return " — showing only what the SDK ships; nothing downloads on this setting"
		MODE_LIGHT:
			return " — your pieces are what you export, the level around them is real but untextured"
		_:
			return ""

func _mapctx_tex_mode() -> int:
	return Modes.ctx_tex(mode_btn.get_selected_id()) if mode_btn else MODE_TEX

# ---- the download gate ---------------------------------------------------
# Every control registered here is one that cannot do anything without fetching
# something first, so on the "nothing downloads" rung they are greyed out.
#
# They are greyed but left ENABLED on purpose. A disabled Button in Godot
# swallows the click without emitting anything, and that click is the only moment
# we know the user wanted the thing — so disabling them would grey out a control
# and then say nothing at all about why, which is the state this gate exists to
# fix. Instead the handler runs, _locked() snaps the control back, and the user
# gets a sentence naming the rung that would give them what they just asked for.
var _gated: Array = []          # of Control, each carrying a "gate_what" meta

# `what` is the subject of the warning sentence, so it reads as the thing the
# user just clicked. `back` is where an OptionButton is snapped to when refused
# (a Button always goes back to unpressed).
func _gate(c: Control, what: String, back := 0) -> Control:
	if c == null: return c
	c.set_meta("gate_what", what)
	c.set_meta("gate_back", back)
	c.tooltip_text += "\n\nNeeds a download, so it is unavailable on \"Low-Poly — what you export\"."
	_gated.append(c)
	return c

func _refresh_gates() -> void:
	var ok := _ctx_allowed()
	for c in _gated:
		if is_instance_valid(c):
			(c as Control).modulate.a = 1.0 if ok else 0.4

# True when the caller must stop. The click has already flipped the control by
# the time a handler runs, so refusing it means putting the control back first.
func _locked(c: Control) -> bool:
	if _ctx_allowed(): return false
	if c is Button:
		(c as Button).set_pressed_no_signal(false)
	elif c is OptionButton:
		(c as OptionButton).select(int(c.get_meta("gate_back", 0)))
	lbl.text = ("%s has to be downloaded, and this setting downloads nothing. "
		+ "Choose \"Low-Poly + Minimal Downloads\" above to get it untextured, "
		+ "or either High-Poly setting for the full version.") \
		% str(c.get_meta("gate_what", "That"))
	_flash_mode()
	return true

# Send the eye to the dropdown the message is talking about — the warning names
# a control the user is not looking at.
func _flash_mode() -> void:
	if mode_btn == null or not mode_btn.is_inside_tree(): return
	var tw := mode_btn.create_tween()
	tw.tween_property(mode_btn, "modulate", Color(1.7, 1.4, 0.55), 0.12)
	tw.tween_property(mode_btn, "modulate", Color.WHITE, 0.5)

# Dropping to the "nothing downloads" rung has to actually take the borrowed
# scenery down with it. Leaving it on screen would mean the rung that promises
# only-what-the-SDK-ships is showing a mined skyline, which is precisely the
# muddle the four rungs exist to remove.
#
# Nothing is deleted from disk: every layer here rebuilds from the same cache the
# moment the user climbs back up.
func _shed_map_context() -> int:
	var r := EditorInterface.get_edited_scene_root()
	var shed := 0
	for c in [mapctx_on, mapctx_objects, mapctx_backdrop, mapctx_water,
			mapctx_fx, mapctx_light]:
		if c != null and (c as Button).button_pressed:
			(c as Button).set_pressed_no_signal(false)
			shed += 1
	if mapctx_variant != null: mapctx_variant.select(0)
	if mapctx_variant_row != null: mapctx_variant_row.visible = false
	# the lighting sub-toggles only exist alongside Lighting itself
	for c in [mapctx_gi, mapctx_shadows, mapctx_maplights]:
		if c != null: (c as Control).visible = false
	if mapctx_fill_row != null: mapctx_fill_row.visible = false
	if r != null:
		HighpolyFx.clear(r)
		HighpolyGamemode.clear(r)
		LightingScript.clear(r)
		mapctx.apply(r, false, false, MODE_SDK)
		# and hand the SDK its own stand-ins back — the layers that were on had
		# hidden them to take their place
		_sdk_assets_hidden(false)
		_sdk_terrain_hidden(false)
	if shed > 0:
		_save_mapctx_state()
	return shed

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

	# ---- the one download bar, shown in place of "Check for Updates" ----
	# One bar, not a stack: only one transfer runs at a time now, so a stack
	# could only ever show one moving row and several idle ones.
	jobs = JobsScript.new()
	jobs.name = "HighpolyJobQueue"
	dock.add_child(jobs)
	job_row = VBoxContainer.new()
	job_row.visible = false
	job_what = Label.new()
	job_what.add_theme_font_size_override("font_size", Theme_.fs(11))
	job_what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	job_row.add_child(job_what)
	job_bar = ProgressBar.new()
	job_bar.min_value = 0.0
	job_bar.max_value = 1.0
	job_bar.show_percentage = false      # it cannot show "45%  1/2", so we draw it
	job_bar.custom_minimum_size = Vector2(0, 24)
	Theme_.bar(job_bar)
	job_row.add_child(job_bar)           # no row: the bar spans the panel

	# The reading sits ON the bar. As a child of the bar it is drawn over the
	# fill, and full-rect anchors keep it centred at any panel width.
	job_pct = Label.new()
	job_pct.set_anchors_preset(Control.PRESET_FULL_RECT)
	job_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	job_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	job_pct.mouse_filter = Control.MOUSE_FILTER_IGNORE
	job_pct.add_theme_font_size_override("font_size", Theme_.fs(11))
	job_pct.add_theme_color_override("font_color", Color.WHITE)
	# outlined, because the text crosses the boundary between the filled part of
	# the bar and the empty part and has to stay readable over both
	job_pct.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	job_pct.add_theme_constant_override("outline_size", 4)
	job_bar.add_child(job_pct)
	jobs.changed.connect(_refresh_job_bar)

	# (the model sync has no bar of its own — it reports on the universal bar)
	sync_lbl = Label.new()
	sync_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sync_lbl.add_theme_font_size_override("font_size", Theme_.fs(12))
	dock.add_child(sync_lbl)
	pause_btn = Button.new()
	pause_btn.text = "Pause downloads"
	pause_btn.visible = false
	pause_btn.tooltip_text = "Stops downloading for now. Use it if you are on limited internet, or need the bandwidth for something else. Nothing is lost. It carries on from where it stopped."
	pause_btn.pressed.connect(func():
		sync.paused = not sync.paused
		pause_btn.text = "Resume downloads" if sync.paused else "Pause downloads")
	dock.add_child(_centred(pause_btn))

	check_btn = Button.new()
	check_btn.text = "Check for Updates"
	check_btn.tooltip_text = "Checks for newly fixed models straight away. This happens by itself every hour, so you rarely need to press it."
	check_btn.pressed.connect(_check_updates_now)
	dock.add_child(_centred(check_btn))
	dock.add_child(job_row)      # takes the button's place while anything downloads

	scope_btn = OptionButton.new()
	scope_btn.add_item("Download only what this map needs", 0)
	scope_btn.add_item("Download everything in the background", 1)
	scope_btn.tooltip_text = "Only this map: keeps just the pieces your open map needs and frees the rest. Everything: quietly downloads the whole library so nothing keeps you waiting later. Either way, anything missing downloads the moment you need it."
	scope_btn.item_selected.connect(func(_i): _scope_changed())
	dock.add_child(scope_btn)

	# Texture quality sits with the other DOWNLOAD decision rather than in
	# Detail Mode: that dropdown selects geometry (proxy / mesh / textured
	# mesh), and folding a second axis into it turns three entries into a
	# six-entry matrix. The map you have open is always fetched at full
	# quality regardless of this — it governs the REST of the library.
	quality_btn = OptionButton.new()
	quality_btn.add_item("Textures: web quality (smaller)", 0)
	quality_btn.add_item("Textures: full in-game quality", 1)
	quality_btn.tooltip_text = "The map you're editing always uses full in-game textures. This sets quality for the REST of the library: web keeps it small; full matches the game everywhere (a much larger download)."
	quality_btn.item_selected.connect(func(_i): _quality_changed())
	dock.add_child(quality_btn)

	# The master control. It switches the borrowed scenery on and off and sets
	# the draw distance for the scenery, the effects, the map lights and your
	# own placed pieces — so it belongs at the top, not inside one section.
	var mcr_row := HBoxContainer.new(); dock.add_child(mcr_row)
	var mcr_lbl := Label.new(); mcr_lbl.text = "Range"
	mcr_row.add_child(mcr_lbl)
	mapctx_range = HSlider.new()
	mapctx_range.min_value = 0; mapctx_range.max_value = 3500
	mapctx_range.step = 100; mapctx_range.value = 800
	mapctx_range.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_range.tooltip_text = "The one distance that governs everything: how far away the real level's scenery, its effects and its lights keep drawing, and how far your own placed pieces keep drawing. Pull it down if the view gets choppy. At zero the borrowed scenery switches off entirely, leaving just your map."
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
		# the light cull now skips a stationary camera, so a range change has to
		# say so or dragging the slider while standing still would do nothing
		LightingScript.invalidate_light_cull()
		if _rr != null:
			HighpolyFx.set_range(_rr, _rad)
			if mapctx_optimize and mapctx_optimize.button_pressed:
				PlacedCull.apply(_rr, _rad, true)   # placed props ride the slider too
		# The slider is a VIEW DISTANCE control, nothing more. It used to double
		# as the on/off switch for the objects layer, and assigning
		# button_pressed fires the toggled handler, so dragging it off zero ran
		# the whole apply path and started DOWNLOADING prop meshes. That made
		# sense while the objects chip was hidden; now that it is a real switch
		# of its own, the slider must never load anything, only decide how far
		# out what is already built stays visible. mapctx.set_radius() above has
		# already re-culled; nothing else here may touch a toggle.
		_save_mapctx_state())

	# From here down the panel is built into collapsible sections. `host` is
	# whichever section's content box is currently being filled, so the existing
	# build order — which several controls depend on — is untouched.
	var host: Node = _section("Detail Mode",
		"Whether you are looking at the Low-Poly pieces you actually build and export with, or the real High-Poly game models laid over the top of them. Switching to High-Poly changes nothing about your map: the Low-Poly underneath is still what gets saved.")

	mode_btn = OptionButton.new()
	# Each entry means ONE thing, for both halves of the plugin — the borrowed
	# scenery and the pieces you placed. Entry 0 briefly drew our own geometry
	# for placed objects while showing SDK colours for the scenery, which made
	# it pixel-identical to entry 1 and left no way to see your real export.
	for id in Modes.ORDER:      # cheapest rung first
		mode_btn.add_item(Modes.label(id), id)
	mode_btn.tooltip_text = "Low-Poly — what you export: only what the SDK ships, and nothing is downloaded.\n\nLow-Poly + Minimal Downloads: your own pieces stay exactly as you export them, but the real level is brought in around them — ground, water, skyline, lighting and the level's own objects — untextured, so it stays small.\n\nHigh-Poly: your pieces are swapped for the real game models too, in clay or with their real textures."
	mode_btn.selected = 0
	mode_btn.item_selected.connect(func(_i): _mode_changed())
	host.add_child(mode_btn)

	# held on the instance: "Original map objects" is created later, with the rest
	# of the map-context controls, but belongs in THIS row — Detail Mode is what
	# governs how it looks.
	_detail_chips = _chip_row(host)
	var detail_chips: Node = _detail_chips
	ovr_chk = Theme_.chip(_override_label())
	ovr_chk.tooltip_text = "Swaps just the pieces you have selected to High-Poly, leaving the rest Low-Poly. Handy for lining something up closely. When the whole map is already High-Poly it does the reverse: your selection drops back to Low-Poly so a heavy area stays smooth while you work."
	ovr_chk.toggled.connect(_override_toggled)
	detail_chips.add_child(ovr_chk)
	_gate(ovr_chk, "Previewing a selection in High-Poly")

	host = _section("Collision",
		"Shows the invisible shapes players bump into. They are often not the shape they look like, which is why something can feel wrong to walk past even when it looks right.")

	var col_chips := _chip_row(host)
	col_chk = Theme_.chip("Collisions")
	col_chk.tooltip_text = "Rough guide to how solid an object is, in see-through red. It shows the object's own shape scaled the way the game scales collision, so a stretched object still bumps as though it were square. It is an approximation, not the game's real collision data, so treat it as a hint rather than an exact answer. Preview only. Nothing about your map changes."
	col_chk.toggled.connect(func(_v): _collision_changed())
	col_chips.add_child(col_chk)

	iso_chk = Theme_.chip("Isolate selected")
	iso_chk.disabled = true
	iso_chk.tooltip_text = "Hides everything except the collision shapes of the pieces you have selected, so you can look at one shape without the rest in the way. Needs Collisions switched on."
	iso_chk.toggled.connect(_isolate_toggled)
	col_chips.add_child(iso_chk)

	# ON by default. These are the editor's normal outlines, and switching them
	# off silently changes how the editor behaves for someone who never asked:
	# an object out of draw range leaves nothing on screen at all, which reads as
	# the plugin having eaten it. Better to keep the SDK's own behaviour and let
	# anyone who wants the frames back turn them off deliberately.
	#
	# The cost is real on a built-up level: one wireframe per placed object,
	# thousands of them drawn every frame, and it does stutter. That is what the
	# chip is for, and the tooltip says so.
	shape_chk = Theme_.chip("Godot shape outlines")
	shape_chk.tooltip_text = "Godot draws a teal outline around every object's collision shape. On a busy level that is thousands of extra outlines every frame, so switching them off can smooth out the viewport. They are on by default because that is how the editor normally behaves."
	shape_chk.toggled.connect(func(v: bool):
		var _r := EditorInterface.get_edited_scene_root()
		var n: int = ShapeViz.apply(_r, not v)
		lbl.text = "Godot shape outlines %s (%d)" % ["shown" if v else "hidden", n]
		EditorInterface.get_editor_settings().set_project_metadata(
			"highpoly", "shape_outlines", v))
	col_chips.add_child(shape_chk)

	var cc_row := HBoxContainer.new(); host.add_child(cc_row)
	var cc_lbl := Label.new(); cc_lbl.text = "Color"
	cc_row.add_child(cc_lbl)
	col_pick = ColorPickerButton.new()
	col_pick.edit_alpha = true
	col_pick.color = HighpolyCollision.get_color()
	col_pick.custom_minimum_size = Vector2(48, 0)
	col_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_pick.tooltip_text = "Colour and see-through-ness of the collision shapes."
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
	col_alpha.tooltip_text = "How see-through the collision shapes are."
	col_alpha.value_changed.connect(func(v: float):
		var c := HighpolyCollision.get_color()
		c.a = v
		HighpolyCollision.set_color(c)
		col_pick.color = c)
	ca_row.add_child(col_alpha)

	host = _section("Map Context",
		"Build inside the real level instead of an empty grey box: the ground, the skyline, the buildings, the lighting and the effects the real place has. All of it is preview only: none of it is saved into your map or exported.")

	var mc_chips := _chip_row(host)
	# sub-toggles of "Lighting", indented under the main row and only
	# visible while it is on
	var mc_sub := _chip_row(host, 14)
	mapctx_on = Theme_.chip("Extended Terrain")
	mapctx_on.tooltip_text = "Adds the real ground and water that surround the play area, so you can see how your build sits in the world. The distant skyline and the level's own objects have their own switches beside this one. Preview only: none of it is saved into your map or included when you export."
	mapctx_on.toggled.connect(func(v: bool):
		if _locked(mapctx_on): return
		var r0 := EditorInterface.get_edited_scene_root()
		# Extended Terrain used to force the objects layer ON with it, so there
		# was no way to see the surrounding ground without also pulling in every
		# object the real level has — which is what "the extended terrain is
		# including the objects within the map" was. The three layers are
		# independent now; Original map objects has its own switch.
		# the SDK's own terrain slab sits exactly where ours goes
		_sdk_terrain_hidden(v)
		# fast show/hide of the built terrain/backdrop/water layers — the full
		# rebuild also regenerated every map object. Falls back to the full
		# apply when nothing is built yet or the detail mode changed.
		if mapctx.set_context_shown(r0, v, _mapctx_tex_mode()):
			lbl.text = "Extended Terrain " + ("on" if v else "off")
			_save_mapctx_state()
			return
		_mapctx_changed())
	mc_chips.add_child(mapctx_on)

	# The distant skyline is its own layer: it is what you see PAST the edge of
	# the play area, and wanting the horizon is a different question from wanting
	# the ground underfoot or the level's own props.
	mapctx_backdrop = Theme_.chip("Backdrops")
	mapctx_backdrop.tooltip_text = "The distant skyline and out-of-bounds scenery the level is surrounded by: bridges, city facades and hills a kilometre or more out. Off by default, because it is heavy and sits well outside the area you build in. Draws whether or not the extended terrain is on."
	mapctx_backdrop.toggled.connect(func(v: bool):
		if _locked(mapctx_backdrop): return
		var r0 := EditorInterface.get_edited_scene_root()
		if v and mapctx.ensure_layer(r0, "backdrop", _mapctx_tex_mode()):
			mapctx.set_backdrop_shown(r0, true, _mapctx_tex_mode())
			lbl.text = "Backdrops shown"
			_save_mapctx_state()
			return
		if mapctx.set_backdrop_shown(r0, v, _mapctx_tex_mode()):
			lbl.text = "Backdrops " + ("shown" if v else "hidden")
			_save_mapctx_state()
			return
		_mapctx_changed())
	mc_chips.add_child(mapctx_backdrop)

	mapctx_water = Theme_.chip("Water")
	mapctx_water.tooltip_text = "The rivers, harbours and sea the real level has, at the real height, so you can see what your build sits above. Speed of the ripples follows the water setting in Configure Shaders, where zero holds it still. Maps with no water body simply have nothing to show."
	mapctx_water.toggled.connect(func(v: bool):
		if _locked(mapctx_water): return
		var r0 := EditorInterface.get_edited_scene_root()
		# flip it if it exists; if not, build JUST this layer. Only a scene with
		# no overlay at all needs the full apply.
		if v and mapctx.ensure_layer(r0, "water", _mapctx_tex_mode()):
			mapctx.set_water_shown(r0, true)
			lbl.text = "Water shown"
			_save_mapctx_state()
			return
		if mapctx.set_water_shown(r0, v):
			lbl.text = "Water " + ("shown" if v else "hidden")
			_save_mapctx_state()
			return
		_mapctx_changed())
	mc_chips.add_child(mapctx_water)

	mapctx_objects = Theme_.chip("Original map objects")
	mapctx_objects.tooltip_text = "Swaps the level's shipped assets for the real per-object geometry, so you get the actual buildings, vehicles and clutter instead of the single merged mesh the SDK ships. The merged one is hidden while this is on and comes back exactly as you left it when you turn it off. How they look follows the Detail Mode above; the Range slider in Map Context sets how far away you can still see them."
	mapctx_objects.toggled.connect(func(v: bool):
		if _locked(mapctx_objects): return
		# checkbox and Range slider are one control pair: turning objects ON
		# from a 0 range starts them at 100 m (slider 0 unchecks the box below)
		if v and mapctx_range != null and int(mapctx_range.value) == 0:
			mapctx_range.set_value_no_signal(100.0)
			if mapctx_range_val: mapctx_range_val.text = _range_label(100.0)
			mapctx.set_radius(100.0)
		# This layer REPLACES the level's own shipped assets, so it owns the
		# SDK's merged MP_<map>_Assets node: bringing in the real per-object
		# geometry means the merged stand-in should get out of the way, and
		# turning it back off restores it exactly as the user left it. Detail
		# Mode used to drive this, which was the wrong owner — it governs the
		# pieces you place, not the level's shipped ones.
		_sdk_assets_hidden(v)
		# fast show/hide of an already-built props layer — a full rebuild
		# re-parses ~2k GLBs (reads as "redownloading"). Falls back to the
		# full apply when nothing is built yet or the detail mode changed.
		_variant_row_update(v)
		var r0 := EditorInterface.get_edited_scene_root()
		if mapctx.set_objects_shown(r0, v, _mapctx_tex_mode()):
			lbl.text = "Map objects " + ("shown" if v else "hidden")
			_save_mapctx_state()
			return
		# not built yet: build JUST the props layer into the existing overlay.
		# The old path fell through to the full apply, which starts by clearing
		# the terrain and skyline it is about to rebuild identically.
		if v and mapctx.props_ready(mapctx.map_of(r0)) \
				and mapctx.ensure_layer(r0, "objects", _mapctx_tex_mode()):
			lbl.text = "Building the map objects…"
			_save_mapctx_state()
			return
		_mapctx_changed())
	# Lives in the MAP CONTEXT row with the other layers. It used to sit under
	# Detail Mode on the argument that it belongs beside the control governing
	# its look — but Detail Mode governs how several layers look, while this
	# switch decides whether a layer of the map context EXISTS at all. That is
	# the same question Extended Terrain, Backdrops and Water answer, and
	# grouping it with them is how people look for it.
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
	mapctx_variant.tooltip_text = "Shows one game mode's real layout: capture points, objectives and spawn areas. These are markers laid on top; the scenery itself is the same for every mode."
	mapctx_variant.item_selected.connect(func(_i):
		if _locked(mapctx_variant): return
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

	# (no "Textures" checkbox any more — the overlay's look follows the Detail
	# Mode dropdown: Low-Poly = flat SDK orange, High-Poly no textures = grey
	# clay, High-Poly textured = real textures. See _mapctx_tex_mode().)

	mapctx_maptile = Theme_.chip("Ground photo")
	mapctx_maptile.tooltip_text = "Lays the map's aerial photo over the ground so it looks like the real place instead of flat colour. Turn it off if it makes buildings look muddy."
	mapctx_maptile.toggled.connect(func(v: bool):
		# instant ACTIVE add/remove (set_maptile) — no overlay rebuild, no
		# generation bump: a running props build keeps going, and the decal
		# can't outlive an uncheck via a superseded async re-apply
		lbl.text = mapctx.set_maptile(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	# Not shown: the SDK ships its own map-texture plugin with an "Apply Texture"
	# button in the same toolbar, and that one is saved into the scene where this
	# one was only ever a preview. Two of them darken the ground twice, so this
	# defers entirely. The control is kept unshown because the overlay code reads
	# its state in several places.
	# no_signal: this runs AFTER the toggled handler is connected, and that
	# handler reaches for `mapctx`, which is not built until later in _enter_tree
	mapctx_maptile.set_pressed_no_signal(false)
	HighpolyMapContext.maptile_enabled = false
	mapctx_maptile.visible = false
	mc_chips.add_child(mapctx_maptile)

	mapctx_fx = Theme_.chip("FX")
	mapctx_fx.tooltip_text = "Adds the fires, smoke columns and sparks the real level has, in the spots it has them. That includes the big distant smoke and haze cards near the skyline, which are effects rather than scenery. They are off by default, because they are hundreds of metres across and sit in front of the surroundings."
	mapctx_fx.toggled.connect(func(v: bool):
		if _locked(mapctx_fx): return
		var _r := EditorInterface.get_edited_scene_root()
		# the level's flipbook cards are drawn as props, so they follow this
		# switch too rather than arriving unbidden with the map objects
		mapctx.set_fx_cards_shown(_r, v)
		lbl.text = HighpolyFx.apply(_r, mapctx.map_of(_r), v)
		_save_mapctx_state())
	mc_chips.add_child(mapctx_fx)

	mapctx_light = Theme_.chip("Lighting")
	mapctx_light.tooltip_text = "Lights your map the way the real one is lit, with the same sun angle, sun colour, sky and haze. Replaces the editor's plain preview light while it is on."
	mapctx_light.toggled.connect(func(v: bool):
		if _locked(mapctx_light): return
		if mapctx_gi: mapctx_gi.visible = v
		if mapctx_shadows: mapctx_shadows.visible = v
		if mapctx_maplights: mapctx_maplights.visible = v
		if mapctx_fill_row: mapctx_fill_row.visible = v
		_lighting_changed()
		_save_mapctx_state())
	mc_chips.add_child(mapctx_light)

	# sub-toggles: only shown while Game lighting is on; both act LIVE on the
	# injected rig/overlay (no rebuild) and are remembered per map
	# Was "Soft shading", and it switched on Godot's real-time global
	# illumination as well as contact shading. The GI half made the view WORSE
	# than leaving the chip off — the game bakes its GI offline and our scene is
	# a runtime overlay spread over kilometres, which is the case that technique
	# handles worst. It now toggles only the contact darkening the game itself
	# has, so the label says that instead of promising bounced light.
	mapctx_gi = Theme_.chip("Contact shading")
	mapctx_gi.button_pressed = true
	mapctx_gi.visible = false
	mapctx_gi.tooltip_text = "Darkens the creases where surfaces meet — under vehicles, inside doorways, along kerbs. This is the same contact shading the game uses, at the radius the map itself specifies. Costs some frame rate; switch it off if the view gets choppy."
	mapctx_gi.toggled.connect(func(v: bool):
		lbl.text = LightingScript.set_gi(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_gi)

	mapctx_shadows = Theme_.chip("Shadows")
	mapctx_shadows.button_pressed = true
	mapctx_shadows.visible = false
	mapctx_shadows.tooltip_text = "Shadows cast by the sun. Costs frame rate. Switch it off if the view gets choppy."
	mapctx_shadows.toggled.connect(func(v: bool):
		lbl.text = LightingScript.set_shadows(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_shadows)

	# Interior light: how much ambient stops depending on seeing sky. Sits with
	# Shadows because that is the pairing people reach for — the complaint it
	# answers is "the shadowed side is pure black", and shadows are what put it
	# there. Shown only alongside the shadow controls, hidden with them.
	mapctx_fill_row = HBoxContainer.new()
	mapctx_fill_row.visible = false
	var fill_lbl := Label.new(); fill_lbl.text = "Interior light"
	mapctx_fill_row.add_child(fill_lbl)
	mapctx_fill = HSlider.new()
	mapctx_fill.min_value = 0; mapctx_fill.max_value = 60
	mapctx_fill.step = 1; mapctx_fill.value = int(round(LightingScript.interior_fill * 100.0))
	# An HSlider's minimum width is ZERO, and this row lives in an
	# HFlowContainer, which sizes children to their minimum. SIZE_EXPAND_FILL
	# means nothing there, so the bar collapsed to no width at all: the label and
	# the "22%" rendered, the draggable part did not exist. Give it a real width.
	mapctx_fill.custom_minimum_size = Vector2(150, 0)
	mapctx_fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_fill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mapctx_fill.tooltip_text = "Lifts the darkest areas — inside buildings, under bridges, the shadowed side of a wall — so you can see what you are working on. At zero the lighting is strictly what the sky reaches, which is the calibrated match to the real game and leaves interiors black. Preview only: it changes nothing about your map."
	mapctx_fill_row.add_child(mapctx_fill)
	mapctx_fill_val = Label.new()
	mapctx_fill_val.text = "%d%%" % int(mapctx_fill.value)
	mapctx_fill_row.add_child(mapctx_fill_val)
	mapctx_fill.value_changed.connect(func(v: float):
		mapctx_fill_val.text = "%d%%" % int(v)
		lbl.text = LightingScript.set_interior_fill(
			EditorInterface.get_edited_scene_root(), v / 100.0)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_fill_row)

	mapctx_maplights = Theme_.chip("Map lights")
	mapctx_maplights.button_pressed = false
	mapctx_maplights.visible = false
	mapctx_maplights.tooltip_text = "The street lights, signs and indoor lights the real level has, several thousand of them on some maps. Only the ones near your camera light up. Costs frame rate."
	mapctx_maplights.toggled.connect(func(v: bool):
		var _r := EditorInterface.get_edited_scene_root()
		lbl.text = LightingScript.set_map_lights(_r,
				v and mapctx_light.button_pressed, mapctx.map_of(_r))
		_save_mapctx_state())
	mc_sub.add_child(mapctx_maplights)


	# Optimize placed objects: distance-cull the props the USER places (their custom
	# map content — not the backdrop) so a densely-built map stays fast. Near props
	# stay full-quality and fully selectable/editable; distant ones stop drawing.
	# Follows the Range slider. Editor-only — nothing hidden, export untouched.
	# Scenery batching. The map package groups props into one MultiMesh per mesh
	# per cell, and at the packaged 64 m that is 13,407 MultiMeshes holding 3.4
	# instances each on Dumbo, half of them holding exactly one. Draw calls then
	# track object count 1:1 and the measured flyover hit 156,177 of them.
	#
	# Bigger cells mean far fewer draw calls but a coarser distance cull, so this
	# is exposed to be MEASURED with Record performance rather than guessed.
	var batch_row := HBoxContainer.new(); host.add_child(batch_row)
	var batch_lbl := Label.new(); batch_lbl.text = "Scenery batching"
	batch_row.add_child(batch_lbl)
	mapctx_batch = OptionButton.new()
	mapctx_batch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_batch.tooltip_text = "How coarsely the level's scenery is grouped for drawing. Larger groups mean far fewer draw calls, which is usually what limits the frame rate, at the cost of a less precise distance cull. Auto uses whatever the map was packaged with. Changing this rebuilds the scenery."
	mapctx_batch.add_item("Auto", 0)
	for m in [64, 128, 256, 512]:
		mapctx_batch.add_item("%d m" % m, m)
	mapctx_batch.select(0)
	mapctx_batch.item_selected.connect(func(i: int):
		if _locked(mapctx_batch): return
		HighpolyMapContext.cell_override = mapctx_batch.get_item_id(i)
		EditorInterface.get_editor_settings().set_project_metadata(
			"highpoly_mapctx", "_cell_override", HighpolyMapContext.cell_override)
		lbl.text = "Scenery batching %s. Rebuilding so it takes effect." \
			% mapctx_batch.get_item_text(i)
		_mapctx_changed())
	batch_row.add_child(mapctx_batch)

	# Not shown: this is just what the Range slider means for the pieces you
	# placed yourself, so it is always on and rides the slider like everything
	# else. Kept unshown because the overlay code reads its state.
	mapctx_optimize = Theme_.chip("Hide far pieces")
	mapctx_optimize.button_pressed = true
	mapctx_optimize.tooltip_text = "Stops drawing the pieces YOU placed once they are far from the camera, so a busy map keeps running smoothly. They are still there, still selectable, and nothing is left out when you export."
	mapctx_optimize.toggled.connect(func(on: bool):
		var _r := EditorInterface.get_edited_scene_root()
		var _rad := 800.0
		if mapctx_range:
			_rad = 1.0e9 if int(mapctx_range.value) >= 3500 else mapctx_range.value
		lbl.text = PlacedCull.apply(_r, _rad, on)   # visible feedback: "N culled at X m"
		_save_mapctx_state())
	mapctx_optimize.visible = false
	mc_chips.add_child(mapctx_optimize)

	# Everything in this section has to fetch the map's data before it can show
	# anything, so all of it is gated together. Registered here, in one place,
	# rather than beside each control: the list IS the answer to "what does this
	# plugin download", and that is worth being able to read at a glance.
	#
	# Deliberately NOT gated: the Range slider (a view distance, it loads
	# nothing), the lighting sub-toggles (they only exist while Lighting is on,
	# which is gated), and the collision overlays (drawn from the scene itself).
	_gate(mapctx_on, "The extended terrain")
	_gate(mapctx_backdrop, "The distant skyline")
	_gate(mapctx_water, "The water")
	_gate(mapctx_objects, "The level's own objects")
	_gate(mapctx_fx, "The level's effects")
	_gate(mapctx_light, "The game lighting")
	_gate(mapctx_variant, "The game mode layouts")
	_gate(mapctx_batch, "Rebuilding the scenery")

	var td_row := HBoxContainer.new(); host.add_child(td_row)
	var td_lbl := Label.new(); td_lbl.text = "Terrain"
	td_row.add_child(td_lbl)
	var td := OptionButton.new()
	td.add_item("Full (1m)", 1)
	td.add_item("High (2m)", 2)
	td.add_item("Medium (4m)", 4)
	td.select(1)   # High is the default (near-native, performant)
	td.tooltip_text = "How finely the ground is built. Full is the sharpest and the slowest. It is built once for each map and remembered afterwards, so you only wait the first time."
	td.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	td_row.add_child(td)
	td.item_selected.connect(func(_i):
		if _locked(td): return
		mapctx.terrain_step = td.get_item_id(td.selected)
		_mapctx_rebuild())
	_gate(td, "The ground", 1)          # snaps back to "High (2m)", its default

	var shader_btn := Button.new()
	shader_btn.text = "Configure Shaders…"
	shader_btn.tooltip_text = "Settings for the moving parts: rippling water, drifting smoke and swaying grass."
	shader_btn.pressed.connect(_open_shader_dialog)
	host.add_child(_centred(shader_btn))

	host = _section("Storage",
		"What has been downloaded to your PC, and how to get the space back. Nothing here belongs to your map, so removing any of it is always safe.")

	storage_lbl = Label.new()
	storage_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	storage_lbl.add_theme_font_size_override("font_size", Theme_.fs(12))
	storage_lbl.text = "Measuring disk usage…"
	host.add_child(storage_lbl)

	# Where it lives, and the reassurance that belongs with it. The downloads sit
	# in Godot's own app-data folder, which nobody would find on their own, and
	# not knowing where several gigabytes went is exactly what makes it alarming.
	var where := Label.new()
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	where.add_theme_font_size_override("font_size", Theme_.fs(11))
	where.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	where.text = "Kept outside your project, so none of it is part of your map or " \
		+ "your export. Deleting any of it only means it downloads again the next " \
		+ "time you need it."
	host.add_child(where)

	var files_btn := Button.new()
	files_btn.text = "Show me these files"
	files_btn.tooltip_text = "Opens the folder where the downloads are kept in your " \
		+ "file browser, so you can see exactly what is there. Nothing in it is part " \
		+ "of your map."
	files_btn.pressed.connect(func():
		var dir := ProjectSettings.globalize_path("user://")
		DirAccess.make_dir_recursive_absolute(dir)   # first run: may not exist yet
		OS.shell_show_in_file_manager(dir)
		lbl.text = "Opened %s" % dir)
	host.add_child(_centred(files_btn))

	var storage_chips := _chip_row(host)
	storage_cache_chk = Theme_.chip("Faster loading")
	storage_cache_chk.tooltip_text = "Saves the work of building the scenery so it comes back in seconds next time instead of minutes. On by default. Switch it off only if you are short on disk: it stops new scenery being saved, but does not free what is already there. Deleting a map's files clears its saved work too."
	var _es := EditorInterface.get_editor_settings()
	# Defaults ON. Without it every scenery build re-parses the whole prop set
	# from scratch (1,977 meshes / 3.65 GiB on Dumbo at in-game quality), which
	# is minutes of work repeated every session. Switching it off does not free
	# any disk either — it only stops FUTURE caching — so leaving it off was a
	# cost with no benefit. It stays available for anyone genuinely short on
	# space, which is the only reason to pick it.
	# batching grain is remembered per project: it is a performance choice, and
	# having it silently reset to Auto would make before/after runs disagree
	HighpolyMapContext.cell_override = int(_es.get_project_metadata(
		"highpoly_mapctx", "_cell_override", 0))
	var _mc_on := bool(_es.get_project_metadata("highpoly_mapctx", "_mesh_cache", true))
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
		lbl.text = "Faster loading " + ("is on. Scenery is saved as it is built" if v
				else "is off. What is already saved stays until you delete it"))
	storage_chips.add_child(storage_cache_chk)

	var purge_row := HBoxContainer.new(); host.add_child(purge_row)
	purge_maps = OptionButton.new()
	purge_maps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	purge_maps.tooltip_text = "Maps you have downloaded. Deleting one frees its space; anything it shares with another downloaded map is kept."
	purge_row.add_child(purge_maps)
	purge_btn = Button.new()
	purge_btn.text = "Delete"
	purge_btn.tooltip_text = "Frees this map's space on your PC. Safe to do, because it downloads again the next time you open that map."
	purge_btn.pressed.connect(_purge_selected)
	purge_row.add_child(purge_btn)

	# The fallback when per-map deleting has left something behind (models
	# arrive by paths no single map owns), or when you just want to start over.
	var reset_btn := Button.new()
	reset_btn.text = "Reset everything"
	reset_btn.tooltip_text = "Deletes everything downloaded: all maps, all scenery and the whole model library. Also puts this panel back to its defaults. Safe to do, because everything downloads again on demand."
	reset_btn.pressed.connect(_reset_everything)
	host.add_child(_centred(reset_btn))

	host = _section("Log",
		"A running account of what the plugin is doing, and anything that went wrong. If something breaks, save this and send it: it records which version, which level and which step, which a screenshot cannot.")

	log_count = Label.new()
	log_count.add_theme_font_size_override("font_size", Theme_.fs(11))
	log_count.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	log_count.text = "Nothing has gone wrong yet."
	host.add_child(log_count)

	log_view = RichTextLabel.new()
	log_view.bbcode_enabled = true
	log_view.scroll_following = true      # newest line stays in sight
	log_view.selection_enabled = true     # so a line can be copied on its own
	log_view.custom_minimum_size = Vector2(0, 190)
	log_view.add_theme_font_size_override("normal_font_size", Theme_.fs(10))
	host.add_child(log_view)

	# ---- problem markers ----
	# Reporting "something is missing over there" costs a conversation to turn
	# into a position. A marker carries the position, your note and what the
	# package expects at that spot, all inside the log file you were going to
	# send anyway.
	var mark_lbl := Label.new()
	mark_lbl.text = "Mark a problem"
	mark_lbl.add_theme_font_size_override("font_size", Theme_.fs(11))
	host.add_child(mark_lbl)
	var mark_note := LineEdit.new()
	mark_note.placeholder_text = "What is wrong here? e.g. wall missing"
	mark_note.tooltip_text = "Describe the problem, then press Drop marker. The marker lands in front of the viewport camera and you can drag it onto the exact spot."
	host.add_child(mark_note)
	var mark_row := HBoxContainer.new()
	mark_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host.add_child(mark_row)
	var mark_add := Button.new()
	mark_add.text = "Drop marker"
	mark_add.tooltip_text = "Places a sphere ahead of the camera with your note attached. Drag it onto the problem. Saving the log records its position and the meshes the map package expects there."
	mark_add.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		var note: String = mark_note.text.strip_edges()
		if note == "":
			lbl.text = "Type what is wrong first, then drop the marker."
			return
		var m := HighpolyMarkers.add(r, note, HighpolyMarkers.camera_point())
		if m == null:
			lbl.text = "Could not place the marker."
			return
		mark_note.text = ""
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(m)
		lbl.text = "Marker placed: %s. Drag it onto the spot, then Save log file." % note)
	mark_row.add_child(mark_add)
	var mark_import := Button.new()
	mark_import.text = "Import spheres"
	mark_import.tooltip_text = "Adopts markers you already placed by hand: every child of a node named Missing-Coordinates becomes a marker, using its node name as the note."
	mark_import.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		var n: int = HighpolyMarkers.import_from(r, "Missing-Coordinates")
		lbl.text = ("Imported %d marker(s). Your original node is untouched; "
			+ "delete it when you are happy.") % n if n > 0 \
			else "No node named Missing-Coordinates with children was found."
		)
	mark_row.add_child(mark_import)
	var mark_clear := Button.new()
	mark_clear.text = "Clear markers"
	mark_clear.tooltip_text = "Removes every marker this panel created. Nothing else in the scene is touched."
	mark_clear.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			return
		lbl.text = "Removed %d marker(s)." % HighpolyMarkers.clear(r))
	mark_row.add_child(mark_clear)

	# ---- performance recorder ----
	# Everything about performance in this plugin has been reasoned from triangle
	# counts, which is guesswork: a scene can be triangle-light and draw-call
	# heavy. This measures the real counters while you fly and says which
	# subsystem owned what was on screen when the frame rate dropped.
	var perf_row := HBoxContainer.new()
	perf_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host.add_child(perf_row)
	perf_btn = Button.new()
	perf_btn.text = "Record performance"
	perf_btn.tooltip_text = "Measures the frame rate while you fly, then reports what was actually being drawn when it was worst, broken down by what put it there. Fly the route that feels slow, then press Stop. Writes a spreadsheet next to the log."
	perf_btn.pressed.connect(func():
		if profiler == null: return
		if profiler.recording:
			lbl.text = profiler.stop()
			perf_btn.text = "Record performance"
		else:
			lbl.text = profiler.start()
			perf_btn.text = "Stop recording")
	perf_row.add_child(perf_btn)

	var log_row := HBoxContainer.new()
	log_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host.add_child(log_row)
	var save_log := Button.new()
	save_log.text = "Save log file"
	save_log.tooltip_text = "Writes everything below to a text file and opens the folder, so you can attach it to a bug report. It includes your plugin version, Godot version and graphics card, which is usually what the answer depends on."
	save_log.pressed.connect(func():
		var p: String = Log.save()
		if p == "":
			lbl.text = "Could not write the log file. See Godot's Output panel."
			return
		lbl.text = "Saved %s" % p
		OS.shell_show_in_file_manager(p))
	log_row.add_child(save_log)
	var clear_log := Button.new()
	clear_log.text = "Clear"
	clear_log.tooltip_text = "Empties the list below. Does not undo anything."
	clear_log.pressed.connect(func():
		Log.clear()
		log_view.clear()
		_refresh_log_count())
	log_row.add_child(clear_log)

	host = dock          # back to the panel itself: these two belong to no section
	lbl = Label.new()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(lbl)

	var ver_lbl := Label.new()
	ver_lbl.text = "v%s  ·  TabbedScamper & dfanz0r" % HighpolyUpdater.plugin_version()
	ver_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ver_lbl.tooltip_text = "Built by TabbedScamper. Frostbite format research by TabbedScamper and dfanz0r."
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
	HighpolyUpdater.sweep_removed()   # clear out what an older version left behind
	_apply_shape_outlines.call_deferred()
	_restore_section_state.call_deferred()
	Log.hook(_log_line)
	for r in Log.lines():                  # anything logged before the panel opened
		_log_line(int(r["lvl"]), str(r["m"]))
	Log.info("Panel opened")
	_adopt_tips.call_deferred()
	_first_run_open.call_deferred()
	_auto_perf_settings.call_deferred()
	_check_plugin_update.call_deferred()
	_refresh_storage.call_deferred()   # async walk; mapctx exists by deferred time

	profiler = ProfilerScript.new()
	profiler.name = "HighpolyProfiler"
	dock.add_child(profiler)
	previews = PreviewsScript.new()
	dock.add_child(previews)
	mapctx = MapContextScript.new()
	dock.add_child(mapctx)
	# the background props builder reports through the dock: live text in the
	# status label + a real progress bar (meshes built / total)
	mapctx.status_label = lbl
	mapctx.build_progress.connect(func(done: int, total: int):
		# same bar as the downloads: building the scenery is the second half of
		# "getting the level in", and it was the one long job with its own bar
		# somewhere else in the panel
		if done < total:
			jobs.set_activity("Building the level's scenery", done, total)
		else:
			jobs.clear_activity("Building the level's scenery"))
	# the skyline gets its own lane; jobs.set_activity is keyed, so it and the
	# scenery build show as separate bars instead of overwriting each other
	mapctx.backdrop_progress.connect(func(done: int, total: int):
		if done < total:
			jobs.set_activity("Building the skyline", done, total)
		else:
			jobs.clear_activity("Building the skyline"))
	mapctx.build_finished.connect(func(_built: int):
		jobs.clear_activity("Building the level's scenery")
		# sidecar-cached meshes load with the shader params they were SAVED
		# with — push the current Configure Shaders prefs over the fresh build
		var _sr := EditorInterface.get_edited_scene_root()
		if _sr != null: mapctx.apply_shader_prefs(_sr))
	# every map-context download (map data, props, maptile) gets its own bar
	mapctx.job_queue = jobs        # map-context downloads take their turn
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
			var _r3 := EditorInterface.get_edited_scene_root()
			LightingScript.tick_lights(_r3, _cam3.global_position)
			# Local lighting zones follow the camera the way the game follows the
			# player: entering an interior blends its exposure in, leaving blends
			# it out. Costs an AABB test per zone (59 across the whole fleet, and
			# most maps have none), so it is not worth gating.
			if mapctx_light != null and mapctx_light.button_pressed:
				LightingScript.tick_zones(_r3, _cam3.global_position,
						LightingScript.base_ev())
			ShapeViz.tick()      # tidy up any outline the editor rebuilt
		# a CANCELLED scenery build (Extended Terrain switched off, or a new
		# apply superseding it) ends without a build_finished — without this the
		# bar would sit there at whatever percent it had reached
		# keyed clear: active_label() may now be showing the OTHER job, so
		# gating on it would leave this lane stuck at whatever percent it reached
		if mapctx and mapctx.is_build_done():
			jobs.clear_activity("Building the level's scenery")
		# collision overlays follow objects the user moves/rescales
		if col_chk.button_pressed or HighpolyCollision.has_isolation():
			HighpolyCollision.refresh_transforms())
	dock.add_child(mapctx_timer); mapctx_timer.start()
	_edited_root = EditorInterface.get_edited_scene_root()

	# every session starts safe: the rung that downloads nothing, until a mode is
	# chosen. _restore_mapctx_state moves off it if the open map was left higher.
	mode_btn.select(mode_btn.get_item_index(MODE_SDK))
	previews.tier = HighpolyLib.Tier.LOW
	_refresh_gates()

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
		HighpolyCollision.release_isolation(_mode(), _textured(), false, false)
		HighpolyCollision.apply(r, false)                  # frees collision overlays
		# visibility_range_end is SAVED into the scene, so leaving it set means
		# the cull keeps running with the plugin disabled — and lands in the
		# user's .tscn if they save
		ShapeViz.release(r)                                # Godot's outlines back
		PlacedCull.release(r)
		SdkHide.restore_all(r)                             # SDK assets/terrain back as they were
		if mapctx: mapctx.apply(r, false, false, false)    # frees _MAP_CONTEXT + maptile
		LightingScript.clear(r)                          # frees _GAME_LIGHTING
		HighpolyLib.restore(r)                             # overlays off, SDK proxies back
	if previews: previews.shutdown()                       # SDK's own icons back
	HighpolyStore.save()
	Log.hook(Callable())         # never call into a freed panel
	if jobs: jobs.reset()        # release the gate: nobody is left to call release()
	if tools_btn:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, tools_btn)
		tools_btn.queue_free()
		tools_btn = null
	if win:
		# free(), not queue_free(): teardown DOES run at editor shutdown, but the
		# deferred queue is not flushed before the process exits, so a queued
		# window is never actually freed. Measured — a leaked Viewport, Camera,
		# Scenario, Environment, Canvas and CanvasItem at exit, all of which is
		# one Window. Freeing here takes the panel root, the scroller and
		# everything under them with it.
		win.free()
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
	_apply_open_scene()

# Draw the open scene with whatever Detail Mode we start in.
#
# Startup never applied anything, and that was CORRECT while Low-Poly meant
# "show the SDK's own proxy": a freshly loaded plugin had nothing to add. Once
# Low-Poly started drawing OUR geometry, the same silence became a bug. Loading
# or reloading the plugin left every placed object on its white blockout, and it
# only healed if the user happened to change modes.
#
# It got worse from there. The placed-object cull gates the proxy on the
# assumption that our overlay covers the near distance, so touching the Range
# slider hid the proxy behind a gate while the overlay that was supposed to
# replace it had never been built. Nothing drew at all.
func _apply_open_scene() -> void:
	if EditorInterface.get_edited_scene_root() == null:
		return
	_apply_scene()
	_reapply_placed_cull()

func _show_migration_wizard() -> void:
	var s: Dictionary = HighpolyMigrate.scan()
	var mb := int(s.model_bytes / 1048576.0)
	var freed := int(s.med_bytes / 1048576.0)
	var lines := [
		"High-Poly Preview 1.5 reorganizes its storage so the editor no longer",
		"imports every downloaded model (much faster startup + updates).",
		"",
		"• Move %d model(s) (%d MB) into the new cache: no re-download" % [s.models, mb],
		"• Delete %d editor import file(s) and %d retired medium-tier model(s) (frees ~%d MB)" % [s.import_files, s.med_files, freed],
	]
	if s.obj_only > 0:
		lines.append("• Re-download %d legacy model(s) in the current format" % s.obj_only)
	lines.append("• Map data re-checks itself automatically from now on")
	lines.append("")
	lines.append("Your scenes, the SDK proxies, and the Portal exporter are not affected.")
	var dlg := ConfirmationDialog.new()
	dlg.title = "High-Poly Preview: one-time reorganization"
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
		banner.text = "Downloads are paused until the files are tidied up, which happens the next time you start the editor."
		banner.visible = true
		lbl.text = "%d high-poly assets available (legacy layout)" % HighpolyLib.known().size()
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _show_scope_prompt(redownload: Array = []) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "High-Poly Preview: model downloads"
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
	_sync_quality_control()
	Log.info("startup: %d models local · scope=%s · quality=%s · mode=%s"
		% [HighpolyStore.count(), HighpolyStore.scope(),
			HighpolyStore.quality(),
			"low-poly" if _mode() == HighpolyLib.Tier.LOW else "high-poly"])
	await sync.start()
	if not extra.is_empty():
		sync.enqueue(extra, true)
	# Prefetch the open scene in BOTH modes. This used to skip Low-Poly on the
	# reasoning that nothing it fetched would be displayed, which was true when
	# Low-Poly drew the SDK proxy. Low-Poly now draws our geometry in clay, so
	# skipping the prefetch is what leaves placed assets as white blocks. The
	# bytes are not the same bytes either: _tier_for() pulls Low-Poly at the web
	# rendition, whose geometry is identical to hq and whose textures we do not
	# render, so the accurate silhouette arrives at a fraction of the size.
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		var keys := HighpolyLib.scene_keys(r)
		Log.info("prefetching %d model(s) for the open scene" % keys.size())
		sync.prioritize_scene(keys)

# ---------- background sync -> auto swap-in ----------
func _on_model_ready(nm: String) -> void:
	_ready_names[nm] = true
	previews.invalidate(nm)
	_swap_timer.start()   # debounce: one scene walk per burst of downloads

func _swap_in_ready() -> void:
	var names := _ready_names
	_ready_names = {}
	if names.is_empty():
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
	# The meshes that just landed are geometry the Object Library can draw icons
	# from, so tell the previews they exist. Without this the thumbnail for a
	# downloaded prop stayed the SDK's stock icon until the item was dropped into
	# a scene, because that placement was what finally fetched the library copy.
	if previews: previews.rescan_context()
	if gen != _mapctx_gen:
		return                         # user toggled Map Context while props re-verified
	if mapctx.last_verify_updates > 0 and mapctx_objects.button_pressed:
		lbl.text = mapctx.apply(r, mapctx_on.button_pressed, true, _mapctx_tex_mode(), mapctx_backdrop != null and mapctx_backdrop.button_pressed, mapctx_water != null and mapctx_water.button_pressed)

func _check_updates_now() -> void:
	if HighpolyLib.use_legacy:
		lbl.text = "Run the storage reorganization first (restart the editor)"
		return
	check_btn.disabled = true
	lbl.text = "Checking for updated models…"
	await sync.check_now()
	# whatever the open scene needs jumps the queue, same as startup — and
	# "same as startup" no longer carries a Low-Poly exception, because startup
	# no longer has one. Both modes draw our geometry, so both modes want the
	# scene's models; they differ only in which rendition _tier_for() picks.
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		sync.prioritize_scene(HighpolyLib.scene_keys(r))
	# Self-heal the open map's package (new files download via ETag) and sweep
	# obsoleted cache artifacts — one button = full migration.
	#
	# Deliberately OUTSIDE the mode check, and with the once-per-session ETag
	# guard cleared first. Both of those made this button lie about what it does:
	# in Low-Poly it skipped the map package entirely, and in any mode the guard
	# meant a map already touched this session was declared "ready" without a
	# single request to the server. So a republished map could not be picked up
	# by pressing Check for Updates — only by restarting the editor. Refreshing
	# the map package is cheap (it pulls mapdata.zip, not the multi-GB prop
	# tiers; those still follow the map-context build and the current mode).
	if r != null:
		var _map: String = mapctx.map_of(r)
		if _map != "" and mapctx.has_data(_map):
			mapctx.forget_session_check(_map)
			await mapctx.download_map(dock, _map, func(s: String): lbl.text = s)
			# The freshness check only FLAGS a republished props.zip; the download
			# itself lives in ensure_props. Without this the button refreshed the
			# map data and left every object mesh on the old build until the layer
			# was toggled off and on again — which is precisely the gap someone
			# presses this button to close. Only when the layer is actually shown,
			# so nobody in Low-Poly is handed a multi-GB download they did not ask
			# for; otherwise the flag simply waits for the layer to come on.
			if mapctx_objects != null and mapctx_objects.button_pressed \
					and not mapctx.props_ready(_map):
				await mapctx.ensure_props(dock, _map, func(s: String): lbl.text = s)
				if previews: previews.rescan_context()
		var _swept: int = mapctx.cleanup_stale(_map)
		if _swept > 0:
			lbl.text = "Checked for updates. %d out-of-date file(s) cleared." % _swept
			_refresh_storage()
			# the sweep can delete prop meshes the preview index thinks are there
			if previews: previews.rescan_context()
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
			lbl.text = "Map objects are still building. Check again when it finishes."
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

# The bar stands in for the Check for Updates button while anything is
# downloading, so the panel never shows both a button and a bar for the same
# thing. "45%  1/2" is this job's progress and which of the queued jobs it is.
# Colour carries the level so an error is findable in a long list without
# reading it. Appended line by line rather than rebuilt, because rebuilding an
# 800-line view on every message is what makes a log panel stutter.
func _log_line(lvl: int, msg: String) -> void:
	if log_view == null or not is_instance_valid(log_view): return
	var col := "#ffffffb0"
	if lvl == Log.Level.WARN: col = "#ffc061"
	elif lvl == Log.Level.ERROR: col = "#ff6b5e"
	log_view.append_text("[color=%s]%s  %s[/color]
"
		% [col, Time.get_time_string_from_system(), msg])
	_refresh_log_count()

func _refresh_log_count() -> void:
	if log_count == null or not is_instance_valid(log_count): return
	var e: int = Log.error_count()
	var w: int = Log.warning_count()
	if e == 0 and w == 0:
		log_count.text = "Nothing has gone wrong yet."
		log_count.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
		return
	log_count.text = "%d problem%s, %d warning%s. Please send this if you need help." 		% [e, "" if e == 1 else "s", w, "" if w == 1 else "s"]
	log_count.add_theme_color_override("font_color",
		Color(1.0, 0.42, 0.37) if e > 0 else Color(1.0, 0.75, 0.38))

# The SDK ships a merged low-poly mesh of the level's buildings and a slab of
# its terrain, both sitting exactly where our versions go. Ours replaces them
# while it is on; theirs comes back — as they left it — when it is off.
func _sdk_assets_hidden(hide: bool) -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null: return
	var n: int = SdkHide.set_hidden(r, SdkHide.ASSETS_SUFFIX, hide)
	if n > 0:
		Log.info("SDK level assets %s (%d node%s)"
			% ["hidden, Original map objects is showing instead" if hide
				else "restored", n, "" if n == 1 else "s"])

func _sdk_terrain_hidden(hide: bool) -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null: return
	var n: int = SdkHide.set_hidden(r, SdkHide.TERRAIN_SUFFIX, hide)
	if n > 0:
		Log.info("SDK terrain %s (%d node%s)"
			% ["hidden, Extended Terrain is showing instead" if hide else "restored",
				n, "" if n == 1 else "s"])

func _refresh_job_bar() -> void:
	if jobs == null or job_row == null: return
	var busy: bool = jobs.busy()
	job_row.visible = busy
	if check_btn: check_btn.visible = not busy
	if not busy: return
	job_bar.value = jobs.ratio()
	job_what.text = jobs.active_label()
	var pct := "%d%%" % int(round(jobs.ratio() * 100.0))
	# the "1/2" counts queued DOWNLOADS; local work is not one of a batch
	job_pct.text = pct if (jobs.count() <= 1 or jobs.active_label() == "") 		else "%s  %d/%d" % [pct, jobs.index(), jobs.count()]

# Off unless the user has said otherwise. Stored per project, so someone who
# wants Godot's outlines back keeps them back.
func _apply_shape_outlines() -> void:
	# Defaults to SHOWN: the editor's own behaviour, kept unless the user turns
	# it off. A saved preference still wins, so anyone who already switched them
	# off keeps them off.
	var want_shown: bool = bool(EditorInterface.get_editor_settings()
		.get_project_metadata("highpoly", "shape_outlines", true))
	if shape_chk: shape_chk.set_pressed_no_signal(want_shown)
	var n: int = ShapeViz.apply(EditorInterface.get_edited_scene_root(), not want_shown)
	if n > 0 and not want_shown:
		Log.info("Hid %d of Godot's collision outlines: thousands of them drawn "
			% n + "every frame is what was stuttering")

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
	pause_btn.visible = busy or sync.paused
	# One bar for everything. A real download outranks this, so a transfer in
	# progress is never hidden behind the background model sync.
	if busy:
		jobs.set_activity("Downloading models for this level",
			int(sync.progress_ratio() * 1000.0), 1000)
	else:
		jobs.clear_activity("Downloading models for this level")
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
	# One plain sentence, then a line per thing, in the words a map builder would
	# use. The old single line packed all of this into one dense string that
	# never actually said what any of it was.
	var lines := ["Using %s on your PC" % _human_size(total), ""]
	lines.append("  Object models: %s%s downloaded  (%s)" % [_fmt_n(int(models[0])),
		(" of %s" % _fmt_n(mtot)) if mtot > 0 else "", _human_size(int(models[1]))])
	lines.append("  Level scenery: %s%s pieces  (%s)" % [_fmt_n(int(props[0])),
		(" of %s" % _fmt_n(ptot)) if ptot > 0 else "", _human_size(int(props[1]))])
	lines.append("  Levels: %s downloaded  (%s)" % [_fmt_n(nmaps), _human_size(maps_bytes)])
	storage_lbl.text = "\n".join(lines)

func _reload_purge_options() -> void:
	if purge_maps == null: return
	var maps: Array = MapContextScript.downloaded_maps()
	# High-poly models arrive as soon as you open a level, whether or not you
	# ever switched Extended Terrain on. Without this the level never appears
	# here, and those models can never be freed.
	var open_map: String = mapctx.map_of(EditorInterface.get_edited_scene_root()) 		if mapctx != null else ""
	if open_map != "" and not maps.has(open_map) and _scene_model_count() > 0:
		maps = maps.duplicate()
		maps.append(open_map)
		maps.sort()
	purge_maps.clear()
	for m in maps:
		purge_maps.add_item(str(m))
	purge_maps.disabled = maps.is_empty()
	purge_btn.disabled = maps.is_empty()

# The models this scene actually has on disk. Also the fallback list of what to
# free for a level whose data was never downloaded — no placements file exists,
# but the open scene knows exactly which objects it uses.
func _scene_keys_on_disk() -> Dictionary:
	var out: Dictionary = {}
	var r := EditorInterface.get_edited_scene_root()
	if r == null: return out
	for k in HighpolyLib.scene_keys(r):        # an Array of names, not a Dictionary
		if FileAccess.file_exists(HighpolyStore.model_path(str(k))):
			out[k] = true
	return out

func _scene_model_count() -> int:
	return _scene_keys_on_disk().size()

func _purge_selected() -> void:
	if purge_maps.selected < 0: return
	var map := purge_maps.get_item_text(purge_maps.selected)
	purge_btn.disabled = true
	storage_lbl.text = "Sizing a %s purge…" % map
	# hand over the open scene's models: for a level with no downloaded data
	# they are the only record of which high-poly models belong to it
	var _open: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var extra: Dictionary = _scene_keys_on_disk() if map == _open else {}
	# purging a DIFFERENT map must not take the open scene's models with it —
	# that scene may have no downloaded map data, so nothing else vouches for them
	var keep: Dictionary = {} if map == _open else _scene_keys_on_disk()
	var info: Dictionary = await mapctx.purge_info(map, extra, keep)
	purge_btn.disabled = false
	var open_map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var freed := int(info.get("map_bytes", 0)) + int(info.get("excl_bytes", 0)) 		+ int(info.get("hp_bytes", 0))
	var excl_n: int = (info.get("excl", []) as Array).size()
	var txt := "Purge downloaded data for %s?\n\nFrees about %s: the map's own data (%s) plus %d objects only %s uses (%s)." % [
		map, _human_size(freed), _human_size(int(info.get("map_bytes", 0))),
		excl_n, map, _human_size(int(info.get("excl_bytes", 0)))]
	var hp_n: int = (info.get("hp_excl", []) as Array).size()
	if hp_n > 0:
		txt += "
Also frees %d high-poly model(s) only %s uses (%s)." % [
			hp_n, map, _human_size(int(info.get("hp_bytes", 0)))]
	if int(info.get("shared", 0)) > 0:
		txt += "\n%d objects are shared with other downloaded maps and will be KEPT: purging never breaks another map." % int(info.get("shared", 0))
	if open_map == map:
		txt += "\n\nWARNING: this is the map you currently have OPEN: its Map Context overlay will be removed."
	txt += "\n\nPurging is always safe: everything re-downloads on demand."
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = txt
	dlg.ok_button_text = "Purge"
	dlg.confirmed.connect(func():
		_do_purge(map, info, open_map == map)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

# Reset: delete everything downloaded and put the panel back to defaults.
func _reset_everything() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = ("Delete ALL downloaded data and reset this panel?\n\n"
		+ "Removes every map, all level scenery and the entire model library, "
		+ "and puts the toggles back to their defaults.\n\n"
		+ "Nothing about your own map is touched: the Low-Poly pieces you "
		+ "build and export with are untouched, and everything here downloads "
		+ "again on demand.")
	dlg.ok_button_text = "Reset everything"
	dlg.confirmed.connect(func():
		_do_reset()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)


func _do_reset() -> void:
	# tear the overlay down FIRST so nothing holds the files we are deleting —
	# same order _do_purge uses, for the same reason
	var r := EditorInterface.get_edited_scene_root()
	if r != null:
		if mapctx: lbl.text = mapctx.apply(r, false, false, false)
		HighpolyLib.restore(r)
		SdkHide.restore_all(r)
	if sync: sync.paused = true
	storage_lbl.text = "Deleting everything…"
	# capture BEFORE the delete: afterwards there are no downloaded maps to list,
	# and their saved toggle state would be stranded describing data that is gone
	var maps_before: Array = MapContextScript.downloaded_maps()
	var freed: int = await mapctx.purge_everything()
	# both stores are gone: forget the map-context index and every icon rendered
	# from it, or the library keeps offering stand-ins for deleted files
	HighpolyStore.ctx_scan(true)
	if previews: previews.rescan_context()

	# --- panel back to defaults ---
	if mode_btn: mode_btn.select(mode_btn.get_item_index(MODE_SDK))
	if previews: previews.tier = HighpolyLib.Tier.LOW
	_refresh_gates()      # back on the rung that downloads nothing: grey them again
	for b in [mapctx_on, mapctx_objects, mapctx_fx, mapctx_light, col_chk,
			iso_chk, ovr_chk]:
		if b: b.set_pressed_no_signal(false)
	if mapctx_backdrop: mapctx_backdrop.set_pressed_no_signal(false)
	if mapctx_water: mapctx_water.set_pressed_no_signal(false)
	HighpolyMapContext.show_fx_cards = false
	if mapctx_gi: mapctx_gi.visible = false
	if mapctx_shadows: mapctx_shadows.visible = false
	if mapctx_maplights: mapctx_maplights.visible = false
	if mapctx_fill_row: mapctx_fill_row.visible = false
	if mapctx_variant_row: mapctx_variant_row.visible = false
	if ovr_chk: ovr_chk.text = _override_label()
	_override.clear()
	# forget the per-map saved state too, or reopening a map restores toggles
	# describing data that no longer exists
	var es := EditorInterface.get_editor_settings()
	for m in maps_before:
		es.set_project_metadata("highpoly_mapctx", str(m), {})
	var open_map: String = mapctx.map_of(r) if r != null else ""
	if open_map != "":
		es.set_project_metadata("highpoly_mapctx", open_map, {})
	# library settings back to shipped defaults too — "reset" should not leave
	# the next download silently running at in-game quality across the whole
	# library because of a choice made before the reset
	HighpolyStore.set_scope("")          # "" = not chosen yet
	HighpolyStore.set_quality("web")
	_sync_scope_control()
	_sync_quality_control()
	if storage_cache_chk:
		storage_cache_chk.set_pressed_no_signal(true)      # the shipped default
		HighpolyMapContext.mesh_cache_enabled = true
		es.set_project_metadata("highpoly_mapctx", "_mesh_cache", true)
	if sync:
		sync.paused = false
	lbl.text = "Reset. %s freed, and everything downloads again on demand." % _human_size(freed)
	_refresh_storage()


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
	# The purge can delete map-context meshes the LIBRARY was being served from
	# (a name held by only one store is owned by both systems). Re-index, drop the
	# icons rendered from what is gone, and re-apply so anything that lost its
	# stand-in falls back to the SDK proxy and queues the real model.
	HighpolyStore.ctx_scan(true)
	if previews: previews.rescan_context()
	if EditorInterface.get_edited_scene_root() != null:
		_apply_scene()
	lbl.text = "%s purged. About %s freed, and it re-downloads on demand." % [map,
		_human_size(int(info.get("map_bytes", 0)) + int(info.get("excl_bytes", 0)))]
	_refresh_storage()

# ---------- plugin self-update ----------
func _check_plugin_update() -> void:
	HighpolyUpdater.check_plugin_update(dock, func(new_version: String, _notes: String):
		if new_version != "" and update_btn != null:
			update_btn.text = "Update Plugin to v%s" % new_version
			update_btn.tooltip_text = "A newer version of this plugin is available. One click installs it; restart the editor afterwards."
			update_btn.visible = true)

func _do_plugin_update() -> void:
	update_btn.disabled = true
	# the updater fetches into memory, so there's no byte stream to track — show
	# an indeterminate row anyway, so this download isn't the one silent one
	# the updater fetches into memory, so there is no byte stream to track — it
	# still takes a turn in the queue so it cannot race a model download
	var token: int = await jobs.acquire("Plugin update")
	var ok: bool = await HighpolyUpdater.update_plugin(dock, func(msg: String):
		lbl.text = msg
		Log.info(msg))
	jobs.release(token, ok, "" if ok else "see the log for what failed")
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
		HighpolyCollision.release_isolation(_mode(), _textured(), false, false)
		HighpolyCollision.apply(old, false)                   # frees collision overlays
		HighpolyLib.restore(old)                              # overlays off, SDK proxies back
	# reset the dock to default for the newly-active scene (programmatic, no rebuild)
	if mode_btn: mode_btn.select(mode_btn.get_item_index(MODE_SDK))
	if previews: previews.tier = HighpolyLib.Tier.LOW
	_refresh_gates()      # the new scene starts on the rung that downloads nothing
	_override.clear()
	if ovr_chk:
		ovr_chk.set_pressed_no_signal(false)
		ovr_chk.text = _override_label()
	if mapctx_on: mapctx_on.set_pressed_no_signal(false)
	if mapctx_objects: mapctx_objects.set_pressed_no_signal(false)
	# the other two map-context layers reset with everything else, or the chips
	# would claim a skyline and a sea that the new scene has not built
	if mapctx_backdrop: mapctx_backdrop.set_pressed_no_signal(false)
	if mapctx_water: mapctx_water.set_pressed_no_signal(false)
	if mapctx_light: mapctx_light.set_pressed_no_signal(false)
	if mapctx_fx:
		mapctx_fx.set_pressed_no_signal(false)
		HighpolyMapContext.show_fx_cards = false   # keep the card layer in step
	if mapctx_gi: mapctx_gi.visible = false
	if mapctx_shadows: mapctx_shadows.visible = false
	if mapctx_maplights: mapctx_maplights.visible = false
	if mapctx_fill_row: mapctx_fill_row.visible = false
	if mapctx_variant_row: mapctx_variant_row.visible = false
	if col_chk: col_chk.set_pressed_no_signal(false)
	if iso_chk:
		iso_chk.set_pressed_no_signal(false)
		iso_chk.disabled = true
	# the remembered visibility is keyed by node path, and those paths belong to
	# the scene that just closed — put that one back before letting go of it.
	# Called even when `old` is already freed: each of these guards its own
	# restore on `root != null` (which a freed Object does NOT pass — measured on
	# Godot 4.6.3) but clears its remembered state unconditionally, and that
	# clearing must happen either way or the next scene inherits bookkeeping
	# belonging to a closed one.
	ShapeViz.release(old)
	PlacedCull.release(old)  # a saved property: don't leave it on a scene we're done with
	SdkHide.restore_all(old)
	_sync_maptile_control()   # the new scene may carry the SDK's own decal
	# The one thing that SHOULD carry across a swap: the pieces you placed in the
	# newly-active scene start culled to wherever the Range slider currently sits.
	# The cull was released from the outgoing scene but never applied to the
	# incoming one, so after a swap the slider read as active while nothing in the
	# new scene was actually following it.
	if r != null and is_instance_valid(r):
		_reapply_placed_cull()
	if lbl and old != null: lbl.text = "Different map opened, so everything is back to Low-Poly"
	# The new scene's props move to the front of the download queue — but ONLY if
	# High-Poly is actually on, exactly as _start_sync() does at launch.
	#
	# A swap resets the dock to Low-Poly a few lines above, and this used to skip
	# the prefetch on that basis: opening a map in Low-Poly began a large download
	# of models the mode did not draw. Low-Poly draws them now, so the prefetch is
	# what makes a freshly-opened scene show real shapes instead of white proxies.
	# The size objection is answered where it belongs, in _tier_for(): Low-Poly
	# pulls the web rendition, same geometry, a fraction of the bytes.
	if r != null and sync != null and not HighpolyLib.use_legacy:
		sync.prioritize_scene(HighpolyLib.scene_keys(r))
	# fresh dock instance (editor start / plugin re-enable) — not a scene
	# switch: bring the overlay back the way this map had it
	if old == null and r != null:
		_restore_mapctx_state.call_deferred()

# ensure the map's prop meshes are in the shared cache (only when objects are
# shown), then apply. Prop meshes download once and are reused across maps.
func _apply_mapctx(r: Node, on: bool, objs: bool, tex: int, gen: int) -> void:
	# Draw what is ALREADY on disk before waiting on anything.
	#
	# Terrain, backdrop, water and scatter all come out of mapdata.zip — ~94 MiB,
	# and apply() builds them synchronously in a moment. The map OBJECTS come out
	# of a separate package that is measured in gigabytes (Dumbo's in-game tier
	# is 3.65 GiB). This used to await that download and only then call apply(),
	# so the fast, already-local terrain was held hostage by the slow one.
	#
	# What that looked like: switching Extended Terrain on hid the SDK's own
	# terrain immediately and then rendered NOTHING for the whole download —
	# minutes of empty world, and if the transfer was interrupted, forever. The
	# user-visible bug was "no terrain or backdrops after downloading"; the cause
	# was ordering, not the terrain.
	var map: String = mapctx.map_of(r)
	# Nothing to fetch (the usual case once a map has been opened once), or the
	# context is being switched off: one build, no intermediate state.
	var bd: bool = mapctx_backdrop != null and mapctx_backdrop.button_pressed
	var wt: bool = mapctx_water != null and mapctx_water.button_pressed
	if not objs or mapctx.props_ready(map):
		lbl.text = mapctx.apply(r, on, objs, tex, bd, wt)
		return
	lbl.text = mapctx.apply(r, on, false, tex, bd, wt)   # terrain, water, backdrop NOW
	await mapctx.ensure_props(dock, map, func(s: String): lbl.text = s)
	# The meshes that just landed are geometry the Object Library can draw icons
	# from, so tell the previews they exist. Without this the thumbnail for a
	# downloaded prop stayed the SDK's stock icon until the item was dropped into
	# a scene, because that placement was what finally fetched the library copy.
	if previews: previews.rescan_context()
	if gen != _mapctx_gen:
		return              # user toggled again while props downloaded — stale state
	lbl.text = mapctx.apply(r, on, true, tex, bd, wt)    # objects on top once here

func _mapctx_rebuild() -> void:
	# rebuild with current toggles, no re-download (e.g. terrain detail changed)
	if not mapctx_on.button_pressed: return
	var r := EditorInterface.get_edited_scene_root()
	if mapctx.map_of(r) == "": return
	lbl.text = mapctx.apply(r, true, mapctx_objects.button_pressed, _mapctx_tex_mode(), mapctx_backdrop != null and mapctx_backdrop.button_pressed, mapctx_water != null and mapctx_water.button_pressed)

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
		if mapctx_fill_row: mapctx_fill_row.visible = false
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
		if mapctx_fill_row: mapctx_fill_row.visible = false

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
		banner.text = "Performance settings applied (multi-threaded rendering and shadow atlas). Restart the editor to activate them."
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
	w_sl.tooltip_text = "How fast the water ripples. 0 is completely still; 1 is the speed the real game uses."
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
	f_sl.tooltip_text = "How fast the distant smoke plumes billow. 0 freezes them still."
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
	wind_chk.tooltip_text = "Gentle sway on leaves and grass while you build. Trunks stay put. It is just for looks here. The real game does its own wind."
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
		"backdrop": mapctx_backdrop.button_pressed if mapctx_backdrop else false,
		"water": mapctx_water.button_pressed if mapctx_water else false,
		"range": mapctx_range.value if mapctx_range else 800.0,
		"maptile": false,      # the SDK plugin owns the ground texture now
		"light": mapctx_light.button_pressed if mapctx_light else false,
		"gi": mapctx_gi.button_pressed if mapctx_gi else true,
		"shadows": mapctx_shadows.button_pressed if mapctx_shadows else true,
		"maplights": mapctx_maplights.button_pressed if mapctx_maplights else false,
		"fill": mapctx_fill.value if mapctx_fill else 22.0,
		"optimize": true,      # always on: it is what the Range slider means
		"fx": mapctx_fx.button_pressed if mapctx_fx else false,
		"variant": mapctx_variant.get_item_text(mapctx_variant.selected)
				if mapctx_variant and mapctx_variant.selected >= 0 else "Off",
		# The RAW dropdown id, not _mapctx_tex_mode(). They were the same thing
		# while there were three entries; they are not any more, because the light
		# rung draws its surroundings in clay and so reports the High-Poly-grey
		# texture mode. Saving that would have quietly promoted anyone on the light
		# rung to High-Poly on their next open — and High-Poly swaps the pieces
		# they placed, so the rung's one promise would break on reload.
		"tex": mode_btn.get_selected_id() if mode_btn else MODE_SDK,
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
		mapctx_maptile.text = "Ground photo (the SDK's is on)"
		mapctx_maptile.tooltip_text = "This level already has the SDK's own map texture, applied from the 3D toolbar and saved in the scene, so the preview decal stays off. Two of them would darken the ground twice.\n\nNote the SDK's decal projects onto EVERYTHING beneath it, including high-poly models that already have their real textures. Delete the '%s' node under Static to go back to the preview decal, which leaves them alone." % String(theirs.name)
	else:
		mapctx_maptile.text = "Ground photo"
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
		# ignore whatever an older version saved: the SDK plugin owns this now
		mapctx_maptile.set_pressed_no_signal(false)
		HighpolyMapContext.maptile_enabled = false
	_sync_maptile_control()
	mapctx_on.set_pressed_no_signal(bool(d.get("on", false)))
	mapctx_objects.set_pressed_no_signal(bool(d.get("objects", false)))
	# set_pressed_no_signal skips the toggled handler, so the SDK _Assets node
	# has to be brought in line here too — otherwise reopening a map with objects
	# saved ON shows the shipped merged mesh AND our per-object geometry at once.
	_sdk_assets_hidden(bool(d.get("objects", false)))
	# defaults OFF, including for saved states written before Backdrops was a
	# switch. The skyline is heavy geometry a kilometre out, so it should be
	# something you ask for rather than something that arrives with the map.
	if mapctx_backdrop:
		mapctx_backdrop.set_pressed_no_signal(bool(d.get("backdrop", false)))
	if mapctx_water:
		mapctx_water.set_pressed_no_signal(bool(d.get("water", false)))
	if mapctx_gi: mapctx_gi.set_pressed_no_signal(bool(d.get("gi", true)))
	if mapctx_shadows: mapctx_shadows.set_pressed_no_signal(bool(d.get("shadows", true)))
	if mapctx_maplights: mapctx_maplights.set_pressed_no_signal(bool(d.get("maplights", false)))
	# set_pressed_no_signal skips the handler, so the card layer has to be told
	# separately — otherwise a restore leaves the statics saying "off" while the
	# chip reads on (or vice versa) and the next build guesses wrong.
	if mapctx_fx:
		HighpolyMapContext.show_fx_cards = bool(d.get("fx", false))
	if mapctx_fx and bool(d.get("fx", false)):
		mapctx_fx.set_pressed_no_signal(true)
		mapctx.set_fx_cards_shown(r, true)
		lbl.text = HighpolyFx.apply(r, map, true)
	if bool(d.get("light", false)) and mapctx_light != null:
		mapctx_light.set_pressed_no_signal(true)
		if mapctx_gi: mapctx_gi.visible = true
		if mapctx_shadows: mapctx_shadows.visible = true
		if mapctx_maplights: mapctx_maplights.visible = true
		if mapctx_fill_row: mapctx_fill_row.visible = true
		# restore the interior fill BEFORE the rig is built, so apply() reads the
		# saved value rather than the static default and the view does not flash
		# at 22% on the way to whatever the user actually chose
		if mapctx_fill:
			var fv: float = float(d.get("fill", mapctx_fill.value))
			mapctx_fill.set_value_no_signal(fv)
			if mapctx_fill_val: mapctx_fill_val.text = "%d%%" % int(fv)
			LightingScript.interior_fill = clampf(fv / 100.0, 0.0, 1.0)
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
	lbl.text = "Bringing back the real level for %s…" % map
	var saved_tex := int(d.get("tex", 0))
	# MIGRATION. Before the light rung existed, id 0 meant plain "Low-Poly" and
	# could perfectly well have map context switched on with it. Restoring such a
	# state literally would now land on the rung that downloads nothing, which
	# sheds every layer the user had left on — they would open their map and find
	# the scenery gone, with no clue that a mode they never touched took it away.
	#
	# A saved state carrying any layer therefore means the light rung, which is
	# where that combination lives now. Nothing is re-downloaded; it is the same
	# cache, re-labelled.
	if saved_tex == MODE_SDK and (bool(d.get("on", false)) or bool(d.get("objects", false)) \
			or bool(d.get("backdrop", false)) or bool(d.get("water", false)) \
			or bool(d.get("light", false)) or bool(d.get("fx", false))):
		saved_tex = MODE_LIGHT
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
	var bd := mapctx_backdrop != null and mapctx_backdrop.button_pressed
	var wt := mapctx_water != null and mapctx_water.button_pressed
	var tex := _mapctx_tex_mode()
	var r := EditorInterface.get_edited_scene_root()
	var rn := "<none>" if r == null else String(r.name)
	var map: String = mapctx.map_of(r)
	# Backdrops counts as a reason to build. Without it in this test, switching
	# Backdrops on with the terrain and objects off fell into the branch below,
	# which applies with backdrop=false and returns, so the toggle did nothing
	# unless Extended Terrain happened to be on as well.
	if not on and not objs and not bd and not wt:
		# no layer wanted at all. Textures can still drape the SDK's shipped
		# maptile over the default terrain (no download needed)
		lbl.text = mapctx.apply(r, false, false, tex); return
	if map == "":
		lbl.text = "Scene root is '%s'. Open an MP_… level scene." % rn
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
	# The gate follows the rung: grey the download-backed controls on the rung
	# that fetches nothing, un-grey them on every other. Dropping onto that rung
	# also sheds whatever the map context had built, so the rung that promises
	# only-what-the-SDK-ships is telling the truth on screen as well as in words.
	_refresh_gates()
	var shed := 0
	if not _ctx_allowed():
		shed = _shed_map_context()
	# the scene-wide apply below re-uniforms everything, so overrides dissolve
	_override.clear()
	if ovr_chk:
		ovr_chk.set_pressed_no_signal(false)
		ovr_chk.text = _override_label()
	previews.tier = _mode()
	previews.textured = _textured()
	# The SDK's merged _Assets mesh is NOT this dropdown's business. Detail Mode
	# governs the pieces YOU placed; the thing that actually stands in for the
	# level's own shipped assets is "Original map objects", which brings in the
	# real per-object geometry. Ownership of that node moved there — hiding it
	# from here meant switching to High-Poly stripped the level's assets even
	# with nothing loaded to replace them.
	_apply_scene()
	# a mode switch rebuilds every preview — re-apply the placed-object cull so
	# your custom map content keeps distance-culling in the new detail mode
	_reapply_placed_cull()
	# whatever this scene needs but doesn't have yet: front of the queue, and
	# swapped in automatically as it lands (no prompt, no re-apply button).
	#
	# HIGH-POLY MODES ONLY. Low-Poly draws the SDK's own proxies and needs
	# nothing from our library, so it queues nothing — see _diff_and_queue.
	# Leaving on Low-Poly therefore fetches zero bytes; this is the moment the
	# user asks for real models, so it is also the moment the fetch belongs.
	if not HighpolyLib.use_legacy and _mode() != HighpolyLib.Tier.LOW:
		var missing: Array = HighpolyLib.take_wanted()
		if not missing.is_empty():
			sync.prioritize_scene(missing)
			lbl.text += ", %d downloading in background" % missing.size()
		# the hourly diff was skipped for every tick spent in Low-Poly, so the
		# library backlog has to be rebuilt on the way out or nothing but the
		# open scene would ever arrive
		sync.check_now()
	lbl.text += _mode_hint()
	if shed > 0:
		lbl.text += ". %d borrowed layer(s) switched off — still downloaded, back the moment you climb a rung" % shed
	# The map-context overlay follows the same dropdown (orange / clay /
	# textured). Re-skin what is already built rather than rebuild it: the full
	# apply() starts with _clear() and re-parses every prop, so changing Detail
	# Mode made the original map objects VANISH for the length of that rebuild.
	# Falls back to the rebuild only when there is nothing built to re-skin.
	if (mapctx_on and mapctx_on.button_pressed) \
			or (mapctx_objects and mapctx_objects.button_pressed) \
			or (mapctx_backdrop and mapctx_backdrop.button_pressed):
		if not mapctx.reskin(EditorInterface.get_edited_scene_root(),
				_mapctx_tex_mode()):
			_mapctx_changed()

func _apply_scene() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"; return
	var n := HighpolyLib.apply(r, _mode(), _textured())
	# Drain what the pass could not draw from the library. This used to happen
	# only on a mode switch, which was survivable while "could not draw" meant
	# "showed the SDK proxy": the user could see something was missing. A
	# map-context stand-in looks right, so nothing would ever prompt the upgrade.
	if not HighpolyLib.use_legacy and sync != null:
		var missing: Array = HighpolyLib.take_wanted()
		if not missing.is_empty():
			sync.prioritize_scene(missing)
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
	return "Preview in High-Poly" if _mode() == HighpolyLib.Tier.LOW \
			else "Keep as Low-Poly"

func _override_toggled(pressed: bool) -> void:
	if _locked(ovr_chk): return
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
			else "Override: select object(s), follows the selection live"
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
				var need := str(hit.get("fetch", ""))
				if need != "":
					# published but not on disk: fetch, then cycle for real. Not
					# awaited here because this handler must return a verdict to
					# the editor synchronously.
					_fetch_variants_then_cycle(hit.get("node"), need)
				return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

# Double-clicked a prop whose variants are published but not downloaded: fetch
# them, then perform the swap the click asked for, so one double-click is still
# one visible result rather than "click, wait, click again".
func _fetch_variants_then_cycle(node: Variant, key: String) -> void:
	if sync == null or HighpolyLib.use_legacy: return
	var n: int = await sync.fetch_variants(key)
	if not is_instance_valid(node) or not (node is Node3D):
		return
	if n <= 0:
		lbl.text = "%s: could not download its variants (see the log)" % key
		return
	var res: Dictionary = HighpolyVariants.cycle(node as Node3D, key)
	lbl.text = str(res.get("msg", "%s: %d variant(s) ready" % [key, n]))

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
			else "Isolate: select placed object(s), follows the selection live"

func _on_selection_changed() -> void:
	if ovr_chk != null and ovr_chk.button_pressed:
		_reoverride_selection()
	if iso_chk != null and iso_chk.button_pressed and col_chk.button_pressed:
		_reisolate_selection()

# ---------- sync scope (replaces the Purge button) ----------
func _sync_scope_control() -> void:
	if scope_btn == null: return
	scope_btn.select(scope_btn.get_item_index(1 if HighpolyStore.scope() == "full" else 0))

func _sync_quality_control() -> void:
	if quality_btn == null: return
	quality_btn.select(quality_btn.get_item_index(
		1 if HighpolyStore.quality() == "full" else 0))

# How many models switching to full quality actually touches, and the extra
# bytes, measured from the manifest's own per-model sizes rather than a figure
# baked into the message. Under "only what this map needs" that is the models
# already on disk; under "everything" it is the whole library.
# Uses has_entry (index lookup) not has_model (disk stat) — this runs over
# every manifest row.
func _quality_estimate() -> Dictionary:
	var scope_full := HighpolyStore.scope() == "full"
	var n := 0
	var extra := 0
	for nm in HighpolyStore.remote.keys():
		if not scope_full and not HighpolyStore.has_entry(nm):
			continue
		var e: Dictionary = HighpolyStore.remote[nm]
		var hq := int(e.get("hqkb", 0))
		if hq == 0: continue          # no hq rendition published for this one yet
		n += 1
		extra += maxi(hq - int(e.get("gkb", e.get("kb", 0))), 0)
	return {"count": n, "extra_kb": extra}

# Only the expensive direction gets a dialog, and it quotes a real figure —
# a vague "this is large" just trains people to click through.
func _quality_changed() -> void:
	var to_full: bool = quality_btn.get_selected_id() == 1
	if not to_full:
		# Dropping to web costs nothing and changes nothing already on disk:
		# hq copies are kept (HighpolySync._needs treats hq as satisfying any
		# tier), so this only affects what is fetched from here on.
		HighpolyStore.set_quality("web")
		lbl.text = "New downloads will use web-quality textures."
		return
	var est := _quality_estimate()
	var n: int = est["count"]
	var gb: float = float(est["extra_kb"]) / 1048576.0
	if n == 0:
		# No hq rendition published yet (or none of the models you hold has one).
		# Setting it is harmless — _rendition() falls back to the web fields —
		# but promising a download that cannot happen would be a lie.
		HighpolyStore.set_quality("full")
		lbl.text = "Full-quality textures aren't published yet. This takes effect when they are."
		return
	var dlg := ConfirmationDialog.new()
	# Scope and quality are independent: scope decides WHICH models you keep,
	# quality decides how good they are. Saying "the whole library" while the
	# user is on "only what this map needs" was simply wrong.
	if HighpolyStore.scope() == "full":
		dlg.dialog_text = ("Use full in-game textures for the whole library?\n\n" +
				"You keep every model, so all %d would re-download at full " +
				"quality: roughly %.1f GB more than web quality. It runs in " +
				"the background and you can pause it any time.\n\n" +
				"The map you're editing already uses full quality, so you only " +
				"need this if you want every other model to match.") % [n, gb]
	else:
		dlg.dialog_text = ("Use full in-game textures?\n\n" +
				"You're keeping only what your maps need, so this re-downloads " +
				"the %d model(s) you already have: roughly %.1f GB more than " +
				"web quality. Other models upgrade as you open the maps that " +
				"use them.\n\n" +
				"The map you're editing already uses full quality, so this is " +
				"for everything else you've collected.") % [n, gb]
	dlg.ok_button_text = "Use full quality"
	dlg.cancel_button_text = "Cancel"
	dlg.confirmed.connect(func():
		HighpolyStore.set_quality("full")
		lbl.text = "Upgrading the library to full-quality textures…"
		await sync.check_now())
	dlg.canceled.connect(func():
		_sync_quality_control()        # snap back, nothing changed
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _scope_changed() -> void:
	var to_full: bool = scope_btn.get_selected_id() == 1
	if to_full:
		var missing: int = maxi(HighpolyStore.remote.size() - HighpolyStore.count(), 0)
		var dlg := ConfirmationDialog.new()
		dlg.dialog_text = ("Download the whole library?\n\n~%d model(s) still to fetch. This can take a while " +
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
	dlg.dialog_text = "Keep only the current scene's models?\nFrees the rest from disk (roughly %d model(s)). Anything you need later re-downloads on demand." % maxi(extra, 0)
	dlg.ok_button_text = "Scene only"
	dlg.confirmed.connect(func():
		HighpolyStore.set_scope("scene")
		# drop overlays first so nothing references the files being removed
		var root := EditorInterface.get_edited_scene_root()
		# Unconditional now, both sides. The mode check was a proxy for "are there
		# overlays to drop", and that stopped being true when Low-Poly started
		# drawing our geometry: in Low-Poly this walked past live overlays and
		# pruned the files still open underneath them.
		if root != null:
			HighpolyLib.restore(root)
		previews.clear_cache()
		var n := HighpolyStore.prune_keep(keep)
		if root != null:
			_apply_scene()
		lbl.text = "Scene-only: freed %d model(s)" % n)
	dlg.canceled.connect(func():
		_sync_scope_control()      # snap the control back, nothing changed
		dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

func _on_node_added(node: Node) -> void:
	if not (node is Node3D): return
	if node.name == HighpolyLib.HP_NODE or node.name == HighpolyCollision.COL_NODE: return
	# OUR OWN BUILD IS NOT A USER PLACING SOMETHING.
	#
	# This is connected to the tree-wide node_added signal, so it fires for every
	# node anyone adds anywhere — including the ~11,600 the map-context build
	# adds itself. Each one used to pay get_edited_scene_root(), an is_ancestor_of
	# walk UP to the root, and another walk up in in_overlay(), purely to
	# conclude that our node is ours. A bool checked first skips all of it.
	#
	# Nothing is missed: everything the build creates is overlay geometry, which
	# the in_overlay() test below would have rejected anyway.
	if mapctx != null and not mapctx.is_build_done(): return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root.is_ancestor_of(node): return
	if HighpolyLib.in_overlay(node): return
	# collision overlay for pieces placed while "Show collisions" is on
	if col_chk != null and col_chk.button_pressed \
			and String(node.scene_file_path).begins_with("res://objects/"):
		_collision_deferred.call_deferred(node)
	# No mode gate: dropping an asset in Low-Poly must still fetch and skin it.
	# This early return is the whole reason a dragged-in prop stayed the SDK's
	# white proxy and never updated -- the download-on-place path below was
	# already built and simply never reached.
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
	var drew := HighpolyLib.apply_one(node as Node3D, k, _mode(), _textured())
	if not HighpolyLib.use_legacy and sync != null:
		# A just-placed prop goes to the VERY front of the queue -- and "drew
		# something" no longer means "we have the real model". apply_one now
		# succeeds on a map-context STAND-IN, which is a distance-streaming bake
		# (merged parts, half-res basecolor). Queueing only on failure would leave
		# a placed, inspected object showing that bake forever, which is precisely
		# the artefact this pairing exists to prevent.
		HighpolyLib.take_wanted()
		if not drew or not HighpolyStore.has_model(k):
			sync.prioritize_one(k)
	# a piece placed while optimization is on should distance-cull right away, like
	# the rest of your map content (O(1): only this node's own meshes are touched)
	if mapctx_optimize != null and mapctx_optimize.button_pressed:
		PlacedCull.apply(node as Node3D, _cull_radius(), true)
