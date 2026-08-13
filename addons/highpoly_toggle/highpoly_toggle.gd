@tool
extends EditorPlugin
# Low / High-poly interchange for Portal SDK level building.
#
# EVERYTHING COMES FROM THE PLAYER'S OWN BATTLEFIELD 6 INSTALL. The map's
# scenery, the high-poly models that replace the SDK's grey proxies, and the
# ground clutter are all read out of the game's own files; nothing is fetched
# and no extracted asset is redistributed. The panel says so at the top and
# disables itself when no install can be found - see _build_bf6_gate.

# The 1x1 white stand-in bound to the bf6_ground_col global sampler. Held here
# as well as in the map context's script static because the RenderingServer
# keeps only the RID: if the last reference dies, the global points at freed
# memory and the next terrain-blend material to draw takes the editor down.
var _ground_white: Texture2D

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
# How many props the last _apply_scene() put on the download queue. `wanted` is
# drained by whoever reads it first, so the count has to be carried rather than
# re-read: _mode_changed used to ask for the list again and always got nothing.
# relative preloads: the plugin works from ANY folder under addons/ (users
# often drop the whole repo zip in, nesting the plugin one level deeper)
# WRITTEN ONCE because it is applied from two places. The chip sets it when the
# panel is built and# change, and the second copy had drifted into a different voice entirely
# ("Project the map-tile colour over the SDK terrain + assets") — so the plain
# wording was replaced by jargon the moment anyone opened a scene, which is to
# say almost nobody ever saw it.

const LIGHTING_TIP := "Lights your map the way the real one is lit, with the \
same sun angle, sun colour, sky and haze. Replaces the editor's plain preview \
light while it is on."

# A GREYED-OUT CONTROL HAS TO SAY WHY, on the control itself. The reason this
# one is unavailable was only ever written into the status line by the click
# handler — which cannot run, because the chip is disabled. So the explanation
# existed and was unreachable at exactly the moment it was needed, and the map
# simply had a Lighting button that could not be pressed and never said why.
const LIGHTING_TIP_NONE := "This map has no lighting data yet, so there is \
nothing to switch on. Everything else in this panel still works."

const BJournal = preload("highpoly_journal.gd")
const PreviewsScript = preload("highpoly_previews.gd")
const ProfilerScript = preload("highpoly_profiler.gd")
const MapContextScript = preload("highpoly_mapcontext.gd")
# Only ever used to ASSIGN statics. Reads and calls go through HighpolyLib as
# before; it is assignment through a class_name that breaks after a live reload.
# See the note at MapContextScript.mesh_cache_enabled.
const LibScript = preload("highpoly_lib.gd")
const HighpolyCollision = preload("highpoly_collision.gd")
const HighpolyDoors = preload("highpoly_doors.gd")
const FlightPath = preload("highpoly_flightpath.gd")
const GameDir = preload("highpoly_gamedir.gd")
const HighpolyVariants = preload("highpoly_variants.gd")
const LightingScript = preload("highpoly_lighting.gd")
const GameSourceScript = preload("highpoly_gamesource.gd")
const PlacedCull = preload("highpoly_placedcull.gd")
const TipsScript = preload("highpoly_tips.gd")
const JobsScript = preload("highpoly_jobs.gd")
const SdkHide = preload("highpoly_sdkhide.gd")

# Progress-bar lane names. Kept together because the bar is keyed by string:
# opening a lane under one spelling and closing it under another leaves a bar
# stuck on screen for the rest of the session.
const FX_JOB := "Placing the level's effects"
const LIGHTS_JOB := "Placing the level's lights"
const ShapeViz = preload("highpoly_shapeviz.gd")
const Log = preload("highpoly_log.gd")
const SectionScript = preload("highpoly_section.gd")
const SplashScript = preload("highpoly_splash.gd")
const Theme_ = preload("highpoly_theme.gd")
var previews: Node
var profiler: Node          # performance recorder (highpoly_profiler.gd)
var perf_btn: Button       # its start/stop button
var mapctx: Node
var diag_pick: Button        # Pick mode: click-select our own overlay geometry
# The note box. A member rather than a local because two different paths label
# their reports with it: dropping a marker, and picking an object.
var mark_note: LineEdit
var _pick_last := Vector2(-1e9, -1e9)   # where the last pick click landed
var _hover_last := Vector2(-1e9, -1e9)  # where the last hover pick ran
var _hover_ms := 0                       # and when, so mouse moves are throttled
var col_chk: Button          # Show collisions overlay
var shape_chk: Button        # Godot's own collision outlines (off by default)
var iso_chk: Button          # Isolate selected: collision only (live w/ selection)
var col_pick: ColorPickerButton
var col_alpha: HSlider
var mapctx_on: Button        # Map Context enabled
var mapctx_objects: Button   # show original map objects (lives under Detail Mode)
var mapctx_backdrop: Button  # show the distant skyline / out-of-bounds vista
var mapctx_water: Button     # show the level's rivers / harbour / sea
var mapctx_roads: Button     # the street network baked onto the ground
var mapctx_grass: Button     # ground clutter from the level's scatter catalogue
var _detail_chips: Node      # Detail Mode's chip row (hosts "Original map objects")
var mapctx_range: HSlider      # object render distance; 0 = objects off, 3500 = no culling
var mapctx_range_val: Label    # live "%dm" / "No Culling" readout next to the slider
var mapctx_fx: Button        # live GPU particles at the map's mined FX spawns
var mapctx_light: Button     # game lighting (sun/sky/fog from the real map VE)
var mapctx_gi: Button        # sub-toggle: SDFGI + SSAO (visible while lighting is on)
var mapctx_shadows: Button   # sub-toggle: sun shadows + overlay casting
var mapctx_maplights: Button # sub-toggle: the map's mined light entities
var mapctx_fill_row: HBoxContainer   # "Interior light" slider row (with the shadow controls)
var mapctx_fill: HSlider             # ambient held back from sky visibility, 0-60%
var mapctx_fill_val: Label
var mapctx_photo_row: HBoxContainer  # "Ground photo" slider row (always shown)
var mapctx_photo: HSlider            # colour-map strength on the extended ground, 0-100%
var mapctx_photo_val: Label
var mapctx_optimize: Button  # distance-cull the user's PLACED objects (their custom map content)
var mapctx_variant_row: HBoxContainer  # "Variant" gamemode dropdown (visible with objects)
var mapctx_variant: OptionButton
# The selected mode's DATA KEY, resolved once when the selection changes.
# The per-tick heal below needs it, and resolving it there would re-parse the
# mined JSON several times a second for a value that only changes on a click.
var _gm_key := ""
# How long the gamemode mine is allowed before it is treated as dead. Measured
# at 3.4 s on MP_Aftermath with the level mounted; 90 s is far enough above that
# to survive a slow drive and still short enough that nobody waits out a
# session for a worker that died on its first line.
const MINE_TIMEOUT_MS := 90000
# Set when a heal ran and still produced no node - the dropdown is showing a
# layer name with no mined mode behind it, so retrying every tick would just
# rebuild nothing forever. Cleared whenever the selection or the map changes.
var _gm_heal_off := ""
var mapctx_timer: Timer

# ---------------------------------------------------------------------------
# THE BATTLEFIELD 6 GATE.
#
# Everything this plugin shows is read out of the player's own installed copy of
# Battlefield 6 — placements, geometry, textures, terrain, lights. Without it
# there is nothing to show, so the panel says so at the top in one line and
# turns everything else off until a real install is pointed at.
#
# Greyed out rather than hidden: a panel whose controls have vanished reads as a
# broken plugin, while a panel that is visibly disabled with a red line above it
# reads as a plugin waiting for something. Only the game-folder row stays live.
#
# `_bf6_disabled_was` remembers what each control's `disabled` was BEFORE the
# gate touched it, so re-enabling puts back what the panel wanted rather than
# switching on things that were disabled for their own reasons.
var bf6_row: VBoxContainer
var bf6_status: Label
var bf6_path: LineEdit
var bf6_browse: Button
var _bf6_ok := false
var _bf6_disabled_was := {}
# generation counter for Map Context toggles: every click supersedes the
# in-flight handler (which may be awaiting a long download). A superseded
# handler must NEVER apply its captured — now stale — checkbox state.
var _mapctx_gen := 0

# True while a game-source open is in flight. Every layer toggle re-enters
# _mapctx_changed, and without this each one starts its own read of the install.
var _gs_opening := false
var update_btn: Button         # "Update Plugin to vX.Y.Z" — hidden until a newer version exists
var banner: Label              # legacy-mode notice ("reorganization pending")
var jobs: Node                 # HighpolyJobs: the download queue
var job_row: VBoxContainer     # the one universal bar, in the Check-for-Updates slot
# the stage checklist shown while the install is being read
var read_panel: VBoxContainer
var read_title: Label
var read_list: Label
var read_note: Label
var _read_model: Dictionary = {}   # empty when no read is running
var job_bar: ProgressBar
var job_pct: Label             # "45%  1/2"
var job_what: Label            # what is downloading right now
var log_view: RichTextLabel
var log_count: Label
                               # download (typed by base, like mapctx/sync — the
                               # global class name isn't registered until a scan)
var check_btn: Button          # manual "Check for updates" (forces a registry re-check)
var _edited_root: Node = null  # tracks the active scene to detect tab switches
var _ready_names: Dictionary = {}   # models that landed since the last swap-in pass
# ---- storage section (dock) ----
var storage_lbl: Label         # disk usage summary (computed async)
var purge_maps: OptionButton   # downloaded maps eligible for purge
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
#   0   Low-Poly (what you export)        SDK proxies          nothing
#   3   Low-Poly + the real level         SDK proxies          real, untextured
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
const ObjDebugScript = preload("highpoly_objdebug.gd")
# The object debug window (Pick mode's Debug button). Lazily built, and held
# here so teardown can close it - an orphaned Window outlives the plugin.
var objdebug = null
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
	LibScript.detail = t
	return t

func _textured() -> bool:
	return Modes.textured(mode_btn.get_selected_id()) if mode_btn else true

# True on every rung except "Low-Poly (what you export)". THE MODE IS THE ONLY
# INPUT, deliberately.
#
# This used to also return true whenever the open map's data was already on
# disk — a download-era mercy: back then the gate existed so nothing FETCHED
# without being asked, and data sitting in the cache made the fetch moot. But
# nothing downloads any more, and the escape had a worse consequence than the
# kindness it bought: after one High-Poly session every map HAS data, so
# dropping back to Low-Poly never re-greyed the chips — they sat lit on the
# export rung, whose whole promise is "only what the SDK ships". The rung's
# meaning is the gate now, not the cost of honouring a click.
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
			return ": showing only what the SDK ships; your game install is not read on this setting"
		MODE_LIGHT:
			return ": your pieces are what you export, and the level around them is real but untextured"
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
	c.tooltip_text += "\n\nNeeds to read your game install, so it is unavailable on \"Low-Poly (what you export)\" — that setting shows only what the SDK ships."
	_gated.append(c)
	return c

func _refresh_gates() -> void:
	var ok := _ctx_allowed()
	for c in _gated:
		if is_instance_valid(c):
			(c as Control).modulate.a = 1.0 if ok else 0.4

# ---------------------------------------------------------------------------
# The Battlefield 6 gate: one status line, the folder, and a Browse button.
# ---------------------------------------------------------------------------
func _build_bf6_gate() -> void:
	bf6_row = VBoxContainer.new()
	bf6_row.name = "BF6Gate"
	dock.add_child(bf6_row)

	bf6_status = Label.new()
	bf6_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bf6_status.add_theme_font_size_override("font_size", Theme_.fs(13))
	bf6_row.add_child(bf6_status)

	var row := HBoxContainer.new()
	bf6_row.add_child(row)
	bf6_path = LineEdit.new()
	bf6_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bf6_path.placeholder_text = "…/steamapps/common/Battlefield 6"
	bf6_path.tooltip_text = "The folder your Battlefield 6 installation lives in — the one that CONTAINS Data, not Data itself."
	row.add_child(bf6_path)
	bf6_browse = Button.new()
	bf6_browse.text = "Locate…"
	row.add_child(bf6_browse)

	bf6_path.text_submitted.connect(func(t: String): _set_game_dir(t))
	bf6_path.focus_exited.connect(func(): _set_game_dir(bf6_path.text))
	bf6_browse.pressed.connect(func():
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.title = "Select your Battlefield 6 install folder"
		if bf6_path.text != "":
			fd.current_dir = bf6_path.text
		fd.dir_selected.connect(func(d: String): _set_game_dir(d))
		EditorInterface.get_base_control().add_child(fd)
		fd.popup_centered_ratio(0.6)
		fd.close_requested.connect(func(): fd.queue_free()))

	# Autodetect covers Steam and EA's usual folders plus every library in
	# libraryfolders.vdf, so most people never touch this row.
	var found: String = GameDir.autodetect()
	bf6_path.text = found if found != "" else GameDir.saved()
	_set_game_dir(bf6_path.text, found != "")


# Verify a folder, remember it when good, and re-gate the panel.
func _set_game_dir(path: String, remember := true) -> void:
	var r: Dictionary = GameDir.verify(path)
	_bf6_ok = bool(r["ok"])
	if _bf6_ok and remember:
		GameDir.save(path)
	if _bf6_ok:
		bf6_status.text = "Battlefield 6 detected"
		bf6_status.add_theme_color_override("font_color", Color(0.42, 0.86, 0.45))
		bf6_path.tooltip_text = str(r["why"])
		Log.info("Battlefield 6 found at %s" % path)
	else:
		bf6_status.text = "Battlefield 6 not detected — %s" % (
			"locate your installation to use this plugin" if path == ""
			else str(r["why"]))
		bf6_status.add_theme_color_override("font_color", Color(0.95, 0.35, 0.35))
		# LOGGED, not just shown. A gate that only fails on screen leaves a log
		# that looks like an idle session, and the user reports it as whatever
		# they were trying to do at the time.
		Log.warn("Battlefield 6 NOT found%s: %s. The panel stays disabled "
			% [" at " + path if path != "" else "", str(r["why"])]
			+ "until an install is located, so its buttons will not respond.")
	_apply_bf6_gate()


# Grey out and disable everything except the gate row itself.
func _apply_bf6_gate() -> void:
	if dock == null or not is_instance_valid(dock):
		return
	for c in dock.get_children():
		if c == bf6_row or c.has_meta("bf6_gate_exempt") or not (c is CanvasItem):
			continue
		(c as CanvasItem).modulate.a = 1.0 if _bf6_ok else 0.35
		gate_interactive(c, _bf6_ok, _bf6_disabled_was)


# Recursively disable (or restore) every control a user can act on.
#
# The prior value is recorded in `was` on the way down and put back on the way
# up, so a control the panel had disabled for its own reasons - a button that
# needs an open scene, say - is not switched on when the gate lifts.
#
# STATIC so it can be tested. EditorPlugin cannot be instantiated outside the
# editor ("Class 'EditorPlugin' can only be instantiated by editor"), so
# anything reachable only through the plugin instance needs a full editor run
# to exercise - and this is the piece with a failure mode worth pinning down.
static func gate_interactive(n: Node, enable: bool, was: Dictionary) -> void:
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for ch in cur.get_children():
			stack.append(ch)
		if not (cur is BaseButton or cur is Range or cur is LineEdit
				or cur is OptionButton or cur is TextEdit):
			continue
		var id := cur.get_instance_id()
		if enable:
			if was.has(id):
				cur.set("disabled", was[id] == true)
				cur.set("editable", true)
				was.erase(id)
		else:
			if not was.has(id):
				# `== true`, NOT bool(): Node.get() returns NULL for a property
				# the node does not have — a LineEdit has no `disabled` — and
				# bool(null) is not a constructor in GDScript, it throws. That
				# threw mid-walk, so the loop died on the first text box it met
				# and every control after it stayed live behind a greyed panel.
				was[id] = cur.get("disabled") == true
			cur.set("disabled", true)
			cur.set("editable", false)


# True when the caller must stop. The click has already flipped the control by
# the time a handler runs, so refusing it means putting the control back first.
func _locked(c: Control) -> bool:
	if _ctx_allowed(): return false
	if c is Button:
		(c as Button).set_pressed_no_signal(false)
	elif c is OptionButton:
		(c as OptionButton).select(int(c.get_meta("gate_back", 0)))
	lbl.text = ("%s is not on this machine for the open map, and this setting "
		+ "fetches nothing. Either install the map's data locally, or choose a "
		+ "High-Poly setting above.") \
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
# Everything the recorder needs to say what the panel was set to. Flat strings
# on purpose: the profiler turns any CHANGE into a timestamped event by
# comparing values, so a nested structure would report as one opaque diff.
# What the user changed, into the crash trail. The profiler already turns state
# changes into timeline events, but only while a recording is running — and the
# crash that prompted all this happened with nothing recording, so the trail
# said nothing about which switch had just been thrown. This runs always.
var _crumb_state := {}


func _crumb_state_change() -> void:
	var now := _perf_state()
	if _crumb_state.is_empty():
		_crumb_state = now
		HighpolyProfiler.crumb("panel", _describe_state(now))
		return
	var diff: Array = []
	for k in now.keys():
		if _crumb_state.get(k) != now[k]:
			diff.append("%s %s->%s" % [k, str(_crumb_state.get(k)), str(now[k])])
	if diff.is_empty():
		return
	_crumb_state = now
	HighpolyProfiler.crumb("panel", " ".join(PackedStringArray(diff)))


func _describe_state(st: Dictionary) -> String:
	var parts: Array = []
	for k in st.keys():
		parts.append("%s=%s" % [k, str(st[k])])
	return " ".join(PackedStringArray(parts))


func _perf_state() -> Dictionary:
	var r := EditorInterface.get_edited_scene_root()
	var chip := func(b: Button) -> String:
		if b == null: return "-"
		return "on" if b.button_pressed else "off"
	return {
		"scene": (String(r.name) if r != null else "(none)"),
		"map": (mapctx.map_of(r) if (mapctx != null and r != null) else ""),
		"mode": (mode_btn.get_selected_id() if mode_btn != null else -1),
		"map_context": chip.call(mapctx_on),
		"objects": chip.call(mapctx_objects),
		"backdrop": chip.call(mapctx_backdrop),
		"water": chip.call(mapctx_water),
		"fx": chip.call(mapctx_fx),
		"lighting": chip.call(mapctx_light),
		"contact_shading": chip.call(mapctx_gi),
		"shadows": chip.call(mapctx_shadows),
		"map_lights": chip.call(mapctx_maplights),
	}

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
	_gm_key = ""
	_gm_heal_off = ""
	_lighting_subs_enabled(false)   # the lighting sub-toggles go unavailable
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
	# The terrain-blend GLOBAL shader parameters, registered before any prop
	# material can compile against them. Session-only (RenderingServer, not
	# ProjectSettings), so nothing is written into the user's project; the map
	# context sets their values per apply. Re-registering errors, so guard on
	# the existing list.
	# THE SAMPLER IS NEVER NULL. Registering it with a null default and setting
	# the real colour map later looks harmless and is not: a terrain-blend
	# material (a kerb apron) can be built and DRAWN before any map sets the
	# global - during a cold build, or on a map with no colour map at all -
	# and sampling an unset global sampler took the editor down with an
	# access violation rather than an error. A 1x1 white stand-in means the
	# worst case is a kerb drawn white for a moment.
	# AND IT IS SET EVERY TIME, not only when it is first added.
	#
	# The RenderingServer keeps the sampler's RID, not a reference to the
	# texture behind it. white_texture() holds that texture in a script static,
	# and a script static dies with the script - so every addon reload (the
	# editor does one after its import scan, and disable/enable does another)
	# frees the texture while the global goes on pointing at where it was. The
	# guard below used to skip the set on that second pass, because the global
	# still EXISTED, so the dangling RID survived the reload and the first
	# terrain-blend material to draw sampled freed memory.
	#
	# That is the access violation three seconds into a build: no GDScript
	# backtrace and no engine error, because the fault is on the render thread
	# sampling a texture that is not there any more.
	#
	# Adding is still conditional - re-adding an existing global is an error -
	# but the VALUE is written unconditionally, which costs nothing and leaves
	# no path where the global outlives the texture it names.
	var sglobals := RenderingServer.global_shader_parameter_get_list()
	if not sglobals.has("bf6_ground_col"):
		RenderingServer.global_shader_parameter_add("bf6_ground_col",
			RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D,
			MapContextScript.white_texture())
	else:
		RenderingServer.global_shader_parameter_set("bf6_ground_col",
			MapContextScript.white_texture())
	if not sglobals.has("bf6_ground_rect"):
		RenderingServer.global_shader_parameter_add("bf6_ground_rect",
			RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0))
	# A SECOND REFERENCE, on the plugin node, so the texture cannot be freed
	# while this plugin is loaded even if the script static is replaced.
	_ground_white = MapContextScript.white_texture()
	dock = VBoxContainer.new()
	dock.name = "HighPolyContent"   # tab title comes from the scroll wrapper

	# ---- is Battlefield 6 here? --------------------------------------------
	# First thing built and first thing seen, because it is the precondition for
	# everything below it.
	_build_bf6_gate()

	# plugin self-update: hidden unless the registry advertises a newer version
	#
	# EXEMPT FROM THE BF6 GATE, both update rows. The gate exists so nothing
	# tries to read a game that is not there - but updating the plugin reads
	# GitHub and the staging lane, not the install. Gated, it locked out the
	# one user who most needs an update: someone whose install is not being
	# DETECTED yet, waiting on exactly the autodetect fix an update carries.
	update_btn = Button.new()
	update_btn.visible = false
	update_btn.pressed.connect(_do_plugin_update)
	var up_row := _centred(update_btn)
	up_row.set_meta("bf6_gate_exempt", true)
	dock.add_child(up_row)

	banner = Label.new()
	banner.visible = false
	banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	dock.add_child(banner)

	# ---- the one download bar, shown in place of "Check for updates" ----
	# One bar, not a stack: only one transfer runs at a time now, so a stack
	# could only ever show one moving row and several idle ones.
	jobs = _take_service("jobs")
	if jobs == null:
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

	check_btn = Button.new()
	check_btn.text = "Check for updates"
	check_btn.tooltip_text = "Applies a plugin update without restarting the editor: staged updates are copied in first, then any plugin script that changed on disk is reloaded in place. Press it when you are told a fix is ready; it refuses while something is building, so it is always safe to press."
	check_btn.pressed.connect(_check_updates_now)
	var ck_row := _centred(check_btn)
	ck_row.set_meta("bf6_gate_exempt", true)   # see update_btn: updates must
	dock.add_child(ck_row)                     # work with no install detected

	dock.add_child(job_row)      # takes the button's place while anything downloads

	# ---- what the read of the install is actually doing ----------------------
	#
	# The first read of a map is about a minute and a half: mounting 144 archives,
	# indexing 223k partition guids, walking 268k instances for the placements,
	# then decoding the ground. All of that used to be one status line that said
	# "reading the ground…" and then sat still, because the stages that take the
	# longest are exactly the ones with no fraction to report. A line that does
	# not move is indistinguishable from a crash, and the reasonable thing to do
	# about a crashed editor is kill it.
	#
	# So: the whole stage list up front, every one of them timed, and the elapsed
	# clock ticking twice a second whether or not the worker has anything new to
	# say. Being able to see that "reading placements" has been running for 40
	# seconds and has found 21,000 things is the difference between waiting and
	# giving up.
	read_panel = VBoxContainer.new()
	read_panel.visible = false
	read_title = Label.new()
	read_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	read_title.add_theme_font_size_override("font_size", Theme_.fs(12))
	read_panel.add_child(read_title)
	read_list = Label.new()
	read_list.add_theme_font_size_override("font_size", Theme_.fs(11))
	read_list.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	read_panel.add_child(read_list)
	read_note = Label.new()
	read_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	read_note.add_theme_font_size_override("font_size", Theme_.fs(11))
	read_note.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	read_panel.add_child(read_note)
	dock.add_child(read_panel)

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
		# MERGING RIDES THIS SLIDER. It is not a separate distance: beyond half
		# of whatever range was chosen, blocks of scenery draw as one merged
		# mesh instead of thousands of pieces. Fed the slider VALUE, not _rad -
		# the top notch sets _rad to 1e9 and half of that would merge nothing.
		mapctx.set_merge_from_range(v)
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
	mode_btn.tooltip_text = "Low-Poly (what you export): only what the SDK ships.

Low-Poly + the real level around it: your own pieces stay exactly as you export them, but the real level is brought in around them, untextured so it stays light: ground, water, skyline, lighting and the level's own objects.

High-Poly: your pieces are swapped for the real game models too, in clay or with their real textures.

All of it is read from your own Battlefield 6 installation."
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

	# BUILD THE OBJECT LIBRARY'S ICONS ON PURPOSE, RATHER THAN BY AMBUSH.
	#
	# They USED to be rendered by a 2-second timer, for whatever the library was
	# showing at the time. Each one assembles the object out of the install and
	# spends a SubViewport frame on it, so what a user experienced was the editor
	# hitching every couple of seconds, indefinitely, with nothing on screen to
	# say what was happening or when it would stop - and adding this button did
	# not stop it, it just put a second copy of the work somewhere visible.
	#
	# The timer now only SERVES icons, from memory or from the on-disk PNG. This
	# button is the only thing that renders one. Anything never built keeps the
	# SDK's stock icon, which is the honest answer for a picture that does not
	# exist yet.
	previews_btn = Button.new()
	previews_btn.text = "Build object previews"
	previews_btn.tooltip_text = "Renders an icon for every object in the library, with a progress bar. This is the only thing that renders them: nothing is drawn in the background while you work, so anything not built yet keeps the SDK's own icon. The icons are cached to disk and survive restarts, so a second press only covers what is new."
	previews_btn.pressed.connect(_build_previews)
	host.add_child(previews_btn)

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
	# Collisions starts off, so these start unavailable, the same way
	# "Isolate selected" does. _collision_changed() drives them from here on.
	col_pick.disabled = true
	col_alpha.editable = false

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

	# PROP LIGHTING: the fixtures a placed prop brought in from the game, and the
	# glow on its own bulb. Both come from the level - the lights are the ones the
	# prefab carries and the glow is its emissive sheet - and this only decides
	# whether they are switched on. Off, a lamp is a lamp that is not turned on,
	# which is the honest default while laying out geometry.
	prop_light_on = Theme_.chip("Prop Lighting")
	prop_light_on.tooltip_text = "Switches on the lights a placed prop carries in the game, and makes its bulbs, screens and lit signs glow. Both come from the level's own data. Preview only: nothing is saved into your map or exported."
	prop_light_on.button_pressed = false
	prop_light_on.toggled.connect(func(v: bool):
		if _locked(prop_light_on): return
		_set_prop_lighting(v))
	# UNDER DETAIL MODE, not with the map-context layers.
	#
	# It reads as a map-context switch because it was next to them, but it is not
	# one: every other chip in that row decides whether a LAYER OF THE MAP exists
	# - the ground, the skyline, the sea, the level's own props. This one decides
	# how the pieces YOU placed are lit, which is the same question Detail Mode
	# answers for how they are modelled and textured. It works with no map
	# context at all.
	_detail_chips.add_child(prop_light_on)

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
	mapctx_water.tooltip_text = "The rivers, harbours and sea the real level has, at the real height, so you can see what your build sits above. Rivers and lakes that live inside the terrain data are built as real surfaces with their own water level. Speed of the ripples follows the water setting in Configure Shaders, where zero holds it still. Some maps ship no water body at all, and a few (Battery, Contaminated) build their sea as ordinary scenery instead: the Backdrops layer draws those."
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

	# ROADS, SEPARATED FROM THE GROUND THEY SIT ON.
	#
	# They came in with Extended Terrain because a map without them is bare dirt
	# where the street network should be. That reasoning holds for looking at the
	# map and not for building on it: laying your own paths and arrays over the
	# ground means wanting the ground and not the streets painted on it, and the
	# only way to get that was to lose the terrain too.
	#
	# Starts unchecked: the point of the chip is bare ground, so having to switch
	# the streets off every time you switch the ground on would defeat it.
	# NO CHIP FOR ROADS AND PATHS. The decals are not optional dressing - they
	# are what the level paints onto whatever surface is under them, terrain or
	# prop, so they arrive with Extended Terrain and are re-projected when the
	# objects layer builds. mapctx_roads stays null and every reference to it
	# is already null-guarded.
	#
	# set_roads_shown() is kept: it is how the Roads node would be hidden again
	# if bare ground is ever wanted back, which is what this chip used to give.

	mapctx_grass = Theme_.chip("Grass")
	mapctx_grass.set_pressed_no_signal(false)
	mapctx_grass.tooltip_text = "Ground clutter — grass tufts, pebbles and debris from the level's own scatter catalogue, placed around your camera as you move. Off by default because it costs instances. How far it grows follows the Range slider (about a third of the scenery distance)."
	mapctx_grass.toggled.connect(func(v: bool):
		if _locked(mapctx_grass): return
		mapctx.set_grass(v)
		# Grass draws on the extended terrain, so with no ground built the chip
		# records the wish and the next terrain build honours it - say which.
		var r0 := EditorInterface.get_edited_scene_root()
		lbl.text = ("Grass " + ("on" if v else "off")) \
			if mapctx.has_terrain(r0) or not v \
			else "Grass will grow when Extended Terrain is on"
		_save_mapctx_state())
	mc_chips.add_child(mapctx_grass)

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
		#
		if v and mapctx.game_source != null \
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
	mapctx_variant.tooltip_text = "Rebuilds one game mode out of real Portal objects - capture points, spawns, combat areas and their volumes - under a node named for the mode. Switching modes hides the last one rather than deleting it, so anything you edited is still there when you switch back."
	mapctx_variant.item_selected.connect(func(_i):
		if _locked(mapctx_variant): return
		var _r := EditorInterface.get_edited_scene_root()
		var _map: String = mapctx.map_of(_r)
		# the dropdown shows the name people use; everything below runs on the
		# data key, because the layer gating matches its string literally
		var _mode := HighpolyGamemode.key_for(_map, _r,
			mapctx_variant.get_item_text(mapctx_variant.selected))
		_gm_key = _mode
		_gm_heal_off = ""
		lbl.text = HighpolyGamemode.apply(_r, _map, _mode, mapctx) \
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

	# NO GROUND-PHOTO CHIP. The SDK ships that feature (3D toolbar ->
	# Download/Apply Texture) and saves it into the user's scene, so it is
	# theirs. We stopped projecting a second one; while Extended Terrain is on
	# we hide theirs instead, because our terrain already carries the same
	# photo inside its shader. See highpoly_mapcontext._set_sdk_decal_shown.

	mapctx_fx = Theme_.chip("FX")
	mapctx_fx.tooltip_text = "Adds the fires, smoke columns and sparks the real level has, in the spots it has them. That includes the big distant smoke and haze cards near the skyline, which are effects rather than scenery. They are off by default, because they are hundreds of metres across and sit in front of the surroundings."
	mapctx_fx.toggled.connect(func(v: bool):
		if _locked(mapctx_fx): return
		var _r := EditorInterface.get_edited_scene_root()
		# Same as the map lights: the build skips mining FX emitters when this
		# layer is off, so switching it on is where they get mined - on a
		# worker, or the first press freezes the editor for the whole mine
		# with nothing on screen saying why (task #75).
		if v and mapctx != null:
			mapctx.want_fx = true
			await _ensure_mapdata_async(mapctx.game_source, {"fx": true})
			mapctx.ensure_section("fx")
		# the level's flipbook cards are drawn as props, so they follow this
		# switch too rather than arriving unbidden with the map objects
		mapctx.set_fx_cards_shown(_r, v)
		lbl.text = await HighpolyFx.apply(_r, mapctx.map_of(_r), v, _lane(FX_JOB),
			mapctx.game_source)
		_save_mapctx_state())
	mc_chips.add_child(mapctx_fx)

	mapctx_light = Theme_.chip("Lighting")
	mapctx_light.tooltip_text = LIGHTING_TIP
	mapctx_light.toggled.connect(func(v: bool):
		if _locked(mapctx_light): return
		_lighting_subs_enabled(v)
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
	mapctx_gi.disabled = true
	mapctx_gi.tooltip_text = "Darkens the creases where surfaces meet: under vehicles, inside doorways, along kerbs. This is the same contact shading the game uses, at the radius the map itself specifies. Costs some frame rate; switch it off if the view gets choppy."
	mapctx_gi.toggled.connect(func(v: bool):
		lbl.text = LightingScript.set_gi(EditorInterface.get_edited_scene_root(), v)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_gi)

	mapctx_shadows = Theme_.chip("Shadows")
	mapctx_shadows.button_pressed = true
	mapctx_shadows.disabled = true
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
	var fill_lbl := Label.new(); fill_lbl.text = "Interior light"
	mapctx_fill_row.add_child(fill_lbl)
	mapctx_fill = HSlider.new()
	mapctx_fill.editable = false        # Lighting starts off; greyed, not hidden
	mapctx_fill.min_value = 0; mapctx_fill.max_value = 60
	mapctx_fill.step = 1; mapctx_fill.value = int(round(LightingScript.interior_fill * 100.0))
	# An HSlider's minimum width is ZERO, and this row lives in an
	# HFlowContainer, which sizes children to their minimum. SIZE_EXPAND_FILL
	# means nothing there, so the bar collapsed to no width at all: the label and
	# the "22%" rendered, the draggable part did not exist. Give it a real width.
	mapctx_fill.custom_minimum_size = Vector2(150, 0)
	mapctx_fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_fill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mapctx_fill.tooltip_text = "Lifts the darkest areas, such as inside buildings, under bridges and the shadowed side of a wall, so you can see what you are working on. At zero the lighting is strictly what the sky reaches, which is the calibrated match to the real game and leaves interiors black. Preview only: it changes nothing about your map."
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

	# Ground photo: how strongly the game's own terrain colour raster steers
	# the extended ground. It is real game data - the engine modulates every
	# terrain material by it - but on a dense city map it reads like a
	# satellite image laid over the ground, and how much of that anyone wants
	# is taste. A user called Aftermath's ground "a google earth image
	# overlay", and they were describing this term at its shipped 75%. Live:
	# the shader reads a uniform, so dragging it needs no rebuild.
	mapctx_photo_row = HBoxContainer.new()
	var ph_lbl := Label.new()
	ph_lbl.text = "Ground photo"
	mapctx_photo_row.add_child(ph_lbl)
	mapctx_photo = HSlider.new()
	mapctx_photo.min_value = 0
	mapctx_photo.max_value = 100
	mapctx_photo.step = 1
	mapctx_photo.value = int(round(MapContextScript.colormap_strength * 100.0))
	mapctx_photo.custom_minimum_size = Vector2(150, 0)
	mapctx_photo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mapctx_photo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mapctx_photo.tooltip_text = "How much aerial-photo detail the ground shows. At 0% the ground keeps only the map's regional colours - city blocks grey, parks green, seabed dark - with no photo detail; at 100% it is the game's full ground raster, which on city maps reads like satellite imagery. It also sets how strongly the raster tints the textured layers."
	mapctx_photo_row.add_child(mapctx_photo)
	mapctx_photo_val = Label.new()
	mapctx_photo_val.text = "%d%%" % int(mapctx_photo.value)
	mapctx_photo_row.add_child(mapctx_photo_val)
	mapctx_photo.value_changed.connect(func(v: float):
		mapctx_photo_val.text = "%d%%" % int(v)
		if mapctx != null:
			lbl.text = mapctx.set_colormap_strength(v / 100.0)
		_save_mapctx_state())
	mc_sub.add_child(mapctx_photo_row)

	# (A pair of sun-position sliders lived here while the azimuth convention was
	# being worked out against the running game. They did their job — SunRotationX
	# turned out to be a compass bearing, see sun_dir() — and came straight back
	# out. The sun is read from each level's own data with nothing to adjust.)

	mapctx_maplights = Theme_.chip("Map lights")
	mapctx_maplights.button_pressed = false
	mapctx_maplights.disabled = true
	mapctx_maplights.tooltip_text = "The street lights, signs and indoor lights the real level has, several thousand of them on some maps. Only the ones near your camera light up. Costs frame rate."
	mapctx_maplights.toggled.connect(func(v: bool):
		var _r := EditorInterface.get_edited_scene_root()
		# The build only mines the light entities when this layer is on, so
		# switching it on is the moment to make sure they exist. set_map_lights
		# reads the file map_data writes and never asks map_data for it, so
		# without this the layer would come on to nothing.
		# ON A WORKER FIRST. ensure_section is a synchronous map_data ask, and
		# a first mine of a section is main-thread freeze territory (task #75:
		# "64 s of a 74 s terrain-only apply" in a user's log). After the worker
		# has mined it, ensure_section is a dictionary lookup.
		if v and mapctx != null:
			mapctx.want_lights = true
			await _ensure_mapdata_async(mapctx.game_source, {"lights": true})
			mapctx.ensure_section("lights")
		lbl.text = await LightingScript.set_map_lights(_r,
				v and mapctx_light.button_pressed, mapctx.map_of(_r),
				_lane(LIGHTS_JOB))
		_save_mapctx_state())
	mc_sub.add_child(mapctx_maplights)


	# Optimize placed objects: distance-cull the props the USER places (their custom
	# map content — not the backdrop) so a densely-built map stays fast. Near props
	# stay full-quality and fully selectable/editable; distant ones stop drawing.
	# Follows the Range slider. Editor-only — nothing hidden, export untouched.
	# Not shown: this is just what the Range slider means for the pieces you
	# placed yourself, so it is always on and rides the slider like everything
	# else. Kept unshown because the overlay code reads its state.
	mapctx_optimize = Theme_.chip("Hide far pieces")
	mapctx_optimize.button_pressed = true
	mapctx_optimize.tooltip_text = "Stops drawing the pieces you placed yourself once they are far from the camera, so a busy map keeps running smoothly. They are still there, still selectable, and nothing is left out when you export."
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
	# Roads and Grass ride the extended terrain, so they are gated with it.
	# Roads had the _locked() snap-back in its handler from day one but was
	# never REGISTERED here, so on the Low-Poly rung it looked pressable and
	# then did nothing a user could see.
	_gate(mapctx_roads, "The roads and paths")
	_gate(mapctx_grass, "The ground clutter")
	_gate(mapctx_objects, "The level's own objects")
	_gate(mapctx_fx, "The level's effects")
	_gate(mapctx_light, "The game lighting")
	_gate(mapctx_variant, "The game mode layouts")

	var shader_btn := Button.new()
	shader_btn.text = "Configure Shaders…"
	shader_btn.tooltip_text = "Settings for the moving parts: rippling water, drifting smoke and swaying grass."
	shader_btn.pressed.connect(_open_shader_dialog)
	host.add_child(_centred(shader_btn))

	# STORAGE, described as what it actually is.
	#
	# This section used to talk about downloads, because that is what it used to
	# be. Nothing here arrives from anywhere now: every byte is WORK ALREADY DONE
	# on your own Battlefield 6 install, kept so the next open does not repeat it.
	# The wording matters beyond tidiness — the reason the plugin reads the game
	# directly is so that it never ships anyone else's assets, and a panel that
	# says "downloaded" describes a plugin we deliberately stopped being.
	host = _section("Storage",
		"Work the plugin has already done on your Battlefield 6 install, kept so the next time you open a map takes seconds instead of minutes. None of it is your map, and none of it came from anywhere but your own game, so clearing any of it is always safe: it is simply worked out again.")

	storage_lbl = Label.new()
	storage_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	storage_lbl.add_theme_font_size_override("font_size", Theme_.fs(12))
	storage_lbl.text = "Measuring disk usage…"
	host.add_child(storage_lbl)

	var where := Label.new()
	where.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	where.add_theme_font_size_override("font_size", Theme_.fs(11))
	where.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	where.text = "Kept in Godot's own app-data folder, outside your project, so " \
		+ "none of it is part of your map or your export. It holds where every " \
		+ "object in a level stands, the ground and its surface, and the meshes " \
		+ "and textures already worked out. Clearing it costs you the wait to " \
		+ "work them out again, nothing else."
	host.add_child(where)

	var files_btn := Button.new()
	files_btn.text = "Show me these files"
	files_btn.tooltip_text = "Opens the folder in your file browser, so you can " \
		+ "see exactly what is there. Nothing in it is part of your map."
	files_btn.pressed.connect(func():
		var dir := ProjectSettings.globalize_path("user://")
		DirAccess.make_dir_recursive_absolute(dir)   # first run: may not exist yet
		OS.shell_show_in_file_manager(dir)
		lbl.text = "Opened %s" % dir)
	host.add_child(_centred(files_btn))

	# Settings that used to live in this row and no longer need to be decisions:
	#
	#   "Faster loading" only ever chose whether to KEEP the work, and switching
	#   it off freed nothing (it stopped future caching), so it was a cost with
	#   no benefit attached to a switch. Always on now.
	#   The shader preferences it happened to load on the way past are still
	#   loaded, below, because those are real settings behind their own dialog.
	# THROUGH THE PRELOAD CONST, never through the class_name.
	#
	# Assigning a static var via HighpolyMapContext.x fails at runtime once that
	# script has been replaced in place by a live reload:
	#   "Invalid assignment of property 'mesh_cache_enabled' ... on a base object
	#    of type 'GDScript'"
	# The class_name global re-registers to a script object this already-compiled
	# file cannot index statics on; the preloaded const still points at the object
	# CACHE_MODE_REPLACE updated, which is the whole basis of the live reload.
	# Reads of CONSTANTS are fine either way, because those resolve at parse time.
	MapContextScript.mesh_cache_enabled = true
	var _es := EditorInterface.get_editor_settings()
	var _sp: Variant = _es.get_project_metadata("highpoly_mapctx", "_shaders", {})
	if _sp is Dictionary:
		for k in (_sp as Dictionary):
			HighpolyMapContext.shader_prefs[k] = _sp[k]

	var storage_chips := _chip_row(host)

	# --- Record flight path (developer tool) --------------------------------
	# Records the editor camera at 20 Hz so a benchmark can fly the SAME route
	# afterwards. Every rendering measurement before this used a static camera,
	# which cannot answer "did that change make flying smoother" — the only
	# question that actually matters. Recording the route you fly captures the
	# places that are actually slow, rather than a synthetic orbit.
	var flight_chk := Theme_.chip("Record flight path")
	flight_chk.tooltip_text = "Developer tool. Records where you fly so the same route can be replayed and timed. Switch it on, fly the part of the map that feels slow, switch it off — it saves a file and tells you where it went."
	flight_chk.toggled.connect(func(v: bool):
		if v:
			var mapn: String = str(mapctx._map) if mapctx != null else ""
			if FlightPath.start(self, mapn if mapn != "" else "unknown"):
				lbl.text = "Recording. Fly the parts that feel slow, then switch this off."
			else:
				flight_chk.set_pressed_no_signal(false)
				lbl.text = "Could not start recording: no 3D viewport camera found."
		else:
			var n: int = FlightPath.sample_count()
			var p: String = FlightPath.stop()
			lbl.text = ("Flight path saved: %d samples at %s" % [n, p]) if p != "" \
					else "Nothing recorded — the camera never moved.")
	storage_chips.add_child(flight_chk)

	# The game folder moved to the TOP of the panel. It is the precondition
	# for everything the plugin does, not a storage setting, and two places to
	# set one path is one place to set it wrong. See _build_bf6_gate.

	var purge_row := HBoxContainer.new(); host.add_child(purge_row)
	purge_maps = OptionButton.new()
	purge_maps.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	purge_maps.tooltip_text = "Maps with a local cache built from your game install. Deleting one frees its space; anything it shares with another cached map is kept."
	purge_row.add_child(purge_maps)
	purge_btn = Button.new()
	purge_btn.text = "Delete"
	purge_btn.tooltip_text = "Frees this map's cache on your PC. Safe to do, because it is rebuilt from your game install the next time you open that map — the rebuild takes a minute or two, not a download."
	purge_btn.pressed.connect(_purge_selected)
	purge_row.add_child(purge_btn)

	# The fallback when per-map deleting has left something behind (models
	# arrive by paths no single map owns), or when you just want to start over.
	var reset_btn := Button.new()
	reset_btn.text = "Reset everything"
	reset_btn.tooltip_text = "Deletes every local cache: all maps, all scenery and every rendered icon. Also puts this panel back to its defaults and closes the reader, so the next map open starts cold. Safe to do, because everything is rebuilt from your game install on demand."
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
	mark_note = LineEdit.new()
	mark_note.placeholder_text = "What is wrong here? e.g. wall missing"
	mark_note.tooltip_text = "Describe the problem, then press Enter to pin it. A confirmed pick (bright red, from Pick mode) wins: the note lands on that exact object and carries its identity into the saved log. Otherwise it pins to the selected object, or with nothing selected it drops in front of the camera. The note floats in the viewport, so a screenshot carries it."
	host.add_child(mark_note)
	# ENTER PINS THE NOTE TO WHAT IS SELECTED.
	#
	# Reviewing a build is a loop of "that one is wrong" -> say why -> move on,
	# and having to aim a sphere at the thing you have already selected is the
	# slow part of it. The note lands above the object's own bounds, so it reads
	# as belonging to that prop rather than floating near it.
	#
	# With nothing selected it behaves exactly like Drop marker, which is the
	# useful fallback rather than an error: the complaint is sometimes about a
	# place rather than an object.
	mark_note.text_submitted.connect(func(_t: String):
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		var note: String = mark_note.text.strip_edges()
		if note == "":
			return
		var sel := EditorInterface.get_selection().get_selected_nodes()
		var target: Node3D = null
		for n in sel:
			if n is Node3D:
				target = n as Node3D
				break
		var pos := HighpolyMarkers.camera_point()
		var what := "in front of the camera"
		var target_desc := ""
		# A CONFIRMED PICK BEATS THE SELECTION. Props draw as MultiMesh
		# batches, so a selection can only name the whole group, and a note
		# pinned to one landed at the centre of every look-alike. The pick
		# holds the ONE clicked instance, the clicked point on it, and its
		# identity in the game files, so the note goes exactly there and the
		# saved log says exactly what it was about.
		if HighpolyDiagnose.is_confirmed():
			pos = HighpolyDiagnose.focus_point() + Vector3(0, 0.3, 0)
			what = "on the picked object"
			target_desc = HighpolyDiagnose.provenance(
				mapctx.game_source if mapctx != null else null)
		elif target != null:
			if target is MultiMeshInstance3D \
					and (target as MultiMeshInstance3D).multimesh != null:
				# The whole batch is selected. The honest anchor without a
				# pick is the instance nearest the camera aim - never the
				# group's centre, which sits in the middle of every look-alike
				# and on nothing at all.
				pos = _nearest_instance_point(target as MultiMeshInstance3D) \
					+ Vector3(0, 0.6, 0)
				what = "on the nearest %s instance" % target.name
			else:
				# Above the object's own bounds. An empty box (a node with no
				# geometry of its own) falls back to its origin plus a little,
				# which is still on the thing rather than metres away from it.
				var ab: AABB = LibScript._global_aabb(target)
				if ab.size.length() > 0.001:
					pos = ab.get_center() + Vector3(0, ab.size.y * 0.5 + 0.6, 0)
				else:
					pos = target.global_position + Vector3(0, 0.6, 0)
				what = "on %s" % target.name
			target_desc = str(r.get_path_to(target))
		var m := HighpolyMarkers.add(r, note, pos)
		if m == null:
			lbl.text = "Could not place the note."
			return
		if target_desc != "":
			# Which object was being complained about, for the saved log.
			m.set_meta("hp_note_target", target_desc)
		mark_note.text = ""
		lbl.text = "Note %s: %s" % [what, note])
	var mark_row := HBoxContainer.new()
	mark_row.alignment = BoxContainer.ALIGNMENT_CENTER
	host.add_child(mark_row)
	var mark_add := Button.new()
	mark_add.text = "Drop marker"
	mark_add.tooltip_text = "Places a sphere with your note attached. With Pick mode focused on an object, the marker lands exactly on the clicked spot; otherwise it appears ahead of the camera for you to drag onto the problem. Saving the log records its position and the meshes the map package expects there."
	mark_add.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		var note: String = mark_note.text.strip_edges()
		if note == "":
			lbl.text = "Type what is wrong first, then drop the marker."
			return
		# THE PICK IS THE ANCHOR. Props draw as MultiMesh batches, so the
		# editor's selection can only name the whole group - a note dropped
		# from a selection landed in the middle of every look-alike. Pick
		# mode already resolves the ONE clicked instance and the clicked
		# point on it; when a focus is live, the marker goes exactly there.
		var pos := HighpolyMarkers.camera_point()
		var pp := HighpolyDiagnose.focus_point()
		if pp.is_finite():
			pos = pp
		var m := HighpolyMarkers.add(r, note, pos)
		if m == null:
			lbl.text = "Could not place the marker."
			return
		if pp.is_finite():
			# The picked object's identity rides with the note, so the saved
			# log names the exact mesh/scope/state rather than a position.
			var pv: String = HighpolyDiagnose.provenance(
				mapctx.game_source if mapctx != null else null)
			if pv != "":
				m.set_meta("hp_note_target", pv)
		mark_note.text = ""
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(m)
		lbl.text = "Marker placed: %s. Drag it onto the spot, then Save log file." % note)
	mark_row.add_child(mark_add)
	var mark_clear := Button.new()
	mark_clear.text = "Clear markers"
	# Clears the pick-mode tint as well. They were two buttons doing one thing -
	# "put the scene back the way it looked" - and having them apart meant
	# leaving a red prop behind after clearing the notes about it.
	mark_clear.tooltip_text = "Removes every marker and note this panel created, and clears the red pick-mode tint. Nothing else in the scene is touched: the tint is an overlay pass, never a material swap."
	mark_clear.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			return
		var tints: int = HighpolyDiagnose.clear()
		var marks: int = HighpolyMarkers.clear(r)
		lbl.text = "Removed %d marker(s), cleared %d tint(s)." % [marks, tints])
	mark_row.add_child(mark_clear)

	# ---- refresh just what you are pointing at ----
	#
	# The iteration loop this closes: drop a marker on a prop that looks wrong,
	# get the code that dresses it changed, press this. Re-dressing the whole map
	# works and takes seconds; re-dressing ONE prop is instant, and instant is
	# what makes it worth trying six variations of a leaf cutout instead of one.
	#
	# Deliberately marker-driven rather than selection-driven: what is selected
	# in the editor is usually the SDK proxy, while the thing that looks wrong is
	# the overlay geometry underneath it, and a marker names a PLACE - which is
	# all that is needed to find the meshes there.
	var mark_fix := Button.new()
	mark_fix.text = "Refresh marked props"
	mark_fix.tooltip_text = "Rebuilds the materials of the map-context meshes nearest your markers, using the currently loaded plugin code. If the plugin was just updated, press Check for updates first so the rebuild runs the new code."
	mark_fix.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		var gs = mapctx.game_source if mapctx != null else null
		if gs == null or not gs.has_method("invalidate_materials"):
			lbl.text = "Nothing is read from the install yet. Build the map context once."
			return
		var meshes := _marked_meshes(r)
		if meshes.is_empty():
			lbl.text = "No markers, or nothing of ours near them. Drop a marker on the prop first."
			return
		var st: Dictionary = gs.invalidate_materials(meshes)
		lbl.text = "Refreshed %d mesh(es) near %d marker(s) in %d ms" 			% [st["meshes"], HighpolyMarkers.list(r).size(), st["ms"]]
		Log.info("Marker refresh: %d mesh(es) found, %d re-dressed, %d surface(s)"
			% [meshes.size(), st["meshes"], st["surfaces"]]))
	mark_row.add_child(mark_fix)

	# ---- diagnose one object ----
	#
	# The note box above is reused: what you type there is what labels the
	# report, so tagging a prop and dropping a marker read the same way.
	#
	# There used to be a separate "Diagnose Selection" button beside this. It
	# asked for a second press to answer a question the first press had already
	# settled: by the time you have clicked an object in pick mode, the plugin is
	# holding the exact surface you asked about. Picking reports.
	var diag_row := HBoxContainer.new()
	host.add_child(diag_row)
	# ---- pick mode: click the original map objects ----
	#
	# The editor cannot select them. Everything we inject is owner-less so it
	# never saves into the user's .tscn, and the editor's picker only resolves a
	# click to a node the edited scene owns. Giving them owners to make them
	# clickable would write thousands of nodes of read-from-the-install geometry
	# into their scene file, which is the one thing this plugin must not do. So
	# while this is on, the plugin does its own ray/triangle pick instead and
	# consumes the click.
	#
	# Tab then drills into what was picked: batch -> one instance -> one surface.
	# That last rung is the point of the whole thing — a car's windows are not a
	# node and cannot be clicked apart from its body, they are a surface with
	# their own shader state, and a surface is the granularity at which glass,
	# liveries and cutouts actually go wrong.
	# A chip, like every other switch in this panel. It was the one CheckButton
	# left, which made the panel look like two different tools stitched together.
	diag_pick = Theme_.chip("Pick mode")
	diag_pick.tooltip_text = "Hover any object in the viewport to highlight it light red, including the original map geometry the editor itself cannot select. Tab drills in while hovering (whole batch, one instance, one part), Shift+Tab steps back out. Left click confirms the highlight bright red and writes what that object is made of into the log: which depot answered, whether the shader state had a record, what textures it bound, and whether its cutout was honoured. With a confirmed pick, type a note above and press Enter to pin it to exactly that spot. Clicking the same spot again drills in, Alt+click steps out, Escape releases the pick. Hide picked (or H) hides the highlighted object so you can reach what it blocks; Unhide brings everything back."
	diag_pick.toggled.connect(func(on: bool):
		_pick_last = Vector2(-1e9, -1e9)
		_hover_last = Vector2(-1e9, -1e9)
		if not on:
			HighpolyDiagnose.clear()
			lbl.text = "Pick mode off."
		else:
			lbl.text = HighpolyDiagnose.focus_label(
				mapctx.game_source if mapctx != null else null))
	diag_row.add_child(diag_pick)
	# ---- hide: get the picked object out of the way ----
	# A button rather than a mouse chord: the right button belongs to
	# freelook, so a right-click hide fought the camera and was removed.
	# H in the viewport does the same without a trip to the panel.
	var hide_btn := Button.new()
	hide_btn.text = "Hide picked"
	hide_btn.tooltip_text = "Hides the object Pick mode is highlighting (H in the viewport does the same), so you can reach what stands behind it. Your own placed objects are not touched; hide those from the scene tree. Unhide brings everything back."
	hide_btn.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		if not HighpolyDiagnose.has_focus():
			lbl.text = "Nothing is picked. Hover or click an object in Pick mode first."
			return
		lbl.text = HighpolyDiagnose.hide_focus(r))
	diag_row.add_child(hide_btn)
	# ---- object debug: isolate the picked thing and turn its knobs ----
	# The step past diagnosing: the report SAYS what the record binds, this
	# SHOWS it - the object alone, every part listed with its textures and
	# state key, and live controls (UV channel, albedo slot, cutout, tint,
	# roughness, emission) to dial in what looks right. "Copy report" exports
	# only the changed knobs against the object's identity, which is exactly
	# the shape a code fix starts from.
	var debug_btn := Button.new()
	debug_btn.text = "Debug"
	debug_btn.tooltip_text = "Opens the object debugger on the picked object: hides the rest of the map, rebuilds this one alone with every UV channel available, and lists everything the game binds to each part. Change the knobs until it looks right, then Copy report puts the recipe in the log and clipboard. Close puts the map back."
	debug_btn.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		if not HighpolyDiagnose.has_focus():
			lbl.text = "Pick an object first: turn Pick mode on, hover it and click."
			return
		if objdebug == null:
			objdebug = ObjDebugScript.new()
		Log.info("Debug pressed: focus %s" % str(HighpolyDiagnose.focus_info().get("mesh")))
		var err: String = objdebug.open(
			mapctx.game_source if mapctx != null else null, r,
			HighpolyDiagnose.focus_info())
		if err != "":
			Log.warn("Object Debug did not open: %s" % err)
		lbl.text = ("Object Debug open. The map is hidden around it; "
			+ "Close in the window brings everything back.") if err == "" else err)
	diag_row.add_child(debug_btn)
	# ---- unhide: bring back what pick mode hid ----
	# Right click / H on a highlighted object gets it out of the way of the
	# thing behind it; this is the way back. It restores everything at once
	# (metas on the nodes, so it also finds things hidden before a plugin
	# reload) and then says which layer chip is still keeping something off
	# screen, so "I unhid it and it did not come back" answers itself.
	var unhide_btn := Button.new()
	unhide_btn.text = "Unhide"
	unhide_btn.tooltip_text = "Brings back every object hidden through Pick mode (Hide picked or H hides the highlighted one so you can reach what it blocks). If a restored object still does not appear, its layer chip is off, and this says which one."
	unhide_btn.pressed.connect(func():
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "Open a level scene first."
			return
		var st: Dictionary = HighpolyDiagnose.unhide_all(r)
		var n: int = int(st["nodes"]) + int(st["insts"])
		if n == 0:
			lbl.text = "Nothing is hidden."
			return
		var msg := "Unhid %d object(s)." % n
		var gates: Array = st["gated"]
		if not gates.is_empty():
			var chips := PackedStringArray()
			for g in gates:
				var c := _layer_chip_name(str(g))
				if not chips.has(c):
					chips.append(c)
			msg += " Some are still off screen: switch %s back on to see them." \
				% ", ".join(chips)
		lbl.text = msg)
	diag_row.add_child(unhide_btn)


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
	# The frame-bucket timer rides this same button rather than getting a switch
	# of its own. It is off at every other moment, which is the point of it: the
	# call sites cost nothing measurable while it is off, and there is no second
	# control to explain or to leave switched on by accident. Its table goes into
	# the log, so "Save log file" already carries it.
	perf_btn.pressed.connect(func():
		if profiler == null: return
		if profiler.recording:
			HighpolyProfile.set_enabled(false)
			lbl.text = profiler.stop()
			if HighpolyProfile.has_data():
				Log.info(HighpolyProfile.report())
			perf_btn.text = "Record performance"
		else:
			HighpolyProfile.set_enabled(true)
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
	# THE STATUS LINE LIVES AT THE TOP. It is where every notification lands —
	# how many models are local, what just downloaded, what a toggle did, what
	# failed — and it sat underneath a screenful of controls, below the Log
	# section, where it had to be scrolled to. Only the version and the credits
	# belong at the bottom.
	lbl = Label.new()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# FIXED HEIGHT, two lines. This label's text changes constantly and ranges
	# from "Map lights off" to a full sentence about a failed download; letting
	# it size itself means every message of a different length reflows the entire
	# panel and everything below it hops. Two lines is enough for the long ones
	# and the height never changes, so nothing moves.
	lbl.max_lines_visible = 2
	lbl.custom_minimum_size.y = Theme_.fs(13) * 2.4
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	dock.add_child(lbl)
	dock.move_child(lbl, 0)
	# The gate outranks even the status line: it is the precondition for
	# everything, the status line included. And now that every control exists,
	# re-apply it — it was built first, when there was nothing yet to grey out.
	dock.move_child(bf6_row, 0)
	_apply_bf6_gate()

	var ver_lbl := Label.new()
	ver_lbl.text = "v%s  ·  TabbedScamper" % HighpolyUpdater.plugin_version()
	ver_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ver_lbl.tooltip_text = "Built by TabbedScamper. Frostbite format research by TabbedScamper."
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
	# Undo what a KILLED bench run left in the user's editor settings. The
	# flight zeroes both idle sleeps so it measures a cost rather than a cap,
	# and perfrun force-kills the editor on hang, crash or timeout - after
	# which the editor renders at full rate forever, including while it sits
	# behind a running game competing for the same GPU. Nothing said so.
	HighpolyFlightRun.restore_pending()
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

	# Adopted across a soft reopen when there is one to adopt, so the open game
	# source, the built cell index and the rendered icons all survive a change to
	# this panel. See _keep_service.
	profiler = _take_service("profiler")
	if profiler == null:
		profiler = ProfilerScript.new()
	profiler.name = "HighpolyProfiler"
	dock.add_child(profiler)
	previews = _take_service("previews")
	if previews == null:
		previews = PreviewsScript.new()
	dock.add_child(previews)
	mapctx = _take_service("mapctx")
	if mapctx == null:
		mapctx = MapContextScript.new()
	dock.add_child(mapctx)
	# the background props builder reports through the dock: live text in the
	# status label + a real progress bar (meshes built / total)
	mapctx.status_label = lbl
	mapctx.build_progress.connect(func(done: int, total: int):
		# same bar as the downloads: building the scenery is the last stage of
		# "getting the level in", and its label says which stage that is —
		# 3/3 after an archive download and unpack, 2/2 when the props came in
		# over ranged reads and there was no unpack stage at all. Without the
		# step, a finished download read as a finished layer and the build that
		# followed looked like the whole thing had started again.
		if done < total:
			jobs.set_activity(mapctx.build_job, done, total)
		else:
			jobs.clear_activity(mapctx.build_job))
	# the third stage: unpacking the archive between the download finishing and
	# the build starting. 31 s on Dumbo with no bar of any kind, which is why the
	# panel looked stuck after the download completed.
	mapctx.stage_progress.connect(func(label: String, done: int, total: int):
		_lane(label).call(done, total))
	# the skyline gets its own lane; jobs.set_activity is keyed, so it and the
	# scenery build show as separate bars instead of overwriting each other
	mapctx.backdrop_progress.connect(func(done: int, total: int):
		if done < total:
			jobs.set_activity("Building the skyline", done, total)
		else:
			jobs.clear_activity("Building the skyline"))
	# STORAGE WENT STALE. It was measured at startup and after a Check for
	# Updates, and nowhere else — so downloading a whole map left the panel still
	# reporting the kilobyte it had found before, which reads as the plugin
	# having downloaded nothing at all. Anything that lands bytes on disk now
	# schedules a re-measure.
	#
	# Debounced rather than immediate: the walk covers thousands of files, and a
	# map load ends several transfers within a second of each other. One scan
	# once it settles, not one per transfer.
	# No download_ended signal any more - nothing downloads. Storage still
	# changes when a build writes its geometry cache, and build_finished is
	# what says so.
	mapctx.build_finished.connect(func(_n: int): _storage_dirty())
	# THE ROAD DECALS GET THEIR OWN LANE. set_activity is keyed by label, so
	# this sits alongside the scenery and skyline lanes without any further
	# wiring; an empty phase closes it. Before this the pass reported through
	# the props lane, which had already finished by the time it ran.
	# ONE STABLE LABEL. set_activity is keyed BY LABEL, so putting the phase in
	# the label meant the close never matched the lanes it opened and each one
	# was left on screen forever at whatever it last reported - the stray bar
	# that appears once the objects have finished. The phase still reaches the
	# log and the breadcrumb, where it is not part of a key.
	mapctx.decal_progress.connect(func(phase: String, done: int, total: int):
		if phase == "":
			jobs.clear_activity("Laying the road decals")
		else:
			jobs.set_activity("Laying the road decals", done, total))
	mapctx.build_finished.connect(func(_b: int): _storage_dirty())
	mapctx.build_finished.connect(func(_built: int):
		jobs.clear_activity("Building the level's scenery")
		# sidecar-cached meshes load with the shader params they were SAVED
		# with — push the current Configure Shaders prefs over the fresh build
		var _sr := EditorInterface.get_edited_scene_root()
		if _sr != null: mapctx.apply_shader_prefs(_sr)
		# The icons are rendered from the same prop meshes the build just wrote,
		# so this is the moment they can stop being the SDK blockout.
		if previews: previews.rescan_context()
		# AND THE VARIANT ROW, which could not have been filled before now.
		#
		# It lists the layers the map's own placements carry, and it was only
		# ever refreshed on the objects TOGGLE - which fires before the build,
		# when the map data is still empty. So it found no layers, hid itself,
		# and nothing ever asked again: the dropdown never appeared even once
		# the props were on screen and their layers were known.
		_variant_row_update(mapctx_objects != null and mapctx_objects.button_pressed)
		_swap_placed_after_build())
	# the map build gets its own bar
	mapctx.job_queue = jobs        # map-context downloads take their turn
	mapctx_timer = Timer.new(); mapctx_timer.wait_time = 0.5
	mapctx_timer.timeout.connect(func():
		# INSTRUMENTED because the panel is reported to get slower the more has
		# been loaded, even with nothing downloading. Everything below runs twice
		# a second forever, and two of them scale with how much is in the scene:
		# mapctx.tick() walks every prop cell built so far (re-parsing each cell
		# key out of a string as it goes), and tick_lights walks every mined
		# fixture. Which one it is should come from a recording rather than from
		# whichever looks worst in the source.
		# HighpolyProfile is the microsecond half of the same question. The
		# HighpolyProfiler.span() calls below stay: they feed the session
		# recording, which is what tells you a phase got slower over an hour. But
		# span() takes MILLIseconds, so every stage under 1 ms in here reads as
		# zero and the tick total is the sum of a handful of zeros. The buckets
		# added around them measure in microseconds and are keyed by frame, so a
		# tick that lands badly once in twenty shows up as a hitch rather than
		# being averaged into nothing.
		# FIRST, before anything else in the tick can add to the delay it is
		# measuring. This timer is the only thing in the plugin that can see a
		# main-thread freeze: it is a 0.5 s Timer on the editor's main loop, so
		# if it fires four minutes late, the main thread was gone for four
		# minutes. That is the freeze a user reported as "it stalled hard on
		# terrain colours", and it left no trace in the log at all, because a
		# phase is only recorded once it finishes.
		HighpolyVitals.sample()
		HighpolyProfile.begin("panel heartbeat")
		var _tt := Time.get_ticks_msec()
		# The read's clock, ticked here rather than by the worker. The stages that
		# take longest report nothing at all while they run, so this is the only
		# thing that keeps the panel moving through them.
		if not _read_model.is_empty():
			HighpolyProfile.begin("panel: read progress refresh")
			_read_refresh()
			HighpolyProfile.end("panel: read progress refresh")
		# Safety net for the save guard. _apply_changes defers the restore, and a
		# deferred call is normally run the same frame, but if anything ever eats
		# it the scene would sit stocked with the preview off and no way to tell
		# why. Half a second late is invisible; never is not.
		if _stocked_for_save:
			_unstock_after_save()
		HighpolyProfile.begin("panel: state crumb")
		_crumb_state_change()
		HighpolyProfile.end("panel: state crumb")
		HighpolyProfile.begin("panel: scene change check")
		_check_scene_change()
		HighpolyProfile.end("panel: scene change check")
		HighpolyProfile.begin("panel: lighting guard")
		_lighting_guard()
		HighpolyProfile.end("panel: lighting guard")
		if mapctx:
			HighpolyProfile.begin("prop cell culling")
			var _t_ctx := Time.get_ticks_msec()
			mapctx.tick()
			HighpolyProfiler.span("panel tick: prop cell culling",
				Time.get_ticks_msec() - _t_ctx)
			HighpolyProfile.end("prop cell culling")
		# THE MODE REBUILDS ITSELF IF YOU DELETE IT. Selecting a mode leaves a
		# node in the scene; deleting that node is a normal thing to do and
		# should not leave the dropdown claiming a mode is shown. So: if a mode
		# is selected and no node in the tree remembers it, build it again.
		#
		# The test is the node's OWN marker, not a fixed name. It used to look
		# for a node called "_GAMEMODE", which no longer exists at all under the
		# per-mode nodes this builds - so that test would have been true on
		# every tick and re-applied the mode several times a second.
		if mapctx_variant != null and mapctx_variant.selected > 0 \
				and mapctx_variant_row != null and mapctx_variant_row.visible:
			HighpolyProfile.begin("gamemode marker heal")
			var _gr := EditorInterface.get_edited_scene_root()
			if _gr != null and _gm_key != "" and _gm_heal_off != _gm_key \
					and not HighpolyGamemode.built(_gr).has(_gm_key):
				var _gmap: String = mapctx.map_of(_gr)
				lbl.text = HighpolyGamemode.apply(_gr, _gmap, _gm_key, mapctx)
				mapctx.set_variant_layers(_gm_key)
				# Still nothing? Then the dropdown is showing one of the map's
				# own layer names, which gates props but has no mined objects to
				# build. Stop, or this retries forever at tick rate.
				if not HighpolyGamemode.built(_gr).has(_gm_key):
					_gm_heal_off = _gm_key
			HighpolyProfile.end("gamemode marker heal")
		# map-lights culling: only lights near the editor camera render
		var _vp3 := EditorInterface.get_editor_viewport_3d(0)
		var _cam3 := _vp3.get_camera_3d() if _vp3 else null
		if _cam3:
			var _r3 := EditorInterface.get_edited_scene_root()
			HighpolyProfile.begin("map light culling")
			var _t_lt := Time.get_ticks_msec()
			LightingScript.tick_lights(_r3, _cam3.global_position)
			HighpolyProfiler.span("panel tick: map-light culling",
				Time.get_ticks_msec() - _t_lt)
			HighpolyProfile.end("map light culling")
			# A placed fixture's lights hang off a scene-level holder so they do
			# not inflate the prop's selection box, so something has to carry
			# them when the builder moves the prop. A few matrix multiplies per
			# tracked fixture, capped at 8 per prop, and dead rows drop out.
			HighpolyProfile.begin("prop light follow")
			LightingScript.refresh_prop_lights()
			HighpolyProfile.end("prop light follow")
			# Local lighting zones follow the camera the way the game follows the
			# player: entering an interior blends its exposure in, leaving blends
			# it out. Costs an AABB test per zone (59 across the whole fleet, and
			# most maps have none), so it is not worth gating.
			if mapctx_light != null and mapctx_light.button_pressed:
				HighpolyProfile.begin("lighting zone blend")
				LightingScript.tick_zones(_r3, _cam3.global_position,
						LightingScript.base_ev())
				HighpolyProfile.end("lighting zone blend")
			HighpolyProfile.begin("collision outline tidy")
			ShapeViz.tick()      # tidy up any outline the editor rebuilt
			HighpolyProfile.end("collision outline tidy")
		# a CANCELLED scenery build (Extended Terrain switched off, or a new
		# apply superseding it) ends without a build_finished — without this the
		# bar would sit there at whatever percent it had reached
		# keyed clear: active_label() may now be showing the OTHER job, so
		# gating on it would leave this lane stuck at whatever percent it reached
		# mapctx.build_job, NOT a literal: the label carries the pipeline step
		# ("3/3" after an archive, "2/2" after a ranged fetch), so a hardcoded
		# copy here silently stops matching and this safety net quietly dies.
		if mapctx and mapctx.is_build_done():
			jobs.clear_activity(mapctx.build_job)
			# THE CPU IMAGE POOL, RECOVERED IF THE BUILD DID NOT DO IT ITSELF.
			#
			# Those images are only needed while uploading, and they are the
			# single largest thing the plugin holds: a CPU copy of every texture
			# in the build, alongside the GPU texture it was uploaded to. The
			# build releases them when both lanes finish, but that release is
			# gated on a set that an aborted or errored build can leave stale -
			# and then several GB sits there for the rest of the session with
			# nothing able to reclaim it, because the pool is static.
			#
			# Costs one dictionary size check twice a second when idle.
			if int(HighpolyBcTex.pool_stats().get("images", 0)) > 0:
				var _freed: Dictionary = HighpolyBcTex.pool_stats()
				HighpolyBcTex.release_images()
				Log.info("released %d CPU texture images (%.0f MB) left over "
					% [int(_freed.get("images", 0)),
					   float(_freed.get("image_mb", 0.0))]
					+ "after the build finished")
		HighpolyProfiler.span("panel tick: total", Time.get_ticks_msec() - _tt)
		# collision overlays follow objects the user moves/rescales
		#
		# MEASURED SEPARATELY, and note it sits OUTSIDE the "panel tick: total"
		# span above: the recorder's idea of a tick has never included this walk,
		# so if this is the expensive part the recorder has been reporting a tick
		# total that is missing it. The heartbeat bucket below does include it.
		if col_chk.button_pressed or HighpolyCollision.has_isolation():
			HighpolyProfile.begin("collision overlay follow")
			HighpolyCollision.refresh_transforms()
			HighpolyProfile.end("collision overlay follow")
		# THE "WHERE AM I" SNAPSHOT. One file that answers which build is
		# running, whether it is stale, which map and layers are up, what the
		# build is doing, which caches exist under which key, and what was
		# last picked - readable from outside WHILE the editor runs, which
		# the session log is not (law C11). Throttled: the heartbeat fires
		# twice a second and none of this changes that fast.
		_write_state_snapshot()
		HighpolyProfile.end("panel heartbeat"))
	# Every "it hangs when I do X" report needs to know what was switched on,
	# and not one of them has ever carried it. Registered rather than snapshotted
	# so the log records the state at SAVE time, which is the state the person
	# is describing.
	HighpolyVitals.set_settings_probe(_settings_snapshot)
	dock.add_child(mapctx_timer); mapctx_timer.start()
	_edited_root = EditorInterface.get_edited_scene_root()

	# every session starts safe: the rung that downloads nothing, until a mode is
	# chosen. _restore_mapctx_state moves off it if the open map was left higher.
	mode_btn.select(mode_btn.get_item_index(MODE_SDK))
	previews.tier = HighpolyLib.Tier.LOW
	_refresh_gates()

	# auto-overlay for pieces placed while a detail mode is active
	# ARM THE LIVE RELOAD with the code this editor just parsed. Doing it here
	# rather than on the first button press matters: an edit made between
	# startup and that press would otherwise be adopted as "already loaded"
	# and never applied.
	HighpolyReload.arm()
	# The cold swap's hand-off: the OLD panel triggered it and is gone; this
	# fresh instance is the proof it worked, and the report says what moved.
	if HighpolyReload.swap_report != "":
		Log.info(HighpolyReload.swap_report)
		HighpolyReload.swap_report = ""
	# AND WHAT IT MOVED, which decides whether the scenery is stale. The
	# overlay survives a cold swap on purpose (tearing it down cost a rebuild
	# per update), but its materials and meshes were built by the code that
	# was just replaced. A user proved the gap: a material fix applied through
	# Check for updates, the standing wheels kept the old shredded look, and
	# the button read as doing nothing. Classify the swapped names; anything
	# past "code" marks the overlay stale, and the state restore below
	# rebuilds it fresh instead of re-syncing chips to stale scenery.
	var _swn: Array = HighpolyReload.take_swap_names()
	if not _swn.is_empty():
		_swap_impact = HighpolyReload.impact(_swn)
		if _swap_impact != "code" and _swap_impact != "none":
			Log.info(("The update changed %s code, so the scenery on screen was "
				+ "built by the OLD code - the map state restore will rebuild "
				+ "it so the change actually shows.") % _swap_impact)
	get_tree().node_added.connect(_on_node_added)
	# live isolation follows the editor selection
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# door toggling + variant cycling need viewport clicks even with nothing
	# edited/selected
	set_input_event_forwarding_always_enabled()

	# THE SNAPSHOT GOES ON NOW, not deferred, and the order is the point.
	# _enter_tree leaves the dropdown on Low-Poly by design (every session starts
	# safe), and _startup applies whatever the dropdown says to every placed prop.
	# Correcting the dropdown one frame later would mean the scene is stripped
	# back to SDK proxies first and put back afterwards - visibly, and for nothing.
	if _kept.has("ui"):
		var _ui: Dictionary = _kept["ui"]
		_kept.erase("ui")
		_soft_restore = false
		_soft_applied = true
		_apply_ui(_ui)
	_startup.call_deferred()
	# ASK GITHUB ONCE ON OPEN. _check_plugin_update existed, worked, and was
	# called by NOTHING - the update button could never appear, which a user
	# proved by releasing v2.3.0 and watching no panel offer it. Deferred so
	# the dock is in the tree before the HTTP node parents to it.
	call_deferred("_check_plugin_update")


# THE STATE OF THE PANEL, for a saved log.
#
# Reports arrive as "it locked up", "it went to 16 GB", "the props are white",
# and every one of them depends on which layers were on and how far the render
# distance was pushed. We have been reconstructing that by asking. Every control
# is null-guarded: the log must save from any state, including a half-built dock
# after a failed reload.
# ---------------------------------------------------------------------------
# THE STATE SNAPSHOT: user://highpoly/state.json, rewritten from the heartbeat.
#
# WHY: everything the plugin knows was locked inside a running editor. The
# session log is the PREVIOUS session until a clean exit (law C11), so the
# only way to answer "what is it doing right now" was a screenshot or a quit.
# One JSON file, read at any moment by `tools/hp.py state`, answers the
# questions every diagnosis opens with: which build is running, is it stale,
# which map, what is switched on, what is the build doing, which caches exist
# and under which key, how many errors, and what was last picked.
#
# It reuses the probes that already exist rather than adding new ones (law
# C8): the settings block IS `_settings_snapshot()`, the pick line IS the
# diagnose provenance, the counts ARE the log's own tallies.
var _state_next := 0
var _state_cache_next := 0
var _state_cache := {}

func _write_state_snapshot() -> void:
	var now := Time.get_ticks_msec()
	if now < _state_next:
		return
	_state_next = now + 2000        # the heartbeat is 0.5 s; none of this moves that fast
	var gs = mapctx.game_source if mapctx != null else null
	var root := EditorInterface.get_edited_scene_root()
	var map: String = mapctx.map_of(root) if mapctx != null else ""
	# The cache directories are a DIRECTORY LISTING, which is the one part of
	# this that is not free. Recounted every 30 s; the key itself is the part
	# that matters and it is a string.
	if now >= _state_cache_next:
		_state_cache_next = now + 30000
		var gd: String = str(gs._geom_dir) if gs != null else ""
		var files := 0
		var bytes := 0
		if gd != "" and DirAccess.dir_exists_absolute(gd):
			for f in DirAccess.get_files_at(gd):
				files += 1
				bytes += int(FileAccess.get_size("%s/%s" % [gd, f]))
		_state_cache = {
			"geom_dir": gd, "geom_files": files,
			"geom_mb": snappedf(bytes / 1048576.0, 0.1),
			"mapctx_dir": "user://mapcontext/%s" % map if map != "" else "",
		}
	var d := {
		"plugin": {
			"version": HighpolyLog.plugin_version(),
			# The single most expensive misunderstanding this project has:
			# a fix deployed into a running editor changes nothing until a
			# restart, and every log written afterwards describes the OLD code.
			"disk_newer": HighpolyLog._staleness() != "",
		},
		"godot": Engine.get_version_info().get("string", ""),
		"epochs": {"geom": HighpolyGameSource.geom_epoch()},
		"map": {
			"name": map,
			"scene_root": String(root.name) if root != null else "",
			"open": gs != null,
		},
		"caches": _state_cache,
		"settings": Array(_settings_snapshot()),
	}
	if mapctx != null:
		d["build"] = {
			"state": "building" if bool(mapctx._building) else "idle",
			"done": int(mapctx._build_done), "total": int(mapctx._build_total),
			"props": int(mapctx._build_props),
		}
	if gs != null:
		d["counts"] = {"decisions": gs.decision_count()}
	if HighpolyDiagnose.has_focus():
		var fi: Dictionary = HighpolyDiagnose.focus_info()
		d["pick"] = {
			"confirmed": HighpolyDiagnose.is_confirmed(),
			"provenance": HighpolyDiagnose.provenance(gs),
			"node": str(fi.get("path", "")),
		}
	HighpolyLog.write_state(d)


func _settings_snapshot() -> PackedStringArray:
	var out := PackedStringArray()
	var yn := func(b: Button) -> String:
		return "unavailable" if b == null else ("ON" if b.button_pressed else "off")
	# WHICH SCENE IS OPEN, AND WHAT MAP WE THINK IT IS.
	#
	# Neither was ever recorded, and everything this plugin does hangs off the
	# second one: map_of() returns the scene ROOT NODE'S NAME, and only if it
	# begins with "MP_". A scene whose root is named anything else resolves to
	# "" and every path that needs the install returns silently - no read, no
	# skinning, nothing in the log to say why.
	#
	# A user reported exactly that: High-Poly selected, a four minute session,
	# and not one "game source" line. Without these two rows there was no way to
	# tell that from a read that failed.
	# THE GATE COMES FIRST, because it is the precondition for every other row
	# and its failure is INVISIBLE everywhere else: when the install is not
	# found the whole panel is dimmed and every control disabled, so pressing
	# Extended Terrain does nothing, writes nothing, and the log shows an idle
	# session. Three logs from one user read exactly that way before this row
	# existed - the reports said "the map cannot be found" when the truth was
	# "the GAME was never found".
	out.append("%-22s %s" % ["battlefield 6",
		"detected" if _bf6_ok else "NOT DETECTED - the panel is disabled, "
			+ "which is why buttons do nothing"])
	out.append("%-22s %s" % ["install path",
		bf6_path.text if bf6_path != null and bf6_path.text != ""
			else "(none set)"])
	if not _bf6_ok:
		var _why: Dictionary = GameDir.verify(
			bf6_path.text if bf6_path != null else "")
		out.append("%-22s %s" % ["why not", str(_why.get("why", "unknown"))])
	var _r0 := EditorInterface.get_edited_scene_root()
	var _map0: String = mapctx.map_of(_r0) if mapctx != null else ""
	out.append("%-22s %s" % ["scene root",
		String(_r0.name) if _r0 != null else "(no scene open)"])
	out.append("%-22s %s" % ["reads as map", _map0 if _map0 != ""
		else "NOT A MAP SCENE — the root must be named MP_<Map> for anything "
			+ "to be read from your install"])
	if mode_btn != null and mode_btn.selected >= 0:
		out.append("%-22s %s" % ["detail mode",
			mode_btn.get_item_text(mode_btn.selected)])
	out.append("%-22s %s" % ["map context", yn.call(mapctx_on)])
	out.append("%-22s %s" % ["map objects", yn.call(mapctx_objects)])
	out.append("%-22s %s" % ["skyline", yn.call(mapctx_backdrop)])
	out.append("%-22s %s" % ["water", yn.call(mapctx_water)])
	# No chip any more: they arrive with the ground. Reported from the map
	# context so a saved log still says whether they are on screen - yn() would
	# print "unavailable" for the missing button, which reads as broken.
	out.append("%-22s %s" % ["roads and paths",
		("ON (with the ground)" if mapctx != null and mapctx._show_roads
		else "off")])
	out.append("%-22s %s" % ["fx", yn.call(mapctx_fx)])
	out.append("%-22s %s" % ["lighting", yn.call(mapctx_light)])
	out.append("%-22s %s" % ["  sdfgi + ssao", yn.call(mapctx_gi)])
	out.append("%-22s %s" % ["  sun shadows", yn.call(mapctx_shadows)])
	out.append("%-22s %s" % ["  map lights", yn.call(mapctx_maplights)])
	out.append("%-22s %s" % ["cull placed objects", yn.call(mapctx_optimize)])
	out.append("%-22s %s" % ["collision overlay", yn.call(col_chk)])
	if mapctx_range != null:
		# Stated with its meaning, because the top of this slider is the setting
		# that turns every performance question into a different question: at
		# maximum, nothing is culled by distance at all.
		var r := int(mapctx_range.value)
		out.append("%-22s %s" % ["render distance",
			"objects OFF" if r <= 0
			else ("MAXIMUM, no distance culling" if r >= int(mapctx_range.max_value)
			else "%d m" % r)])
	if mapctx_variant != null and mapctx_variant.selected > 0:
		out.append("%-22s %s" % ["gamemode variant",
			mapctx_variant.get_item_text(mapctx_variant.selected)])
	return out


func _exit_tree() -> void:
	# The clean-exit marker. Its ABSENCE next session is what says the editor
	# died rather than closed, so this has to run on the ordinary path — and it
	# runs first, before any of the teardown below can throw and skip it.
	HighpolyProfiler.crumbs_end()
	# The object debugger holds a Window parented to the editor itself and an
	# isolation over the scene; both outlive this dock unless closed here.
	if objdebug != null:
		objdebug.close()
		objdebug = null
	# A recording left running across a plugin reload would leave open buckets on
	# a stack that outlives the panel, and the next session would charge its first
	# frames to whatever was open when this one ended.
	HighpolyProfile.set_enabled(false)
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	var esel := EditorInterface.get_selection()
	if esel.selection_changed.is_connected(_on_selection_changed):
		esel.selection_changed.disconnect(_on_selection_changed)
	# A SOFT REOPEN IS NOT A SHUTDOWN. The same plugin is coming straight back,
	# so nothing below needs undoing, and undoing it is exactly what made a layout
	# change cost a full rebuild. Hand the long-lived services across and stop.
	if _soft_reopen:
		_soft_reopen = false     # one reopen, not every disable from here on
		_kept["ui"] = _capture_ui()
		_keep_service("mapctx", mapctx)
		_keep_service("previews", previews)
		_keep_service("profiler", profiler)
		_keep_service("jobs", jobs)
		Log.hook(Callable())     # never call into a freed panel
		if tools_btn:
			remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, tools_btn)
			tools_btn.queue_free()
			tools_btn = null
		# A DOCKED CONTROL HAS TO BE TAKEN OUT BEFORE ITS OWNER GOES.
		#
		# win.free() takes dock_root with it only while dock_root is inside the
		# window. Docked, it is parented into the editor's own dock column
		# instead, so freeing the window leaves it sitting there - a tab
		# belonging to a plugin that no longer exists, which survives into the
		# editor's saved layout.
		if _is_docked():
			remove_control_from_docks(dock_root)
			dock_root.queue_free()
			dock_root = null
		if win:
			win.free()
			win = null
		return
	# Their ground decal is a saved node we only ever HID; a plugin that is being
	# switched off must not leave a piece of the user's scene invisible.
	if mapctx != null:
		mapctx.restore_sdk_decals()
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
	Log.hook(Callable())         # never call into a freed panel
	if jobs: jobs.reset()        # release the gate: nobody is left to call release()
	if tools_btn:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, tools_btn)
		tools_btn.queue_free()
		tools_btn = null
	# Out of the dock column first, or freeing the window frees nothing: docked,
	# dock_root is not the window's child and would be left behind as a tab
	# belonging to a plugin that has been switched off.
	if _is_docked():
		remove_control_from_docks(dock_root)
		dock_root.free()
		dock_root = null
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

# ---------- startup ----------
func _startup() -> void:
	# UNATTENDED SESSIONS, when the environment asks for one. Both run the real
	# dock path over the real scene and quit with a report, which is the only way
	# to measure what a user actually experiences — a bench that loads the same
	# meshes into a bare tree measures a different world.
	#
	# Checked FIRST and returning: an unattended run has nobody at the keyboard.

	# The performance run (tools/perfrun.py) is tested before the autorun because
	# the two configure the dock differently, and a stale BF6_AUTORUN left in the
	# environment must not shadow a perf run that was explicitly asked for.
	if HighpolyFlightRun.requested():
		HighpolyFlightRun.run(self, dock, mapctx)
		return
	if HighpolyAutorun.requested():
		HighpolyAutorun.run(self, dock, mapctx)
		return
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
	await _apply_scene()
	_reapply_placed_cull()

func _marked_meshes(root: Node) -> Array:
	var pts: Array = []
	for m in HighpolyMarkers.list(root):
		var md: Dictionary = m
		if md.has("pos"):
			pts.append(md["pos"])
		elif md.has("node") and md["node"] is Node3D:
			pts.append((md["node"] as Node3D).global_transform.origin)
	if pts.is_empty():
		return []
	var ctx := root.get_node_or_null(HighpolyMapContext.NODE)
	if ctx == null:
		return []
	var out: Array = []
	var stack: Array = [ctx]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var mesh: Mesh = null
		var xforms: Array = []
		if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
			var mm := (n as MultiMeshInstance3D).multimesh
			mesh = mm.mesh
			var gx: Transform3D = (n as Node3D).global_transform 				if (n as Node3D).is_inside_tree() else (n as Node3D).transform
			for i in range(mm.instance_count):
				xforms.append(gx * mm.get_instance_transform(i))
		elif n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			mesh = (n as MeshInstance3D).mesh
			xforms.append((n as Node3D).global_transform)
		if mesh == null or out.has(mesh):
			continue
		for x in xforms:
			var hit := false
			for p in pts:
				if (x as Transform3D).origin.distance_to(p as Vector3) 						<= HighpolyMarkers.RADIUS:
					hit = true
					break
			if hit:
				out.append(mesh)
				break
	return out


# ---------- the scene ON DISK stays stock ----------
#
# Everything the plugin ADDS is owner-less, so none of it can ever be written to
# a .tscn. That was always the plan and it holds. What it does not cover is
# everything the plugin CHANGES on nodes that are the user's own:
#
#   * the SDK proxy meshes of every placed object, hidden while an overlay draws
#     in their place (`visible`, which serialises as an instance override)
#   * the level's own _Assets and terrain, hidden by Original map objects
#   * the level's ground decal, hidden by the map tile
#   * visibility_range_* on placed meshes, written by the distance cull
#
# Every one of those is a serialized property on a node the scene owns, so a
# scene saved with the plugin on carries them into the file. Uninstall the plugin
# afterwards and the level opens with its assets hidden and its placed props
# invisible, with nothing left to explain why. Teardown restores all of it in
# memory, which is no help to a file that was written an hour earlier.
#
# _apply_changes is the editor's "about to save" hook. Put the scene back to
# stock here, let the save write a stock file, restore the preview on the next
# frame. Cheap for the same reason a mode switch is cheap: the overlays stay
# parented and only visibility flips, so nothing is rebuilt, re-fitted or
# re-read. It costs two visibility walks per Ctrl+S.
var _stocked_for_save := false

func _apply_changes() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null or _stocked_for_save:
		return
	_stocked_for_save = true
	PlacedCull.release(r)              # visibility_range_* back to what it was
	SdkHide.restore_all(r)             # the level's own assets and terrain back
	if mapctx != null:
		mapctx.restore_sdk_decals()    # their ground decal back
	HighpolyLib.restore(r)             # overlays hidden, SDK proxies shown
	# Deferred rather than awaited: the save runs the moment this returns, so
	# anything queued here lands after the file has been written.
	call_deferred("_unstock_after_save")


func _unstock_after_save() -> void:
	if not _stocked_for_save:
		return
	_stocked_for_save = false
	if EditorInterface.get_edited_scene_root() == null:
		return
	_sdk_assets_hidden(mapctx_objects != null and mapctx_objects.button_pressed)
	_sdk_terrain_hidden(mapctx_on != null and mapctx_on.button_pressed)
	await _apply_scene()
	_reapply_placed_cull()


# THE BUILD AND THE PLACED PROPS ARE THE SAME WORK, done once.
#
# Building the level's scenery parses the game's meshes for everything the level
# contains. The objects the USER placed are drawn from the same prefabs through
# the same mesh_for(), which caches, so once the build has been past a mesh the
# placed prop that wants it costs a dictionary lookup rather than a second parse.
#
# What was missing was the MOMENT. A placed prop resolves when something asks it
# to: a mode switch, a drop, a selection. None of those happen while a build
# runs, so a prop whose model only became reachable because of the build sat as
# an SDK proxy until the user happened to touch it, standing next to a level full
# of the very same object drawn properly.
#
# So the build's completion asks. It is the paced swap, which for a prop that is
# already overlaid is a validity check and two visibility flags, and for one that
# is not is the mesh the build has just cached.
func _swap_placed_after_build() -> void:
	if _mode() == HighpolyLib.Tier.LOW:
		# Low-Poly draws the SDK's own proxies on purpose. Its one exception is
		# the per-selection preview, and that path opens and applies by itself.
		return
	var r := EditorInterface.get_edited_scene_root()
	if r == null or HighpolyLib.game_source == null:
		return
	await _apply_scene()
	_reapply_placed_cull()


# THE PANEL COMES BACK THE WAY IT WAS, which is a separate question from the
# scene coming back.
#
# The scene survives a soft reopen because nothing tears it down. The CONTROLS do
# not: they are built fresh, so they come up on their shipped defaults - Low-Poly,
# every chip off - while the scene still has the scenery on and the props swapped.
# The panel then disagrees with the level it is describing, and the first toggle
# you touch acts on the panel's idea rather than the scene's.
#
# Reading the saved per-map state back is the wrong repair: that is what was on
# disk, and what matters is what was on SCREEN a moment ago, which may be neither
# saved nor savable yet. So the live values are carried across with the services.
#
# Applied with no signals: every one of these already describes something the
# scene is doing, so firing the handlers would rebuild what is already built.
func _capture_ui() -> Dictionary:
	var chips := {}
	for e in _ui_chips():
		var c: Button = e[1]
		if c != null and is_instance_valid(c):
			chips[str(e[0])] = c.button_pressed
	return {
		"chips": chips,
		"mode": mode_btn.get_selected_id() if mode_btn != null else -1,
		"range": mapctx_range.value if mapctx_range != null else -1.0,
		"fill": mapctx_fill.value if mapctx_fill != null else -1.0,
		"photo": mapctx_photo.value if mapctx_photo != null else -1.0,
		"variant": mapctx_variant.selected if mapctx_variant != null else -1,
		"scroll": dock_scroll.scroll_vertical if dock_scroll != null else 0,
		"open": win != null and win.visible,
		"rect": Rect2i(win.position, win.size) if (win != null and win.visible) else Rect2i(),
	}


func _apply_ui(d: Dictionary) -> void:
	var chips: Dictionary = d.get("chips", {})
	for e in _ui_chips():
		var c: Button = e[1]
		if c != null and is_instance_valid(c) and chips.has(str(e[0])):
			c.set_pressed_no_signal(bool(chips[str(e[0])]))
	var m := int(d.get("mode", -1))
	if mode_btn != null and m >= 0:
		mode_btn.select(mode_btn.get_item_index(m))
		if previews != null:
			previews.tier = _mode()
			previews.textured = _textured()
	var rg := float(d.get("range", -1.0))
	if mapctx_range != null and rg >= 0.0:
		mapctx_range.set_value_no_signal(rg)
		if mapctx_range_val: mapctx_range_val.text = _range_label(rg)
	var fl := float(d.get("fill", -1.0))
	if mapctx_fill != null and fl >= 0.0:
		mapctx_fill.set_value_no_signal(fl)
		if mapctx_fill_val: mapctx_fill_val.text = "%d%%" % int(fl)
	var pv := float(d.get("photo", -1.0))
	if mapctx_photo != null and pv >= 0.0:
		mapctx_photo.set_value_no_signal(pv)
		if mapctx_photo_val: mapctx_photo_val.text = "%d%%" % int(pv)
		MapContextScript.colormap_strength = clampf(pv / 100.0, 0.0, 1.0)
		MapContextScript.colormap_enabled = pv > 0.5
	var vi := int(d.get("variant", -1))
	if mapctx_variant != null and vi >= 0 and vi < mapctx_variant.item_count:
		mapctx_variant.select(vi)
	# The statics the chips only MIRROR have to be told too, because nothing
	# fired a handler to tell them.
	if mapctx_fx != null:
		MapContextScript.show_fx_cards = mapctx_fx.button_pressed
	_refresh_gates()
	_lighting_subs_enabled(mapctx_light != null and mapctx_light.button_pressed)
	# The window is a child of the editor, not of the dock, so a reopen closes it
	# and the launcher button comes back untoggled. Put it back where it was.
	if bool(d.get("open", false)) and win != null:
		var rc: Rect2i = d.get("rect", Rect2i())
		if rc.size.x > 0:
			_win_rect = rc
		if tools_btn != null:
			tools_btn.set_pressed_no_signal(true)
		_set_tools_visible(true)
	var sc := int(d.get("scroll", 0))
	if dock_scroll != null and sc > 0:
		# after the layout settles, or the scroller clamps it to a height the
		# content has not reached yet
		_restore_scroll.call_deferred(sc)


func _restore_scroll(v: int) -> void:
	if dock_scroll != null and is_instance_valid(dock_scroll):
		dock_scroll.scroll_vertical = v


# Every control whose position is part of "how the panel was". Named, because a
# reopen rebuilds them and only the name survives.
func _ui_chips() -> Array:
	return [
		["on", mapctx_on], ["objects", mapctx_objects],
		["backdrop", mapctx_backdrop], ["water", mapctx_water],
		["fx", mapctx_fx], ["light", mapctx_light], ["gi", mapctx_gi],
		["shadows", mapctx_shadows], ["maplights", mapctx_maplights],
		["optimize", mapctx_optimize], ["col", col_chk], ["shape", shape_chk],
		["iso", iso_chk], ["ovr", ovr_chk], ["pick", diag_pick],
	]


# ---------- reopening the panel ----------
#
# WHAT LIVE RELOAD CANNOT DO. Replacing a script updates the code every existing
# object runs, which is why a material fix reaches a prop already on screen. It
# cannot un-create an object. This panel is built inline in _enter_tree, so every
# control on it was constructed when the editor opened: a change that ADDS,
# REMOVES or RELABELS a control changes the function that would build it and not
# the buttons already sitting there. So the plugin is reopened, which runs the
# real _exit_tree and _enter_tree and rebuilds the panel by exactly the path that
# builds it at startup.
#
# A REOPEN MUST NOT COST THE SCENERY. The first version let the ordinary teardown
# run, which frees _MAP_CONTEXT and every overlay, so the scene rebuilt itself
# afterwards - a minute of work to move a button. And because this file is the
# one that changes most, that was nearly every press of Check for updates. The
# rebuild was the complaint that started the live reload in the first place.
#
# So a reopen for a layout change is SOFT:
#
#   * the scene is left exactly as it is. Nothing is restored, because nothing is
#     going away: the same plugin is coming straight back.
#   * the long-lived services (the map context, the previews, the recorder, the
#     job queue) are handed across rather than rebuilt. They hold the open game
#     source, the cell index, the icon cache - state that costs minutes to
#     rebuild and nothing to keep.
#
# They are kept by REPARENTING them out of the dock before it is freed, into the
# editor's own base control, and picked up again by _enter_tree. A static holds
# the references: statics live on the script, and the script is not going
# anywhere, only this object is.
const PLUGIN_NAME := "highpoly_toggle"
static var _kept: Dictionary = {}     # service name -> Node, across a soft reopen
static var _soft_reopen := false      # set by _reopen_panel, read by _exit_tree
# The other half of the same fact, read by the startup restore: it must adopt the
# scenery that is standing rather than sweep it and build a fresh copy.
static var _soft_restore := false
# Set for the life of this instance when it came back from a soft reopen, so the
# scene-change path does not run the disk restore over a panel that already
# describes the scene correctly.
var _soft_applied := false
var _needs_reopen := false
# The cold swap's impact class ("materials"/"mixed"/"geometry"), carried from
# the swap marker to the map state restore, which rebuilds stale scenery once
# and clears it. Empty = no swap, or a swap that cannot reach anything built.
var _swap_impact := ""

func _reopen_panel() -> void:
	Log.info("Reopening the panel to apply a layout change. The scenery and the "
		+ "open game source are kept.")
	_soft_reopen = true
	_soft_restore = true
	EditorInterface.call_deferred("set_plugin_enabled", PLUGIN_NAME, false)
	EditorInterface.call_deferred("set_plugin_enabled", PLUGIN_NAME, true)


# Hand a service across the reopen. Reparented rather than orphaned: a node with
# no parent is outside the tree, and these run timers and awaits.
func _keep_service(name: String, node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var host := EditorInterface.get_base_control()
	if host == null:
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	host.add_child(node)
	_kept[name] = node


# The other side: adopt one if a soft reopen left it, else null for the caller to
# construct. Cleared as it is taken, so a later ordinary start cannot pick up a
# service belonging to a session that has ended.
func _take_service(name: String) -> Node:
	if not _kept.has(name):
		return null
	var n = _kept[name]
	_kept.erase(name)
	if n == null or not is_instance_valid(n):
		return null
	if n.get_parent() != null:
		n.get_parent().remove_child(n)
	return n


func _hot_reload() -> bool:
	# Asked on BOTH sides of the reload, because the answer is the difference.
	# See HighpolyGameSource.geom_epoch for why it has to be a call and not a
	# constant read.
	var epoch_before: int = HighpolyGameSource.geom_epoch()
	var r: Dictionary = HighpolyReload.reload_code()
	var geom_changed: bool = HighpolyGameSource.geom_epoch() != epoch_before
	var names: Array = r["names"]
	if bool(r["first"]):
		Log.info("Live reload armed: this install is now the baseline, so the "
			+ "next press picks up whatever has changed since.")
		return true
	if not (r["failed"] as Array).is_empty():
		lbl.text = "Some plugin files would not reload — restart the editor"
		Log.error("Live reload could not replace: %s" % str(r["failed"]))
		return false
	if names.is_empty():
		Log.info("Plugin code unchanged — nothing to reload.")
		return true

	var what := HighpolyReload.impact(names, geom_changed)
	# HEAL THE LIVING INSTANCES FIRST, before anything re-dresses through them.
	# A swap replaces code but never runs the new initializers on an existing
	# object, so a member the update ADDED is null on every live instance - and
	# the very next material build dies on it, dressing the whole map white.
	# (That exact regression shipped once; see HighpolyReload.heal_new_members.)
	var _gs0 = mapctx.game_source if mapctx != null else null
	var _healed := 0
	for o in [mapctx, _gs0,
			(_gs0.src if _gs0 != null else null),
			(_gs0.walk if _gs0 != null else null),
			previews, jobs]:
		_healed += HighpolyReload.heal_new_members(o)
	if _healed > 0:
		Log.info("Initialized %d member(s) the update added on live objects" % _healed)
	# REFRESH WHAT IS CHEAP TO RE-ASK, and nothing else.
	#
	# map_data holds answers derived from the install, and a reader fix cannot
	# reach an answer already given. The first version of this dropped the whole
	# summary, which was far too blunt: apply() clears the scene BEFORE it reloads
	# the data, so a rebuild that then failed on a missing key left the level torn
	# down with every later toggle hitting the same error. It also put a minute of
	# terrain work on the main thread inside a toggle handler.
	#
	# Water is re-asked instead, on its own, because it is one small partition
	# parse and because its staleness is invisible by construction: map_data only
	# writes a "water" key when water is FOUND, so a level read before the fix
	# carries an ABSENT key, which every consumer reads as "this level has no
	# water" rather than "not looked up yet".
	if what != "code" and what != "none":
		var _gs = mapctx.game_source if mapctx != null else null
		if _gs != null and _gs.has_method("refresh_water"):
			_gs.refresh_water()
		# The scene's Water node was built from the PRE-reload answer, so a
		# refreshed answer is invisible until the layer rebuilds. If it is on,
		# re-fire its own handler (deferred: this runs inside the reload) so a
		# water fix reaches the screen without a manual off/on - the exact step
		# users skip, reasonably, after pressing a button called "updates".
		if mapctx_water != null and mapctx_water.button_pressed:
			(func():
				if mapctx_water != null and is_instance_valid(mapctx_water):
					mapctx_water.toggled.emit(true)).call_deferred()
	Log.info("Reloaded %d file(s) in place: %s" % [names.size(), ", ".join(names)])
	match what:
		"code":
			# Dock and logging only. Nothing already built can look different,
			# so re-dressing thousands of surfaces would be pure cost.
			lbl.text = "Reloaded %d file(s)" % names.size()
		"materials", "mixed":
			var gs = mapctx.game_source if mapctx != null else null
			if gs != null and gs.has_method("invalidate_materials"):
				var st: Dictionary = gs.invalidate_materials()
				Log.info("Re-dressed %d mesh(es), %d surface(s) in %d ms"
					% [st["meshes"], st["surfaces"], st["ms"]])
				lbl.text = "Reloaded %d file(s), re-dressed %d mesh(es)" 					% [names.size(), st["meshes"]]
			else:
				lbl.text = "Reloaded %d file(s)" % names.size()
			# AND THE OBJECTS THE USER PLACED, which the re-dress above does not
			# reach: it re-dresses the meshes the MAP CONTEXT recorded, and a
			# placed object's overlay is a separate node holding its own mesh.
			# Without this a material fix landed on every prop on the map and on
			# anything placed after the reload, and left the objects already in
			# the scene untouched.
			#
			# Guarded and paced by _swap_placed_after_build rather than calling
			# the apply straight: it refuses in Low-Poly, where the SDK's own
			# proxies are what the user asked to see, and it restores the
			# distance cull afterwards.
			LibScript.build_epoch += 1
			_swap_placed_after_build()
			if what == "mixed":
				# Those files resolve materials AND build geometry, and only the
				# first half of that is live now. Saying so beats letting a road
				# height change look like it applied.
				lbl.text += ". Rebuild the map to pick up the geometry change."
				Log.info("Those files also build geometry (roads, terrain drape, "
					+ "prop meshes). If that is what changed, toggle Map Context "
					+ "off and on.")
		"geometry":
			# Honest rather than convenient: the built meshes came out of the
			# code that just changed, and no amount of re-dressing fixes a
			# vertex. Say what it needs instead of half-doing it.
			lbl.text = "Reloaded %d file(s) — rebuild the map to apply" 				% names.size()
			Log.warn("Those files decide what geometry is BUILT, so the meshes "
				+ "already in the scene are stale. Toggle Map Context off and "
				+ "on to rebuild.")
	# The panel is built once, at startup. A change to the file that builds it
	# cannot move a control that already exists, so say so and put the button
	# that applies it where the message is.
	# DONE, not offered. The plugin knows when a layout change cannot be applied
	# in place, and a button that must be pressed after another button is one the
	# user has to learn the meaning of. The caller reopens and stops there,
	# because reopening frees this object.
	_needs_reopen = names.has("highpoly_toggle.gd")
	if _needs_reopen:
		Log.info("The panel itself changed. Its controls were built when the "
			+ "editor opened, so the plugin is being reopened to build them "
			+ "again. The level scenery is rebuilt with it.")
	return true


func _check_updates_now() -> void:
	check_btn.disabled = true
	# THE BUTTON SAYS "Check for updates", SO CHECK GITHUB. This call was only
	# ever wired to nothing (see _enter_tree); the button applied staged files
	# and reloaded local changes but never asked the releases API, so a fresh
	# release sat invisible until an editor restart - and then still invisible,
	# because the startup check was not wired either. Announced, so pressing
	# the button says "up to date" or "vX.Y.Z is available" instead of nothing.
	_check_plugin_update(true)
	# STAGED UPDATES FIRST. Mid-session fixes cannot be written into res://
	# (the editor hot-reloads changed scripts underneath running code - the
	# "Bad address index" crash), so they land in user://highpoly/staged and
	# THIS press - a moment the user chose - is what moves them into the addon
	# before the normal reload below picks them up. Refused while anything is
	# building, because swapping code under a live build is the exact crash
	# the staging exists to avoid. "starting up" counts as quiet: it is the
	# boot crumb, and nothing has armed a build yet when it still reads that.
	if HighpolyReload.staged_count() > 0:
		var _c := HighpolyVitals.crumb_now()
		if not (HighpolyVitals.crumb_is_idle() or _c == "starting up"):
			check_btn.disabled = false
			lbl.text = "An update is staged, but something is building (%s) — press again when it settles" % _c
			return
		var staged: Dictionary = HighpolyReload.apply_staged()
		if not (staged["failed"] as Array).is_empty():
			check_btn.disabled = false
			lbl.text = "Some staged files could not be applied — try once more, or restart the editor"
			Log.error("Staged update could not replace: %s" % str(staged["failed"]))
			return
		var _ap := staged["applied"] as Array
		if not _ap.is_empty():
			Log.info("Applied %d staged file(s): %s" % [_ap.size(), ", ".join(_ap)])
		# WHAT THIS BUTTON CANNOT DO, said plainly rather than left to be
		# discovered. Scripts and shaders go live here; anything else - the
		# native extension, the fx data files, binaries - is only picked up
		# when the editor next starts, because nothing can swap them under a
		# running session. Saying so is what makes the button trustworthy
		# enough to use instead of closing the editor every time.
		var _ig := (staged.get("ignored", []) as Array)
		if not _ig.is_empty():
			Log.warn(("%d staged file(s) are not code and stay where they are "
				+ "until the editor is next started: %s")
				% [_ig.size(), ", ".join(_ig)])
	# CODE FIRST, and only what actually moved.
	#
	# This button used to be about downloading models. There are no models to
	# download: everything is read from the install. What is left is the thing it
	# grew into, which is applying plugin code without an editor restart. The
	# scripts and shaders whose CONTENT differs are replaced in place, and objects
	# already holding them run the new code immediately.
	#
	# Hash-compared rather than mtime-compared on purpose. A zip extraction
	# stamps every file with the same "now", so an mtime test would replay the
	# entire addon on every press and re-dress a map for nothing.
	#
	# SCRIPT CHANGES TAKE THE COLD SWAP, not the live rebind. Hot reload onto
	# live instances is where every "now restart the editor" came from: null
	# new members, constants folded stale into callers, big scripts silently
	# keeping old bytecode. The cold swap disables the plugin, replaces the
	# scripts while nothing holds them, and re-enables - a plugin-only
	# restart in a couple of seconds. Triggered DEFERRED off the tree because
	# the disable frees THIS dock, and freeing the object whose method is on
	# the stack is a crash. Shader-only changes keep the cheap live path.
	var pend: Dictionary = HighpolyReload.pending()
	var moved: Array = (pend["changed"] as Array) + (pend["added"] as Array)
	var has_gd := false
	for f in moved:
		if str(f).get_extension().to_lower() == "gd":
			has_gd = true
			break
	if has_gd and not bool(pend["first"]):
		lbl.text = "Applying the update - the panel rebuilds itself in a moment"
		Log.info("Cold swap: %d changed file(s), restarting the plugin in place"
			% moved.size())
		get_tree().process_frame.connect(Callable(HighpolyReload, "cold_swap"),
			CONNECT_ONE_SHOT | CONNECT_DEFERRED)
		return
	if not _hot_reload():
		check_btn.disabled = false
		return
	if _needs_reopen:
		# Nothing after this point: reopening frees the plugin, and the storage
		# readout below awaits, so it would resume inside a freed object.
		lbl.text = "Applying a panel change…"
		_reopen_panel()
		return
	check_btn.disabled = false
	_refresh_storage()

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

# The bar stands in for the Check for updates button while anything is
# downloading, so the panel never shows both a button and a bar for the same
# thing. "45%  1/2" is this job's progress and which of the queued jobs it is.
# Colour carries the level so an error is findable in a long list without
# reading it. Appended line by line rather than rebuilt, because rebuilding an
# 800-line view on every message is what makes a log panel stutter.
func _log_line(lvl: int, msg: String) -> void:
	# THE READER LOGS FROM A WORKER THREAD, AND THIS IS EDITOR UI.
	#
	# HighpolyLog._add calls this sink wherever it is called from, and the ground
	# build runs on a WorkerThreadPool task: ensure_ground -> terrain_surface ->
	# BF6Splat.composite -> its progress lambda -> tick_long -> info -> here. Godot
	# refuses append_text/add_theme_color_override off the main thread, so the
	# panel silently missed those lines and the engine log filled with 42 errors
	# our own report counted as zero - it counts what goes THROUGH the logger, and
	# these were the logger failing. call_deferred is the documented remedy and is
	# safe to call from any thread.
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		_log_line.call_deferred(lvl, msg)
		return
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

# One keyed bar for one long job, opened on the first report and closed when
# done reaches total. Handed to whatever is doing the work as a plain Callable,
# so a module does not have to know the panel exists to be able to report.
#
# Written once and shared because three separate long jobs — unpacking the
# scenery archive, placing the map lights and placing the FX — each ran for tens
# of seconds with no bar at all. Getting the map objects in is three stages and
# only two of them were visible, so the panel showed a finished download and a
# build that had not started, which reads exactly like a hang.
func _lane(label: String) -> Callable:
	return func(done: int, total: int) -> void:
		if jobs == null: return
		if total > 0 and done < total:
			jobs.set_activity(label, done, total)
		else:
			jobs.clear_activity(label)


# ---------- the read of the install, stage by stage ----------
#
# Three entry points, and the split matters. _read_begin and _read_stage_set are
# driven by the worker (through open_async's once-a-frame pump); _read_refresh is
# driven by the panel's own half-second timer. Only the second kind can keep a
# clock moving through a stage that reports nothing at all for forty seconds,
# which is most of a cold read.
#
# THE MODEL IS STATIC AND TAKES ITS CLOCK AS AN ARGUMENT so it can be tested.
# An EditorPlugin cannot be instantiated outside a running editor, so anything
# living on `self` is only ever exercised by hand, and the part worth testing
# here is exactly the fiddly part: a stage that never reported at all still has
# to end up marked done rather than sitting on "waiting" forever.

# model: {map, cold, stage, done, total, t0, stage_t0, spent}
static func read_model_new(map: String, cold: bool, now: int) -> Dictionary:
	return {"map": map, "cold": cold,
		"stage": str(HighpolyGameSource.OPEN_STAGES[0]),
		"done": 0, "total": 0, "t0": now, "stage_t0": now, "spent": {}}


static func read_model_stage(m: Dictionary, stage: String, done: int,
		total: int, now: int) -> void:
	if str(m["stage"]) != stage:
		# EVERYTHING EARLIER IN THE LIST IS FINISHED, whether or not it ever
		# reported. Stages get skipped outright all the time: a cached walk never
		# calls back, a map with no ground skips five of them at once. Marking
		# only the stage we just left would leave those on "waiting" for the rest
		# of the read, which reads as stuck at precisely the moment things are
		# going well.
		var at: int = HighpolyGameSource.OPEN_STAGES.find(stage)
		for i in range(maxi(at, 0)):
			var s := str(HighpolyGameSource.OPEN_STAGES[i])
			if not (m["spent"] as Dictionary).has(s):
				(m["spent"] as Dictionary)[s] = 0
		if str(m["stage"]) != "":
			(m["spent"] as Dictionary)[str(m["stage"])] = now - int(m["stage_t0"])
		m["stage"] = stage
		m["stage_t0"] = now
	m["done"] = done
	m["total"] = total


static func read_model_title(m: Dictionary, now: int) -> String:
	return "Reading %s from your game install (%s)" % [str(m["map"]),
		_clock(now - int(m["t0"]))]


static func read_model_lines(m: Dictionary, now: int) -> Array:
	var spent: Dictionary = m["spent"]
	var out: Array = []
	for st in HighpolyGameSource.OPEN_STAGES:
		var s := str(st)
		if spent.has(s):
			var ms := int(spent[s])
			# A stage that took no measurable time was served from a cache or was
			# not needed, and saying which is worth a word: "cached" is the whole
			# reason a read that took two minutes yesterday takes two seconds now.
			out.append("   done      %s   %s" % [s, "cached" if ms < 60 else _clock(ms)])
		elif s == str(m["stage"]):
			var detail := ""
			if int(m["total"]) > 0:
				detail = "   %d%%" % int(100.0 * float(m["done"])
					/ float(maxi(1, int(m["total"]))))
			elif int(m["done"]) > 0:
				detail = "   %s found so far" % _grouped(int(m["done"]))
			out.append("   NOW       %s   %s%s"
				% [s, _clock(now - int(m["stage_t0"])), detail])
		else:
			out.append("   waiting   %s" % s)
	return out


func _map_read_before(map: String) -> bool:
	return FileAccess.file_exists("%s/%s/colormap.png"
		% [HighpolyMapContext.CACHE, map])


# What the catalogue mount calls itself on the job bar. Named the way a user
# would describe it rather than after the function, because this string is
# what they read while they wait.
const CATALOGUE_BAR := "adding the placeable catalogue"

# Rate limit for the bar's own readout; see _refresh_job_bar_body.
var _bar_logged_ms := 0

# The stage whose key is currently in the job bar's activity table. Exactly
# one is live at a time; see _read_refresh for why that matters.
var _bar_stage := ""


func _read_begin(map: String, cold: bool) -> void:
	_read_model = read_model_new(map, cold, Time.get_ticks_msec())
	if read_note != null:
		# Said BEFORE the wait rather than after it. The read is about a minute
		# and a half the first time a map is seen and about two seconds every
		# time after, and someone who does not know that is watching what looks
		# like a hang.
		read_note.text = ("First time on this map, so this reads it out of your "
			+ "game install. It takes a couple of minutes. After this it takes "
			+ "about two seconds.") if cold else ""
		read_note.visible = cold
	_read_refresh()


func _read_stage_set(stage: String, done: int, total: int) -> void:
	if _read_model.is_empty():
		return
	read_model_stage(_read_model, stage, done, total, Time.get_ticks_msec())
	_read_refresh()


func _read_end() -> void:
	_bar_stage = ""
	if jobs != null and not _read_model.is_empty():
		for s in HighpolyGameSource.OPEN_STAGES:
			jobs.clear_activity(str(s))
	_read_model = {}
	if read_panel != null and is_instance_valid(read_panel):
		read_panel.visible = false
	if job_bar != null and is_instance_valid(job_bar):
		job_bar.indeterminate = false


func _read_refresh() -> void:
	if read_panel == null or not is_instance_valid(read_panel):
		return
	if _read_model.is_empty():
		read_panel.visible = false
		return
	var now := Time.get_ticks_msec()
	read_panel.visible = true
	read_title.text = read_model_title(_read_model, now)
	read_list.text = "\n".join(PackedStringArray(
		read_model_lines(_read_model, now)))
	# THE BIG BAR SHOWS THE WHOLE READ, not the current stage's own counts.
	#
	# It was fed the stage's done/total, and half the stages have no denominator
	# to give: the walk reports rows-found-so-far against a total of 0, and the
	# ground stages report 0,0. Those became "0 of 1" and an indeterminate bar,
	# so reading placements - the longest stage of a cold open - never moved the
	# bar at all.
	#
	# There IS an honest overall denominator: the read has a fixed, ordered list
	# of stages, and the model already knows which one it is on. Position is the
	# stage index plus how far through that stage we are when it can say, scaled
	# by 100 so a fractional stage still moves the bar. Monotonic, always
	# determinate, and it keeps moving through a stage that cannot count itself
	# because the NEXT stage starting is itself progress.
	var total := int(_read_model["total"])
	var done := int(_read_model["done"])
	var stages: Array = HighpolyGameSource.OPEN_STAGES
	var at: int = stages.find(str(_read_model["stage"]))
	if at < 0:
		at = 0
	var frac := 0.0
	if total > 0:
		frac = clampf(float(done) / float(total), 0.0, 1.0)
	# WEIGHTED BY WHAT EACH STAGE COSTS, not one tenth each. See STAGE_WEIGHT:
	# an even split put the whole first half minute inside the first 30% and
	# gave the splat composite, which is more than a third of the read, 10% of
	# the travel. The bar sat near zero and then appeared to freeze at 70%.
	var w: Dictionary = HighpolyGameSource.STAGE_WEIGHT
	var before := 0.0
	var total_w := 0.0
	for i in range(stages.size()):
		var sw := float(w.get(stages[i], 1.0))
		total_w += sw
		if i < at:
			before += sw
	var here := float(w.get(str(_read_model["stage"]), 1.0))
	var pos := (before + frac * here) / maxf(total_w, 0.001)
	if jobs != null:
		# ONE LIVE KEY AT A TIME, and this is why the bar read zero for most of
		# a load even after the stages were weighted.
		#
		# HighpolyJobs keys activities by label and ratio() returns the
		# LEAST-finished of them. A key per stage means every finished stage
		# stays in that dictionary at the value it stopped on - so once
		# "mounting the install" ended at its weight share, about 8%, it sat
		# there as the smallest entry and pinned the bar at 8% for the whole
		# read no matter how far the later stages got.
		#
		# The key still names the current stage, because the label beside the
		# bar is read as much as the bar is. The previous stage is simply
		# retired as we leave it, so the dictionary holds exactly one entry and
		# the minimum IS the position. _read_end still sweeps OPEN_STAGES, so
		# nothing is left behind if a read ends mid-stage.
		var stage_now := str(_read_model["stage"])
		if _bar_stage != "" and _bar_stage != stage_now:
			jobs.clear_activity(_bar_stage)
		_bar_stage = stage_now
		jobs.set_activity(stage_now, int(round(pos * 1000.0)), 1000)
	if job_bar != null and is_instance_valid(job_bar):
		job_bar.indeterminate = false


static func _clock(ms: int) -> String:
	var s := int(ms / 1000)
	if s < 60:
		return "%ds" % s
	return "%d:%02d" % [int(s / 60), s % 60]


# 268587 -> "268,587". Long numbers are the point of the walk's readout and
# unreadable without the separators.
static func _grouped(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if n < 0 else out

# The other end of every jobs.changed emit. Timed here as well as at the emit
# side so a recording can separate "the bar is updated too often" from "updating
# the bar is expensive": the job bucket counts the calls, this one counts the
# Control writes they cause.
func _refresh_job_bar() -> void:
	if jobs == null or job_row == null: return
	HighpolyProfile.begin("job bar: panel redraw")
	_refresh_job_bar_body()
	HighpolyProfile.end("job bar: panel redraw")


func _refresh_job_bar_body() -> void:
	var busy: bool = jobs.busy()
	job_row.visible = busy
	if check_btn: check_btn.visible = not busy
	if not busy: return
	# the journal's "did the user see progress" counter: only a VALUE CHANGE
	# counts - redrawing the same percentage is not progress to a human
	if absf(job_bar.value - jobs.ratio()) > 0.0005:
		BJournal.bar_tick()
	job_bar.value = jobs.ratio()
	# THE BAR'S OWN CURVE, once a second. "It reads zero for most of the load"
	# is a report nobody could check: the journal counts value CHANGES, which
	# says the bar moved but not what it moved to, and a bar pinned near zero
	# by a stale entry still ticks. This prints what a user is looking at, so
	# the claim becomes a series of numbers.
	var _now := Time.get_ticks_msec()
	if _now - _bar_logged_ms >= 1000:
		_bar_logged_ms = _now
		Log.info("job bar: %3d%%  %s"
			% [int(round(jobs.ratio() * 100.0)), jobs.active_label()])
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

# ---------------------------------------------------------------------------
# TWO HOMES: the floating window, and a tab beside Inspector / Signals / Groups.
#
# Closing the window used to just hide it, which threw the panel away until you
# remembered the toolbar button. Docking instead keeps it to hand where every
# other editor panel lives, and the toolbar button pops it back out to float.
#
# The panel itself never rebuilds. dock_root is one Control holding the whole
# UI, and both homes are the same reparent - so the open reader, the built
# overlay, the job queue and every toggle carry across untouched. That is the
# same property the soft-reopen path depends on, for the same reason.
# Right-hand column, lower half — the strip Inspector, Signals and Groups share.
#
# Which home the panel is in persists through _get_window_layout, the slice of
# the editor's own layout file Godot hands plugins. Not project metadata: the
# window rect and whether it was open already live there, and two places
# remembering the same thing is how they end up disagreeing.
const DOCK_SLOT := EditorPlugin.DOCK_SLOT_RIGHT_BL


func _is_docked() -> bool:
	return dock_root != null and is_instance_valid(dock_root) \
		and win != null and dock_root.get_parent() != win


# Move the panel into the editor's dock column. Idempotent.
func _dock_panel() -> void:
	if dock_root == null or not is_instance_valid(dock_root) or _is_docked():
		return
	if win != null and win.visible:
		_win_rect = Rect2i(win.position, win.size)
	if win != null:
		win.hide()
		if dock_root.get_parent() == win:
			win.remove_child(dock_root)
	# A DOCK IS A CONTAINER AND A WINDOW IS NOT, and this panel was built for the
	# window. Inside a Window the FULL_RECT anchors set at creation do the
	# sizing; inside a TabContainer anchors are ignored and the container sizes
	# its child from the size flags instead - which were never set, because
	# nothing had ever put this Control in a Container. Both homes now get what
	# they need and neither disturbs the other: a Window ignores size flags
	# exactly as a Container ignores anchors.
	#
	# dock_root.name is already "High-Poly" from _enter_tree, and that name is
	# what the dock uses as the tab label.
	dock_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock_root.custom_minimum_size = Vector2(260, 220)
	add_control_to_dock(DOCK_SLOT, dock_root)
	# PAUSED WHILE DOCKED. The video is a backdrop, and a docked panel is on
	# screen for the whole session - the original reasoning for stopping the
	# decoder when the panel closes ("this plugin exists to buy back frame time,
	# not to spend it on its own scenery") applies more here, not less.
	if video: video.paused = true
	_stop_boot()


# Take it back out of the dock and float it.
func _float_panel() -> void:
	if dock_root == null or not is_instance_valid(dock_root) or win == null:
		return
	if _is_docked():
		remove_control_from_docks(dock_root)
	if dock_root.get_parent() != win:
		if dock_root.get_parent() != null:
			dock_root.get_parent().remove_child(dock_root)
		win.add_child(dock_root)


func _set_tools_visible(on: bool) -> void:
	if win == null: return
	if not on:
		# CLOSING DOCKS IT rather than hiding it. Nothing is lost and nothing is
		# rebuilt; the panel is simply somewhere else.
		_dock_panel()
		return
	_float_panel()
	if video:
		if video.is_playing(): video.paused = false
		else: video.play()
	if _win_rect.size.x > 0 and _usable(_win_rect):
		win.position = _win_rect.position
		win.size = _win_rect.size
	else:
		# NOT popup_centered(): popup() force-sets transient, and the OS
		# refuses a transient window that is always-on-top ("Windows with the
		# 'on top' can't become transient", once per open). Centre by hand.
		win.size = WIN_SIZE
		var pw := EditorInterface.get_base_control().get_window()
		win.position = pw.position + (pw.size - win.size) / 2
	win.show()
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
	# The X docks it, same as untoggling the button. _dock_panel records the
	# window rect on the way out, so floating it again lands where you left it.
	_dock_panel()

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
	cfg.set_value("HighPoly", "docked", _is_docked())

func _set_window_layout(cfg: ConfigFile) -> void:
	_win_rect = cfg.get_value("HighPoly", "win_rect", Rect2i())
	# THE PANEL ALWAYS LIVES SOMEWHERE NOW: floating, or a tab in the dock
	# column. There is no third state where it exists and cannot be seen, which
	# is what "closed" used to mean and what made people hunt for the button.
	if bool(cfg.get_value("HighPoly", "docked", false)):
		_dock_panel.call_deferred()
	elif tools_btn and bool(cfg.get_value("HighPoly", "win_open", false)):
		tools_btn.button_pressed = true      # fires _set_tools_visible
	else:
		# Neither recorded: a layout written before the panel could dock, or a
		# first run. Docked is the safe home - visible, out of the way, and one
		# click from floating.
		_dock_panel.call_deferred()

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
var _storage_timer: Timer


# Ask for a re-measure "soon". Several transfers finish within a second of each
# other at the end of a map load; this collapses them into one walk.
func _storage_dirty() -> void:
	if _storage_timer == null:
		_storage_timer = Timer.new()
		_storage_timer.one_shot = true
		_storage_timer.wait_time = 2.0
		_storage_timer.timeout.connect(_refresh_storage)
		dock.add_child(_storage_timer)
	_storage_timer.start()


func _refresh_storage() -> void:
	_storage_gen += 1
	var gen := _storage_gen
	_reload_purge_options()
	storage_lbl.text = "Measuring disk usage…"
	var props: Array = await mapctx.dir_usage_async(MapContextScript.PROPS_CACHE)
	if gen != _storage_gen: return
	var maps_bytes := 0
	var nmaps := 0
	for m in MapContextScript.cached_maps():
		var u: Array = await mapctx.dir_usage_async("%s/%s" % [MapContextScript.CACHE, m])
		if gen != _storage_gen: return
		maps_bytes += int(u[1])
		nmaps += 1
	var total := int(props[1]) + maps_bytes
	# One plain sentence, then a line per thing, in the words a map builder would
	# use. The old single line packed all of this into one dense string that
	# never actually said what any of it was.
	var lines := ["Using %s on your PC" % _human_size(total), ""]
	lines.append("  Object meshes worked out so far: %s  (%s)"
		% [_fmt_n(int(props[0])), _human_size(int(props[1]))])
	lines.append("  Levels read from your game: %s  (%s)"
		% [_fmt_n(nmaps), _human_size(maps_bytes)])
	storage_lbl.text = "\n".join(lines)

func _reload_purge_options() -> void:
	if purge_maps == null: return
	var maps: Array = MapContextScript.cached_maps()
	purge_maps.clear()
	for m in maps:
		purge_maps.add_item(str(m))
	# AN EMPTY DROPDOWN NEXT TO A GREYED-OUT DELETE reads as something broken.
	# It is the ordinary state before a level has been read, so it should say so
	# rather than leave the user looking for what they did wrong.
	if maps.is_empty():
		purge_maps.add_item("Nothing read yet")
	purge_maps.disabled = maps.is_empty()
	purge_btn.disabled = maps.is_empty()

func _purge_selected() -> void:
	if purge_maps.selected < 0: return
	var map := purge_maps.get_item_text(purge_maps.selected)
	purge_btn.disabled = true
	storage_lbl.text = "Sizing a %s purge…" % map
	# Nothing is shared with a model library any more, so there is no set of
	# objects to hand over or hold back: a level owns the work done for it.
	var info: Dictionary = await mapctx.purge_info(map, {}, {})
	purge_btn.disabled = false
	var open_map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var freed := int(info.get("map_bytes", 0)) + int(info.get("excl_bytes", 0)) 		+ int(info.get("hp_bytes", 0))
	var excl_n: int = (info.get("excl", []) as Array).size()
	var txt := "Clear the work done for %s?\n\nFrees about %s: the map's own data (%s) plus %d objects only %s uses (%s)." % [
		map, _human_size(freed), _human_size(int(info.get("map_bytes", 0))),
		excl_n, map, _human_size(int(info.get("excl_bytes", 0)))]
	var hp_n: int = (info.get("hp_excl", []) as Array).size()
	if hp_n > 0:
		txt += "
Also frees %d high-poly model(s) only %s uses (%s)." % [
			hp_n, map, _human_size(int(info.get("hp_bytes", 0)))]
	if int(info.get("shared", 0)) > 0:
		txt += "\n%d object(s) are shared with other cached maps and are kept, so deleting this one never breaks another." % int(info.get("shared", 0))
	if open_map == map:
		txt += "\n\nThis is the map you have open, so the borrowed scenery around it will disappear."
	txt += "\n\nThis is always safe: it is all rebuilt from your game install when you need it again."
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = txt
	dlg.ok_button_text = "Delete"
	dlg.confirmed.connect(func():
		_do_purge(map, info, open_map == map)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	EditorInterface.popup_dialog_centered(dlg)

# Reset: clear every cache, drop what is held in memory, panel back to defaults.
#
# THE OLD WORDING DESCRIBED A PLUGIN THAT NO LONGER EXISTS. It said this deletes
# "all downloaded data" and that "everything here downloads again on demand".
# Nothing downloads. Since 2.0 every model, texture and heightfield is read from
# the player's own Battlefield 6 install, so what this clears is CACHES - work
# already done, kept so it need not be done twice.
#
# That is more than pedantry: someone pressed Reset, watched the high-poly props
# come straight back, and reasonably asked what Reset had actually done. The
# honest answer was "deleted some files you were not using at that moment",
# because the open reader - the mounted archives, the parsed meshes, the decoded
# textures - survived untouched in memory and served the rebuild from RAM.
func _reset_everything() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = ("Clear everything this plugin has cached and reset the "
		+ "panel?\n\nIt re-reads from your Battlefield 6 install afterwards, so "
		+ "nothing is lost — the next map you open simply takes its full time "
		+ "again instead of being served from disk.\n\nCleared: the decoded "
		+ "terrain and scenery, the geometry and thumbnail caches, the archive "
		+ "index, and whatever is currently held in memory — so this really is "
		+ "a cold start.\n\nYour own map is not touched. The Low-Poly pieces "
		+ "you build and export with are exactly as you left them.")
	dlg.ok_button_text = "Clear caches and reset"
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
	storage_lbl.text = "Deleting everything…"
	# capture BEFORE the delete: afterwards there are no downloaded maps to list,
	# and their saved toggle state would be stranded describing data that is gone
	var maps_before: Array = MapContextScript.cached_maps()
	var freed: int = await mapctx.purge_everything()
	# both stores are gone: forget the map-context index and every icon rendered
	# from it, or the library keeps offering stand-ins for deleted files
	HighpolyStore.ctx_scan(true)
	if previews: previews.rescan_context()

	# AND DROP THE OPEN READER, which is what made Reset a half-measure.
	#
	# It deleted caches on disk and left the game source mounted in memory -
	# archives, parsed meshes, resolved materials, decoded textures, all of it.
	# So the very next rebuild served everything from RAM and the props came
	# back instantly, which is not what anyone pressing "reset everything"
	# expects to see, and is why it looked as though nothing had happened.
	#
	# Released rather than merely dropped: release_caches() is what actually
	# frees the textures and materials. Then the references go, so the next
	# thing that needs the install opens it again from scratch - which is the
	# cold start this button is for.
	if mapctx != null and mapctx.game_source != null:
		if mapctx.game_source.has_method("release_caches"):
			mapctx.game_source.release_caches()
		mapctx.game_source = null
	LibScript.game_source = null
	LightingScript.game_source = null
	HighpolyVitals.set_cache_probe(Callable())

	# --- panel back to defaults ---
	if mode_btn: mode_btn.select(mode_btn.get_item_index(MODE_SDK))
	if previews: previews.tier = HighpolyLib.Tier.LOW
	_refresh_gates()      # back on the rung that downloads nothing: grey them again
	for b in [mapctx_on, mapctx_objects, mapctx_fx, mapctx_light, col_chk,
			iso_chk, ovr_chk]:
		if b: b.set_pressed_no_signal(false)
	if mapctx_backdrop: mapctx_backdrop.set_pressed_no_signal(false)
	if mapctx_water: mapctx_water.set_pressed_no_signal(false)
	MapContextScript.show_fx_cards = false
	_lighting_subs_enabled(false)
	if mapctx_variant_row: mapctx_variant_row.visible = false
	_gm_key = ""
	_gm_heal_off = ""
	if ovr_chk: ovr_chk.text = _override_label()
	_override.clear()
	# forget the per-map saved state too, or reopening a map restores toggles
	# describing data that no longer exists
	var es := EditorInterface.get_editor_settings()
	for m in maps_before:
		es.set_project_metadata("highpoly_mapctx", str(m), {})
	# is_instance_valid, not `!= null`: the reset above yields, and a scene closed
	# while it ran leaves `r` non-null and freed, which a typed `root: Node`
	# parameter rejects at the call.
	var open_map: String = mapctx.map_of(r) if is_instance_valid(r) else ""
	if open_map != "":
		es.set_project_metadata("highpoly_mapctx", open_map, {})
	MapContextScript.mesh_cache_enabled = true
	es.set_project_metadata("highpoly_mapctx", "_mesh_cache", true)
	lbl.text = "Reset. %s freed. It is all worked out again the next time you open a map." % _human_size(freed)
	_refresh_storage()


func _do_purge(map: String, info: Dictionary, was_open: bool) -> void:
	if was_open:
		# drop the live overlay FIRST: cancels any running props build, detaches
		# the scatter and frees _MAP_CONTEXT, so nothing
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
		await _apply_scene()
	lbl.text = "%s purged. About %s freed; it rebuilds from your game install on demand." % [map,
		_human_size(int(info.get("map_bytes", 0)) + int(info.get("excl_bytes", 0)))]
	_refresh_storage()

# ---------- plugin self-update ----------
# `announce` makes the outcome visible on the status line - the manual
# button's press must say something either way, where the silent startup
# check only reveals the update button when there is one.
func _check_plugin_update(announce := false) -> void:
	HighpolyUpdater.check_plugin_update(dock, func(new_version: String, _notes: String):
		if new_version != "" and is_instance_valid(update_btn):
			update_btn.text = "Update Plugin to v%s" % new_version
			update_btn.tooltip_text = "A newer version of this plugin is available. One click installs it; restart the editor afterwards."
			update_btn.visible = true
		if announce and is_instance_valid(lbl):
			lbl.text = ("v%s is available - press Update Plugin above" % new_version) \
				if new_version != "" \
				else "Plugin is up to date (v%s)" % HighpolyUpdater.plugin_version())

func _do_plugin_update() -> void:
	update_btn.disabled = true
	# the updater fetches into memory, so there's no byte stream to track — show
	# an indeterminate row anyway, so this download isn't the one silent one
	# the updater fetches into memory, so there is no byte stream to track — it
	# still takes a turn in the queue so it cannot race a model download
	var token: int = await jobs.acquire("Plugin update")
	# RELEASE OUR OWN LOCK FIRST. The panel's video player holds waves.ogv
	# open, and Windows will not overwrite an open file - the updater's
	# hash-skip already avoids rewriting an unchanged video, but a release
	# that DOES change it must not fail on our own player.
	var _vid_stream = null
	if video != null and is_instance_valid(video):
		_vid_stream = video.stream
		video.stop()
		video.stream = null
	var ok: bool = await HighpolyUpdater.update_plugin(dock, func(msg: String):
		lbl.text = msg
		Log.info(msg))
	if _vid_stream != null and video != null and is_instance_valid(video):
		video.stream = _vid_stream
		video.play()
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
	if mapctx_roads:
		mapctx_roads.set_pressed_no_signal(false)
		if mapctx: mapctx.set_roads_shown(null, false)
	if mapctx_light: mapctx_light.set_pressed_no_signal(false)
	if mapctx_fx:
		mapctx_fx.set_pressed_no_signal(false)
		MapContextScript.show_fx_cards = false   # keep the card layer in step
	_lighting_subs_enabled(false)
	if mapctx_variant_row: mapctx_variant_row.visible = false
	_gm_key = ""
	_gm_heal_off = ""
	if col_chk: col_chk.set_pressed_no_signal(false)
	if iso_chk:
		iso_chk.set_pressed_no_signal(false)
		iso_chk.disabled = true
	# The remembered visibility is keyed by node path, and those paths belong to
	# the scene that just closed, so that one is put back before we let go of it.
	# The clearing has to happen even when there is nothing left to restore, or
	# the next scene inherits bookkeeping belonging to a closed one.
	#
	# PASS null RATHER THAN A FREED NODE. These take `root: Node`, and GDScript
	# checks a typed argument at the CALL, before the function body runs — so
	# handing one a freed Object raises "argument 1 (previously freed) is not a
	# subclass of the expected argument class" and the call never happens at all.
	# The comment that used to sit here claimed the opposite: that each of these
	# guards its own restore on `root != null`, which a freed Object does not
	# pass. That is true of the guard and irrelevant, because the guard is
	# downstream of a check that already rejected the call. A user's editor log
	# showed exactly that, three times in a row, on a scene swap.
	var alive: Node = old if (old != null and is_instance_valid(old)) else null
	ShapeViz.release(alive)
	PlacedCull.release(alive)  # a saved property: don't leave it on a closed scene
	SdkHide.restore_all(alive)
	# The one thing that SHOULD carry across a swap: the pieces you placed in the
	# newly-active scene start culled to wherever the Range slider currently sits.
	# The cull was released from the outgoing scene but never applied to the
	# incoming one, so after a swap the slider read as active while nothing in the
	# new scene was actually following it.
	if r != null and is_instance_valid(r):
		_reapply_placed_cull()
	if lbl and old != null: lbl.text = "Different map opened, so everything is back to Low-Poly"
	# fresh dock instance (editor start / plugin re-enable) — not a scene
	# switch: bring the overlay back the way this map had it
	if old == null and r != null and not _soft_applied:
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
	# ONE APPLY, ALWAYS. This used to build the terrain first, fetch the prop
	# GLBs, then apply again with objects on top - a two-phase dance whose only
	# purpose was to show something while a download ran. There is no download:
	# the scenery is read from the install, so the single apply below is the
	# whole of it.
	# SAY WHAT WAS ASKED FOR AND WHAT CAME BACK.
	#
	# "Extended Terrain sometimes does nothing" produced a log in which the SDK
	# terrain is hidden, twice, and nothing else is recorded at all: no build, no
	# stage, no failure. The toggle plainly fires, and everything after it is
	# silent, so the log cannot distinguish "the build was never reached" from
	# "the build ran and produced nothing". One line here settles that the next
	# time it happens instead of needing a reproduction.
	Log.info("Map context apply: terrain=%s objects=%s backdrop=%s water=%s tex=%d map=%s"
		% [str(on), str(objs), str(bd), str(wt), tex, map if map != "" else "<none>"])
	var _res: String = await _apply_with_placements(r, on, objs, tex, bd, wt)
	Log.info("Map context apply returned: %s" % (_res if _res != "" else "<empty>"))
	lbl.text = _res

# Contact shading, Shadows, Map lights and Interior light: the four options that
# only mean anything while Lighting is on.
#
# GREYED, NOT HIDDEN. They used to disappear, and a row that disappears drags
# every row beneath it upwards — so switching Lighting moved the rest of the
# panel under the user's cursor, and the next click could land on a control they
# were not aiming at. Greyed, they stay put and simply stop responding, and the
# panel keeps the same shape whatever is switched on.
#
# ONE FUNCTION because there were EIGHT places setting these four controls, and
# they had already drifted: two of them forgot Map lights entirely, so it stayed
# clickable after Lighting went off.
func _lighting_subs_enabled(on: bool) -> void:
	if mapctx_gi: mapctx_gi.disabled = not on
	if mapctx_shadows: mapctx_shadows.disabled = not on
	if mapctx_maplights: mapctx_maplights.disabled = not on
	if mapctx_fill: mapctx_fill.editable = on


# Is anything that draws the MAP switched on?
#
# Detail Mode skins the objects YOU placed and needs none of the map's own
# contents: no placement walk, no terrain composite. Map Context is the master
# switch for everything that does.
func _wants_map_layers() -> bool:
	# THE LAYERS THAT CONSUME PLACEMENT ROWS, and only those. Extended Terrain
	# itself is deliberately NOT in this list: the ground is the streaming
	# tree, the palette and the colour map, and its texture names resolve
	# through the partition catalogue that build_catalog makes regardless -
	# the walk's 38k rows feed props, skyline, lights and FX, none of which
	# terrain reads. The master chip used to be the last line here, which
	# made switching terrain on pay the ~50 s cold walk for data nothing
	# consumed (found by asking exactly that of the build journal). A layer
	# turned on later still gets its rows: every consumer runs
	# _ensure_placements_async first.
	if mapctx_objects != null and mapctx_objects.button_pressed:
		return true
	if mapctx_backdrop != null and mapctx_backdrop.button_pressed:
		return true
	if mapctx_water != null and mapctx_water.button_pressed:
		return true
	if mapctx_light != null and mapctx_light.button_pressed:
		return true
	return mapctx_fx != null and mapctx_fx.button_pressed


# Walk the level's placements if a map layer needs them and the open skipped it.
# On a worker, behind the same read panel the open uses, because it is ~49 s cold.
func _ensure_placements_async(gs) -> bool:
	# THE READ WORKER WAITS FOR THE SWAP TOO.
	#
	# Serialising the BUILD against the swap was not enough: backdrop still died
	# with build=0.0 s, i.e. while the build was still waiting its turn. What
	# else a geometry layer starts is this - the placement walk, 58,055 rows,
	# on a worker - and it is the one thing terrain never asks for, which is
	# exactly the layer that does not crash.
	if _swap_busy:
		await _await_flag("swapping placed objects",
			func(): return _swap_busy)
	var map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var ground := "%s/%s" % [HighpolyMapContext.CACHE, map]
	if gs == null or (gs.placements_ready and gs.surface_cache == ground):
		return gs != null
	# THE SAME GATE THE TERRAIN READ WORKER TAKES. Both paths reach
	# ensure_ground on this same directory, and only the terrain side was
	# serialised, so the two could composite the same ground on two threads at
	# once. See _read_worker_busy for the full account.
	if not await _await_flag("another layer's install read",
			func(): return _read_worker_busy):
		return gs != null
	# RE-ASKED AFTER THE WAIT, because the worker just queued ahead of this one
	# may have done exactly this work. This is where the duplicate build goes.
	if gs.placements_ready and gs.surface_cache == ground:
		return true
	_read_worker_busy = true
	# COLD IS ASKED, NOT ASSUMED. This passed `false` unconditionally, and
	# `cold` is the flag that shows the note explaining that a first read of a
	# map takes minutes and every read after it takes seconds. So the one path
	# where the wait is longest - Original map objects on a map never read
	# before - was the one path that explained nothing, and a user watching a
	# ten minute silence has no way to tell it apart from a hang.
	_read_begin(map, not _map_read_before(map))
	HighpolyVitals.crumb("walking the map's placements")
	var done := [false]
	var okv := [false]
	var tid := WorkerThreadPool.add_task(func() -> void:
		var relay := func(stage: String, d: int, t: int):
			_prog_relay = [stage, d, t]
		okv[0] = gs.ensure_placements(relay)
		# The ground too, on this same worker. map_data would otherwise composite
		# it on the main thread, which is a minute of frozen editor.
		gs.ensure_ground(ground, relay)
		done[0] = true, true, "bf6 placement walk")
	while not done[0]:
		if get_tree() == null:
			break
		if not _prog_relay.is_empty():
			_read_stage_set(str(_prog_relay[0]), int(_prog_relay[1]),
				int(_prog_relay[2]))
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	_prog_relay = []
	_read_end()
	HighpolyVitals.crumb("idle, nothing building")
	# RELEASED AFTER THE TASK IS JOINED, not when the loop above exits. The loop
	# also breaks when the tree goes away, and releasing there would let the
	# next read worker start while this one is still inside ensure_ground.
	_read_worker_busy = false
	return okv[0]


# Written by the walk worker, read by the frame pump. Same reasoning as the
# game source's own relay: a Label may not be touched off the main thread.
var _prog_relay: Array = []


func _mapctx_rebuild() -> void:
	# rebuild with current toggles, no re-download (e.g. terrain detail changed)
	if not mapctx_on.button_pressed: return
	var r := EditorInterface.get_edited_scene_root()
	if mapctx.map_of(r) == "": return
	# Which optional map data to mine. The light and FX layers have their own
	# buttons and apply() never saw them, so every apply mined 3,874 light
	# entities and 701 FX emitters whether or not anything would draw them.
	_mapctx_sync_wants()
	lbl.text = await _apply_with_placements(r, true, mapctx_objects.button_pressed,
		_mapctx_tex_mode(),
		mapctx_backdrop != null and mapctx_backdrop.button_pressed,
		mapctx_water != null and mapctx_water.button_pressed)


# THE ONLY WAY THE MAP CONTEXT IS APPLIED, so the placement walk cannot be
# skipped by a path that forgot to ask for it.
#
# The open stopped walking placements when no map layer was on, which is right -
# Detail Mode does not need the level's contents. But the on-demand walk was
# wired into ONE of the two callers that build, and the other one applied with
# an unwalked source: "0 prop groups, 0 skyline groups, 0 placements", and
# clicking Original map objects brought nothing in.
#
# Guarding each caller is what produced that bug, so there is one chokepoint now
# and both callers go through it. ensure_placements returns immediately when the
# walk has already run, so this costs nothing on the common path.
func _apply_with_placements(r: Node, on: bool, objs: bool, tex, bd: bool, wt: bool) -> String:
	# GATED ON WHAT CONSUMES THE WALK, which is the objects and the skyline.
	#
	# This read `if on`, and `on` is the flag the log prints as "terrain". A user
	# switching Original map objects on with the terrain off produced
	# "terrain=false objects=true", the guard never fired, and the build grouped
	# an empty row set into "0 prop groups, 0 skyline groups, 0 placements" -
	# the same failure this function was added to prevent, for a second time,
	# because I gated it on the wrong flag.
	#
	# objs and bd are the two layers built FROM walk rows. Nothing else needs
	# them, and ensure_placements returns immediately once the walk has run.
	# THE CATALOGUE WAIT THAT USED TO BE HERE IS GONE.
	#
	# It was the first fix for the crash inside terrain(): the sweep grew
	# src.ebx and src.res while the build scanned them, so the build waited for
	# the sweep to finish. Correct, and the wrong price - switching Extended
	# Terrain on could sit there for up to a minute and a half waiting for
	# something the terrain does not use and whose name means nothing to anyone
	# ("the placeable catalogue" reads as "object previews").
	#
	# BF6Source.mount_rest now builds into private copies and publishes them in
	# one assignment, so there is no half-grown mount for anything to trip over
	# and nothing to wait for. See the note there.
	if (objs or bd) and mapctx != null and mapctx.game_source != null \
			and not mapctx.game_source.placements_ready:
		await _ensure_placements_async(mapctx.game_source)
	# THE MAP DATA TOO, for the same reason and with the same gate apply uses
	# (need_data = terrain or objects or backdrop or water). apply() calls
	# map_data on the MAIN thread, and the first ask decodes the heightfield,
	# drapes the roads and mines any wanted section - the 35-44 s freezes the
	# stall table blamed on "idle" (task #91). Mining it here on a worker turns
	# apply's own call into a dictionary return. The want dict must be the one
	# apply will pass, or apply's ask still lazily fills the difference on the
	# main thread - which is why the wants are synced first.
	if (on or objs or bd or wt) and mapctx != null and mapctx.game_source != null:
		_mapctx_sync_wants()
		await _ensure_mapdata_async(mapctx.game_source,
			{"lights": mapctx.want_lights, "fx": mapctx.want_fx, "water": wt})
	return mapctx.apply(r, on, objs, tex, bd, wt)


# ONE READ WORKER AT A TIME, whichever layer asked for it.
#
# This used to gate only map_data against map_data, and that is not the pair
# that collides. The two read workers are:
#
#   _ensure_mapdata_async     (Extended terrain) -> ensure_ground, then map_data
#   _ensure_placements_async  (Objects/backdrop) -> ensure_placements, then
#                                                   ensure_ground
#
# BOTH end up in ensure_ground on the same cache directory, and only the first
# was gated - so terrain could be part-way through baking the ground while the
# objects worker started baking the SAME ground on another thread.
#
# ensure_ground's own guard does not stop it either, because it is check-then-
# act with the two halves set at opposite ends:
#
#     if surface_cache == cache_dir and _surface_tried == cache_dir: return
#     surface_cache = cache_dir          # set at the START
#     ... 30-80 s of compositing ...
#     _surface_tried = cache_dir         # set at the END
#
# A second caller arriving in that window sees surface_cache already matching,
# _surface_tried not yet set, and falls straight through into a second
# concurrent build. ensure_placements has the same shape around
# placements_ready, with walk.rows / walk.ents / walk.by_name as the shared
# state two walks would then write at once.
#
# It is visible in the phase table of the one backdrop run that survived, which
# lists "terrain surface" TWICE, 33.2 s and 31.6 s - the same ground built
# twice over. So serialising is not only the safe thing, it gives that time
# back: the second caller now finds the guard satisfied and skips the work.
#
# Named for what it means rather than what it started as.
# A WAIT THAT CAN SAY WHY IT IS WAITING.
#
# Six loops in this file park on a boolean with no timeout and no message, so a
# flag left set by an early return or an unfinished worker hangs the UI on its
# last label - "Building the map objects..." forever, with nothing in the log.
# That is indistinguishable from a button that did nothing.
#
# Returns true if the flag cleared, false if the tree went away. Never gives up
# on its own: whether waiting is still correct depends on the caller, and
# guessing wrong here would start a second builder while the first is live,
# which is the crash class the flags exist to prevent.
func _await_flag(name: String, is_set: Callable) -> bool:
	if not is_set.call():
		return true
	var t0 := Time.get_ticks_msec()
	var said := 0
	while is_set.call():
		if get_tree() == null:
			return false
		var waited := Time.get_ticks_msec() - t0
		# said == 0 makes the second test `waited >= 0`, which is true on the
		# very first frame - this warned every frame until I read it back.
		if (said == 0 and waited >= 8000) or (said > 0 and waited >= 30000 * said):
			said += 1
			Log.warn(("Still waiting on '%s' after %.0f s. The layer "
				+ "you switched on cannot start until it clears; if this "
				+ "never finishes it is a stuck flag, not slow work.")
				% [name, waited / 1000.0])
		await get_tree().process_frame
	return true


var _read_worker_busy := false

func _ensure_mapdata_async(gs, want: Dictionary) -> void:
	if gs == null or mapctx == null:
		return
	# Same rule as _ensure_placements_async: no read worker while the scene is
	# being swapped.
	if _swap_busy:
		while _swap_busy and get_tree() != null:
			await get_tree().process_frame
	var map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	if map == "":
		return
	var dir := "%s/%s" % [HighpolyMapContext.CACHE, map]
	while _read_worker_busy:
		if get_tree() == null:
			return
		await get_tree().process_frame
	if not gs.map_data_would_build(dir, want):
		return
	_read_worker_busy = true
	_read_begin(map, not _map_read_before(map))
	HighpolyVitals.crumb("reading %s: terrain, roads and map layers" % map)
	var done := [false]
	var tid := WorkerThreadPool.add_task(func() -> void:
		var relay := func(stage: String, d: int, t: int):
			_prog_relay = [stage, d, t]
		# ensure_ground first when the open skipped it: map_data's surface
		# re-ask would otherwise composite the splat inside this same task
		# with no per-stage progress.
		gs.ensure_ground(dir, relay)
		gs.map_data(dir, want)
		done[0] = true, true, "bf6 map data mine")
	while not done[0]:
		if get_tree() == null:
			break
		if not _prog_relay.is_empty():
			_read_stage_set(str(_prog_relay[0]), int(_prog_relay[1]),
				int(_prog_relay[2]))
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	_prog_relay = []
	_read_end()
	HighpolyVitals.crumb("idle, nothing building")
	_read_worker_busy = false



# The dock owns these two buttons; the map context cannot see them. Kept in one
# place so a new caller cannot forget half of it.
func _mapctx_sync_wants() -> void:
	if mapctx == null:
		return
	mapctx.want_lights = mapctx_maplights != null and mapctx_maplights.button_pressed
	mapctx.want_fx = mapctx_fx != null and mapctx_fx.button_pressed

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
		_lighting_subs_enabled(false)
		lbl.text = "No lighting data for this scene" if map != "" else "Open an MP_… level scene first"
		return
	lbl.text = LightingScript.apply(r, map,
			mapctx_gi.button_pressed if mapctx_gi else true,
			mapctx_shadows.button_pressed if mapctx_shadows else true)
	if mapctx_maplights and mapctx_maplights.button_pressed:
		lbl.text += " | " + await LightingScript.set_map_lights(r, true, map,
			_lane(LIGHTS_JOB))

# grey the checkbox out when the open scene has no lighting data (called from
# the dock's 0.5 s timer — cheap: one dictionary lookup)
func _lighting_guard() -> void:
	# Video memory used to ride along with the Lighting sub-controls, which meant
	# it was INVISIBLE until somebody switched Lighting on. It is a scenery
	# setting, nothing to do with lighting, and it is the one control the
	# out-of-memory warning tells people to change — so it was pointing them at
	# something they could not see. It is simply always there now.
	if mapctx_light == null: return
	var map: String = mapctx.map_of(EditorInterface.get_edited_scene_root())
	var ok := map != "" and LightingScript.has_data(map)
	if mapctx_light.disabled == (not ok): return
	mapctx_light.disabled = not ok
	# Say so ON THE CHIP. The status-line message for this lives in the click
	# handler, which a disabled chip never reaches.
	mapctx_light.tooltip_text = LIGHTING_TIP if ok else LIGHTING_TIP_NONE
	if not ok and mapctx_light.button_pressed:
		mapctx_light.set_pressed_no_signal(false)
		_lighting_subs_enabled(false)

# one-time baked-in performance settings: multi-threaded rendering (zero
# visual impact) + 2048 shadow atlas (negligible under the soft overcast sun).
# Applied ONCE per project — a user who reverts a setting is respected.
func _auto_perf_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	# The key is VERSIONED. The old one gated the whole function, so anyone who
	# had already run it would never receive a setting added later — the change
	# would ship and apply to new users only, which is the kind of thing that
	# gets diagnosed as "it works on my machine".
	if bool(es.get_project_metadata("highpoly_mapctx", "_perf_applied2", false)):
		return
	es.set_project_metadata("highpoly_mapctx", "_perf_applied2", true)
	var changed := false

	# MESH LOD. Godot selects a LOD when its geometric error would project to
	# `threshold_pixels` on screen. The default is 1.0 — LODs only engage once
	# their error is a single pixel, which is as conservative as the setting
	# goes. Switch distance scales inversely, so 4.0 makes every LOD engage at
	# a quarter of its current distance. Verified through the engine source:
	# renderer_viewport.cpp:317, renderer_scene_render_rd.cpp:1368,
	# mesh_storage.h:479.
	#
	# Set to 4.0 rather than the 8.0 the formula would also allow, because the
	# mechanism is verified and the VISUAL cost is not: the bench harness times
	# the reader, it does not yet measure frame rate or draw calls, so nobody
	# has looked at the popping this introduces on real props. 4.0 is what I
	# would defend without that measurement; raise it once there is one.
	if float(ProjectSettings.get_setting(
			"rendering/mesh_lod/lod_change/threshold_pixels", 1.0)) < 4.0:
		ProjectSettings.set_setting(
				"rendering/mesh_lod/lod_change/threshold_pixels", 4.0)
		changed = true

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
		banner.text = "Performance settings applied (mesh LOD distance, multi-threaded rendering, shadow atlas). Restart the editor to activate them."
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
	# THE MAP'S OWN LAYERS, when there is no mined mode file.
	#
	# This asked HighpolyGamemode.modes(), which reads gamemode_markers.json -
	# written by a miner that no longer exists. The list came back empty on
	# every map, so `show` was always false and the whole row was HIDDEN. Not
	# greyed out, not empty: absent. Which is why the game mode could not be
	# selected at all.
	#
	# The layers are discovered from the subworlds the placements came out of,
	# so the map can list its own: winter_event, rush, domination, sabotage and
	# the rest. When the marker file does come back it wins, because it also
	# carries the spawns and objectives this cannot.
	var mds: Array = HighpolyGamemode.modes(mapctx.map_of(r)) if objects_on else []
	var mined := not mds.is_empty()
	if objects_on and mds.is_empty():
		mds = mapctx.available_layers()
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
		# mined modes get the name people use ("Team Deathmatch"); the layer-name
		# fallback is left alone, because those ARE the layer's own spelling and
		# set_variant_layers matches on it
		mapctx_variant.add_item(HighpolyGamemode.pretty(str(m)) if mined else str(m))
	for i in range(mapctx_variant.item_count):
		if mapctx_variant.get_item_text(i) == cur:
			mapctx_variant.select(i)
			break
	# the row was just repopulated, so the cached key and the "cannot build"
	# latch both belong to the previous map's list
	_gm_key = HighpolyGamemode.key_for(mapctx.map_of(r), r,
		mapctx_variant.get_item_text(mapctx_variant.selected)) \
		if mapctx_variant.selected > 0 else ""
	_gm_heal_off = ""

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
		# defaults FALSE on read, like every other layer chip: a saved state from
		# before this chip existed restores with the streets off, same as any
		# layer you have not asked for.
		"roads": mapctx_roads.button_pressed if mapctx_roads else false,
		"grass": mapctx_grass.button_pressed if mapctx_grass else false,
		"range": mapctx_range.value if mapctx_range else 800.0,
		"maptile": false,      # the SDK plugin owns the ground texture now
		"light": mapctx_light.button_pressed if mapctx_light else false,
		"gi": mapctx_gi.button_pressed if mapctx_gi else true,
		"shadows": mapctx_shadows.button_pressed if mapctx_shadows else true,
		"maplights": mapctx_maplights.button_pressed if mapctx_maplights else false,
		"proplight": prop_light_on.button_pressed if prop_light_on else false,
		"fill": mapctx_fill.value if mapctx_fill else 22.0,
		"photo": mapctx_photo.value if mapctx_photo else 75.0,
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
# checks (registry refresh + GLB mtime vs sidecar), i.e. "Check for updates"
# semantics without the clicks.
# The SDK has its own map-texture decal (3D toolbar -> Download/Apply Texture)
# and it SAVES into the level. When it's there, ours stands down so the ground
# isn't darkened twice — say so on the control instead of leaving a checkbox that
# looks broken. Also warn about the one real difference: theirs projects onto
# everything, high-poly models included.
func _restore_mapctx_state() -> void:
	var r := EditorInterface.get_edited_scene_root()
	# A SOFT REOPEN LEFT EVERYTHING STANDING. The sweep below exists because an
	# ordinary plugin reload orphans our owner=null overlays, and there is nothing
	# orphaned here: the same map context node, the same FX, the same lighting rig,
	# still owned by the service that built them and handed across intact. Sweeping
	# them would destroy exactly what the soft reopen exists to keep.
	var soft := _soft_restore
	_soft_restore = false
	if r != null and not soft:
		# plugin reloads orphan our owner=null overlay nodes ("FX won't
		# despawn") — sweep them all before restoring the saved state
		HighpolyFx.clear(r)
		HighpolyGamemode.clear(r)
		LightingScript.clear(r)
	var map: String = mapctx.map_of(r)
	if map == "": return
	# A BOOT STARTS CLEAN. Godot reopens whatever scene was last edited, and
	# restoring saved layers there began a full build immediately - before the
	# user had chosen anything - so switching to the scene they actually wanted
	# fought a build already in flight and the editor locked up hard.
	#
	# The restore now only re-syncs the CHIPS to an overlay that is ALREADY
	# BUILT. That is the soft-reopen case (a plugin reload or the cold swap,
	# where the owner=null overlay nodes survive in the scene and the chips
	# would otherwise read "off" over visible terrain). A real boot has no
	# overlay, so everything stays off and nothing is applied until asked.
	# The saved entry is left alone rather than cleared: nothing else reads it,
	# and the next deliberate toggle rewrites it anyway.
	#
	# EXCEPT AFTER A SWAP THAT CHANGED WHAT BUILDS THE SCENERY. The standing
	# overlay's materials and meshes came out of the code the swap just
	# replaced, so re-syncing chips to it shows the OLD look and reads as the
	# update doing nothing (the truckpickup wheels stayed shredded through the
	# very update that fixed them). Tear the stale overlay down first; the
	# restore below then rebuilds it through the normal path, with the new
	# code and fresh material caches. One rebuild per code-that-builds update,
	# only when scenery is actually standing.
	var _stale_swap := _swap_impact != "" and _swap_impact != "code" \
		and _swap_impact != "none"
	_swap_impact = ""
	if _stale_swap and r.get_node_or_null(HighpolyMapContext.NODE) != null \
			and mapctx != null:
		Log.info("Rebuilding the map context: the update replaced the code "
			+ "that built what is on screen.")
		mapctx.apply(r, false, false, false)
	elif r.get_node_or_null(HighpolyMapContext.NODE) == null:
		return
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
	# Pushed into the map context by hand: set_pressed_no_signal skips the
	# handler, so without this the chip and the built node could disagree.
	# ROADS ARE ALWAYS SHOWN NOW, and this has to be pushed rather than left to
	# the next build. Visibility is applied when the Roads node is PLACED
	# ((_rd as Node3D).visible = _show_roads), so a scene built while the old
	# chip was off keeps a hidden node forever - and "Check for updates" swaps
	# the scripts without rebuilding anything, so the change appeared to do
	# nothing at all. Reported by the user as "the decals did not get projected
	# onto the terrain": they were built, and hidden.
	#
	# The saved "roads" key is deliberately ignored: every existing saved state
	# carries the chip's old default of false, and honouring it would keep them
	# hidden for everyone who ever used the chip.
	if mapctx:
		mapctx.set_roads_shown(EditorInterface.get_edited_scene_root(), true)
	# set_pressed_no_signal skips the handler, so the want flag is set by hand;
	# the terrain build reads it when the kits come up. Defaults OFF, including
	# for saved states written before the chip existed.
	if mapctx_grass:
		var _gr_on := bool(d.get("grass", false))
		mapctx_grass.set_pressed_no_signal(_gr_on)
		if mapctx: mapctx.set_grass(_gr_on)
	if mapctx_gi: mapctx_gi.set_pressed_no_signal(bool(d.get("gi", true)))
	if mapctx_shadows: mapctx_shadows.set_pressed_no_signal(bool(d.get("shadows", true)))
	if mapctx_maplights: mapctx_maplights.set_pressed_no_signal(bool(d.get("maplights", false)))
	# set_pressed_no_signal SKIPS the handler, so the switch has to be applied by
	# hand or the statics and the chip disagree. That is what left a rebooted
	# scene showing lit fixtures under a chip that read "off".
	if prop_light_on:
		var _pl := bool(d.get("proplight", false))
		prop_light_on.set_pressed_no_signal(_pl)
		_set_prop_lighting(_pl)
	# set_pressed_no_signal skips the handler, so the card layer has to be told
	# separately — otherwise a restore leaves the statics saying "off" while the
	# chip reads on (or vice versa) and the next build guesses wrong.
	if mapctx_fx:
		MapContextScript.show_fx_cards = bool(d.get("fx", false))
	if mapctx_fx and bool(d.get("fx", false)):
		mapctx_fx.set_pressed_no_signal(true)
		mapctx.set_fx_cards_shown(r, true)
		lbl.text = await HighpolyFx.apply(r, map, true, _lane(FX_JOB),
			mapctx.game_source)
	# The FX apply above yields. A scene closed during it leaves `r` freed, and
	# everything below still hands it to typed `root: Node` parameters, which
	# fail at the call rather than inside.
	if not is_instance_valid(r):
		return
	if bool(d.get("light", false)) and mapctx_light != null:
		mapctx_light.set_pressed_no_signal(true)
		_lighting_subs_enabled(true)
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
	# the Ground photo strength, BEFORE the apply below builds the terrain
	# material, so the build binds the saved value rather than the default
	if mapctx_photo:
		var pv: float = float(d.get("photo", mapctx_photo.value))
		mapctx_photo.set_value_no_signal(pv)
		if mapctx_photo_val: mapctx_photo_val.text = "%d%%" % int(pv)
		MapContextScript.colormap_strength = clampf(pv / 100.0, 0.0, 1.0)
		MapContextScript.colormap_enabled = pv > 0.5
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
		if soft:
			# The controls now describe what is already on screen, which is all a
			# soft reopen needed. Building would tear down the scenery and put
			# back a copy of it.
			_refresh_gates()
			return
		_mode_changed()          # re-applies the library AND rebuilds the overlay
	elif not soft:
		_mapctx_changed()
	else:
		_refresh_gates()

# OPEN THE GAME SOURCE, wherever the need arises.
#
# This used to live inside _mapctx_changed, which made "have we read the
# install" a side effect of toggling Map Context. That was survivable while a
# download could supply models; with the download path gone the install is the
# ONLY source, so a user who switched to High-Poly without ever touching Map
# Context got a null game source, no asset id, and their props stayed the SDK's
# white proxies with nothing in the log to say why. Dropping a new prop in the
# same state did the same thing for the same reason.
#
# Returns true when a source for `map` is available afterwards.
#
# The one-open-at-a-time guard moved here with it, and now covers more callers
# than before: the mode dropdown and a dragged-in prop can both arrive while a
# Map Context toggle is still awaiting.
# Is a reader for THIS map already open? If so, make sure everything that reads
# one is pointed at it, and say yes.
#
# The three early exits in _ensure_game_source all used to just answer "yes,
# there is one" and return. That is true and not enough: the assignments that
# hand the reader to the object library and the lighting live at the BOTTOM of
# the function, so a caller that took an early exit left those pointing at
# whatever was there before - the previous map's reader, on a map switch. The
# library then answered every "what does this prop look like" from the wrong
# level.
func _adopt_open_source(map: String) -> bool:
	if mapctx == null or mapctx.game_source == null:
		return false
	if str(mapctx.game_source.level) != map.to_lower():
		return false
	LibScript.game_source = mapctx.game_source
	LightingScript.game_source = mapctx.game_source
	return true


func _ensure_game_source(map: String, gen: int = -1) -> bool:
	if map == "":
		return false
	if mapctx == null:
		return false
	if _adopt_open_source(map):
		return true
	if not HighpolyGameSource.available():
		# THE SILENCE WAS THE BUG REPORT. This returned false with nothing
		# written anywhere, the caller un-pressed the layer chip, and the only
		# trace was a panel label the user reads as "the map cannot be found".
		# It is also reachable while the GATE says detected, because the gate
		# and the reader used to discover the install two different ways.
		Log.warn("Map context: the reader cannot open your Battlefield 6 "
			+ "install, so %s was not read. %s" % [map, BF6Container.last_error])
		Log.warn("  the panel's own check may still say 'detected': set the "
			+ "folder at the top of the panel with Locate... and try again.")
		return false
	# NAMED, and it checks for a newer toggle each pass as before.
	while _gs_opening:
		if not await _await_flag("opening the game install",
				func(): return _gs_opening):
			return false
		if gen >= 0 and gen != _mapctx_gen:
			return false
		if _adopt_open_source(map):
			return true
		break
	if _adopt_open_source(map):
		return true
	_gs_opening = true
	lbl.text = "Reading %s from your Battlefield 6 install." % map
	var gs = HighpolyGameSource.new()
	# WIRE THE READER'S OWN LOG, or its whole phase table goes to stdout.
	#
	# log_fn was declared and never assigned, so _say() always fell through to
	# print() - into the editor's Output panel, which nobody thinks to copy, and
	# NOT into the log people send us. A user reported a 15 minute terrain build
	# and their saved log was 28 lines with a four and a half minute silent gap
	# exactly where the answer should have been. The table existed the whole
	# time; it was going somewhere nobody looks.
	gs.log_fn = func(s: String) -> void: Log.info(s)
	# ONLY BUILD THE GROUND IF SOMETHING IS GOING TO DRAW IT.
	#
	# surface_cache was set unconditionally, so every open composited the terrain
	# colour map, layer palette and splat - about 28 s cold - including for
	# somebody who only switched Detail Mode to High-Poly and never asked for a
	# map layer at all. Empty means "do not build it here"; Extended Terrain
	# builds it when it is switched on.
	gs.surface_cache = ("%s/%s" % [HighpolyMapContext.CACHE, map]) \
		if _wants_map_layers() else ""
	# Let a saved log attribute memory to us instead of leaving it to inference.
	# The reader's caches are the thing that reaches 13.8 GB, and until now the
	# only way anyone learned that was by running our harness, which no user
	# does.
	HighpolyVitals.set_cache_probe(func() -> Dictionary:
		return gs.cache_stats() if gs != null else {})
	# Rates describe THIS map's read. Left accumulating, a second map opened in
	# the same session would average its warm cache into the first map's cold
	# read and flatter a slow disk into looking fine.
	BF6Cas.io_reset()
	# Cold is the ~90 s case, and it has to be decided BEFORE the read: the whole
	# point of saying "this takes a couple of minutes" is saying it first.
	#
	# Asked of the ground cache rather than of the walk cache, which is the one
	# that actually governs the time. The walk's cache path is keyed on the
	# signature of the mounted archives, and mounting is the first stage of the
	# read itself, so nothing can consult it before the read begins. A map that
	# has a decoded ground on disk has been read on this machine before, which is
	# the same question in a form that can be answered from a file test.
	_read_begin(map, not _map_read_before(map))
	# The placement walk is the map's own contents. Detail Mode skins what YOU
	# placed and needs none of it, so it is not walked unless a map layer is on.
	var ok_g: bool = await gs.open_async(dock, map, "",
		{"placements": _wants_map_layers()},
		func(stage: String, done: int, total: int):
			# The same string the panel is showing, kept where the freeze
			# detector can name it. If the editor stops here, the log now says
			# WHICH stage it stopped in rather than going quiet.
			HighpolyVitals.crumb("reading %s: %s" % [map, stage])
			_read_stage_set(stage, done, total)
			lbl.text = "%s: %s" % [map, stage])
	_read_end()
	HighpolyVitals.crumb("idle, the read has finished")
	_gs_opening = false
	if gen >= 0 and gen != _mapctx_gen:
		return false
	for k in gs.timings:
		if str(k).begins_with("_"):
			continue
		HighpolyProfiler.span("game source: %s" % k, int(gs.timings[k]))
	HighpolyProfiler.crumb("game source", "%s in %d ms%s"
		% [map, int(gs.timings.get("_total", 0)),
		   "  (walk cached)" if int(gs.timings.get("_cached", 0)) == 1 else ""])
	# A READ THAT FAILED WHILE THE MACHINE WAS SHORT OF MEMORY GETS ONE MORE GO.
	#
	# The previous map's caches are dropped on a switch, but Godot hands freed
	# pages back lazily and the reader allocates hard while it mounts - so a
	# switch on a tight machine can fail on the first attempt and succeed on the
	# second, with nothing changed except that everything we were holding has
	# actually gone by then. Retried once, and only under real pressure, so a
	# genuinely absent map still fails immediately instead of taking twice as
	# long to say so.
	if not ok_g and HighpolyVitals.pressure() > 0:
		var before := HighpolyVitals.free_mb()
		if mapctx != null and mapctx.game_source != null \
				and mapctx.game_source.has_method("release_caches"):
			mapctx.game_source.release_caches()
		HighpolyLog.warn(("map context: reading %s failed with %d MB free. "
			+ "Releasing everything held and trying once more.")
			% [map, int(before)])
		# a frame for the engine to actually hand the pages back
		await get_tree().process_frame
		await get_tree().process_frame
		ok_g = await gs.open_async(dock, map, "",
			{"placements": _wants_map_layers()}, Callable())
		if ok_g:
			HighpolyLog.info("map context: %s read on the second attempt (%d MB "
				% [map, int(HighpolyVitals.free_mb())]
				+ "free now). Close other applications if this keeps happening.")
	if not ok_g:
		# The stage and the machine's free memory come with gs.error now (see
		# HighpolyGameSource._fail). A read that fails part-way through mounting
		# on a machine with a few hundred MB left is not the same complaint as a
		# map whose archives are absent, and this line used to read identically
		# for both.
		HighpolyLog.warn("map context: could not read %s from the install — %s"
			% [map, gs.error])
		HighpolyLog.warn("  if the free-memory figure above is small, this is the "
			+ "editor running out rather than anything wrong with your game: "
			+ "restart it and open this map first, before any other.")
		return false
	mapctx.game_source = gs
	# The object library reads from the same source: a placed object is
	# assembled from the game's own prefab instead of a fetched GLB.
	LibScript.game_source = gs
	LightingScript.game_source = gs   # the level's own sky panorama
	# THE PLACEABLE CATALOGUE, AFTER THE MAP IS USABLE, not in front of it.
	#
	# It is 85 s cold, it covers objects from OTHER levels, and this map does not
	# need it: its own props come from its own archives. Paying it up front is
	# what made a first open take three and a half minutes before anything could
	# be drawn. Added on a worker instead, additively, so the map is on screen
	# and being worked on while it lands.
	# MINE FIRST, THEN THE CATALOGUE, one after the other rather than both at
	# once. These were started back to back and neither was awaited, so both ran
	# on workers at the same time - and the catalogue sweep INSERTS into
	# gs.src.ebx while the mine iterates it. Growing a Dictionary under another
	# thread's iterator is not something to leave to luck, and when the mine died
	# of it there was nothing to see: the failure is silent (see below).
	#
	# The mine takes about 3 s and only needs this level's partitions, which the
	# level mount already has; the catalogue is 85 s cold and is for OTHER
	# levels' objects. Running the short one first costs the long one nothing.
	_gamemodes_then_catalogue(gs, map)
	return true


func _gamemodes_then_catalogue(gs, map: String) -> void:
	await _mine_gamemodes_async(gs, map)
	_upgrade_catalogue_async(gs)


# THE MODE MARKERS, mined from the install on a worker.
#
# highpoly_gamemode.gd has always been able to draw capture zones, objectives
# and spawns; it needed gamemode_markers.json, from a miner that no longer
# exists. HighpolyGmMine rebuilds that file from the game. 7 s on MP_Aftermath,
# so it goes on a worker rather than in front of the map.
#
# Only when there is nothing usable on disk: the file is derived from the
# install and does not go stale between sessions, so re-mining on every open
# would spend those seconds for nothing.
#
# "Usable" is not the same as "present". The first version of this file held an
# origin per marker and nothing else, which is all the orb overlay needed;
# rebuilding real Portal objects needs polygons, extents and facings, so an old
# file has to be re-mined rather than read. Testing only for existence would
# leave anyone who ran the previous version with a file that can never build
# anything and no way to notice.
func _mine_gamemodes_async(gs, map: String) -> void:
	if gs == null or map == "":
		return
	if HighpolyGamemode.usable(map):
		return
	# The one read that has to touch gs.src.ebx, taken here on the main thread
	# so the worker never iterates a Dictionary anything else might grow.
	var roots: Array = HighpolyGmMine.roots_of(gs, str(gs.level))
	if roots.is_empty():
		HighpolyLog.warn("gamemode markers: %s has no _layers_gameplay partitions "
			% map + "in the mount, so there are no modes to mine")
		return
	var done := [false]
	var n := [0]
	var tid := WorkerThreadPool.add_task(func() -> void:
		n[0] = HighpolyGmMine.mine_to_disk(gs, str(gs.level), map, roots)
		done[0] = true, true, "bf6 gamemode markers")
	# A FAILED WORKER USED TO HANG HERE FOREVER, SILENTLY.
	#
	# done[0] is set by the last line of the task, so a GDScript error anywhere
	# inside it leaves the flag false and this loop awaiting frames for the rest
	# of the session: no file, no dropdown, no warning, nothing in the log to
	# say the mine had even been attempted. That is what "users are not getting
	# gamemode data" looked like. Bounded now, and it says so.
	var t0 := Time.get_ticks_msec()
	while not done[0]:
		if get_tree() == null:
			return
		if Time.get_ticks_msec() - t0 > MINE_TIMEOUT_MS:
			HighpolyLog.warn(("gamemode markers: the miner did not finish within "
				+ "%d s and has been given up on. No modes will be offered for %s. "
				+ "This means the worker stopped early - the Output panel will "
				+ "carry the script error.") % [MINE_TIMEOUT_MS / 1000, map])
			return
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	if n[0] > 0:
		# The dropdown lists what this just produced, so it has to be asked
		# again - the same timing mistake that kept the row hidden before.
		_variant_row_update(mapctx_objects != null and mapctx_objects.button_pressed)
	else:
		HighpolyLog.warn("gamemode markers: nothing mined for %s from %d gameplay "
			% [map, roots.size()] + "partition(s), so the Variant list stays empty")
	return


# Runs the catalogue sweep off the main thread and refreshes what depends on it.
func _upgrade_catalogue_async(gs) -> void:
	if gs == null or gs.catalogue_ready:
		return
	HighpolyVitals.crumb("adding the placeable catalogue in the background")
	# Raised HERE, on the main thread, before the worker exists - and lowered
	# only after it is joined. Anything that scans the whole mount waits on it.
	# See HighpolyGameSource.catalogue_upgrading for the crash this prevents.
	gs.catalogue_upgrading = true
	var done := [false]
	# THE LONGEST PHASE OF A COLD OPEN, AND THE BAR SAID NOTHING FOR IT.
	#
	# The catalogue mount is ~85 s and it drove no progress at all: it is not
	# one of the read stages, so the read panel never saw it and the job bar
	# sat empty for the whole of it. upgrade_catalogue has always taken a
	# progress callable; nobody passed one.
	#
	# Relayed rather than set directly, because the sweep runs on the worker
	# and the bar is a Control: the worker only writes two ints, and the poll
	# loop below - already running once a frame - is what touches the panel.
	var relay := [0, 0]
	var tid := WorkerThreadPool.add_task(func() -> void:
		gs.upgrade_catalogue(func(d: int, t: int, _found: int) -> void:
			relay[0] = d
			relay[1] = t)
		done[0] = true, true, "bf6 placeable catalogue")
	while not done[0]:
		if get_tree() == null:
			break
		if jobs != null and int(relay[1]) > 0:
			jobs.set_activity(CATALOGUE_BAR, int(relay[0]), int(relay[1]))
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	if jobs != null:
		jobs.clear_activity(CATALOGUE_BAR)
	gs.catalogue_upgrading = false
	HighpolyVitals.crumb("idle, nothing building")
	if not gs.catalogue_ready:
		return
	# Icons and placed objects that could not resolve from the level's archives
	# alone can resolve now, and nothing may keep the old answer.
	if previews != null:
		previews.clear_cache()
	Log.info("the placeable catalogue is ready: objects from other maps can be "
		+ "drawn now")


func _mapctx_changed() -> void:
	# THE BUILD WAITS FOR THE PLACED-OBJECT SWAP TO FINISH.
	#
	# These are two loops that both mutate the same scene across their own
	# yields, and running them together is what kills the four layers that
	# build game geometry. Measured: terrain plus the swap is fine, a geometry
	# layer WITHOUT the swap (mode SDK) ran past 225 s, and the two together
	# die at 24-36 s every time.
	#
	# The collision is not rare, it is the default. On a fresh start the plugin
	# carries the live mode across the editor addon reload, so _apply_open_scene
	# re-skins every placed object - 7,792 of them on MP_Aftermath - and a user
	# switching a layer on lands squarely inside that.
	#
	# The other direction was already handled: _swap_placed_after_build runs the
	# swap once the build is done. This is the missing half.
	if _swap_busy:
		Log.info("Waiting for the placed objects to finish swapping before "
			+ "building the map layers.")
		await _await_flag("swapping placed objects",
			func(): return _swap_busy)
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
	# ---- THE GAME FIRST, the download only as a fallback --------------------
	#
	# Everything the map context needs is in the player's own install:
	# placements, geometry, textures, the skyline and the terrain, each verified
	# against the pipeline it replaces. Reading from there means nothing is
	# downloaded and no extracted EA assets are redistributed, which is the
	# entire point of the reader.
	#
	# Cold this costs ~85 s (mount, 223k partition guids, the level walk), warm
	# 1.3 s, all cached under the mounted TOCs' signature so a game patch
	# invalidates it. It runs on a worker with the dock still live — see
	# HighpolyGameSource.open_async.
	# ONE OPEN AT A TIME, and this is not a tidiness point.
	#
	# _mapctx_changed runs on every one of the layer toggles — on, objects,
	# backdrop, water, textures — and each of them reached this guard while the
	# first open was still awaiting, saw game_source still null, and started
	# another. A recorded session opened the same map SIX times. Warm that is six
	# times 1.4 s; cold it is six threads all missing the same walk cache and
	# each paying the full 85 s, because none of them has written the cache yet.
	#
	# A later arrival waits for the one in flight rather than starting its own.
	await _ensure_game_source(map, gen)
	# THE MAP'S OWN CONTENTS, walked now if an earlier open did not need them.
	#
	# An open made for Detail Mode alone skips the placement walk, because
	# skinning what YOU placed does not need to know what the LEVEL contains.
	# Switching a map layer on is the moment it does, and everything downstream -
	# props, skyline, lights, the group placements - reads from that walk, so it
	# has to complete before the build starts rather than during it.
	if _wants_map_layers() and mapctx != null and mapctx.game_source != null:
		if not mapctx.game_source.placements_ready:
			await _ensure_placements_async(mapctx.game_source)
	if gen != _mapctx_gen:
		# A newer toggle superseded this one while the install was being read.
		# Correct, and utterly invisible: the click appears to do nothing.
		Log.info("Map context: this change was superseded by a newer one before it "
			+ "could build. The newer one is what applies.")
		return

	# THE INSTALL IS THE ONLY SOURCE. There used to be a fallback here: a cached
	# map went through download_map to self-heal, and an unseen one raised a
	# dialog offering to fetch tens of megabytes. Both are gone with the rest of
	# the download path - the plugin requires Battlefield 6, says so at the top
	# of the panel, and disables itself when it is not there.
	#
	# Reaching this point means the gate let us through and the read still
	# failed, which is worth saying plainly rather than silently doing nothing.
	if mapctx.game_source != null and mapctx.game_source.level == map.to_lower():
		lbl.text = "Building %s…" % map
		await _apply_mapctx(r, on, objs, tex, gen)
		return
	mapctx_on.set_pressed_no_signal(false)
	mapctx_objects.set_pressed_no_signal(false)
	# LOGGED, not just labelled. A chip that un-presses itself with only a
	# panel message is indistinguishable from a button that does nothing, and
	# the saved log then shows the layer as OFF with no reason recorded.
	Log.warn("Map context: %s could not be read, so Extended Terrain and "
		% map + "Original map objects were switched back off. "
		+ "The install the reader found: '%s'."
		% (mapctx.game_source.src.game if mapctx.game_source != null
			and mapctx.game_source.src != null else "none"))
	lbl.text = "Could not read %s from your Battlefield 6 install. Check the game folder at the top of this panel." % map
# The models a rung needs come from the install, so make sure it is open before
# applying one that draws our geometry. Without this, switching to High-Poly in a
# session that never touched Map Context applied a rung with nothing to apply.
#  is for the case the scene mode cannot speak for: previewing a single
# selected object in High-Poly WHILE the scene is on Low-Poly. That is the whole
# point of the override, and gating on the scene mode meant it opened nothing,
# resolved nothing and drew nothing - the one mode where the preview is the only
# way to see a real model was the one mode where it could not work.
func _ensure_source_for_mode(force := false) -> void:
	if not force and _mode() == HighpolyLib.Tier.LOW:
		return                       # the SDK's own proxies need nothing from us
	var r := EditorInterface.get_edited_scene_root()
	if r == null or mapctx == null:
		return
	var map: String = mapctx.map_of(r)
	if map == "":
		# SILENT BEFORE, AND THE SILENCE WAS THE BUG REPORT.
		#
		# map_of() is the scene root's NAME and only when it begins with "MP_".
		# Anything else - a renamed root, a scene built from scratch - resolves
		# to "" and every path that needs the install returned here without a
		# word. A user sat in High-Poly for four minutes with nothing skinned
		# and a log containing no game-source line at all, which is
		# indistinguishable from a read that failed until you know this rule.
		#
		# Said once per scene, not once per call: this runs on every dropped
		# node as well as on the mode switch.
		if _said_not_map != String(r.name):
			_said_not_map = String(r.name)
			var msg := ("\"%s\" is not a map scene, so there is nothing to read "
				+ "from your install. Detail Mode needs the scene's ROOT NODE "
				+ "named MP_<Map> - the level scenes the SDK ships already are, "
				+ "and a copy keeps working as long as you keep that name.")\
				% String(r.name)
			lbl.text = msg
			HighpolyLog.warn(msg)
		return
	_said_not_map = ""
	# THE OPEN SOURCE HAS TO BE THIS SCENE'S MAP, NOT MERELY NON-NULL.
	#
	# This asked only whether a source existed, and _check_scene_change resets
	# every chip on the dock but does not close the reader - deliberately, since
	# switching back to a map you were just on should not pay for it twice. So
	# after opening a second map the previous map's source was still sitting
	# there, this returned immediately, and the scene-wide apply then asked
	# MP_Aftermath's reader for MP_Abbasid's props. The catalogue covers every
	# level, so a handful still resolved and the rest did not: "only a few
	# assets come in high poly".
	#
	# Turning "Original map objects" on looked like the fix because that path
	# goes through _ensure_game_source, which HAS always compared the level -
	# it opened the right reader, and everything skinned from then on. The
	# toggle was never doing the skinning; it was repairing this.
	if HighpolyLib.game_source != null \
			and str(HighpolyLib.game_source.level) == map.to_lower():
		return
	await _ensure_game_source(map)


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
	# BEFORE _apply_scene, not after: the apply is what asks the library for a
	# model per prop, and with no game source open every one of those asks
	# returns nothing. Awaiting here means the first switch to High-Poly in a
	# session pays the read once and then actually swaps.
	await _ensure_source_for_mode()
	# SAID, AND GIVEN A FRAME TO BE SEEN, before the swap starts. HighpolyLib
	# .apply walks the whole scene and builds an overlay per prop in one
	# uninterrupted pass: the editor does not repaint until it returns, so
	# whatever the panel said last is what stays on screen for the duration. With
	# nothing set here that was the last line from the read, which had just
	# finished, so the plugin looked done and idle while it was in fact busy.
	lbl.text = "Swapping placed objects to %s." % mode_btn.get_item_text(mode_btn.selected)
	if dock != null and dock.get_tree() != null:
		await dock.get_tree().process_frame
	# The SDK's merged _Assets mesh is NOT this dropdown's business. Detail Mode
	# governs the pieces YOU placed; the thing that actually stands in for the
	# level's own shipped assets is "Original map objects", which brings in the
	# real per-object geometry. Ownership of that node moved there — hiding it
	# from here meant switching to High-Poly stripped the level's assets even
	# with nothing loaded to replace them.
	await _apply_scene()
	# a mode switch rebuilds every preview — re-apply the placed-object cull so
	# your custom map content keeps distance-culling in the new detail mode
	_reapply_placed_cull()
	# whatever this scene needs but doesn't have yet: front of the queue, and
	# swapped in automatically as it lands (no prompt, no re-apply button).
	#
	lbl.text += _mode_hint()
	if shed > 0:
		lbl.text += ". %d borrowed layer(s) switched off. They come back the moment you climb a rung" % shed
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

# PACED, so the swap has a bar instead of being a freeze.
#
# This used to be one call to HighpolyLib.apply, which walks the scene and builds
# an overlay per prop without ever returning to the editor. Nothing repaints for
# the duration, so the panel kept showing whatever it last said (the finished
# read), which looks exactly like being done. Now the plan comes first, so the
# total is known, and the work is done a slice at a time with a frame in between.
#
# THE SLICE IS TIMED, NOT COUNTED, and it re-times itself from the cost of the
# yield. A yielded frame is not free here: the editor redraws the whole scene,
# and the build harness measured 125 ms per yield with a map loaded and up to two
# seconds while the skyline is up. At a fixed "yield every 50 props" a big scene
# would spend more time redrawing than swapping. Working for four times what the
# last yield cost holds the overhead near 20% whatever the scene weighs, and a
# bar that moves five times a second is no better than one that moves twice.
#
# Scenes small enough to finish inside the first slice never yield at all, so the
# common case pays nothing for any of this.
const SWAP_JOB := "Swapping placed objects"

# How many swap passes are inside the loop right now. Should never exceed 1.
var _swap_live := 0
# True while a placed-object swap is walking the scene. The map-context build
# waits on it; see _mapctx_changed.
var _swap_busy := false
var _swap_gen := 0

func _apply_scene() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"; return
	# A newer swap cancels an older one. Two mode switches in quick succession
	# would otherwise interleave, each applying its own tier to a different half
	# of the scene.
	_swap_gen += 1
	var gen := _swap_gen
	_swap_busy = true
	# WHO IS SWAPPING, AND IS ANYONE ELSE. Two passes over the same scene
	# nodes, interleaved across their yields, would both be freeing and
	# re-adding the same children - and the four layers that crash all die
	# somewhere inside this loop with every breadcrumb balanced, which is what
	# a second writer looks like from inside the first.
	if OS.get_environment("BF6_MESH_TRACE") == "1":
		_swap_live += 1
		HighpolyLog.info("mesh trace: SWAP-PASS start gen=%d live=%d"
			% [gen, _swap_live])
		HighpolyLog.flush()
	var tier := _mode()
	var tex := _textured()
	var todo: Array = HighpolyLib.plan(r)
	var total := todo.size()
	var lane := _lane(SWAP_JOB)
	var tree: SceneTree = dock.get_tree() if dock != null else null
	var budget := 400                      # ms of work before the first yield
	var slice_t0 := Time.get_ticks_msec()
	var n := 0
	for i in range(total):
		var pair: Array = todo[i]
		# Re-checked every item: the plan was made before the first yield and the
		# scene is live in between.
		if not is_instance_valid(pair[0]):
			continue
		if HighpolyLib.apply_one(pair[0] as Node3D, str(pair[1]), tier, tex):
			n += 1
		if tree == null or Time.get_ticks_msec() - slice_t0 < budget:
			continue
		lane.call(i + 1, total)
		lbl.text = "Swapping placed objects: %d of %d" % [i + 1, total]
		var y0 := Time.get_ticks_msec()
		await tree.process_frame
		if gen != _swap_gen or EditorInterface.get_edited_scene_root() != r:
			lane.call(total, total)        # close the bar, leave the rest to the newer pass
			if gen == _swap_gen:
				_swap_busy = false
			if OS.get_environment("BF6_MESH_TRACE") == "1":
				_swap_live -= 1
				HighpolyLog.info("mesh trace: SWAP-PASS superseded gen=%d live=%d"
					% [gen, _swap_live])
				HighpolyLog.flush()
			return
		budget = clampi((Time.get_ticks_msec() - y0) * 4, 250, 2000)
		slice_t0 = Time.get_ticks_msec()
	lane.call(total, total)
	_swap_busy = false
	if OS.get_environment("BF6_MESH_TRACE") == "1":
		_swap_live -= 1
		HighpolyLog.info("mesh trace: SWAP-PASS done gen=%d live=%d"
			% [gen, _swap_live])
		HighpolyLog.flush()
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
	# On a Low-Poly scene this pass is the ONLY thing asking for a real model, so
	# it has to be the thing that opens the install. Forced, because the scene
	# mode says Low-Poly and would otherwise refuse.
	if tier != HighpolyLib.Tier.LOW and HighpolyLib.game_source == null:
		await _ensure_source_for_mode(true)
		if not is_instance_valid(self):
			return
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


# ---------- viewport double-click: doors, then variant cycling ----------
# Double-clicking a door proxy swings it open/closed like in game. If no door
# was hit, a prop that ships variant models (police liveries, barn colours,
# destroyed shells, …) cycles base -> variants -> base instead — doors always
# win when a prop is both. Only consumed when something was actually hit, so
# normal click/drag selection and camera behavior stay untouched.
var prop_light_on: Button = null
var previews_btn: Button = null      # "Build object previews", with a progress row
var _said_not_map := ""              # scene we have already explained is not a map


# Render every library icon now, through the same progress queue the other long
# jobs use, instead of letting the 2-second timer do it a hitch at a time.
func _build_previews() -> void:
	# the journal's button row: any preview/library work WITHOUT one of these
	# upstream of it is work nobody pressed for
	BJournal.event("ui", "button: Build object previews")
	if previews == null:
		return
	if previews.building:
		# A SECOND PRESS IS A CANCEL, not a second build. The button is the only
		# thing on screen that can stop this, and a run over a large library is
		# long enough that someone will want to.
		previews.cancel_build = true
		previews_btn.text = "Stopping…"
		return
	# Icons of what you PLACE, so they follow Detail Mode - and Detail Mode
	# cannot draw anything without the install open. Asked for first, or the
	# whole run renders nothing and reports success.
	await _ensure_source_for_mode(true)
	if previews == null or not is_instance_valid(previews_btn):
		return
	var missing: int = previews.missing_count()
	if missing == 0:
		lbl.text = "Object previews are already built for this detail mode"
		return
	var was := previews_btn.text
	previews_btn.text = "Stop building previews"
	var token: int = await jobs.acquire("Object previews")
	var res: Dictionary = await previews.build_all(func(done: int, total: int):
		jobs.report(done, total))
	jobs.release(token, not res.has("error"), str(res.get("error", "")))
	if is_instance_valid(previews_btn):
		previews_btn.text = was
	if res.has("error"):
		lbl.text = str(res["error"])
		return
	lbl.text = ("Object previews: %d rendered, %d already cached, %d have nothing "
		+ "to draw them from — %.1f s%s") % [int(res["rendered"]),
		int(res["already_cached"]), int(res["no_source"]), float(res["seconds"]),
		"  (stopped early)" if bool(res["cancelled"]) else ""]
	HighpolyLog.info(lbl.text)


# ONE SWITCH, BOTH HALVES. The fixtures are Light3D children of each overlay and
# only need showing; the glow is an emission multiplier baked into the materials,
# so that half needs the materials rebuilding. Doing only one of the two would
# leave a lamp casting light with a dark bulb, or a bright bulb lighting nothing.
func _set_prop_lighting(on: bool) -> void:
	# STATICS ARE SET THROUGH THE PRELOAD CONST, never through the class_name.
	# After an in-place reload the two are different script objects and the
	# assignment lands on the wrong one, which is a bug this plugin has already
	# paid for once.
	LightingScript.prop_lighting = on
	# OFF MEANS OFF, not "as authored". The first version set this to 1.0 when
	# switched off, which draws the lit sheet at the strength the artist gave it -
	# and a lamp's lit sheet is a lit sheet, so every bulb still glowed. A switch
	# labelled Prop Lighting that leaves the bulbs on is just wrong.
	var r := EditorInterface.get_edited_scene_root()
	var n: int = LightingScript.set_prop_lights_shown(r, on)
	# The cull pass early-outs while the camera is still, so without this a
	# toggle made standing in one place would not be re-decided until the user
	# moved. It is also what applies the RANGE to fixtures just switched on:
	# set_prop_lights_shown shows all of them, and the next tick trims them back
	# to the slider.
	LightingScript.invalidate_light_cull()
	# ONE NUMBER ON A FEW DOZEN MATERIALS, not a rebuild.
	#
	# This used to call invalidate_materials and then re-apply every placed
	# overlay. That re-resolves every surface from the depot - 13,097 of them,
	# measured at 12.7 SECONDS in the user's log - to change an emission
	# multiplier, and 99% of those surfaces have no glow to change. The materials
	# are shared between the map context and placed props, so setting the
	# parameter in place reaches both and nothing has to be rebuilt at all.
	var want: float = PROP_EMISSION_ON if on else 0.0
	var gs = mapctx.game_source if mapctx != null else null
	if gs != null and gs.has_method("set_prop_emission"):
		var t0 := Time.get_ticks_msec()
		var touched: int = gs.set_prop_emission(want)
		Log.info("Prop lighting %s: %d fixture(s), %d material(s) in %d ms"
			% ["on" if on else "off", n, touched, Time.get_ticks_msec() - t0])
	else:
		# No map open yet. Nothing exists to update, but the value has to be
		# right for whatever gets built next.
		GameSourceScript.prop_emission = want
	lbl.text = "Prop lighting " + ("on" if on else "off")
	_save_mapctx_state()


# How hard a lit sheet is driven when the switch is on. Ours, not the level's:
# the sheet says WHERE the light is, not how bright the room should read.
const PROP_EMISSION_ON := 4.0


# WRAPPED RATHER THAN WRAPPED IN PLACE. The body below returns from five
# different points, and a bucket left open by an early return would swallow
# everything begun after it, so the measurement sits in a shell that always
# closes. Same pattern anywhere else in this file with several exits.
#
# WORTH MEASURING because of how often it runs: set_input_event_forwarding_always
# _enabled() is on, so every mouse move over the 3D viewport arrives here, which
# during camera navigation is several events per frame. Anything non-trivial in
# this path is paid at exactly the moment the user is looking for smoothness.
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not HighpolyProfile.enabled:
		return _forward_3d_gui_input_body(camera, event)
	HighpolyProfile.begin("viewport input forwarding")
	var r := _forward_3d_gui_input_body(camera, event)
	HighpolyProfile.end("viewport input forwarding")
	return r


func _forward_3d_gui_input_body(camera: Camera3D, event: InputEvent) -> int:
	if diag_pick != null and diag_pick.button_pressed:
		var v := _pick_input(camera, event)
		if v != EditorPlugin.AFTER_GUI_INPUT_PASS:
			return v
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
		# NO SELECTION HANDLING HERE ANY MORE. The proxy is left visible and
		# drawing nothing (highpoly_lib.invisible_material), so the editor picks it
		# natively and the gizmo is the ordinary gizmo. The hand-rolled version this
		# replaces guessed from bounding boxes, stole presses meant for gizmo
		# handles, and selected neighbours - all of which the engine gets right.
	return EditorPlugin.AFTER_GUI_INPUT_PASS

# ---------- pick mode ----------
#
# Only ever reached while Pick mode is on, and it consumes only the events it
# actually acts on, so camera navigation, box-select and the gizmos keep working
# with it armed.
#
# TWO WAYS TO DRILL, deliberately. Tab is the one people expect, coming from
# Revit, but the 3D viewport is a Control and Tab is the focus-change key, so
# there is no guarantee it reaches a plugin on every platform and theme. Clicking
# the same spot again does the same job and cannot be intercepted by anything, so
# the feature does not depend on which of the two the editor lets us have.
func _pick_input(camera: Camera3D, event: InputEvent) -> int:
	if not HighpolyProfile.enabled:
		return _pick_input_body(camera, event)
	HighpolyProfile.begin("pick mode input")
	var r := _pick_input_body(camera, event)
	HighpolyProfile.end("pick mode input")
	return r


func _pick_input_body(camera: Camera3D, event: InputEvent) -> int:
	var gs = mapctx.game_source if mapctx != null else null
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# HOVER: the light-red preview, the way Revit pre-highlights before a
	# click. Only mouse MOVES with no button held, and throttled, because this
	# path runs several times per frame during camera navigation. The event is
	# never consumed: hovering must not eat the input the camera, the gizmos
	# and box-select need. A confirmed pick stays put - hover resumes after
	# Escape releases it.
	if event is InputEventMouseMotion:
		var mv := event as InputEventMouseMotion
		if mv.button_mask != 0 or HighpolyDiagnose.is_confirmed():
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		var now := Time.get_ticks_msec()
		if now - _hover_ms < 90 or mv.position.distance_to(_hover_last) < 6.0:
			return EditorPlugin.AFTER_GUI_INPUT_PASS
		_hover_ms = now
		_hover_last = mv.position
		if HighpolyDiagnose.hover(camera, mv.position, root):
			lbl.text = HighpolyDiagnose.focus_label(gs)
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventKey and (event as InputEventKey).pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_TAB and HighpolyDiagnose.has_focus():
			var moved := HighpolyDiagnose.step(-1 if k.shift_pressed else 1, root)
			lbl.text = HighpolyDiagnose.focus_label(gs) if moved else \
				("Already at the outermost level." if k.shift_pressed
					else "That is the last part of this object.")
			if moved: _report_focus(root, gs)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if k.keycode == KEY_H and HighpolyDiagnose.has_focus():
			# Hide the highlighted object without leaving the viewport - the
			# keyboard twin of the panel's Hide picked button. (This was a
			# right-click once; that collided with freelook and was removed.)
			lbl.text = HighpolyDiagnose.hide_focus(root)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if k.keycode == KEY_ESCAPE and HighpolyDiagnose.has_focus():
			# Two stages, like any selection tool: the first Escape releases a
			# confirmed selection back to hovering, the second clears the pick.
			if HighpolyDiagnose.is_confirmed():
				HighpolyDiagnose.unconfirm(root)
				lbl.text = HighpolyDiagnose.focus_label(gs)
			else:
				HighpolyDiagnose.clear()
				lbl.text = "Pick cleared. Hover another object."
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if not (event is InputEventMouseButton):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	# alt+click steps back out, the mouse-only counterpart of Shift+Tab
	if mb.alt_pressed:
		if HighpolyDiagnose.has_focus() and HighpolyDiagnose.step(-1, root):
			lbl.text = HighpolyDiagnose.focus_label(gs)
			_report_focus(root, gs)
		else:
			lbl.text = "Already at the outermost level."
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	# clicking the same spot again drills instead of re-picking the same thing
	if HighpolyDiagnose.has_focus() and mb.position.distance_to(_pick_last) <= 6.0:
		if HighpolyDiagnose.step(1, root):
			lbl.text = HighpolyDiagnose.focus_label(gs)
			_report_focus(root, gs)
		else:
			lbl.text = "That is the last part of this object. Alt+click to step out."
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	# THE CLICK CONFIRMS THE HOVER - it never re-picks. Hover and click run
	# the pick with different rules (hover skips the camera-enclosing meshes
	# and previews big ones by their box), so a fresh full-budget pick here
	# could resolve to something BEHIND the highlight: the ray slips past the
	# box-previewed building's actual triangles and lands on the prop inside
	# it. What is light red is what the click selects, always.
	if HighpolyDiagnose.has_focus() and not HighpolyDiagnose.is_confirmed():
		_pick_last = mb.position
		HighpolyDiagnose.confirm(root)
		var hn := HighpolyDiagnose.focus_node()
		if hn != null:
			EditorInterface.edit_node(hn)
		lbl.text = HighpolyDiagnose.focus_label(gs)
		_report_focus(root, gs)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	var t0 := Time.get_ticks_msec()
	var hit: Dictionary = HighpolyDiagnose.pick(camera, mb.position, root)
	_pick_last = mb.position
	if hit.is_empty():
		# Nothing there — hand the click back rather than swallowing it, so
		# clicking empty space still deselects and box-select still starts.
		HighpolyDiagnose.clear()
		lbl.text = "Nothing under the cursor."
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	HighpolyDiagnose.focus_on(hit, root)
	# THE CLICK IS THE CONFIRMATION. Hover already showed this thing light red;
	# the click makes it bright red, and from here the note box pins to it.
	HighpolyDiagnose.confirm(root)
	# The Inspector is the closest thing to real selection an owner-less node can
	# have: it shows the actual overlay MeshInstance/MultiMeshInstance, its mesh,
	# its material and its transform, live.
	var fn := HighpolyDiagnose.focus_node()
	if fn != null:
		EditorInterface.edit_node(fn)
	lbl.text = HighpolyDiagnose.focus_label(gs)
	Log.debug("pick: %s in %d ms" % [lbl.text, Time.get_ticks_msec() - t0])
	_report_focus(root, gs)
	return EditorPlugin.AFTER_GUI_INPUT_STOP


# The full resolution chain for whatever is focused, written into the log.
#
# Emitted on every pick AND on every drill step, because both change WHICH
# object the answer is about, and a report describing the thing you were looking
# at a moment ago is worse than no report at all. It is a few dictionary lookups
# and a string join per surface, so there is nothing here worth the second button
# press it used to cost.
func _report_focus(root: Node, gs) -> void:
	if root == null or not HighpolyDiagnose.has_focus():
		return
	var note: String = mark_note.text.strip_edges() if mark_note != null else ""
	HighpolyDiagnose.run(root, gs, mapctx, note)
	# The provenance line is the selector every outside tool takes (`hp.py
	# explain`, `dossier.py`), so a pick is worth an event: it means the
	# question "which object are we talking about" survives outside the editor
	# without anyone transcribing a label out of a screenshot.
	HighpolyLog.event("pick.confirm",
		{"provenance": HighpolyDiagnose.provenance(gs),
		 "label": HighpolyDiagnose.focus_label(gs), "note": note})


# Overlay group name -> the panel chip that shows or hides it, so the Unhide
# report can point at the switch instead of naming an internal node.
static func _layer_chip_name(group: String) -> String:
	if group.begins_with("V_"):
		return "the Variant '%s'" % group.substr(2)
	match group:
		"Backdrop":
			return "Backdrops"
		"Props":
			return "Original map objects"
		"Water":
			return "Water"
		"Roads":
			return "Roads"
		"FXCards":
			return "FX"
		"Terrain", "_MAP_CONTEXT":
			return "Extended Terrain"
	return group


# The instance of a batch nearest to where the camera is looking: the honest
# anchor for a note when the selection can only name the whole MultiMesh
# group. Nearest to the camera AIM (a point ahead of the camera), not to the
# camera itself, so a note pinned while looking down a street lands on the
# instance being looked at rather than the one behind the viewpoint.
func _nearest_instance_point(mmi: MultiMeshInstance3D) -> Vector3:
	var aim := HighpolyMarkers.camera_point()
	var mm := mmi.multimesh
	var gx := mmi.global_transform if mmi.is_inside_tree() else mmi.transform
	var best := aim
	var bd := 1e30
	for i in range(mm.instance_count):
		var p := (gx * mm.get_instance_transform(i)).origin
		var dd := p.distance_squared_to(aim)
		if dd < bd:
			bd = dd
			best = p
	return best

func _collision_changed() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"
		col_chk.set_pressed_no_signal(false)
		return
	var on := col_chk.button_pressed
	iso_chk.disabled = not on
	# The colour and alpha only tint shapes that are being drawn. Left live with
	# Collisions off they are two controls that visibly do nothing, which reads
	# as the setting being broken rather than not applicable yet.
	if col_pick: col_pick.disabled = not on
	if col_alpha: col_alpha.editable = on
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

# Fires on every click in the viewport and on every arrow-key step through the
# scene tree, so it is on the interactive path even though it is not per-frame.
func _on_selection_changed() -> void:
	HighpolyProfile.begin("selection changed")
	if ovr_chk != null and ovr_chk.button_pressed:
		_reoverride_selection()
	if iso_chk != null and iso_chk.button_pressed and col_chk.button_pressed:
		_reisolate_selection()
	HighpolyProfile.end("selection changed")


# Wrapped for the same reason as the input forwarder: seven early returns.
#
# THE CALL COUNT IS THE POINT HERE. This is connected to the tree-wide
# node_added signal, so a map-context build fires it about 11,600 times, and
# those arrive in bursts inside single frames. Whether the burst costs anything
# now that there is a bool gate at the top is exactly what nobody has measured.
func _on_node_added(node: Node) -> void:
	if not HighpolyProfile.enabled:
		_on_node_added_body(node)
		return
	HighpolyProfile.begin("node added filter")
	_on_node_added_body(node)
	HighpolyProfile.end("node added filter")


func _on_node_added_body(node: Node) -> void:
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
	# A REBUILT MODE IS NOT SOMETHING YOU JUST PLACED. Its nodes are owned (they
	# are yours to keep and edit), so in_overlay above does not cover them, and
	# they all sit under res://objects/ - which is exactly what the collision
	# branch below tests. A few hundred capture points and spawns arriving at
	# once would each get a collision overlay built for them.
	if HighpolyGamemode.in_gamemode(node): return
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
	# A PROP DROPPED BEFORE ANYTHING OPENED THE INSTALL still has to become the
	# real thing. This is the common first action in a session - drag a crate in,
	# switch to High-Poly - and it used to leave the SDK proxy behind because the
	# only code that opened a game source was the Map Context toggle.
	if HighpolyLib.game_source == null and _mode() != HighpolyLib.Tier.LOW:
		await _ensure_source_for_mode()
		if not is_instance_valid(node):
			return
	HighpolyLib.apply_one(node as Node3D, k, _mode(), _textured())
	# a piece placed while optimization is on should distance-cull right away, like
	# the rest of your map content (O(1): only this node's own meshes are touched)
	if mapctx_optimize != null and mapctx_optimize.button_pressed:
		PlacedCull.apply(node as Node3D, _cull_radius(), true)
