@tool
extends Node
class_name HighpolyMapContext
# Editor-only "Map Context": injects the real map terrain + the game's original
# object placements as an owner=null "_MAP_CONTEXT" node under the level root.
# Nothing is saved or exported; the SDK level scene stays byte-identical. Data
# (terrain GLB + placements.json) is downloaded per-map on demand from the same
# registry host and cached under user://mapcontext/<Map>/.
#
# Props are drawn as one MultiMeshInstance3D per unique mesh (thousands of
# placements, a few hundred draw calls), and streamed by distance from the
# editor camera via a render-radius slider.

const NODE := "_MAP_CONTEXT"
const CACHE := "user://mapcontext"
# shared, deduplicated prop-mesh store — downloaded ONCE and reused across every
# map (a rock used by 5 maps is stored once), so per-map data stays tiny.
const PROPS_CACHE := "user://mapcontext/_props"

var _active := false               # Map Context enabled at all
var _show_objects := false         # original map objects (props) layer on
var radius: float = 768.0          # metres; props beyond this are hidden
var _map := ""
var _data: Dictionary = {}
var _cells: Dictionary = {}        # "cx,cz" -> Array[MultiMeshInstance3D] (props)
var _cell_size := 64.0
var _world_min := -2048.0
var _mesh_cache: Dictionary = {}   # model path -> Mesh
var terrain_step: int = 2          # metres per terrain vertex (1=full, 2=high, 4=medium)
# vegetation scatter (grass/shrub kits from the game's MeshScatteringDatabase);
# a strict no-op for maps whose package carries no scatter.json
const ScatterScript = preload("highpoly_scatter.gd")
var _scatter = ScatterScript.new()
var _scatter_n := 0
# self-healing (v1.5): once per session per map, HEAD the map's packages and
# compare ETags against the ones recorded at last download. A republished
# package (game patch, fixed placements, corrected prop meshes) re-downloads
# automatically — no "Reload map data" button. Installs with no recorded ETag
# (anything pre-1.5) count as stale, which retroactively heals every install
# that cached wrong props under the old "file exists = current" rule.
var _session_checked: Dictionary = {}   # map -> true
var _props_refresh: Dictionary = {}     # map -> true (props.zip must overwrite-all)
# registry-following props: shared prop meshes are verified per session per map
# against the model registry (mesh-name keyed hashes from the plugin manifest),
# so a model swapped on the SITE under the same name reaches map context too —
# not only when the map's props.zip is rebuilt. Verified hashes are remembered
# in _props/index.json; unknown files are content-hashed ONCE (same sha1[:12]
# the registry publishes), so nothing is re-downloaded that already matches.
var last_verify_updates := 0
var _props_verified: Dictionary = {}    # map -> true (this session)

# ---------- non-blocking props build (state) ----------
# apply() stays synchronous for terrain/backdrop/scatter (fast), but the props
# layer (~2k unique GLB parses + MultiMesh builds — minutes of work that used
# to freeze the editor) is handed to an incremental background builder; see
# _build_props_async. _build_gen is bumped by _clear(), cancelling any
# in-flight build; is_build_done() lets batch consumers (PhotoMatch's render
# hook) wait for a COMPLETE overlay before shooting.
signal build_progress(done: int, total: int)   # per work-slice + on completion
signal build_finished(built: int)              # completed (not emitted when superseded)
const BUILD_FRAME_MS := 40          # per-frame parse budget (always >=1 mesh per frame)
const BUILD_REPORT_EVERY := 100     # print / progress-file cadence (meshes)
var _build_gen := 0                 # generation: _clear() bumps it, cancelling in-flight builds
var _building := false              # a background props build is in flight
var _build_done := 0                # mesh groups processed so far
var _build_total := 0               # mesh groups queued
var _build_props := 0               # meshes actually built (parse succeeded)
var _last_report := 0               # _build_done at the last print/file report
var _build_status_base := ""        # apply()'s summary minus the objects part
var _last_status := ""              # exact string the last full apply() returned
var status_label: Label = null      # set by the toggle plugin: live progress target
# incremental refresh ("Check for Updates"): per-parsed-GLB source stamps plus
# which prop entries each source built, so a cache file overwritten by the
# background re-bake rebuilds JUST its own MultiMeshes — no full re-toggle
var _mesh_stat: Dictionary = {}     # glb path -> {"mt": int, "sz": int} at parse time
var _prop_by_src: Dictionary = {}   # glb path -> Array[prop entry] built from it
var _props_dir := ""                # last props build: per-map dir (legacy "glb" paths)
var _props_textured := false        # last props build: textured flag
var _props_mat: Material = null     # last props build: flat study material
var _props_tex_mode := -1           # last props build: detail mode (0/1/2)
var _ctx_tex_mode := -1             # last apply(): detail mode (set_context_shown key)
# manual override for the maptile DECAL on the SDK terrain + assets (textured
# mode, non-splat path): it tints buildings/props, which fights the re-baked
# real textures. Default true = exactly the old behaviour. STATIC on purpose:
# the dock checkbox (via set_maptile) and PhotoMatch's transient render
# instance share ONE preference — as a per-instance var, the render hook's
# fresh instance re-added the decal from its own default on every render.
static var maptile_enabled := true
static var _maptile_ok := false     # last apply(): textured + non-splat (a decal would show)

func reset_props_verification() -> void:
	# called when the sync manager adopts a NEW manifest (models changed)
	_props_verified.clear()

# Untextured "study" colours match the SDK's own placeholder look so our overlay
# blends seamlessly with the shipped terrain/assets: green for land, orange for
# objects. Sampled from M_LevelTerrain / M_LevelAssets. A small emission floor
# keeps them readable even where the scene's ambient light is dark/blue.
const SDK_GRID_M := 12.0                     # SDK terrain grid cell = 12 m (UV 0..100 over 1200 m)
const TERRAIN_GREEN := Color(0.4078, 0.5608, 0.3098)
const ASSETS_ORANGE := Color(1.0, 0.6745, 0.4706)
static var _terrain_mat: StandardMaterial3D = null
static var _assets_mat: StandardMaterial3D = null

# tex_mode 1 (High-Poly — no textures): neutral SHADED clay, so geometry reads
# like the library's untextured high-poly mode (the study green/orange above are
# unshaded placeholders by design).
static var _clay_cache: StandardMaterial3D = null
static func _clay_mat() -> StandardMaterial3D:
	if _clay_cache == null:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.62, 0.62, 0.62)
		m.roughness = 0.9
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_clay_cache = m
	return _clay_cache

static func _flat_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	# unshaded: the exact flat colour renders everywhere, independent of scene
	# lighting / vertex normals — so the huge terrain never darkens under the
	# level's dim ambient (was showing dark bluish/green in the middle).
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func terrain_material() -> StandardMaterial3D:
	if _terrain_mat == null: _terrain_mat = _flat_mat(TERRAIN_GREEN)
	return _terrain_mat

func assets_material() -> StandardMaterial3D:
	if _assets_mat == null: _assets_mat = _flat_mat(ASSETS_ORANGE)
	return _assets_mat

# The SDK's own terrain material (M_LevelTerrain — the shiny lime green). Reused
# verbatim on our untextured map-context terrain so it matches the shipped
# playable terrain exactly (same shader/colour/shininess), instead of our flat
# unshaded green. Fetched from the live scene; falls back to our flat green.
func _sdk_terrain_material(root: Node, map: String) -> Material:
	return _sdk_material(root, "%s_Terrain" % map, terrain_material())

# The SDK's own asset placeholder material (M_LevelAssets — shiny orange), reused
# on our untextured map-context objects so they match the shipped assets.
func _sdk_assets_material(root: Node, map: String) -> Material:
	return _sdk_material(root, "%s_Assets" % map, assets_material())

func _sdk_material(root: Node, node_name: String, fallback: Material) -> Material:
	var node := root.find_child(node_name, true, false)
	if node == null: return fallback
	var mi := _first_mesh(node)
	if mi == null or mi.mesh == null: return fallback
	var m := mi.get_surface_override_material(0)
	if m == null: m = mi.mesh.surface_get_material(0)
	return m if m != null else fallback

# The shipped maptile jpg is a top-down satellite covering ONLY the playable
# area (~1000-2100m per map, NOT the full heightfield). Rather than guess its
# world extent, we reuse the exact per-map placement the community "TexturedMaps"
# pack tuned by hand: a Decal projecting the jpg straight down onto whatever
# terrain is beneath it (the SDK's terrain AND our extended terrain), so it lands
# pixel-accurate with zero alignment math. pos = decal centre, size = XZ extent x
# projection height, nf = normal_fade. Keyed by level-scene root name.
const MAPTILE_DECALS := {
	"MP_Abbasid": {"pos": Vector3(-84.688, 64.872, 122.928), "size": Vector3(1085, 100, 1085), "nf": 0.49},
	"MP_Aftermath": {"pos": Vector3(-576.833, 61.616, -30.161), "size": Vector3(878, 150, 878), "nf": 0.514},
	# Portal variant of Aftermath: same world space; "tile" reuses MP_Aftermath's
	# maptile jpg (the SDK ships no MP_Aftermath_Portal.jpg of its own)
	"MP_Aftermath_Portal": {"pos": Vector3(-576.833, 61.616, -30.161), "size": Vector3(878, 150, 878), "nf": 0.514, "tile": "MP_Aftermath"},
	"MP_Badlands": {"pos": Vector3(0.475, 95.294, -100.406), "size": Vector3(1400, 100, 1400), "nf": 0.515},
	"MP_Battery": {"pos": Vector3(696.983, 0, 88.527), "size": Vector3(1400, 500, 1400), "nf": 0.51},
	"MP_Capstone": {"pos": Vector3(0.112, 0, -168.568), "size": Vector3(1400, 1000, 1400), "nf": 0.408},
	"MP_Contaminated": {"pos": Vector3(-0.356, 262.189, -99.707), "size": Vector3(1400, 1000, 1400), "nf": 0.471},
	"MP_Dumbo": {"pos": Vector3(0.137, 0, -154.76), "size": Vector3(1400, 1000, 1400), "nf": 0.496},
	"MP_Eastwood": {"pos": Vector3(0.07, 0, -187.89), "size": Vector3(1400, 1000, 1400), "nf": 0},
	"MP_FireStorm": {"pos": Vector3(0.144, 0, 21.261), "size": Vector3(1642, 1000, 1642), "nf": 0.492},
	"MP_GolmudRailway": {"pos": Vector3(-125.62, 637.725, 850.344), "size": Vector3(2100, 1000, 2100), "nf": 0.489},
	"MP_Granite_ClubHouse_Portal": {"pos": Vector3(-449.986, 193.789, -574.909), "size": Vector3(1000, 1000, 1000), "nf": 0.508},
	"MP_Granite_MainStreet_Portal": {"pos": Vector3(-1106.69, 0, 152.565), "size": Vector3(1000, 1000, 1000), "nf": 0.51},
	"MP_Granite_Marina_Portal": {"pos": Vector3(-1201.9, 122.79, -604.9), "size": Vector3(1000, 1000, 1000), "nf": 0.504},
	"MP_Granite_MilitaryRnD_Portal": {"pos": Vector3(469, 0, -685.396), "size": Vector3(1000, 1000, 1000), "nf": 0.51},
	"MP_Granite_MilitaryStorage_Portal": {"pos": Vector3(561.774, 0, 388.344), "size": Vector3(1000, 1000, 1000), "nf": 0.527},
	"MP_Granite_TechCampus_Portal": {"pos": Vector3(-209.754, 0, 320.753), "size": Vector3(1000, 1000, 1000), "nf": 0.502},
	"MP_Granite_Underground_Portal": {"pos": Vector3(785.048, 239.369, -404.124), "size": Vector3(1000, 200, 1000), "nf": 0.5},
	"MP_Limestone": {"pos": Vector3(696.708, 22.57, 88.363), "size": Vector3(1400, 1000, 1400), "nf": 0.481},
	"MP_Outskirts": {"pos": Vector3(-381.997, 0, -89.8), "size": Vector3(1740, 1000, 1740), "nf": 0.532},
	"MP_Plaza": {"pos": Vector3(14.265, 0, 100.163), "size": Vector3(1000, 1000, 1000), "nf": 0.512},
	# Portal_Sand is a blank desert canvas: uniform sand maptile + no placed objects.
	# Full-terrain bounds so the whole heightfield reads as sand (its only detail
	# layer available is Capstone's greenish ground; restricting bounds would show
	# green vista). pos.y/size.y span the 0..330 m dune height for the decal box.
	"MP_Portal_Sand": {"pos": Vector3(0, 165, 0), "size": Vector3(8192, 700, 8192), "nf": 0.5},
	"MP_Subsurface": {"pos": Vector3(0.513, 66.437, -104.04), "size": Vector3(1420, 100, 1420), "nf": 0.511},
	"MP_Tungsten": {"pos": Vector3(60.235, 86.514, -25.078), "size": Vector3(1550, 100, 1550), "nf": 0.507},
}
const DECAL_NODE := "_MAPTILE_DECAL"
const WATER_NODE := "_WATER"

# Water is a flat surface entity (WaterEntityData), not a mesh placement. Its
# exact plane (surface height Y, world centre, X/Z extent) is EXTRACTED per map
# from the level's water.ebx and shipped in placements.json ("water"). A flat
# plane at that height is exact for the surface: terrain above it occludes it, so
# it shows only where the ground is below the waterline. Maps with no water body
# carry no "water" key and get no plane. (No guessed/global water.)
const WATER_COLOR := Color(0.10, 0.22, 0.30, 0.72)

# ---------- map identity ----------
static func map_of(root: Node) -> String:
	# level scene roots are named exactly "MP_<Map>"
	if root == null: return ""
	var n := String(root.name)
	return n if n.begins_with("MP_") else ""

func base_url() -> String:
	return HighpolyUpdater.manifest_url().get_base_dir() + "/"

# ---------- data fetch (per-map, cached) ----------
func _cache_dir() -> String:
	return "%s/%s" % [CACHE, _map]

func has_data(map: String) -> bool:
	return FileAccess.file_exists("%s/%s/placements.json" % [CACHE, map])

# Audit what's cached vs. what the manifest needs. Returns a human string and
# prints to the Output panel so problems are visible without a live debugger.
func cache_status(map: String) -> String:
	var dir := "%s/%s" % [CACHE, map]
	var pjp := "%s/placements.json" % dir
	if not FileAccess.file_exists(pjp):
		var s := "MapContext[%s]: NO placements.json in %s (nothing downloaded yet)" % [map, dir]
		print(s); return s
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(pjp))
	if not (d is Dictionary):
		var s := "MapContext[%s]: placements.json unreadable" % map
		print(s); return s
	var hm: Dictionary = d.get("heightmap", {})
	var terr_have := hm.has("file") and FileAccess.file_exists("%s/%s" % [dir, hm["file"]])
	var need := 0; var have := 0
	for e in d.get("backdrop", []):
		if e is Dictionary and e.has("glb"):
			need += 1
			if FileAccess.file_exists("%s/%s" % [dir, e["glb"]]): have += 1
	var s := "MapContext[%s]: terrain=%s, surroundings %d/%d cached, dir=%s" % [
		map, ("yes" if terr_have else "MISSING"), have, need, ProjectSettings.globalize_path(dir)]
	print(s); return s

func _fetch_once(host: Node, url: String, to_file := "") -> PackedByteArray:
	var http := HTTPRequest.new(); host.add_child(http)
	if to_file != "": http.download_file = to_file
	var err := http.request(url)
	if err != OK: http.queue_free(); return PackedByteArray()
	var res: Array = await http.request_completed
	http.queue_free()
	# 200 = ok. r2.dev rate-limits (403/429/5xx) under rapid sequential pulls.
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return PackedByteArray()
	if to_file != "" and not FileAccess.file_exists(to_file):
		return PackedByteArray()
	return res[3] if to_file == "" else PackedByteArray([1])

# retry with backoff — the public r2.dev host throttles bursts
func _fetch(host: Node, url: String, to_file := "") -> PackedByteArray:
	for attempt in range(4):
		var r := await _fetch_once(host, url, to_file)
		if not r.is_empty(): return r
		# brief backoff before retrying (0.4s, 0.8s, 1.6s)
		var t := host.get_tree().create_timer(0.4 * pow(2, attempt))
		await t.timeout
	return PackedByteArray()

# Large-file download straight to disk with a live "N MB" progress callback
# (total_mb = 0 hides the total). Returns true on HTTP 200 + file present.
func _download_with_progress(host: Node, url: String, to_file: String, status: Callable,
		label: String, total_mb := 0) -> bool:
	var http := HTTPRequest.new(); host.add_child(http)
	http.download_file = to_file
	var tick := Timer.new(); tick.wait_time = 0.5; host.add_child(tick); tick.start()
	tick.timeout.connect(func():
		var d := http.get_downloaded_bytes()
		if d > 0:
			var mb := d / 1048576
			status.call("%s %d%s MB…" % [label, mb, (" / %d" % total_mb) if total_mb > 0 else ""]))
	var ok := false
	if http.request(url) == OK:
		var res: Array = await http.request_completed
		ok = res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200 and FileAccess.file_exists(to_file)
	tick.queue_free(); http.queue_free()
	return ok

# ---------- package freshness (ETags) ----------
func _etags_path(map: String) -> String:
	return "%s/%s/etags.json" % [CACHE, map]

func _etags(map: String) -> Dictionary:
	if FileAccess.file_exists(_etags_path(map)):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(_etags_path(map)))
		if j is Dictionary: return j
	return {}

func _save_etag(map: String, key: String, val: String) -> void:
	if val == "": return
	var d := _etags(map)
	d[key] = val
	DirAccess.make_dir_recursive_absolute("%s/%s" % [CACHE, map])
	var f := FileAccess.open(_etags_path(map), FileAccess.WRITE)
	if f: f.store_string(JSON.stringify(d)); f.close()

# Record the CURRENT remote ETag for a package we just downloaded in full.
func _stamp_etag(host: Node, map: String, key: String, url: String) -> void:
	var http := HTTPRequest.new(); host.add_child(http)
	var tag := await HighpolyUpdater.remote_etag(http, url)
	http.queue_free()
	_save_etag(map, key, tag)

# Once per session per map: are the published packages newer than our cache?
# Returns {"mapdata": bool, "props": bool}; network failure = not stale (the
# cached data keeps working offline, and we re-check next session).
func _check_freshness(host: Node, map: String) -> Dictionary:
	var out := {"mapdata": false, "props": false}
	var have := _etags(map)
	var b := base_url() + "maps/%s/" % map
	var http := HTTPRequest.new(); host.add_child(http)
	for key in ["mapdata", "props"]:
		var tag: String = await HighpolyUpdater.remote_etag(http, b + key + ".zip")
		if tag != "" and tag != str(have.get(key, "")):
			out[key] = true
	http.queue_free()
	return out

func _purge_terrain_cache(map: String) -> void:
	var dir := "%s/%s" % [CACHE, map]
	var da := DirAccess.open(dir)
	if da == null: return
	for f in da.get_files():
		if f.begins_with("terrain_s") and f.ends_with(".res"):
			DirAccess.remove_absolute("%s/%s" % [dir, f])

# Download a map's data as ONE zip (terrain + placements + backdrop glbs) and
# extract it. A single request avoids the r2.dev burst-throttling that 38
# separate downloads trip. Idempotent: if placements.json is already cached and
# all backdrop files present, does nothing. status is Callable(String).
func download_map(host: Node, map: String, status: Callable, force := false) -> bool:
	var b := base_url() + "maps/%s/" % map
	var dir := "%s/%s" % [CACHE, map]
	DirAccess.make_dir_recursive_absolute(dir)
	# self-heal: on first touch this session, compare package ETags; a
	# republished mapdata.zip forces a fresh pull (incl. rebuilding the cached
	# terrain meshes), a republished props.zip flags an overwrite-all extract
	if has_data(map) and not _session_checked.get(map, false):
		_session_checked[map] = true
		var fresh: Dictionary = await _check_freshness(host, map)
		if fresh.get("props", false):
			_props_refresh[map] = true
		if fresh.get("mapdata", false):
			status.call("%s map data was updated — refreshing…" % map)
			force = true
	if force:
		# force a fresh pull (e.g. the map data format changed): drop the manifest
		# AND the terrain meshes built from the old heightmap
		DirAccess.remove_absolute("%s/placements.json" % dir)
		_purge_terrain_cache(map)
	if _map_cache_complete(map):
		status.call("%s map data ready" % map); return true
	# size (optional, for the status line)
	var total_mb := 0
	var meta_raw := await _fetch(host, b + "mapdata.json")
	if not meta_raw.is_empty():
		var meta: Variant = JSON.parse_string(meta_raw.get_string_from_utf8())
		if meta is Dictionary: total_mb = int(int(meta.get("bytes", 0)) / 1048576.0)
	status.call("Downloading %s map data%s…" % [map, (" (~%d MB)" % total_mb) if total_mb else ""])
	var tmp := "%s/mapdata.zip" % dir
	var got_ok := await _download_with_progress(host, b + "mapdata.zip", tmp, status,
		"Downloading %s map data:" % map, total_mb)
	if not got_ok:
		status.call("Map data download failed (server busy — try Reload again)")
		return false
	status.call("Extracting %s…" % map)
	var zr := ZIPReader.new()
	if zr.open(ProjectSettings.globalize_path(tmp)) != OK:
		status.call("Map archive unreadable"); return false
	var n := 0
	for f in zr.get_files():
		if f.ends_with("/"): continue
		var dest := "%s/%s" % [dir, f]
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out: out.store_buffer(zr.read_file(f)); out.close(); n += 1
	zr.close()
	DirAccess.remove_absolute(tmp)
	await _stamp_etag(host, map, "mapdata", b + "mapdata.zip")
	status.call("%s map data ready (%d files)" % [map, n])
	return _map_cache_complete(map)

# True when the cached manifest AND every file it references (heightmap blob +
# backdrop glbs) are on disk — i.e. nothing left to download for this map.
func _map_cache_complete(map: String) -> bool:
	var dir := "%s/%s" % [CACHE, map]
	var pjp := "%s/placements.json" % dir
	if not FileAccess.file_exists(pjp): return false
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(pjp))
	if not (d is Dictionary): return false
	var hm: Dictionary = d.get("heightmap", {})
	if hm.has("file") and not FileAccess.file_exists("%s/%s" % [dir, hm["file"]]): return false
	for e in d.get("backdrop", []):
		if e is Dictionary and e.has("glb") and not FileAccess.file_exists("%s/%s" % [dir, e["glb"]]):
			return false
	return true

# ---------- apply / build ----------
func _clear(root: Node) -> void:
	# cancel any in-flight background props build: the builder re-checks this
	# generation after every await and stops dead once it changes (its nodes
	# are freed with _MAP_CONTEXT below)
	_build_gen += 1
	_building = false
	# detach/stop the scatter BEFORE freeing the tree it lives under: its
	# camera-follow tick holds MultiMeshInstance3D refs that must not outlive
	# _MAP_CONTEXT (frees now interleave with running ticks across frames)
	_scatter.clear()      # scatter lives under _MAP_CONTEXT; drop its caches too
	_scatter_n = 0
	# name-pattern sweep: plugin reloads orphan the owner=null overlay; a
	# rebuilt twin gets auto-renamed next to it and a single-name lookup then
	# frees the wrong one (doubled props / undead overlays)
	for c in root.get_children():
		if String(c.name).contains(NODE):
			root.remove_child(c)
			c.queue_free()
	_cells.clear()
	_bd_list.clear()
	# drop the in-RAM caches so a re-apply re-reads the on-disk files (picks up
	# prop textures / terrain layers updated since the last apply)
	_mesh_cache.clear()
	_mesh_stat.clear()     # refresh bookkeeping follows the mesh cache
	_prop_by_src.clear()
	_layer_cache.clear()
	_splat_cache.clear()   # re-read baked splat data on the next apply
	# remove the maptile decal (editor-only)
	_remove_maptile(root)

# ---------- SDK maptile (top-down satellite) ----------
# Inject a Decal (owner=null) that projects the shipped maptile jpg straight
# down onto whatever terrain is beneath it — the SDK's own terrain AND our
# extended terrain — using the community pack's hand-tuned per-map placement.
# Reversible, never saved. Works with or without extended map data downloaded.
func _apply_maptile(root: Node, map: String) -> int:
	if not MAPTILE_DECALS.has(map): return 0
	# "tile" lets a variant map (e.g. MP_Aftermath_Portal) reuse another map's jpg
	var img_path := "res://raw/maptiles/%s.jpg" % MAPTILE_DECALS[map].get("tile", map)
	if not ResourceLoader.exists(img_path): return 0
	var tex = load(img_path)
	if tex == null: return 0
	var d: Dictionary = MAPTILE_DECALS[map]
	var dec := Decal.new()
	dec.name = DECAL_NODE
	dec.texture_albedo = tex
	dec.size = d["size"]
	dec.normal_fade = float(d.get("nf", 0.0))
	# hit everything EXCEPT our extended terrain (which carries its own detail
	# shader) — so the decal only textures the SDK terrain + assets/buildings and
	# doesn't re-flatten our detailed map-context terrain where they overlap.
	dec.cull_mask = 0xFFFFF & ~EXT_TERRAIN_LAYER
	dec.position = d["pos"]
	root.add_child(dec); dec.owner = null
	return 1

# Remove EVERY maptile decal under the root — matched by name prefix, not just
# the exact name, so a stray auto-renamed duplicate (add_child name collision)
# can't survive an exact-name lookup and linger forever.
func _remove_maptile(root: Node) -> void:
	for c in root.get_children():
		if c is Decal and String(c.name).contains(DECAL_NODE):
			root.remove_child(c)
			c.queue_free()

# Instant "Maptile decal" toggle (dock checkbox). ACTIVE add/remove — no
# overlay rebuild, no _clear(), no generation bump, so a running props build
# keeps going. Off: the decal is pulled from the scene right now (before any
# await could supersede a re-apply). On: re-added immediately when the last
# apply() ran textured without splat coverage (_maptile_ok); otherwise the
# static preference simply takes effect on the next textured apply.
func set_maptile(root: Node, on: bool) -> String:
	maptile_enabled = on
	if root == null or map_of(root) == "":
		return "Maptile decal %s (takes effect on MP_… scenes)" % ("on" if on else "off")
	_remove_maptile(root)
	if not on:
		return "Maptile decal off"
	if _maptile_ok:
		return "Maptile decal on" if _apply_maptile(root, map_of(root)) > 0 \
			else "No maptile for %s" % map_of(root)
	return "Maptile decal on (shows in textured, non-splat mode)"

# ---------- near-exact detail terrain (real game ground-layer textures) ----------
# The maptile gives the real large-scale colour; the game's own tiling ground
# layers (albedo + normal, extracted from the terrainmaterials palette) add crisp
# close-up detail. Layer selected by surface slope (flat = ground, steep = cliff).
# Normal is applied in view space (no mesh tangents needed).
# bundled fallback layers live next to this script (path derived at runtime so
# the plugin works from any install folder under addons/)
static func _layer_dir() -> String:
	return (HighpolyMapContext as Script).resource_path.get_base_dir() + "/terrain_layers/"
# dedicated render layer for our extended terrain, so the SDK maptile decal can
# be told to skip it (the decal only textures the SDK's own terrain + assets)
const EXT_TERRAIN_LAYER := 1 << 19
const TERRAIN_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D maptile : source_color, filter_linear_mipmap;
uniform vec4 map_bounds;                 // xmin, zmin, sizeX, sizeZ (world)
uniform sampler2D ground_alb : source_color, filter_linear_mipmap;
uniform sampler2D ground_nrm : filter_linear_mipmap;
uniform sampler2D cliff_alb : source_color, filter_linear_mipmap;
uniform sampler2D cliff_nrm : filter_linear_mipmap;
uniform float tile_scale = 4.0;          // world metres per detail-texture repeat
uniform float detail_strength = 0.5;
uniform float normal_strength = 0.7;
uniform float slope_lo = 0.35;
uniform float slope_hi = 0.70;
uniform float edge_fade = 0.03;          // soft blend at the maptile border (uv fraction)
// EXACT splat data (baked from the game's own terrain layer masks — see the
// pipeline's splat_build.py). splat_slices = 0 (default) keeps the legacy
// slope ground/cliff heuristic, so maps/packages without splat data render
// exactly as before.
uniform int splat_slices = 0;            // layer_alb/layer_nrm slice count
uniform vec4 splat_bounds;               // xmin, zmin, sizeX, sizeZ (world)
uniform sampler2D splat_idx : filter_nearest, repeat_disable;  // top-4 table idx (x255)
uniform sampler2D splat_w : filter_linear, repeat_disable;     // top-4 weights (sum=1)
uniform sampler2DArray layer_alb : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_nrm : filter_linear_mipmap, repeat_enable;
varying vec3 wpos;
varying vec3 wnorm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	// slope-selected tiling ground detail — the legacy heuristic, kept as the
	// fallback for texels/maps without splat data and for out-of-slice layers
	float slope = clamp(1.0 - wnorm.y, 0.0, 1.0);
	float b = smoothstep(slope_lo, slope_hi, slope);
	vec2 tuv = wpos.xz / tile_scale;
	vec3 fb_alb = mix(texture(ground_alb, tuv).rgb, texture(cliff_alb, tuv).rgb, b);
	vec3 fb_nrm = mix(texture(ground_nrm, tuv).rgb, texture(cliff_nrm, tuv).rgb, b);
	vec3 det = fb_alb;
	vec3 nrm = fb_nrm;
	if (splat_slices > 0) {
		// exact per-texel layer blend: 4 table indices (nearest) + 4 weights
		// (linear — weights fall to 0 where indices change, hiding idx seams)
		vec2 suv = vec2((wpos.x - splat_bounds.x) / splat_bounds.z,
		                (wpos.z - splat_bounds.y) / splat_bounds.w);
		if (suv.x >= 0.0 && suv.x <= 1.0 && suv.y >= 0.0 && suv.y <= 1.0) {
			vec4 sid = texture(splat_idx, suv) * 255.0;
			vec4 sw = texture(splat_w, suv);
			vec3 acc = vec3(0.0);
			vec3 nacc = vec3(0.0);
			float tot = 0.0;
			for (int i = 0; i < 4; i++) {
				float wi = sw[i];
				if (wi < 0.004) { continue; }
				int id = int(sid[i] + 0.5);
				if (id < splat_slices) {
					acc += wi * texture(layer_alb, vec3(tuv, float(id))).rgb;
					nacc += wi * texture(layer_nrm, vec3(tuv, float(id))).rgb;
				} else {
					acc += wi * fb_alb;      // unpackaged layer: slope fallback
					nacc += wi * fb_nrm;
				}
				tot += wi;
			}
			if (tot > 0.01) {
				det = acc / tot;
				nrm = nacc / tot;
			}
		}
	}
	float dl = dot(det, vec3(0.3333));

	// maptile weight: 1 inside the satellite footprint, faded to 0 at its edge
	vec2 muv = vec2((wpos.x - map_bounds.x) / map_bounds.z, (wpos.z - map_bounds.y) / map_bounds.w);
	float in01 = step(0.0, muv.x) * step(muv.x, 1.0) * step(0.0, muv.y) * step(muv.y, 1.0);
	vec2 edge = min(muv, 1.0 - muv);
	float w = in01 * smoothstep(0.0, edge_fade, min(edge.x, edge.y));

	// inside: the real satellite colour as the large-scale tint, grained by the
	// (now splat-exact) detail layers. outside (and over the maptile's black
	// out-of-bounds borders): the tiling detail colour alone.
	vec3 mt = texture(maptile, muv).rgb;
	w *= smoothstep(0.03, 0.12, dot(mt, vec3(0.3333)));   // drop the black borders
	vec3 inside = mt * mix(1.0, dl * 2.0, detail_strength) * mix(vec3(1.0), det / (dl + 1e-3), 0.3 * detail_strength);
	ALBEDO = clamp(mix(det, inside, w), 0.0, 1.0);
	ROUGHNESS = 0.92;
	vec2 nxy = (nrm.rg * 2.0 - 1.0) * normal_strength;
	float nz = sqrt(clamp(1.0 - dot(nxy, nxy), 0.0, 1.0));
	vec3 N = normalize(wnorm);
	vec3 T = normalize(vec3(1.0, 0.0, 0.0) - N * N.x);
	vec3 Bt = cross(N, T);
	vec3 wn = normalize(nxy.x * T + nxy.y * Bt + nz * N);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
}
"""
static var _tshader: Shader = null
static var _layer_cache: Dictionary = {}   # "<map>/<name>" -> Texture2D (or null)
# ---------- exact splat data (baked from the game's terrain layer masks) ----------
# user://mapcontext/<map>/splat/{idx.png, w.png, layers.json, lNN_alb/_nrm.png,
# grass_mask.png} — produced by the pipeline's splat_build.py. Maps without the
# files (older packages, graph-layer city maps) keep the legacy heuristic path.
static var _splat_cache: Dictionary = {}   # map -> Dictionary ({} = none)
var _splat_active := false                 # last _terrain_shader_mat had splat data
var _splat_n := 0                          # its texture-array slice count
# With splat shading the extended terrain (which spans the WHOLE footprint,
# including under the SDK bowl) becomes the ground truth. It is lifted slightly
# so it wins the depth test against the SDK's own coincident bowl mesh — the
# maptile decal that used to mask that z-fight is gone in splat mode.
const SPLAT_LIFT := 0.15

# Load a map's baked splat set (cached): textures + world box + slice count.
# Returns {} when the map package carries no usable splat data.
func _splat_set(map: String) -> Dictionary:
	if _splat_cache.has(map): return _splat_cache[map]
	var out: Dictionary = {}
	var dir := "%s/%s/splat" % [CACHE, map]
	var lj := "%s/layers.json" % dir
	if FileAccess.file_exists(lj) and FileAccess.file_exists("%s/idx.png" % dir) \
			and FileAccess.file_exists("%s/w.png" % dir):
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(lj))
		if meta is Dictionary and int((meta as Dictionary).get("slices", 0)) > 0 \
				and (meta as Dictionary).get("world", {}) is Dictionary:
			var slices := int(meta["slices"])
			var wj: Dictionary = meta["world"]
			var idx_img := Image.load_from_file(ProjectSettings.globalize_path("%s/idx.png" % dir))
			var w_img := Image.load_from_file(ProjectSettings.globalize_path("%s/w.png" % dir))
			var albs: Array[Image] = []
			var nrms: Array[Image] = []
			for i in range(slices):
				var a := Image.load_from_file(ProjectSettings.globalize_path("%s/l%02d_alb.png" % [dir, i]))
				var n := Image.load_from_file(ProjectSettings.globalize_path("%s/l%02d_nrm.png" % [dir, i]))
				if a == null or n == null:
					albs.clear()
					break
				a.convert(Image.FORMAT_RGB8); a.generate_mipmaps(); albs.append(a)
				n.convert(Image.FORMAT_RGB8); n.generate_mipmaps(); nrms.append(n)
			if idx_img != null and w_img != null and albs.size() == slices:
				idx_img.convert(Image.FORMAT_RGBA8)   # indices: MUST stay unfiltered/no mips
				w_img.convert(Image.FORMAT_RGBA8)
				var ta := Texture2DArray.new(); ta.create_from_images(albs)
				var tn := Texture2DArray.new(); tn.create_from_images(nrms)
				out = {
					"idx": ImageTexture.create_from_image(idx_img),
					"w": ImageTexture.create_from_image(w_img),
					"alb": ta, "nrm": tn, "slices": slices,
					"bounds": Vector4(float(wj.get("x0", 0.0)), float(wj.get("z0", 0.0)),
						float(wj.get("size", 1.0)), float(wj.get("size", 1.0))),
				}
	_splat_cache[map] = out
	return out

# Detail-layer texture for a map: prefer the PER-MAP layer shipped in the map
# package (user://mapcontext/<map>/terrain_layers/<name>.png — the real ground/
# cliff set that map streams in game), falling back per file to the plugin's
# bundled default set.
func _layer_tex(map: String, nm: String) -> Texture2D:
	var key := "%s/%s" % [map, nm]
	if _layer_cache.has(key): return _layer_cache[key]
	var t: Texture2D = null
	var per_map := "%s/%s/terrain_layers/%s.png" % [CACHE, map, nm]
	if FileAccess.file_exists(per_map):
		var img := Image.load_from_file(ProjectSettings.globalize_path(per_map))
		if img != null:
			img.generate_mipmaps()
			t = ImageTexture.create_from_image(img)
	if t == null:
		var p := _layer_dir() + nm + ".png"
		t = load(p) if ResourceLoader.exists(p) else null
	_layer_cache[key] = t
	return t

# Build the detail-terrain material for this map, or null if the maptile or the
# ground-layer set isn't available (→ caller falls back to the flat decal).
func _terrain_shader_mat(map: String) -> ShaderMaterial:
	if not MAPTILE_DECALS.has(map): return null
	var img := "res://raw/maptiles/%s.jpg" % MAPTILE_DECALS[map].get("tile", map)
	if not ResourceLoader.exists(img): return null
	var ga := _layer_tex(map, "ground_alb"); var gn := _layer_tex(map, "ground_nrm")
	var ca := _layer_tex(map, "cliff_alb"); var cn := _layer_tex(map, "cliff_nrm")
	if ga == null or gn == null or ca == null or cn == null: return null
	if _tshader == null:
		_tshader = Shader.new(); _tshader.code = TERRAIN_SHADER
	var d: Dictionary = MAPTILE_DECALS[map]
	var pos: Vector3 = d["pos"]; var sz: Vector3 = d["size"]
	var m := ShaderMaterial.new()
	m.shader = _tshader
	m.set_shader_parameter("maptile", load(img))
	m.set_shader_parameter("map_bounds", Vector4(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5, sz.x, sz.z))
	m.set_shader_parameter("ground_alb", ga); m.set_shader_parameter("ground_nrm", gn)
	m.set_shader_parameter("cliff_alb", ca); m.set_shader_parameter("cliff_nrm", cn)
	# exact splat blend where the map package ships baked splat data; without it
	# splat_slices stays 0 and the shader keeps the legacy slope heuristic
	_splat_active = false
	_splat_n = 0
	var sp := _splat_set(map)
	if not sp.is_empty():
		m.set_shader_parameter("splat_idx", sp["idx"])
		m.set_shader_parameter("splat_w", sp["w"])
		m.set_shader_parameter("layer_alb", sp["alb"])
		m.set_shader_parameter("layer_nrm", sp["nrm"])
		m.set_shader_parameter("splat_bounds", sp["bounds"])
		m.set_shader_parameter("splat_slices", int(sp["slices"]))
		_splat_active = true
		_splat_n = int(sp["slices"])
	return m

func _load_data(map: String) -> bool:
	var p := "%s/%s/placements.json" % [CACHE, map]
	if not FileAccess.file_exists(p): return false
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary): return false
	_data = d
	_map = map
	var w: Dictionary = d.get("world", {})
	_world_min = float(w.get("min", -2048))
	_cell_size = float(w.get("cell", 64))
	_load_prop_layers(map)
	return true

# ---------- per-layer prop attribution (prop_layers.json) ----------
# Mined per-instance layer tags: 89.9% of placements are always-on; the rest
# belong to event layers (default summer vs winter dressing, gauntlet) or
# per-gamemode containers (Rush barriers...). The builder splits those
# instances into layer GROUPS whose visibility follows the Variant dropdown —
# so the variant genuinely controls object placements, instantly.
var _prop_layers: Dictionary = {}       # mesh -> {int i -> "layerKey[,layerKey]"}
var _mode_map: Dictionary = {}          # ModeName -> {show_layers:[...]}
var _variant_layer_groups: Dictionary = {}   # layerKey -> Node3D
var _variant_mode := "Off"

func _load_prop_layers(map: String) -> void:
	_prop_layers = {}
	_mode_map = {}
	var p := "%s/%s/prop_layers.json" % [CACHE, map]
	if not FileAccess.file_exists(p): return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary): return
	for rec in d.get("props", []):
		if not (rec is Dictionary): continue
		var mesh := str(rec.get("mesh", ""))
		var lv: Variant = rec.get("layer")
		var key: String
		if lv is Array:
			var arr: Array = []
			for x in lv: arr.append(str(x))
			arr.sort()
			key = ",".join(arr)
		else:
			key = str(lv)
		if not _prop_layers.has(mesh): _prop_layers[mesh] = {}
		(_prop_layers[mesh] as Dictionary)[int(rec.get("i", -1))] = key
	_mode_map = d.get("mode_map", {})

func _active_variant_layers(mode: String) -> Dictionary:
	# "Off"/unknown = the normal game look: default-event dressing only
	var act := {"default_event": true}
	var mm: Dictionary = _mode_map.get(mode, {})
	if not mm.is_empty():
		act = {}
		for l in mm.get("show_layers", ["default_event"]):
			act[str(l)] = true
	return act

func _variant_key_visible(key: String, act: Dictionary) -> bool:
	for part in key.split(","):
		if act.has(part):
			return true
	return false

# live layer switch — pure visibility flips, no rebuild
func set_variant_layers(mode: String) -> String:
	_variant_mode = mode
	var act := _active_variant_layers(mode)
	var n := 0
	for k in _variant_layer_groups:
		var g: Node3D = _variant_layer_groups[k]
		if is_instance_valid(g):
			g.visible = _variant_key_visible(str(k), act)
			n += 1
	return "%s: %d placement layer group(s) switched" % [
		mode if mode != "" else "Off", n]

func _variant_group(props_root: Node3D, key: String) -> Node3D:
	if _variant_layer_groups.has(key):
		var g0: Node3D = _variant_layer_groups[key]
		if is_instance_valid(g0):
			return g0
	var g := Node3D.new()
	g.name = "V_" + key.replace(",", "+")
	props_root.add_child(g)
	g.owner = null
	g.visible = _variant_key_visible(key, _active_variant_layers(_variant_mode))
	_variant_layer_groups[key] = g
	return g

# source file a prop entry's mesh loads from: `mesh` = SHARED prop cache
# (preferred), `glb` = legacy per-map bundle. "" = res:// SDK proxy / none —
# those aren't file-refreshable.
func _prop_path(e: Dictionary, dir: String) -> String:
	if e.has("mesh"): return "%s/%s.glb" % [PROPS_CACHE, e["mesh"]]
	if e.has("glb"): return "%s/%s" % [dir, e["glb"]]
	return ""

static func _file_size(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null: return -1
	var n := int(f.get_length())
	f.close()
	return n

# A prop's mesh: the EXACT extracted game mesh from the downloaded per-map props
# bundle (`glb`) when available — the accurate path — else the res:// SDK proxy
# (`model`) fallback for meshes we haven't extracted yet.
func _prop_mesh(e: Dictionary, dir: String) -> Mesh:
	var gp := _prop_path(e, dir)
	if gp == "":
		return _mesh_for(str(e["model"])) if e.has("model") else null
	if _mesh_cache.has(gp): return _mesh_cache[gp]
	# stamp the source BEFORE parsing: if the background re-bake overwrites the
	# file mid-parse, the recorded (pre-write) stamp differs from the new one
	# and refresh_changed_props still catches it. Missing files stamp mt=0, so
	# a mesh that APPEARS later counts as changed too.
	_mesh_stat[gp] = {
		"mt": FileAccess.get_modified_time(gp) if FileAccess.file_exists(gp) else 0,
		"sz": _file_size(gp),
	}
	var m := _parse_prop_file(gp)
	_mesh_cache[gp] = m
	return m

# "Fast startup cache" (Storage section): after the first parse each finished
# mesh is saved as a binary sidecar (<x>.glb.baked.res) and loaded directly on
# later builds — skipping the glTF parse + texture recompress + merge that made
# every editor/plugin restart re-chew ~2k GLBs for minutes. A sidecar older
# than its GLB (re-download / re-bake) is stale and re-parses, so updated
# models flow through exactly like Check for Updates. Costs ~the model cache's
# size again on disk; per-map purge removes sidecars with their GLBs.
static var mesh_cache_enabled := false

# Parse a prop GLB from disk into one baked/merged Mesh — NO cache interaction,
# so the refresh path can build-then-swap (parse first, only then evict).
# Returns null for missing/torn/unparseable files.
func _parse_prop_file(gp: String) -> Mesh:
	# v2 suffix: v1 sidecars predate runtime LOD generation — regenerate once
	var baked := gp + ".baked2.res"
	if mesh_cache_enabled and FileAccess.file_exists(baked) \
			and FileAccess.get_modified_time(baked) >= FileAccess.get_modified_time(gp):
		var bm := ResourceLoader.load(baked, "Mesh", ResourceLoader.CACHE_MODE_REPLACE)
		if bm is Mesh:
			return bm
	var m: Mesh = null
	var g := _load_external_glb(gp)
	if g:
		var inst := g.instantiate()
		# merge ALL mesh nodes — multi-part GLBs (one node per material part,
		# e.g. dump-extracted window units: glass part + wall part) used to
		# render only their FIRST part via _first_mesh_and_xf, which showed
		# floating glass panes with the wall part silently dropped
		var pairs: Array = []
		_all_meshes_and_xf(inst, Transform3D(), pairs)
		if pairs.size() == 1:
			m = _bake_mesh(pairs[0][0], pairs[0][1])
		elif pairs.size() > 1:
			m = _merge_meshes(pairs)
		inst.queue_free()
	_fx_animate_materials(m)
	_wind_swap_materials(m)
	_parallax_materials(m)
	m = _with_lods(m)
	if mesh_cache_enabled and m != null:
		if ResourceSaver.save(m, baked, ResourceSaver.FLAG_COMPRESS) != OK:
			DirAccess.remove_absolute(baked)   # never leave a torn cache file
	return m

# ---------- Configure Shaders (dock dialog) ----------
# live-tunable overlay shader prefs, persisted by the dock:
#   water    – multiplier on each water body's AUTHORED ripple_speed (0 = still)
#   flip     – multiplier on flipbook-card animation speed (smoke; 0 = static)
#   wind     – subtle foliage sway on leaf-card materials
static var shader_prefs := {"water": 1.0, "flip": 1.0, "wind": false, "wind_str": 0.08}
const FLIP_BASE_SPEED := 0.25          # fx_smoke.gdshader authored default

# Backdrop-FX flipbook cards (smoke plumes): the baker tags materials whose
# sheet packs 3 animation-time samples in R/G/B with "__fxanim3" and keeps the
# packed data. Swap those for fx_smoke.gdshader, which crossfades the channels
# live — the smoke billows in the editor using the game's own texture data.
static var _fx_smoke_shader: Shader = null
static var _wind_shader: Shader = null
const WIND_MAT_PAT := "leaf|leaves|frond|foliage|grass|weed|plant|fern|bush"

static func _fx_animate_materials(m: Mesh) -> void:
	if not (m is ArrayMesh): return
	var am := m as ArrayMesh
	for i in range(am.get_surface_count()):
		var mat := am.surface_get_material(i)
		if mat is BaseMaterial3D and String(mat.resource_name).contains("__fxanim3"):
			if _fx_smoke_shader == null:
				_fx_smoke_shader = load((HighpolyMapContext as Script)
						.resource_path.get_base_dir() + "/fx_smoke.gdshader")
			if _fx_smoke_shader == null: return
			var sm := ShaderMaterial.new()
			sm.shader = _fx_smoke_shader
			sm.set_shader_parameter("packed_tex", (mat as BaseMaterial3D).albedo_texture)
			sm.set_shader_parameter("speed", FLIP_BASE_SPEED * float(shader_prefs.get("flip", 1.0)))
			am.surface_set_material(i, sm)

# Foliage Wind: swap leaf-card materials (name matches WIND_MAT_PAT AND the
# material is alpha-cutout — trunks/bark stay put) for foliage_wind.gdshader.
# Always swapped; wind_strength 0 renders identical to the original, so the
# dock toggle is a pure live uniform change.
static func _wind_swap_materials(m: Mesh) -> void:
	if not (m is ArrayMesh): return
	var rx := RegEx.create_from_string("(?i)(" + WIND_MAT_PAT + ")")
	var am := m as ArrayMesh
	for i in range(am.get_surface_count()):
		var mat := am.surface_get_material(i)
		if not (mat is BaseMaterial3D): continue
		var bm := mat as BaseMaterial3D
		if bm.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED: continue
		if bm.albedo_texture == null: continue
		if rx.search(String(bm.resource_name)) == null: continue
		if _wind_shader == null:
			_wind_shader = load((HighpolyMapContext as Script)
					.resource_path.get_base_dir() + "/foliage_wind.gdshader")
		if _wind_shader == null: return
		var sm := ShaderMaterial.new()
		sm.shader = _wind_shader
		sm.resource_name = bm.resource_name
		sm.set_shader_parameter("albedo_tex", bm.albedo_texture)
		sm.set_shader_parameter("albedo_mul", bm.albedo_color)
		sm.set_shader_parameter("alpha_cut", bm.alpha_scissor_threshold
				if bm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR else 0.5)
		sm.set_shader_parameter("wind_strength",
				float(shader_prefs.get("wind_str", 0.08)) if bool(shader_prefs.get("wind", false)) else 0.0)
		am.surface_set_material(i, sm)

# push the current shader_prefs onto every live overlay material (water plane,
# flipbook cards, foliage) — called by the dock's Configure Shaders dialog and
# after builds finish (sidecar-cached meshes carry the params they were saved
# with). Walk is cheap: materials only, no geometry.
func apply_shader_prefs(root: Node) -> String:
	var ctx := root.get_node_or_null(NODE) if root != null else null
	if ctx == null: return "Map Context off"
	var counts := {"water": 0, "flip": 0, "wind": 0}
	_prefs_walk(ctx, counts)
	return "Shaders: %d water, %d flipbook, %d foliage material(s) updated" % [
		counts["water"], counts["flip"], counts["wind"]]

func _prefs_walk(n: Node, counts: Dictionary) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		_prefs_mat(gi.material_override, counts)
		var mesh: Mesh = null
		if gi is MeshInstance3D: mesh = (gi as MeshInstance3D).mesh
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			mesh = (gi as MultiMeshInstance3D).multimesh.mesh
		if mesh != null:
			# meshes loaded from pre-wind sidecar caches still carry their
			# BaseMaterial3D foliage — swap them here so Foliage Wind reaches
			# them live (no-op on already-swapped/non-foliage surfaces)
			_wind_swap_materials(mesh)
			for i in range(mesh.get_surface_count()):
				_prefs_mat(mesh.surface_get_material(i), counts)
	for c in n.get_children():
		_prefs_walk(c, counts)

func _prefs_mat(mat: Material, counts: Dictionary) -> void:
	if not (mat is ShaderMaterial): return
	var sm := mat as ShaderMaterial
	if sm.shader == null: return
	var sp := String(sm.shader.resource_path)
	# water: HighpolyWater builds its Shader from TEXT (no resource_path — a
	# path match can NEVER hit it; that was "the water slider does nothing").
	# Detect it by its own parameter instead: every water material sets
	# ripple_speed explicitly from its kind preset.
	if sm.get_shader_parameter("ripple_speed") != null:
		if not sm.has_meta("base_ripple"):
			sm.set_meta("base_ripple", float(sm.get_shader_parameter("ripple_speed")))
		sm.set_shader_parameter("ripple_speed",
				float(sm.get_meta("base_ripple")) * float(shader_prefs.get("water", 1.0)))
		counts["water"] += 1
	elif sp.ends_with("/fx_smoke.gdshader"):
		sm.set_shader_parameter("speed", FLIP_BASE_SPEED * float(shader_prefs.get("flip", 1.0)))
		counts["flip"] += 1
	elif sp.ends_with("/foliage_wind.gdshader"):
		sm.set_shader_parameter("wind_strength",
				float(shader_prefs.get("wind_str", 0.08)) if bool(shader_prefs.get("wind", false)) else 0.0)
		counts["wind"] += 1

# VISTA PARALLAX: the size-adaptive skyline bake tags wall materials
# "__vtrparallax" and carries the facade's WINDOW DEPTH MASK in the albedo
# alpha (rendered opaque, so the channel is a free data carrier). Build a
# heightmap from it and enable deep parallax — the "massive depth fixes" the
# game's backdrop shader applies to distant facades.
static var _pxheights: Dictionary = {}    # texture RID -> heightmap ImageTexture
static func _parallax_materials(m: Mesh) -> void:
	if not (m is ArrayMesh): return
	var am := m as ArrayMesh
	for i in range(am.get_surface_count()):
		var mat := am.surface_get_material(i)
		if not (mat is BaseMaterial3D): continue
		var bm := mat as BaseMaterial3D
		if not String(bm.resource_name).contains("__vtrparallax"): continue
		if bm.albedo_texture == null: continue
		var key: Variant = bm.albedo_texture.get_rid()
		if not _pxheights.has(key):
			var img := bm.albedo_texture.get_image()
			if img == null: continue
			if img.is_compressed(): img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			var h := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_L8)
			for y in range(img.get_height()):
				for x in range(img.get_width()):
					# windows (alpha=1) sit LOW; walls high
					h.set_pixel(x, y, Color.from_hsv(0, 0, 1.0 - img.get_pixel(x, y).a))
			_pxheights[key] = ImageTexture.create_from_image(h)
		bm.heightmap_enabled = true
		bm.heightmap_texture = _pxheights[key]
		bm.heightmap_scale = 0.35          # ~35 cm window recess at vista scale
		bm.heightmap_deep_parallax = true
		bm.heightmap_min_layers = 4
		bm.heightmap_max_layers = 8

# RUNTIME MESH LODs: Godot only auto-generates LODs during editor import —
# runtime-loaded GLBs render FULL detail at any distance, which is why flying
# was vertex-bound even on a 4080. Rebuild each merged mesh through
# ImporterMesh.generate_lods(); the result (mesh + LOD chain) is what the
# fast-startup sidecar caches, so the generation cost is paid once.
static func _with_lods(m: Mesh) -> Mesh:
	if not (m is ArrayMesh): return m
	var am := m as ArrayMesh
	if am.get_surface_count() == 0: return m
	var im := ImporterMesh.new()
	for s in range(am.get_surface_count()):
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, am.surface_get_arrays(s),
				[], {}, am.surface_get_material(s))
	im.generate_lods(25.0, 60.0, [])
	var out := im.get_mesh()
	return out if out != null and out.get_surface_count() > 0 else m

# names of prop meshes this map needs that aren't in the shared cache yet
func _props_missing() -> Array:
	DirAccess.make_dir_recursive_absolute(PROPS_CACHE)
	var miss: Array = []
	var seen: Dictionary = {}
	for e in _data.get("props", []):
		if e is Dictionary and e.has("mesh"):
			var nm: String = e["mesh"]
			if seen.has(nm): continue
			seen[nm] = true
			if not FileAccess.file_exists("%s/%s.glb" % [PROPS_CACHE, nm]):
				miss.append(nm)
	# vegetation scatter kit meshes (scatter.json) live in the same shared cache
	for nm in _scatter_mesh_names():
		if seen.has(nm): continue
		seen[nm] = true
		if not FileAccess.file_exists("%s/%s.glb" % [PROPS_CACHE, nm]):
			miss.append(nm)
	return miss

# mesh names the map's scatter table needs ([] when the map has no scatter data)
func _scatter_mesh_names() -> Array:
	var p := "%s/%s/scatter.json" % [CACHE, _map]
	if not FileAccess.file_exists(p): return []
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary): return []
	var out: Array = []
	for e in (d as Dictionary).get("entries", []):
		if e is Dictionary and e.has("mesh"): out.append(str(e["mesh"]))
	return out

# download the map's prop meshes into the SHARED cache. Normally extracts only
# meshes not already present (a rock shared with a previously-loaded map isn't
# re-written), but when the freshness check saw a republished props.zip it
# overwrites EVERY mesh the zip carries — this is what heals a stale/wrong
# cached prop (the old rule "file exists = current" pinned it forever).
# Returns true if everything the map needs is now cached.
func ensure_props(host: Node, map: String, status: Callable) -> bool:
	if not _load_data(map): return false
	var refresh: bool = _props_refresh.get(map, false)
	var miss := _props_missing()
	if miss.is_empty() and not refresh:
		await _verify_props_registry(host, map, status)
		return true
	if refresh:
		status.call("Prop meshes were updated — refreshing…")
	else:
		status.call("Downloading %d prop meshes…" % miss.size())
	var b := base_url() + "maps/%s/" % map
	var tmp := "%s/%s/_props.zip" % [CACHE, map]
	DirAccess.make_dir_recursive_absolute("%s/%s" % [CACHE, map])
	var ok := await _download_with_progress(host, b + "props.zip", tmp, status,
		"Downloading prop meshes:")
	if not ok:
		status.call("Prop mesh download failed (try again)"); return false
	var zr := ZIPReader.new()
	if zr.open(ProjectSettings.globalize_path(tmp)) != OK:
		status.call("Prop archive unreadable"); return false
	var want: Dictionary = {}
	for nm in miss: want["%s.glb" % nm] = true
	var n := 0
	for f in zr.get_files():
		if want.has(f) or (refresh and f.ends_with(".glb") and not f.contains("/")):
			var out := FileAccess.open("%s/%s" % [PROPS_CACHE, f], FileAccess.WRITE)
			if out: out.store_buffer(zr.read_file(f)); out.close(); n += 1
	zr.close()
	DirAccess.remove_absolute(tmp)
	if refresh:
		_props_refresh.erase(map)
		_mesh_cache.clear()          # re-parse refreshed meshes on the next build
		_save_props_index({})        # overwritten files: forget verified hashes, re-verify
	await _stamp_etag(host, map, "props", b + "props.zip")
	await _verify_props_registry(host, map, status)
	status.call("%d prop meshes ready" % n)
	return true

# ---------- registry-following prop meshes ----------
func _props_index() -> Dictionary:
	var p := "%s/index.json" % PROPS_CACHE
	if FileAccess.file_exists(p):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if j is Dictionary: return j
	return {}

func _save_props_index(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(PROPS_CACHE)
	var f := FileAccess.open("%s/index.json" % PROPS_CACHE, FileAccess.WRITE)
	if f: f.store_string(JSON.stringify(d)); f.close()

# Bring this map's registry-published prop meshes in line with the site.
# Change-only: verified hashes short-circuit via index.json; a file whose hash
# is unknown is content-hashed once (recorded if it already matches); only
# genuine mismatches download, individually, from godot/<mesh>.glb.
func _verify_props_registry(host: Node, map: String, status: Callable) -> void:
	last_verify_updates = 0
	if _props_verified.get(map, false): return
	var reg: Dictionary = HighpolyStore.mesh_remote
	if reg.is_empty(): return          # manifest not adopted yet; next pass covers
	_props_verified[map] = true
	var idx := _props_index()
	var jobs: Array = []               # [mesh, remote_glb, target_hash]
	var seen: Dictionary = {}
	var hashed := 0
	for e in _data.get("props", []):
		if not (e is Dictionary) or not e.has("mesh"): continue
		var nm: String = e["mesh"]
		if seen.has(nm): continue
		seen[nm] = true
		if not reg.has(nm): continue   # not registry-published: props.zip copy + ETag healing apply
		var target := str((reg[nm] as Dictionary).get("hash", ""))
		if target == "" or str(idx.get(nm, "")) == target: continue
		var p := "%s/%s.glb" % [PROPS_CACHE, nm]
		if not FileAccess.file_exists(p): continue   # missing files are ensure_props' job
		var lh := HighpolyStore.file_hash(p)
		hashed += 1
		if hashed % 10 == 0:
			await host.get_tree().process_frame      # keep the editor smooth
		if lh == target:
			idx[nm] = target           # already the site's model — record, done forever
			continue
		jobs.append([nm, str((reg[nm] as Dictionary).get("glb", "")), target])
	if jobs.is_empty():
		_save_props_index(idx)
		return
	var http := HTTPRequest.new(); host.add_child(http)
	var done := 0
	for j in jobs:
		status.call("Updating prop meshes to match the site… (%d/%d)" % [done + 1, jobs.size()])
		var data := await HighpolyUpdater._fetch(http, base_url() + j[1])
		if not data.is_empty():
			var out := FileAccess.open("%s/%s.glb" % [PROPS_CACHE, j[0]], FileAccess.WRITE)
			if out:
				out.store_buffer(data); out.close()
				idx[j[0]] = j[2]
				_mesh_cache.erase("%s/%s.glb" % [PROPS_CACHE, j[0]])
				last_verify_updates += 1
		done += 1
	http.queue_free()
	_save_props_index(idx)
	if last_verify_updates > 0:
		status.call("%d prop mesh(es) updated to match the site" % last_verify_updates)

func _mesh_for(model_path: String) -> Mesh:
	if _mesh_cache.has(model_path): return _mesh_cache[model_path]
	var m: Mesh = null
	if ResourceLoader.exists(model_path):
		var res = load(model_path)
		if res is PackedScene:
			var inst = (res as PackedScene).instantiate()
			# Library GLBs are MANY mesh nodes now (per-material sub-parts, swatch
			# splits) — taking only the first node rendered props as lone
			# fragments. Merge EVERY mesh node (its glTF import transform baked:
			# 0.01 scale / axis swap / cm verts — the 700 m helicopter class),
			# grouping surfaces by material to stay under MAX_MESH_SURFACES.
			var pairs: Array = []
			_all_meshes_and_xf(inst, Transform3D(), pairs)
			if pairs.size() == 1:
				m = _bake_mesh(pairs[0][0], pairs[0][1])
			elif pairs.size() > 1:
				m = _merge_meshes(pairs)
			inst.queue_free()
		elif res is Mesh:
			m = res
	_mesh_cache[model_path] = m
	return m

# every mesh node in the scene with its accumulated transform
func _all_meshes_and_xf(n: Node, pxf: Transform3D, out: Array) -> void:
	var xf := pxf * ((n as Node3D).transform if n is Node3D else Transform3D())
	var mesh: Mesh = null
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		mesh = (n as MeshInstance3D).mesh
	elif n is ImporterMeshInstance3D and (n as ImporterMeshInstance3D).mesh != null:
		mesh = (n as ImporterMeshInstance3D).mesh.get_mesh()
	if mesh != null:
		out.append([mesh, xf])
	for c in n.get_children():
		_all_meshes_and_xf(c, xf, out)

# merge many (mesh, xf) into one ArrayMesh: bake transforms, concatenate
# surfaces PER MATERIAL (one output surface per unique material) so hundreds
# of sub-part nodes never exceed RenderingServer::MAX_MESH_SURFACES (256)
func _merge_meshes(pairs: Array) -> ArrayMesh:
	# NOTE: plain Arrays (reference type) as accumulators — packed arrays kept
	# inside a Dictionary are copy-on-write and `g["v"].append(...)` mutates a
	# discarded copy (classic GDScript pitfall). Packed at surface build below.
	var groups: Dictionary = {}   # material RID key -> {mat, v, n, uv, i, has_uv}
	for pair in pairs:
		var mesh: Mesh = pair[0]
		var xf: Transform3D = pair[1]
		var nb := xf.basis.inverse().transposed()
		var flip := xf.basis.determinant() < 0.0
		for s in range(mesh.get_surface_count()):
			var arr: Array = mesh.surface_get_arrays(s)
			var V = arr[Mesh.ARRAY_VERTEX]
			if V == null or V.size() == 0: continue
			var mat := mesh.surface_get_material(s)
			var key := mat.get_rid() if mat != null else RID()
			if not groups.has(key):
				groups[key] = {"mat": mat, "v": [], "n": [], "uv": [], "i": [],
					"has_uv": false}
			var g: Dictionary = groups[key]
			var gv: Array = g["v"]
			var gn: Array = g["n"]
			var guv: Array = g["uv"]
			var gi: Array = g["i"]
			var base := gv.size()
			for i in range(V.size()): gv.append(xf * V[i])
			var N = arr[Mesh.ARRAY_NORMAL]
			if N != null and N.size() == V.size():
				for i in range(N.size()): gn.append((nb * N[i]).normalized())
			else:
				for i in range(V.size()): gn.append(Vector3.UP)
			var UV = arr[Mesh.ARRAY_TEX_UV]
			if UV != null and UV.size() == V.size():
				g["has_uv"] = true
				for i in range(UV.size()): guv.append(UV[i])
			else:
				for i in range(V.size()): guv.append(Vector2.ZERO)
			var idx = arr[Mesh.ARRAY_INDEX]
			if idx != null and idx.size() >= 3:
				if flip:
					for t in range(0, idx.size() - 2, 3):
						gi.append(base + idx[t]); gi.append(base + idx[t + 2]); gi.append(base + idx[t + 1])
				else:
					for t in range(idx.size()): gi.append(base + idx[t])
			else:
				for t in range(V.size()): gi.append(base + t)
	var out := ArrayMesh.new()
	for key in groups:
		if out.get_surface_count() >= 255:
			push_warning("map-context merge: >255 unique materials, dropping remainder")
			break
		var g: Dictionary = groups[key]
		var arr := []; arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = PackedVector3Array(g["v"])
		arr[Mesh.ARRAY_NORMAL] = PackedVector3Array(g["n"])
		if g["has_uv"]: arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array(g["uv"])
		arr[Mesh.ARRAY_INDEX] = PackedInt32Array(g["i"])
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		if g["mat"] != null:
			out.surface_set_material(out.get_surface_count() - 1, g["mat"])
	return out

# first mesh + its transform relative to the scene root (accumulated)
func _first_mesh_and_xf(n: Node, pxf: Transform3D) -> Array:
	var xf := pxf * ((n as Node3D).transform if n is Node3D else Transform3D())
	var mesh: Mesh = null
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		mesh = (n as MeshInstance3D).mesh
	elif n is ImporterMeshInstance3D and (n as ImporterMeshInstance3D).mesh != null:
		mesh = (n as ImporterMeshInstance3D).mesh.get_mesh()
	if mesh != null: return [mesh, xf]
	for c in n.get_children():
		var r := _first_mesh_and_xf(c, xf)
		if not r.is_empty(): return r
	return []

# bake a transform into a mesh's vertices + normals (cached per model, so once)
func _bake_mesh(mesh: Mesh, xf: Transform3D) -> Mesh:
	if xf.is_equal_approx(Transform3D()): return mesh
	var out := ArrayMesh.new()
	var nb := xf.basis.inverse().transposed()
	for s in range(mesh.get_surface_count()):
		var arr: Array = mesh.surface_get_arrays(s)
		var V = arr[Mesh.ARRAY_VERTEX]
		if V != null:
			var nv := PackedVector3Array(); nv.resize(V.size())
			for i in range(V.size()): nv[i] = xf * V[i]
			arr[Mesh.ARRAY_VERTEX] = nv
		var N = arr[Mesh.ARRAY_NORMAL]
		if N != null:
			var nn := PackedVector3Array(); nn.resize(N.size())
			for i in range(N.size()): nn[i] = (nb * N[i]).normalized()
			arr[Mesh.ARRAY_NORMAL] = nn
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := mesh.surface_get_material(s)     # keep the texture/material!
		if mat != null: out.surface_set_material(out.get_surface_count() - 1, mat)
	return out

# Runtime GLTF (generate_scene) yields ImporterMeshInstance3D holding an
# ImporterMesh; res:// imported scenes yield MeshInstance3D holding a Mesh.
# Return the first real Mesh regardless of which.
func _extract_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return (n as MeshInstance3D).mesh
	if n is ImporterMeshInstance3D and (n as ImporterMeshInstance3D).mesh != null:
		return (n as ImporterMeshInstance3D).mesh.get_mesh()
	for c in n.get_children():
		var r := _extract_mesh(c)
		if r: return r
	return null

func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n
	for c in n.get_children():
		var r := _first_mesh(c)
		if r: return r
	return null

func _xform(a: Array, o: int) -> Transform3D:
	# 12 floats = basis rows (m0..m8) + origin; basis columns are the transpose
	var t := Transform3D()
	t.basis.x = Vector3(a[o+0], a[o+3], a[o+6])
	t.basis.y = Vector3(a[o+1], a[o+4], a[o+7])
	t.basis.z = Vector3(a[o+2], a[o+5], a[o+8])
	t.origin = Vector3(a[o+9], a[o+10], a[o+11])
	return t

# basis determinant sign: negative = a mirrored instance, which a MultiMesh
# renders with reversed winding (inside-out / inverted normals) unless we feed
# it a winding-flipped copy of the mesh (double flip = correct).
func _det3(a: Array, o: int) -> float:
	var r := Vector3(a[o+0], a[o+3], a[o+6])
	var u := Vector3(a[o+1], a[o+4], a[o+7])
	var f := Vector3(a[o+2], a[o+5], a[o+8])
	return r.dot(u.cross(f))

static var _flip_cache: Dictionary = {}
func _flipped_mesh(mesh: Mesh) -> Mesh:
	if _flip_cache.has(mesh): return _flip_cache[mesh]
	var out := ArrayMesh.new()
	for s in range(mesh.get_surface_count()):
		var arr: Array = mesh.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		if idx != null and idx.size() >= 3:
			var ni := PackedInt32Array(); ni.resize(idx.size())
			for t in range(0, idx.size() - 2, 3):
				ni[t] = idx[t]; ni[t + 1] = idx[t + 2]; ni[t + 2] = idx[t + 1]
			arr[Mesh.ARRAY_INDEX] = ni
		var nrm = arr[Mesh.ARRAY_NORMAL]
		if nrm != null:
			var nn := PackedVector3Array(); nn.resize(nrm.size())
			for k in range(nrm.size()): nn[k] = -nrm[k]
			arr[Mesh.ARRAY_NORMAL] = nn
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := mesh.surface_get_material(s)   # keep materials on the flipped copy
		if mat != null: out.surface_set_material(out.get_surface_count() - 1, mat)
	_flip_cache[mesh] = out
	return out

# One MultiMeshInstance3D for a batch of placements, splitting mirrored
# (negative-determinant) instances onto a winding-flipped copy of the mesh so
# they render right-side-out. Used for backdrop entries (no distance streaming).
var _bd_list: Array = []    # backdrop MMIs — tied to the Range slider too

func _add_multimesh(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> void:
	var count := int(xf.size() / 12)
	if mesh == null or count == 0: return
	var pos: Array = []
	var neg: Array = []
	for i in range(count):
		var o := i * 12
		var dst: Array = neg if _det3(xf, o) < 0.0 else pos
		for j in range(12): dst.append(xf[o + j])
	if not pos.is_empty():
		var m1 := _build_mmi(mesh, pos, textured, flat_mat)
		parent.add_child(m1)
		_bd_list.append(m1)
	if not neg.is_empty():
		var m2 := _build_mmi(_flipped_mesh(mesh), neg, textured, flat_mat)
		parent.add_child(m2)
		_bd_list.append(m2)

# Build the _MAP_CONTEXT subtree. Everything owner=null.
#   enabled      – Map Context on at all (terrain + surroundings baseline)
#   show_objects – add the game's original object placements (props layer)
#   tex          – detail mode, following the dock's Detail Mode dropdown:
#                  0 = flat SDK study colours (green land, orange objects),
#                  1 = untextured grey high-poly (clay), 2 = textured.
#                  Legacy bool callers (PhotoMatch): false = 0, true = 2.
func apply(root: Node, enabled: bool, show_objects: bool, tex = true) -> String:
	var tex_mode: int = (2 if tex else 0) if tex is bool else int(tex)
	var textured := tex_mode == 2
	_active = enabled
	_show_objects = show_objects
	_ctx_tex_mode = tex_mode
	if root == null: return "No scene open"
	var map := map_of(root)
	if map == "": return "Open a level scene (MP_…) first"
	_clear(root)

	# Load map data whenever we need geometry — terrain context OR objects.
	var need_data := enabled or show_objects
	var have_data := false
	if need_data:
		have_data = _load_data(map)

	if not enabled and not textured and not show_objects:
		return "Map Context off"

	# one owner=null container for all editor-only overlay geometry (never saved)
	var ctx := Node3D.new(); ctx.name = NODE
	root.add_child(ctx); ctx.owner = null
	var dir := "%s/%s" % [CACHE, map]

	# --- textured ground ---
	# Two layers, kept separate:
	#  1. The SDK's shipped playable centre (MP_<Map>_Terrain + _Assets/buildings)
	#     keeps the simple maptile DECAL — the "easy win", untouched, still textures
	#     the buildings.
	#  2. OUR map-context terrain (the centre-fill our terrain adds + the outer
	#     tiles beyond the SDK bowl) gets the near-exact DETAIL shader: real game
	#     ground-layer albedo/normal, slope-selected, so it's no longer pixelated.
	var tmat: ShaderMaterial = null
	var sdk_overlaid := 0
	_maptile_ok = false                # set true below when a decal would show
	if textured:
		tmat = _terrain_shader_mat(map)               # detail material for our extended terrain
		# With REAL splat data the extended terrain (which underlies the whole
		# footprint, SDK bowl included) carries the exact ground look and the
		# maptile lives INSIDE its shader as the large-scale colour term — so the
		# old maptile decal is skipped entirely: it used to tint props/buildings
		# and re-flatten the ground. Maps/packages without splat data keep the
		# decal exactly as before.
		var splat_covers: bool = _splat_active and tmat != null and enabled \
			and have_data and (_data.get("heightmap", {}) as Dictionary).has("file")
		# manual "Maptile decal" override: skip the decal entirely when off (it
		# tints buildings/props — fights the re-baked real prop textures).
		# _maptile_ok remembers the mode so set_maptile can re-add instantly.
		_maptile_ok = not splat_covers
		if not splat_covers and maptile_enabled:
			sdk_overlaid = _apply_maptile(root, map)  # decal on SDK terrain + assets

	if not enabled and not show_objects:
		if not textured: return "Map Context off"
		if sdk_overlaid > 0: return "SDK terrain textured (decal)"
		return "Maptile decal off" if not maptile_enabled else "No maptile for %s" % map
	if not have_data:
		return "%s not downloaded (hit Reload map data)" % map

	# --- terrain + backdrop: "Show map context" ---
	var bd_ok := 0; var bd_total := 0
	if enabled:
		# untextured "study" material = the SDK's own M_LevelTerrain (shiny lime green
		# + its 12 m grid), matching the shipped terrain. DUPLICATE it (never touch the
		# shared SDK material) + CULL_DISABLED: our heightmap mesh winds opposite to the
		# SDK mesh, so the SDK material's back-face culling would black out the top.
		# `green` = backdrop; `green_tiled` = re-tiled to the SDK 12 m grid.
		var green_base: Material = _sdk_terrain_material(root, map)
		var green: Material = green_base
		var green_tiled: Material = green_base
		var hm: Dictionary = _data.get("heightmap", {})
		if green_base is BaseMaterial3D:
			var span: float = float(hm.get("world_max", 2048)) - float(hm.get("world_min", -2048))
			var gb := (green_base as BaseMaterial3D).duplicate() as BaseMaterial3D
			gb.cull_mode = BaseMaterial3D.CULL_DISABLED
			green = gb
			var gt := (green_base as BaseMaterial3D).duplicate() as BaseMaterial3D
			gt.cull_mode = BaseMaterial3D.CULL_DISABLED
			gt.uv1_scale = Vector3(span / SDK_GRID_M, span / SDK_GRID_M, 1.0)
			green_tiled = gt
		var terrain_lift := 0.0
		if hm.has("file"):
			var tmi := _build_terrain_from_heightmap(dir, hm)   # full-accuracy mesh from raw 16-bit heights
			if tmi:
				# exact data height, no sink (was -0.5 to dodge z-fighting under
				# the SDK bowl: read as "terrain a meter low" — the heightmap is
				# exact ±5 mm). In SPLAT mode the maptile decal that visually
				# masked the coincident SDK bowl is gone, so lift our terrain a
				# hair instead: it wins the depth test and the splat ground shows
				# over the whole footprint (bowl included).
				if textured and tmat != null and _splat_active:
					terrain_lift = SPLAT_LIFT
				tmi.position.y = terrain_lift
				tmi.material_override = tmat if (textured and tmat != null) else green_tiled
				tmi.layers = EXT_TERRAIN_LAYER                   # keep the SDK maptile decal off it
				ctx.add_child(tmi); tmi.owner = null
			_add_water_plane(ctx)
			# vegetation scatter: grass/shrub kits placed procedurally around the
			# editor camera (highpoly_scatter.gd). Any detail mode — grass reads
			# fine over the flat green too; no scatter.json → strict no-op.
			if hm.has("file"):
				_scatter.y_lift = terrain_lift    # grass sits ON the (possibly lifted) ground
				_scatter_n = _scatter.setup(self, ctx, map, dir, hm, _scatter_tile(map))
				if _scatter_n > 0:
					var scam := _editor_cam()
					if scam: _scatter.tick(scam.global_transform.origin)
		var bd_root := Node3D.new(); bd_root.name = "Backdrop"
		ctx.add_child(bd_root); bd_root.owner = null
		for e in _data.get("backdrop", []):
			if not (e is Dictionary): continue
			bd_total += 1
			var mesh: Mesh = null
			if e.has("glb"):
				var gp := "%s/%s" % [dir, e["glb"]]
				if FileAccess.file_exists(gp):
					# merge ALL mesh nodes like the props path — the rebuilt
					# skyline GLBs carry one node per material section (Roof,
					# Walls...); _extract_mesh took only the FIRST, which
					# rendered the distant buildings as floating rooftops
					mesh = _parse_prop_file(gp)
			elif e.has("model"):
				mesh = _mesh_for(str(e["model"]))
			if mesh:
				_add_multimesh(bd_root, mesh, e.get("xf", []), textured,
						_clay_mat() if tex_mode == 1 else green)
				bd_ok += 1

	# --- status summary base (computed BEFORE the props build launches, so the
	# background builder's very first progress report already carries it) ---
	var mt := ""
	if textured:
		if tmat != null and _splat_active:
			mt = ", SPLAT terrain (%d layer slices, no decal)" % _splat_n
		elif tmat != null:
			mt = ", decal + detail terrain" if maptile_enabled else ", detail terrain (decal off)"
		else:
			mt = ", maptile decal (no layer set)" if maptile_enabled else ", decal off (no layer set)"
	var tex_lbl := "textured" if textured else ("clay" if tex_mode == 1 else "flat colour")
	var surr := ", surroundings %d/%d" % [bd_ok, bd_total]
	var sct := ", %d scatter types" % _scatter_n if _scatter_n > 0 else ""
	_build_status_base = "%s: terrain %s%s%s%s" % [map, tex_lbl, surr, sct, mt]

	# --- objects: "Original map objects" — independent of the terrain context, so
	# you can drop them onto the SDK's own playable terrain alone. Untextured, they
	# use the SDK's M_LevelAssets (shiny orange) placeholder to match the shipped
	# assets; textured, they keep their own material.
	if show_objects:
		var orange: Material = _sdk_assets_material(root, map)
		if orange is BaseMaterial3D:
			var od := (orange as BaseMaterial3D).duplicate() as BaseMaterial3D
			od.cull_mode = BaseMaterial3D.CULL_DISABLED
			orange = od
		if tex_mode == 1:
			orange = _clay_mat()          # grey clay instead of the SDK orange
		var props_root := Node3D.new(); props_root.name = "Props"
		ctx.add_child(props_root); props_root.owner = null
		# NON-BLOCKING: parsing ~2k unique GLBs + building their MultiMeshes
		# inline froze the editor for minutes. Queue the mesh groups
		# nearest-first from the editor camera and hand them to an incremental
		# builder (small time budget per frame) — the editor stays responsive
		# and props appear from the camera OUTWARD. apply() itself stays
		# synchronous; callers that need the COMPLETE overlay (PhotoMatch)
		# wait on is_build_done().
		_props_dir = dir              # remembered for refresh_changed_props
		_props_textured = textured
		_props_mat = orange
		_props_tex_mode = tex_mode    # set_objects_shown fast path key
		_variant_layer_groups = {}    # groups rebuild under the fresh Props node
		var entries := _sorted_prop_entries(_data.get("props", []))
		_build_total = entries.size()
		_build_done = 0
		_build_props = 0
		_last_report = 0
		_building = _build_total > 0
		if _building:
			_build_props_async(props_root, entries, dir, textured, orange, _build_gen)   # fire-and-forget
		else:
			_apply_radius()

	var objs := ""
	if show_objects:
		if _building:
			objs = ", building %d object meshes…" % _build_total
		else:
			objs = ", %d object meshes" % _build_props
	_last_status = "%s: terrain %s%s%s%s%s" % [map, tex, surr, objs, sct, mt]
	return _last_status

# ---------- non-blocking props build ----------
# True once the background props build has finished (or none is running).
# Batch consumers (PhotoMatch's render hook) poll this before rendering so
# they always shoot a COMPLETE overlay.
func is_build_done() -> bool:
	return not _building

# Live one-line progress for hosts that own their own status label; the full
# apply() summary once the build is done.
func build_progress_text() -> String:
	if not _building:
		return _last_status
	return "%s, objects %d/%d…" % [_build_status_base, _build_done, _build_total]

# Prop entries sorted nearest-first from the editor camera (distance of each
# mesh group's CLOSEST placement), so props appear from the camera outward.
# `src` = any list of prop entries (the full _data set, or a refresh subset).
func _sorted_prop_entries(src: Array) -> Array:
	var cpos := Vector3.ZERO
	var cam := _editor_cam()
	if cam: cpos = cam.global_transform.origin
	var order: Array = []
	for e in src:
		if not (e is Dictionary): continue
		var xf: Array = e.get("xf", [])
		if xf.is_empty(): continue
		order.append([_min_d2(xf, cpos), e])
	order.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for p in order: out.append(p[1])
	return out

# squared distance from cpos to the NEAREST placement origin in a 12-float-
# stride transform array (INF for an empty array)
static func _min_d2(xf: Array, cpos: Vector3) -> float:
	var d2 := INF
	var count := int(xf.size() / 12)
	for i in range(count):
		var o := i * 12
		var dx := float(xf[o + 9]) - cpos.x
		var dy := float(xf[o + 10]) - cpos.y
		var dz := float(xf[o + 11]) - cpos.z
		var dd := dx * dx + dy * dy + dz * dz
		if dd < d2: d2 = dd
	return d2

# Incremental builder — launched WITHOUT await from apply() (fire-and-forget).
# Spends BUILD_FRAME_MS of GLB parsing + MultiMesh building per frame, then
# yields a frame. gen is compared against _build_gen after EVERY await: a new
# apply()/_clear() bumps the generation and this pass stops dead — its nodes
# were already freed with _MAP_CONTEXT, and it must never touch the state a
# newer pass now owns (so no _building/_report writes on that path).
func _build_props_async(props_root: Node3D, entries: Array, dir: String,
		textured: bool, flat_mat: Material, gen: int) -> void:
	var frame_start := Time.get_ticks_msec()
	for e in entries:
		var gp := _prop_path(e, dir)
		var mesh := _prop_mesh(e, dir)      # the expensive part (GLB parse; cached)
		if gp != "":
			# refresh bookkeeping: which entries this source file built (recorded
			# even when the parse failed, so a file that lands later refreshes in)
			if not _prop_by_src.has(gp): _prop_by_src[gp] = []
			(_prop_by_src[gp] as Array).append(e)
		if mesh != null:
			var xf: Array = e.get("xf", [])
			var em: Dictionary = _prop_layers.get(str(e.get("mesh", "")), {})
			if em.is_empty():
				_add_cell_multimeshes(props_root, mesh, xf, textured, flat_mat, gp)
			else:
				# split layer-gated instances (winter dressing, Rush barriers…)
				# into visibility groups the Variant dropdown flips live.
				# (refresh_changed_props re-merges a refreshed mesh's instances
				# into the base group until the next full build — minor drift.)
				var base: Array = []
				var bux: Dictionary = {}
				var n := int(xf.size() / 12)
				for i in range(n):
					if em.has(i):
						var k: String = em[i]
						if not bux.has(k): bux[k] = []
						for j in range(12): (bux[k] as Array).append(xf[i * 12 + j])
					else:
						for j in range(12): base.append(xf[i * 12 + j])
				if not base.is_empty():
					_add_cell_multimeshes(props_root, mesh, base, textured, flat_mat, gp)
				for k in bux:
					_add_cell_multimeshes(_variant_group(props_root, str(k)),
							mesh, bux[k], textured, flat_mat, gp)
			_build_props += 1
		_build_done += 1
		if Time.get_ticks_msec() - frame_start >= BUILD_FRAME_MS:
			_apply_radius()                 # freshly added cells obey the range slider
			_report_progress()
			if not is_inside_tree():        # host removed us mid-build: no tree to await
				if gen == _build_gen:
					_building = false
					build_finished.emit(_build_props)
				return
			await get_tree().process_frame  # keep the editor smooth
			if gen != _build_gen:
				return                      # superseded by a new apply()/_clear()
			if not is_instance_valid(props_root):
				_building = false           # scene/ctx freed underneath us
				build_finished.emit(_build_props)
				return
			frame_start = Time.get_ticks_msec()
	_apply_radius()
	_building = false
	_report_progress(true)
	build_finished.emit(_build_props)

# Progress: emit the signal (the toggle dock drives a ProgressBar off it) and
# write the host's status label when one was injected; without a label, fall
# back to print() + a tail-able user://mapcontext/build_progress.txt, both at
# a ~BUILD_REPORT_EVERY-mesh cadence so the Output panel isn't flooded.
func _report_progress(final := false) -> void:
	build_progress.emit(_build_done, _build_total)
	var msg: String
	if final:
		msg = "%s, %d object meshes" % [_build_status_base, _build_props]
	else:
		msg = "%s, objects %d/%d…" % [_build_status_base, _build_done, _build_total]
	var l: Label = null
	if status_label != null and is_instance_valid(status_label):
		l = status_label
	if l != null:
		l.text = msg
	if final or _build_done - _last_report >= BUILD_REPORT_EVERY:
		_last_report = _build_done
		if l == null:
			print("MapContext: %s" % msg)
		var f := FileAccess.open(CACHE + "/build_progress.txt", FileAccess.WRITE)
		if f:
			f.store_string("%d/%d%s" % [_build_done, _build_total, " done" if final else ""])
			f.close()

# ---------- incremental props refresh ("Check for Updates") ----------
# The background re-bake overwrites GLBs in the shared props cache file-by-file
# while the user works. Rescan every source file this overlay parsed (mtime +
# size stamped at parse); changed files are handed to _refresh_props_async,
# which BUILD-THEN-SWAPs each one — the old mesh/MultiMeshes stay live until
# the replacement parsed successfully (camera-out order, same progress bar/
# signals/label as a full build). Returns the number of changed files queued,
# 0 when nothing changed, and -1 while a build is still running — the running
# pass owns all build state, so the caller should simply try again after.
func refresh_changed_props(root: Node) -> int:
	if _building: return -1
	if root == null or not _show_objects: return 0
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return 0
	var props_root := ctx.get_node_or_null("Props") as Node3D
	if props_root == null: return 0
	# camera-out ordered jobs: [min_d2, path, entries] for every stamped source
	# whose on-disk file changed. NOTHING is evicted or freed here — the async
	# refresh swaps each mesh only AFTER its replacement parsed successfully.
	var cpos := Vector3.ZERO
	var cam := _editor_cam()
	if cam: cpos = cam.global_transform.origin
	var jobs: Array = []
	for gp in _mesh_stat.keys():
		var rec: Dictionary = _mesh_stat[gp]
		var mt: int = FileAccess.get_modified_time(gp) if FileAccess.file_exists(gp) else 0
		if mt == int(rec.get("mt", -1)) and _file_size(gp) == int(rec.get("sz", -2)):
			continue
		var entries: Array = _prop_by_src.get(gp, [])
		if entries.is_empty(): continue        # stamped but unused by this map
		var d2 := INF
		for e in entries:
			var dd := _min_d2(e.get("xf", []), cpos)
			if dd < d2: d2 = dd
		jobs.append([d2, gp, entries])
	if jobs.is_empty(): return 0
	jobs.sort_custom(func(a, b): return a[0] < b[0])
	_build_total = jobs.size()
	_build_done = 0
	_build_props = 0
	_last_report = 0
	_building = true
	# same generation as the surrounding overlay: a later full apply()/_clear()
	# bumps it and cancels this refresh exactly like a full build
	_refresh_props_async(props_root, jobs, _build_gen)
	return _build_total

# Incremental REFRESH builder (fire-and-forget, like _build_props_async): one
# job per changed source file, strictly BUILD-THEN-SWAP —
#   1. parse the replacement mesh (atomic byte snapshot, no cache writes)
#   2. only on success: swap the caches, build the NEW MultiMeshes, then
#      queue_free exactly the OLD ones (collected before the add — old and new
#      share the same "src" tag)
#   3. on failure (e.g. caught the re-bake mid-write): keep the old mesh AND
#      the old stamp, count it, continue — the next Check retries that file.
# Same per-frame budget, progress reporting and generation-cancel rules as the
# full builder.
func _refresh_props_async(props_root: Node3D, jobs: Array, gen: int) -> void:
	var failed := 0
	var frame_start := Time.get_ticks_msec()
	for job in jobs:
		var gp: String = job[1]
		var entries: Array = job[2]
		# stamp BEFORE reading: a file replaced between stamp and read still
		# differs from the stored stamp on the next Check — never missed
		var stamp := {
			"mt": FileAccess.get_modified_time(gp) if FileAccess.file_exists(gp) else 0,
			"sz": _file_size(gp),
		}
		var mesh := _parse_prop_file(gp)
		if mesh == null:
			failed += 1
		else:
			var old = _mesh_cache.get(gp, null)    # untyped: may be null
			if old != null:
				_flip_cache.erase(old)             # its mirrored twin came from the old mesh
			_mesh_cache[gp] = mesh
			_mesh_stat[gp] = stamp
			var old_mmis := _collect_prop_mmis(gp)
			for e in entries:
				_add_cell_multimeshes(props_root, mesh, e.get("xf", []),
					_props_textured, _props_mat, gp)
			_free_mmi_list(old_mmis)               # replacement is live — drop the old
			_build_props += 1
		_build_done += 1
		if Time.get_ticks_msec() - frame_start >= BUILD_FRAME_MS:
			_apply_radius()                 # swapped cells obey the range slider
			_report_progress()
			if not is_inside_tree():        # host removed us mid-refresh
				if gen == _build_gen:
					_building = false
					build_finished.emit(_build_props)
				return
			await get_tree().process_frame  # keep the editor smooth
			if gen != _build_gen:
				return                      # superseded by a new apply()/_clear()
			if not is_instance_valid(props_root):
				_building = false           # scene/ctx freed underneath us
				build_finished.emit(_build_props)
				return
			frame_start = Time.get_ticks_msec()
	_apply_radius()
	_building = false
	if failed > 0:
		print("MapContext: %d changed prop file(s) failed to parse (mid-write?) — kept the old meshes; run Check for Updates again" % failed)
	_report_progress(true)
	build_finished.emit(_build_props)

# every live props MultiMesh built from `src` (checked BEFORE adding its
# replacements, which carry the same tag)
func _collect_prop_mmis(src: String) -> Array:
	var out: Array = []
	for key in _cells.keys():
		for mmi in _cells[key]:
			if is_instance_valid(mmi) and str(mmi.get_meta("src", "")) == src:
				out.append(mmi)
	return out

# queue_free (never free()) EXACTLY these MultiMeshes and forget them from the
# cell index — the renderer may still reference them this frame
func _free_mmi_list(list: Array) -> void:
	if list.is_empty(): return
	var kill: Dictionary = {}
	for m in list: kill[m] = true
	for key in _cells.keys():
		var kept: Array = []
		for mmi in _cells[key]:
			if not is_instance_valid(mmi):
				continue                           # freed externally: just forget it
			if kill.has(mmi):
				var par := (mmi as Node).get_parent()
				if par != null: par.remove_child(mmi)
				mmi.queue_free()
			else:
				kept.append(mmi)
		if kept.is_empty(): _cells.erase(key)
		else: _cells[key] = kept

# ---------- storage / purge ----------
# maps with downloaded data: user://mapcontext subfolders carrying a
# placements.json (the shared _props store is not a map)
static func downloaded_maps() -> Array:
	var out: Array = []
	var da := DirAccess.open(CACHE)
	if da == null: return out
	var subs := da.get_directories()
	subs.sort()
	for sub in subs:
		if sub == "_props": continue
		if FileAccess.file_exists("%s/%s/placements.json" % [CACHE, sub]):
			out.append(sub)
	return out

# every shared-cache mesh name a downloaded map references (props placements +
# vegetation scatter kits) — the reference sets purge safety is built on
static func map_prop_refs(map: String) -> Dictionary:
	var out: Dictionary = {}
	var pj := "%s/%s/placements.json" % [CACHE, map]
	if FileAccess.file_exists(pj):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(pj))
		if d is Dictionary:
			for e in (d as Dictionary).get("props", []):
				if e is Dictionary and e.has("mesh"):
					out[str(e["mesh"])] = true
	var sj := "%s/%s/scatter.json" % [CACHE, map]
	if FileAccess.file_exists(sj):
		var d2: Variant = JSON.parse_string(FileAccess.get_file_as_string(sj))
		if d2 is Dictionary:
			for e in (d2 as Dictionary).get("entries", []):
				if e is Dictionary and e.has("mesh"):
					out[str(e["mesh"])] = true
	return out

# async recursive [file count, bytes] for a folder — chunk-yields so multi-GB
# walks never block the editor; callers re-check their own state after awaits
func dir_usage_async(path: String) -> Array:
	var files := 0
	var bytes := 0
	var since := 0
	var stack: Array = [path]
	while not stack.is_empty():
		var d: String = stack.pop_back()
		var da := DirAccess.open(d)
		if da == null: continue
		for sub in da.get_directories():
			stack.append("%s/%s" % [d, sub])
		for f in da.get_files():
			bytes += maxi(0, _file_size("%s/%s" % [d, f]))
			files += 1
			since += 1
			if since >= 256:
				since = 0
				if not is_inside_tree(): return [files, bytes]
				await get_tree().process_frame   # keep the editor smooth
	return [files, bytes]

# What purging `map` would delete — real sizes + sharing, computed BEFORE the
# confirmation dialog so it shows true numbers:
#   excl        shared-cache meshes referenced ONLY by this map among the
#               downloaded maps (deletable)
#   shared      count referenced by at least one OTHER downloaded map (KEPT —
#               purging must never silently break another map)
#   excl_bytes  bytes of the deletable shared-cache glbs
#   map_bytes   bytes of the map's own folder
func purge_info(map: String) -> Dictionary:
	var refs := map_prop_refs(map)
	var others: Dictionary = {}
	for m in downloaded_maps():
		if str(m) == map: continue
		for nm in map_prop_refs(str(m)).keys():
			others[nm] = true
		if is_inside_tree():
			await get_tree().process_frame   # placements parses are chunky
	var excl: Array = []
	var shared := 0
	var excl_bytes := 0
	var i := 0
	for nm in refs.keys():
		if others.has(nm):
			shared += 1
			continue
		var p := "%s/%s.glb" % [PROPS_CACHE, nm]
		if FileAccess.file_exists(p):
			excl.append(nm)
			excl_bytes += maxi(0, _file_size(p))
		i += 1
		if i % 400 == 0 and is_inside_tree():
			await get_tree().process_frame
	var mu: Array = await dir_usage_async("%s/%s" % [CACHE, map])
	return {"excl": excl, "shared": shared, "excl_bytes": excl_bytes,
		"map_bytes": int(mu[1])}

# Execute the purge: delete the map's folder + its exclusive shared-cache
# glbs, scrub them from the props index and the in-RAM caches, and forget the
# map's session state so a future re-enable re-downloads cleanly. The CALLER
# turns the overlay off first when purging the currently open map.
func purge_map(map: String, info: Dictionary) -> void:
	var idx := _props_index()
	var idx_changed := false
	var n := 0
	for nm in info.get("excl", []):
		var p := "%s/%s.glb" % [PROPS_CACHE, str(nm)]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		for sfx in [".baked.res", ".baked2.res"]:
			if FileAccess.file_exists(p + sfx):
				DirAccess.remove_absolute(p + sfx)   # fast-startup sidecars
		if idx.has(nm):
			idx.erase(nm)
			idx_changed = true
		_mesh_cache.erase(p)
		_mesh_stat.erase(p)
		_prop_by_src.erase(p)
		n += 1
		if n % 256 == 0 and is_inside_tree():
			await get_tree().process_frame   # keep the editor smooth
	if idx_changed:
		_save_props_index(idx)
	_rm_dir_recursive("%s/%s" % [CACHE, map])
	_session_checked.erase(map)
	_props_verified.erase(map)
	_props_refresh.erase(map)
	_splat_cache.erase(map)
	if _map == map:
		_data = {}
		_map = ""

# UPDATE-BUTTON CLEANUP: sweep stale cache artifacts so "Check for Updates"
# both delivers the new files AND reclaims what this release obsoleted —
# v1 mesh sidecars (pre-LOD), torn .tmp.glb leftovers, and orphaned sidecars
# whose source GLB is gone. Never touches live GLBs or map data.
func cleanup_stale(map: String) -> int:
	var removed := 0
	var dirs := [ProjectSettings.globalize_path(PROPS_CACHE)]
	if map != "":
		dirs.append(ProjectSettings.globalize_path("%s/%s" % [CACHE, map]))
		dirs.append(ProjectSettings.globalize_path("%s/%s/backdrop" % [CACHE, map]))
	for d in dirs:
		var da := DirAccess.open(d)
		if da == null: continue
		for f in da.get_files():
			var p := "%s/%s" % [d, f]
			var kill := false
			if f.ends_with(".baked.res"):
				kill = true                     # v1 sidecar (pre-LOD)
			elif f.ends_with(".tmp.glb"):
				kill = true                     # torn mid-write leftover
			elif f.ends_with(".baked2.res"):
				kill = not FileAccess.file_exists(p.trim_suffix(".baked2.res"))
			if kill:
				DirAccess.remove_absolute(p)
				removed += 1
	return removed

# recursive delete — DirAccess has no rm -r
static func _rm_dir_recursive(path: String) -> void:
	var da := DirAccess.open(path)
	if da == null: return
	for sub in da.get_directories():
		_rm_dir_recursive("%s/%s" % [path, sub])
	for f in da.get_files():
		da.remove(f)
	DirAccess.remove_absolute(path)

# Water: exact flat plane(s) from the extracted WaterEntityData / placed water
# quads in placements.json. "water" is either one {height, center, size} dict (a
# single sea-level surface) or a LIST of them (separate lakes/rivers/pools at
# different elevations, e.g. Golmud's mountain lakes). Optional per-plane keys:
# "kind" (ocean/river/lake/pool shading preset), "yaw" (rotated quads, radians),
# "color" ([r,g,b] tint override) — see HighpolyWater. Terrain above a plane
# occludes it, so each only shows where the ground dips below its own waterline.
# Maps without a water body carry no "water" key and get no planes.
func _add_water_plane(ctx: Node3D) -> void:
	var wdata: Variant = _data.get("water", null)
	var planes: Array = []
	if wdata is Dictionary:
		planes = [wdata]
	elif wdata is Array:
		planes = wdata
	for wcfg in planes:
		if not (wcfg is Dictionary) or not wcfg.has("height"): continue
		var wc: Array = wcfg.get("center", [0.0, 0.0])
		var wsz: Array = wcfg.get("size", [5000.0, 5000.0])
		var wp := MeshInstance3D.new()
		wp.name = WATER_NODE
		var pm := PlaneMesh.new()
		pm.size = Vector2(float(wsz[0]), float(wsz[1]))
		wp.mesh = pm
		# BF6-style animated water (depth-tinted transparency + fresnel + ripples,
		# see water.gdshader); flat translucent colour if the shader file is missing
		var wmat: Material = HighpolyWater.material(wcfg)
		if wmat == null:
			var fb := StandardMaterial3D.new()
			fb.albedo_color = WATER_COLOR
			fb.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			fb.metallic = 0.3
			fb.roughness = 0.1
			fb.cull_mode = BaseMaterial3D.CULL_DISABLED
			wmat = fb
		wp.material_override = wmat
		wp.position = Vector3(float(wc[0]), float(wcfg["height"]), float(wc[1]))
		wp.rotation.y = float(wcfg.get("yaw", 0.0))   # rotated river/lake quads keep their bearing
		wp.layers = EXT_TERRAIN_LAYER    # keep the SDK maptile decal off the water
		ctx.add_child(wp); wp.owner = null

# ---------- full-accuracy terrain from the raw 16-bit heightmap ----------
# Godot downsamples 16-bit PNGs to 8-bit, so heights ship as a raw uint16 blob
# (row-major, little-endian). Built at `terrain_step` metres/vertex and cached
# to user:// so the (slow) build only happens once per detail level.
func _build_terrain_from_heightmap(dir: String, meta: Dictionary) -> MeshInstance3D:
	var step: int = max(1, terrain_step)
	var cache := "%s/terrain_s%d.res" % [dir, step]
	var mesh: ArrayMesh = null
	if ResourceLoader.exists(cache):
		mesh = ResourceLoader.load(cache)
	if mesh == null:
		var raw := FileAccess.get_file_as_bytes("%s/%s" % [dir, meta.get("file", "height.r16")])
		if raw.is_empty(): return null
		mesh = _heightmap_mesh(raw, int(meta.get("res", 4097)), step, meta)
		if mesh: ResourceSaver.save(mesh, cache)
	if mesh == null: return null
	var mi := MeshInstance3D.new(); mi.name = "Terrain"; mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _heightmap_mesh(raw: PackedByteArray, res: int, step: int, meta: Dictionary) -> ArrayMesh:
	var wmin: float = float(meta.get("world_min", -2048))
	var wspan: float = float(meta.get("world_max", 2048)) - wmin
	var base: float = float(meta.get("base", 0.0))
	var scale: float = float(meta.get("scale", 1.0)) / 65535.0
	var n := (res - 1) / step + 1
	var inv := 1.0 / float(res - 1)
	var verts := PackedVector3Array(); verts.resize(n * n)
	var norms := PackedVector3Array(); norms.resize(n * n)
	var uvs := PackedVector2Array(); uvs.resize(n * n)
	var world_step := float(step) * inv * wspan
	for gz in range(n):
		var py := gz * step
		var rowoff := py * res
		var pym := (maxi(0, py - step)) * res
		var pyp := (mini(res - 1, py + step)) * res
		for gx in range(n):
			var px := gx * step
			var wy := base + float(raw.decode_u16((rowoff + px) * 2)) * scale
			var i := gz * n + gx
			verts[i] = Vector3(wmin + float(px) * inv * wspan, wy, wmin + float(py) * inv * wspan)
			uvs[i] = Vector2(float(px) * inv, float(py) * inv)
			var hxm := float(raw.decode_u16((rowoff + maxi(0, px - step)) * 2)) * scale
			var hxp := float(raw.decode_u16((rowoff + mini(res - 1, px + step)) * 2)) * scale
			var hzm := float(raw.decode_u16((pym + px) * 2)) * scale
			var hzp := float(raw.decode_u16((pyp + px) * 2)) * scale
			norms[i] = Vector3(-(hxp - hxm), 2.0 * world_step, -(hzp - hzm)).normalized()
	var indices := PackedInt32Array(); indices.resize((n - 1) * (n - 1) * 6)
	var k := 0
	for gz in range(n - 1):
		var ro := gz * n
		for gx in range(n - 1):
			var a := ro + gx
			indices[k] = a; indices[k+1] = a + n; indices[k+2] = a + 1
			indices[k+3] = a + 1; indices[k+4] = a + n; indices[k+5] = a + n + 1
			k += 6
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

func _load_external_glb(abs_or_res: String) -> PackedScene:
	# user:// glbs aren't imported; load via runtime GLTF; res:// via normal loader
	if abs_or_res.begins_with("res://"):
		return load(abs_or_res) if ResourceLoader.exists(abs_or_res) else null
	HighpolyStore._ensure_webp_ext()   # webp-embedded basecolors (whole prop cache)
	# ONE-SHOT byte snapshot + append_from_buffer, NOT append_from_file: the
	# background re-bake rewrites these cache files continuously, and Godot's
	# Windows FileAccess opens share-all — a file-based parse can read a file
	# MID-OVERWRITE (torn chunk lengths → native crash in the glTF parser,
	# 0xc0000005). A single read sees one consistent byte snapshot, and a
	# malformed snapshot FAILS the parse instead of crashing it.
	var bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(abs_or_res))
	# glb sanity: 12-byte header starting with the "glTF" magic — every file we
	# load here is a .glb; a short/other prefix = missing or torn mid-write
	if bytes.size() < 12 or bytes.decode_u32(0) != 0x46546C67:
		return null
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	# buffer loads have no filename, and trimesh GLBs carry no scenes[0].name —
	# generate_scene would set_name("") on the root ("p_name.is_empty()" error
	# spam, one per GLB). Naming the state names the root instead.
	st.filename = abs_or_res.get_file()
	# embed textures directly instead of routing them through the editor's
	# reimport system (which fails on user:// webp and made the parse
	# return an error → whole mesh dropped). We build the scene regardless of
	# the return code because the geometry is valid even when textures don't
	# fully resolve.
	st.set_handle_binary_image(GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED)
	doc.append_from_buffer(bytes, ProjectSettings.globalize_path(abs_or_res).get_base_dir(), st)
	var scene := doc.generate_scene(st)
	if scene == null: return null
	# raw embedded textures are a memory bomb at scale — recompress to S3TC
	HighpolyStore.compress_scene_textures(scene)
	var ps := PackedScene.new(); ps.pack(scene); scene.queue_free()
	return ps

func _add_cell_multimeshes(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material, src := "") -> void:
	# split placements into world cells (for distance streaming), and within each
	# cell split normal vs mirrored (negative-determinant) instances — the game
	# legitimately mirror-instances props and a MultiMesh renders those inside-out
	# unless fed a winding-flipped mesh.
	var buckets: Dictionary = {}   # "cx,cz" -> [Array normal, Array mirrored]
	var count := int(xf.size() / 12)
	for i in range(count):
		var o := i * 12
		var ox: float = xf[o + 9]
		var oz: float = xf[o + 11]
		var key := "%d,%d" % [int((ox - _world_min) / _cell_size), int((oz - _world_min) / _cell_size)]
		if not buckets.has(key): buckets[key] = [[], []]
		var dst: Array = buckets[key][1] if _det3(xf, o) < 0.0 else buckets[key][0]
		for j in range(12): dst.append(xf[o + j])
	var flipped: Mesh = null
	for key in buckets.keys():
		var groups: Array = buckets[key]
		for gi in range(2):
			var gxf: Array = groups[gi]
			if gxf.is_empty(): continue
			var msh := mesh
			if gi == 1:
				if flipped == null: flipped = _flipped_mesh(mesh)
				msh = flipped
			var mmi := _build_mmi(msh, gxf, textured, flat_mat)
			if src != "": mmi.set_meta("src", src)   # refresh: find MMIs by source file
			parent.add_child(mmi); mmi.owner = null
			if not _cells.has(key): _cells[key] = []
			_cells[key].append(mmi)

func _build_mmi(mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh
	var count := int(xf.size() / 12); mm.instance_count = count
	for i in range(count): mm.set_instance_transform(i, _xform(xf, i * 12))
	var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm
	if not textured: mmi.material_override = flat_mat
	# props/backdrop CAST shadows (the flat no-shadow overlay was an old
	# study-mode perf choice — with game lighting it read as "shadows don't
	# render"). Follows the dock's Shadows sub-checkbox so meshes built while
	# it's unchecked stay light. Grass scatter is always shadow-off (GPU cost).
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if HighpolyLighting.cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# VISIBILITY RANGES (Godot's per-instance HLOD): small props stop being
	# drawn long before the Range slider would cull their cell — the single
	# biggest draw-call saver when flying (a trash can 1.5 km out was a full
	# draw call). Sized from the mesh's own AABB; fades instead of popping.
	var _sz := mesh.get_aabb().get_longest_axis_size()
	if _sz < 3.0:
		mmi.visibility_range_end = 400.0
	elif _sz < 12.0:
		mmi.visibility_range_end = 1200.0
	if mmi.visibility_range_end > 0.0:
		mmi.visibility_range_end_margin = 60.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return mmi

# Fast path for the "Original map objects" toggle: SHOW/HIDE the already-built
# props subtree instead of tearing the whole overlay down and re-parsing ~2k
# GLBs (7+ GB — the "feels like it's redownloading" wait was that rebuild).
# Returns false when there is no live props layer for this detail mode — the
# caller must run the full apply() then.
func set_objects_shown(root: Node, on: bool, tex_mode := -1) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return false
	var props := ctx.get_node_or_null("Props")
	if props == null: return false
	if tex_mode >= 0 and tex_mode != _props_tex_mode:
		return false                   # detail mode changed → needs a rebuild
	_show_objects = on
	(props as Node3D).visible = on
	if on:
		_apply_radius()                # re-cull for wherever the camera is now
	return true

# Fast path for the "Show whole map" toggle: hide/show the already-built
# terrain/backdrop/water/scatter layers instead of tearing the WHOLE overlay
# down — the full apply() also regenerated every map object ("why do all the
# original map objects regenerate when toggling Show Whole Map").
# Returns false when the context layers were never built for this detail
# mode — the caller runs the full apply() then.
func set_context_shown(root: Node, on: bool, tex_mode := -1) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return false
	if tex_mode >= 0 and _ctx_tex_mode >= 0 and tex_mode != _ctx_tex_mode:
		return false                   # detail mode changed → needs a rebuild
	var found := false
	for c in ctx.get_children():
		if c.name == "Props" or not (c is Node3D):
			continue
		found = true
		(c as Node3D).visible = on
	if on and not found:
		return false                   # terrain/backdrop never built → full apply
	_active = on
	return true

# ---------- distance streaming (called by the dock on a timer) ----------
func set_radius(r: float) -> void:
	radius = r
	_apply_radius()

func _apply_radius(budget: int = 1 << 30) -> void:
	# backdrop-only is valid (Show Whole Map without objects) — don't early-out
	# on empty cells or the skyline loop below never runs
	if _cells.is_empty() and _bd_list.is_empty(): return
	var cam := _editor_cam()
	var cx := 0.0; var cz := 0.0
	if cam:
		var p := cam.global_transform.origin; cx = p.x; cz = p.z
	# Flip only the cells whose state actually CHANGES, nearest first, capped at
	# `budget` cells per pass (the dock tick passes a small one; slider changes
	# and rebuilds pass unlimited). Showing a cell re-registers every instance
	# with the renderer and dirties SDFGI + the shadow atlas — flipping a whole
	# ring of cells in one frame was the fly-forward hitch. The old loop also
	# re-issued cast_shadow on EVERY cell EVERY tick (same value or not), which
	# dirties the render server even standing still.
	var half_diag := _cell_size * 0.7071
	var changes: Array = []
	for key in _cells.keys():
		var lst: Array = _cells[key]
		if lst.is_empty() or not is_instance_valid(lst[0]): continue
		var parts: PackedStringArray = String(key).split(",")
		# Euclidean distance to the cell CENTRE, margin = half the cell
		# diagonal. The old test used the cell's min corner with a square
		# metric and a whole-cell margin — at a 100 m slider it kept content
		# out to ~230 m, which read as "culling not working".
		var ckx: float = int(parts[0]) * _cell_size + _world_min + _cell_size * 0.5
		var ckz: float = int(parts[1]) * _cell_size + _world_min + _cell_size * 0.5
		var dx := ckx - cx
		var dz := ckz - cz
		var dist := sqrt(dx * dx + dz * dz)
		var vis_now: bool = (lst[0] as Node3D).visible
		# hysteresis: a visible cell gets an extra half-cell of grace before it
		# hides, so slow flight along the boundary doesn't flip the same cells
		# back and forth every tick
		var near: bool = dist <= radius + half_diag + (_cell_size * 0.5 if vis_now else 0.0)
		# shadow-caster LOD: only cells near the camera join the sun-shadow
		# pass (the pass re-renders every caster per split — with GI + map
		# lights on, whole-map casting was THE lag). 350 m covers everything
		# a shadow is visible on at street scale.
		var casts: bool = near and dist <= 350.0 + half_diag \
			and HighpolyLighting.cast_shadows
		var casts_now: bool = (lst[0] as GeometryInstance3D).cast_shadow \
			== GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if near != vis_now or casts != casts_now:
			changes.append([0 if near else 1, dist, key, near, casts])
	changes.sort()   # lexicographic: shows before hides, nearest first
	for ch in changes:
		if budget <= 0: break
		budget -= 1
		for mmi in _cells[ch[2]]:
			if is_instance_valid(mmi):
				mmi.visible = ch[3]
				(mmi as GeometryInstance3D).cast_shadow = \
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON if ch[4] \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# backdrop follows the Range slider too: cull each skyline/surroundings
	# cluster by distance to its own bounds (a 500 m-wide cluster whose edge
	# is near stays visible); "No Culling" keeps the full horizon
	for bmi in _bd_list:
		if not is_instance_valid(bmi): continue
		var bb: AABB = (bmi as VisualInstance3D).get_aabb()
		var ndx := clampf(cx, bb.position.x, bb.end.x) - cx
		var ndz := clampf(cz, bb.position.z, bb.end.z) - cz
		(bmi as Node3D).visible = (ndx * ndx + ndz * ndz) <= radius * radius

func _editor_cam() -> Camera3D:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	return vp.get_camera_3d() if vp else null

# maptile jpg + world bounds for the scatter greenness filter (same source the
# detail-terrain shader uses); {} when the map has no tile — scatter still works
func _scatter_tile(map: String) -> Dictionary:
	if not MAPTILE_DECALS.has(map): return {}
	var img := "res://raw/maptiles/%s.jpg" % MAPTILE_DECALS[map].get("tile", map)
	if not ResourceLoader.exists(img): return {}
	var d: Dictionary = MAPTILE_DECALS[map]
	var pos: Vector3 = d["pos"]; var sz: Vector3 = d["size"]
	return {"img": img, "bounds": Vector4(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5, sz.x, sz.z)}

func set_scatter_range(v: float) -> void:
	if _scatter == null: return
	var cam := _editor_cam()
	_scatter.set_range(v, cam.global_transform.origin if cam else Vector3.ZERO)

func tick() -> void:
	# called by the dock timer while objects are shown (streamed by distance).
	# Gate on _show_objects ALONE: objects can be shown without "Show whole
	# map" (_active), and the old `_active and` gate froze their culling —
	# the radius only applied once at slider-change instead of following the
	# camera.
	if _show_objects or (_active and not _bd_list.is_empty()):
		_apply_radius(4)   # amortised: a few cells per tick, never a whole ring
	# vegetation scatter follows the camera (regenerates on 32 m cell crossings);
	# frozen while the context layers are hidden (set_context_shown fast path)
	if _active and _scatter != null and _scatter.active:
		var cam := _editor_cam()
		if cam: _scatter.tick(cam.global_transform.origin)
