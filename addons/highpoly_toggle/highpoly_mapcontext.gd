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

enum Mode { OFF, EXTENTS, FULL, FULL_TEXTURED }

var mode: int = Mode.OFF
var radius: float = 768.0          # metres; props beyond this are hidden
var _map := ""
var _data: Dictionary = {}
var _cells: Dictionary = {}        # "cx,cz" -> Array[MultiMeshInstance3D] (props)
var _cell_size := 64.0
var _world_min := -2048.0
var _mesh_cache: Dictionary = {}   # model path -> Mesh

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

func _fetch(host: Node, url: String, to_file := "") -> PackedByteArray:
	var http := HTTPRequest.new(); host.add_child(http)
	if to_file != "": http.download_file = to_file
	var err := http.request(url)
	if err != OK: http.queue_free(); return PackedByteArray()
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return PackedByteArray()
	return res[3] if to_file == "" else PackedByteArray([1])

# Download a map's data bundle (terrain + placements + backdrop glbs). Returns
# true on success; status is Callable(String).
func download_map(host: Node, map: String, status: Callable) -> bool:
	var b := base_url() + "maps/%s/" % map
	var dir := "%s/%s" % [CACHE, map]
	DirAccess.make_dir_recursive_absolute(dir)
	status.call("Fetching %s placements…" % map)
	var pj := await _fetch(host, b + "placements.json")
	if pj.is_empty():
		status.call("No map data published for %s" % map); return false
	FileAccess.open("%s/placements.json" % dir, FileAccess.WRITE).store_buffer(pj)
	var data: Variant = JSON.parse_string(pj.get_string_from_utf8())
	if not (data is Dictionary):
		status.call("Map data unreadable"); return false
	# terrain
	var terr: Dictionary = data.get("terrain", {})
	if terr.has("med"):
		status.call("Downloading terrain…")
		await _fetch(host, b + str(terr["med"]), "%s/%s" % [dir, terr["med"]])
	# backdrop glbs
	var bd: Array = data.get("backdrop", [])
	var i := 0
	for e in bd:
		if e is Dictionary and e.has("glb"):
			i += 1
			status.call("Downloading backdrop… (%d)" % i)
			var rel := str(e["glb"])
			DirAccess.make_dir_recursive_absolute(("%s/%s" % [dir, rel]).get_base_dir())
			await _fetch(host, b + rel, "%s/%s" % [dir, rel])
	status.call("%s map data ready" % map)
	return true

# ---------- apply / build ----------
func _clear(root: Node) -> void:
	var old := root.get_node_or_null(NODE)
	if old: root.remove_child(old); old.queue_free()
	_cells.clear()

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
			var mi := _first_mesh(inst)
			if mi: m = mi.mesh
			inst.queue_free()
		elif res is Mesh:
			m = res
	_mesh_cache[model_path] = m
	return m

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

func _add_multimesh(parent: Node3D, mesh: Mesh, xf: Array, textured: bool) -> void:
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
		mmi.material_override = HighpolyLib.gray_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # perf
	parent.add_child(mmi)

# Build the _MAP_CONTEXT subtree for the given mode. Everything owner=null.
func apply(root: Node, want_mode: int) -> String:
	mode = want_mode
	if root == null: return "No scene open"
	var map := map_of(root)
	if map == "": return "Open a level scene (MP_…) first"
	_clear(root)
	if mode == Mode.OFF: return "Map Context off"
	if not _load_data(map):
		return "%s not downloaded" % map
	var ctx := Node3D.new(); ctx.name = NODE
	root.add_child(ctx); ctx.owner = null
	var dir := "%s/%s" % [CACHE, map]
	var textured := mode == Mode.FULL_TEXTURED

	# terrain
	var terr: Dictionary = _data.get("terrain", {})
	if terr.has("med"):
		var tp := "%s/%s" % [dir, terr["med"]]
		if FileAccess.file_exists(tp):
			var tres := _load_external_glb(tp)
			if tres:
				var tnode := tres.instantiate()
				tnode.name = "Terrain"
				if not textured: _gray(tnode)
				ctx.add_child(tnode); tnode.owner = null

	# backdrop (out-of-bounds surroundings) — shown in every non-off mode
	var bd_root := Node3D.new(); bd_root.name = "Backdrop"
	ctx.add_child(bd_root); bd_root.owner = null
	for e in _data.get("backdrop", []):
		if not (e is Dictionary): continue
		var mesh: Mesh = null
		if e.has("glb"):
			var gp := "%s/%s" % [dir, e["glb"]]
			if FileAccess.file_exists(gp):
				var g := _load_external_glb(gp)
				if g:
					var mi := _first_mesh(g.instantiate())
					if mi: mesh = mi.mesh
		elif e.has("model"):
			mesh = _mesh_for(str(e["model"]))
		if mesh: _add_multimesh(bd_root, mesh, e.get("xf", []), textured)

	# props (interactive layer) — only in FULL / FULL_TEXTURED, streamed by cell
	var n_props := 0
	if mode != Mode.EXTENTS:
		var props_root := Node3D.new(); props_root.name = "Props"
		ctx.add_child(props_root); props_root.owner = null
		for e in _data.get("props", []):
			if not (e is Dictionary): continue
			var mesh := _mesh_for(str(e.get("model", "")))
			if mesh == null: continue
			_add_cell_multimeshes(props_root, mesh, e.get("xf", []), textured)
			n_props += 1
		_apply_radius()
	return "%s: %s (%d prop meshes)" % [map, ["off","extents","full","full+tex"][mode], n_props]

func _load_external_glb(abs_or_res: String) -> PackedScene:
	# user:// glbs aren't imported; load via runtime GLTF; res:// via normal loader
	if abs_or_res.begins_with("res://"):
		return load(abs_or_res) if ResourceLoader.exists(abs_or_res) else null
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(abs_or_res), st) != OK:
		return null
	var scene := doc.generate_scene(st)
	if scene == null: return null
	var ps := PackedScene.new(); ps.pack(scene); scene.queue_free()
	return ps

func _add_cell_multimeshes(parent: Node3D, mesh: Mesh, xf: Array, textured: bool) -> void:
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
		var mmi := _build_mmi(mesh, buckets[key], textured)
		parent.add_child(mmi); mmi.owner = null
		if not _cells.has(key): _cells[key] = []
		_cells[key].append(mmi)

func _build_mmi(mesh: Mesh, xf: Array, textured: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh
	var count := int(xf.size() / 12); mm.instance_count = count
	for i in range(count): mm.set_instance_transform(i, _xform(xf, i * 12))
	var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm
	if not textured: mmi.material_override = HighpolyLib.gray_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi

func _gray(n: Node) -> void:
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).material_override = HighpolyLib.gray_material()
	for c in n.get_children(): _gray(c)

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
	# called by the dock timer while a full mode is active
	if mode == Mode.FULL or mode == Mode.FULL_TEXTURED:
		_apply_radius()
