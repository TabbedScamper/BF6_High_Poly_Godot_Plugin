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

# MOUNT EVERY LEVEL'S ARCHIVES, not just this one.
#
# Reading a level needs only that level. The objects a PLAYER places need the
# whole catalogue, because a pf_portal_ prefab lives in the bundles of the levels
# that USE the object. Someone placing a Cairo awning on Dumbo is asking for
# something Dumbo's archives have never heard of.
#
# Measured on this install, mounting mp_dumbo against mounting everything:
#
#            archives   ebx      pf_portal_   SDK objects covered
#   level     18 s      223,185   1,723        1,609 of 10,883  (14.8%)
#   all       85 s      450,884   9,456        8,840 of 10,883  (81.2%)
#
# The cold mount is 85 s instead of 18 s, once per install, cached against the
# archives' signature; warm it is 2.7 s against 0.8 s. In exchange the placeable
# catalogue actually resolves, and it resolves BETTER than the model library this
# replaced, which had 8,303 rows. Of the 2,043 still unmatched, 1,408 are audio
# and fx scenes with no geometry to draw, so real coverage is 93% of the objects
# that have a model at all.
#
# That trade is the whole plugin: it exists to draw the objects you place.
var catalogue_mount := true

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


# THE STAGES OF A READ, in the order they happen, so a caller can draw the whole
# list up front with the ones still to come greyed out rather than discovering
# them one at a time. A cold read is a minute and a half; a list that grows as it
# goes cannot tell you whether you are near the end, and "near the end" is the
# only thing anyone actually wants to know while waiting.
const ST_MOUNT  := "mounting the install"
const ST_TYPES  := "reading type layouts"
const ST_INDEX  := "indexing partitions"
const ST_WALK   := "reading placements"
const ST_GROUND := "reading the ground"
const ST_COLOUR := "the ground: colour map"
const ST_PAL    := "the ground: layer palette"
const ST_SPLAT  := "the ground: blending layers"
const ST_BASE   := "the ground: street materials"
const ST_LAYERS := "the ground: layer textures"

const OPEN_STAGES := [ST_MOUNT, ST_TYPES, ST_INDEX, ST_WALK, ST_GROUND,
	ST_COLOUR, ST_PAL, ST_SPLAT, ST_BASE, ST_LAYERS]

# WHAT THE BUILT GEOMETRY IS. Bumped when a change alters the meshes this reader
# produces: a different cull, a different merge, a corrected winding. NOT bumped
# for anything that only changes how they are dressed, logged or reported.
#
# It has two jobs, and the second is why it is a number rather than the literal
# "g2" that used to be spelled into the cache path:
#
#   1. it versions the on-disk geometry cache, so a stale entry from before the
#      change is never served;
#   2. it is what a live reload asks to decide whether the meshes already in the
#      scene are stale. That used to be answered by which FILE changed, and the
#      file list is far too coarse: adding a progress callback to bf6_walk.gd
#      cannot move a vertex, but bf6_walk.gd is on the geometry list, so the
#      reload told the user to rebuild the whole map. Now "rebuild" is something
#      we state deliberately by bumping this, not a side effect of which file an
#      edit happened to land in.
# 5: surfaces now record which palette entries their vertices select, in the
#    surface name (see the merge loop), so the colour table can be resolved
#    per surface instead of only when all eight entries agree.
const GEOM_EPOCH := 5

# A FUNCTION, not read as a constant from outside, and that is load-bearing.
# GDScript folds a constant into the caller at parse time, so a caller that read
# HighpolyGameSource.GEOM_EPOCH would keep reporting the value it was compiled
# against even after this script is replaced in place. A call cannot be folded,
# so it returns what the CURRENTLY LOADED code says, which is the whole question
# a live reload is asking.
static func geom_epoch() -> int:
	return GEOM_EPOCH

# Everything up to (and including) the placements. Long on a cold run — this is
# the 85 s — so callers should be showing progress while it happens.
#
# `progress` is called as (stage: String, done: int, total: int). A total of 0
# means "done is a running count, not a fraction" — the walk knows how many
# placements it has found but nothing knows how many there will be, and a
# denominator we would have to invent is worse than none.
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
		progress.call(ST_MOUNT, 0, 0)
	if not src.mount(level, func(tocs, paths, _ebx):
			if progress.is_valid():
				progress.call(ST_MOUNT, tocs, paths),
			true, 0, catalogue_mount):
		error = src.last_error()
		return false
	timings["mount"] = Time.get_ticks_msec() - t
	t = Time.get_ticks_msec()

	if progress.is_valid():
		progress.call(ST_TYPES, 0, 0)
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
	walk.build_catalog(func(done, total, _found):
		if progress.is_valid():
			progress.call(ST_INDEX, done, total))
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
		progress.call(ST_WALK, 0, 0)
		walk.progress = func(found: int, _seen: int):
			progress.call(ST_WALK, found, 0)
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
			progress.call(ST_GROUND, 0, 0)
		terrain_surface(surface_cache, false, progress)
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


# EVERYTHING map_data DERIVED, dropped so the next ask is computed by the code
# that is running NOW.
#
# map_data is a cache of answers, not of bytes: where the water is, where the
# roads are, which lights the level has. A live reload replaces the code that
# PRODUCES those answers and cannot replace answers already given, so a fix to
# any of them is invisible until something drops this.
#
# Found the hard way. The water reader looked in one partition and missed the one
# aftermath uses; the fix reached the editor, the user re-toggled Water, and
# nothing happened, because map_data still held the empty answer from before the
# fix. Worse, map_data only sets its "water" key when water is FOUND, so the
# stale entry is an absent key rather than an empty list, and every consumer
# reads it as "this level has no water" rather than "not looked up yet".
#
# Nothing on disk is thrown away: the heightfield, the ground images and the
# geometry cache are all keyed and reused. This is the in-memory summary.
func drop_map_data() -> void:
	_map_data.clear()
	_map_data_key = "￿"
	_water_part = "￿"


# Re-ask ONE question and patch the answer in place, leaving the rest of the
# summary alone.
#
# The whole-summary drop above is correct and unusable on a live map: apply()
# clears the scene before it reloads the data, so anything that goes wrong in the
# rebuild leaves the level torn down, and the rebuild itself is terrain work on
# the main thread inside a toggle handler. This costs one partition parse.
#
# Erasing on empty matters as much as setting on found. map_data only writes the
# key when there IS water, so leaving a stale entry behind would be a level
# showing water it does not have.
func refresh_water() -> void:
	_water_part = "￿"
	_water_look_cache.clear()
	_water_sim_done = false
	_water_sim.clear()
	if _map_data.is_empty():
		return
	var w := water()
	if w.is_empty():
		_map_data.erase("water")
	else:
		_map_data["water"] = w


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
	# SIZED FROM THE TREE, not from a constant. This was 4097, which happened to
	# be what the old download pipeline packaged and was never checked against
	# what the game holds. If a level's deepest height nodes are finer than that,
	# compositing into 4097 threw the difference away and the ground could not be
	# made sharper by any setting, because the loss happened here. Capped at
	# 16385, which is 512 MB of u16 and far past anything observed: a level that
	# asked for more would be a decoding mistake rather than a very detailed map.
	var want := t.native_size()
	if want <= 0:
		want = 4097
	want = clampi(want, 1025, 16385)
	var g := t.composite(want)
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
	# Says the spacing in METRES, which is the number anyone actually wants and
	# the one nothing used to print. "4097x4097" cannot be compared against
	# "the ground looks blocky"; "1.95 m between samples" can.
	_say("game source: terrain %dx%d from %d nodes, %.2f m per sample (tree "
		% [g["size"], g["size"], g["nodes"], (hi.x - lo.x) / maxf(1.0, float(int(g["size"]) - 1))]
		+ "offers %d, node grid %d, border %d), y %.0f..%.0f m"
		% [want, t.xs, t.border, lo.y, hi.y])
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


func terrain_surface(cache_dir: String, force := false,
		progress := Callable()) -> Dictionary:
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
	var tiles := sp.color_tiles(chunks, fetch, func(done: int, total: int):
		if progress.is_valid():
			progress.call(ST_COLOUR, done, total))
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
	if progress.is_valid():
		progress.call(ST_PAL, 0, 0)
	var pidx: Dictionary = walk.gi if walk != null and walk.gi is Dictionary \
		else src.partition_index()
	var pal := BF6TerrainLayers.new()
	if not pal.load(src, level, pidx):
		_say("game source: terrain layers — %s" % pal.error)
		return {}

	# ---- the splat -----------------------------------------------------------
	t0 = Time.get_ticks_msec()
	var comp := sp.composite(chunks, fetch, SURFACE_RES, func(done: int, total: int):
		if progress.is_valid():
			progress.call(ST_SPLAT, done, total))
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
		if progress.is_valid():
			progress.call(ST_BASE, 0, 0)
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
		if progress.is_valid():
			progress.call(ST_LAYERS, s, picked.size())
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
# HOW FAR A ROAD SITS ABOVE THE GROUND, and the game's answer is ZERO.
#
# TERRAIN.md 10.4: decals are drawn "blended, depth-write-off pass after opaque,
# DEPTH-BIASED". A depth bias is a raster-state trick in screen space - the
# geometry stays AT the terrain surface and only its depth comparison is nudged.
# There is no authored height anywhere in the data, because the engine never
# lifts anything.
#
# We have no depth bias, so this is a substitute. It was 15 cm, and that was not
# chosen for comfort either: at 6 cm the median vertex still sat 7 cm proud and
# 5% dipped UNDER the ground. The cause was a mismatch rather than a need - the
# drape sampled the height grid bilinearly at full resolution while the rendered
# terrain is flat triangles spanning `drape_step` texels, so the two surfaces
# genuinely disagree mid-triangle on slopes.
#
# _height_at now evaluates the SAME triangle the terrain mesh draws, so the
# drape lands ON the rendered surface rather than near it and the lift only has
# to cover float precision. 15 cm was tall enough to cut through car tyres.
const ROAD_Y_BIAS := 0.01

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
# Metres per terrain vertex, in texels of the height grid. Set by the map
# context from its own `terrain_step` so the drape and the mesh cannot drift
# apart; 2 is that context's default.
var drape_step := 2


# THE HEIGHT OF THE TERRAIN AS DRAWN, not as stored.
#
# This used to interpolate the full-resolution grid bilinearly, and the rendered
# terrain is not that surface. The mesh takes every `drape_step`-th texel as a
# vertex and fills each quad with two FLAT TRIANGLES, so between vertices the
# two disagree by whatever the height does across a step — on a slope with any
# relief, easily 10 cm. That gap is the whole reason the road had to be lifted
# 15 cm to stop it sinking through the ground.
#
# So sample the same lattice and evaluate the same triangle. The quad is split
# on the ANTI-diagonal — indices go (a, a+1, a+nx) then (a+1, a+nx+1, a+nx) —
# so a point belongs to the first triangle when tx + tz <= 1. Evaluating that
# triangle's plane puts the drape exactly on the surface being drawn, and the
# lift then only has to cover float precision.
func _height_at(x: float, z: float) -> float:
	var res: int = int(_hm["res"])
	var wmin: float = float(_hm["min"])
	var span: float = float(_hm["max"]) - wmin
	if span <= 0.0 or res < 2:
		return 0.0
	var d: PackedByteArray = _hm["data"]
	var st: int = maxi(1, drape_step)
	var fx: float = clampf((x - wmin) / span * (res - 1), 0.0, res - 1.001)
	var fz: float = clampf((z - wmin) / span * (res - 1), 0.0, res - 1.001)
	@warning_ignore("integer_division")
	var x0: int = clampi((int(fx) / st) * st, 0, res - 1 - st)
	@warning_ignore("integer_division")
	var z0: int = clampi((int(fz) / st) * st, 0, res - 1 - st)
	var x1: int = mini(x0 + st, res - 1)
	var z1: int = mini(z0 + st, res - 1)
	var tx: float = clampf((fx - float(x0)) / float(st), 0.0, 1.0)
	var tz: float = clampf((fz - float(z0)) / float(st), 0.0, 1.0)
	var h00 := float(d.decode_u16((z0 * res + x0) * 2))
	var h10 := float(d.decode_u16((z0 * res + x1) * 2))
	var h01 := float(d.decode_u16((z1 * res + x0) * 2))
	var h11 := float(d.decode_u16((z1 * res + x1) * 2))
	var hv: float
	if tx + tz <= 1.0:
		hv = h00 + (h10 - h00) * tx + (h01 - h00) * tz          # (0,0) (1,0) (0,1)
	else:
		hv = h10 + (h11 - h10) * (tx + tz - 1.0) \
			+ (h01 - h10) * (1.0 - tx)                          # (1,0) (1,1) (0,1)
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


# WHICH PARTITION DECLARES THE WATER, found rather than assumed.
#
# This used to read one file: <level>/default. That is where mp_dumbo keeps its
# water surface, and it is not where every level keeps it. mp_aftermath declares
# it in <level>/_layers_content/water, so the read returned nothing, and nothing
# is indistinguishable from "this level has no water" - the level came up dry
# with no error anywhere.
#
# Measured: scanning all 3,521 of aftermath's partitions finds the water type in
# exactly one, and the same scan over dumbo's 1,891 finds it in exactly one. So
# the entity is always somewhere; only its partition varies.
#
# Named candidates first because they cost three parses and cover what we have
# seen, then a full scan because a candidate list is a guess and a scan is an
# answer. Partitions whose name mentions water are tried first within the scan,
# which is a hint about ORDER only: the scan still reaches everything.
var _water_part := "￿"          # "" is a legitimate answer (no water)

func _water_partition() -> String:
	if _water_part != "￿":
		return _water_part
	_water_part = ""
	var lvl := _level_dir()
	for cand in ["%s/default" % lvl, "%s/_layers_content/water" % lvl,
			"%s/default" % level]:
		if src.ebx.has(cand) and _counts_water(str(cand)):
			_water_part = str(cand)
			return _water_part
	var rest: Array = []
	for k in src.ebx.keys():
		var n := str(k)
		if lvl != "" and not n.begins_with(lvl):
			continue
		if n.to_lower().contains("water"):
			if _counts_water(n):
				_water_part = n
				return n
		else:
			rest.append(n)
	for n in rest:
		if _counts_water(str(n)):
			_water_part = str(n)
			return _water_part
	return ""


func _counts_water(name: String) -> bool:
	var raw: PackedByteArray = src.get_ebx(name)
	if raw.is_empty():
		return false
	var e := BF6Ebx.new(types, walk.gi if walk != null else {})
	if not e.parse(raw):
		return false
	for i in range(e.instance_offsets.size()):
		if e.instance_type(i) == WATER_TYPE:
			return true
	return false


func water() -> Array:
	if src == null or types == null:
		return []
	var out: Array = []
	var name := _water_partition()
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
		var row := {"height": ty, "center": [tx, tz],
			"size": [absf(sx), absf(sz)]}
		# THE LOOK, from the same depot chain every other surface uses.
		# Read from the deserialized instance rather than a raw offset: unlike
		# the transform, the state key sits past the fields whose offsets shift
		# between the two water shader variants.
		var inst = e.read_instance(i)
		if inst is Dictionary:
			var look := _water_look(int((inst as Dictionary).get(WATER_STATE_KEY, 0)))
			if not look.is_empty():
				row["look"] = look
		# THE MOTION, from the level's ocean simulation entity. Per LEVEL, not
		# per surface — a level declares one wind, and copying it onto each
		# surface is what lets the whole thing survive placements.json without a
		# second top-level key that a cached load could miss.
		var sim := water_sim()
		if not sim.is_empty():
			row["sim"] = sim
		out.append(row)
	if not out.is_empty():
		var l0: Dictionary = (out[0] as Dictionary).get("look", {})
		_say("game source: water — %d surface(s), first at y %.1f, %.0f x %.0f m%s"
			% [out.size(), float(out[0]["height"]),
			   float((out[0]["size"] as Array)[0]),
			   float((out[0]["size"] as Array)[1]),
			   "" if l0.is_empty() else ", %s shader, %d texture(s)"
					% [str(l0.get("variant", "?")), (l0.get("tex", {}) as Dictionary).size()]])
	return out


# ---------------------------------------------------------------------------
# WHAT THE WATER IS ACTUALLY MADE OF.
#
# WaterSurfaceEntityData carries a u64 in field 0x2E15621F, and that u64 IS a
# ShaderBlockDepot StateKey — so water resolves through exactly the same chain
# as any mesh section (SHADERS.md 3, 5), no special case in the depot at all.
#
# Measured rather than assumed: every 8-byte-aligned u64 in the 0x260-byte
# instance was tested against ALL 16,936 depots the mp_dumbo mount carries.
# Of 47 candidates, exactly ONE key matched in exactly ONE depot
# (42f38eeaac4aa54e in game/glaciermp/levels/mp_dumbo/mp_dumbo) — a single hit
# out of ~800k lookups, which is not something a coincidence produces.
#
# TWO SHADER VARIANTS, and they disagree on almost everything. This is the
# reason a reader must not generalise from one map:
#
#   foam-only  mp_dumbo, mp_aftermath      1 texture,  7 constants
#              t_waterfoam_rgb + two linear float3 water colours
#   full ocean mp_tungsten, mp_eastwood,   3-4 textures, 25-27 constants
#              granite/limestone/outskirts/isolated
#              t_oceanmicrodetail_nsh (the ripple normal), t_oceanfoam_nsh,
#              t_oceannoise, perlin2d, and ONE linear float3 water colour
#
# mp_dumbo's own depots bind the ocean slots ZERO times (checked across every
# depot under the level), so the reduced variant is a real authoring choice for
# the harbour maps and not a resolution miss.
#
# The parameter NAMES are not recoverable — cooked depot parameters are
# machine-generated expression-shader names and no hash construction reproduces
# them (SHADERS.md 3.5). The slot ids below are therefore stable opaque hashes,
# identified by what they bind and by which maps change them.
const WATER_STATE_KEY := 0x2E15621F

const WSLOT_FOAM_RGB := 0x3faa6a0b       # t_waterfoam_rgb   R patches, G bubbles, B crest streaks
const WSLOT_WATER_A := 0x50b54e74        # linear float3, the brighter of the pair
const WSLOT_WATER_B := 0xdfcb439c        # linear float3, the darker of the pair
const WSLOT_FOAM_NSH := 0x60181bbf       # t_oceanfoam_nsh
const WSLOT_DETAIL_NSH := 0x635b5631     # t_oceanmicrodetail_nsh — the ripple normal
const WSLOT_NOISE := 0x18caba16          # t_oceannoise
const WSLOT_PERLIN := 0xf9b82d1e         # perlin2d (128x128 R8, gradient noise)
const WSLOT_OCEAN_COLOR := 0xeaca953a    # linear float3, the ocean variant's water colour

const WSLOT_ROLE := {
	WSLOT_FOAM_RGB: "foam_rgb", WSLOT_FOAM_NSH: "foam_nsh",
	WSLOT_DETAIL_NSH: "detail_nsh", WSLOT_NOISE: "noise", WSLOT_PERLIN: "perlin",
}

var _water_look_cache := {}


# The depot record for one water state key, as {variant, tex, color, scalar}.
#
# SCOPED TO THIS LEVEL'S OWN BUNDLES. A StateKey is only unique within a scope,
# so a global search can bind a colliding key from a parallel level — a
# confidently wrong material, which is worse than none because nothing about it
# looks broken (SHADERS.md 4). The water entity's own partition is a sibling of
# the depot that holds it (aftermath declares water in _layers_content/water and
# the record lives in _layers_content/content), so walking UP from the partition
# does not reach it; the level directory is the narrowest prefix that does.
func _water_look(state_key: int) -> Dictionary:
	if state_key == 0 or src == null or walk == null:
		return {}
	if _water_look_cache.has(state_key):
		return _water_look_cache[state_key]
	var out := {}
	var lvl := _level_dir()
	for scope in _depot_bundles.keys():
		var sn := str(scope)
		if lvl != "" and not sn.begins_with(lvl):
			continue
		var pair = _depot_for(sn)
		if pair == null:
			continue
		var dep: BF6Depot = pair[0]
		if not dep.key_to_record.has(state_key):
			continue
		out = _water_params(dep, pair[1] as PackedByteArray, state_key)
		out["depot"] = sn
		break
	_water_look_cache[state_key] = out
	return out


func _water_params(dep: BF6Depot, d: PackedByteArray, key: int) -> Dictionary:
	var tex := {}          # role -> texture EBX file guid
	var asset := {}        # role -> texture asset name (for logs and reports)
	var color := {}        # "%08x" slot -> [r, g, b] LINEAR
	var scalar := {}       # "%08x" slot -> float
	var other := {}        # "%08x" slot -> [typeHash, raw hex] for non-Float32 inlines
	for p in dep.params(int(dep.key_to_record[key]), d):
		var pd: Dictionary = p
		var n32: int = int(pd["name32"])
		var th: int = int(pd["type_hash"])
		if th == BF6Depot.TH_TEXTURE:
			var refs: Array = pd["refs"]
			if refs.is_empty():
				continue
			var g := str((refs[0] as Array)[1])
			var role := str(WSLOT_ROLE.get(n32, "nh_%08x" % n32))
			tex[role] = g
			var an = walk.gi.get(g)
			if an != null:
				asset[role] = str(an)
		elif th == 0x25f81af1:
			var r3: PackedByteArray = pd["raw"]
			color["%08x" % n32] = [r3.decode_float(0), r3.decode_float(4),
				r3.decode_float(8)]
		elif th == 0x14a0b1c1:
			scalar["%08x" % n32] = (pd["raw"] as PackedByteArray).decode_float(0)
		else:
			# NOT EVERY 4-BYTE CONSTANT IS A Float32. The ocean variant ships at
			# least one under a different type hash, and a reader that only
			# collects 0x14a0b1c1 silently reports one constant fewer than the
			# record holds - which is exactly how a count gets quoted wrong.
			# Kept as raw bytes rather than coerced, since the type is the thing
			# that is not known.
			var rb = pd["raw"]
			if rb != null:
				other["%08x" % n32] = [th, (rb as PackedByteArray).hex_encode()]
	# The variant is named by what it BINDS, the same data-driven rule the glass
	# and carpaint fingerprints use — never by the map or by a texture name.
	var variant := "foam"
	if tex.has("detail_nsh") or tex.has("foam_nsh"):
		variant = "ocean"
	# Normalised colours, so a consumer does not have to know which variant it
	# got. Which of the foam variant's two float3s is shallow and which is deep
	# is NOT settled — see water.gdshader.
	var shallow: Array = []
	var deep: Array = []
	if variant == "ocean":
		# ONE colour, and "deep" is deliberately left absent rather than set to
		# the same value: the consumer's fallback darkens it, and writing the
		# identical colour into both would flatten the depth gradient to nothing
		# while still looking like mined data.
		shallow = color.get("%08x" % WSLOT_OCEAN_COLOR, [])
	else:
		shallow = color.get("%08x" % WSLOT_WATER_A, [])
		deep = color.get("%08x" % WSLOT_WATER_B, [])
	var out := {"variant": variant, "tex": tex, "asset": asset,
		"color": color, "scalar": scalar, "other": other,
		"key": BF6Depot.key_hex(key)}
	if not shallow.is_empty():
		out["shallow"] = shallow
	if not deep.is_empty():
		out["deep"] = deep
	return out


# One of the water textures as a Texture2D, by the file guid _water_look put in
# the look dict. Goes through the ordinary texture path so it gets the same
# cache, the same block compression and the same normal-map handling as every
# other surface; `detail_nsh` and `foam_nsh` carry a normal in RG and are
# tagged as such, because DXT-compressing a normal map bands every ripple.
func water_texture(file_guid, is_normal := false):
	return _texture_for(file_guid, is_normal, 0)


# ---------------------------------------------------------------------------
# WHAT DRIVES THE WAVES: WaterOceanSimulationEntityData.
#
# The depot record above says what the water is MADE of. It says nothing about
# how it MOVES, because the wave field is a runtime GPU simulation and nothing
# on disk holds the result. What IS on disk is the simulation's inputs, on a
# WaterOceanSimulationEntityData in one of the level's *_schematic partitions,
# and those are enough to give the preview the map's own wind direction, its own
# roughness and its own crest sharpness instead of one fixed sine field.
#
# MEASURED ACROSS THE WHOLE GAME (40 instances in 21 partitions, reachable from
# a single mount because the mount carries every level's bundles):
#
#   WindAngle    -0.08 .. 3.00      radians. NOT turns: 1.34 and 3.00 are out of
#                                   a 0..1 range, and the spread sits inside
#                                   -pi..pi. Which world axis 0 points down, and
#                                   the sign, are NOT resolved - see below.
#   WindSpeed     0.01 .. 0.75      NOT metres per second. Every calm MP water
#                                   is 0.01, the windy ones 0.07, and the D-Day
#                                   singleplayer sea 0.30-0.75. Used as a
#                                   normalised roughness with 0.07 as neutral.
#   Choppiness    0.005 .. 3.00     crest sharpness. mp_aftermath 0.02 (glassy),
#                                   mp_tungsten 0.60, sp_invasion 3.00.
#   FoamThreshold 0 .. 290          units unknown; used as a relative cutoff.
#   TileDimension 0.01 .. 128       reported, NOT wired: 0.5 on mp_dumbo against
#                                   128 on a singleplayer sea is not a metre
#                                   count that a wavelength can be read out of.
#
# TWO OR MORE INSTANCES PER LEVEL, one flagged 0x6E8C0B93 and the others clear,
# and what selects between them at runtime is not known. mp_tungsten's single
# instance is CLEAR, so "take the flagged one" alone would leave the one true
# ocean map with no wave data at all. The rule here is: prefer a flagged
# instance, otherwise take the first - stated rather than hidden, because on
# mp_isolated (four instances, two flagged, very different values) it is a
# guess.
const SIM_TYPE := "3ad51130-494f-ee8a-45cd-01103be713ee"
const SIM_ENABLE := 0x6E8C0B93           # named from OceanComponentData.PropertyOverrides
const SIM_WIND_ANGLE := 0x2BD08352
const SIM_WIND_SPEED := 0x8613EBCA
const SIM_CHOPPINESS := 0xD488F0CB
const SIM_WIND_DIST := 0xA1E59641
const SIM_FOAM_ENABLE := 0xF0340815
const SIM_FOAM_THRESHOLD := 0xFFA1D0E2
const SIM_FOAM_MAX := 0xF2C13BDD
const SIM_TILE_DIM := 0x54A5216B
const SIM_MIN_WAVELENGTH := 0x787474E1
const SIM_LARGE_WAVE_RED := 0xC44A1FAF
const SIM_WAVE_THICKNESS := 0xAA2BBED7

# WindDistribution is a SplineCurve (type name hash 0x3A39B4F4), NOT a spectrum
# of float4s. Its members are XValues0..2 (12 slots), YValues0..3 (16 slots),
# GValues0..5 (tangents) and SplineType, which is an ENUM whose values are
# literally 5, 9 and 13 CONTROL POINTS (exe_enum_values.tsv).
#
# The packing, derived and then checked against every instance in the game:
# n control points use the first n-1 X slots with the LAST X implicit at 1.0
# (12 X slots = 13-1), and the first n Y slots. mp_tungsten reads
# X = 0, .092, .182, .362, .489, .662, .784, .900 (+1.0) with n = 9, which is
# ascending and ends exactly where the implicit point would - that is the check.
#
# WHAT THE X AXIS MEANS IS INFERRED, not proved, and the inference is this:
#   * X 0 and X 1 both carry Y ~ 0 on essentially every authored curve, which is
#     the continuity condition of a function on a CIRCLE, not of a spectrum.
#   * the common authored idiom is a single narrow lobe centred at X = 0.5
#     (dsub_sp_nightraid is exactly 0, 0, 1, 0 over 0, .001, .575, .999) -
#     a spreading function peaked on the wind direction.
#   * the two presets of a level are MIRRORS of each other: mp_dumbo's flagged
#     instance is Y = (0, 1.0, 0, 0.4, 0) and its clear one (0, 0.4, 0, 1.0, 0).
#     Mirroring is a direction operation. A wavelength spectrum does not mirror.
# So it is read as ENERGY BY DIRECTION, X mapping the full circle around
# WindAngle. Read the other way (amplitude by wavelength) the same numbers would
# still drive four wave components, just with the roles of the two axes swapped.
#
# GValues are non-zero on 15 of the 40 instances, so the curve is not always
# piecewise linear. It does not matter here: only the control points are used,
# and a control point is where the author put a lobe.
const SIM_CURVE_TYPE := 0xEC989148
const SIM_CURVE_X := [0xA3F9DFEE, 0xAB145027, 0x4FBB37BF]
const SIM_CURVE_Y := [0x57C358C3, 0xE9D446E7, 0xE4DA513E, 0xF324662A]
const SIM_VEC4 := [0x3901DB14, 0x42FC0F5E, 0x32A99B9C, 0x7C8062F2]   # x,y,z,w BY OFFSET

var _water_sim_done := false
var _water_sim := {}


# The open level's ocean simulation inputs, or {} when it declares none.
#
# Small on purpose: every value here rides in placements.json next to the water
# planes, so a cached load with no game mount still gets the map's own wind and
# choppiness. Textures need a mount; numbers do not.
func water_sim() -> Dictionary:
	if _water_sim_done:
		return _water_sim
	_water_sim_done = true
	_water_sim = {}
	if src == null or types == null:
		return _water_sim
	var lvl := _level_dir()
	# Same ORDER-not-scope idiom as _water_partition: the shapes we have seen
	# first (the _layers_content/water_shared ones and mp_granite's water_global
	# both carry "water" in the name, mp_dumbo keeps it in default_schematic),
	# then every other schematic under the level. A candidate list is a guess;
	# the sweep behind it is the answer.
	var named: Array = []
	var rest: Array = []
	for k in src.ebx.keys():
		var n := str(k)
		if lvl != "" and not n.begins_with(lvl):
			continue
		if not n.contains("schematic"):
			continue
		if n.contains("water"):
			named.append(n)
		else:
			rest.append(n)
	named.sort()
	rest.sort()
	rest.push_front("%s/default_schematic" % lvl)
	for n in named + rest:
		var got := _sim_in(str(n))
		if not got.is_empty():
			_water_sim = got
			_say("game source: ocean sim — %s, wind %.2f rad, speed %.3f, chop %.3f, %d wind lobe(s)"
				% [str(n).get_file(), float(got.get("angle", 0.0)),
				   float(got.get("speed", 0.0)), float(got.get("chop", 0.0)),
				   (got.get("dist", []) as Array).size()])
			break
	return _water_sim


func _sim_in(name: String) -> Dictionary:
	var raw: PackedByteArray = src.get_ebx(name)
	if raw.is_empty():
		return {}
	var e := BF6Ebx.new(types, walk.gi if walk != null else {})
	if not e.parse(raw):
		return {}
	var first := {}
	for i in range(e.instance_offsets.size()):
		if e.instance_type(i) != SIM_TYPE:
			continue
		var d = e.read_instance(i)
		if not (d is Dictionary):
			continue
		var row := _sim_row(d as Dictionary, name, i)
		if bool((d as Dictionary).get(SIM_ENABLE, false)):
			return row                     # the flagged one wins outright
		if first.is_empty():
			first = row
	return first


func _sim_row(d: Dictionary, part: String, idx: int) -> Dictionary:
	return {
		"part": part, "index": idx,
		"enabled": bool(d.get(SIM_ENABLE, false)),
		"angle": float(d.get(SIM_WIND_ANGLE, 0.0)),
		"speed": float(d.get(SIM_WIND_SPEED, 0.0)),
		"chop": float(d.get(SIM_CHOPPINESS, 0.0)),
		"foam": bool(d.get(SIM_FOAM_ENABLE, true)),
		"foam_threshold": float(d.get(SIM_FOAM_THRESHOLD, 0.0)),
		"foam_max": float(d.get(SIM_FOAM_MAX, 0.0)),
		"tile": float(d.get(SIM_TILE_DIM, 0.0)),
		"min_wavelength": float(d.get(SIM_MIN_WAVELENGTH, 0.0)),
		"large_wave_reduction": float(d.get(SIM_LARGE_WAVE_RED, 0.0)),
		"wave_thickness": float(d.get(SIM_WAVE_THICKNESS, 1.0)),
		"dist": _sim_curve(d.get(SIM_WIND_DIST, null)),
	}


# WindDistribution's control points as [[x, y], ...], x ascending over 0..1.
func _sim_curve(v) -> Array:
	if not (v is Dictionary):
		return []
	var c: Dictionary = v
	var n := int(c.get(SIM_CURVE_TYPE, 0))
	if n < 2:
		return []
	var xs: Array = _sim_flat(c, SIM_CURVE_X)
	var ys: Array = _sim_flat(c, SIM_CURVE_Y)
	var out: Array = []
	for i in range(n):
		# the last control point's X is implicit at 1.0: 12 X slots hold 13-1
		var x := 1.0
		if i < n - 1 and i < xs.size():
			x = float(xs[i])
		var y: float = float(ys[i]) if i < ys.size() else 0.0
		out.append([snappedf(x, 0.0001), snappedf(y, 0.0001)])
	return out


func _sim_flat(c: Dictionary, members: Array) -> Array:
	var out: Array = []
	for m in members:
		var v = c.get(m, null)
		for comp in SIM_VEC4:
			out.append(float((v as Dictionary).get(comp, 0.0)) if v is Dictionary else 0.0)
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
# One collected entity -> one record of the schema set_map_lights reads, or
# null when it is not a light or is authored off.
#
# Split out of lights() so the placed-object walker can produce the same shape:
# a lamp dropped into a scene and the same lamp standing on the map are the same
# fixture read the same way, and two builders would drift.
func _light_record(ent: Dictionary):
	if str(ent.get("tag", "")) != "light":
		return null
	var tname := str(LIGHT_TYPES.get(str(ent.get("type", "")), ""))
	if tname == "":
		return null
	var f: Dictionary = ent.get("f", {})
	# An explicitly disabled fixture is off in the game and stays off here.
	# Absent means enabled: most lights declare none of the six spellings.
	for h in F_ENABLED:
		if f.has(h) and f[h] == false:
			return null
	if f.get(F_VISIBLE) == false:
		return null
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
		rec["angle"] = float(f.get(F_OUTER_ANGLE, 60.0))
		# A SPOT SHINES ALONG MINUS ITS FORWARD AXIS. Basis row 2 is FORWARD
		# (right/up/forward/translation at 0..3), and the sign is the whole
		# answer: get it backwards and every cone in the map points at the
		# ceiling it is mounted in.
		#
		# MEASURED, not assumed. Read off the fixtures whose real aim is not
		# in doubt: lf_com_potlight_round_01 is a recessed ceiling downlight
		# and its component sits 0.11 m BELOW the fixture origin with forward
		# = (0, +1, 0); lf_com_flushmount_round_01 (-0.13 m) and
		# lf_ind_ceilingled_square_01 (-0.47 m) are the same, and
		# lf_com_streetlight_02 and lf_euu_streetlamp_vintage_01 sit 9.9 m and
		# 7.1 m up their poles with forward = (0, +1, 0). Taking forward as
		# the beam would have every one of them lighting the ceiling or the
		# sky, so the beam is -forward.
		var d: Vector3 = -(xf[2] as Vector3)
		if d.length() > 1e-4:
			rec["dir"] = [d.x, d.y, d.z]
	return rec


func _light_records(ents: Array) -> Array:
	var out: Array = []
	for e in ents:
		if not (e is Dictionary):
			continue
		var rec = _light_record(e)
		if rec != null:
			out.append(rec)
	return out


func lights(cache_dir: String) -> int:
	if walk == null or walk.ents.is_empty():
		return 0
	var out: Array = _light_records(walk.ents)
	var spots := 0
	for r in out:
		if bool((r as Dictionary).get("spot", false)):
			spots += 1
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
var _obj_lights := {}                  # portal name (lower) -> [light record], object-local


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
		_obj_lights[key] = []
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
		# A PLACED PROP'S OWN LIGHTS. This walker was built for meshes and asked
		# for no entities, so a lamp dropped into a scene from the SDK arrived
		# with its geometry and none of its lighting — not misplaced, absent.
		# Collecting them costs the same pass; object_lights() is what reads them
		# and nothing is built unless a caller asks.
		for gd in LIGHT_TYPES:
			_obj_walk.want_types[str(gd)] = "light"
		_obj_walk.want_fields = LIGHT_FIELDS
	_obj_walk.rows.clear()
	_obj_walk.ents.clear()
	_obj_walk.walk(str(ref), BF6Walk.IDENT, {}, 0)
	# Read off the same pass, in the object's own local space, and cached beside
	# the rows: object_rows is memoised, so a later object_lights() call would
	# otherwise be looking at whichever object was assembled most recently.
	_obj_lights[key] = _light_records(_obj_walk.ents)

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
			# and this one is not. Its own bundle is the answer; directory
			# ancestry is the fallback behind it.
			scope = _scope_of(res_name)
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


# The light records a placed Portal object carries, in the object's own local
# space, in the same schema as lights.json.
#
# Not wired into object_node(): whether a scene full of placed lamps should also
# build thousands of Light3D nodes is a budget decision (Forward+ caps clustered
# elements at 512 in view), not something a mesh assembler should decide on its
# own. This is the data, ready for whatever does.
func object_lights(portal_name: String) -> Array:
	var key := portal_name.to_lower()
	if not _obj_lights.has(key):
		object_rows(portal_name)
	var got = _obj_lights.get(key, [])
	return got if got is Array else []


# THE BUNDLE THAT SHIPPED THIS RESOURCE, which is what a depot is keyed on.
#
# Asked first, because it is the answer rather than an approximation of it. A
# ShaderBlockDepot is named <bundle>_win32_shaderstate/shaderblockdepot_<id>, so
# the scope of a mesh opened on its own is simply the bundle it came in.
#
# This is what was missing from every object a player places. Such an object is
# not read as part of a level, so there is no walk above it to inherit a scope
# from, and the directory guess below finds nothing because directories are not
# what depots are keyed on. Measured before this existed: every surface of every
# placed object reported "no ShaderBlockDepot for this scope", and the models
# came out untextured. It was hidden for as long as most placed props were served
# by the downloaded model library, which had its materials baked in.
func _scope_of(res_name: String) -> String:
	if src == null:
		return ""
	var b := str(src.res_bundle.get(res_name, ""))
	if b != "":
		# THE TOC SPELLS A BUNDLE "win32/game/..." AND THE DEPOT SPELLS IT
		# "game/...". Depot resources are named <bundle asset path>_win32_
		# shaderstate/shaderblockdepot_<n> (findings/sbd-scope-is-graph-ancestry),
		# and the asset path has no platform prefix. One token apart, and the
		# lookup misses every time without saying so.
		for cand in [b, b.trim_prefix("win32/")]:
			if _depot_bundles.has(cand):
				return str(cand)
	return _scope_by_path(res_name)


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
# And what the colour-table split costs: meshes built with their surfaces cut by
# palette entry, and meshes that had to be read from the game again because the
# cached copy was merged.
var n_pal_split := 0
var n_pal_rebuilt := 0


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


# ---------------------------------------------------------------------------
# EXPLAIN ONE MESH: everything that decided how it looks.
#
# For the Diagnose Selection tool. When a prop looks wrong the useful question
# is never "is it wrong" - you can see that - it is WHICH LINK in the chain gave
# the answer: the mesh resolved, the scope found a depot, the depot had a record
# for the state key, the record bound an albedo, the alpha slot held something
# that passed the cutout test. Each of those fails differently and they all look
# the same on screen.
#
# -> a Dictionary shaped for printing, never null.
# ---------------------------------------------------------------------------
func describe(am: Mesh) -> Dictionary:
	var out := {"found": false, "mesh": "", "scope": "", "variation": 0,
		"surfaces": []}
	for row in _dressed:
		var r: Array = row
		if r[0] != am:
			continue
		out["found"] = true
		out["mesh"] = str(r[4]) if r.size() > 4 else ""
		out["scope"] = str(r[2])
		out["variation"] = int(r[3])
		var keys: Array = r[1]
		for i in range(keys.size()):
			out["surfaces"].append(describe_state(_mkey(keys[i]), str(r[2]),
				int(r[3]), i, _mpal(keys[i])))
		break
	return out


# One surface's resolution chain, step by step.
func describe_state(state_key: int, scope: String, var_hash: int,
		index := -1, pal := PackedInt32Array()) -> Dictionary:
	var d := {"index": index, "state_key": BF6Depot.key_hex(state_key),
		"depot": "", "key_used": "", "record": false, "slots": {},
		"masked": false, "cut": 0.0, "mask_shape": {}, "material": "none",
		"note": ""}
	if state_key == 0:
		d["note"] = "section carries no shader state key"
		return d
	var pair = _depot_for(scope)
	if pair == null:
		d["note"] = "no ShaderBlockDepot for this scope - nothing can resolve"
		return d
	var dep: BF6Depot = pair[0]
	d["depot"] = "ok"
	var used := state_key
	if var_hash != 0 and dep.key_to_record.has(state_key + var_hash):
		used = state_key + var_hash
		d["key_used"] = "derived (base + variation)"
	elif var_hash != 0:
		d["key_used"] = "base (the variation has no record here)"
	else:
		d["key_used"] = "base"
	if not dep.key_to_record.has(used):
		d["note"] = "the depot has NO RECORD for this key - drawn with Godot's default (white)"
		return d
	d["record"] = true
	var slots: Dictionary = dep.textures_for(used, pair[1])
	var dconsts: Dictionary = slots.get("constants", {})
	slots.erase("constants")
	# WHY THIS PROP IS THE COLOUR IT IS. Most painted props ship a neutral grey
	# texture and take their colour from a constant, so "which textures resolved"
	# on its own answers half the question people actually ask here.
	var dtint = _albedo_tint(dconsts, pal)
	d["tint"] = "identity (neutral, as authored)" if dtint == null \
		else "linear (%.4f, %.4f, %.4f)" % [(dtint as Color).r,
			(dtint as Color).g, (dtint as Color).b]
	# WHICH ENTRY OF THE COLOUR TABLE THIS SURFACE ASKED FOR, which is the
	# difference between "the record has no colour" and "the record has eight and
	# this surface picked one".
	if dconsts.has(C_COLOR_TABLE):
		d["palette"] = "table of 8; this surface selects %s" \
			% ("nothing readable (no usage 0x33 on these vertices)" if pal.is_empty()
				else str(Array(pal)))
	var dcp = _carpaint_of(slots, dconsts)
	if dcp != null:
		var bc: Color = (dcp as Array)[0]
		d["carpaint"] = "body linear (%.4f, %.4f, %.4f), smoothness %.3f" \
			% [bc.r, bc.g, bc.b, float((dcp as Array)[1])]
	for k in slots.keys():
		var guid := str(slots[k])
		var nm = walk.gi.get(guid) if walk != null else null
		d["slots"][str(k)] = str(nm).get_file() if nm != null else guid
	if not (slots.has("basecolor") or slots.has("basecolor_veg")):
		if dcp != null:
			d["note"] = ("carpaint: no albedo sheet by design, the shell's colour "
				+ "is the body constant above")
		else:
			d["note"] = ("record resolves but binds NO albedo - shader-computed "
				+ "material, nothing to sample (drawn white)")
	# the cutout chain, which is what foliage questions are about
	var alpha = slots.get("alpha")
	if alpha != null:
		var an = walk.gi.get(str(alpha)) if walk != null else null
		var akey := str(an).to_lower().trim_suffix(".ebx") if an != null else ""
		var m = _mask_for(alpha)
		d["masked"] = m != null
		d["cut"] = _cut_for(alpha)
		if akey != "" and _mask_cache.has(akey):
			d["mask_shape"] = {"accepted": bool(_mask_cache[akey])}
		if m == null:
			d["note"] += ("  alpha slot bound but REJECTED as a cutout "
				+ "(placeholder or wear mask) - surface drawn opaque")
	var mat = material_for(state_key, scope, var_hash, pal)
	if mat == null:
		d["material"] = "none (white)"
	elif mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		d["material"] = "shader: %s" % (sh.resource_path.get_file()
			if sh != null and sh.resource_path != "" else "inline")
	else:
		d["material"] = "StandardMaterial3D"
	return d


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
		# UNLESS THIS SCOPE NEEDS THE MESH CUT DIFFERENTLY. The cached mesh was
		# merged one surface per shader state, which is the right answer for
		# every mesh whose colour table this scope resolves to a single colour —
		# and 154 groups on mp_dumbo where it is not, because their vertices
		# select two entries that are two different colours. A merged surface
		# cannot be taken apart after the fact, so those are read from the game
		# again and NOT written back (see the save below): they are 2.3% of the
		# groups, and keeping the file on disk merged is what lets every other
		# scope go on sharing it.
		var ckeys := _keys_of(cached as ArrayMesh)
		if not _needs_split(ckeys, scope, var_hash):
			_keys_for[kc] = ckeys
			_dress(cached as ArrayMesh, ckeys, scope, var_hash)
			_mesh_by_sig[_sig_for(kc, ckeys, scope, var_hash)] = cached
			return cached as ArrayMesh
		n_pal_rebuilt += 1

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

	# ---- WHICH COLOUR-TABLE ENTRIES EACH SHADER STATE SELECTS -------------
	#
	# One byte per vertex (usage 0x33, DESTRUCTION.md 9.3) folded down to the SET
	# of entries a merge key's vertices ask for. Two things come out of it: the
	# set is written into the surface name so material_for can resolve the table
	# against it, and where the entries it names are two different colours the
	# surface has to be cut in two, because one surface takes one material.
	#
	# A key is only usable if EVERY section under it could be read: the sections
	# merge into one surface, so one section without a selector would leave the
	# surface claiming entries for vertices that never asked for any. Values
	# above 7 are the same kind of unusable — the table has eight entries, and a
	# 102 is this element meaning something else on that mesh family. Measured on
	# mp_dumbo: no section whose record carries a colour table ever selects
	# outside 0..7.
	var key_sel := {}               # state key -> bitmask of entries selected
	for s in secs:
		var sec: Dictionary = s
		var key := int(sec.get("state_key", 0))
		var verts0 = sec.get("verts")
		var sv: PackedByteArray = sec.get("pal", PackedByteArray())
		var m := int(sec.get("pal_mask", 0))
		if not (verts0 is PackedVector3Array) or sv.is_empty() \
				or sv.size() != (verts0 as PackedVector3Array).size():
			m = 0x100               # this section has no answer, so the key has none
		key_sel[key] = int(key_sel.get(key, 0)) | m
	for k in key_sel.keys():
		if int(key_sel[k]) & 0x100:
			key_sel[k] = 0
	# ...and of those, the ones whose entries are genuinely different colours in
	# THIS scope's depot. Everything else merges exactly as it always did.
	var key_canon := {}             # state key -> entry -> canonical entry
	for key in key_sel.keys():
		var entries := _bits(int(key_sel[key]))
		if entries.size() < 2:
			continue
		var canon = _pal_canon(key, scope, var_hash)
		if canon == null:
			continue
		var gs := {}
		for e in entries:
			gs[int((canon as PackedByteArray)[int(e)])] = true
		if gs.size() > 1:
			key_canon[key] = canon

	var by_mat := {}                # bucket id -> [verts, normals, uvs, indices]
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
		# THE BUCKETS THIS SECTION FEEDS. One, named after the shader state, for
		# every section on the map that is not a split facade; one per colour
		# otherwise. `gk` holds the canonical entry each bucket draws.
		var canon = key_canon.get(key)
		var sv: PackedByteArray = sec.get("pal", PackedByteArray())
		var gk: Array = []
		var bids: Array = []
		if canon != null and sv.size() == n:
			var gs := {}
			for v in sv:
				gs[int((canon as PackedByteArray)[int(v)])] = true
			gk = gs.keys()
			gk.sort()
			for p in gk:
				bids.append("%d@%d" % [key, int(p)])
		else:
			bids.append(str(key))
		var bases := {}
		for bid in bids:
			if not by_mat.has(bid):
				by_mat[bid] = [PackedVector3Array(), PackedVector3Array(),
					PackedVector2Array(), PackedInt32Array()]
				order.append(bid)
				want_normals[bid] = true
				want_uvs[bid] = true
			# PULLED OUT INTO LOCALS AND WRITTEN BACK, which is not stylistic.
			#
			# A PackedVector3Array is a VALUE in GDScript, so `acc[0].append_array(v)`
			# appends to a temporary copy and throws it away. The first version of
			# this loop did exactly that for the vertices, normals and UVs — only the
			# indices were assigned back — and every merged surface came out with an
			# empty vertex array: "Condition array_len == 0 is true", thousands of
			# times, on a mesh that had just been read correctly.
			var acc: Array = by_mat[bid]
			var av: PackedVector3Array = acc[0]
			var an: PackedVector3Array = acc[1]
			var au: PackedVector2Array = acc[2]
			# THE WHOLE SECTION GOES INTO EVERY BUCKET IT FEEDS, and the pieces
			# index into their own copy. Splitting the vertices as well would mean
			# a remap table per piece to buy back the ~500k vertices the 170 split
			# sections on this map duplicate — real memory, but far less than the
			# bug surface of renumbering every index twice.
			bases[bid] = av.size()
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
				want_normals[bid] = false
			var uv = sec.get("uvs")
			if uv is PackedVector2Array and (uv as PackedVector2Array).size() == n:
				au.append_array(uv)
			else:
				want_uvs[bid] = false
			by_mat[bid] = [av, an, au, acc[3]]
		# PER TRIANGLE, on its first vertex's tag. A triangle spans one
		# destruction part in practice, and requiring all three to be visible
		# would also drop the seam triangles between a hidden part and a visible
		# one - a hole in the intact body rather than a removed overlay. The
		# palette entry is read the same way and for the same reason.
		var pv: PackedInt32Array = sec.get("parts", PackedInt32Array())
		var ii: PackedInt32Array = idx
		if bids.size() == 1:
			var bid0: String = bids[0]
			var acc0: Array = by_mat[bid0]
			var ai: PackedInt32Array = acc0[3]
			var base: int = int(bases[bid0])
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
			acc0[3] = ai
			by_mat[bid0] = acc0
		else:
			# ONE PASS PER PIECE rather than one dictionary lookup per triangle:
			# a Packed array taken out of a container is shared, and pushing to it
			# from inside a loop that fetches it again would copy the whole array
			# every triangle.
			var cb: PackedByteArray = canon
			for j in range(bids.size()):
				var bidj: String = bids[j]
				var accj: Array = by_mat[bidj]
				var aij: PackedInt32Array = accj[3]
				var basej: int = int(bases[bidj])
				var pj: int = int(gk[j])
				for k in range(0, ii.size() - 2, 3):
					var v0 := int(ii[k])
					if int(cb[int(sv[v0])]) != pj:
						continue
					if not hidden.is_empty() and not pv.is_empty() \
							and v0 < pv.size() and hidden.has(int(pv[v0])):
						continue
					aij.push_back(v0 + basej)
					aij.push_back(int(ii[k + 1]) + basej)
					aij.push_back(int(ii[k + 2]) + basej)
				accj[3] = aij
				by_mat[bidj] = accj

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
		var sname := _surface_name(str(key), key_sel, key_canon)
		am.surface_set_name(am.get_surface_count() - 1, sname)
		# `kept`, not `order`: a key whose sections all dropped out contributes no
		# surface, so recording it would put the surface list and the key list out
		# of step — and _sig_for reads them as parallel.
		kept.append(sname)
	n_sections += secs.size()
	n_surfaces += am.get_surface_count()
	if not key_canon.is_empty():
		n_pal_split += 1
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
	#
	# NOT SAVED WHEN A PALETTE SPLIT CUT IT, because how it is cut depends on
	# this scope's depot and the file is keyed on the mesh alone. Writing it
	# would hand the next scope a mesh split for someone else's colours; the
	# merged spelling stays on disk and the ~2% of groups that need the split
	# read the game again each session (n_pal_rebuilt).
	if key_canon.is_empty():
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
	# would keep serving a car with its crash panels inside it forever. Bump
	# GEOM_EPOCH on any change to what the geometry itself contains.
	var d := "user://bf6_geom/%s_%s_g%d" % [level, sig, GEOM_EPOCH]
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
#
# Left as STRINGS rather than parsed to ints: a name can carry the palette
# entries the surface selects as well as the state key (see _mkey), and the two
# halves are read by the two helpers rather than by everything downstream.
func _keys_of(am: ArrayMesh) -> Array:
	var out: Array = []
	for i in range(am.get_surface_count()):
		out.append(am.surface_get_name(i))
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
		var mat = material_for(_mkey(keys[i]), scope, var_hash, _mpal(keys[i]))
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
	# The colour-table grouping is derived from a record the same way a material
	# is, so a code edit invalidates it too. It decides how a mesh's surfaces are
	# CUT, though, not just what colour they take: a mesh already in the scene
	# keeps the surfaces it was built with until it is rebuilt.
	_pal_canon_cache.clear()
	_mask_cache.clear()
	_mask_cut.clear()
	_tex_cache.clear()
	_hidden_cache.clear()
	_tint_mask_cache.clear()
	_decal_tex_cache.clear()
	_foliage_shader = null
	_prop_tint_shader = null
	# HELD SHADERS MUST BE DROPPED HERE OR AN EDIT TO ONE NEVER REACHES THE
	# SCREEN. Every shader this file loads is cached in a member and reused, so
	# after a live reload the material is rebuilt around the OLD compiled shader
	# and the user sees their update do nothing. Missing this line is why the
	# decals did not change when decal.gdshader did.
	_decal_shader = null
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
		var mat = material_for(_mkey(keys[i]), scope, var_hash, _mpal(keys[i]))
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
		var m = material_for(_mkey(k), scope, var_hash, _mpal(k))
		# THE SURFACE LAYOUT IS PART OF THE SIGNATURE, not only the materials it
		# ends up with: a mesh built with a palette split has more surfaces than
		# the same mesh built without one, and sharing across that would put a
		# two-surface mesh where a three-surface one belongs.
		parts.append(str(k))
		parts.append("0" if m == null else str((m as Material).get_instance_id()))
	return "#".join(PackedStringArray(parts))


# ---------------------------------------------------------------------------
# The material one shader state binds, or null when nothing resolves.
#
# Cached per (scope, key): the depot deduplicates blobs by content — 39,559 keys
# onto 6,319 records — so building one material per SECTION would make thousands
# of identical StandardMaterial3Ds and upload the same pixels behind each.
# ---------------------------------------------------------------------------
func material_for(state_key: int, scope: String, var_hash := 0,
		pal := PackedInt32Array()):
	if state_key == 0:
		tex_stats["no_key"] = int(tex_stats["no_key"]) + 1
		return null
	# THE PALETTE ENTRIES ARE PART OF THE IDENTITY. Two surfaces of one mesh can
	# share a shader state and select different entries of its colour table —
	# that is the whole point of a per-vertex selector — so caching on the state
	# key alone would hand the second one the first one's colour.
	var ck := "%s|%s|%d|%s" % [scope, BF6Depot.key_hex(state_key), var_hash,
		"" if pal.is_empty() else ",".join(Array(pal).map(func(x): return str(x)))]
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
	# ---- CARPAINT ------------------------------------------------------
	# Before the look-key share for the same reason glass is: a carpaint shell
	# binds no colour sheet, so every one of them would key alike and collapse
	# onto one material regardless of what colour the car is.
	var cp = _carpaint_of(slots, consts)
	if cp != null:
		var cm := StandardMaterial3D.new()
		cm.albedo_color = _srgb_of((cp as Array)[0] as Color)
		var nm2 = _texture_for(slots.get("normal", slots.get("normal_vt")), true)
		if nm2 != null:
			cm.normal_enabled = true
			cm.normal_texture = nm2
		cm.roughness = clampf(1.0 - float((cp as Array)[1]), 0.04, 1.0)
		cm.metallic = 0.0
		cm.metallic_specular = 0.8
		_mat_cache[ck] = cm
		tex_stats["carpaint"] = int(tex_stats.get("carpaint", 0)) + 1
		tex_stats["materials"] = int(tex_stats["materials"]) + 1
		return cm

	# ---- TILE PAINT ----------------------------------------------------
	# Before the look-key share for the third time, and for the third version of
	# the same reason: a tile-painted body binds NO colour sheet, no normal and
	# no mask, so every one of the map's 25 tile-paint records keys alike and all
	# of them would collapse onto whichever material was built first.
	#
	# SHARED BY WHAT IT PAINTS, though, which glass and carpaint above still are
	# not: one bus placed from four subworlds resolves four state keys onto the
	# same two palette entries, and building a material each would be four
	# uploads of one colour.
	var tp = _tilepaint_of(slots, consts, pal)
	if tp != null:
		var tpl := str((tp as Array)[1])
		var tpm = _mat_by_look.get(tpl)
		if tpm == null:
			tpm = (tp as Array)[0]
			_mat_by_look[tpl] = tpm
			tex_stats["materials"] = int(tex_stats["materials"]) + 1
		_mat_cache[ck] = tpm
		tex_stats["tilepaint"] = int(tex_stats.get("tilepaint", 0)) + 1
		return tpm

	var tint = _albedo_tint(consts, pal)
	var look := _look_key(slots, tint)
	if _mat_by_look.has(look):
		var shared = _mat_by_look[look]
		_mat_cache[ck] = shared
		return shared

	# ---- DECALS --------------------------------------------------------
	# Placeable puddles, dirt, road lines and wall staining. They bind their own
	# slot family and none of the named prop slots, so without this every one of
	# them fell through to the plain path, found no basecolor, and was written
	# off as procedural: they drew nothing at all. Shared by look like everything
	# below, because a decal binds real distinct sheets and its look key already
	# separates it from anything else.
	# THE AUTHORED GLOSS IS PART OF THE LOOK. Two decals that bind the same
	# sheets and differ only in it are different materials, and this is the third
	# place in this file where leaving a per-record value out of the key would
	# have handed one record another record's material.
	var dlook := "%s|g%.4f" % [look, _decal_gloss(consts)]
	var dhit = _mat_by_look.get(dlook)
	if dhit != null:
		_mat_cache[ck] = dhit
		return dhit
	var dm = _decal_of(slots, consts)
	if dm != null:
		_mat_cache[ck] = dm
		_mat_by_look[dlook] = dm
		tex_stats["decals"] = int(tex_stats.get("decals", 0)) + 1
		tex_stats["materials"] = int(tex_stats["materials"]) + 1
		return dm

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
		var fm = _foliage_material(slots, mask, _cut_for(slots.get("alpha")), tint)
		if fm != null:
			_mat_cache[ck] = fm
			_mat_by_look[look] = fm
			tex_stats["masked"] = int(tex_stats.get("masked", 0)) + 1
			tex_stats["materials"] = int(tex_stats["materials"]) + 1
			return fm

	# ---- is the paint only on PART of this prop? -----------------------
	# The tint is masked per texel by the `_nmt` alpha (DESTRUCTION.md 9.5), and
	# a StandardMaterial3D can only multiply the whole surface. Taken only where
	# that alpha genuinely varies; prop_tint.gdshader carries the polarity
	# measurement and _tint_mask_for decides what "varies" means.
	if tint is Color:
		var tm = _tint_masked_material(slots, tint as Color)
		if tm != null:
			_mat_cache[ck] = tm
			_mat_by_look[look] = tm
			tex_stats["tint_masked"] = int(tex_stats.get("tint_masked", 0)) + 1
			tex_stats["materials"] = int(tex_stats["materials"]) + 1
			return tm

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
	if tint is Color:
		# Applied UNIFORMLY, which is the honest approximation and not the whole
		# rule: DESTRUCTION.md §9.5 says the albedo tint is masked per texel by
		# the _nmt normal map's alpha, so a part-painted prop gets its paint over
		# its whole surface here. The alternative on the table was to skip the
		# tint entirely, which draws every painted prop in primer grey.
		#
		# Deliberately NOT counted as "something resolved": a record that binds no
		# texture at all is procedural (material-with-no-albedo-is-shader-computed)
		# and a tint alone is not enough to draw it. Letting the tint stand in for
		# an albedo would turn every procedural blockout into a flat coloured slab.
		mat.albedo_color = _srgb_of(tint as Color)
		tex_stats["tinted"] = int(tex_stats.get("tinted", 0)) + 1
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
	# SLOT 0 IS AT VALUE BYTE 0, and this was off by one float.
	#
	# The spec locates the pane tint at "bytes 4..16 of the payload", and the
	# payload it means is `[u32 elementCount][element 0][pad]…`. bf6_depot hands
	# back the VALUE bytes with that count already consumed, so slot 0 starts at
	# 0 and each later slot at 16*k — the 16-byte cbuffer stride with the last
	# element unpadded (124 bytes for float3[8], measured).
	#
	# Reading from 4 returned (g, b, pad): the headlight glass whose real tint is
	# the documented (0.791, 0.856, 0.890) came back as (0.856, 0.890, 0.000),
	# i.e. every pane on the map was drawn a channel to the left and with a zero
	# blue — clear glass rendered yellow, privacy grey rendered olive. Verified
	# on retail bytes: 9b974a3f 8d3b5b3f 65d7633f 00000000.
	var pal = consts.get(C_GLASS_PALETTE)
	if pal is PackedByteArray and (pal as PackedByteArray).size() >= 12:
		var b: PackedByteArray = pal
		tint = Color(b.decode_float(0), b.decode_float(4), b.decode_float(8))
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
	# ENCODED TO sRGB ON THE WAY IN. The depot's tint is linear, and every colour
	# a Godot material takes is a source_color: the engine runs srgb_to_linear on
	# it before the shader sees it (the same conversion foliage_wind.gdshader's
	# `albedo_mul : source_color` gets). Handing over the linear number directly
	# means it is linearised twice, which darkens every pane and drags saturated
	# tints toward black.
	var lin := Color(clampf(tint.r, 0.0, 1.0), clampf(tint.g, 0.0, 1.0),
		clampf(tint.b, 0.0, 1.0))
	m.albedo_color = Color(lin.linear_to_srgb(), 0.22)
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


# ---------------------------------------------------------------------------
# PROP TINT: the constant that colours an otherwise neutral texture.
#
# BF6 authors most painted props ONCE, in grey, and colours them with a shader
# constant. The base _cs sheet of a shipping container decodes to a neutral grey
# (R 163, G 162, B 161, channels correlated 0.99+); the green, the red and the
# orange are four constants in four depot records. A reader that binds textures
# and stops there draws the whole map in primer.
#
# The constants, all LINEAR (SHADERS.md §5.4, DESTRUCTION.md §9.5), and their
# populations over the 7,460 distinct records mp_dumbo's 41 depots hold:
#
#   0x8A369BB2  variant paint     1.0 neutral, used AS the colour   1,934 records
#   0x686A1072  albedo tint       0.5 neutral, x2 = identity        2,095 records
#   0x888A432A  arch layer tint   0.4995 neutral, x2 = identity     1,081 records
#   0xC2BB295A  colour table      eight 0.4995-neutral entries      3,080 records
#
# `alb` and `l2a` are MUTUALLY EXCLUSIVE — 0 of 7,460 records carry both — so
# they are two shader families' name for the same job and the order below is a
# preference, not a blend.
#
# THE PAINT REPLACES THE TINT, it does not multiply with it. Measured on the
# container: across all 19 records with a non-neutral paint, the albedo tint is
# either exactly neutral or the SAME fixed (0.086, 0.159, 0.315) regardless of
# which colour the variant is — it is not the variant's colour, and multiplying
# the two would tint every green container blue.
const C_ALBEDO_TINT := 0x686A1072
const C_PAINT_MUL := 0x8A369BB2
const C_ARCH_LAYER := 0x888A432A
const C_COLOR_TABLE := 0xC2BB295A
const C_CARPAINT_BODY := 0xDD0512FA
const C_CARPAINT_SMOOTH := 0xFE9EDB18
const C_TILEPAINT_A := 0xF1CEE56D
const C_TILEPAINT_B := 0xF1CEE56E
# The neutral values are not all the same number: the albedo tint's is exactly
# 0.5 while the architecture and colour-table families ship 0.499458. One
# tolerance covers both; a strict `== 0.5` would call 3,044 identity records
# tinted and repaint the map for nothing.
const TINT_EPS := 0.004


func _c3(raw, o := 0):
	if not (raw is PackedByteArray):
		return null
	var b: PackedByteArray = raw
	if b.size() < o + 12:
		return null
	return Color(b.decode_float(o), b.decode_float(o + 4), b.decode_float(o + 8))


static func _near(c: Color, v: float) -> bool:
	return absf(c.r - v) < TINT_EPS and absf(c.g - v) < TINT_EPS \
		and absf(c.b - v) < TINT_EPS


# The linear tint this record applies to its albedo, or null for identity.
#
# `pal` is the set of 0xC2BB295A entries the SURFACE BEING DRESSED selects, read
# per vertex off the mesh (usage 0x33) and carried in the surface name. Empty
# means "not known", which is what every caller that has no mesh in front of it
# passes; the table is then only usable when all eight entries agree.
func _albedo_tint(consts: Dictionary, pal := PackedInt32Array()):
	var out = null
	# 1. paint, if it is doing anything. Wins outright.
	var pm = _c3(consts.get(C_PAINT_MUL))
	if pm != null and not _near(pm as Color, 1.0):
		out = pm
	if out == null:
		# 2. the two exclusive per-family tints, each 0.5-ish neutral, x2 = 1.
		var t = _c3(consts.get(C_ALBEDO_TINT))
		if t == null:
			t = _c3(consts.get(C_ARCH_LAYER))
		if t != null and not _near(t as Color, 0.5) and not _near(t as Color, 0.4995):
			out = Color((t as Color).r * 2.0, (t as Color).g * 2.0, (t as Color).b * 2.0)
	if out == null:
		# 3. the eight-entry colour table, over THE ENTRIES THIS SURFACE SELECTS.
		#
		# Which entry a vertex takes is chosen per vertex by vertex element usage
		# 0x33 (SubMaterialIndex, UByte4, lane 0 — DESTRUCTION.md 9.3), and the
		# mesh builder folds that down to the set of entries each surface's
		# vertices actually use. So the question here is not "do all eight agree"
		# but "do the ones this surface uses agree", which is a much weaker thing
		# to ask: a table with eight entries for eight different props is uniform
		# as far as any one surface is concerned.
		#
		# With `pal` empty the old rule stands — all eight must agree — because a
		# caller with no mesh in front of it has nothing to select with, and
		# taking entry 0 for the whole surface would be a guess.
		var tab = consts.get(C_COLOR_TABLE)
		if tab is PackedByteArray and (tab as PackedByteArray).size() >= 124:
			var b: PackedByteArray = tab
			var picks := pal
			if picks.is_empty():
				picks = PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7])
			var e0 = _c3(b, 16 * clampi(int(picks[0]), 0, 7))
			var uniform := true
			for k in picks:
				var ek = _c3(b, 16 * clampi(int(k), 0, 7))
				if ek == null or not (ek as Color).is_equal_approx(e0 as Color):
					uniform = false
					break
			if uniform and not _near(e0 as Color, 0.5) and not _near(e0 as Color, 0.4995):
				out = Color((e0 as Color).r * 2.0, (e0 as Color).g * 2.0,
					(e0 as Color).b * 2.0)
	if out == null:
		return null
	var c: Color = out
	if absf(c.r - 1.0) < TINT_EPS and absf(c.g - 1.0) < TINT_EPS \
			and absf(c.b - 1.0) < TINT_EPS:
		return null
	return c


# A Godot albedo colour from a LINEAR multiplier. Every colour a material takes
# is a source_color and is run through srgb_to_linear before the shader sees it,
# so the linear value has to be encoded on the way in or it is linearised twice.
static func _srgb_of(c: Color) -> Color:
	return Color(clampf(c.r, 0.0, 4.0), clampf(c.g, 0.0, 4.0),
		clampf(c.b, 0.0, 4.0)).linear_to_srgb()


# ---------------------------------------------------------------------------
# WHICH COLOUR TABLE ENTRIES ARE THE SAME COLOUR: entry k -> the lowest entry
# that holds k's colour, or null when this table cannot split anything.
#
# Null on three counts, and each of them saves a surface that would otherwise be
# cut in half for no visible difference:
#
#   the record has no table at all;
#   every entry is neutral, so the table selects between eight identities;
#   every entry is the SAME colour, which _albedo_tint already applies whole.
#
# Grouping by colour rather than by index is what keeps the split honest about
# cost: br_ind_storagewallsmall's sections use three entries that all hold
# (1.68, 1.58, 1.47), and splitting those into three surfaces would triple a
# draw call to draw one colour.
func _table_canon(raw):
	if not (raw is PackedByteArray) or (raw as PackedByteArray).size() < 124:
		return null
	var b: PackedByteArray = raw
	var cols: Array = []
	var any := false
	for k in range(8):
		var c = _c3(b, 16 * k)
		if c == null:
			return null
		if not _near(c as Color, 0.5) and not _near(c as Color, 0.4995):
			any = true
		cols.append(c)
	if not any:
		return null
	var canon := PackedByteArray()
	canon.resize(8)
	var groups := 0
	for k in range(8):
		canon[k] = k
		for j in range(k):
			if (cols[j] as Color).is_equal_approx(cols[k] as Color):
				canon[k] = canon[j]
				break
		if int(canon[k]) == k:
			groups += 1
	if groups < 2:
		return null
	return canon


# The same grouping for the tile-paint pair: two zones are one surface only if
# they agree on BOTH the clean colour and the aged one, since the tilebreaker
# moves every texel between them.
func _pair_canon(raw_a, raw_b):
	if not (raw_a is PackedByteArray) or (raw_a as PackedByteArray).size() < 124:
		return null
	var canon := PackedByteArray()
	canon.resize(8)
	var groups := 0
	for k in range(8):
		canon[k] = k
		var ak = _c3(raw_a, 16 * k)
		var bk = _c3(raw_b, 16 * k)
		if ak == null:
			return null
		for j in range(k):
			var aj = _c3(raw_a, 16 * j)
			var bj = _c3(raw_b, 16 * j)
			if not (ak as Color).is_equal_approx(aj as Color):
				continue
			if (bk == null) != (bj == null):
				continue
			if bk != null and not (bk as Color).is_equal_approx(bj as Color):
				continue
			canon[k] = canon[j]
			break
		if int(canon[k]) == k:
			groups += 1
	if groups < 2:
		return null
	return canon


# The same, for one shader state under one scope: null unless the colour table
# is what decides this record's colour AND its entries disagree.
#
# Everything with a higher claim on the albedo is checked first, because the
# table is the LAST rule in _albedo_tint and a record that has a paint or a
# per-family tint never reaches it — splitting its surface would cost a draw
# call to select between colours nothing reads. Measured on mp_dumbo: 506 of the
# 898 sections whose table disagrees are in exactly that position.
var _pal_canon_cache := {}


func _pal_canon(state_key: int, scope: String, var_hash: int):
	var ck := "%s|%s|%d" % [scope, BF6Depot.key_hex(state_key), var_hash]
	if _pal_canon_cache.has(ck):
		return _pal_canon_cache[ck]
	var out = null
	var pair = _depot_for(scope)
	if pair != null:
		var dep: BF6Depot = pair[0]
		var used := state_key
		if var_hash != 0 and dep.key_to_record.has(state_key + var_hash):
			used = state_key + var_hash
		if dep.key_to_record.has(used):
			var slots: Dictionary = dep.textures_for(used, pair[1])
			var consts: Dictionary = slots.get("constants", {})
			slots.erase("constants")
			if _glass_tint(slots, consts) == null \
					and _carpaint_of(slots, consts) == null:
				# Tile paint first: it is read before the tint chain in
				# material_for, and its zones are absolute colours rather than
				# multipliers, so they group by the (clean, aged) PAIR.
				if consts.has(C_TILEPAINT_A):
					out = _pair_canon(consts.get(C_TILEPAINT_A),
						consts.get(C_TILEPAINT_B))
				elif _albedo_tint(consts) == null:
					out = _table_canon(consts.get(C_COLOR_TABLE))
	_pal_canon_cache[ck] = out
	return out


# Would this surface list have to be cut up to be coloured correctly?
#
# Asked of a mesh that came back from the geometry cache, whose surfaces were
# merged without knowing what any depot holds. A surface whose vertices select
# two entries that are two different colours cannot be dressed in one material,
# and there is no way to recover the split from a merged surface — so the answer
# being yes means this mesh has to be read from the game again.
func _needs_split(keys: Array, scope: String, var_hash: int) -> bool:
	for v in keys:
		var pal := _mpal(v)
		if pal.size() < 2:
			continue
		var canon = _pal_canon(_mkey(v), scope, var_hash)
		if canon == null:
			continue
		var seen := {}
		for e in pal:
			seen[int((canon as PackedByteArray)[clampi(int(e), 0, 7)])] = true
			if seen.size() > 1:
				return true
	return false


# ---------------------------------------------------------------------------
# THE MERGE KEY, which is a shader state key and now sometimes more than that.
#
# Written into the surface name and read back out of it, so it survives the
# geometry cache without a second file beside every mesh. Two spellings:
#
#   "<state key>"            nothing selected, or no selector on this section
#   "<state key>@2,5"        the surface's vertices select colour-table entries
#                            2 and 5 (sorted, no duplicates)
#
# The entry list is a GEOMETRY FACT — it is read off the vertex buffer and says
# nothing about any depot — which is what lets one cached mesh serve every scope
# that places it, exactly as before.
static func _mkey(v) -> int:
	var s := str(v)
	var at := s.find("@")
	return int(s.substr(0, at)) if at >= 0 else int(s)


# The name a finished surface carries: its shader state key, plus the palette
# entries its vertices selected when every section behind it could be read.
#
# `bid` is the bucket the merge loop used — "<key>" or "<key>@<canonical entry>"
# — and the name it produces lists the RAW entries that bucket drew, which is
# what material_for needs: two entries of one colour are one bucket but both
# have to be named, or the record would be asked about an entry the surface does
# not use.
func _surface_name(bid: String, key_sel: Dictionary, key_canon: Dictionary) -> String:
	var at := bid.find("@")
	var key := int(bid.substr(0, at)) if at >= 0 else int(bid)
	var sel := _bits(int(key_sel.get(key, 0)))
	if sel.is_empty():
		return str(key)
	var want: Array = sel
	if at >= 0:
		var piece := int(bid.substr(at + 1))
		var canon: PackedByteArray = key_canon[key]
		want = []
		for e in sel:
			if int(canon[int(e)]) == piece:
				want.append(int(e))
	if want.is_empty():
		return str(key)
	var parts := PackedStringArray()
	for e in want:
		parts.append(str(int(e)))
	return "%d@%s" % [key, ",".join(parts)]


# The entries a selector bitmask names, ascending. Empty when the mask is unset
# or carries the out-of-range bit.
static func _bits(mask: int) -> Array:
	var out: Array = []
	if mask <= 0 or (mask & 0x100) != 0:
		return out
	for k in range(8):
		if mask & (1 << k):
			out.append(k)
	return out


static func _mpal(v) -> PackedInt32Array:
	var out := PackedInt32Array()
	var s := str(v)
	var at := s.find("@")
	if at < 0:
		return out
	for t in s.substr(at + 1).split(",", false):
		out.append(int(t))
	return out


# ---------------------------------------------------------------------------
# CARPAINT, by what the record binds rather than by the prop's name.
#
# DESTRUCTION.md §9.1: flakes normal bound AND no basecolor texture AND no
# tile-paint palette. 132 of mp_dumbo's 7,460 records match, and every one of
# them carries a body colour — which matters because a carpaint record has NO
# albedo texture at all, so before this the shell fell through to Godot's
# default and every car on the map was white.
func _carpaint_of(slots: Dictionary, consts: Dictionary):
	if not slots.has("carpaint_flakes"):
		return null
	if slots.has("basecolor") or slots.has("basecolor_veg"):
		return null
	if consts.has(C_TILEPAINT_A) or consts.has(C_TILEPAINT_B):
		return null
	var body = _c3(consts.get(C_CARPAINT_BODY))
	if body == null:
		return null
	var smooth := 0.5
	var s = consts.get(C_CARPAINT_SMOOTH)
	if s is PackedByteArray and (s as PackedByteArray).size() >= 4:
		smooth = clampf((s as PackedByteArray).decode_float(0), 0.0, 1.0)
	return [body, smooth]


# The three slots the material actually reads, in a fixed order. Deliberately
# NOT every slot the depot binds: two states that differ only in a weathering
# sheet we never sample produce the same StandardMaterial3D, and treating them
# as different would keep the meshes apart for a difference that cannot be seen.
func _look_key(slots: Dictionary, tint = null) -> String:
	# The mask is part of the look. Two states that share a colour sheet and
	# differ only in their opacity mask are different materials, and folding them
	# together would hand one of them the other's cutout.
	#
	# THE TINT IS PART OF THE LOOK TOO, and leaving it out silently undoes the
	# whole tint feature: a variation record is a full copy of the base record
	# with the constants changed, so the green container and the grey one bind
	# byte-identical textures. Keyed on textures alone the second one is handed
	# the first one's material and both come out the same colour.
	# THE DECAL SHEETS ARE PART OF THE LOOK, and this is the same trap the
	# paragraph above describes, one family further on. A decal binds NONE of the
	# four slots below, so without these two every decal on the map produced the
	# identical key and the first material built was handed to all 134 of them -
	# a puddle came back wearing a dirt sheet. Caught by a test that asserted the
	# puddle takes the colourless path and found it had a colour sheet it cannot
	# have.
	var t := "-"
	if tint is Color:
		t = "%.4f,%.4f,%.4f" % [(tint as Color).r, (tint as Color).g,
			(tint as Color).b]
	return "%s|%s|%s|%s|%s|%s|%s" % [
		str(slots.get("basecolor_veg", slots.get("basecolor", ""))),
		str(slots.get("normal", slots.get("normal_vt", ""))),
		str(slots.get("emissive", "")),
		str(slots.get("alpha", "")), t,
		str(slots.get("decal_ca", "")), str(slots.get("decal_nrm", ""))]


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
var _prop_tint_shader: Shader = null


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
	# ACCEPTED ON WHAT IT DOES AT 0.5, not on how much of it is fully clear.
	#
	# The clear-fraction floor was mine and it was wrong in the most damaging
	# place available. t_com_treedestroyed_02_a has only 2.3% of its texels below
	# 0.1 - it is a dense canopy - so a 10% floor REJECTS it, and that is the
	# single most-used vegetation mask on this map: 750 states on dumbo, 1,192 on
	# aftermath. Rejected means drawn opaque, so every one of those trees became
	# a solid block.
	#
	# The pipeline's stricter `opaque > 0.35` rule fails the other way, on the
	# distance-ramp family: those never exceed 0.9 at all, so it would reject 59
	# of the map's 168 masks.
	#
	# What every real mask does and no placeholder does is SEPARATE AT 0.5 - some
	# of it below, some above. t_debug_r is 100% above (constant 255) and
	# t_debug_black 100% below, so the same test that admits both mask families
	# still excludes both placeholders.
	var below: float = shape["below_half"]
	var is_cut := below >= CUTOUT_MIN_CLEAR and below <= CUTOUT_MAX_CLEAR
	_mask_cache[an] = is_cut
	if not is_cut:
		tex_stats["masks_placeholder"] = int(tex_stats.get("masks_placeholder", 0)) + 1
		return null
	# THE CUT IS 0.5, MEASURED — and the adaptive formula that used to be here is
	# what people were seeing as "the cutouts look wrong".
	#
	# It read `clampf(shape.max * 0.45, 0.12, 0.5)`, reasoning that a mask
	# topping out at 0.70 must be scaled to. That had the shape of the data
	# wrong. Across all 168 vegetation mask pairs on this map the alpha-slot R
	# channel comes in two families and BOTH cross 0.5:
	#
	#   109 hard masks            bimodal — t_com_treedestroyed_02_a is 51% in
	#                             the top bucket against 3% in the bottom
	#    59 distance-field ramps  max ~0.698, 0% above 0.98, only 17% inside a
	#                             0.45..0.55 band. A distance ramp around a HARD
	#                             edge, not a soft-opacity gradient.
	#
	# 168 of 168 reach above 0.5 and none vanishes at it. The ramp family is what
	# the old formula mishandled: 0.698 x 0.45 = 0.31, and thresholding a
	# distance field at 0.31 instead of 0.5 dilates every leaf into a blob — 59
	# of the map's 168 masks drawn fat.
	_mask_cut[an] = 0.5
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
# Fractions of the mask BELOW 0.5. A real mask has some of both sides; a
# placeholder is entirely one. 2% admits t_com_treedestroyed_02_a's dense canopy
# (22.6% below) and still excludes a constant sheet.
const CUTOUT_MIN_CLEAR := 0.02
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
	var below := 0
	var n := 0
	var hi := 0.0
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var v := c.get_pixel(x, y).r
			n += 1
			hi = maxf(hi, v)
			# THE SPLIT AT 0.5 is what actually decides whether this is a mask.
			# `clear` and `opaque` are kept because they describe the shape, but
			# neither of them admits both mask families on their own.
			if v < 0.5:
				below += 1
			if v < 0.1:
				clear += 1
			elif v > 0.9:
				opaque += 1
	if n == 0:
		return {}
	return {"clear": float(clear) / float(n), "opaque": float(opaque) / float(n),
		"below_half": float(below) / float(n), "max": hi, "samples": n}


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


func _foliage_material(slots: Dictionary, mask, cut: float, tint = null):
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
	# `albedo_mul` is declared source_color, so it takes the sRGB encoding of the
	# depot's linear tint exactly like a StandardMaterial3D albedo does.
	if tint is Color:
		m.set_shader_parameter("albedo_mul", Color(_srgb_of(tint as Color), 1.0))
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


# ---------------------------------------------------------------------------
# THE PAINT MASK: the `_nmt` sheet when its alpha channel says something.
#
# DESTRUCTION.md 9.5 says the albedo tint is masked per texel by this alpha. On
# mp_dumbo's 1,278 distinct tinted records, behind 360 distinct sheets, that
# alpha is one of three things:
#
#   429 records (131 sheets)  constant 1.0 — paint the whole surface, which is
#                             exactly what the uniform tint already does
#    66 records ( 10 sheets)  constant 0.0 — a whole sheet with nothing to say
#   693 records (219 sheets)  a varying mask, 451 of them crossing 0.5
#
# ONLY THE THIRD GROUP GETS THE SHADER. A constant sheet carries no per-texel
# information, so honouring it would mean deciding on no evidence whether a flat
# 0.0 means "never paint this" or "this sheet does not participate" — and one of
# those answers puts 66 records back in primer grey. The uniform tint they have
# today is right for the 429 and unchanged for the 66.
#
# THE SLOT IS `_nmt` AND ONLY `_nmt`. The other normal slot, `_nmo`
# (0xEC35A74C), has a documented and DIFFERENT alpha — occlusion (SHADERS.md
# 5.4) — and multiplying a tint by an occlusion map would darken every crevice
# in the prop's own colour. No tinted record on this map binds it, so the guard
# costs nothing and states the rule.
var _tint_mask_cache := {}             # texture asset -> bool, does it vary


func _tint_mask_for(file_guid):
	if file_guid == null or str(file_guid) == "":
		return null
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return null
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	var known = _tint_mask_cache.get(an)
	if known != null and not bool(known):
		return null
	# The FULL-SIZE texture is what the material binds — it is the normal map as
	# well, and handing the shader a 128 px copy of that would flatten the prop.
	# The 128 px copy is only the instrument the verdict is read off, and
	# "constant or not" is a question that survives any downscale: a resize
	# cannot invent variation in a flat sheet, and it cannot flatten a mask that
	# has both 0 and 1 in it.
	var tex = _texture_for(file_guid, true)
	if tex == null:
		_tint_mask_cache[an] = false
		return null
	if known != null:
		return tex
	var small = _texture_for(file_guid, true, TINT_MASK_PROBE_DIM)
	# DROPPED FROM THE TEXTURE CACHE AS SOON AS IT HAS ANSWERED. A capped fetch
	# is cached under its own key and would otherwise stay resident for the whole
	# session behind the full-size copy of the same sheet — measured at +407 MB
	# over 331 sheets, which is a lot of video memory to spend on a yes/no.
	_tex_cache.erase("%s@%d" % [an, TINT_MASK_PROBE_DIM])
	var img: Image = (small as ImageTexture).get_image() if small != null else null
	if img == null:
		_tint_mask_cache[an] = false
		return null
	var c := img.duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		_tint_mask_cache[an] = false
		return null
	var w := c.get_width()
	var h := c.get_height()
	if w < 4 or h < 4:
		_tint_mask_cache[an] = false
		return null
	var lo := 2.0
	var hi := -1.0
	for y in range(0, h, maxi(1, int(h / 48))):
		for x in range(0, w, maxi(1, int(w / 48))):
			var a := c.get_pixel(x, y).a
			lo = minf(lo, a)
			hi = maxf(hi, a)
	var varies := (hi - lo) > TINT_MASK_MIN_RANGE
	_tint_mask_cache[an] = varies
	tex_stats["tint_masks_checked"] = int(tex_stats.get("tint_masks_checked", 0)) + 1
	if not varies:
		return null
	return tex


# 2% of the range, the same tolerance the constant/varying split was measured
# with. Below it a sheet is flat to within BC7's own quantisation.
const TINT_MASK_MIN_RANGE := 0.02
const TINT_MASK_PROBE_DIM := 128


# ---------------------------------------------------------------------------
# PLACEABLE MESH DECALS: puddles, dirt, road lines, wall staining.
#
# They bind a slot family of their own and NONE of the named prop slots, so this
# reader resolved nothing for them and every one drew untextured. See
# decal.gdshader for the channel packing and how the two decal families are told
# apart; here is only which sheets are real.
#
# THE PLACEHOLDERS ARE REJECTED ON CONTENT, NOT ON THEIR NAMES. t_grey, t_grid,
# t_debug_r and t_base_n are recognisable today and a name test is a guess about
# every map nobody has opened. A defaulted sheet is flat, and flat is measurable.
# This is the same rule the alpha slot already follows.
var _decal_tex_cache := {}             # texture asset -> bool, does it vary


func _decal_sheet(file_guid, is_normal: bool):
	if file_guid == null or str(file_guid) == "":
		return null
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return null
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	var known = _decal_tex_cache.get(an)
	if known != null and not bool(known):
		return null
	var tex = _texture_for(file_guid, is_normal)
	if tex == null:
		_decal_tex_cache[an] = false
		return null
	if known != null:
		return tex
	# Same instrument as the tint mask: a small copy answers "flat or not", and
	# is dropped from the cache immediately so a probe does not keep a second
	# copy of every decal sheet resident for the session.
	var small = _texture_for(file_guid, is_normal, TINT_MASK_PROBE_DIM)
	_tex_cache.erase("%s@%d" % [an, TINT_MASK_PROBE_DIM])
	var img: Image = (small as ImageTexture).get_image() if small != null else null
	if img == null:
		_decal_tex_cache[an] = false
		return null
	var c := img.duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		_decal_tex_cache[an] = false
		return null
	var w := c.get_width()
	var h := c.get_height()
	if w < 4 or h < 4:
		_decal_tex_cache[an] = false
		return null
	var lo := [2.0, 2.0, 2.0, 2.0]
	var hi := [-1.0, -1.0, -1.0, -1.0]
	for y in range(0, h, maxi(1, int(h / 48))):
		for x in range(0, w, maxi(1, int(w / 48))):
			var p := c.get_pixel(x, y)
			var v := [p.r, p.g, p.b, p.a]
			for i in range(4):
				lo[i] = minf(lo[i], float(v[i]))
				hi[i] = maxf(hi[i], float(v[i]))
	var varies := false
	for i in range(4):
		if hi[i] - lo[i] > TINT_MASK_MIN_RANGE:
			varies = true
			break
	_decal_tex_cache[an] = varies
	tex_stats["decal_sheets_checked"] = int(tex_stats.get("decal_sheets_checked", 0)) + 1
	return tex if varies else null


var _decal_shader = null

# THE DECAL'S OWN GLOSS SCALE, and the only per-decal number in the record worth
# reading. Surveyed over all 134 of mp_dumbo's resolvable decals: of ~40
# constants in the block, exactly THREE take more than one value map-wide, and
# only this one separates the families:
#
#   0x47A7C17C   wet (binds no real colour sheet)  1.000 on 20 of 20
#                dry                               0.500 dominant, avg 0.538
#   0xE0C2F8EC   wet 1.000 on 20 of 20, dry avg 0.970 - varies, but does not
#                split wet from dry, so it is not this and is left unread
#   0x33FC54D3   0.500 on effectively everything - a neutral, carries nothing
#
# Read as a MULTIPLIER on the sheet's own smoothness rather than as a floor: the
# sheet already carries per-texel smoothness, and 0.5 on dirt then means "half as
# glossy as painted", which is what dirt should be. It is not in the research
# corpus under any name, so this reading is ours and is marked probable, not
# verified. PROBABLE is why there is a fallback: a decal with no such constant
# keeps the sheet unscaled rather than being forced to a guess.
const C_DECAL_GLOSS := 0x47A7C17C


func _decal_gloss(consts: Dictionary) -> float:
	var raw = consts.get(C_DECAL_GLOSS)
	if not (raw is PackedByteArray) or (raw as PackedByteArray).size() < 4:
		return 1.0
	return clampf((raw as PackedByteArray).decode_float(0), 0.0, 1.0)


# The decal material, or null when this record is not one.
func _decal_of(slots: Dictionary, consts: Dictionary = {}):
	if not (slots.has("decal_ca") or slots.has("decal_nrm")):
		return null
	# THE NORMAL SHEET IS LOADED AS A COLOUR TEXTURE, DELIBERATELY.
	#
	# is_normal makes _texture_for compress with COMPRESS_SOURCE_NORMAL, which
	# keeps two channels and throws B and A away - and on this family B and A are
	# the smoothness and the COVERAGE. Asking for the normal-map format therefore
	# deleted the puddle's transparency and its shine in one go, and it drew as
	# flat opaque grey. The shader reconstructs Z from RG anyway, so the
	# normal-map format buys nothing here and costs the two channels that matter.
	var ca = _decal_sheet(slots.get("decal_ca"), false)
	var nrm = _decal_sheet(slots.get("decal_nrm"), false)
	if ca == null and nrm == null:
		# Every sheet defaulted. Nothing to draw, and drawing the placeholders
		# would put a debug grid or a red field on the map.
		return null
	if _decal_shader == null:
		var dir := (get_script() as Script).resource_path.get_base_dir()
		var s = load("%s/decal.gdshader" % dir)
		if not (s is Shader):
			return null
		_decal_shader = s
	var m := ShaderMaterial.new()
	m.shader = _decal_shader
	m.set_shader_parameter("gloss_scale", _decal_gloss(consts))
	m.set_shader_parameter("has_col", ca != null)
	m.set_shader_parameter("has_nrm", nrm != null)
	if ca != null:
		m.set_shader_parameter("col_tex", ca)
	if nrm != null:
		m.set_shader_parameter("nrm_tex", nrm)
	# Transparent, so it has to sort after the opaque surface it marks.
	m.render_priority = 1
	return m


# The masked-tint material, or null when this record wants the plain one.
func _tint_masked_material(slots: Dictionary, tint: Color):
	var nrm_guid = slots.get("normal_vt")
	if nrm_guid == null:
		return null
	var albedo = _texture_for(slots.get("basecolor_veg", slots.get("basecolor")))
	if albedo == null:
		# A record with no colour sheet is procedural and draws nothing here
		# either way; the plain path is where that decision lives.
		return null
	var mask = _tint_mask_for(nrm_guid)
	if mask == null:
		return null
	if _prop_tint_shader == null:
		var dir := (get_script() as Script).resource_path.get_base_dir()
		var s = load("%s/prop_tint.gdshader" % dir)
		if not (s is Shader):
			return null
		_prop_tint_shader = s
	var m := ShaderMaterial.new()
	m.shader = _prop_tint_shader
	m.set_shader_parameter("albedo_tex", albedo)
	m.set_shader_parameter("normal_tex", mask)
	m.set_shader_parameter("use_normal", true)
	m.set_shader_parameter("use_paint_mask", true)
	# LINEAR, straight through. The shader's uniform is a plain vec3 for exactly
	# this reason (see the note there): the depot's number is a multiplier that
	# reaches 1.92, and a source_color Color would both clamp it and linearise it
	# a second time.
	m.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	var emis = _texture_for(slots.get("emissive"))
	if emis != null:
		m.set_shader_parameter("emission_tex", emis)
		m.set_shader_parameter("use_emission", true)
	return m


# ---------------------------------------------------------------------------
# TILE PAINT: the bus, the semi trailer and the delivery van.
#
# 25 distinct records on mp_dumbo, 81 surfaces on the built map, and every one
# of those 81 draws today with NO MATERIAL AT ALL — Godot's default white — for
# a reason that is correct as far as it goes: the record binds no basecolour
# sheet, so the "a record with no albedo is shader-computed" rule declines to
# invent one. What it computes is a paint, and the paint is right here:
#
#   0xF1CEE56D  palette A, eight float3 entries, the clean colour per zone
#   0xF1CEE56E  palette B, the same eight aged/charred
#   0x851A1207  the tilebreaker sheet, greyscale, the lerp between them
#   0x98D18DE2  its UV tiling (3.0 or 4.0 on this map's records)
#   usage 0x33  the zone, per vertex, resolved into `pal` upstream
#
# Both palettes are ABSOLUTE COLOURS, not multipliers: there is no x2 and no
# neutral here, and treating them like the 0.5-neutral tints would halve every
# bus on the map.
#
# THE UV SCALE IS THE ONE GUESS. impl/notes/material-recipes.md reads
# 0x98D18DE2 as the tilebreaker's tiling and marks that unconfirmed; the recipe
# either side of it — two palettes lerped by that sheet's red channel — is the
# most strongly evidenced thing in that document, fitted numerically against
# in-game photographs of the bus. Getting the scale wrong changes how coarse the
# weathering reads and nothing else: every texel still lands between two colours
# the artist authored for this vehicle, which is why this is worth drawing and
# white is not.
const C_TILE_UV := 0x98D18DE2


func _tilepaint_of(slots: Dictionary, consts: Dictionary, pal: PackedInt32Array):
	if not consts.has(C_TILEPAINT_A):
		return null
	# The zone. With no selector on these vertices there is nothing to choose
	# with, and entry 0 is the body colour on all 25 of this map's records — the
	# only reading that is ever right by construction rather than by luck.
	var zone := 0
	if not pal.is_empty():
		zone = clampi(int(pal[0]), 0, 7)
	else:
		tex_stats["tilepaint_zone0"] = int(tex_stats.get("tilepaint_zone0", 0)) + 1
	var a = _c3(consts.get(C_TILEPAINT_A), 16 * zone)
	if a == null:
		return null
	var b = _c3(consts.get(C_TILEPAINT_B), 16 * zone)
	if b == null:
		b = a
	if _prop_tint_shader == null:
		var dir := (get_script() as Script).resource_path.get_base_dir()
		var s = load("%s/prop_tint.gdshader" % dir)
		if not (s is Shader):
			return null
		_prop_tint_shader = s
	var m := ShaderMaterial.new()
	m.shader = _prop_tint_shader
	m.set_shader_parameter("tint", Vector3((a as Color).r, (a as Color).g, (a as Color).b))
	m.set_shader_parameter("tint_b", Vector3((b as Color).r, (b as Color).g, (b as Color).b))
	# None of mp_dumbo's 25 tile-paint records binds a colour sheet — the paint
	# IS the colour — but the shader multiplies by one and a record on another
	# map that carries both should get both rather than have its sheet dropped.
	var alb = _texture_for(slots.get("basecolor_veg", slots.get("basecolor")))
	if alb != null:
		m.set_shader_parameter("albedo_tex", alb)
	var tb = _texture_for(slots.get("tilebreaker"))
	if tb != null:
		m.set_shader_parameter("breaker_tex", tb)
		m.set_shader_parameter("use_breaker", true)
		var uv = consts.get(C_TILE_UV)
		var sc := 1.0
		if uv is PackedByteArray and (uv as PackedByteArray).size() >= 4:
			sc = (uv as PackedByteArray).decode_float(0)
		m.set_shader_parameter("breaker_scale", clampf(sc, 0.01, 64.0))
	var nrm = _texture_for(slots.get("normal_vt", slots.get("normal")), true)
	if nrm != null:
		m.set_shader_parameter("normal_tex", nrm)
		# NOT as a paint mask. The mask branch multiplies the tint by this
		# sheet's alpha, and a tile-painted body's colour is not masked by
		# anything — it is the tilebreaker's job to vary it.
		m.set_shader_parameter("use_normal", true)
	# The two colours and the sheet ARE the material; the state key is not.
	return [m, "tp|%.4f,%.4f,%.4f|%.4f,%.4f,%.4f|%s|%s|%s" % [
		(a as Color).r, (a as Color).g, (a as Color).b,
		(b as Color).r, (b as Color).g, (b as Color).b,
		str(slots.get("tilebreaker", "")), str(slots.get("normal_vt", "")),
		str(slots.get("basecolor_veg", slots.get("basecolor", "")))]]


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
	# MIPMAPS, which nothing on this path ever generated.
	#
	# Every sampler in foliage_wind.gdshader asks for filter_linear_mipmap and
	# there was never a chain to sample, so it silently fell back to bilinear on
	# the base level. A hard alpha discard against an unfiltered, minified mask
	# turns sub-pixel leaf structure into per-frame speckle that crawls with the
	# camera - the "lacy / moth-eaten" look - and it is INVARIANT to mask
	# resolution. Which is why the earlier experiment capping masks at 2048 /
	# 1024 / 512 found no difference and concluded the framing was to blame: all
	# three renders were missing the same mip chain.
	#
	# NOT ON A COMPRESSED IMAGE, which is most of them: the game ships BCn and
	# Godot cannot build a mip chain for a block format. It refuses per call, by
	# name, so a prop with twelve textures printed twelve engine errors and drew
	# correctly anyway - noise that reads like a decode failure while the decode
	# was fine.
	if not img.has_mipmaps() and not img.is_compressed() \
			and img.get_width() >= 4 and img.get_height() >= 4:
		img.generate_mipmaps()
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
