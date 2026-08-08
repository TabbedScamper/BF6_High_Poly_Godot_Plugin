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

# Where terrain_surface writes, when the caller wants the ground built as part of
# the open rather than in the middle of the build. Empty = do not build it here.
var surface_cache := ""

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
var _mat_by_look := {}                 # "<albedo>|<normal>|<emissive>" -> Material

# SHARING A BUILT MESH ACROSS SCOPES.
#
# map_data groups placements by (mesh, scope) because a shader state key is only
# unique within a scope. Measured on mp_dumbo that turns 2,117 distinct meshes
# into 5,498 groups: 3,381 of them (61%) are a mesh that has already been read
# from the CAS, parsed and turned into an ArrayMesh once. Parsing is 56.9 s of
# an 87 s build, so those repeats are the single largest item in it.
#
# They are only repeats if the RESULT is the same, and it usually is: of the
# 1,266 meshes placed from more than one scope, 1,174 (93%) resolve to
# byte-identical texture sets in every one, 34 genuinely differ, and 58 resolve
# nothing anywhere. So the share is conditional on the materials, not assumed
# from the mesh name — the 34 that differ still get a mesh each.
#
# `_keys_for` is what makes the test cheap. The ordered list of merge keys is a
# property of the MeshSet alone, so once one scope has parsed a mesh, any other
# scope can work out what its materials WOULD be from depot lookups alone and
# skip the parse entirely when they match.
var _keys_for := {}                    # "<res>#<lod>" -> [merge keys, in order]
var _mesh_by_sig := {}                 # "<res>#<lod>#<material ids>" -> Mesh
var n_mesh_shared := 0
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
	_geom_open()

	# THE GROUND'S APPEARANCE IS BUILT HERE, not in map_data, and the reason is
	# which thread each runs on. map_data is called from the middle of the build,
	# on the main thread; terrain_surface is about a minute of BC7 decoding and
	# page compositing the first time a map is seen. Doing it there would freeze
	# the editor for a minute with a dead UI and no way to say why.
	#
	# Here it is on the open_async worker, behind the progress bar that already
	# exists for the 85 s cold open, and it is pure Image and file work — no
	# Node, no ImageTexture, no RenderingServer — which is what makes it safe off
	# the main thread. map_data's own call then finds the cache and costs
	# nothing.
	if surface_cache != "":
		t = Time.get_ticks_msec()
		if progress.is_valid():
			progress.call("reading the ground", 0, 0)
		terrain_surface(surface_cache)
		timings["terrain surface"] = Time.get_ticks_msec() - t
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
		# AND BY VARIATION. Two placements of one crate under two different
		# ObjectVariations are two different materials — that is the whole point
		# of a variation — so folding them into one group would dress both from
		# whichever was seen first. The geometry is NOT split by this: the
		# geometry cache is keyed on the mesh alone, so a second variation costs
		# a material lookup and not a re-parse.
		var vh := _variation_live(scope, _var_hash(row.get("var")), res_name)
		var gkey := "%s|%s|%d" % [res_name, scope, vh]
		var is_bd: bool = root_ref != "" \
			and str(row.get("src", "")).to_lower() == root_ref \
			and str(row.get("kind", "")).begins_with("smg")
		var into: Dictionary = by_bd if is_bd else by_mesh
		if not into.has(gkey):
			into[gkey] = PackedFloat32Array()
			_group_meta[gkey] = [res_name, scope, str(row.get("src", "")), vh]
		var a: PackedFloat32Array = into[gkey]
		# TRANSPOSED ON THE WAY OUT, and this is the whole of the 12-float
		# convention rather than a detail of it.
		#
		# The walk emits right/up/forward as three vectors, each the world
		# direction of the placement's local X, Y and Z — which is the honest
		# reading of a Frostbite LinearTransform and the convention its own
		# composition uses. The downstream format is the other one: _xform()
		# builds `basis.x = (f0, f3, f6)`, i.e. it reads the flattened 12 as a
		# row-major matrix and takes its COLUMNS. Handing it our vectors in order
		# gives it the transpose of the rotation, which for an orthonormal basis
		# is the INVERSE rotation.
		#
		# This failure passes every cheap check. The translation is untouched, so
		# every object lands in exactly the right place; a transposed rotation is
		# still perfectly orthonormal, so an orthonormality audit passes it; and
		# it is invisible on any placement whose rotation happens to be
		# symmetric. It shows up only as "everything is in the right spot but
		# facing the wrong way" — which is exactly how it was reported.
		#
		# The Python pipeline does this in spec_to_raw.py and measured it there:
		# 73.6% of placements differed by exactly a transpose, and the other
		# 26.3% were the symmetric cases where the transpose equals the original.
		# That 26.3% is why a spot check of a handful of props can look fine.
		var r0: Vector3 = (xf as Array)[0]
		var r1: Vector3 = (xf as Array)[1]
		var r2: Vector3 = (xf as Array)[2]
		var o3: Vector3 = (xf as Array)[3]
		a.push_back(r0.x); a.push_back(r1.x); a.push_back(r2.x)
		a.push_back(r0.y); a.push_back(r1.y); a.push_back(r2.y)
		a.push_back(r0.z); a.push_back(r1.z); a.push_back(r2.z)
		a.push_back(o3.x); a.push_back(o3.y); a.push_back(o3.z)
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
		# The ground's appearance — colour map, layer palette, splat. The
		# expensive one, and skipped outright once the map's cache holds it.
		var sf := terrain_surface(cache_dir)
		if not sf.is_empty():
			out["surface"] = sf
		timings["terrain surface"] = Time.get_ticks_msec() - t
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
# WHAT THE GROUND LOOKS LIKE — the colour map, the layer palette and the splat,
# all out of terrain block 1 and the level's layer-graph chain.
#
# Until now the ground was four bundled PNGs blended by slope, and since the
# maptile came out it had no large-scale colour at all. The game ships all three
# missing pieces:
#
#   THE COLOUR MAP (§5.3). One BC7 tile per streaming-tree node, trailing the
#   weight pages in the node's CAS chunk. It is the aerial photograph the engine
#   modulates every terrain material by, it covers the whole ±4096 m footprint
#   rather than the playable bowl, and 1,109 tiles assemble into a seamless
#   image of Brooklyn with no visible seam and no shuffled quadrant.
#
#   THE PALETTE (§9). 47 layers on Dumbo, of which 16 bind textures — cobblestone,
#   concrete tile, broken asphalt, fairway grass, sand, gravel, cracked concrete
#   — with the layer's own UV tiling rate beside each. Every one resolves.
#
#   THE SPLAT (§5.2). Per-layer 66x66 coverage pages saying which layer covers
#   which ground. 10,425 pages on Dumbo, and the street grid comes out of them
#   as a picture.
#
# THE OTHER 31 LAYERS BIND NOTHING, and that is not a resolution failure. They
# are shader-computed materials (see the research's
# `material-with-no-albedo-is-shader-computed`): their surface exists only inside
# the compiled shader program. On Dumbo those cover 88% of the map — the ground
# outside the playable area, which in game is only ever seen at a distance and
# whose appearance the engine takes from the colour map. Using the colour map
# there is not a shortcut around a missing texture; it is the same data path the
# engine uses.
#
# ALL OF IT IS CACHED. The composite is ~40 s of GDScript, once per map, into
# the same per-map cache directory the heightfield goes to, in exactly the
# layout the terrain shader's splat path already reads.
const SURFACE_RES := 2048              # splat raster side
const COLOR_RES := 4096                # colour map side (~2 m per texel on a 8 km map)
const LAYER_TEX_DIM := 512             # per-slice detail textures; all slices must match


func terrain_surface(cache_dir: String, force := false) -> Dictionary:
	if src == null or cache_dir == "":
		return {}
	var dir_splat := "%s/splat" % cache_dir
	var meta_path := "%s/layers.json" % dir_splat
	if not force and FileAccess.file_exists(meta_path) \
			and FileAccess.file_exists("%s/colormap.png" % cache_dir):
		var got: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if got is Dictionary:
			return got as Dictionary

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
	var b1 := t.find_block(res, 1)
	if b1.is_empty():
		_say("game source: terrain surface — %s" % t.error)
		return {}
	var sp := BF6Splat.new()
	if not sp.parse(b1):
		_say("game source: terrain surface — %s" % sp.error)
		return {}
	var chunks := t.read_chunk_directory(res)
	if chunks.is_empty() or not sp.detect_layout(chunks):
		_say("game source: terrain surface — %s" % (sp.error if sp.error != "" else t.error))
		return {}
	var fetch := func(g): return src.get_chunk(str(g))

	DirAccess.make_dir_recursive_absolute(dir_splat)
	DirAccess.make_dir_recursive_absolute("%s/terrain_layers" % cache_dir)
	# STALE SLICES GO FIRST. A rebuild that produces fewer layers than the last
	# one leaves the old lNN_*.png behind, and those are the exact hazard the
	# loader warns about — a leftover slice at a different resolution makes
	# Texture2DArray refuse the whole set and hand back a zero-layer texture,
	# which is not null, so nothing downstream notices. (mp_dumbo's cache still
	# held a 256px l05 from the download pipeline.)
	var old := DirAccess.get_files_at(dir_splat)
	for f in old:
		var fn := str(f)
		if fn.begins_with("l") and fn.ends_with(".png"):
			DirAccess.remove_absolute("%s/%s" % [dir_splat, fn])

	# ---- the colour map ------------------------------------------------------
	var t0 := Time.get_ticks_msec()
	var tiles := sp.color_tiles(chunks, fetch)
	var t_read := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	var cmap := sp.assemble_colors(tiles, COLOR_RES)
	var t_asm := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	if cmap != null:
		cmap.save_png("%s/colormap.png" % cache_dir)
	_say("game source: terrain colour map — %d tiles, %dx%d (read %.1fs, assemble %.1fs, write %.1fs)"
		% [tiles.size(), COLOR_RES, COLOR_RES, t_read / 1000.0, t_asm / 1000.0,
		   (Time.get_ticks_msec() - t0) / 1000.0])

	# ---- the palette ---------------------------------------------------------
	var pidx: Dictionary = walk.gi if walk != null and walk.gi is Dictionary \
		else src.partition_index()
	var pal := BF6TerrainLayers.new()
	if not pal.load(src, level, pidx):
		_say("game source: terrain layers — %s" % pal.error)
		return {}

	# ---- the splat -----------------------------------------------------------
	t0 = Time.get_ticks_msec()
	var comp := sp.composite(chunks, fetch, SURFACE_RES)
	_say("game source: terrain splat composite — %.1fs"
		% ((Time.get_ticks_msec() - t0) / 1000.0))
	if comp.is_empty():
		_say("game source: terrain splat — %s" % sp.error)
		return {}

	# ---- the base field, which is where the materials actually are ----------
	#
	# The weight pages alone give a two-texture ground, and that is not a bug in
	# them. On mp_dumbo 30 layers are PAINTED and 2 of those have a texture,
	# while 16 layers are BASE (no page, full coverage) and 11 of those do. The
	# palette's cobblestone, concrete tile, broken asphalt and gravel are all on
	# the base side, and block 7 is what says which one covers which texel.
	#
	# Decoded, dumbo's base field is the Brooklyn block grid: 16% cobblestone
	# pavement in exactly the shape of the city blocks, everything else on a
	# shader-computed layer. Which matches §8's claim that the resolved base
	# field reproduces the real street grids.
	var base := PackedByteArray()
	var b7 := t.find_block(res, 7)
	if not b7.is_empty():
		var mt := BF6MaterialTree.new()
		t0 = Time.get_ticks_msec()
		if mt.parse(b7):
			var linked: Array = []
			for l in pal.layers:
				if int((l as Dictionary)["link"]) >= 0:
					linked.append(int((l as Dictionary)["index"]))
			linked.sort()
			base = mt.rasterize(SURFACE_RES, func(k): return sp.base_list(k),
				sp.full_list(), linked)
			_say("game source: terrain base field — %d pairs, %d nodes, %.1fs"
				% [mt.pairs.size(), mt.nodes.size(),
				   (Time.get_ticks_msec() - t0) / 1000.0])
		else:
			_say("game source: terrain base field — %s" % mt.error)

	# WHAT IS LEFT AFTER THE LAYERS WE CAN DRAW.
	#
	# A painted layer with no texture is shader-computed: its appearance lives
	# inside a compiled shader program and there is nothing to sample. So the
	# share of a texel those layers hold is not something we can paint, and
	# handing it to the base material — the ground underneath, which usually DOES
	# have a texture — is the closest honest approximation. Where the base has no
	# texture either, the weight stays unclaimed and the shader's slope fallback
	# takes it, modulated by the colour map.
	var textured := {}
	for l in pal.layers:
		var li := int((l as Dictionary)["index"])
		if pal.albedo_of(li) != "":
			textured[li] = true
	if base.size() == SURFACE_RES * SURFACE_RES:
		var idx0: PackedByteArray = comp["idx"]
		var wgt0: PackedByteArray = comp["w"]
		var placed := 0
		for i in range(base.size()):
			var bl := int(base[i])
			if bl == 255 or not textured.has(bl):
				continue
			var o := i * 4
			var s_tex := 0
			for k in range(4):
				if wgt0[o + k] == 0:
					break
				if textured.has(int(idx0[o + k])):
					s_tex += int(wgt0[o + k])
			if s_tex >= 255:
				continue
			BF6Splat._insert(idx0, wgt0, o, bl, 255 - s_tex)
			placed += 1
		_say("game source: terrain base field placed on %.0f%% of texels"
			% (100.0 * float(placed) / float(maxi(1, base.size()))))

	var per_layer := {}
	var idx_c: PackedByteArray = comp["idx"]
	var wgt_c: PackedByteArray = comp["w"]
	for i in range(SURFACE_RES * SURFACE_RES):
		var o := i * 4
		for s in range(4):
			if wgt_c[o + s] == 0:
				break
			var l := int(idx_c[o + s])
			per_layer[l] = int(per_layer.get(l, 0)) + 1

	# SLICES ARE THE TEXTURED LAYERS THAT ACTUALLY APPEAR, ordered by how much
	# ground they cover. The shader indexes a Texture2DArray, so the indices have
	# to be compact 0..N-1 — the raw layer index is not, and 47 slices of which
	# 31 would be blank is 31 textures uploaded to draw nothing.
	var slice_of := {}
	var picked: Array = []
	var by_area: Array = per_layer.keys()
	by_area.sort_custom(func(x, y): return int(per_layer[x]) > int(per_layer[y]))
	for l in by_area:
		var li := int(l)
		if pal.albedo_of(li) == "":
			continue
		slice_of[li] = picked.size()
		picked.append(li)
		if picked.size() >= 32:
			break

	var slice_meta: Array = []
	var written := 0
	for s in range(picked.size()):
		var li: int = picked[s]
		var alb := _layer_image(pal.albedo_of(li), false)
		var nrm := _layer_image(pal.normal_of(li), true)
		if alb == null:
			continue
		if nrm == null:
			# A flat normal rather than dropping the slice: the albedo is the
			# part that carries the look, and Texture2DArray refuses a set with
			# a hole in it.
			nrm = Image.create_empty(LAYER_TEX_DIM, LAYER_TEX_DIM, false,
				Image.FORMAT_RGB8)
			nrm.fill(Color(0.5, 0.5, 1.0))
		alb.save_png("%s/l%02d_alb.png" % [dir_splat, s])
		nrm.save_png("%s/l%02d_nrm.png" % [dir_splat, s])
		written += 1
		slice_meta.append({
			"layer": li,
			"albedo": pal.albedo_of(li).get_file(),
			"metres_per_repeat": pal.metres_per_repeat(li),
			"texels": int(per_layer.get(li, 0)),
		})

	# Remap the composited layer indices to slice indices. A texel whose layer
	# has no texture is left pointing past the end of the array on purpose: the
	# shader's `id < splat_slices` test then falls back for it, which is the
	# right answer for a shader-computed layer we cannot reproduce.
	#
	# Through a 256-entry lookup rather than a dictionary. This runs over 16.7
	# million bytes; a Dictionary.get per byte is about a minute of GDScript, and
	# a PackedByteArray index is the same answer for free.
	var lut := PackedByteArray()
	lut.resize(256)
	lut.fill(255)
	for l in slice_of.keys():
		lut[int(l)] = int(slice_of[l])
	var idx: PackedByteArray = comp["idx"]
	var wgt: PackedByteArray = comp["w"]
	var out_of_slice := 0
	for i in range(idx.size()):
		if wgt[i] == 0:
			idx[i] = 255
		else:
			var s := int(lut[idx[i]])
			idx[i] = s
			if s == 255 and (i & 3) == 0:
				out_of_slice += 1

	var img_idx := Image.create_from_data(SURFACE_RES, SURFACE_RES, false,
		Image.FORMAT_RGBA8, idx)
	var img_w := Image.create_from_data(SURFACE_RES, SURFACE_RES, false,
		Image.FORMAT_RGBA8, wgt)
	img_idx.save_png("%s/idx.png" % dir_splat)
	img_w.save_png("%s/w.png" % dir_splat)

	# ---- the slope fallback, also from the game ------------------------------
	_write_fallback_layers(pal, picked, "%s/terrain_layers" % cache_dir)

	var meta := {
		"slices": written,
		"world": {"x0": sp.root_min.x, "z0": sp.root_min.y,
			"size": sp.root_max.x - sp.root_min.x},
		"colormap": {"file": "colormap.png", "res": COLOR_RES,
			"x0": sp.root_min.x, "z0": sp.root_min.y,
			"size": sp.root_max.x - sp.root_min.x},
		"layers": slice_meta,
	}
	var f := FileAccess.open(meta_path, FileAccess.WRITE)
	if f == null:
		_say("game source: terrain surface — cannot write %s" % meta_path)
		return {}
	f.store_string(JSON.stringify(meta, "  "))
	f.close()
	_say(("game source: terrain splat — %d pages over %d layers, %d textured "
		+ "slices, %.0f%% of ground on a shader-computed layer")
		% [int(comp["pages"]), per_layer.size(), written,
		   100.0 * float(out_of_slice) / float(maxi(1, SURFACE_RES * SURFACE_RES))])
	return meta


# One layer texture, decoded from the game and squared off to LAYER_TEX_DIM.
#
# Every slice has to be the same size or Texture2DArray rejects the whole set
# and leaves a 0-layer texture behind, which is not null — so every check
# downstream passes and the shader samples an empty array across the map. That
# is the speckled-black ground the download path shipped once; sizing here
# rather than at load is what stops it recurring.
func _layer_image(res_name: String, _is_normal: bool) -> Image:
	if res_name == "":
		return null
	var raw := src.get_res(res_name)
	if raw.is_empty():
		return null
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)),
		LAYER_TEX_DIM)
	if got.is_empty() or not (got.get("image") is Image):
		return null
	var img := got["image"] as Image
	if img.is_compressed():
		if img.decompress() != OK:
			return null
	img.convert(Image.FORMAT_RGB8)
	if img.get_width() != LAYER_TEX_DIM or img.get_height() != LAYER_TEX_DIM:
		img.resize(LAYER_TEX_DIM, LAYER_TEX_DIM, Image.INTERPOLATE_LANCZOS)
	return img


# The ground/cliff pair the shader falls back to, taken from the game's palette
# instead of the four PNGs that used to ship beside this plugin.
#
# BOTH ARE HEURISTICS and are named as such, because nothing in the data says
# which layer is the flat one and which is the steep one — that is a fact about
# the slope blend, which is ours, not about the terrain.
#
# GROUND is the textured layer covering the most ground, which is the best
# available answer to "what does this map's dirt look like". It deliberately
# skips `t_ter_defaulttexture`: that is the engine's own default terrain
# material and it is a FLAT NEUTRAL PLATE — using it because it sounds
# authoritative gives a fallback with no detail in it at all, which is worse
# than the bundled png it replaced. Checked by looking at the decoded image.
#
# CLIFF is the highest-covering rock/gravel/stone layer, or the second-placed
# layer when the map has none.
func _write_fallback_layers(pal, by_area: Array, out_dir: String) -> void:
	var ground := -1
	var cliff := -1
	for l in by_area:
		var i := int(l)
		var nm: String = pal.albedo_of(i)
		if nm == "" or nm.contains("defaulttexture") or nm.contains("debug"):
			continue
		if ground < 0:
			ground = i
			continue
		if cliff < 0 and (nm.contains("rock") or nm.contains("gravel")
				or nm.contains("stone") or nm.contains("cliff")):
			cliff = i
	if cliff < 0:
		for l in by_area:
			if int(l) != ground and pal.albedo_of(int(l)) != "":
				cliff = int(l)
				break
	if ground < 0:
		return
	if cliff < 0:
		cliff = ground
	for pair in [[ground, "ground"], [cliff, "cliff"]]:
		var li: int = pair[0]
		var tag: String = pair[1]
		var a := _layer_image(pal.albedo_of(li), false)
		if a != null:
			a.save_png("%s/%s_alb.png" % [out_dir, tag])
		var n := _layer_image(pal.normal_of(li), true)
		if n != null:
			n.save_png("%s/%s_nrm.png" % [out_dir, tag])


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
// A DECAL's basecolor alpha IS its coverage - measured, 11 of the 13 basecolors
// used by records with no op slot have a varying alpha and it is exactly the
// ribbon fading into the ground. A TERRAIN LAYER's basecolor alpha is not:
// concrete tile spans 0.86..1.00, cobblestone 0.54..1.00 and broken asphalt
// 0.40..1.00, and that is a blend/height field, not coverage. The same
// `ALPHA = cv.a` fallback is right for the first and would draw every block
// pavement at 54% opacity for the second, so the layer route says so.
uniform bool opaque_alpha = false;
uniform vec4 flat_col : source_color = vec4(0.35, 0.35, 0.35, 1.0);
void fragment() {
	vec4 c = has_cv ? texture(cv, UV) : flat_col;
	ALBEDO = c.rgb;
	// R, not A. Of this map's 33 op textures, 30 vary on R and one on A.
	ALPHA = opaque_alpha ? 1.0 : (has_op ? texture(op, UV).r : c.a);
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
		# A PROP-LESS RECORD IS NOT A BROKEN ONE, and it is not a small case:
		# 135 of this map's 433 records carry no textures at all, and their
		# AssetSlot is a terrain LAYER-GRAPH LAYER INDEX. The surface is that
		# layer's own material - slot 8 is L08 concrete tile on 109 records,
		# which is every block pavement on the map. Those were drawing flat grey.
		var key := "%s|%s" % [cv, op]
		if cv == "" and op == "":
			key = "layer:%d" % int(rec["asset_slot"])
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
			var t1 := float(rec["tiling1"])
			if absf(t1) < 1e-3:
				t1 = t0
			# ALONG THE RIBBON, NOT ALONG WORLD X AND Z.
			#
			# The fallback used to tile a fill as (x/t0, z/t0), which is
			# axis-aligned world tiling. That is correct only for a road that
			# happens to run north-south or east-west, and Dumbo's street grid is
			# rotated — so some roads looked perfect and the rest carried lane
			# markings and asphalt grain running across them at an angle.
			#
			# §10.4 says the engine reconstructs u in-shader from world position
			# and the record's DIRECTION, which the vertex format carries as a
			# per-record constant tangent. Projecting onto that tangent and its
			# perpendicular is that reconstruction.
			var dir := td.direction(rec)
			for i in range(n):
				var x := vs[i * 4]
				var z := vs[i * 4 + 1]
				verts.push_back(Vector3(x, _height_at(x, z) + ROAD_Y_BIAS, z))
				if stamp:
					uvs.push_back(Vector2(vs[i * 4 + 3], vs[i * 4 + 2]))
				else:
					uvs.push_back(Vector2((x * dir.x + z * dir.y) / t0,
						(-x * dir.y + z * dir.x) / t1))
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


# The terrain layer palette, loaded once, for the prop-less road records.
var _road_pal = null
var _road_pal_tried := false


func _road_layer_albedo(layer: int):
	if not _road_pal_tried:
		_road_pal_tried = true
		var pal := BF6TerrainLayers.new()
		var pidx: Dictionary = walk.gi if walk != null and walk.gi is Dictionary 			else {}
		if pal.load(src, level, pidx):
			_road_pal = pal
		else:
			_say("game source: roads - terrain layer palette: %s" % pal.error)
	if _road_pal == null:
		return null
	var nm: String = _road_pal.albedo_of(layer)
	if nm == "":
		return null
	var raw := src.get_res(nm)
	if raw.is_empty():
		return null
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)),
		texture_max_dim)
	if got.is_empty() or not (got.get("image") is Image):
		return null
	return ImageTexture.create_from_image(got["image"] as Image)


func _road_material(key: String) -> Material:
	if _road_shader == null:
		_road_shader = Shader.new()
		_road_shader.code = ROAD_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _road_shader
	# THE SURFACE GOES UNDER THE MARKINGS, and nothing in the file says so.
	#
	# These draw blended with depth writes off, so depth cannot separate two
	# coplanar ribbons - whichever is submitted last wins. And they DO overlap:
	# 3,189 record pairs intersect in XZ on this map, by design.
	#
	# The authored sequence does not help. Record order, vertex-buffer order and
	# index-buffer order are all the SAME single sequence (checked), and in it
	# the plain fills sit LATER than the detail - mean rank 275 against 189, with
	# 976 pairs where a fill follows a marking. Emitting in file order, which is
	# what we did, is therefore exactly what buries the road under a plain plane.
	#
	# The split is structural rather than a guess about size. A prop-less record
	# takes a TERRAIN LAYER's material: that is a road surface. A record with its
	# own property stream names a decal texture, and 238 of those 298 carry an
	# `op` coverage mask, which is what a marking needs and a surface does not.
	# The footprints agree - fills median 1,756 m2 against detail's 518 - but the
	# binding is the reason, not the area.
	#
	# So: fills at priority 0, detail at 1. Godot draws higher priority later.
	mat.render_priority = 1
	# The terrain-layer route. The palette is the same one the ground reads, so
	# a pavement decal and the pavement under it are painted from one source
	# rather than two that can disagree.
	if key.begins_with("layer:"):
		mat.render_priority = 0
		var li := int(key.substr(6))
		var alb = _road_layer_albedo(li)
		if alb != null:
			mat.set_shader_parameter("cv", alb)
			mat.set_shader_parameter("has_cv", true)
		# Full coverage: the layer carries no `_op` of its own (checked - the
		# four layers these records point at bind only cv/ao/nhs) and its
		# basecolor alpha is a blend field rather than a mask.
		mat.set_shader_parameter("opaque_alpha", true)
		return mat
	var parts := key.split("|")
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


# ---------------------------------------------------------------------------
# THE SKY, from the level's own VisualEnvironment preset.
#
# The panorama the game draws behind the level. One .dds of it used to ship
# inside this addon — Battlefield art, handed to everyone who installed the
# plugin — which is exactly what it must not do; it is read from the player's
# install instead, like everything else.
#
# The active preset is the non-`thermal` ve_* partition the level root imports.
# `SkyType` 0 selects the panoramic path, `PanoramicTexture` is the HDR image,
# and `LuminanceScale` carries its magnitude: panoramas ship NORMALISED, so the
# texture alone is not the brightness.
#
# 360 x 90, NOT 360 x 180 — the trap this whole feature turns on. The 4:1 aspect
# is angular coverage: the top row is the ZENITH, the bottom row the HORIZON,
# and there is no below-horizon content at all. Godot's PanoramaSkyMaterial
# wants a 2:1 equirect, and handing it the texture directly stretches 90 degrees
# of sky over a full sphere — measured across 22 maps, that puts the painted sun
# BELOW the horizon on every one. So it is remapped: the panorama occupies the
# upper half and the horizon row is carried down to fill the lower.
const F_PANORAMIC_TEXTURE := 0xC4184CD8
const F_LUMINANCE_SCALE := 0x5EBAF2B1
const F_SKY_TYPE := 0xFF6D65E7
const F_PANORAMIC_ROTATION := 0x89F2223A


# {texture, luminance_scale, rotation} or {} when the level has no panorama.
func sky() -> Dictionary:
	if src == null or walk == null or types == null:
		return {}
	if not _sky_cache.is_empty():
		return _sky_cache
	# EVERY ve_* the root imports, best candidate first, because the level root
	# imports several and only one of them is the environment. Dumbo's first is
	# ve_sunflare_01, a lens-flare preset with no sky in it at all - so the
	# choice is made on CONTENT (does it carry a PanoramicTexture) rather than on
	# the name, with the name only used to order the search.
	for ve in _ve_candidates():
		var got := _sky_from(str(ve))
		if not got.is_empty():
			_sky_cache = got
			_say("game source: sky - %s, luminance scale %.0f"
				% [str(ve).get_file(), got["luminance_scale"]])
			return got
	return {}


func _sky_from(ve: String) -> Dictionary:
	var raw := src.get_ebx(ve)
	if raw.is_empty():
		return {}
	var e := BF6Ebx.new(types, walk.gi)
	if not e.parse(raw):
		return {}

	# THE PANORAMA IS AN IMPORT, NOT A FIELD VALUE. PanoramicTexture is present
	# on the sky component and is NULL in the shipped data - the pointer is
	# resolved at load - while SkyType and LuminanceScale beside it are set. So
	# the texture is found the only way it can be: among the partition's
	# imports, which name it directly.
	var pano := _panorama_import(e)
	if pano == "":
		return {}
	var tex = _texture_for_asset(pano)
	if tex == null:
		return {}
	var img: Image = (tex as ImageTexture).get_image()
	if img == null:
		return {}

	# The scalars DO come from the component, where they are real.
	var lum := 0.0
	var rot := 0.0
	for i in range(e.instance_offsets.size()):
		var inst = e.read_instance(i)
		if not (inst is Dictionary) or not (inst as Dictionary).has(F_LUMINANCE_SCALE):
			continue
		var d: Dictionary = inst
		lum = float(d.get(F_LUMINANCE_SCALE, 0.0))
		rot = float(d.get(F_PANORAMIC_ROTATION, 0.0))
		break
	return {
		"texture": ImageTexture.create_from_image(_to_equirect(img)),
		"luminance_scale": lum,
		"rotation": rot,
		"preset": ve.get_file(),
		"panorama": pano.get_file(),
	}


# The sky panorama among a VE partition's imports.
#
# Told apart by name, because that is what distinguishes them: the same
# partition also imports hdrcube_<level>_NN (the reflection cubemap, not a sky)
# and t_skypanoramicprocedural_b (a procedural fallback, not this level's
# painted sky). Both would resolve and both would be wrong.
func _panorama_import(e: BF6Ebx) -> String:
	var best := ""
	for imp in e.imports:
		var t = walk.gi.get(str((imp as Dictionary)["partition"]))
		if t == null:
			continue
		var n := str(t).to_lower()
		if n.ends_with(".ebx"):
			n = n.substr(0, n.length() - 4)
		var leaf := n.get_file()
		if not leaf.contains("panoramicsky"):
			continue
		if leaf.contains("procedural") or leaf.contains("hdrcube"):
			continue
		if leaf.contains(level):
			return n              # this level's own sky wins outright
		if best == "":
			best = n
	return best


# Decode a texture by ASSET NAME rather than by guid. The panorama is reached
# through the import list, which already gives the name.
func _texture_for_asset(asset: String):
	var an := asset.to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	if _tex_cache.has(an):
		return _tex_cache[an]
	var raw := src.get_res(an)
	if raw.is_empty():
		_tex_cache[an] = null
		return null
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)), 0)
	if got.is_empty() or not (got.get("image") is Image):
		_tex_cache[an] = null
		return null
	var t := ImageTexture.create_from_image(got["image"] as Image)
	_tex_cache[an] = t
	return t


var _sky_cache := {}


# Every ve_* the level root imports, most likely first: the ones naming this
# level, then the rest. `thermal` is dropped outright - it is the thermal-optic
# preset, it decodes fine, and it is not what the level looks like.
func _ve_candidates() -> Array:
	var root := str(walk.stats.get("root", ""))
	if root == "":
		return []
	if root.to_lower().ends_with(".ebx"):
		root = root.substr(0, root.length() - 4)
	var raw := src.get_ebx(root)
	if raw.is_empty():
		return []
	var e := BF6Ebx.new(types, walk.gi)
	if not e.parse(raw):
		return []
	var named: Array = []
	var other: Array = []
	for imp in e.imports:
		var target = walk.gi.get(str((imp as Dictionary)["partition"]))
		if target == null:
			continue
		var n := str(target).to_lower()
		if n.ends_with(".ebx"):
			n = n.substr(0, n.length() - 4)
		var leaf := n.get_file()
		if not leaf.begins_with("ve_") or leaf.contains("thermal"):
			continue
		if leaf.contains(level):
			named.append(n)
		else:
			other.append(n)
	named.append_array(other)
	return named


# A PointerRef's FILE guid, whichever shape the deserializer handed back.
static func _ref_guid(v):
	if v is Dictionary:
		var d: Dictionary = v
		for k in ["import", "file", "partition"]:
			if d.has(k) and str(d[k]) != "":
				return str(d[k])
	return null


# 4:1 sky-dome panorama -> the 2:1 equirect PanoramaSkyMaterial expects.
#
# Upper half is the panorama (zenith at the top, horizon at its bottom row);
# lower half repeats the horizon row, so below the horizon reads as haze rather
# than as a mirrored or stretched sky.
static func _to_equirect(src_img: Image) -> Image:
	var w := src_img.get_width()
	var h := src_img.get_height()
	if w <= 0 or h <= 0 or w < h * 3:
		return src_img            # already 2:1-ish; leave it alone
	var img := src_img.duplicate() as Image
	if img.is_compressed() and img.decompress() != OK:
		return src_img
	var out := Image.create(w, h * 2, false, img.get_format())
	out.blit_rect(img, Rect2i(0, 0, w, h), Vector2i(0, 0))
	# The horizon row, carried down. Copied as a 1-pixel-tall strip per row
	# rather than pixel by pixel: a 4096-wide sky is 4 million set_pixel calls
	# otherwise, which is seconds of stall for a gradient nobody looks at.
	for y in range(h, h * 2):
		out.blit_rect(img, Rect2i(0, h - 1, w, 1), Vector2i(0, y))
	return out


# ---------------------------------------------------------------------------
# GROUND CLUTTER, from the level's own MeshScatteringDatabase.
#
# The scatter generator was built on the belief that the game does not ship
# scatter data, so it invented a kit list and placed it by reading greenness off
# the map photo. The CATALOGUE is shipped: one resource per level naming the
# MeshSets it strews — pebbles, asphalt chunks, brick rubble, litter, grass
# kits, weeds, shrubs — with a view distance and a ratio for each. 44 records on
# mp_dumbo, every one resolving to a real MeshSet.
#
# WHAT THIS DOES NOT GIVE, and why the placement heuristic stays: where each
# clump goes. The resource answers WHICH and WITH WHAT PARAMETERS, not WHERE.
#
# The records do carry a point list, and it is tempting to read it as the kit
# pattern the scatter wants — it is not claimed to be. Only 6 of the 44 records
# have one, they are all vegetation while hard debris has none, and the values
# sit in a +/-0.5 range. A placement kit would need one per scattered mesh. The
# research lists that array's meaning as open (a bend/wind pivot list is the
# leading guess), so it is carried through unread rather than assumed.
func scatter_entries() -> Array:
	if src == null or walk == null:
		return []
	if not _scatter_cache.is_empty():
		return _scatter_cache
	var name := BF6Scatter.find_res(src, level)
	if name == "":
		return []
	var raw := src.get_res(name)
	if raw.is_empty():
		return []
	var sc := BF6Scatter.new()
	if not sc.parse(raw):
		_say("game source: scatter — %s" % sc.error)
		return []
	if not sc.exact(raw.size()):
		# A variable-length walk that does not land on the last byte has lost
		# sync, and everything after the desync is fiction. Better no clutter
		# than a catalogue of misread names.
		_say("game source: scatter — parse ended at %d of %d bytes, ignoring it"
			% [sc.consumed, raw.size()])
		return []
	var out: Array = []
	for r in sc.records:
		var rec: Dictionary = r
		var res_name := resolve_mesh(str(rec["name"]))
		if res_name == "":
			continue
		var scope := _scope_by_path(res_name)
		var gkey := "%s|%s" % [res_name, scope]
		if not _group_meta.has(gkey):
			_group_meta[gkey] = [res_name, scope, ""]
		out.append({
			"mesh": gkey,
			"name": str(rec["name"]).get_file(),
			"distance": float(rec["distance"]),
			"ratio": float(rec["ratio"]),
		})
	_scatter_cache = out
	_say("game source: scatter — %d clutter mesh(es) of %d in the catalogue"
		% [out.size(), sc.records.size()])
	return out


var _scatter_cache: Array = []


# ---------------------------------------------------------------------------
# PORTAL OBJECTS, assembled from the game's own prefab blueprints.
#
# Every SDK-placeable object has a matching pf_portal_<name>.ebx under
# glacierportal/modbuilder: the authoritative list of member meshes and their
# transforms, often nesting gpf_/pf_/pfls_ sub-prefabs. That is what makes the
# composite objects work — souk houses, wreck tanks, prop-dressed cars, planter
# clusters — which single-mesh name matching can never represent.
#
# THE LEVEL WALK ALREADY DOES THIS. A prefab is the same graph the level is made
# of: ReferenceObjectData with Blueprint and BlueprintTransform, exactly the
# fields BF6Walk reads. Starting it at the prefab with an identity transform
# gives member meshes in the object's own local space, which is what a placed
# overlay wants. Nothing new had to be understood; it only had to be pointed
# somewhere else.
const PORTAL_PREFIX := "pf_portal_"

var _obj_walk: BF6Walk = null
var _obj_cache := {}                   # portal name (lower) -> Mesh-bearing Node3D or null


# The prefab for a Portal object name, assembled, or null.
#
# Returns a fresh Node3D each call: the caller parents it into a scene, and one
# shared instance placed twice is a node with two parents. The expensive part —
# resolving and parsing each member MeshSet — is cached inside mesh_for and
# shared across every placement anyway.
func object_node(portal_name: String) -> Node3D:
	var rows := object_rows(portal_name)
	if rows.is_empty():
		return null
	var root := Node3D.new()
	root.name = portal_name
	for r in rows:
		var row: Dictionary = r
		var m: Mesh = mesh_for(str(row["group"]))
		if m == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.transform = row["xf"] as Transform3D
		root.add_child(mi)
	return root if root.get_child_count() > 0 else null


# [{group, xf}] for one Portal object, cached per name.
func object_rows(portal_name: String) -> Array:
	if walk == null or src == null:
		return []
	var key := portal_name.to_lower()
	if _obj_cache.has(key):
		return _obj_cache[key]

	# pf_portal_<name> first, then the bare name: a few placeables are their own
	# prefab rather than a wrapped one.
	var ref = null
	for cand in [PORTAL_PREFIX + key, key]:
		ref = walk.resolve_name(cand)
		if ref != null:
			break
	if ref == null:
		_obj_cache[key] = []
		return []

	# A SECOND WALKER, sharing the first's catalogue. build_catalog is the
	# expensive part (223k EBX headers) and it is already done; what must not be
	# shared is `rows`, because assembling an object in the middle of a level
	# walk would append members to the map's placement list.
	if _obj_walk == null:
		_obj_walk = BF6Walk.new(src, types)
		_obj_walk.by_name = walk.by_name
		_obj_walk.gi = walk.gi
		_obj_walk.scope_index = walk.scope_index
	_obj_walk.rows.clear()
	_obj_walk.ents.clear()
	_obj_walk.walk(str(ref), BF6Walk.IDENT, {}, 0)

	var out: Array = []
	for r in _obj_walk.rows:
		var row: Dictionary = r
		var res_name := resolve_mesh(str(row["mesh"]))
		if res_name == "":
			continue
		var xf = row["xf"]
		if not (xf is Array) or (xf as Array).size() < 4:
			continue
		var scope := str(row.get("scope", ""))
		if scope == "":
			# A prefab opened on its own has no mounting subworld to inherit a
			# depot scope from — that is a property of being placed in a level,
			# and this one is not. Fall back to directory ancestry, which the
			# scope research measured as recovering a further 7.5% of sections
			# on top of the graph rule.
			scope = _scope_by_path(res_name)
		var b: Array = xf as Array
		var t := Transform3D(
			Basis((b[0] as Vector3), (b[1] as Vector3), (b[2] as Vector3)),
			b[3] as Vector3)
		# Variations count here too: a Portal object placed with a livery is
		# the same case as one placed on the map, and reading only the base
		# key gives it the unvaried paint or nothing at all.
		var vh := _variation_live(scope, _var_hash(row.get("var")), res_name)
		var gk := "%s|%s|%d" % [res_name, scope, vh]
		out.append({"group": gk, "xf": t})
		if not _group_meta.has(gk):
			_group_meta[gk] = [res_name, scope, str(row.get("src", "")), vh]
	_obj_cache[key] = out
	return out


# The nearest bundle that owns a depot, walking UP this asset's directories.
func _scope_by_path(res_name: String) -> String:
	var d := res_name.get_base_dir()
	while d != "" and d != "/":
		# A bundle asset lives at <dir>/<dir name>, which is the key the depot
		# index is built on — matching the bare directory finds nothing.
		var cand := "%s/%s" % [d, d.get_file()]
		if _depot_bundles.has(cand):
			return cand
		if _depot_bundles.has(d):
			return d
		d = d.get_base_dir()
	return ""


# Is there a prefab for this name at all? Cheap: catalogue lookup, no walk.
func has_object(portal_name: String) -> bool:
	if walk == null:
		return false
	var key := portal_name.to_lower()
	if _obj_cache.has(key):
		return not (_obj_cache[key] as Array).is_empty()
	for cand in [PORTAL_PREFIX + key, key]:
		if walk.resolve_name(cand) != null:
			return true
	return false


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
# How much the per-material merge below is actually buying, in draw calls.
var n_sections := 0
var n_surfaces := 0


# djb2-lower of an ObjectVariation asset path, `.ebx` dropped, or 0 for none.
#
# Inlined rather than taken from BF6MVDB: this is the only thing the game path
# wants from that module, and importing it for four lines would make every
# harness that touches materials depend on the whole variation database.
static func _var_hash(ov) -> int:
	if ov == null:
		return 0
	var p := str(ov).trim_suffix(".ebx")
	if p == "":
		return 0
	var h := 5381
	for b in p.to_lower().to_utf8_buffer():
		h = ((h * 33) ^ int(b)) & 0xFFFFFFFF
	return h


# DOES THIS VARIATION CHANGE ANYTHING FOR THIS MESH? -> the hash, or 0.
#
# Splitting the placement groups by variation is what lets a livery be drawn,
# and it is not free: every extra group is another MultiMesh and another draw
# call. Splitting on the raw hash took mp_dumbo from 5,498 groups to 6,431 and,
# in a renderer that is draw-call bound, the frame mean from 13.3 ms to 17.3.
#
# So the split is earned rather than assumed: a variation counts only if THIS
# mesh's own section keys have derived entries in THIS scope's depot.
#
# The per-DEPOT version of this test was tried first — "does the depot hold any
# key that is another key plus this hash" — and recovered 4 groups of 933. It
# is true as soon as any mesh in the bundle uses the variation, which is nearly
# always, so it answers a question no one asked.
#
# Reading the section keys costs no geometry: MeshSet.parse returns the section
# table straight out of the resource, with no CAS chunk and no vertex decode.
var _var_live := {}
var _sec_keys := {}


func _variation_live(scope: String, vh: int, res_name: String) -> int:
	if vh == 0 or res_name == "":
		return 0
	var ck := "%s|%s|%d" % [res_name, scope, vh]
	if _var_live.has(ck):
		return int(_var_live[ck])
	var pair = _depot_for(scope)
	if pair == null:
		_var_live[ck] = 0
		return 0
	var dep: BF6Depot = pair[0]
	var live := 0
	for k in _section_keys(res_name):
		if int(k) != 0 and dep.key_to_record.has(int(k) + vh):
			live = vh
			break
	_var_live[ck] = live
	return live


# ---------------------------------------------------------------------------
# THE PARTS THIS PROP HIDES AT SPAWN - DESTRUCTION.md 4.3's twin-pair rule.
#
#   a part is hidden IFF HealthStateIndex != 0
#   AND an intact (state 0) twin exists for the same PartComponentIndex
#
# The "and" is the whole rule. Culling every non-zero state removes legitimate
# static geometry: plenty of props have parts whose damaged look IS the authored
# look, and those have no state-0 twin. Measured over mp_dumbo's car meshes, 74
# props carry the table with no twin pairs at all and are correctly left intact,
# while 40 have something to hide.
#
# THE TABLE IS ON THE PROP, NOT THE MESH. `X_mesh` is owned by `X` in the same
# folder, and the table is field 0x5B95359C on one of the prop's instances.
#
# SKINNED MESHES ARE EXEMPT (4.4). On a playable vehicle the per-vertex
# BoneIndices value is a SKELETON BONE - a different and differently-sized index
# space; ob_veh_helicopter_ah6m_base has 56 bones against 50 destruction parts.
# Indexing the part table with a bone id is a category error that would cull
# arbitrary pieces of every aircraft.
const F_PHYSICS_PART_INFOS := 0x5B95359C
const F_HEALTH_STATE := 0x97C633FB
const F_PART_COMPONENT := 0x0723904B
const MESHTYPE_SKINNED := 1

var _hidden_cache := {}


func _hidden_parts(res_name: String, info: Dictionary) -> Dictionary:
	if _hidden_cache.has(res_name):
		return _hidden_cache[res_name]
	var out := {}
	if int(info.get("mesh_type", -1)) == MESHTYPE_SKINNED:
		_hidden_cache[res_name] = out
		return out
	# `X_mesh` -> `X`; a mesh whose name does not carry the suffix IS its own
	# prop, which is the same fallback resolve_mesh uses in the other direction.
	var prop := res_name
	if prop.ends_with(MESH_SUFFIX):
		prop = prop.substr(0, prop.length() - MESH_SUFFIX.length())
	var raw := src.get_ebx(prop + ".ebx")
	if raw.is_empty():
		raw = src.get_ebx(prop)
	if raw.is_empty():
		_hidden_cache[res_name] = out
		return out
	var e := BF6Ebx.new(types, walk.gi)
	if not e.parse(raw):
		_hidden_cache[res_name] = out
		return out
	for i in range(e.instance_offsets.size()):
		var inst = e.read_instance(i)
		if not (inst is Dictionary):
			continue
		var t = (inst as Dictionary).get(F_PHYSICS_PART_INFOS)
		if not (t is Array) or (t as Array).is_empty():
			continue
		var rows: Array = t
		var intact := {}
		for r in rows:
			if r is Dictionary and int((r as Dictionary).get(F_HEALTH_STATE, -1)) == 0:
				intact[int((r as Dictionary).get(F_PART_COMPONENT, -1))] = true
		for k in range(rows.size()):
			var rd = rows[k]
			if not (rd is Dictionary):
				continue
			if int((rd as Dictionary).get(F_HEALTH_STATE, 0)) != 0 					and intact.has(int((rd as Dictionary).get(F_PART_COMPONENT, -1))):
				out[k] = true
		break
	if not out.is_empty():
		tex_stats["dest_props"] = int(tex_stats.get("dest_props", 0)) + 1
	_hidden_cache[res_name] = out
	return out


# A mesh's LOD-0 section state keys, from the resource alone.
func _section_keys(res_name: String) -> Array:
	if _sec_keys.has(res_name):
		return _sec_keys[res_name]
	var out: Array = []
	var d := src.get_res(res_name)
	if not d.is_empty():
		var info := _ms.parse(d)
		var lods: Array = info.get("lods", [])
		if not lods.is_empty():
			for s in (lods[0] as Dictionary).get("sections", []):
				out.append(int((s as Dictionary).get("state_key", 0)))
	_sec_keys[res_name] = out
	return out


func mesh_for(group_key: String, lod := 0) -> Mesh:
	var _t0 := Time.get_ticks_usec()
	var res_name := group_key
	var scope := ""
	var var_hash := 0
	if _group_meta.has(group_key):
		var m: Array = _group_meta[group_key]
		res_name = str(m[0])
		scope = str(m[1])
		if m.size() > 3:
			var_hash = int(m[3])
	elif group_key.contains("|"):
		var parts := group_key.split("|")
		res_name = str(parts[0])
		scope = str(parts[1])
		if parts.size() > 2:
			var_hash = int(str(parts[2]))
	if res_name == "":
		return null
	# HAS THIS MESH ALREADY BEEN BUILT WITH THESE MATERIALS?
	#
	# Only askable once some scope has parsed it, because the answer depends on
	# the order its sections merge in — which is why this is a cache lookup and
	# not a rule. Everything here is depot lookups against caches; no CAS read,
	# no parse.
	var kc := "%s#%d" % [res_name, lod]
	var known = _keys_for.get(kc)
	if known is Array:
		var sig := _sig_for(kc, known as Array, scope, var_hash)
		if _mesh_by_sig.has(sig):
			n_mesh_shared += 1
			return _mesh_by_sig[sig]

	# FROM DISK, if this map has been built before on this install. The geometry
	# is the expensive half — 25.6 s of a 50.9 s build against 8.3 s of
	# materials — and it is identical every time until the game is patched, at
	# which point the TOC signature in the directory name changes and the whole
	# cache is orphaned rather than stale.
	#
	# This is a file derived from the player's own install, not a download. The
	# same standard the walk cache and height_game.r16 already meet.
	var cached = _geom_load(kc)
	if cached is ArrayMesh:
		var ckeys := _keys_of(cached as ArrayMesh)
		_keys_for[kc] = ckeys
		_dress(cached as ArrayMesh, ckeys, scope, var_hash)
		_mesh_by_sig[_sig_for(kc, ckeys, scope, var_hash)] = cached
		return cached as ArrayMesh

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

	# ONE SURFACE PER MATERIAL, not one per section.
	#
	# A surface IS a draw call, and this whole overlay is draw-call bound —
	# proven linear at about 2.6 us each, with 60 fps needing roughly 6k against
	# tens of thousands. A MeshSet splits its geometry into sections for the
	# game's own streaming and culling reasons, and several sections of one mesh
	# routinely bind the SAME shader state: emitting a surface each hands Godot
	# a batch it cannot merge and a draw call it did not need.
	#
	# This is the same mistake the download path made and fixed. There the merge
	# key compared material IDENTITY rather than content and the skyline came out
	# at 49,966 surfaces; keying on content took it to 550 and the frame rate
	# from 7.7 to 83 fps. Here identity IS content: material_for caches per
	# (scope, state key) and hands back the same object every time, so the state
	# key is the merge key and no comparison is needed at all.
	#
	# Sections with no material resolved are merged together too, under key 0 —
	# they will all be drawn with Godot's default anyway, so splitting them buys
	# nothing.
	# WHAT THE GAME HIDES AT SPAWN, dropped before anything is merged.
	#
	# A destructible prop's damaged look is built INTO its intact mesh - the
	# deflated tyre, the cracked windscreen, the crushed panel - tagged per
	# vertex and hidden until the piece breaks. Nothing separate is placed, so
	# there is no placement to filter: on mp_dumbo `dc_` rows are 0. Left in, a
	# parked car carries its own wreck inside it, which is what the overlapping
	# geometry was.
	var hidden: Dictionary = _hidden_parts(res_name, info)
	_dress_name = res_name

	var by_mat := {}                # merge key -> [verts, normals, uvs, indices]
	var order: Array = []           # insertion order, so the result is stable
	var want_normals := {}
	var want_uvs := {}
	for s in secs:
		var sec: Dictionary = s
		var verts = sec.get("verts")
		if not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			continue
		var idx = sec.get("indices")
		if not (idx is PackedInt32Array) or (idx as PackedInt32Array).is_empty():
			continue
		var n: int = (verts as PackedVector3Array).size()
		var key := int(sec.get("state_key", 0))
		if not by_mat.has(key):
			by_mat[key] = [PackedVector3Array(), PackedVector3Array(),
				PackedVector2Array(), PackedInt32Array()]
			order.append(key)
			want_normals[key] = true
			want_uvs[key] = true
		# PULLED OUT INTO LOCALS AND WRITTEN BACK, which is not stylistic.
		#
		# A PackedVector3Array is a VALUE in GDScript, so `acc[0].append_array(v)`
		# appends to a temporary copy and throws it away. The first version of
		# this loop did exactly that for the vertices, normals and UVs — only the
		# indices were assigned back — and every merged surface came out with an
		# empty vertex array: "Condition array_len == 0 is true", thousands of
		# times, on a mesh that had just been read correctly.
		var acc: Array = by_mat[key]
		var av: PackedVector3Array = acc[0]
		var an: PackedVector3Array = acc[1]
		var au: PackedVector2Array = acc[2]
		var ai: PackedInt32Array = acc[3]
		var base: int = av.size()
		av.append_array(verts)
		# Length-checked before use: Godot rejects the whole surface if an
		# attribute array disagrees with the vertex count, and a section that
		# carries no normals hands back an empty one rather than nothing. Merged,
		# it is worse than a rejected surface — one section without normals would
		# leave the accumulated array short and silently misalign every section
		# after it. So a group where ANY section lacks an attribute drops that
		# attribute for the whole group.
		var nrm = sec.get("normals")
		if nrm is PackedVector3Array and (nrm as PackedVector3Array).size() == n:
			an.append_array(nrm)
		else:
			want_normals[key] = false
		var uv = sec.get("uvs")
		if uv is PackedVector2Array and (uv as PackedVector2Array).size() == n:
			au.append_array(uv)
		else:
			want_uvs[key] = false
		# PER TRIANGLE, on its first vertex's tag. A triangle spans one
		# destruction part in practice, and requiring all three to be visible
		# would also drop the seam triangles between a hidden part and a visible
		# one - a hole in the intact body rather than a removed overlay.
		var pv: PackedInt32Array = sec.get("parts", PackedInt32Array())
		var ii: PackedInt32Array = idx
		if not hidden.is_empty() and not pv.is_empty():
			for k in range(0, ii.size() - 2, 3):
				var v0 := int(ii[k])
				if v0 < pv.size() and hidden.has(int(pv[v0])):
					continue
				ai.push_back(int(ii[k]) + base)
				ai.push_back(int(ii[k + 1]) + base)
				ai.push_back(int(ii[k + 2]) + base)
		else:
			for i in ii:
				ai.push_back(i + base)
		by_mat[key] = [av, an, au, ai]

	var am := ArrayMesh.new()
	var kept: Array = []
	for key in order:
		var acc: Array = by_mat[key]
		var verts: PackedVector3Array = acc[0]
		if verts.is_empty() or (acc[3] as PackedInt32Array).is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		if bool(want_normals[key]) \
				and (acc[1] as PackedVector3Array).size() == verts.size():
			arr[Mesh.ARRAY_NORMAL] = acc[1]
		if bool(want_uvs[key]) \
				and (acc[2] as PackedVector2Array).size() == verts.size():
			arr[Mesh.ARRAY_TEX_UV] = acc[2]
		arr[Mesh.ARRAY_INDEX] = acc[3]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		# THE MERGE KEY, STORED AS THE SURFACE'S NAME. It is what decides which
		# material this surface takes, it has to survive a round trip through the
		# geometry cache, and a surface name is the one place a Mesh already
		# carries a string per surface. The alternative was a second index file
		# beside every mesh, which is another thing to keep in step and another
		# thing to be missing.
		am.surface_set_name(am.get_surface_count() - 1, str(key))
		# `kept`, not `order`: a key whose sections all dropped out contributes no
		# surface, so recording it would put the surface list and the key list out
		# of step — and _sig_for reads them as parallel.
		kept.append(key)
	n_sections += secs.size()
	n_surfaces += am.get_surface_count()
	# Parse covers everything from the MeshSet header to the finished ArrayMesh
	# — read_lod plus the surface building — with the material time subtracted
	# out, because the materials are interleaved into that loop and counting
	# them twice would make the two halves sum to more than the whole.
	t_parse += (Time.get_ticks_usec() - _t1) - mat_us
	n_meshes += 1
	if am.get_surface_count() == 0:
		return null
	# SAVED BEFORE THE MATERIALS GO ON, which is the whole design of the cache.
	# A geometry-only mesh is the expensive part and the part that is identical
	# in every scope; the materials are 8.3 s against the parse's 25.6 s, they
	# dedup across the map, and saving them would embed the same textures behind
	# thousands of separate files.
	_geom_save(kc, kept, am)
	_dress(am, kept, scope, var_hash)
	# Recorded so the NEXT scope to want this mesh can decide without parsing.
	_keys_for[kc] = kept
	_mesh_by_sig[_sig_for(kc, kept, scope, var_hash)] = am
	return am


# ---------------------------------------------------------------------------
# THE GEOMETRY CACHE.
#
# One .res per (MeshSet, LOD), holding the merged ArrayMesh with its surfaces
# named after their merge keys and NO materials. Keyed by directory on the level
# and the mounted TOCs' signature, so a game patch orphans the whole thing at
# once instead of leaving one stale mesh behind the rest.
#
# Materials are deliberately not in it. They are a third of the cost, they dedup
# hard across the map — 1,192 materials for 5,655 groups — and saving them would
# embed the same textures behind thousands of separate files, turning a ~460 MB
# cache into a multi-gigabyte one.
var geom_cache := true
var _geom_dir := ""
var n_geom_loaded := 0
var n_geom_saved := 0
var t_geom_load := 0
var t_geom_save := 0


func _geom_open() -> void:
	_geom_dir = ""
	if not geom_cache or src == null:
		return
	var sig := src.signature()
	if sig == "":
		return
	# VERSIONED, because this cache holds the RESULT of decisions this reader
	# makes and not just the game's bytes. The TOC signature catches a game patch;
	# it does not catch us starting to cull destruction overlays, and a stale entry
	# would keep serving a car with its crash panels inside it forever. Bump on any
	# change to what the geometry itself contains.
	var d := "user://bf6_geom/%s_%s_g2" % [level, sig]
	if DirAccess.make_dir_recursive_absolute(d) != OK and not DirAccess.dir_exists_absolute(d):
		return
	_geom_dir = d


# md5 of the key, not the key: a MeshSet name is a long path with slashes in it,
# and those are directories rather than characters as far as a file name is
# concerned.
func _geom_path(kc: String) -> String:
	return "%s/%s.res" % [_geom_dir, kc.md5_text()]


func _geom_load(kc: String):
	if _geom_dir == "":
		return null
	var p := _geom_path(kc)
	if not ResourceLoader.exists(p):
		return null
	var t := Time.get_ticks_usec()
	# CACHE_MODE_IGNORE: this reader keeps its own share table (_mesh_by_sig),
	# which is keyed on the materials as well as the mesh. Letting Godot's
	# resource cache hand the same instance to two callers would put a mesh from
	# one scope into another with no way to tell.
	var r = ResourceLoader.load(p, "ArrayMesh", ResourceLoader.CACHE_MODE_IGNORE)
	t_geom_load += Time.get_ticks_usec() - t
	if not (r is ArrayMesh) or (r as ArrayMesh).get_surface_count() == 0:
		return null
	n_geom_loaded += 1
	return r


func _geom_save(kc: String, keys: Array, am: ArrayMesh) -> void:
	if _geom_dir == "" or keys.is_empty():
		return
	var t := Time.get_ticks_usec()
	if ResourceSaver.save(am, _geom_path(kc)) == OK:
		n_geom_saved += 1
	t_geom_save += Time.get_ticks_usec() - t


# The merge keys a cached mesh carries, recovered from its surface names.
func _keys_of(am: ArrayMesh) -> Array:
	var out: Array = []
	for i in range(am.get_surface_count()):
		out.append(int(am.surface_get_name(i)))
	return out


# Put this scope's materials on a mesh whose surfaces are already built.
# EVERY MESH THIS READER HAS DRESSED, so it can dress them again.
#
# The meshes are already in the scene, held by MultiMeshInstance3Ds. Changing a
# material rule and re-running _dress over this list updates what is on screen
# with no node touched, no geometry re-parsed and no rebuild - which is the
# difference between a live iteration loop and restarting the editor.
#
# Weak by nature: entries whose ArrayMesh has been freed are skipped and dropped
# on the next pass, so a scene change does not leak them.
var _dressed: Array = []
# The mesh currently being built, so _dress can record what it dressed without
# every caller having to pass it.
var _dress_name := ""


func _dress(am: ArrayMesh, keys: Array, scope: String, var_hash := 0) -> void:
	if not build_materials:
		return
	_dressed.append([am, keys, scope, var_hash, _dress_name])
	var _t := Time.get_ticks_usec()
	for i in range(mini(keys.size(), am.get_surface_count())):
		var mat = material_for(int(keys[i]), scope, var_hash)
		if mat != null:
			am.surface_set_material(i, mat)
	t_mat += Time.get_ticks_usec() - _t


# ---------------------------------------------------------------------------
# THROW AWAY EVERY DERIVED MATERIAL AND BUILD THEM AGAIN, in place.
#
# What gets dropped is only what OUR CODE decided: the material per state key,
# the share-by-look table, the cutout verdicts, the decoded textures. What does
# NOT get dropped is anything derived from the game - the placement walk, the
# partition index, the parsed geometry - because that is unchanged by a code
# edit and re-reading it costs 85 seconds to learn nothing.
#
# -> {"meshes": n, "surfaces": n, "gone": n, "ms": n}
# ---------------------------------------------------------------------------
# `only` restricts the pass to specific Mesh OBJECTS - the marker loop's "I am
# pointing at this tree, fix that one". Identity rather than name: the meshes are
# reached through the MultiMeshInstance3Ds in the scene, those nodes are not
# named after the resource they draw, and matching a name we would have to invent
# is a guess where an object reference is a fact. Empty means everything, which
# is what an update the user did not author wants.
func invalidate_materials(only: Array = []) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	# A FILTERED pass still clears the shared caches, because the point is to
	# recompute with new code and a cached answer is the old code's. It costs
	# the unfiltered meshes a lazy re-resolve on their next dress, not a wrong
	# material: nothing is written to them here.
	_mat_cache.clear()
	_mat_by_look.clear()
	_mask_cache.clear()
	_mask_cut.clear()
	_tex_cache.clear()
	_hidden_cache.clear()
	_foliage_shader = null
	_road_shader = null
	_road_pal = null
	_road_pal_tried = false
	# Zeroed in place rather than replaced: `tex_stats` is an inferred typed
	# Dictionary, and assigning an untyped literal to it is a runtime error the
	# editor reports at load with no line of ours attached to it.
	for k in tex_stats.keys():
		tex_stats[k] = 0
	var live: Array = []
	var meshes := 0
	var surfaces := 0
	var gone := 0
	for e in _dressed:
		var row: Array = e
		var am = row[0]
		if not is_instance_valid(am):
			gone += 1
			continue
		live.append(row)
		if not only.is_empty() and not only.has(am):
			continue
		meshes += 1
		surfaces += (am as ArrayMesh).get_surface_count()
		_dress_only(am as ArrayMesh, row[1] as Array, str(row[2]), int(row[3]))
	_dressed = live
	return {"meshes": meshes, "surfaces": surfaces, "gone": gone,
		"ms": Time.get_ticks_msec() - t0}


# _dress without the bookkeeping, so re-dressing does not grow the list it is
# iterating.
func _dress_only(am: ArrayMesh, keys: Array, scope: String, var_hash: int) -> void:
	for i in range(mini(keys.size(), am.get_surface_count())):
		var mat = material_for(int(keys[i]), scope, var_hash)
		am.surface_set_material(i, mat)


# What this mesh WOULD look like under `scope`, as a string: the identity of the
# Material each merge key resolves to. Material objects are shared by content
# (see _look_key), so two scopes that dress a mesh the same way produce the same
# signature — which is the whole point, since object identity alone never would.
func _sig_for(kc: String, keys: Array, scope: String, var_hash := 0) -> String:
	if not build_materials:
		return kc
	var parts: Array = [kc, str(var_hash)]
	for k in keys:
		var m = material_for(int(k), scope, var_hash)
		parts.append("0" if m == null else str((m as Material).get_instance_id()))
	return "#".join(PackedStringArray(parts))


# ---------------------------------------------------------------------------
# The material one shader state binds, or null when nothing resolves.
#
# Cached per (scope, key): the depot deduplicates blobs by content — 39,559 keys
# onto 6,319 records — so building one material per SECTION would make thousands
# of identical StandardMaterial3Ds and upload the same pixels behind each.
# ---------------------------------------------------------------------------
func material_for(state_key: int, scope: String, var_hash := 0):
	if state_key == 0:
		tex_stats["no_key"] = int(tex_stats["no_key"]) + 1
		return null
	var ck := "%s|%s|%d" % [scope, BF6Depot.key_hex(state_key), var_hash]
	if _mat_cache.has(ck):
		return _mat_cache[ck]

	var pair = _depot_for(scope)
	if pair == null:
		tex_stats["no_depot"] = int(tex_stats["no_depot"]) + 1
		_mat_cache[ck] = null
		return null
	var dep: BF6Depot = pair[0]

	# THE VARIATION KEY FIRST, THE BASE KEY AS FALLBACK (SHADERS.md §5.2).
	#
	# A placement carrying an ObjectVariation — a livery, a paint, a poster —
	# resolves its material through a DERIVED key:
	#
	#     variationStateKey = sectionStateKey + djb2_lower(ov asset path)
	#
	# It is a genuine 64-bit add, carry included. GDScript's int is signed
	# two's-complement, so `+` produces exactly the bit pattern the depot is
	# keyed on; splitting it into dwords and adding them independently would not.
	#
	# Reading only the base key cost two different things at once, and the second
	# is invisible. 10.6% of this map's placements carry a variation. For 235 of
	# 1,442 distinct (mesh, variation, scope) groups the base key is not in the
	# depot AT ALL — banners, crates, ammo boxes — so those drew with Godot's
	# default material, which is white. The other 1,207 resolved something, so
	# they LOOKED fine, and were being dressed in the unvaried material: the base
	# paint instead of the livery.
	#
	# The hash is over the asset path with `.ebx` DROPPED. Measured against four
	# other spellings over the 235 groups that only a derived key can dress:
	# path-minus-`.ebx` resolved 235/235, every alternative 0/235.
	var used := state_key
	if var_hash != 0:
		if dep.key_to_record.has(state_key + var_hash):
			used = state_key + var_hash
			tex_stats["var_key"] = int(tex_stats.get("var_key", 0)) + 1
		else:
			tex_stats["var_fallback"] = int(tex_stats.get("var_fallback", 0)) + 1
	if not dep.key_to_record.has(used):
		tex_stats["no_key"] = int(tex_stats["no_key"]) + 1
		_mat_cache[ck] = null
		return null
	var slots: Dictionary = dep.textures_for(used, pair[1])
	var consts: Dictionary = slots.get("constants", {})
	slots.erase("constants")

	# ---- GLASS, BY WHAT IT BINDS RATHER THAN WHAT IT IS CALLED ----------
	#
	# BF6 collapsed its surface shaders into one uber-shader, so shader identity
	# cannot tell a window from a wall (SHADERS.md §5, TERRAIN.md §12). The
	# fingerprint is in the parameters:
	#
	#   architecture / prop glass  binds the destruction glass-volume slot
	#                              0xBB245590, or the arch glass tint 0x6BB97444
	#   vehicle glass              binds the glass tint palette 0xA0106346
	#
	# Without this every window in the level draws as an opaque pane in whatever
	# its base colour happens to be — which on this map is near-white, so the
	# buildings read as blank white panels where the glass should be.
	#
	# Checked BEFORE the look-key share, because two states that differ only in
	# being glass must not collapse onto one material.
	var glass_tint = _glass_tint(slots, consts)
	if glass_tint != null:
		var gm := _glass_material(slots, glass_tint as Color)
		_mat_cache[ck] = gm
		tex_stats["glass"] = int(tex_stats.get("glass", 0)) + 1
		tex_stats["materials"] = int(tex_stats["materials"]) + 1
		return gm

	# KEYED ON WHAT IT LOOKS LIKE, not on where it was found.
	#
	# Two subworlds that place the same prop resolve it through two different
	# depots and two different state keys, and 1,174 of the 1,266 meshes placed
	# from several scopes (93%) come back with byte-identical texture sets. Keyed
	# per (scope, key) those became two StandardMaterial3Ds holding the same
	# textures — which is only a little waste on its own, but it also makes the
	# two meshes incomparable, and that is what forces the same geometry to be
	# parsed once per scope. Sharing the material is what lets mesh_for share the
	# mesh.
	#
	# This is the download path's lesson arriving on the game path: there the
	# merge key compared material identity rather than content, and fixing it
	# took the skyline from 49,966 surfaces to 550.
	var look := _look_key(slots)
	if _mat_by_look.has(look):
		var shared = _mat_by_look[look]
		_mat_cache[ck] = shared
		return shared

	# ---- masked? -------------------------------------------------------
	# 52.8% of this map's sections bind the alpha slot and 81% of those bind
	# `t_debug_r`: 64x64, constant 255, a default rather than a mask. Trusting
	# "an alpha slot is bound" would put a scissor and a shader on 1,543 fully
	# opaque sections for nothing.
	#
	# So the test is the CONTENT — a mask has to actually vary — and it is done
	# once per distinct texture. Not the name: `t_debug_r` is recognisable today
	# and a name test is a guess about every other map.
	var mask = _mask_for(slots.get("alpha"))
	if mask != null:
		var fm = _foliage_material(slots, mask, _cut_for(slots.get("alpha")))
		if fm != null:
			_mat_cache[ck] = fm
			_mat_by_look[look] = fm
			tex_stats["masked"] = int(tex_stats.get("masked", 0)) + 1
			tex_stats["materials"] = int(tex_stats["materials"]) + 1
			return fm

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
		_mat_by_look[look] = null
		return null
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[ck] = mat
	_mat_by_look[look] = mat
	tex_stats["materials"] = int(tex_stats["materials"]) + 1
	return mat


# ---------------------------------------------------------------------------
# GLASS: the tint colour if this shader state is glass, else null.
#
# SHADERS.md §5's parameter table:
#   0xBB245590  destruction glass volume slot — the arch/prop glass fingerprint
#   0xA0106346  glass tint palette, float3 x 8; slot 0 is the pane tint and
#               lives at bytes 4..16 of the payload
#   0x6BB97444  architecture glass colour, a linear vec3
#
# Returning a COLOUR rather than a bool because the tint is the difference
# between a window and a windscreen, and both exist on this map.
const C_GLASS_PALETTE := 0xA0106346
const C_GLASS_ARCH := 0x6BB97444


func _glass_tint(slots: Dictionary, consts: Dictionary):
	var tint := Color(0.62, 0.70, 0.72)      # unbound: cool neutral pane
	var is_glass := slots.has("glass_volume")
	# The palette is float3[8] and the pane tint is slot 0, which the spec
	# locates at bytes 4..16 — NOT at 0. Reading from 0 gives the array's
	# leading element count and a black pane.
	var pal = consts.get(C_GLASS_PALETTE)
	if pal is PackedByteArray and (pal as PackedByteArray).size() >= 16:
		var b: PackedByteArray = pal
		tint = Color(b.decode_float(4), b.decode_float(8), b.decode_float(12))
		is_glass = true
	else:
		var arch = consts.get(C_GLASS_ARCH)
		if arch is PackedByteArray and (arch as PackedByteArray).size() >= 12:
			var b2: PackedByteArray = arch
			tint = Color(b2.decode_float(0), b2.decode_float(4), b2.decode_float(8))
			is_glass = true
	if not is_glass:
		return null
	# A tint of zero is a bound-but-unset parameter, not black glass.
	if tint.r + tint.g + tint.b < 0.01:
		tint = Color(0.62, 0.70, 0.72)
	return tint


# Blended, depth-write off, drawn after opaque — the pass TERRAIN.md §12 says
# these belong in. Godot's DEPTH_DRAW_OPAQUE_ONLY is that: the material still
# tests depth, it just does not write it, so panes behind panes stay visible.
func _glass_material(slots: Dictionary, tint: Color) -> Material:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(clampf(tint.r, 0.0, 1.0), clampf(tint.g, 0.0, 1.0),
		clampf(tint.b, 0.0, 1.0), 0.22)
	var alb = _texture_for(slots.get("basecolor"))
	if alb != null:
		m.albedo_texture = alb
	var nrm = _texture_for(slots.get("normal", slots.get("normal_vt")), true)
	if nrm != null:
		m.normal_enabled = true
		m.normal_texture = nrm
	m.roughness = 0.05
	m.metallic = 0.0
	m.metallic_specular = 0.85
	return m


# The three slots the material actually reads, in a fixed order. Deliberately
# NOT every slot the depot binds: two states that differ only in a weathering
# sheet we never sample produce the same StandardMaterial3D, and treating them
# as different would keep the meshes apart for a difference that cannot be seen.
func _look_key(slots: Dictionary) -> String:
	# The mask is part of the look. Two states that share a colour sheet and
	# differ only in their opacity mask are different materials, and folding them
	# together would hand one of them the other's cutout.
	return "%s|%s|%s|%s" % [
		str(slots.get("basecolor_veg", slots.get("basecolor", ""))),
		str(slots.get("normal", slots.get("normal_vt", ""))),
		str(slots.get("emissive", "")),
		str(slots.get("alpha", ""))]


# ---------------------------------------------------------------------------
# THE OPACITY MASK, or null when the slot holds a placeholder.
#
# Returns the ImageTexture only if the texture genuinely varies. A constant
# channel is a default that was bound because the shader has the slot, not
# because anything is cut out.
#
# Measured on a decompressed 32x32 copy: the source is BC4, which cannot be
# sampled directly, and the question ("does this vary at all") survives the
# downscale — a mask with any cutout at all has both light and dark pixels at
# any resolution. Cached per texture, so 90 distinct masks on this map cost 90
# decompressions rather than one per section.
var _mask_cache := {}                  # texture asset name -> bool
var _mask_cut := {}                    # texture asset name -> scissor threshold
var _foliage_shader: Shader = null


func _mask_for(file_guid):
	if file_guid == null or str(file_guid) == "":
		return null
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return null
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	var known = _mask_cache.get(an)
	if known != null and not bool(known):
		return null
	var tex = _texture_for(file_guid, false, MASK_MAX_DIM)
	if tex == null:
		_mask_cache[an] = false
		return null
	if known != null:
		return tex
	var img: Image = (tex as ImageTexture).get_image()
	if img == null:
		_mask_cache[an] = false
		return null
	var shape := mask_shape(img)
	tex_stats["masks_checked"] = int(tex_stats.get("masks_checked", 0)) + 1
	if shape.is_empty():
		# Undecodable: assume it IS a cutout rather than silently drawing a tree
		# as a solid block. A wrong scissor is visible and reportable; a missing
		# one looks exactly like the bug this fixes.
		_mask_cache[an] = true
		return tex
	var clear: float = shape["clear"]
	var is_cut := clear >= CUTOUT_MIN_CLEAR and clear <= CUTOUT_MAX_CLEAR
	_mask_cache[an] = is_cut
	if not is_cut:
		tex_stats["masks_placeholder"] = int(tex_stats.get("masks_placeholder", 0)) + 1
		return null
	# THE CUT ADAPTS TO THE MASK, because they do not share a range. Every leaf
	# atlas measured has 0.0% of its texels above 0.9 — not a sampling artefact,
	# it survives full-resolution sampling — and t_com_decorations_01_a spans
	# 0..178 of 255, i.e. it tops out at 0.70. Meanwhile t_com_treedestroyed_02_a
	# is 53% above 0.9. A fixed 0.5 works for both of those and would erase any
	# mask that happened to top out below it, which is the failure that looks
	# like the object was never built.
	_mask_cut[an] = clampf(shape["max"] * 0.45, 0.12, 0.5)
	return tex


# IS THIS A CUTOUT, OR SOMETHING ELSE LIVING IN THE ALPHA SLOT?
#
# dfanz0r's rule, and the reason for it: "alpha is only honored when it looks
# like a cutout — wear/blend masks stored in alpha channels otherwise punch
# holes in solid surfaces." The slot is not a vegetation slot; it holds
# placeholders, wear masks and real coverage alike.
#
# Measured over this map's 90 distinct alpha textures, the fraction of fully
# clear texels separates them cleanly and both ends are placeholders:
#
#   t_debug_r                            0.0% clear   1,543 bindings
#   t_com_semitruck_unique_01_a          1.3%
#   t_naf_carpet_01_a                    3.6%
#   ...real cutouts, leaves and fences, 20-82%...
#   t_com_fabricsplinter_01_a           82.1%
#   t_debug_black                      100.0% clear       5 bindings
#
# A FULLY CLEAR mask is as much a placeholder as a fully opaque one, and it is
# the more dangerous of the two: honouring it does not draw a solid block, it
# draws nothing at all. Both ends are rejected.
#
# SAMPLED AT FULL RESOLUTION, no resize. Downscaling a leaf atlas to 48x48
# bilinear averaged every antialiased edge into mid-grey and reported an ivy
# sheet as 0.0% opaque — which is not a property of the ivy, it is a property
# of the resize. A stride over the real texels has no such artefact.
# THE LOWER BOUND WAS TOO GENEROUS, and the evidence for that is in the table
# above rather than anywhere new. The measured placeholders sit at 0.0%, 1.3%
# and 3.6% clear; the measured real cutouts start at 20%. A 1% floor accepts all
# three placeholders as cutouts, and dfanz0r's warning is exactly what that
# looks like on screen — "wear/blend masks stored in alpha channels punch holes
# in solid surfaces". 13,796 of this map's state keys bind an alpha slot against
# 708 that bind vegetation, so the great majority of the things this test sees
# are NOT foliage and a permissive test costs them holes.
#
# 10% sits in the gap between 3.6 and 20 with margin on both sides.
const CUTOUT_MIN_CLEAR := 0.10
const CUTOUT_MAX_CLEAR := 0.98
const CUTOUT_SAMPLES := 128
# NULL RESULT: mask resolution does not matter here, so a mask takes the same
# cap as every other texture (-1 = use texture_max_dim).
#
# The first rendered foliage looked lacy and moth-eaten, and the obvious
# explanation was the _a masks being 2048 while everything is capped at 1024 —
# a hard scissor against an under-resolved mask punches exactly that kind of
# hole. Uncapping them changed nothing. Capping them at 512 also changed
# nothing: all three renders are indistinguishable.
#
# The lacy look was the FRAMING. Six plants in one shot puts each at about 40
# pixels, and at that size any leafy silhouette reads as speckle whether the
# cutout is right or wrong. One plant filling the frame shows clean leaf edges
# and a correct compound-leaf shape. The instrument was the bug.
const MASK_MAX_DIM := -1


static func mask_shape(img: Image) -> Dictionary:
	var c := img.duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		return {}
	var w := c.get_width()
	var h := c.get_height()
	if w < 2 or h < 2:
		return {}
	var sx: int = maxi(1, int(w / CUTOUT_SAMPLES))
	var sy: int = maxi(1, int(h / CUTOUT_SAMPLES))
	var clear := 0
	var opaque := 0
	var n := 0
	var hi := 0.0
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var v := c.get_pixel(x, y).r
			n += 1
			hi = maxf(hi, v)
			if v < 0.1:
				clear += 1
			elif v > 0.9:
				opaque += 1
	if n == 0:
		return {}
	return {"clear": float(clear) / float(n), "opaque": float(opaque) / float(n),
		"max": hi, "samples": n}


# A masked material: albedo plus the mask, through the same foliage_wind shader
# the Configure Shaders wind pref already knows how to drive.
#
# Deliberately THAT shader rather than a new one. apply_shader_prefs finds a
# wind material by `shader.resource_path.ends_with("/foliage_wind.gdshader")`,
# so building game-path foliage with it means the existing pref plumbing drives
# it with no new code — and a second near-identical shader is how the two drift.
func _cut_for(file_guid) -> float:
	if file_guid == null:
		return 0.5
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return 0.5
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	return float(_mask_cut.get(an, 0.5))


func _foliage_material(slots: Dictionary, mask, cut: float):
	if _foliage_shader == null:
		var dir := (get_script() as Script).resource_path.get_base_dir()
		var s = load("%s/foliage_wind.gdshader" % dir)
		if not (s is Shader):
			return null
		_foliage_shader = s
	var albedo = _texture_for(slots.get("basecolor_veg", slots.get("basecolor")))
	if albedo == null:
		return null
	var m := ShaderMaterial.new()
	m.shader = _foliage_shader
	m.set_shader_parameter("albedo_tex", albedo)
	m.set_shader_parameter("mask_tex", mask)
	m.set_shader_parameter("use_mask", true)
	m.set_shader_parameter("alpha_cut", cut)
	# WIND ONLY ON VEGETATION, gated per material. basecolor_veg is the game's
	# own vegetation classification — 76 of this map's 352 masked sections. The
	# other 276 are chain link, tarps, hesco barriers and vehicle decals, and a
	# swaying chain-link fence is worse than a still one.
	m.set_shader_parameter("wind_scale", 1.0 if slots.has("basecolor_veg") else 0.0)
	var nrm = _texture_for(slots.get("normal", slots.get("normal_vt")), true)
	if nrm != null:
		m.set_shader_parameter("use_normal", true)
		m.set_shader_parameter("normal_tex", nrm)
	m.set_shader_parameter("roughness_mul", 0.9)
	m.set_shader_parameter("specular_amount", 0.35)
	return m


# `cap` overrides texture_max_dim for this one texture. 0 means "whatever the
# game ships", and the OPACITY MASKS ask for that.
#
# A mask's resolution is the silhouette. Capped at 1024 alongside everything
# else, a 2048 leaf atlas loses exactly the thin structures the cutout is made
# of, and a hard scissor turns each half-covered texel into a hole: rendered,
# the plants came out lacy and moth-eaten rather than leafy. And it is the
# cheapest possible thing to uncap — these are single-channel BC4, half a byte
# per texel, 512 KB for a 2048 sheet against 5.3 MB for the BC7 colour sheet
# beside it, over 26 distinct masks on this map.
func _texture_for(file_guid, is_normal := false, cap := -1):
	if file_guid == null or str(file_guid) == "":
		return null
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return null
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	# The cap is part of the identity: the same asset fetched once capped and
	# once not is two different images, and sharing them would hand whichever
	# arrived second the other's resolution.
	if cap >= 0:
		an = "%s@%d" % [an, cap]
	if _tex_cache.has(an):
		tex_stats["reused"] = int(tex_stats["reused"]) + 1
		return _tex_cache[an]
	var raw := src.get_res(an.get_slice("@", 0) if cap >= 0 else an)
	if raw.is_empty():
		_tex_cache[an] = null
		tex_stats["failed"] = int(tex_stats["failed"]) + 1
		return null
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)),
		texture_max_dim if cap < 0 else cap)
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
