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

var src: BF6Source = null
var types: BF6Types = null
var walk: BF6Walk = null
var level := ""
var error := ""

# blueprint path (lowercased, no .ebx) -> res name, or "" for "known to have none"
var _res_for := {}
var _ms := BF6MeshSet.new()


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
		if not by_mesh.has(res_name):
			by_mesh[res_name] = PackedFloat32Array()
		var a: PackedFloat32Array = by_mesh[res_name]
		# The same 12-float layout placements.json uses: basis rows then origin.
		for i in range(4):
			var v: Vector3 = (xf as Array)[i]
			a.push_back(v.x)
			a.push_back(v.y)
			a.push_back(v.z)
		by_mesh[res_name] = a
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
# UNTEXTURED FOR NOW, and that is the honest state of this: materials resolve
# through the ShaderBlockDepot, which is not ported. A prop comes back with
# geometry and no maps. See the note in highpoly_mapcontext where this is used.
# ---------------------------------------------------------------------------
func mesh_for(res_name: String, lod := 0) -> Mesh:
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
	return am if am.get_surface_count() > 0 else null
