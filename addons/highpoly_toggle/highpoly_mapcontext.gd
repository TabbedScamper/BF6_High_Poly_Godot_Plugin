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
	var old := root.get_node_or_null(NODE)
	if old: root.remove_child(old); old.queue_free()
	_cells.clear()
	_scatter.clear()      # scatter lives under _MAP_CONTEXT; drop its caches too
	_scatter_n = 0
	# drop the in-RAM caches so a re-apply re-reads the on-disk files (picks up
	# prop textures / terrain layers updated since the last apply)
	_mesh_cache.clear()
	_layer_cache.clear()
	_splat_cache.clear()   # re-read baked splat data on the next apply
	# remove the maptile decal (editor-only)
	var dec := root.get_node_or_null(DECAL_NODE)
	if dec: root.remove_child(dec); dec.queue_free()

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
	return true

# A prop's mesh: the EXACT extracted game mesh from the downloaded per-map props
# bundle (`glb`) when available — the accurate path — else the res:// SDK proxy
# (`model`) fallback for meshes we haven't extracted yet.
func _prop_mesh(e: Dictionary, dir: String) -> Mesh:
	# `mesh` = exact game mesh from the SHARED prop cache (preferred); `glb` =
	# legacy per-map bundle; `model` = res:// SDK proxy fallback.
	var gp := ""
	if e.has("mesh"): gp = "%s/%s.glb" % [PROPS_CACHE, e["mesh"]]
	elif e.has("glb"): gp = "%s/%s" % [dir, e["glb"]]
	elif e.has("model"): return _mesh_for(str(e["model"]))
	else: return null
	if _mesh_cache.has(gp): return _mesh_cache[gp]
	var m: Mesh = null
	if FileAccess.file_exists(gp):
		var g := _load_external_glb(gp)
		if g:
			var inst := g.instantiate()
			var pair := _first_mesh_and_xf(inst, Transform3D())
			if not pair.is_empty(): m = _bake_mesh(pair[0], pair[1])
			inst.queue_free()
	_mesh_cache[gp] = m
	return m

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
	_flip_cache[mesh] = out
	return out

# One MultiMeshInstance3D for a batch of placements, splitting mirrored
# (negative-determinant) instances onto a winding-flipped copy of the mesh so
# they render right-side-out. Used for backdrop entries (no distance streaming).
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
		parent.add_child(_build_mmi(mesh, pos, textured, flat_mat))
	if not neg.is_empty():
		parent.add_child(_build_mmi(_flipped_mesh(mesh), neg, textured, flat_mat))

# Build the _MAP_CONTEXT subtree. Everything owner=null.
#   enabled      – Map Context on at all (terrain + surroundings baseline)
#   show_objects – add the game's original object placements (props layer)
#   textured     – real textures instead of the flat green/orange study colours
func apply(root: Node, enabled: bool, show_objects: bool, textured: bool) -> String:
	_active = enabled
	_show_objects = show_objects
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
		if not splat_covers:
			sdk_overlaid = _apply_maptile(root, map)  # decal on SDK terrain + assets

	if not enabled and not show_objects:
		if not textured: return "Map Context off"
		return "SDK terrain textured (decal)" if sdk_overlaid > 0 else "No maptile for %s" % map
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
					var g := _load_external_glb(gp)
					if g:
						var gi := g.instantiate()
						mesh = _extract_mesh(gi)
						gi.queue_free()
			elif e.has("model"):
				mesh = _mesh_for(str(e["model"]))
			if mesh:
				_add_multimesh(bd_root, mesh, e.get("xf", []), textured, green)
				bd_ok += 1

	# --- objects: "Original map objects" — independent of the terrain context, so
	# you can drop them onto the SDK's own playable terrain alone. Untextured, they
	# use the SDK's M_LevelAssets (shiny orange) placeholder to match the shipped
	# assets; textured, they keep their own material.
	var n_props := 0
	if show_objects:
		var orange: Material = _sdk_assets_material(root, map)
		if orange is BaseMaterial3D:
			var od := (orange as BaseMaterial3D).duplicate() as BaseMaterial3D
			od.cull_mode = BaseMaterial3D.CULL_DISABLED
			orange = od
		var props_root := Node3D.new(); props_root.name = "Props"
		ctx.add_child(props_root); props_root.owner = null
		for e in _data.get("props", []):
			if not (e is Dictionary): continue
			var mesh := _prop_mesh(e, dir)
			if mesh == null: continue
			_add_cell_multimeshes(props_root, mesh, e.get("xf", []), textured, orange)
			n_props += 1
		_apply_radius()

	var mt := ""
	if textured:
		if tmat != null and _splat_active:
			mt = ", SPLAT terrain (%d layer slices, no decal)" % _splat_n
		elif tmat != null:
			mt = ", decal + detail terrain"
		else:
			mt = ", maptile decal (no layer set)"
	var tex := "textured" if textured else "flat colour"
	var surr := ", surroundings %d/%d" % [bd_ok, bd_total]
	var objs := ", %d object meshes" % n_props if show_objects else ""
	var sct := ", %d scatter types" % _scatter_n if _scatter_n > 0 else ""
	return "%s: terrain %s%s%s%s%s" % [map, tex, surr, objs, sct, mt]

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
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	# embed textures directly instead of routing them through the editor's
	# reimport system (which fails on user:// webp and made append_from_file
	# return an error → whole mesh dropped). We build the scene regardless of
	# the return code because the geometry is valid even when textures don't
	# fully resolve.
	st.set_handle_binary_image(GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED)
	doc.append_from_file(ProjectSettings.globalize_path(abs_or_res), st)
	var scene := doc.generate_scene(st)
	if scene == null: return null
	# raw embedded textures are a memory bomb at scale — recompress to S3TC
	HighpolyStore.compress_scene_textures(scene)
	var ps := PackedScene.new(); ps.pack(scene); scene.queue_free()
	return ps

func _add_cell_multimeshes(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> void:
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
			parent.add_child(mmi); mmi.owner = null
			if not _cells.has(key): _cells[key] = []
			_cells[key].append(mmi)

func _build_mmi(mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh
	var count := int(xf.size() / 12); mm.instance_count = count
	for i in range(count): mm.set_instance_transform(i, _xform(xf, i * 12))
	var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm
	if not textured: mmi.material_override = flat_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi

# ---------- distance streaming (called by the dock on a timer) ----------
func set_radius(r: float) -> void:
	radius = r
	_apply_radius()

func _apply_radius() -> void:
	if _cells.is_empty(): return
	var cam := _editor_cam()
	var cx := 0.0; var cz := 0.0
	if cam:
		var p := cam.global_transform.origin; cx = p.x; cz = p.z
	for key in _cells.keys():
		var parts: PackedStringArray = String(key).split(",")
		var kx: float = int(parts[0]) * _cell_size + _world_min
		var kz: float = int(parts[1]) * _cell_size + _world_min
		var near: bool = abs(kx - cx) <= radius + _cell_size and abs(kz - cz) <= radius + _cell_size
		for mmi in _cells[key]:
			if is_instance_valid(mmi): mmi.visible = near

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

func set_scatter_density(v: float) -> void:
	if _scatter == null: return
	var cam := _editor_cam()
	_scatter.set_density(v, cam.global_transform.origin if cam else Vector3.ZERO)

func tick() -> void:
	# called by the dock timer while objects are shown (streamed by distance)
	if _active and _show_objects:
		_apply_radius()
	# vegetation scatter follows the camera (regenerates on 32 m cell crossings)
	if _scatter != null and _scatter.active:
		var cam := _editor_cam()
		if cam: _scatter.tick(cam.global_transform.origin)
