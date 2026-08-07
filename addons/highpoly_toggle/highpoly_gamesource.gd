@tool
extends RefCounted
class_name HighpolyGameSource

# The map, read from the player's own Battlefield 6 install.
#
# Everything the map context draws has until now arrived as a download: a
# per-map placements.json plus ~6.6 GB of extracted geometry and textures in
# user://mapcontext. That is redistribution of EA's assets, and it is the thing
# this replaces. The reader stack underneath (bf6_source -> bf6_walk ->
# bf6_meshset) produces the same answers from files the user already owns.
#
# Verified against the Python pipeline it replaces, on MP_Dumbo:
#   placements  48,126 rows, 2,727 meshes, 0 unmatched, 0 past 0.01 m
#   variations  7,799 pairs, 3,030 bindings, 0 missing / extra / wrong
#   geometry    2,273 of 2,727 meshes resolve to a MeshSet (93.7% of
#               placements); the rest are gameplay objects with no geometry —
#               combat areas, teams, killcam UI — and correctly have none
#
# Costs, measured (test_coldstart.gd):
#   cold  15.6 s mount + 19.1 s partition index + 50.2 s walk = 85 s
#   warm  1.3 s, everything cached under the mounted TOCs' signature
#
# SHAPED LIKE placements.json ON PURPOSE. map_data() returns the dictionary
# _load_data already understands, so the build path does not have to know where
# a map came from. The alternative — a second build path for game-sourced maps —
# is how the two quietly drift until only one of them is correct.

# LOGGING IS INJECTED, not imported. highpoly_log.gd reaches into the map
# context, the markers and the profiler, so preloading it here would drag the
# entire plugin in behind a module whose whole job is to read files — and make
# this impossible to test outside the editor, which is where it has to be
# tested. The plugin passes its logger in; a bare harness passes nothing.
var log_fn := Callable()


func _say(s: String) -> void:
	if log_fn.is_valid():
		log_fn.call(s)
	else:
		print(s)


# A blueprint X owns the MeshSet X_mesh, falling back to X itself. This is the
# pipeline's own rule (build_multimat.find_meshset), not a guess, and getting it
# wrong is silent: looking the blueprint path up directly resolves 0 of 2,727.
const MESH_SUFFIX := "_mesh"

const SHADERSTATE := "_win32_shaderstate/"

var src: BF6Source = null
var types: BF6Types = null
var walk: BF6Walk = null
var level := ""
var error := ""

# blueprint path (lowercased, no .ebx) -> res name, or "" for "known to have none"
var _res_for := {}
var _ms := BF6MeshSet.new()
var _tex := BF6Texture.new()

# bundle asset path -> depot res name, and the parsed depots, kept because a map
# touches a few dozen of the 15,391 the mount carries.
var _depot_bundles := {}
var _depot_cache := {}

# ONE ImageTexture PER TEXTURE, and one material per shader state.
#
# The same lesson the .bctex pool taught, one layer up: Dumbo's props reference
# 29,166 textures resolving to far fewer distinct assets, and a state key IS a
# material state — the depot itself deduplicates blobs by content, 39,559 keys
# onto 6,319 records. Building an ImageTexture or a material per section would
# re-upload the same pixels thousands of times, which is exactly the 14.5 GB of
# video memory the download path used to ask for.
var _tex_cache := {}                   # texture res name -> ImageTexture
var _mat_cache := {}                   # "<scope>|<state key>" -> Material
var _group_meta := {}                  # group key -> [res name, scope, a src]
var tex_stats := {"decoded": 0, "reused": 0, "failed": 0, "no_depot": 0,
	"no_key": 0, "materials": 0}


# Is there a game to read at all? Cheap: no mount, no parse. Used to decide
# whether to offer the reader as a source, so it must not cost anything on a
# machine that has no BF6 installed.
static func available(game_dir := "") -> bool:
	var s := BF6Source.new()
	return s.open(game_dir)


# Everything up to (and including) the placements. Long on a cold run — this is
# the 85 s — so callers should be showing progress while it happens.
#
# `progress` is called as (stage: String, done: int, total: int); total is 0 for
# stages that cannot report a fraction.
func open_map(map: String, game_dir := "", progress := Callable()) -> bool:
	error = ""
	level = map.to_lower()
	src = BF6Source.new()
	if not src.open(game_dir):
		error = src.error
		return false
	if progress.is_valid():
		progress.call("mounting the install", 0, 0)
	if not src.mount(level):
		error = src.last_error()
		return false

	types = BF6Types.new()
	var exe := ""
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			exe = c
			break
	if exe == "":
		error = "no bf6.exe under %s — the type layouts live in it" % src.game
		return false
	if not types.open(exe):
		error = types.error
		return false

	walk = BF6Walk.new(src, types)
	walk.build_catalog(func(done, total, found):
		if progress.is_valid():
			progress.call("indexing partitions", done, total))

	# WHICH BUNDLES OWN A DEPOT, handed to the walk BEFORE it runs so every row
	# records the scope it was placed under. A section's shader state key is only
	# unique within a scope, and the scope is the subworld that MOUNTED the
	# prefab — an ancestor in the walk graph, with no path relationship to the
	# partition the placement sits in. Matching by directory instead resolved
	# 54.7% of sections; this resolves 99.5%.
	for rn in src.res.keys():
		var n := str(rn)
		var at := n.find(SHADERSTATE)
		if at > 0 and n.find("shaderblockdepot", at) > 0:
			_depot_bundles[n.substr(0, at)] = n
	for d in _depot_bundles:
		walk.scope_index[str(d)] = str(d)
	if progress.is_valid():
		progress.call("reading placements", 0, 0)
	if not walk.run_cached(level):
		error = str(walk.stats.get("error", "the placement walk produced nothing"))
		return false
	_say("game source: %s — %d placements%s" % [map, walk.rows.size(),
		"  (cached)" if walk.stats.get("from_cache", false) else ""])
	return true


# ---------------------------------------------------------------------------
# THE SHAPE _load_data WANTS.
#
# placements.json carries props as {mesh: <file stem>, xf: [12 floats per
# instance]} — one entry per distinct mesh, with every instance flattened into
# one array. The walk produces one ROW per instance, so this groups them.
#
# `mesh` here is the resolved RES name rather than a file stem, and _prop_mesh
# is what knows the difference. Nothing else in the build path needs to.
# ---------------------------------------------------------------------------
func map_data() -> Dictionary:
	var by_mesh := {}
	var dropped := 0
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for r in walk.rows:
		var row: Dictionary = r
		var res_name := resolve_mesh(str(row["mesh"]))
		if res_name == "":
			dropped += 1
			continue
		var xf = row["xf"]
		if not (xf is Array) or (xf as Array).size() < 4:
			continue
		# GROUPED BY (MESH, SCOPE), not by mesh alone. The same mesh placed from
		# two subworlds looks its textures up in two different depots, so folding
		# those placements together would dress half of them from the wrong one.
		var scope := str(row.get("scope", ""))
		var gkey := "%s|%s" % [res_name, scope]
		if not by_mesh.has(gkey):
			by_mesh[gkey] = PackedFloat32Array()
			_group_meta[gkey] = [res_name, scope, str(row.get("src", ""))]
		var a: PackedFloat32Array = by_mesh[gkey]
		# The same 12-float layout placements.json uses: basis rows then origin.
		for i in range(4):
			var v: Vector3 = (xf as Array)[i]
			a.push_back(v.x)
			a.push_back(v.y)
			a.push_back(v.z)
		by_mesh[gkey] = a
		var o: Vector3 = (xf as Array)[3]
		lo = Vector3(minf(lo.x, o.x), minf(lo.y, o.y), minf(lo.z, o.z))
		hi = Vector3(maxf(hi.x, o.x), maxf(hi.y, o.y), maxf(hi.z, o.z))

	var props: Array = []
	for k in by_mesh:
		props.append({"mesh": k, "xf": Array(by_mesh[k] as PackedFloat32Array)})

	# _world_min is the origin of the cell grid, and placements.json ships it
	# per map. Derived here from the placements themselves rather than assumed:
	# a wrong origin does not fail, it silently shifts every cell boundary and
	# makes the range slider cull the wrong things.
	var wmin: float = -2048.0
	if lo.x < INF:
		wmin = floorf(minf(lo.x, lo.z) / 512.0) * 512.0
	_say("game source: %d distinct meshes, %d placements, %d rows with no "
		% [props.size(), walk.rows.size() - dropped, dropped]
		+ "geometry (gameplay objects)")
	return {
		"props": props,
		"backdrop": [],
		"world": {"min": wmin},
		"from_game": true,
	}


# blueprint path -> res name, "" when the mount has no geometry for it.
func resolve_mesh(mesh_path: String) -> String:
	var n := mesh_path.to_lower()
	if n.ends_with(".ebx"):
		n = n.substr(0, n.length() - 4)
	if _res_for.has(n):
		return str(_res_for[n])
	var got := ""
	for cand in [n + MESH_SUFFIX, n]:
		if src.res.has(cand):
			got = cand
			break
	_res_for[n] = got
	return got


# ---------------------------------------------------------------------------
# Geometry for one resolved mesh, as an ArrayMesh.
#
# LOD 0 by default. The MeshSets carry 4.1 LODs on average and #63 wants the
# coarser ones for draw-call reasons, so the level is a parameter rather than a
# constant even though nothing passes it yet.
#
# TEXTURED, via the section's shader state key and the depot for `scope`. Pass
# the group key from map_data() and both the mesh and its scope are recovered
# from it, so a caller never has to carry them separately.
# ---------------------------------------------------------------------------
func mesh_for(group_key: String, lod := 0) -> Mesh:
	var res_name := group_key
	var scope := ""
	if _group_meta.has(group_key):
		var m: Array = _group_meta[group_key]
		res_name = str(m[0])
		scope = str(m[1])
	elif group_key.contains("|"):
		var parts := group_key.split("|")
		res_name = str(parts[0])
		scope = str(parts[1])
	if res_name == "":
		return null
	var d := src.get_res(res_name)
	if d.is_empty():
		return null
	var info := _ms.parse(d)
	if info.is_empty():
		return null
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return null
	var li: int = clampi(lod, 0, lods.size() - 1)
	var L: Dictionary = lods[li]
	# The geometry buffer lives in a chunk unless the MeshSet inlines it; both
	# happen, and asking for the wrong one gives an empty mesh rather than an
	# error.
	var chunk := PackedByteArray()
	var cid: PackedByteArray = L.get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	# The fourth argument is keep_shadow, NOT the parsed info — read_lod parses
	# the file itself. Passing `info` there reads as `true` and brings the
	# shadow-only sections back as visible geometry.
	var secs = _ms.read_lod(d, li, chunk, false)
	if not (secs is Array) or (secs as Array).is_empty():
		return null

	var am := ArrayMesh.new()
	for s in secs:
		var sec: Dictionary = s
		var verts = sec.get("verts")
		if not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			continue
		var n: int = (verts as PackedVector3Array).size()
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		# Length-checked before use: Godot rejects the whole surface if an
		# attribute array disagrees with the vertex count, and a section that
		# carries no normals hands back an empty one rather than nothing.
		var nrm = sec.get("normals")
		if nrm is PackedVector3Array and (nrm as PackedVector3Array).size() == n:
			arr[Mesh.ARRAY_NORMAL] = nrm
		var uv = sec.get("uvs")
		if uv is PackedVector2Array and (uv as PackedVector2Array).size() == n:
			arr[Mesh.ARRAY_TEX_UV] = uv
		var idx = sec.get("indices")
		if not (idx is PackedInt32Array) or (idx as PackedInt32Array).is_empty():
			continue
		arr[Mesh.ARRAY_INDEX] = idx
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat = material_for(int(sec.get("state_key", 0)), scope)
		if mat != null:
			am.surface_set_material(am.get_surface_count() - 1, mat)
	return am if am.get_surface_count() > 0 else null


# ---------------------------------------------------------------------------
# The material one shader state binds, or null when nothing resolves.
#
# Cached per (scope, key): the depot deduplicates blobs by content — 39,559 keys
# onto 6,319 records — so building one material per SECTION would make thousands
# of identical StandardMaterial3Ds and upload the same pixels behind each.
# ---------------------------------------------------------------------------
func material_for(state_key: int, scope: String):
	if state_key == 0:
		tex_stats["no_key"] = int(tex_stats["no_key"]) + 1
		return null
	var ck := "%s|%s" % [scope, BF6Depot.key_hex(state_key)]
	if _mat_cache.has(ck):
		return _mat_cache[ck]

	var pair = _depot_for(scope)
	if pair == null:
		tex_stats["no_depot"] = int(tex_stats["no_depot"]) + 1
		_mat_cache[ck] = null
		return null
	var dep: BF6Depot = pair[0]
	if not dep.key_to_record.has(state_key):
		tex_stats["no_key"] = int(tex_stats["no_key"]) + 1
		_mat_cache[ck] = null
		return null
	var slots: Dictionary = dep.textures_for(state_key, pair[1])
	slots.erase("constants")

	var mat := StandardMaterial3D.new()
	var any := false
	# basecolor_veg is the vegetation sheet and takes precedence where both are
	# bound; normal_vt is the architecture normal paired with a tiling basecolor.
	var albedo = _texture_for(slots.get("basecolor_veg", slots.get("basecolor")))
	if albedo != null:
		mat.albedo_texture = albedo
		any = true
	var nrm = _texture_for(slots.get("normal", slots.get("normal_vt")))
	if nrm != null:
		mat.normal_enabled = true
		mat.normal_texture = nrm
		any = true
	var emis = _texture_for(slots.get("emissive"))
	if emis != null:
		mat.emission_enabled = true
		mat.emission_texture = emis
		any = true
	if not any:
		# A state with no albedo is NOT necessarily a failure: some materials are
		# procedural and bind only noise and weathering sheets. Cached as null so
		# it is not re-resolved, and counted separately from a missing depot.
		_mat_cache[ck] = null
		return null
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[ck] = mat
	tex_stats["materials"] = int(tex_stats["materials"]) + 1
	return mat


func _texture_for(file_guid):
	if file_guid == null or str(file_guid) == "":
		return null
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return null
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	if _tex_cache.has(an):
		tex_stats["reused"] = int(tex_stats["reused"]) + 1
		return _tex_cache[an]
	var raw := src.get_res(an)
	if raw.is_empty():
		_tex_cache[an] = null
		tex_stats["failed"] = int(tex_stats["failed"]) + 1
		return null
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)))
	if got.is_empty() or not (got.get("image") is Image):
		_tex_cache[an] = null
		tex_stats["failed"] = int(tex_stats["failed"]) + 1
		return null
	var t := ImageTexture.create_from_image(got["image"] as Image)
	_tex_cache[an] = t
	tex_stats["decoded"] = int(tex_stats["decoded"]) + 1
	return t


func _depot_for(scope: String):
	if scope == "":
		return null
	if _depot_cache.has(scope):
		return _depot_cache[scope]
	var name = _depot_bundles.get(scope)
	if name == null:
		_depot_cache[scope] = null
		return null
	var b := src.get_res(str(name))
	if b.is_empty():
		_depot_cache[scope] = null
		return null
	var dep := BF6Depot.new()
	_depot_cache[scope] = [dep, b] if dep.parse(b) else null
	return _depot_cache[scope]
