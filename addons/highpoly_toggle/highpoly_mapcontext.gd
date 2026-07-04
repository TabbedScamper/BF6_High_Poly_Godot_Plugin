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

var _active := false               # Map Context enabled at all
var _show_objects := false         # original map objects (props) layer on
var radius: float = 768.0          # metres; props beyond this are hidden
var _map := ""
var _data: Dictionary = {}
var _cells: Dictionary = {}        # "cx,cz" -> Array[MultiMeshInstance3D] (props)
var _cell_size := 64.0
var _world_min := -2048.0
var _mesh_cache: Dictionary = {}   # model path -> Mesh
var _overlaid: Array = []          # SDK meshes we put a maptile material_overlay on
var terrain_step: int = 2          # metres per terrain vertex (1=full, 2=high, 4=medium)

# Untextured "study" colours match the SDK's own placeholder look so our overlay
# blends seamlessly with the shipped terrain/assets: green for land, orange for
# objects. Sampled from M_LevelTerrain / M_LevelAssets. A small emission floor
# keeps them readable even where the scene's ambient light is dark/blue.
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

# The shipped maptile jpg is 4096² covering the full world heightfield (±2048m,
# 1px/m). Everything textured — the SDK's own terrain/assets AND our extended
# out-of-bounds terrain — must share this ONE world→UV mapping or the pieces
# show the image at different scales and don't line up. Read the real bounds
# from the downloaded map data when present; otherwise fall back to ±2048.
const WORLD_HALF := 2048.0
# V orientation of the maptile jpg vs world +Z. Single source of truth so the
# SDK-terrain overlay and the extended-terrain material always agree. Flip if
# the satellite image comes in mirrored north/south.
const MAPTILE_FLIP_V := 1.0
func _maptile_bounds() -> Array:
	var w: Dictionary = _data.get("world", {})
	var lo: float = float(w.get("min", -WORLD_HALF))
	var hi: float = float(w.get("max", WORLD_HALF))
	return [lo, hi, lo, hi]

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
	var terr: Dictionary = d.get("terrain", {})
	var terr_have := terr.has("med") and FileAccess.file_exists("%s/%s" % [dir, terr["med"]])
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

# Download a map's data as ONE zip (terrain + placements + backdrop glbs) and
# extract it. A single request avoids the r2.dev burst-throttling that 38
# separate downloads trip. Idempotent: if placements.json is already cached and
# all backdrop files present, does nothing. status is Callable(String).
func download_map(host: Node, map: String, status: Callable, force := false) -> bool:
	var b := base_url() + "maps/%s/" % map
	var dir := "%s/%s" % [CACHE, map]
	DirAccess.make_dir_recursive_absolute(dir)
	if force:
		# force a fresh pull (e.g. the map data format changed): drop the manifest
		DirAccess.remove_absolute("%s/placements.json" % dir)
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
	# dedicated progress-aware download so the user sees it moving
	var http := HTTPRequest.new(); host.add_child(http)
	http.download_file = tmp
	var tick := Timer.new(); tick.wait_time = 0.5; host.add_child(tick); tick.start()
	tick.timeout.connect(func():
		var d := http.get_downloaded_bytes()
		if d > 0: status.call("Downloading %s map data… %d / %d MB" % [map, d / 1048576, total_mb]))
	var got_ok := false
	if http.request(b + "mapdata.zip") == OK:
		var res: Array = await http.request_completed
		got_ok = res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200 and FileAccess.file_exists(tmp)
	tick.queue_free(); http.queue_free()
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
	status.call("%s map data ready (%d files)" % [map, n])
	return _map_cache_complete(map)

func _map_cache_complete(map: String) -> bool:
	var dir := "%s/%s" % [CACHE, map]
	var pjp := "%s/placements.json" % dir
	if not FileAccess.file_exists(pjp): return false
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(pjp))
	if not (d is Dictionary): return false
	var terr: Dictionary = d.get("terrain", {})
	if terr.has("med") and not FileAccess.file_exists("%s/%s" % [dir, terr["med"]]): return false
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
	# remove the maptile overlay we placed on the SDK terrain/assets (editor-only)
	for n in _overlaid:
		if is_instance_valid(n): (n as GeometryInstance3D).material_overlay = null
	_overlaid.clear()

# ---------- SDK terrain/assets maptile overlay (textured mode) ----------
const MAPTILE_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, unshaded;
uniform sampler2D maptile : source_color, filter_linear_mipmap;
uniform vec4 bounds;            // minx, maxx, minz, maxz (world XZ)
uniform float flip_v = 1.0;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float u = (wpos.x - bounds.x) / (bounds.y - bounds.x);
	float v = (wpos.z - bounds.z) / (bounds.w - bounds.z);
	if (flip_v > 0.5) v = 1.0 - v;
	if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) discard;
	ALBEDO = texture(maptile, vec2(u, v)).rgb;
}
"""
static var _maptile_shader_res: Shader = null

func _mesh_instances(n: Node, out: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null: out.append(n)
	for c in n.get_children(): _mesh_instances(c, out)

# Overlay the SDK's shipped top-down maptile (res://raw/maptiles/MP_<Map>.jpg)
# on the SDK terrain + assets meshes via material_overlay. Reversible; never
# saved. Uses the SHARED world→UV mapping (±2048), the same one the extended
# terrain uses, so the SDK's playable area and our out-of-bounds terrain line
# up seamlessly. Works even without map data downloaded.
func _apply_maptile(root: Node, map: String) -> int:
	var img_path := "res://raw/maptiles/%s.jpg" % map
	if not ResourceLoader.exists(img_path): return 0
	var tex = load(img_path)
	if tex == null: return 0
	if _maptile_shader_res == null:
		_maptile_shader_res = Shader.new(); _maptile_shader_res.code = MAPTILE_SHADER
	# gather SDK terrain + assets mesh instances
	var targets: Array = []
	for nm in ["%s_Terrain" % map, "%s_Assets" % map]:
		var node := root.find_child(nm, true, false)
		if node: _mesh_instances(node, targets)
	if targets.is_empty(): return 0
	var b := _maptile_bounds()
	var flip := float(_data.get("maptile", {}).get("flip", MAPTILE_FLIP_V))
	for mi in targets:
		var sm := ShaderMaterial.new()
		sm.shader = _maptile_shader_res
		sm.set_shader_parameter("maptile", tex)
		sm.set_shader_parameter("bounds", Vector4(b[0], b[1], b[2], b[3]))
		sm.set_shader_parameter("flip_v", flip)
		(mi as GeometryInstance3D).material_overlay = sm
		_overlaid.append(mi)
	return targets.size()

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

func _mesh_for(model_path: String) -> Mesh:
	if _mesh_cache.has(model_path): return _mesh_cache[model_path]
	var m: Mesh = null
	if ResourceLoader.exists(model_path):
		var res = load(model_path)
		if res is PackedScene:
			var inst = (res as PackedScene).instantiate()
			m = _extract_mesh(inst)
			inst.queue_free()
		elif res is Mesh:
			m = res
	_mesh_cache[model_path] = m
	return m

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

func _dump_tree(n: Node, depth: int) -> void:
	print("  %s- %s (%s)" % ["  ".repeat(depth), n.name, n.get_class()])
	for c in n.get_children():
		_dump_tree(c, depth + 1)

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

func _add_multimesh(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> void:
	var count := int(xf.size() / 12)
	if mesh == null or count == 0: return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	for i in range(count):
		mm.set_instance_transform(i, _xform(xf, i * 12))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	if not textured:
		mmi.material_override = flat_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # perf
	parent.add_child(mmi)

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

	# Load extended data first when enabling context, so the maptile overlay and
	# the extended terrain share the exact same world bounds (per-map correct).
	var have_data := false
	if enabled:
		have_data = _load_data(map)

	# The maptile overlay on the SDK's own terrain/assets is driven by `textured`
	# ALONE — so ticking just "Textures" (map context off) drapes the shipped
	# satellite image over the default SDK terrain, correctly aligned.
	var sdk_overlaid := 0
	if textured:
		sdk_overlaid = _apply_maptile(root, map)

	if not enabled:
		if textured:
			return "SDK terrain textured (%d mesh%s)" % [sdk_overlaid, "" if sdk_overlaid == 1 else "es"]
		return "Map Context off"
	if not have_data:
		return "%s not downloaded (hit Reload map data)" % map
	var ctx := Node3D.new(); ctx.name = NODE
	root.add_child(ctx); ctx.owner = null
	var dir := "%s/%s" % [CACHE, map]

	# central terrain: always shown when enabled. The SDK's own playable terrain
	# is only ~±600m (the gameplay bowl); our extracted terrain covers the full
	# ±2048 heightfield, filling the ring gap between the SDK bowl and the near
	# backdrop tiles (~±2043). Nudged down 0.5m so the SDK's detailed bowl stays
	# on top where they overlap.
	var hm: Dictionary = _data.get("heightmap", {})
	if hm.has("file"):
		var tmi := _build_terrain_from_heightmap(dir, hm)   # full-accuracy mesh from raw 16-bit heights
		if tmi:
			tmi.position.y = -0.5                            # sit just under the SDK bowl in the overlap
			if textured:
				tmi.material_override = _maptile_material(map)   # shared ±2048 world→UV
			else:
				tmi.material_override = terrain_material()   # SDK-matched green
			ctx.add_child(tmi); tmi.owner = null

	# backdrop (out-of-bounds surrounding landscape) — always shown when enabled;
	# it's terrain family, so it takes the green study colour when untextured.
	var bd_root := Node3D.new(); bd_root.name = "Backdrop"
	ctx.add_child(bd_root); bd_root.owner = null
	var bd_ok := 0; var bd_total := 0
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
					if mesh == null and bd_ok == 0 and bd_total <= 2:
						print("[MapContext] backdrop '%s' produced no mesh; node tree:" % e.get("glb"))
						_dump_tree(gi, 0)
					gi.queue_free()
		elif e.has("model"):
			mesh = _mesh_for(str(e["model"]))
		if mesh:
			_add_multimesh(bd_root, mesh, e.get("xf", []), textured, terrain_material())
			bd_ok += 1

	# props (original map objects) — only when show_objects; orange when untextured
	var n_props := 0
	if show_objects:
		var props_root := Node3D.new(); props_root.name = "Props"
		ctx.add_child(props_root); props_root.owner = null
		for e in _data.get("props", []):
			if not (e is Dictionary): continue
			var mesh := _mesh_for(str(e.get("model", "")))
			if mesh == null: continue
			_add_cell_multimeshes(props_root, mesh, e.get("xf", []), textured, assets_material())
			n_props += 1
		_apply_radius()
	var miss := bd_total - bd_ok
	var tail := "" if miss == 0 else "  (%d surrounding piece(s) missing — hit Reload map data)" % miss
	var objs := ", %d object meshes" % n_props if show_objects else ", objects off"
	var mt := "" if sdk_overlaid == 0 else ", maptile on %d SDK mesh(es)" % sdk_overlaid
	var tex := "textured" if textured else "flat colour"
	return "%s: %s — %d/%d surroundings%s%s%s" % [map, tex, bd_ok, bd_total, objs, mt, tail]

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

func _maptile_material(map: String) -> Material:
	var img_path := "res://raw/maptiles/%s.jpg" % map
	if not ResourceLoader.exists(img_path): return terrain_material()
	if _maptile_shader_res == null:
		_maptile_shader_res = Shader.new(); _maptile_shader_res.code = MAPTILE_SHADER
	var b := _maptile_bounds()
	var sm := ShaderMaterial.new()
	sm.shader = _maptile_shader_res
	sm.set_shader_parameter("maptile", load(img_path))
	sm.set_shader_parameter("bounds", Vector4(b[0], b[1], b[2], b[3]))
	sm.set_shader_parameter("flip_v", float(_data.get("maptile", {}).get("flip", MAPTILE_FLIP_V)))
	return sm

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
	var ps := PackedScene.new(); ps.pack(scene); scene.queue_free()
	return ps

func _add_cell_multimeshes(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> void:
	# split this mesh's placements into world cells so the streamer can hide far ones
	var buckets: Dictionary = {}   # "cx,cz" -> PackedFloat32Array
	var count := int(xf.size() / 12)
	for i in range(count):
		var ox: float = xf[i * 12 + 9]
		var oz: float = xf[i * 12 + 11]
		var key := "%d,%d" % [int((ox - _world_min) / _cell_size), int((oz - _world_min) / _cell_size)]
		if not buckets.has(key): buckets[key] = []
		for j in range(12): buckets[key].append(xf[i * 12 + j])
	for key in buckets.keys():
		var mmi := _build_mmi(mesh, buckets[key], textured, flat_mat)
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

func tick() -> void:
	# called by the dock timer while objects are shown (streamed by distance)
	if _active and _show_objects:
		_apply_radius()
