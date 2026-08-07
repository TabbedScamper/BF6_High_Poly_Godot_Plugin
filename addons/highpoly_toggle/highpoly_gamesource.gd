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
	if not log_fn.is_valid():
		print(s)
		return
	# DEFERRED OFF THE MAIN THREAD. open_map runs on a worker and the plugin's
	# logger writes into an editor Control, which is main-thread-only — the same
	# trap the progress callback fell into, and the same fix. call_deferred puts
	# it on the main thread's queue instead of refusing it.
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		log_fn.call_deferred(s)
	else:
		log_fn.call(s)


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

# Off skips material resolution entirely, so a caller can measure geometry on
# its own. The whole-map build costs +12.8 GB of static memory and the split
# between geometry and textures is not guessable — the download path holds
# ~3.4 GB doing a comparable job, so this is the difference between "inherent"
# and "a pooling bug", and those want opposite fixes.
var build_materials := true

# Largest texture edge to load. 0 loads whatever the game ships, which for
# Dumbo is 8.2 GB of mostly-2K BC7 for one map — against 460 MB for all of its
# geometry. 1024 takes the embedded chunk instead of the streamed one, which
# costs a byte range rather than a decompress, and is the same ceiling the
# packaged .bctex set was published at.
var texture_max_dim := 1024

# WHERE THE OPEN GOES, per phase, in ms. There is no point optimising this
# without it: the three phases have completely different fixes (a mount is
# bundle metadata, the index is 223k EBX headers, the walk is instance decoding)
# and a single total says nothing about which one to touch. `_cached` records
# whether the walk came from its cache, because a warm run's phase split is a
# different measurement from a cold one and mixing them is how a 50x speedup
# gets attributed to the wrong change.
var timings := {}

var tex_dims := {}                     # "WxH fFMT mip" -> count
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
	timings.clear()
	var t_all := Time.get_ticks_msec()
	var t := Time.get_ticks_msec()
	src = BF6Source.new()
	if not src.open(game_dir):
		error = src.error
		return false
	if progress.is_valid():
		progress.call("mounting the install", 0, 0)
	if not src.mount(level):
		error = src.last_error()
		return false
	timings["mount"] = Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()

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
	# LIGHTS COME OUT OF THE SAME PASS as the placements. They are placed by
	# exactly this traversal — a fixture inherits the composed transform of
	# whichever prefab holds it — and walking a second time to fetch them would
	# cost another 50 s to learn something the first walk went straight past.
	for g in LIGHT_TYPES:
		walk.want_types[str(g)] = "light"
	walk.want_fields = LIGHT_FIELDS
	timings["typeinfo"] = Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()
	walk.build_catalog(func(done, total, found):
		if progress.is_valid():
			progress.call("indexing partitions", done, total))
	timings["partition index"] = Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()

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
	timings["placement walk"] = Time.get_ticks_msec() - t
	timings["_total"] = Time.get_ticks_msec() - t_all
	timings["_cached"] = 1 if walk.stats.get("from_cache", false) else 0
	_say("game source: %s — %d placements%s" % [map, walk.rows.size(),
		"  (cached)" if walk.stats.get("from_cache", false) else ""])
	return true


# OPENED ON A WORKER, because a cold open is ~85 s.
#
# Mounting the install, indexing 223k partition guids and walking the level are
# all pure file and CPU work — no Node, no ImageTexture, no RenderingServer —
# which is exactly the kind that is safe off the main thread. Running it inline
# would freeze the editor for a minute and a half with a dead UI, and the first
# thing anyone would do is kill it.
#
# The caller pumps frames while it runs, so the dock keeps drawing and its
# status label keeps updating.
var _open_result := false
var _open_done := false

# THE PROGRESS THE WORKER RECORDED, read by the pump on the main thread.
#
# The obvious wiring — hand the caller's progress Callable to open_map and let
# the worker call it — is wrong, and wrong in the way that produces a working
# build and a screenful of errors. The caller's callback sets a Label's text,
# and Control.text reaches queue_redraw, update_minimum_size and
# update_configuration_warnings, none of which may be touched off the main
# thread. Godot refuses each one by name, once per call: the partition index
# reports 223k times and buried the run in half a megabyte of stack traces.
#
# So the worker only ASSIGNS, and the frame pump below — which is already on the
# main thread, because it is awaiting process_frame — is what calls the caller
# back. No lock: these are three independent variables written by one thread and
# read by another for display, and the worst a torn read can do is show a stale
# percentage for one frame.
var _prog_stage := ""
var _prog_done := 0
var _prog_total := 0


func open_async(host: Node, map: String, game_dir := "",
		progress := Callable()) -> bool:
	_open_done = false
	_open_result = false
	_prog_stage = ""
	_prog_done = 0
	_prog_total = 0
	var task := func():
		_open_result = open_map(map, game_dir,
			func(stage: String, done: int, total: int):
				_prog_stage = stage
				_prog_done = done
				_prog_total = total)
		_open_done = true
	var tid := WorkerThreadPool.add_task(task, true, "bf6 game source open")
	var last := ""
	while not WorkerThreadPool.is_task_completed(tid):
		if host == null or not is_instance_valid(host) or host.get_tree() == null:
			break
		if progress.is_valid() and _prog_stage != "":
			# Reported once a frame at most, whatever the worker does. The
			# partition index calls its callback per bundle; forwarding every one
			# would rebuild the label's layout 223k times for 60 visible states.
			var now := "%s %d/%d" % [_prog_stage, _prog_done, _prog_total]
			if now != last:
				last = now
				progress.call(_prog_stage, _prog_done, _prog_total)
		await host.get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(tid)
	return _open_result and _open_done


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
# BUILT ONCE PER MAP, and this is not a micro-optimisation.
#
# _load_data is called from more places than the build: showing or hiding a
# layer, reskinning, the range tick, a variant switch. On the download path each
# call re-parsed a JSON file, which is wasteful and survivable. Here it would
# re-composite a 4097x4097 heightfield, rebuild 45,736 triangles of road, and
# re-emit 7,878 lights and 624 FX points — measured in one session log running
# three times before the build even started.
#
# Keyed on the cache directory because that is what changes the RESULT: the
# terrain and the light and FX files are written there, so a different directory
# is a different answer rather than the same one.
var _map_data := {}
var _map_data_key := "￿"          # not "" — that is a legitimate key


func map_data(cache_dir := "") -> Dictionary:
	if _map_data_key == cache_dir and not _map_data.is_empty():
		return _map_data
	var out := _build_map_data(cache_dir)
	_map_data = out
	_map_data_key = cache_dir
	return out


func _build_map_data(cache_dir: String) -> Dictionary:
	var by_mesh := {}
	var by_bd := {}
	var dropped := 0
	# THE SKYLINE IS ALREADY IN THE WALK — measured, not assumed. All 155 of the
	# packaged backdrop meshes appear among the rows and all 155 resolve to a
	# MeshSet, so the 1,247 MB the download spends on it buys nothing the install
	# does not already have.
	#
	# Telling it apart: every backdrop row is a StaticModelGroup emitted directly
	# from the LEVEL ROOT partition, which is where MAP_LOADING 6.6 says vista
	# instancing lives. That rule catches all 155 plus 30 further SMG rows the
	# packaged pipeline had filed as props — and the packaged split is OUR
	# classification rather than the game's, so those 30 are a content
	# disagreement with an old heuristic, not an error against ground truth.
	var root_ref := str(walk.stats.get("root", "")).to_lower()
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
		var is_bd: bool = root_ref != "" \
			and str(row.get("src", "")).to_lower() == root_ref \
			and str(row.get("kind", "")).begins_with("smg")
		var into: Dictionary = by_bd if is_bd else by_mesh
		if not into.has(gkey):
			into[gkey] = PackedFloat32Array()
			_group_meta[gkey] = [res_name, scope, str(row.get("src", ""))]
		var a: PackedFloat32Array = into[gkey]
		# The same 12-float layout placements.json uses: basis rows then origin.
		for i in range(4):
			var v: Vector3 = (xf as Array)[i]
			a.push_back(v.x)
			a.push_back(v.y)
			a.push_back(v.z)
		into[gkey] = a
		var o: Vector3 = (xf as Array)[3]
		lo = Vector3(minf(lo.x, o.x), minf(lo.y, o.y), minf(lo.z, o.z))
		hi = Vector3(maxf(hi.x, o.x), maxf(hi.y, o.y), maxf(hi.z, o.z))

	var props: Array = []
	for k in by_mesh:
		props.append({"mesh": k, "xf": Array(by_mesh[k] as PackedFloat32Array)})
	var backdrop: Array = []
	for k in by_bd:
		backdrop.append({"mesh": k, "xf": Array(by_bd[k] as PackedFloat32Array)})

	# _world_min is the origin of the cell grid, and placements.json ships it
	# per map. Derived here from the placements themselves rather than assumed:
	# a wrong origin does not fail, it silently shifts every cell boundary and
	# makes the range slider cull the wrong things.
	var wmin: float = -2048.0
	if lo.x < INF:
		wmin = floorf(minf(lo.x, lo.z) / 512.0) * 512.0
	_say("game source: %d prop groups, %d skyline groups, %d placements, "
		% [props.size(), backdrop.size(), walk.rows.size() - dropped]
		+ "%d rows with no geometry (gameplay objects)" % dropped)
	var out := {
		"props": props,
		"backdrop": backdrop,
		"world": {"min": wmin},
		"from_game": true,
	}
	if cache_dir != "":
		var t := Time.get_ticks_msec()
		var hm := terrain(cache_dir)
		if not hm.is_empty():
			out["heightmap"] = hm
		timings["terrain"] = Time.get_ticks_msec() - t
		t = Time.get_ticks_msec()
		# ORDER MATTERS: the roads are draped on the heightfield terrain() just
		# composited, so they cannot be built before it.
		var rd := roads()
		if rd != null:
			out["roads"] = rd
		timings["roads"] = Time.get_ticks_msec() - t
		t = Time.get_ticks_msec()
		# Written as the files the light and FX layers already read, rather than
		# handed over in memory. Those two layers are toggled long after the build
		# — from the dock, on demand — so the data has to outlive this call, and a
		# file in the map's own cache is what the rest of the plugin means by that.
		out["lights"] = lights(cache_dir)
		out["fx"] = fx(cache_dir)
		timings["lights + fx"] = Time.get_ticks_msec() - t
	var w := water()
	if not w.is_empty():
		out["water"] = w
	return out


# ---------------------------------------------------------------------------
# THE TERRAIN, out of the game's streaming tree.
#
# The map context builds its ground from a raw u16 grid plus {base, scale},
# where world_y = base + raw * scale/65535 — and the game's own heights use
# exactly that encoding with scale = WorldSizeY. So the raw samples go straight
# in with base 0 and no renormalisation: on Dumbo, 6336 and 28302 map to 24.8 m
# and 110.6 m, which is the AABB range the tree declares.
#
# Verified against the packaged height.r16 at r = 0.9964 over 453,660 samples —
# the same ground. It is not byte-identical and was never going to be: that file
# came from a different pipeline which normalised to the full u16 range
# (0..65450 against our 6336..28302), so a mean difference of 10,407 says
# nothing and the correlation says everything.
#
# Written to the map cache because the builder takes a FILE. That is a file
# derived from the player's install, not a download.
func terrain(cache_dir: String) -> Dictionary:
	if src == null:
		return {}
	var pick := ""
	for rn in src.res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains(level):
			pick = n
			break
	if pick == "":
		return {}
	var res := src.get_res(pick)
	if res.is_empty():
		return {}
	var t := BF6Terrain.new()
	var blk := t.find_block(res, BF6Terrain.BLOCK_HEIGHTS)
	if blk.is_empty() or not t.read_block_header(blk) or not t.walk_nodes(blk):
		_say("game source: terrain — %s" % t.error)
		return {}
	var dir := t.read_chunk_directory(res)
	if not dir.is_empty():
		t.resolve_external(dir, func(form): return src.get_chunk(str(form)))
	# 4097, not 4096: one sample per grid LINE, which is what the builder's own
	# default res says and what the packaged file is.
	var g := t.composite(4097)
	if g.is_empty():
		_say("game source: terrain — %s" % t.error)
		return {}
	var lo: Vector3 = g["min"]
	var hi: Vector3 = g["max"]
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var path := "%s/height_game.r16" % cache_dir
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("game source: terrain — cannot write %s" % path)
		return {}
	f.store_buffer(g["data"])
	f.close()
	# KEPT IN MEMORY as well as written, because the roads need it. Decal
	# vertices carry world X and Z and no Y at all — they are draped on the
	# terrain — so building them means sampling this exact grid with this exact
	# formula. Re-reading the file we just wrote would work and would also be
	# the place the two copies quietly disagree.
	_hm = {"data": g["data"], "res": int(g["size"]), "min": lo.x,
		"max": hi.x, "base": 0.0, "scale": float(g["world_size_y"])}
	_say("game source: terrain %dx%d from %d nodes, y %.0f..%.0f m"
		% [g["size"], g["size"], g["nodes"], lo.y, hi.y])
	return {
		"file": "height_game.r16",
		"res": g["size"],
		"world_min": lo.x,
		"world_max": hi.x,
		"base": 0.0,
		"scale": float(g["world_size_y"]),
	}


# ---------------------------------------------------------------------------
# ROADS AND STREET MARKINGS, out of the level's TerrainDecals resource.
#
# The spline control points are stripped from the runtime EBX, so this compiled
# geometry is the only source for the street network — without it a rebuilt map
# is bare ground where the roads should be. bf6_decals.gd reads the container;
# this drapes it and dresses it.
#
# THE DRAPE. Decal vertices carry world X and Z and NO Y: the engine lays them on
# the heightfield and draws them blended with depth-write off. We cannot turn
# depth writes off on a normal mesh, so they are lifted instead. 0.15 m is
# measured, not chosen for comfort: at 0.06 the median vertex sat 0.07 m proud
# and 5% still dipped up to 0.12 m UNDER the ground, because the rendered terrain
# is flat-shaded triangles between grid points while the drape samples
# bilinearly — the two disagree mid-triangle, on slopes.
const ROAD_Y_BIAS := 0.15

# COVERAGE IS A SECOND TEXTURE, not an alpha channel, so this cannot be a
# StandardMaterial3D. The markings — lane lines, crosswalks, arrows — live ONLY
# in the `op` slot; without it they paint as solid blocks over the road surface.
#
# The alternative was compositing op into cv's alpha at load. That means
# decompressing two BC7 images, resizing one and writing a million bytes per
# material group in GDScript, for a result a sampler gives away free.
const ROAD_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley;
uniform sampler2D cv : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D op : filter_linear_mipmap, repeat_enable;
uniform bool has_cv = false;
uniform bool has_op = false;
uniform vec4 flat_col : source_color = vec4(0.35, 0.35, 0.35, 1.0);
void fragment() {
	vec4 c = has_cv ? texture(cv, UV) : flat_col;
	ALBEDO = c.rgb;
	ALPHA = has_op ? texture(op, UV).r : c.a;
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
}
"""

var _road_shader: Shader = null
var _hm := {}                          # the composited heightfield, for the drape
var road_stats := {}


# One ArrayMesh, one surface per material group, or null.
#
# GROUPED BY (basecolor, coverage) rather than per record: 433 records on Dumbo
# resolve to a few dozen distinct material pairs, and a surface per record would
# be 433 draw calls for a road network.
func roads() -> Mesh:
	road_stats = {}
	if src == null or _hm.is_empty():
		return null
	var name := BF6Decals.find_res(src, level)
	if name == "":
		return null
	var raw := src.get_res(name)
	if raw.is_empty():
		return null
	var td := BF6Decals.new()
	if not td.parse(raw):
		_say("game source: roads — %s" % td.error)
		return null
	road_stats = td.stats()

	var groups := {}
	for r in td.records:
		var rec: Dictionary = r
		var pr: Dictionary = rec["props"]
		var cv := _prop_guid(pr, BF6Decals.SLOT_CV)
		var op := _prop_guid(pr, BF6Decals.SLOT_OP)
		var key := "%s|%s" % [cv, op]
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(rec)

	var am := ArrayMesh.new()
	var tris := 0
	for key in groups:
		var recs: Array = groups[key]
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		for r in recs:
			var rec: Dictionary = r
			var vs := td.vertices(rec)
			var n := vs.size() / 4
			# A record whose vertex count disagrees with its triangle count means
			# the VB is being read at the wrong place, and a wrong VB still
			# produces plausible floats. Dropped rather than drawn as confetti.
			if n != int(rec["tri_count"]) * 3:
				continue
			# STAMP decals (crosswalks, manholes, arrows) map the unit square as
			# (v1, v0). Long tiled fills overflow half precision along the ribbon,
			# so those are tiled from world position at Tiling0 m/tile instead —
			# using their stored UVs draws a smear.
			var stamp := true
			for i in range(n):
				if absf(vs[i * 4 + 2]) > 1.05 or absf(vs[i * 4 + 3]) > 1.05:
					stamp = false
					break
			var t0 := float(rec["tiling0"])
			if absf(t0) < 1e-3:
				t0 = 8.0
			for i in range(n):
				var x := vs[i * 4]
				var z := vs[i * 4 + 1]
				verts.push_back(Vector3(x, _height_at(x, z) + ROAD_Y_BIAS, z))
				if stamp:
					uvs.push_back(Vector2(vs[i * 4 + 3], vs[i * 4 + 2]))
				else:
					uvs.push_back(Vector2(x / t0, z / t0))
		if verts.is_empty():
			continue
		var idx := PackedInt32Array()
		idx.resize(verts.size())
		for i in range(verts.size()):
			idx[i] = i
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_TEX_UV] = uvs
		arr[Mesh.ARRAY_INDEX] = idx
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		am.surface_set_material(am.get_surface_count() - 1,
			_road_material(str(key)))
		tris += verts.size() / 3
	road_stats["groups"] = am.get_surface_count()
	road_stats["drawn_triangles"] = tris
	if am.get_surface_count() == 0:
		return null
	_say("game source: roads — %d records in %d material group(s), %d triangles%s"
		% [td.records.size(), am.get_surface_count(), tris,
		   "" if int(td.truncated_at) < 0
		   else "  (TRUNCATED at record %d — partial)" % td.truncated_at])
	return am


func _prop_guid(props: Dictionary, slot: int) -> String:
	var p = props.get(slot)
	if not (p is Array) or str((p as Array)[0]) != "tex":
		return ""
	return BF6Decals.guid_str((p as Array)[1])


func _road_material(key: String) -> Material:
	if _road_shader == null:
		_road_shader = Shader.new()
		_road_shader.code = ROAD_SHADER
	var parts := key.split("|")
	var mat := ShaderMaterial.new()
	mat.shader = _road_shader
	var cv = _texture_for(parts[0] if parts.size() > 0 else "")
	var op = _texture_for(parts[1] if parts.size() > 1 else "")
	if cv != null:
		mat.set_shader_parameter("cv", cv)
		mat.set_shader_parameter("has_cv", true)
	if op != null:
		mat.set_shader_parameter("op", op)
		mat.set_shader_parameter("has_op", true)
	# A record with no properties is POSITIONAL rather than broken: its AssetSlot
	# is a terrain layer index and the surface is that layer's own material. It is
	# real road either way, so it gets a neutral grey and is drawn.
	return mat


# Bilinear world height, the same formula the terrain build uses.
func _height_at(x: float, z: float) -> float:
	var res: int = int(_hm["res"])
	var wmin: float = float(_hm["min"])
	var span: float = float(_hm["max"]) - wmin
	if span <= 0.0 or res < 2:
		return 0.0
	var d: PackedByteArray = _hm["data"]
	var fx: float = clampf((x - wmin) / span * (res - 1), 0.0, res - 1.001)
	var fz: float = clampf((z - wmin) / span * (res - 1), 0.0, res - 1.001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - x0
	var tz := fz - z0
	var h00 := float(d.decode_u16((z0 * res + x0) * 2))
	var h10 := float(d.decode_u16((z0 * res + x0 + 1) * 2))
	var h01 := float(d.decode_u16(((z0 + 1) * res + x0) * 2))
	var h11 := float(d.decode_u16(((z0 + 1) * res + x0 + 1) * 2))
	var hv := h00 * (1.0 - tx) * (1.0 - tz) + h10 * tx * (1.0 - tz) \
		+ h01 * (1.0 - tx) * tz + h11 * tx * tz
	return float(_hm["base"]) + hv * float(_hm["scale"]) / 65535.0


# ---------------------------------------------------------------------------
# THE WATER SURFACE, from the level's default world part.
#
# A WaterSurfaceEntityData instance whose SpatialEntityData.Transform is a unit
# quad scaled to the surface: right row at +0x20 carries scaleX, forward at
# +0x40 scaleZ, translation at +0x50 is (tx, ty, tz) with ty the water height.
# TERRAIN.md §11, verified across all 11 water surfaces in the game.
#
# READ FROM RAW OFFSETS, deliberately. The type has no fields in
# SharedTypeDescriptors, so the deserializer returns nothing for it — this is
# one of the few places where reaching into the instance bytes is correct
# rather than lazy.
#
# TWO TRAPS, both of which produce plausible water in the wrong place:
#   * TileOffset at +0x90 is (2048, 0.5, 2048) and looks like extents+height.
#     Taking its Y puts the sea at y = 0.5 instead of Dumbo's 49.8.
#   * both documented readings give a HALF extent, and PlaneMesh.size is a FULL
#     width — so the scale value goes in as-is. Halving it draws the water at
#     half its width and a quarter of its area, which is invisible from the
#     middle of a map.
const WATER_TYPE := "ae0b69fc-2207-d874-8230-fcd467a592cf"


func water() -> Array:
	if src == null or types == null:
		return []
	var out: Array = []
	var name := ""
	for cand in ["%s/default" % _level_dir(), "%s/default" % level]:
		if src.ebx.has(cand):
			name = cand
			break
	if name == "":
		return []
	var raw := src.get_ebx(name)
	if raw.is_empty():
		return []
	var e := BF6Ebx.new(types, walk.gi if walk != null else {})
	if not e.parse(raw):
		return []
	for i in range(e.instance_offsets.size()):
		if e.instance_type(i) != WATER_TYPE:
			continue
		var base: int = e.payload + int(e.instance_offsets[i])
		if base + 0x60 > e.data.size():
			continue
		var sx := e.data.decode_float(base + 0x20)
		var sz := e.data.decode_float(base + 0x48)
		var tx := e.data.decode_float(base + 0x50)
		var ty := e.data.decode_float(base + 0x54)
		var tz := e.data.decode_float(base + 0x58)
		if absf(sx) < 1.0 or absf(sz) < 1.0:
			continue
		out.append({"height": ty, "center": [tx, tz],
			"size": [absf(sx), absf(sz)]})
	if not out.is_empty():
		_say("game source: water — %d surface(s), first at y %.1f, %.0f x %.0f m"
			% [out.size(), float(out[0]["height"]),
			   float((out[0]["size"] as Array)[0]),
			   float((out[0]["size"] as Array)[1])])
	return out


# ---------------------------------------------------------------------------
# THE MAP'S LIGHTS.
#
# 7,878 fixtures on Dumbo — 4,470 spot and 3,408 omni, the same set and the same
# split lights_mine.py produces — collected on the placement walk rather than by
# a second pass: a light inherits the composed world transform of whichever
# prefab holds it, so mining it IS the walk.
#
# The type guids and field hashes are baked in as constants because they have to
# be. The exe's reflection tables carry name HASHES and no names, and the hash is
# not one of the reversible ones — djb2 and fnv in both directions fail on every
# known pair — so a name can only be looked up in a table, never computed. These
# were resolved once from bf6-research's sdk_type_guids.tsv and
# sdk_field_names.tsv, the same way every other constant in this reader was.
#
# GUIDS COME IN PAIRS: the SDK table lists two spellings of most types, one with
# the first three groups byte-swapped. Both are registered because which one a
# given partition uses is not something worth guessing at, and the cost of an
# unused key in a dictionary is nothing.
const LIGHT_TYPES := {
	"02addd9b-6abc-a282-5950-a6f9bc3f87d9": "LocalLight",
	"a2826abc-5059-f9a6-bc3f-87d98e7e8131": "LocalLight",
	"173542d2-6bcc-b1b7-f7dc-9a9f9bc17467": "PbrAnalyticLight",
	"b1b76bcc-dcf7-9f9a-9bc1-746783feaff0": "PbrAnalyticLight",
	"f9310135-b610-00d8-6a82-067a0e8e36f2": "PbrRectangularLight",
	"00d8b610-826a-7a06-0e8e-36f289697545": "PbrRectangularLight",
	"d0528228-e56b-10ab-434c-834bb3d8a821": "PbrSphereLight",
	"10abe56b-4c43-4b83-b3d8-a82181ba3193": "PbrSphereLight",
	"00215d53-9aaa-8dc4-b3de-cdc707ebb39f": "PbrSpotLight",
	"8dc49aaa-deb3-c7cd-07eb-b39fcbe829d8": "PbrSpotLight",
	"3769daef-26a1-5435-a6a2-2041f97521c8": "PbrTubeLight",
	"543526a1-a2a6-4120-f975-21c84b940f78": "PbrTubeLight",
	"9785f711-e676-ea9a-9fd8-00146ed5e43c": "PointLight",
	"f2841e1a-79ec-eae8-c5d8-46998d444f0d": "SpotLight",
}

const F_COLOR := 0x33ED1C78
const F_INTENSITY := 0x13763A5B
const F_ATTEN_RADIUS := 0xC21D1F46
const F_OUTER_ANGLE := 0x56FC2180
const F_LIGHT_UNIT := 0xC07607F5
const F_RADIUS_A := 0x48DAD7C1
const F_RADIUS_B := 0x5CDA5A37
const F_VISIBLE := 0x2A7B2AF9
# Enabled has SIX distinct hash spellings in the SDK table — the name is reused
# across unrelated types and each carries its own hash. All are read and the
# first present wins; picking one and hoping would drop or keep the wrong set.
const F_ENABLED: Array = [0x1E84390E, 0x54C21171, 0x77933D85, 0x89872D33,
	0xCEFB1F0D, 0xF97D7309]

const LIGHT_FIELDS: Array = [F_COLOR, F_INTENSITY, F_ATTEN_RADIUS,
	F_OUTER_ANGLE, F_LIGHT_UNIT, F_RADIUS_A, F_RADIUS_B, F_VISIBLE,
	0x1E84390E, 0x54C21171, 0x77933D85, 0x89872D33, 0xCEFB1F0D, 0xF97D7309]


# The schema highpoly_lighting.set_map_lights already reads, written into the
# map cache. Deliberately the same FILE as the download path used: the light
# builder is 150 lines of Godot-side work — culling, distance fade, the spot
# cone convention — and a second entry point into it is how the two drift until
# only one is right.
func lights(cache_dir: String) -> int:
	if walk == null or walk.ents.is_empty():
		return 0
	var out: Array = []
	var spots := 0
	for e in walk.ents:
		var ent: Dictionary = e
		if str(ent.get("tag", "")) != "light":
			continue
		var tname := str(LIGHT_TYPES.get(str(ent.get("type", "")), ""))
		if tname == "":
			continue
		var f: Dictionary = ent.get("f", {})
		# An explicitly disabled fixture is off in the game and stays off here.
		# Absent means enabled: most lights declare none of the six spellings.
		var off := false
		for h in F_ENABLED:
			if f.has(h) and f[h] == false:
				off = true
				break
		if off or f.get(F_VISIBLE) == false:
			continue
		var xf: Array = ent["xf"]
		var pos: Vector3 = xf[3]
		var col: Vector3 = f.get(F_COLOR, Vector3.ONE) if f.get(F_COLOR) is Vector3 \
			else Vector3.ONE
		var rad = f.get(F_ATTEN_RADIUS)
		if not (rad is float or rad is int):
			rad = f.get(F_RADIUS_A, f.get(F_RADIUS_B, 10.0))
		var spot := tname.contains("Spot")
		var rec := {
			"pos": [pos.x, pos.y, pos.z],
			"spot": spot,
			"radius": float(rad) if (rad is float or rad is int) else 10.0,
			"color": [col.x, col.y, col.z],
			"intensity": float(f.get(F_INTENSITY, 1000.0)),
			"unit": int(f.get(F_LIGHT_UNIT, 0)),
			"layer": "base",
			"type": tname,
		}
		if spot:
			spots += 1
			rec["angle"] = float(f.get(F_OUTER_ANGLE, 60.0))
			# Basis row 2 is FORWARD (right/up/forward/translation at 0..3).
			var d: Vector3 = xf[2]
			if d.length() > 1e-4:
				rec["dir"] = [d.x, d.y, d.z]
		out.append(rec)
	if out.is_empty():
		return 0
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var f2 := FileAccess.open("%s/lights.json" % cache_dir, FileAccess.WRITE)
	if f2 == null:
		_say("game source: lights — cannot write to %s" % cache_dir)
		return 0
	f2.store_string(JSON.stringify({"lights": out}))
	f2.close()
	_say("game source: %d lights (%d spot, %d omni)"
		% [out.size(), spots, out.size() - spots])
	return out.size()


# ---------------------------------------------------------------------------
# THE MAP'S FX SPAWN POINTS.
#
# Already in the walk: every fx_* reference is visited and its world transform
# composed, and the rows that resolve to no mesh are exactly these. So this
# reads the rows rather than walking again.
#
# WHAT IS SHIPPED, AND WHY NOT ALL OF IT. On Dumbo 14,163 rows are fx, and
# ~94% of them are destruction and impact effects — fx_propdest_glass_tiny on
# every window, fx_gendest_metal on every railing. Those are EVENT-TRIGGERED:
# they fire when the prop breaks, and the plugin draws a record as a
# continuously emitting particle system. Shipping them buries the map under
# permanent shattering glass and burns the whole emitter budget on effects that
# are never seen in play. Ambient FX is what reads as the map.
const FX_TRIGGERED: Array = ["dest", "debris", "breakpoint", "impact", "bullet",
	"_hit", "explosion", "detach", "burst", "tracer", "muzzle", "casing"]

# Class drives the plugin's fallback look and its draw distance, so it only has
# to be right about the KIND. Order matters: "smokey_steam" is smoke before it
# is anything else.
const FX_CLASSES: Array = [
	["electric", ["electric", "spark", "arc_", "lightning"]],
	["fire", ["fire", "flame", "burn", "ember", "torch"]],
	["smoke", ["smoke", "steam", "fume", "exhaust"]],
	["dust", ["dust", "sand", "ash", "debris", "trash", "leaf", "leaves",
		"paper", "pollen", "snow", "mist", "fog", "haze"]],
]


static func _fx_class(n: String) -> String:
	for c in FX_CLASSES:
		for tok in (c as Array)[1]:
			if n.contains(str(tok)):
				return str((c as Array)[0])
	return "other"


func fx(cache_dir: String, keep_triggered := false) -> int:
	if walk == null:
		return 0
	var out: Array = []
	var triggered := 0
	var joined := 0
	var graph_cache := {}
	for r in walk.rows:
		var row: Dictionary = r
		var path := str(row["mesh"])
		var leaf := path.get_file().to_lower()
		if leaf.ends_with(".ebx"):
			leaf = leaf.substr(0, leaf.length() - 4)
		if not leaf.begins_with("fx_"):
			continue
		var trig := false
		for tok in FX_TRIGGERED:
			if leaf.contains(str(tok)):
				trig = true
				break
		if trig:
			triggered += 1
			if not keep_triggered:
				continue
		var xf = row["xf"]
		if not (xf is Array) or (xf as Array).size() < 4:
			continue
		var o: Vector3 = (xf as Array)[3]
		var fwd: Vector3 = (xf as Array)[2]
		var yaw := 0.0
		if absf(fwd.x) > 1e-6 or absf(fwd.z) > 1e-6:
			yaw = atan2(fwd.x, fwd.z)
		# THE EMITTER GRAPH, mined rather than shipped. The plugin's fx_params
		# table is keyed by eg_* graph, and an fx_ effect COMPOSES one or more of
		# them — the pipeline kept that mapping in a 23 MB fx_effects.json. It
		# does not need to: an fx partition's imports name the graphs directly,
		# and there are a few hundred distinct effects on a map against tens of
		# thousands of placements, so this is a few hundred header reads.
		var graph = graph_cache.get(leaf)
		if graph == null:
			graph = _fx_graph(path)
			graph_cache[leaf] = graph
		if str(graph) != "":
			joined += 1
		out.append({
			"pos": [o.x, o.y, o.z],
			"yaw": yaw,
			"class": _fx_class(leaf),
			"effect": str(graph) if str(graph) != "" else leaf.to_upper(),
			"source_class": "base",
			"name": leaf,
		})
	if out.is_empty():
		return 0
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var f := FileAccess.open("%s/fx.json" % cache_dir, FileAccess.WRITE)
	if f == null:
		_say("game source: fx — cannot write to %s" % cache_dir)
		return 0
	f.store_string(JSON.stringify({"fx": out, "_map": level,
		"_triggered_excluded": 0 if keep_triggered else triggered}))
	f.close()
	_say("game source: %d fx points (%d event-triggered excluded), "
		% [out.size(), 0 if keep_triggered else triggered]
		+ "%d joined an emitter graph" % joined)
	return out.size()


# The first eg_* partition an fx effect imports, or "".
func _fx_graph(path: String) -> String:
	var n := path.to_lower()
	if n.ends_with(".ebx"):
		n = n.substr(0, n.length() - 4)
	var raw := src.get_ebx(n)
	if raw.is_empty():
		return ""
	var e := BF6Ebx.new(types, walk.gi)
	# The EFIX tables alone carry the imports, and parse() reads exactly those —
	# no instance is decoded here, which is why a few hundred of these is cheap.
	if not e.parse(raw):
		return ""
	for imp in e.imports:
		var target = walk.gi.get(str((imp as Dictionary)["partition"]))
		if target == null:
			continue
		var tl := str(target).get_file().to_lower()
		if tl.ends_with(".ebx"):
			tl = tl.substr(0, tl.length() - 4)
		if tl.begins_with("eg_"):
			return tl.to_upper()
	return ""


# The level's asset directory, e.g. game/glaciermp/levels/mp_dumbo, taken from
# the walk's resolved root rather than reconstructed from a studio name.
func _level_dir() -> String:
	var root := str(walk.stats.get("root", "")) if walk != null else ""
	if root == "":
		return ""
	if root.to_lower().ends_with(".ebx"):
		root = root.substr(0, root.length() - 4)
	return root.get_base_dir()


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
# WHERE A MESH'S TIME GOES, accumulated across the whole build in microseconds.
#
# Split three ways because the three want different fixes and the total says
# nothing about which: reading and decompressing the resource is I/O against the
# CAS, parsing it is byte work that could go on a worker thread, and the
# material is a depot lookup plus a texture decode and a GPU upload that cannot.
# Guessing which dominates is how the last two optimisation attempts this
# session went wrong.
var t_res := 0
var t_parse := 0
var t_mat := 0
var n_meshes := 0


func mesh_for(group_key: String, lod := 0) -> Mesh:
	var _t0 := Time.get_ticks_usec()
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
	t_res += Time.get_ticks_usec() - _t0
	var _t1 := Time.get_ticks_usec()
	var mat_us := 0
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
		var _t2 := Time.get_ticks_usec()
		var mat = material_for(int(sec.get("state_key", 0)), scope) \
			if build_materials else null
		var _dm := Time.get_ticks_usec() - _t2
		t_mat += _dm
		mat_us += _dm
		if mat != null:
			am.surface_set_material(am.get_surface_count() - 1, mat)
	# Parse covers everything from the MeshSet header to the finished ArrayMesh
	# — read_lod plus the surface building — with the material time subtracted
	# out, because the materials are interleaved into that loop and counting
	# them twice would make the two halves sum to more than the whole.
	t_parse += (Time.get_ticks_usec() - _t1) - mat_us
	n_meshes += 1
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
	var nrm = _texture_for(slots.get("normal", slots.get("normal_vt")), true)
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


func _texture_for(file_guid, is_normal := false):
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
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)),
		texture_max_dim)
	if got.is_empty() or not (got.get("image") is Image):
		_tex_cache[an] = null
		tex_stats["failed"] = int(tex_stats["failed"]) + 1
		return null
	# COMPRESS BEFORE UPLOADING, which is the difference between 12.8 GB and
	# something a machine can hold.
	#
	# Measured over the whole map: geometry alone costs +460 MB, geometry with
	# textures +12,775 MB — so 2,229 textures were taking 12.3 GB, about 5.5 MB
	# each. A 1024x1024 block-compressed texture is half a megabyte; 5.5 MB is
	# an uncompressed RGBA8 (or worse, a half-float) sitting resident, which is
	# exactly what the download path found on ITS textures before the .bctex
	# pool: "every single one is uncompressed RGB8 or RGBA8, 147 MB of GLB
	# decodes to 639 MB resident", fixed there by S3TC for 5.1x.
	#
	# Some arrive already block-compressed straight out of the game, and
	# is_compressed() skips those. NORMAL MAPS GET BC5: compressing a normal map
	# as DXT puts visible banding on every curved surface, and it is the classic
	# mistake with this optimisation.
	var img := got["image"] as Image
	# WHAT IS ACTUALLY RESIDENT, recorded per texture. Compressing before upload
	# turned out to be a no-op — every image already arrives block-compressed
	# from the game — yet 2,229 of them still cost 12.3 GB, about 5.5 MB each.
	# A 1024x1024 BC1 is half a megabyte, so either these are much larger than
	# 1K or they carry full mip chains, and those want different fixes. Measured
	# rather than guessed a third time.
	# The CHUNK matters as much as the size. A streamed chunk is mip 0 on its
	# own, so there is no smaller level in it to take; an embedded chunk carries
	# the tail of the chain and a resolution cap can simply pick a lower mip for
	# free. Which one these arrive in decides whether capping is a slice or a
	# decompress-and-resize.
	var key := "%dx%d f%d %s%s" % [img.get_width(), img.get_height(),
		img.get_format(), str(got.get("chunk", "?")),
		" mip" if img.has_mipmaps() else ""]
	tex_dims[key] = int(tex_dims.get(key, 0)) + 1
	tex_stats["bytes"] = int(tex_stats.get("bytes", 0)) + img.get_data().size()
	if not img.is_compressed() and img.get_width() >= 4 and img.get_height() >= 4:
		img.compress(Image.COMPRESS_S3TC,
			Image.COMPRESS_SOURCE_NORMAL if is_normal
				else Image.COMPRESS_SOURCE_GENERIC)
		tex_stats["compressed"] = int(tex_stats.get("compressed", 0)) + 1
	var t := ImageTexture.create_from_image(img)
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
