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

# Which bf6.exe supplied the type layouts, and which others were available.
# Recorded for the log: SP and MP ship different type databases and the first
# candidate wins silently, so "which one" is a real question a support log has
# to answer rather than something to guess at afterwards.
var _exe_used := ""
var _exe_others: Array = []


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
const BJournal = preload("highpoly_journal.gd")
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
#
# BUT NOT BEFORE THE MAP CAN APPEAR. Those 85 s used to be paid up front, on the
# path that opens a level, and the level does not need them: a map's own props
# come out of its own archives. The catalogue is needed the moment somebody
# browses the Object Library or places an object from another level, which is
# after the map is on screen and is a fine time to still be working.
#
# So the open mounts this level, and the catalogue is added afterwards on a
# worker (upgrade_catalogue). The add is additive and first-wins, so nothing the
# level already resolved can change underneath it.
var catalogue_mount := false
# True once the whole placeable catalogue is mounted. Until then an object from
# another level legitimately does not resolve yet, which is different from not
# existing, and callers that care should say so rather than reporting "the game
# has no prefab for this".
var catalogue_ready := false
# True once the LEVEL's own placements have been walked. Detail Mode does not
# need them, so an open for Detail Mode alone leaves this false and the map
# context asks for them when it is switched on.
var placements_ready := false

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
# geometry. A cap takes the embedded chunk instead of the streamed one, which
# costs a byte range rather than a decompress.
#
# THE SINGLE BIGGEST LEVER ON VIDEO MEMORY, measured in the real editor on
# MP_Aftermath with everything on except FX and nothing distance-culled:
#
#            video memory   of which textures   frames under 60   1% low
#   1024        6834 MB           5050 MB            25.33%        13.1
#    512        5356 MB           3574 MB            25.26%        13.0
#
# 512 gives back 1.5 GB of video memory and costs NOTHING measurable in frame
# rate: median 4.41 ms against 4.40, p99 66.8 against 67.1. It costs visible
# detail and nothing else.
#
# That is worth taking because the CARD is what kills the editor. 6834 MB on an
# 8 GB card is 85%, and the plugin's own tripwire fires at 6144; 5356 MB is 67%
# and leaves room for the SDK's own scene. Godot does not survive a card running
# out of memory, it closes.
#
# It is a setting because the right answer depends on the card. Read at open, so
# changing it takes effect on the next map.
const TEX_DIM_SETTING := "highpoly/texture_max_dim"
var texture_max_dim := 512

# WHERE THE OPEN GOES, per phase, in ms. There is no point optimising this
# without it: the three phases have completely different fixes (a mount is
# bundle metadata, the index is 223k EBX headers, the walk is instance decoding)
# and a single total says nothing about which one to touch. `_cached` records
# whether the walk came from its cache, because a warm run's phase split is a
# different measurement from a cold one and mixing them is how a 50x speedup
# gets attributed to the wrong change.
var timings := {}

# THE SAME PHASES, WITH WHAT THEY PROCESSED AND WHERE THE ANSWER CAME FROM.
#
# `timings` is milliseconds and nothing else, and a bare millisecond count has
# pointed optimisation work at the wrong phase more than once. "partition index
# 300 ms" reads as a solved problem right up until you learn it is 300 ms
# because the index came off disk, and 19 SECONDS the first time this install
# is opened. The cold read is 85 s and the warm one is 1.3 s: the two are
# different measurements, and a table that mixes them is worse than no table.
#
# So every phase records three things beside its time:
#   items   how many of whatever it processes (bundles, partitions, rows, tiles)
#   from    where the answer came from, one of:
#             install   read out of the game's archives. This is the cold cost.
#             cache     served from a file this plugin wrote on an earlier open.
#             memory    served from a dictionary already live in this process.
#             mixed     both, and `note` carries the split.
#   note    anything that makes the row readable on its own
#
# A phase that is fast BECAUSE IT WAS CACHED says so in its own row. Without
# that line someone eventually deletes the caching to simplify a code path and
# only finds out on a machine that has never opened the map.
const FROM_INSTALL := "install"
const FROM_CACHE := "cache"
const FROM_MEMORY := "memory"
const FROM_MIXED := "mixed"

var phases := {}                       # name -> {ms, items, unit, from, note}
var _phase_order: Array = []

# Set while open_map runs: true when ANY of mount / index / walk had to read the
# install. Reported at the top of the table, because it is the one fact that
# decides whether the rest of the numbers mean anything.
var read_was_cold := false


# Record one phase. Also writes `timings`, which is what the dock already
# forwards into the profiler's TIME BY PHASE table, so a new phase here appears
# there too without anything else changing.
func note_phase(name: String, ms: float, items := 0, unit := "items",
		from := "", note := "") -> void:
	if not phases.has(name):
		_phase_order.append(name)
	phases[name] = {"ms": maxf(0.0, ms), "items": items, "unit": unit,
		"from": from, "note": note}
	timings[name] = int(ms)
	_ph_forward(name, ms)


# Add to a phase that is measured in pieces (the ground's sub-steps, called once
# each but worth keeping apart) rather than replacing it.
func add_phase(name: String, ms: float, items := 0, unit := "items",
		from := "", note := "") -> void:
	var e: Dictionary = phases.get(name, {"ms": 0.0, "items": 0, "unit": unit,
		"from": from, "note": note})
	if not phases.has(name):
		_phase_order.append(name)
	e["ms"] = float(e["ms"]) + maxf(0.0, ms)
	e["items"] = int(e["items"]) + items
	if from != "":
		e["from"] = from if str(e.get("from", "")) in ["", from] else FROM_MIXED
	if note != "":
		e["note"] = note
	e["unit"] = unit
	phases[name] = e
	timings[name] = int(e["ms"])
	_ph_forward(name, ms)


# THE SHARED PROFILE SINK, and the reason most of this reader's phases never
# reach it.
#
# HighpolyProfile keeps static dictionaries with no lock, and open_map runs on a
# WorkerThreadPool task, so forwarding from there would be a data race whose
# symptom is a corrupted report or a crash rather than a wrong number. The dock
# already forwards `timings` from the main thread once the open returns, so
# nothing is actually lost; the phases just arrive as one batch at the end
# instead of live. Anything called from the main thread (map_data during a
# build) does forward live, and that is what this guard is for.
func _ph_forward(name: String, ms: float) -> void:
	# The journal takes rows from ANY thread (it carries its own mutex), which
	# is exactly what the profile below cannot - so the worker-thread phases
	# (the whole open_map walk, the part where the job bar sits still) land
	# in the journal live even though they reach the profile late.
	var ph: Dictionary = phases.get(name, {})
	BJournal.phase("game source: %s" % name, ms, int(ph.get("items", 0)),
		str(ph.get("note", "")))
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return
	HighpolyProfile.add("game source: %s" % name, int(ms * 1000.0))


# The table, as lines. Printed by open_map so it exists in the session log even
# when the profiler is not recording, which is most of the time.
# WHAT THIS INSTALL ACTUALLY CONTAINS, as five numbers that can be compared
# against a working machine at a glance.
#
# This exists because a user's terrain rendered with 95% of its layer materials
# missing, their bus and rubble drew white, and several props got no overlay at
# all - and every one of those reported the same thing, "depot ok, record NO".
# The cause was not in the plugin: their install held 9,951 depot scopes against
# 16,936 here, and 205,348 res against 260,328, while carrying the IDENTICAL
# 38,226 placements for the map. The map was whole and the library behind it was
# not. Finding that took diffing two logs by hand; these five lines make it the
# first thing anyone sees.
#
# The reference figures are deliberately included. A number with nothing to
# compare it to is not a diagnosis, and nobody reading a stranger's log knows
# what "9,951 depot scopes" is supposed to be.
# Captured while the partition index phase runs; walk.stats loses it afterwards.
var _catalog_names := 0

const REF_EBX := 450884
const REF_RES := 260328
const REF_NAMES := 818517
const REF_SCOPES := 16936

func install_report() -> PackedStringArray:
	var out := PackedStringArray()
	if src == null:
		return out
	# Taken from the source itself rather than from a stats dictionary: these
	# are the same values the mount note prints, so the two can never disagree.
	var ebx := int(src.ebx.size())
	var res := int(src.res.size())
	var names := _catalog_names
	var scopes := int(_depot_bundles.size())
	if ebx == 0 and res == 0:
		return out
	out.append("")
	out.append("YOUR BATTLEFIELD 6 INSTALL, next to a known-good one")
	# THE VERSION EVIDENCE FIRST, because it is the thing that explains a
	# shortfall AND a layout the reader cannot parse, and we were not recording
	# it at all. bf6.exe's size and modification time are not a version string,
	# but two installs that differ in either are not the same build - which is
	# the question actually being asked when someone's terrain will not resolve.
	if _exe_used != "":
		var f := FileAccess.open(_exe_used, FileAccess.READ)
		var sz := 0
		if f != null:
			sz = f.get_length()
			f.close()
		out.append("  type database      %s" % _exe_used)
		out.append("                     %d bytes, modified %s" % [sz,
			Time.get_datetime_string_from_unix_time(
				FileAccess.get_modified_time(_exe_used))])
		if not _exe_others.is_empty():
			# SP and MP carry different type databases and the first candidate
			# wins. If the layouts do not fit this install, this is the first
			# thing to try swapping.
			out.append("  ALSO PRESENT       %s" % ", ".join(_exe_others))
			out.append("                     (SP and MP carry DIFFERENT type")
			out.append("                      databases; the wrong one resolves")
			out.append("                      to wrong layouts rather than failing)")
	out.append("  game folder        %s" % src.game)
	# WHICH MOUNT THIS DESCRIBES. The reference figures are for a mount of every
	# level, and the open now mounts only the level being read - the placeable
	# catalogue arrives afterwards, on a worker. Comparing a level mount against
	# the all-levels reference reports a healthy install as 49% and flags it LOW,
	# which is the same false alarm that already sent one person off to verify a
	# game that was fine. Say what is being counted, and only compare when the
	# comparison means something.
	if not catalogue_ready:
		out.append("  mount              THIS LEVEL ONLY so far. The rest of the")
		out.append("                     placeable catalogue is still loading, so")
		out.append("                     these counts are EXPECTED to be lower")
		out.append("                     than the reference and nothing here is")
		out.append("                     evidence of a problem yet.")
	else:
		out.append("  A big shortfall here is not a plugin bug: it means the game")
		out.append("  itself is missing content, and nothing can be drawn from")
		out.append("  records that are not on your disk. Verify or repair the game")
		out.append("  install if these read low.")
	for row in [["EBX entries", ebx, REF_EBX], ["resources", res, REF_RES],
			["catalogue names", names, REF_NAMES],
			["depot scopes", scopes, REF_SCOPES]]:
		var have := int(row[1])
		var want := int(row[2])
		var pct := 100.0 * float(have) / maxf(float(want), 1.0)
		if not catalogue_ready:
			out.append("  %-18s %10d   (level mount; no reference yet)"
				% [row[0], have])
		else:
			out.append("  %-18s %10d   reference %10d   %5.1f%%%s"
				% [row[0], have, want, pct,
				   "   <-- LOW" if pct < 90.0 else ""])
	return out


func phase_report(title := "") -> PackedStringArray:
	var out := PackedStringArray()
	if _phase_order.is_empty():
		return out
	out.append("")
	out.append("READER PHASES  %s  %s" % [
		level if title == "" else title,
		"COLD (read from the install)" if read_was_cold
			else "WARM (served from caches)"])
	out.append("  A phase marked \"cache\" is cheap only because an earlier open")
	out.append("  paid for it. Delete the cache and it costs what \"install\" costs.")
	out.append("  %-26s %9s  %-20s %11s  %-7s %s"
		% ["phase", "wall", "items", "each", "from", "note"])
	var total := 0.0
	for k in _phase_order:
		var e: Dictionary = phases[k]
		var ms := float(e["ms"])
		var n := int(e["items"])
		total += ms
		var each := "" if n <= 0 else ("%.3f ms" % (ms / float(n)))
		out.append("  %-26s %8.2fs  %-20s %11s  %-7s %s"
			% [str(k).left(26), ms / 1000.0,
			   ("%d %s" % [n, e["unit"]]) if n > 0 else "",
			   each, str(e.get("from", "")), str(e.get("note", ""))])
	out.append("  %-26s %8.2fs   (attributed; the total open was %.2fs)"
		% ["sum of the above", total / 1000.0,
		   float(timings.get("_total", 0)) / 1000.0])
	return out


func print_phases() -> void:
	# The install fingerprint goes FIRST. When something is wrong with a user's
	# game rather than with this plugin, the phase timings underneath are a
	# distraction - the five counts above them are the answer, and they should
	# be the first thing read rather than something found by diffing two logs
	# by hand afterwards.
	for line in install_report():
		_say(line)
	for line in phase_report():
		_say(line)
	# WHERE THE INSTALL READ ACTUALLY WENT: drive time against Oodle time.
	#
	# BF6Cas has counted both since it was written and io_report() formats
	# them - but its only caller was a diagnostics panel a bench run never
	# opens, so the numbers were gathered every run and read in none. Without
	# them "mount costs 16 s" cannot be acted on: whether that is the drive,
	# the decompressor, or the GDScript around them decides whether the fix is
	# parallel reads, a different path, or fewer calls per record.
	for line in BF6Cas.io_report():
		_say(line)


# THE PER-MESH HALF OF THE READER, which the open never sees.
#
# open_map ends before a single mesh has been asked for: everything below is
# paid during the map context's props and skyline builds, once per mesh group,
# and it is where a cold build spends its minutes. Reported on the same terms as
# the open (wall, items, each, and whether it was a cache hit) so the two tables
# can be read against each other instead of in different units.
#
# Called by the builder when a build finishes; safe to call at any point, and
# the numbers are cumulative since this source was opened.
func build_report() -> PackedStringArray:
	var out := PackedStringArray()
	if n_meshes == 0 and n_geom_hit == 0 and n_mesh_shared == 0:
		return out
	var asks := n_geom_hit + n_geom_miss + n_mesh_shared
	out.append("")
	out.append("READER, PER MESH  %s  %d mesh asks" % [level, asks])
	out.append("  %-30s %9s  %-18s %11s  %s"
		% ["phase", "wall", "items", "each", "from"])
	# A table of rows rather than a helper lambda: a lambda would capture `out`
	# by value (a PackedStringArray is a value type in GDScript) and every line
	# it appended would be written to a copy and thrown away.
	var rows: Array = [
		["mesh: read the resource (CAS)", t_res, n_geom_miss, "meshes", FROM_INSTALL],
		["mesh: parse + build ArrayMesh", t_parse, n_geom_miss, "meshes", FROM_INSTALL],
		["mesh: load from geom cache", t_geom_load, n_geom_loaded, "meshes", FROM_CACHE],
		["mesh: save to geom cache", t_geom_save, n_geom_saved, "meshes", FROM_INSTALL],
		["materials: dress surfaces", t_mat, n_mat_built + n_mat_cached,
			"lookups", FROM_MIXED],
		["materials: of which textures", t_tex, int(tex_stats.get("decoded", 0)),
			"decoded", FROM_INSTALL],
		["materials: of which depots", t_depot, n_depot_parsed, "depots",
			FROM_INSTALL],
	]
	for r in rows:
		var us := int((r as Array)[1])
		var items := int((r as Array)[2])
		out.append("  %-30s %8.2fs  %-18s %11s  %s"
			% [str((r as Array)[0]).left(30), us / 1e6,
			   "%d %s" % [items, str((r as Array)[3])],
			   "" if items <= 0 else ("%.3f ms" % (us / 1000.0 / float(items))),
			   str((r as Array)[4])])
	out.append("  cache hits: %d of %d mesh asks served from disk (%.0f%%), "
		% [n_geom_hit, maxi(1, asks), 100.0 * n_geom_hit / maxf(1.0, float(asks))]
		+ "%d shared in memory, %d read from the install" % [n_mesh_shared, n_geom_miss])
	out.append("  materials: %d built, %d from the cache (%.0f%% reuse); "
		% [n_mat_built, n_mat_cached,
		   100.0 * n_mat_cached / maxf(1.0, float(n_mat_built + n_mat_cached))]
		+ "textures %d decoded, %d reused, %d failed"
		% [int(tex_stats.get("decoded", 0)), int(tex_stats.get("reused", 0)),
		   int(tex_stats.get("failed", 0))])
	if n_geom_miss == 0 and asks > 0:
		out.append("  NOTE: every mesh came from a cache. These per-mesh costs are")
		out.append("  NOT what a first open pays. Delete user://bf6_geom to measure that.")

	# WHY SOME OF IT DREW WHITE, as a count rather than as a marker at a time.
	#
	# Every one of these was already being tallied and none of them was ever
	# printed. A user marks three white props by hand and we investigate three
	# props; the number that matters is whether it is three surfaces or three
	# thousand, and whether they failed for the same reason - and that decides
	# whether it is their install (see the fingerprint above) or our reader.
	var no_key := int(tex_stats.get("no_key", 0))
	var no_dep := int(tex_stats.get("no_depot", 0))
	var mats := int(tex_stats.get("materials", 0))
	var fell := int(tex_stats.get("var_fallback", 0))
	if no_key + no_dep + fell > 0:
		var tried := maxi(1, mats + no_key + no_dep)
		out.append("")
		out.append("SURFACES THAT COULD NOT BE DRESSED  (these draw WHITE)")
		out.append("  %-34s %8d   %5.1f%% of %d"
			% ["no record in the depot", no_key,
			   100.0 * no_key / float(tried), tried])
		out.append("  %-34s %8d   %5.1f%%"
			% ["no depot for the scope at all", no_dep,
			   100.0 * no_dep / float(tried)])
		out.append("  %-34s %8d" % ["dressed successfully", mats])
		# These WOULD have drawn white. Counted separately, and by which fallback
		# answered, so the rescue cannot quietly hide how often the walk hands
		# the dressing code the wrong scope.
		var fb_ship := int(tex_stats.get("scope_shipping", 0))
		var fb_sib := int(tex_stats.get("scope_sibling", 0))
		if fb_ship + fb_sib > 0:
			out.append("  %-34s %8d   would have drawn white"
				% ["  rescued by another scope", fb_ship + fb_sib])
			out.append("  %-34s %8d   the bundle that ships the mesh"
				% ["    of those, shipping bundle", fb_ship])
			out.append("  %-34s %8d   a sibling subworld of the level"
				% ["    a level sibling", fb_sib])
		if fell > 0:
			# Not white, but wrong: the base paint instead of the livery. Worth
			# separating, because it looks like a texture bug and is not one.
			out.append("  %-34s %8d   drew in base paint, not their variant"
				% ["variation had no record", fell])
		out.append("  A large count here with a LOW line in the install")
		out.append("  fingerprint above is the game install, not this plugin:")
		out.append("  a record that is not on the disk cannot be read off it.")

	# WHAT THE TEXTURES WEIGH, AND WHAT SHAPE THEY ARE.
	#
	# tex_dims has been counting every decoded texture by size, format, chunk
	# and mip state since it was written, and tex_stats["bytes"] has been adding
	# up what they cost. Neither was ever printed. A user reported textures that
	# "looked really corrupt" alongside 13 GB of RAM, and the two questions that
	# separates - is a format decoding wrong, and are these simply enormous -
	# were both already answered in memory and thrown away.
	var tbytes := int(tex_stats.get("bytes", 0))
	if tbytes > 0 or not tex_dims.is_empty():
		out.append("")
		out.append("TEXTURES DECODED")
		out.append("  %-34s %8d   %s"
			% ["decoded this session", int(tex_stats.get("decoded", 0)),
			   HighpolyLog.human_bytes(tbytes)])
		var tfail := int(tex_stats.get("failed", 0))
		out.append("  %-34s %8d%s" % ["failed to decode", tfail,
			"   <-- these draw as whatever was last bound" if tfail > 0 else ""])
		var over := int(tex_stats.get("over_cap", 0))
		var atc := int(tex_stats.get("at_cap", 0))
		if over + atc > 0:
			out.append("  %-34s %8d px" % ["resolution cap", texture_max_dim])
			out.append("  %-34s %8d" % ["  within it", atc])
			out.append("  %-34s %8d%s" % ["  larger than it", over,
				"   <-- no smaller level exists in the chunk" if over > 0 else ""])
		if not tex_dims.is_empty():
			# The biggest families only. The full table runs to hundreds of rows
			# and the point is which handful dominate.
			var shapes: Array = []
			for k in tex_dims.keys():
				shapes.append([str(k), int(tex_dims[k])])
			shapes.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
			out.append("  most common shapes (size, format, chunk, mips):")
			for r in shapes.slice(0, mini(shapes.size(), 8)):
				out.append("  %-34s %8d" % [str((r as Array)[0]), int((r as Array)[1])])
	return out


# 16777216 -> "16,777,216". The splat's texel count is the number that says
# whether the paint loop is doing too much work or just doing it slowly.
static func _grouped_i(n: int) -> String:
	var t := str(absi(n))
	var out := ""
	var c := 0
	for i in range(t.length() - 1, -1, -1):
		out = t[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if n < 0 else out


var _hm_paint_us := 0
var _hm_texels := 0
var _hm_grid := 1


func print_build_report() -> void:
	for line in build_report():
		_say(line)


# WALK THE LEVEL'S PLACEMENTS, for a map-context layer being switched on after
# an open that did not need them.
#
# Blocking, and meant to be called from a worker: it is the ~49 s cold traversal
# that used to run on every open whether or not anything was going to draw the
# map. Safe to call more than once.
#
# Everything downstream of the walk is keyed off it, so map_data has to be
# dropped: its group placements were computed from an empty row set.
func ensure_placements(progress := Callable()) -> bool:
	if placements_ready:
		return true
	if src == null or walk == null:
		return false
	var t := Time.get_ticks_msec()
	if progress.is_valid():
		progress.call(ST_WALK, 0, 0)
		walk.progress = func(found: int, _seen: int):
			progress.call(ST_WALK, found, 0)
	if not walk.run_cached(level):
		error = str(walk.stats.get("error", "the placement walk produced nothing"))
		return false
	placements_ready = true
	var cached: bool = bool(walk.stats.get("from_cache", false))
	note_phase("placement walk", Time.get_ticks_msec() - t, walk.rows.size(),
		"placements", FROM_CACHE if cached else FROM_INSTALL,
		"%d light entities, walked when the map layer was switched on"
			% walk.ents.size())
	# Anything derived from an empty walk is wrong now.
	drop_map_data()
	_say("game source: walked %d placements for the map layers"
		% walk.rows.size())
	return true


# COMPOSITE THE GROUND, for a map layer switched on after an open that skipped it.
#
# Same reason this lives in the open rather than in map_data: it is about a
# minute of BC7 decoding and page compositing the first time a map is seen, and
# map_data runs on the MAIN thread. Called from the same worker as
# ensure_placements so it stays off it.
func ensure_ground(cache_dir: String, progress := Callable()) -> bool:
	if cache_dir == "" or src == null:
		return false
	if surface_cache == cache_dir and _surface_tried == cache_dir:
		return not _surface_failed
	surface_cache = cache_dir
	var t := Time.get_ticks_msec()
	if progress.is_valid():
		progress.call(ST_GROUND, 0, 0)
	var sf := terrain_surface(cache_dir, false, progress)
	_surface_tried = cache_dir
	_surface_failed = sf.is_empty()
	note_phase("terrain surface", Time.get_ticks_msec() - t,
		int(sf.get("slices", 0)), "layer slices",
		FROM_CACHE if _surface_cached else FROM_INSTALL,
		"built when the terrain layer was switched on")
	# map_data may already hold a version of this map with no ground in it.
	drop_map_data()
	return not sf.is_empty()


# THE PLACEABLE CATALOGUE, added after the map is already on screen.
#
# Blocking, and meant to be called from a worker: it is the 85 s cold sweep of
# every other level's archives that used to sit in front of the map appearing.
# A cache written by an earlier session turns it into a load instead.
#
# Safe to call more than once; the second call returns immediately.
# TRUE WHILE THE CATALOGUE SWEEP IS GROWING src.ebx AND src.res.
#
# Those two Dictionaries are mounted once and then read all over this file by
# scanning every key - terrain() looks for the streaming tree that way,
# _water_partition and water_sim do the same, _level_dir and the gamemode
# miner's roots_of too. That is fine against a mount that has stopped changing,
# and it is a crash against one that has not: the sweep runs on a worker, and a
# Dictionary that rehashes under another thread's iterator takes the process
# down. A user's crash log caught it exactly there -
#
#   FATAL: Index p_index = 184634 is out of bounds (size = 184634)
#      at terrain() highpoly_gamesource.gd:1470   <- for rn in src.res.keys()
#
# with 184,634 sitting between MP_Tungsten's level mount (154,245 resources) and
# the full catalogue, which is what a half-grown dictionary looks like.
#
# Set on the MAIN thread before the worker starts and cleared after it is
# joined, so a reader can wait on it without a lock.
#
# EXCEPT NO READER EVER DID. This flag is written in two places in
# highpoly_toggle.gd and read in none, so the protection described above never
# existed and the crash named above was never prevented. A dump later caught
# the same race from the other side - a null dereference inside CowData::_ref
# at the instant of the publish, Godot exe +0x3A073D7 on worker thread 13 of
# 71 - which is what finally made the gap visible.
#
# The real protection is BF6Source.snap_res / snap_ebx: every walk takes a
# reference to the dictionary under the publish lock and iterates THAT, so it
# can neither straddle a swap nor watch a rehash. A flag could not do this job
# anyway; it can only ask a reader to wait, and these readers are worker
# threads with nowhere good to wait.
#
# Kept because it is cheap, honest state saying whether the upgrade is in
# flight. It is not a lock and must not be used as one.
var catalogue_upgrading := false


func upgrade_catalogue(progress := Callable()) -> bool:
	if catalogue_ready or src == null:
		return catalogue_ready
	var t := Time.get_ticks_msec()
	var from_cache := false
	if src.has_catalogue_cache() and src.load_catalogue_cache():
		from_cache = true
	elif not src.mount_rest(progress):
		_say("game source: could not add the placeable catalogue: %s"
			% src.last_error())
		return false
	catalogue_ready = true
	# The depot scope index is derived from the resource names, and there are now
	# more of them. Rebuilt rather than appended so it cannot disagree with the
	# mount it describes.
	#
	# BUILT PRIVATELY, PUBLISHED ON THE MAIN THREAD. This runs on the catalogue
	# worker, and the old clear()-and-regrow mutated _depot_bundles IN PLACE
	# while the main thread iterates it - _siblings_of does exactly that on
	# every twice-failed surface, and a user's crash log caught signal 11 there
	# during the on-load apply of their placed pieces (godot-crash-2026-08-10_
	# 01-44-24.log). Same rule and same reason as BF6Source._publish. The
	# derived caches go in the SAME swap: _obj_cache because objects that did
	# not resolve before may resolve now, and _sib_scopes because its sibling
	# lists were computed from the OLD depot set and nothing else ever reset it.
	var nb := {}
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = src.snap_res()
	for rn in t_res.keys():
		var n := str(rn)
		var at := n.find(SHADERSTATE)
		if at > 0 and n.find("shaderblockdepot", at) > 0:
			nb[n.substr(0, at)] = n
	var pub_done := [false]
	var publish := func() -> void:
		_depot_bundles = nb
		if walk != null:
			var si: Dictionary = walk.scope_index.duplicate()
			for d in nb:
				si[str(d)] = str(d)
			walk.scope_index = si
		_obj_cache = {}
		_sib_scopes = {}
		pub_done[0] = true
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		publish.call()
	else:
		publish.call_deferred()
		# The catalogue caller pumps frames while waiting for this worker, so
		# the deferred publish runs within a frame or two; nothing on the main
		# thread hard-blocks on this task, so this cannot deadlock.
		while not pub_done[0]:
			OS.delay_msec(1)
	note_phase("catalogue mount", Time.get_ticks_msec() - t, src.ebx.size(),
		"ebx", FROM_CACHE if from_cache else FROM_INSTALL,
		"every level's archives, %d depot scopes" % _depot_bundles.size())
	_say("game source: placeable catalogue ready, %d ebx, %d res, %d depot scopes%s"
		% [src.ebx.size(), src.res.size(), _depot_bundles.size(),
		   "  (cached)" if from_cache else ""])
	return true


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

# WHAT EACH STAGE IS WORTH ON THE BAR, in seconds of a measured cold open.
#
# The bar used to give every stage an equal tenth, and a bar whose weights are
# wrong is worse than no bar: mount, type layouts and indexing together take
# about 23 s and crawled through the first 30%, so the whole first half minute
# read as "stuck at zero", while the splat composite - 135 s, more than a third
# of the entire read - got 10% of the travel and looked frozen at 70%.
#
# These are measurements, not guesses: a cold MP_Aftermath through
# tools/bench_buttons.py, 2026-08-11. They do not have to be exact and they do
# not have to match every map. They have to be roughly PROPORTIONAL, so that
# equal bar movement means roughly equal waiting, which is the only thing the
# bar is for.
const STAGE_WEIGHT := {
	ST_MOUNT: 16.0,
	ST_TYPES: 0.1,
	ST_INDEX: 7.0,
	ST_WALK: 25.0,
	ST_GROUND: 2.0,
	ST_COLOUR: 2.0,
	ST_PAL: 0.2,
	ST_SPLAT: 135.0,
	ST_BASE: 3.3,
	ST_LAYERS: 0.5,
}

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
# 6: the backdrop plume sheet is read as LIGHTING, not colour - smoke.gdshader
#    gained lighting_packed and takes the channel average when the sheet carries
#    chroma a smoke sheet has no business having. That changes the pixels a
#    cached plume material produces, and a cached one would have gone on drawing
#    the old answer forever: the plumes are map-context props, so their material
#    lives behind this epoch. The correction is only visible once it is bumped,
#    which is the whole reason this number exists.
# 7: blend-keyed materials are NAMED (M_TerrainBlend) so the load-time
# ground-colour swap can find them, and uv2 carries the declB-resolved unwrap.
# Epoch 6 bakes have neither and every mesh must re-parse once.
# How many materials bind the terrain-colour slot, and how many of those
# we actually NAME for the load-time swap. The user reports sidewalks
# still drawing pure white, so the first question is whether the naming
# fires at all - and the gap between these two numbers is the answer.
static var n_blend_slot := 0
static var n_blend_named := 0

# 8: surfaces now carry ARRAY_TEX_UV2 where the mesh has a genuine second
# unwrap, so a cached epoch-7 mesh would serve geometry without it forever.
const GEOM_EPOCH := 11

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
# `want` names the MAP-CONTEXT work. {"placements": false} opens the install for
# skinning the objects the user placed and nothing else, which is all Detail Mode
# needs. Absent means build everything, so existing callers are unchanged.
# WHICH STAGE FAILED, AND WHAT THE MACHINE HAD LEFT WHEN IT DID.
#
# "could not read <map> from the install" was one message covering five
# completely different failures - no install, the mount, no bf6.exe, the type
# database, the placement walk - and it named none of them. A user reporting it
# for one map could not be answered at all, because the same sentence is
# printed whether their game is missing that map's archives or whether the
# editor simply had no memory left to mount them.
#
# The free-memory figure is here because that second case is real and looks
# identical from outside: the read allocates while it mounts, and a machine
# down to its last few hundred MB fails somewhere in the middle of that with
# whatever error the failing allocation happened to produce. A report that says
# "mounting the level's archives" next to "410 MB free" answers itself.
static func _fail(stage: String, why: String) -> String:
	var mem := OS.get_memory_info()
	var free_mb := int(mem.get("free", 0)) / 1048576
	var heap_mb := int(OS.get_static_memory_usage()) / 1048576
	return "%s: %s  [%d MB RAM free, %d MB held by the editor]" % [
		stage, why, free_mb, heap_mb]


func open_map(map: String, game_dir := "", progress := Callable(),
		want := {}) -> bool:
	error = ""
	# Read here rather than at construction, so a change takes effect on the next
	# map rather than needing the editor restarted.
	if ProjectSettings.has_setting(TEX_DIM_SETTING):
		var v := int(ProjectSettings.get_setting(TEX_DIM_SETTING))
		if v == 0 or (v >= 64 and v <= 8192):
			texture_max_dim = v
	# A RE-OPEN NEVER THROWS AWAY WORK. Toggling a layer re-opens the map with
	# that moment's want, and this function used to rebuild the source and the
	# walk from scratch every time: a terrain-only re-open after an objects
	# session replaced a 38k-row walk with an EMPTY one while placements_ready
	# stayed true from the earlier open - so the objects layer's ensure-guard
	# saw "ready", skipped the walk, and "built" zero props from zero rows
	# (user log 2026-08-11). Same map, already open, nothing missing: return.
	var want_pl := bool(want.get("placements", true))
	if src != null and error == "" and level == map.to_lower() \
			and not src.res.is_empty() \
			and (not want_pl or placements_ready) \
			and (surface_cache == "" or _surface_tried == surface_cache):
		BJournal.event("note", "open %s" % map,
			"already open, nothing missing - kept as is")
		return true
	# and when a full open DOES proceed, the flag tells the truth about THIS
	# open, so a later layer toggle knows to top the walk up
	placements_ready = false
	level = map.to_lower()
	timings.clear()
	phases.clear()
	_phase_order.clear()
	read_was_cold = false
	# INTENT NEXT TO ACTIVITY. Every phase row of this open now sits under a
	# row saying what the open was ASKED to do, so "want placements=false"
	# followed by a placement-walk phase reads as the contradiction it is.
	# The Extended-Terrain-walks-placements bug lived for months because the
	# phase table could only say the walk was fast, never that nothing had
	# asked for it.
	BJournal.event("note", "open %s" % map, "want: placements=%s"
		% str(bool(want.get("placements", true))))
	var t_all := Time.get_ticks_msec()
	var t := Time.get_ticks_msec()
	src = BF6Source.new()
	if not src.open(game_dir):
		error = _fail("finding the install", src.error)
		return false
	if progress.is_valid():
		progress.call(ST_MOUNT, 0, 0)
	if not src.mount(level, func(tocs, paths, _ebx):
			if progress.is_valid():
				progress.call(ST_MOUNT, tocs, paths),
			true, 0, catalogue_mount):
		error = _fail("mounting the level's archives", src.last_error())
		return false
	# COUNTED IN BUNDLES, not in seconds alone. The mount is a sweep over every
	# bundle in every mounted TOC, so bundles is the denominator that makes two
	# runs comparable: a level mount and a catalogue mount differ by 5x in the
	# work they do and the per-bundle cost is what says whether that ratio is
	# the whole story.
	var mount_cached: bool = bool(src.stats.get("from_cache", false))
	if not mount_cached:
		read_was_cold = true
	note_phase("mount", Time.get_ticks_msec() - t, src.ebx.size(), "ebx",
		FROM_CACHE if mount_cached else FROM_INSTALL,
		"%d res, %d chunks, %s" % [src.res.size(), src.chunks.size(),
			"every level" if catalogue_mount else "this level only"])
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
		error = _fail("finding the type database",
			"no bf6.exe under %s — the type layouts live in it" % src.game)
		return false
	if not types.open(exe):
		error = _fail("reading the type database", types.error)
		return false
	# WHICH EXE WON, recorded because it is a real choice with consequences and
	# the log never said. SP and MP carry DIFFERENT type databases, and picking
	# the wrong one resolves types to the WRONG LAYOUTS rather than failing -
	# which looks exactly like a table whose offset cannot be pinned, and is a
	# live suspect for a user whose terrain layer palette came back unusable.
	# The candidate order puts SP first, so an install with both silently gets
	# SP; if that turns out to be the bug, this line is what proves it.
	_exe_used = exe
	_exe_others = []
	for c in BF6Types.exe_candidates(src.game):
		if c != exe and FileAccess.file_exists(c):
			_exe_others.append(c)

	walk = BF6Walk.new(src, types)
	# LIGHTS COME OUT OF THE SAME PASS as the placements. They are placed by
	# exactly this traversal — a fixture inherits the composed transform of
	# whichever prefab holds it — and walking a second time to fetch them would
	# cost another 50 s to learn something the first walk went straight past.
	for g in LIGHT_TYPES:
		walk.want_types[str(g)] = "light"
	# AND THE ENVIRONMENT DECAL VOLUMES, for the same reason: soot under a burn
	# barrel, graffiti on a wall and the light splash a gobo fixture paints are
	# all placed by exactly this traversal. Their texture resolves later through
	# the ShaderBlockDepot of the scope the walk records on each entity.
	for g in EDV_TYPES:
		walk.want_types[str(g)] = "edv"
	walk.want_fields = LIGHT_FIELDS + EDV_FIELDS
	# Always the install: the type layouts are read out of bf6.exe on every open
	# and the only caches BF6Types keeps are in-memory ones, so this row never
	# goes warm and there is no point looking for a cache that is not there.
	note_phase("typeinfo", Time.get_ticks_msec() - t, 1, "exe", FROM_INSTALL,
		exe.get_file())
	t = Time.get_ticks_msec()
	# WHETHER THE INDEX WAS BUILT OR READ, decided by whether it reported any
	# progress at all. bf6_source.partition_index returns a cached dictionary
	# before it starts the sweep, and the sweep is the only thing that calls the
	# callback, so zero calls IS the cache hit. There is no flag to read: the
	# index does not record one, and inferring it from "it was fast" is exactly
	# the mistake this table exists to stop.
	var idx_ticks := 0
	walk.build_catalog(func(done, total, _found):
		idx_ticks += 1
		if progress.is_valid():
			progress.call(ST_INDEX, done, total))
	var idx_cached := idx_ticks == 0
	if not idx_cached:
		read_was_cold = true
	# KEPT, because walk.stats does not survive the walk.
	#
	# The install fingerprint read this same key later and got 0, then printed
	# "catalogue names 0, reference 818517, 0.0% <-- LOW" on a completely healthy
	# install - a false alarm telling people to verify a game that is fine. The
	# walk replaces its stats when it runs, and on the cached path the
	# replacement has no "catalog" entry at all.
	_catalog_names = int(walk.stats.get("catalog", 0))
	note_phase("partition index", Time.get_ticks_msec() - t,
		int(walk.stats.get("guid_index", 0)), "partitions",
		FROM_CACHE if idx_cached else FROM_INSTALL,
		"%d names in the catalogue" % _catalog_names)
	t = Time.get_ticks_msec()

	# WHICH BUNDLES OWN A DEPOT, handed to the walk BEFORE it runs so every row
	# records the scope it was placed under. A section's shader state key is only
	# unique within a scope, and the scope is the subworld that MOUNTED the
	# prefab — an ancestor in the walk graph, with no path relationship to the
	# partition the placement sits in. Matching by directory instead resolved
	# 54.7% of sections; this resolves 99.5%.
	# TIMED, because it is a linear scan of every res name the mount produced and
	# a catalogue mount produces 450k of them. It runs before the walk on every
	# open, warm or cold, and nothing had ever measured it: a phase that only
	# exists between two phases that ARE measured is exactly the kind that hides
	# for a year inside somebody else's number.
	var t_scope := Time.get_ticks_msec()
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = src.snap_res()
	for rn in t_res.keys():
		var n := str(rn)
		var at := n.find(SHADERSTATE)
		if at > 0 and n.find("shaderblockdepot", at) > 0:
			_depot_bundles[n.substr(0, at)] = n
	for d in _depot_bundles:
		walk.scope_index[str(d)] = str(d)
	note_phase("depot scope index", Time.get_ticks_msec() - t_scope,
		src.res.size(), "res names", FROM_MEMORY,
		"%d depot scopes found" % _depot_bundles.size())
	t = Time.get_ticks_msec()
	# THE WALK IS MAP-CONTEXT WORK, and it is skipped when nothing is going to
	# draw the map.
	#
	# It traverses the LEVEL's own placements - 38,226 of them on Aftermath, 49 s
	# cold - to answer "what does this map contain and where". Skinning the
	# objects the USER placed does not need any of that: those resolve through
	# the partition index and the depot scopes above, both of which are already
	# built. Someone who only switches Detail Mode to High-Poly was paying for
	# the whole map anyway, and watching a progress bar talk about placements
	# they never asked for.
	if bool(want.get("placements", true)):
		if progress.is_valid():
			progress.call(ST_WALK, 0, 0)
			walk.progress = func(found: int, _seen: int):
				progress.call(ST_WALK, found, 0)
		if not walk.run_cached(level):
			error = _fail("walking the map's placements",
				str(walk.stats.get("error", "it produced nothing")))
			return false
		placements_ready = true
		var walk_cached: bool = bool(walk.stats.get("from_cache", false))
		if not walk_cached:
			read_was_cold = true
		# Per ROW rather than per partition: rows are what the build consumes, and
		# the cold walk is 50 s for ~48k of them, so the per-row figure is the one
		# that can be compared against a change to the traversal.
		note_phase("placement walk", Time.get_ticks_msec() - t, walk.rows.size(),
			"placements", FROM_CACHE if walk_cached else FROM_INSTALL,
			"%d light entities" % walk.ents.size())
	t = Time.get_ticks_msec()
	_geom_open()
	# The geometry cache directory carries GEOM_EPOCH, so a bump orphans every
	# mesh on disk and the next open is cold no matter how many times the map has
	# been built. Recorded here rather than left to be discovered from a build
	# that is mysteriously slow again.
	var geom_n := 0
	if _geom_dir != "":
		geom_n = DirAccess.get_files_at(_geom_dir).size()
	note_phase("geometry cache open", Time.get_ticks_msec() - t, geom_n,
		"meshes on disk",
		FROM_CACHE if geom_n > 0 else FROM_INSTALL,
		("epoch %d, empty: every mesh will be read from the install" % GEOM_EPOCH)
			if geom_n == 0 else ("epoch %d" % GEOM_EPOCH))

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
		var sf := terrain_surface(surface_cache, false, progress)
		# WHAT THE OPEN ALREADY TRIED, so map_data does not try it again on the
		# main thread. See the note on _surface_tried.
		_surface_tried = surface_cache
		_surface_failed = sf.is_empty()
		if not _surface_cached:
			read_was_cold = true
		note_phase("terrain surface", Time.get_ticks_msec() - t,
			int(sf.get("slices", 0)), "layer slices",
			FROM_CACHE if _surface_cached else FROM_INSTALL,
			"served from %s/splat/layers.json" % surface_cache.get_file()
				if _surface_cached else "composited from the streaming tree")
	timings["_total"] = Time.get_ticks_msec() - t_all
	timings["_cached"] = 1 if walk.stats.get("from_cache", false) else 0
	timings["_cold"] = 1 if read_was_cold else 0
	_say("game source: %s, %d placements%s" % [map, walk.rows.size(),
		"  (cached)" if walk.stats.get("from_cache", false) else ""])
	print_phases()
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


func open_async(host: Node, map: String, game_dir := "", want := {},
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
				_prog_total = total,
			want)
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
# Which OPTIONAL sections of map_data have been mined so far. Not part of the
# cache key: sections are added as their layers are switched on, so this records
# progress rather than identity.
var _md_built := {}


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
	var w := water(surface_cache)
	if w.is_empty():
		_map_data.erase("water")
	else:
		_map_data["water"] = w


# Has map_data already been built for this cache directory? Asked by the builder
# BEFORE it calls map_data, so its phase table can say whether that call was a
# dictionary lookup or the ninety seconds of terrain, roads, lights and FX that
# the first ask actually is.
func map_data_ready(cache_dir := "") -> bool:
	return _map_data_key == cache_dir and not _map_data.is_empty()


# Would map_data(cache_dir, want) do real work, or return the stored answer?
#
# The dock asks this before deciding whether to spend a worker task and a read
# panel on the call. It must give the same answer map_data itself would reach:
# a missing base build is work, and so is any wanted optional section that has
# not been built yet - that is the lazy fill, and it is just as capable of
# freezing the main thread as the first build (mining water alone was measured
# in the tens of seconds).
func map_data_would_build(cache_dir := "", want := {}) -> bool:
	if _map_data_key != cache_dir or _map_data.is_empty():
		return true
	var need := _md_need(want)
	for k in MD_OPTIONAL:
		if bool(need.get(k, true)) and not _md_built.has(k):
			return true
	# WATER RE-ASKS WHEN THE ANSWER WAS "NONE". The key is only written when
	# water is FOUND, so "built, but no key" is indistinguishable from "asked
	# before the reader could find it" - and that exact shape is how a water
	# fix reached a user's editor and did nothing until a restart (twice now:
	# the aftermath partition miss, then the block-2 river). The cost of the
	# re-ask on a genuinely waterless map is one partition parse and one
	# find_block, on the worker, only when the user toggles Water on.
	if bool(need.get("water", false)) and not _map_data.has("water"):
		return true
	return false


# BUILD ONLY WHAT THE LAYERS THAT ARE ON ACTUALLY NEED.
#
# This used to build all of it, every time, whatever was switched on. A user's
# log records an apply with terrain=true objects=false backdrop=false
# water=false which then went on to mine 3,874 lights, 701 FX emitters, an ocean
# simulation and 49 scatter kits - none of which anything was going to draw. It
# is 64 s of a 74 s terrain-only apply, on the main thread, and it is the "why
# is it extracting things I did not ask for" that people keep reporting.
#
# `want` names the OPTIONAL sections: lights, fx, water. Absent or empty means
# build everything, so every existing caller behaves exactly as before. The
# ground, the roads and the group placements are always built: a terrain apply
# genuinely needs them, and they are what the props and skyline lanes key off.
#
# Sections are added LAZILY. Switching the light layer on later asks again with
# lights wanted, and only the missing section is built - so nothing is lost by
# not building it up front, which is what makes this safe to skip rather than
# merely cheaper.
const MD_OPTIONAL := ["lights", "fx", "water", "edv"]

func map_data(cache_dir := "", want := {}) -> Dictionary:
	var need := _md_need(want)
	if _map_data_key == cache_dir and not _map_data.is_empty():
		var missing := {}
		for k in MD_OPTIONAL:
			if bool(need.get(k, true)) and not _md_built.has(k):
				missing[k] = true
		if missing.is_empty():
			return _map_data
		_md_fill(cache_dir, missing, _map_data)
		return _map_data
	var out := _build_map_data(cache_dir, need)
	_map_data = out
	_map_data_key = cache_dir
	return out


func _md_need(want: Dictionary) -> Dictionary:
	if want.is_empty():
		return {"lights": true, "fx": true, "water": true, "edv": true}
	var d := {}
	for k in MD_OPTIONAL:
		d[k] = bool(want.get(k, false))
	return d


# Build the optional sections named in `need` into `out`. Used both by the first
# build and by a later ask that turns a layer on.
func _md_fill(cache_dir: String, need: Dictionary, out: Dictionary) -> void:
	if cache_dir != "" and bool(need.get("lights", false)) \
			and not _md_built.has("lights"):
		var t := Time.get_ticks_msec()
		# Written as the files the light layer reads, rather than handed over in
		# memory: the layer is toggled long after the build, from the dock.
		out["lights"] = lights(cache_dir)
		_md_built["lights"] = true
		note_phase("lights", Time.get_ticks_msec() - t, int(out["lights"]),
			"fixtures", FROM_MEMORY, "from the walk's light entities")
	if cache_dir != "" and bool(need.get("fx", false)) and not _md_built.has("fx"):
		var t := Time.get_ticks_msec()
		out["fx"] = fx(cache_dir)
		_md_built["fx"] = true
		note_phase("fx points", Time.get_ticks_msec() - t, int(out["fx"]),
			"emitters", FROM_INSTALL, "emitter graph read per distinct effect")
	if bool(need.get("water", false)) \
			and (not _md_built.has("water") or not out.has("water")):
		# The second clause is the re-ask: see map_data_would_build. An empty
		# earlier answer must not outlive the code that produced it.
		var t_w := Time.get_ticks_msec()
		var w := water(cache_dir)
		if not w.is_empty():
			out["water"] = w
		_md_built["water"] = true
		note_phase("water", Time.get_ticks_msec() - t_w, w.size(), "bodies",
			FROM_INSTALL, "the level's water partition")
	if bool(need.get("edv", false)) and not _md_built.has("edv"):
		# In memory like water, not a file like lights: the builder runs while
		# this source is alive either way, and the sheets resolve through
		# decal_sheet() at build time. The key is written even when the answer
		# is empty - the records come off the already-run walk, so a re-ask
		# could never find more than this one did.
		var t_e := Time.get_ticks_msec()
		var recs := _edv_records()
		out["edv"] = recs
		_md_built["edv"] = true
		note_phase("decal volumes", Time.get_ticks_msec() - t_e, recs.size(),
			"volumes", FROM_MEMORY, "from the walk's collected entities")
	if phases.has("lights") and phases.has("fx points"):
		timings["lights + fx"] = int(phases["lights"]["ms"]) \
			+ int(phases["fx points"]["ms"])


# WHICH SWITCHABLE LAYER A PLACEMENT BELONGS TO, from the subworld it came out
# of. "" means always on.
#
# A level ships its content in subworlds side by side, and the walk records which
# one each placement came from. Measured on MP_Aftermath, by prop instances:
#
#   sub_art_00..12          ~32,000   the map itself
#   default_event             2,001   the normal-season dressing
#   winter_event              1,770   the SEASONAL dressing
#   _layers_gameplay/*          ~250   per gamemode: conquest, domination, rush,
#                                     sabotage, kingofthehill, teamdeathmatch...
#   aftermathgauntlet*, squadobliteration
#
# Everything after default_event is content that should only appear when its
# season or gamemode is chosen, and all of it was being drawn at once. Two of
# the props a user marked are this: "these should only show up during the winter
# mode" and "these should only show up in certain game modes".
#
# THE MACHINERY TO HIDE THEM ALREADY EXISTED and was fed by prop_layers.json,
# produced by a miner that no longer exists (task #37). _active_variant_layers
# already defaults to {"default_event": true}, so returning the subworld's leaf
# name here is all it needs: art and the level's own bundle return "" and stay
# visible, default_event matches the default set, and everything else is hidden
# until its layer is picked.
func layer_of_scope(scope: String) -> String:
	if scope == "":
		return ""
	var leaf := scope.get_file()
	var dir := scope.get_base_dir()
	# The level's own bundle: .../mp_aftermath/mp_aftermath. RESTRICTED to
	# non-gameplay paths: on MP_Abbasid the gameplay layers live at
	# _layers_gameplay/<x>/<x>, where leaf == dir-name is the LAYOUT, not the
	# level bundle - the unrestricted rule made conquest/rush/testlevelmode
	# always-visible there (docs/MAP-ABBASID.md, task #77).
	if leaf == level:
		return ""
	if leaf == dir.get_file() and not dir.contains("_layers_gameplay"):
		return ""
	# The art subworlds ARE the map, and so are whole world AREAS: Abbasid's
	# area_02_subworld sits at the level root with 263 objects of plain map -
	# classifying it as switchable dressing hid a whole district by default
	# (the user's "missing props" marks).
	if leaf.begins_with("sub_art_") or leaf.begins_with("area_"):
		return ""
	if dir.ends_with("_layers_world"):
		# GAMEMODE DRESSING HIDES HERE TOO. Abbasid files eight
		# <mode>_subworld layers under _layers_world, where the blanket ""
		# drew Rush barriers and Payload dressing in every mode (the user's
		# "gamemode props showing" marks). Only names that carry a KNOWN mode
		# token become mode layers - an unrecognised subworld stays visible,
		# because wrongly hiding map content is the worse failure.
		if leaf.ends_with("_subworld"):
			var stem := leaf.trim_suffix("_subworld")
			for tok in ["conquest", "rush", "breakthrough", "domination",
					"teamdeathmatch", "kingofthehill", "sabotage", "payload",
					"obliteration", "gunmaster", "freeforall", "escalation",
					"attrition", "gauntlet", "squaddm", "strikepoint"]:
				if stem.contains(str(tok)):
					return stem
		return ""
	if dir.ends_with("_layers_content"):
		return ""
	return leaf


func _build_map_data(cache_dir: String, need := {}) -> Dictionary:
	var t_group := Time.get_ticks_msec()
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
		props.append({"mesh": k, "xf": Array(by_mesh[k] as PackedFloat32Array),
			"layer": layer_of_scope(str((_group_meta[k] as Array)[1]))})
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
	# THE GROUPING PASS, which nothing had ever timed. It runs over every walk row
	# and does a mesh resolve, a variation hash and a live-variation lookup per
	# row, and on a warm open (walk from cache, geometry from cache) it is one of
	# the few things left that is genuinely proportional to the map.
	note_phase("map data: group placements", Time.get_ticks_msec() - t_group,
		walk.rows.size(), "rows", FROM_MEMORY,
		"%d prop groups, %d skyline groups, %d rows with no geometry"
		% [by_mesh.size(), by_bd.size(), dropped])
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
		# Composited from the streaming tree the first time, read back from
		# height_game.r16 after that - terrain() fingerprints the tree res, so a
		# game patch recomposites and anything else is a file read. This row is
		# where "every open pays 30 s" used to hide.
		var _hm_cached := bool(hm.get("from_cache", false))
		note_phase("ground: heightfield", Time.get_ticks_msec() - t,
			int(hm.get("res", 0)), "samples per side",
			FROM_CACHE if _hm_cached else FROM_INSTALL,
			"read back from height_game.r16" if _hm_cached
				else "composited from the streaming tree and written for next "
					+ "time; paint %.1fs over %s texels into a %s grid (%.1fx "
					% [float(_hm_paint_us) / 1e6, _grouped_i(_hm_texels),
						_grouped_i(_hm_grid),
						float(_hm_texels) / maxf(1.0, float(_hm_grid))]
					+ "overdraw)")
		t = Time.get_ticks_msec()
		# The ground's appearance: colour map, layer palette, splat. The
		# expensive one, and skipped outright once the map's cache holds it.
		# Skip the retry the open already proved cannot work. Deterministic: same
		# cache dir, same install, same code, so a second attempt returns the
		# same nothing - it just spends minutes of frozen editor doing it.
		var sf := {} as Dictionary
		if _surface_failed and _surface_tried == cache_dir:
			_say("game source: the ground had no usable surface on the open, so "
				+ "map_data is NOT compositing it a second time (that retry is "
				+ "what froze the editor with every progress bar at zero)")
		else:
			sf = terrain_surface(cache_dir)
		if not sf.is_empty():
			out["surface"] = sf
		# A SECOND ASK, under its own name. open_map already built this on the
		# worker, so this call is normally a JSON read of layers.json. Filing it
		# under "terrain surface" would overwrite the cold measurement with the
		# warm one and make the composite look free.
		note_phase("map data: surface re-ask", Time.get_ticks_msec() - t,
			int(sf.get("slices", 0)), "layer slices",
			FROM_CACHE if _surface_cached else FROM_MEMORY,
			"already built by the open" if _surface_cached
				else ("SKIPPED: the open already failed to build it"
					if _surface_failed and _surface_tried == cache_dir
					else "the open did not build it, so it was composited here"))
		t = Time.get_ticks_msec()
		# ORDER MATTERS: the roads are draped on the heightfield terrain() just
		# composited, so they cannot be built before it.
		var rd := roads()
		if rd != null:
			out["roads"] = rd
		note_phase("roads", Time.get_ticks_msec() - t,
			0 if rd == null else rd.get_surface_count(), "surfaces",
			FROM_INSTALL, "TerrainDecals, draped on the heightfield")
	# GIVE THE HEIGHTFIELD BACK. It exists for one reason: _height_at(), which is
	# read by exactly one caller, the road drape just above. After that it is
	# dead weight held for the rest of the session - and it is not small. A
	# user's log records a 16385 x 16385 field, which at u16 is 537 MB resident
	# for nothing. The metadata stays (it is a few floats and cheap to keep);
	# only the samples go.
	if not _hm.is_empty() and _hm.has("data"):
		var _hm_mb := float((_hm["data"] as PackedByteArray).size()) / 1048576.0
		_hm["data"] = PackedByteArray()
		if _hm_mb >= 1.0:
			_say("game source: released the %.0f MB heightfield; the roads are "
				% _hm_mb + "draped and nothing else reads it")
	# The optional sections, only the ones asked for. Anything skipped here is
	# built on demand the moment its layer is switched on: see map_data().
	_md_fill(cache_dir, need, out)
	var skipped := PackedStringArray()
	for k in MD_OPTIONAL:
		if not _md_built.has(k):
			skipped.append(str(k))
	if not skipped.is_empty():
		_say("game source: skipped %s - the layer(s) are off. They are mined the "
			% ", ".join(skipped)
			+ "moment you switch one on, so nothing is lost by not doing it now.")
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
# The heightfield cache's fingerprint: the streaming-tree res's size plus a
# hash of its first and last 64 KB. Hashing the whole res would also work; the
# sampled form is kept because the res can be tens of MB and the two ends catch
# both a re-authored header and appended data, which is how these grow.
static func _terrain_key(res: PackedByteArray) -> String:
	var n := res.size()
	var head := res.slice(0, mini(65536, n))
	var tail := res.slice(maxi(0, n - 65536), n)
	# The GLOBAL hash(): PackedByteArray carries no .hash() method of its own.
	# +h3: bilinear composite + the street-preserving block-8 hole mask - the
	# suffix retires every nearest-sampled, hole-less cache in the field.
	return "%d:%d:%d+h3" % [n, hash(head), hash(tail)]


func terrain(cache_dir: String) -> Dictionary:
	if src == null:
		return {}
	var pick := ""
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = src.snap_res()
	for rn in t_res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains(level):
			pick = n
			break
	if pick == "":
		return {}
	var res := src.get_res(pick)
	if res.is_empty():
		return {}
	# READ THE FILE BACK INSTEAD OF REDOING THE WORK. The composite below walks
	# ~264 nodes and assembles an 8193^2 grid - ~30 s of the main-thread freeze
	# that followed every apply, paid on EVERY open because height_game.r16 was
	# written and never read. The fingerprint is the streaming-tree res itself
	# (size + head/tail sample), so a game patch that changes the terrain
	# invalidates the cache and a reinstall to the same content does not. get_res
	# is already paid either way - it is the line above - so a hit costs one
	# 128 MB file read against a 30 s composite.
	var r16_path := "%s/height_game.r16" % cache_dir
	var meta_path := "%s/height_game.json" % cache_dir
	var hm_key := _terrain_key(res)
	if FileAccess.file_exists(r16_path) and FileAccess.file_exists(meta_path):
		var mv: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if mv is Dictionary and str((mv as Dictionary).get("key", "")) == hm_key:
			var md := mv as Dictionary
			var side := int(md.get("res", 0))
			var bytes := FileAccess.get_file_as_bytes(r16_path)
			# The length check is the corruption guard: a partial write from a
			# crashed session must fall through to the composite, not ship a
			# short grid the mesh builder would index off the end of.
			if side > 0 and bytes.size() == side * side * 2:
				_hm = {"data": bytes, "res": side,
					"min": float(md.get("world_min", 0.0)),
					"max": float(md.get("world_max", 0.0)), "base": 0.0,
					"scale": float(md.get("scale", 0.0))}
				_build_tile_steps()
				_say("game source: terrain %dx%d read back from the cache" % [side, side]
					+ " (the install's streaming tree is unchanged)")
				return {
					"file": "height_game.r16",
					"res": side,
					"world_min": float(md.get("world_min", 0.0)),
					"world_max": float(md.get("world_max", 0.0)),
					"base": 0.0,
					"scale": float(md.get("scale", 0.0)),
					"from_cache": true,
				}
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
	if not g.is_empty():
		_hm_paint_us = int(g.get("us_paint", 0))
		_hm_texels = int(g.get("texels", 0))
		_hm_grid = int(g.get("grid", 1))
	if g.is_empty():
		_say("game source: terrain — %s" % t.error)
		return {}
	var lo: Vector3 = g["min"]
	var hi: Vector3 = g["max"]
	DirAccess.make_dir_recursive_absolute(cache_dir)
	# NO TERRAIN CUT. Block 8 looked like a render-hole mask for one session
	# (its region contains 91% of the sidewalks) and IS NOT one: triangle-level
	# ray-casts through every placement near cut street texels found NO ground
	# mesh at street height - the street surface in that region IS the terrain,
	# and the game draws it. Block 8 is a hard-ground descriptor for the
	# dynamic-world systems (77-100% of crater-denial markers sit inside it).
	# Cutting our terrain there produced voids where the road was. The mask
	# reader stays in BF6MaterialTree for scatter/deformation use; nothing
	# consumes it for rendering, and the mask file from the one build that
	# wrote it is removed so a stale mesh rebuild cannot pick it up.
	DirAccess.remove_absolute("%s/holes_game.png" % cache_dir)
	var path := "%s/height_game.r16" % cache_dir
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_say("game source: terrain — cannot write %s" % path)
		return {}
	f.store_buffer(g["data"])
	f.close()
	# The read-back's fingerprint, written beside the grid. The r16 alone cannot
	# say which install produced it, and serving stale heights after a game patch
	# would put every draped road underground with nothing naming the cause.
	var mf := FileAccess.open(meta_path, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify({"key": hm_key, "res": int(g["size"]),
			"world_min": lo.x, "world_max": hi.x,
			"scale": float(g["world_size_y"])}))
		mf.close()
	# KEPT IN MEMORY as well as written, because the roads need it. Decal
	# vertices carry world X and Z and no Y at all — they are draped on the
	# terrain — so building them means sampling this exact grid with this exact
	# formula. Re-reading the file we just wrote would work and would also be
	# the place the two copies quietly disagree.
	_hm = {"data": g["data"], "res": int(g["size"]), "min": lo.x,
		"max": hi.x, "base": 0.0, "scale": float(g["world_size_y"])}
	_build_tile_steps()
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
# The splat raster TARGETS A TEXEL DENSITY rather than a fixed side. 2048 on
# an 8 km map is 4 m per texel, and 4 m stair-steps at every layer boundary is
# the "pixelated ground" a user reported; the game's own weight pages are
# denser than that (per-node pages, ~1 m native), so the resolution was ours,
# not the data's. 2 m per texel, capped: a 4 km map stays at 2048 and an 8 km
# map doubles to 4096. The cap is VRAM - idx+w at 4096 are 128 MB resident
# against 32 at 2048, and 8192 would be half a gigabyte for one map.
const SURFACE_RES_MIN := 2048
const SURFACE_RES_MAX := 4096
const SURFACE_M_PER_TEXEL := 2.0

static func _surface_res_for(world_size: float) -> int:
	var want := int(world_size / SURFACE_M_PER_TEXEL)
	var side := SURFACE_RES_MIN
	while side < want and side < SURFACE_RES_MAX:
		side *= 2
	return side
# The colour map targets 1 m per texel the same way the splat raster targets
# 2 m (see _surface_res_for): a 4 km map stays at 4096, an 8 km map doubles to
# 8192. Affordable where the splat raster is not, because the loader S3TC
# compresses it - 8192 lands at ~45 MB resident where the splat pair at the
# same side would be half a gigabyte of raw RGBA it must stay.
const COLOR_RES_MIN := 4096
const COLOR_RES_MAX := 8192

static func _color_res_for(world_size: float) -> int:
	var want := int(world_size / 1.0)
	var side := COLOR_RES_MIN
	while side < want and side < COLOR_RES_MAX:
		side *= 2
	return side
# Bumped whenever the colour map is DECODED differently, so an existing cache
# is rebuilt instead of serving the previous interpretation forever.
#   1  a red/blue swap that turned out to be wrong and was reverted
#   2  the layout fix: first-tile-of-trailer, per-node trailer sizes, apron 2
const CMAP_VERSION := 2
# Bumped whenever the WEIGHT PAGES are read differently - this invalidates the
# whole surface (slices, idx, w), not just the colour map.
#   2  detect_layout rewritten: the old scorer picked page size 2592 on every
#      map, so the nine 4356/5184 maps had their pages sliced at wrong offsets
#      and decoded with the wrong codec. Their idx/w caches are noise and must
#      be rebuilt. (Starts at 2 to match CMAP_VERSION's history.)
#   3  pages sliced FORWARD from the block-0 payload: v2 still sliced them
#      end-relative, which on the block-2 water maps (tungsten, eastwood,
#      isolated) read the WATER HEIGHTFIELD as weight pages on exactly the
#      river nodes. See MAP-TUNGSTEN.md §U.
#   4  the raster targets 2 m per texel (large maps bake at 4096, not 2048)
#      and the layer slices doubled to 1024 px - same reader, sharper bake.
#   5  the colour map targets 1 m per texel (large maps bake at 8192), and
#      layers.json carries "linked" so the near-field window can rasterise
#      street materials without reloading the palette.
#   6  VIRTUAL SLICES: computed layers (no colour sheet anywhere - measured
#      three probes deep on aftermath) keep ids of their own (32..63) so the
#      fallback detail runs at each layer's AUTHORED tiling and smoothness
#      instead of one global 4 m tile. 87% of aftermath's ground stopped
#      being one texture for it. The palette also accepts texture params
#      behind unknown slot hashes, classified by name suffix.
#   7  the generic slope-fallback ground is picked by MATERIAL CLASS, not by
#      coverage: aftermath's biggest textured layer is cobblestone, and with
#      the virtual slices tiling the generic ground everywhere the seabed
#      came out as bricks. Natural surfaces only; architectural ones barred.
#   8  pages are sampled through their INTERIOR 64x64: the 66x66 page carries
#      a 1-texel apron (byte-identical to the neighbour on 400/400 adjacent
#      pairs), and stretching all 66 across the record scaled every painted
#      shape by 66/64 and shifted paint up to a page texel at node edges.
#   9  block-7 base pairs briefly indexed the MAP-GLOBAL no-page list - see 10.
#  10  block-7 base pairs index the SPATIALLY MATCHED block-1 node's own
#      no-page list (TERRAIN.md 8 as written). v9's global list was validated
#      on aftermath/outskirts, the two maps where every node list EQUALS the
#      global list; on 23 of 35 maps they differ (mp_isolated: 98.9% of its
#      base-kind texels named the wrong layer, dumbo 31%). The v9-era symptom
#      that motivated the global list was a broken key-equality node lookup,
#      not the list choice: the match is by BOUNDS (bf6_splat.base_list_at).
const SPLAT_VERSION := 10
# Per-slice detail textures; all slices must match. 1024 rather than 512: the
# game's layer sheets are mostly 1024+, and at 512 the close-up ground was a
# quarter of the detail the install holds. The loader compresses the slices to
# S3TC before the array upload, so 1024 compressed is CHEAPER resident than
# 512 raw was.
const LAYER_TEX_DIM := 1024


# Set by terrain_surface: true when it returned the cached answer without
# touching the install. It is the difference between a 40 s phase and a 5 ms
# one, and it is invisible from the outside because both return the same
# dictionary.
var _surface_cached := false
# WHICH cache dir the open already composited a surface for, and whether that
# attempt failed.
#
# THIS IS THE WHOLE "IT FROZE AND THE BARS SAT AT 0%" MECHANISM.
#
# open_map builds the ground on a WorkerThreadPool task, behind a progress bar,
# and map_data's later call was designed to "find the cache and cost nothing".
# That holds only while the build SUCCEEDS. When it fails - a layer palette that
# will not resolve, say - layers.json is never written, so map_data finds no
# cache and composites the entire ground again: colour map, palette search,
# splat. On the MAIN thread. With no progress callback passed at all.
#
# So the editor freezes, every bar stays where it was, and the log goes quiet,
# all from one silent retry. And the retry cannot succeed: same inputs, same
# code, same answer. It is pure cost.
var _surface_tried := ""
var _surface_failed := false


# One row per palette layer for layers.json: the index and a representative
# texture stem ("" when the layer binds nothing anywhere). The stem, not the
# path: classification keys on words like grass/gravel, and the directory adds
# nothing but bytes to a file parsed on every open.
func _palette_rows(pal) -> Array:
	var out: Array = []
	for i in range(pal.layers.size()):
		var lay: Dictionary = pal.layers[i]
		var nm := ""
		for k in (lay["textures"] as Dictionary):
			nm = str((lay["textures"] as Dictionary)[k]).get_file()
			if nm != "":
				break
		out.append({"layer": i, "tex": nm})
	return out


func terrain_surface(cache_dir: String, force := false,
		progress := Callable()) -> Dictionary:
	_surface_cached = false
	if src == null or cache_dir == "":
		return {}
	# EVERY STAGE BELOW NOW REPORTS WHILE IT RUNS, not only when it ends.
	#
	# This whole function is main-thread work, so a user who stalls inside it
	# freezes the editor: the panel stops repainting, the heartbeat stops
	# firing, and note_phase - which records a phase when it FINISHES - records
	# nothing for a phase that has not finished. One user sat here for four and
	# a half minutes and their log contained a blank gap where the answer was.
	#
	# Wrapped once here rather than at each progress.call site, so a stage added
	# later is covered without anyone remembering to.
	var _panel := progress
	progress = func(stage: String, done: int, total: int) -> void:
		HighpolyVitals.crumb(stage)
		HighpolyVitals.tick_long(stage, done, total)
		if _panel.is_valid():
			_panel.call(stage, done, total)
	var dir_splat := "%s/splat" % cache_dir
	var meta_path := "%s/layers.json" % dir_splat
	if not force and FileAccess.file_exists(meta_path) \
			and FileAccess.file_exists("%s/colormap.png" % cache_dir):
		var got: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		# THE VERSION GATE IS BACK, because the day the old note here waited for
		# has come. It was removed when re-deriving the colour map bought
		# "nothing anyone can see" - correct then, because the colour map never
		# reached the shader. Now detect_layout has been rewritten (the old one
		# picked the wrong page size on nine of sixteen maps, so those caches
		# hold noise for weights AND colour), the colour map is decoded from the
		# right bytes, and the shader path is wired. A cache from before the fix
		# is precisely "the previous interpretation served forever", which is
		# what the gate exists to end. The rebuild it forces runs on a worker
		# behind the read panel - not the main-thread freeze the old note
		# rightly refused to pay.
		if got is Dictionary \
				and int((got as Dictionary).get("splat_v", 0)) == SPLAT_VERSION:
			_surface_cached = true
			return got as Dictionary

	var pick := ""
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = src.snap_res()
	for rn in t_res.keys():
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
	# The raster sides for THIS map, from its world span (see _surface_res_for).
	var sres := _surface_res_for(sp.root_max.x - sp.root_min.x)
	var cres := _color_res_for(sp.root_max.x - sp.root_min.x)

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
	var cmap := sp.assemble_colors(tiles, cres)
	var t_asm := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	if cmap != null:
		# THE ENCODE COMES OFF THE COLD PATH. PNG-encoding the 8192 map was
		# 15.5 s of every cold open (measured in a user log), and nothing in
		# THIS session needs the file: the assembled Image is kept in memory
		# and _colormap_set takes it from there, so the disk copy only exists
		# for the NEXT session and can be written whenever it likes.
		_cmap_mem = cmap
		_cmap_mem_level = level
		var cpath := "%s/colormap.png" % cache_dir
		WorkerThreadPool.add_task(func(): cmap.save_png(cpath))
	var t_write := Time.get_ticks_msec() - t0
	_say("game source: terrain colour map, %d tiles, %dx%d (read %.1fs, assemble %.1fs, write queued)"
		% [tiles.size(), cres, cres, t_read / 1000.0, t_asm / 1000.0])
	# THREE SEPARATE COSTS, kept apart. Reading the tiles is CAS I/O plus a BC7
	# decode per tile, assembling is a blit into one 4096 image, and writing is a
	# PNG encode. They have nothing in common and a single "colour map" number
	# would send anyone straight at the wrong one.
	note_phase("ground: colour tiles read", t_read, tiles.size(), "tiles",
		FROM_INSTALL, "BC7 decode per tile out of the streaming tree")
	note_phase("ground: colour assemble", t_asm, tiles.size(), "tiles",
		FROM_MEMORY, "into one %dx%d image" % [cres, cres])
	note_phase("ground: colour PNG write", t_write, 1, "file", FROM_MEMORY,
		"colormap.png handed to a worker; the 15.5 s encode is off the open")

	# ---- the palette ---------------------------------------------------------
	if progress.is_valid():
		progress.call(ST_PAL, 0, 0)
	t0 = Time.get_ticks_msec()
	var pidx: Dictionary = walk.gi if walk != null and walk.gi is Dictionary \
		else src.partition_index()
	var pal := BF6TerrainLayers.new()
	if not pal.load(src, level, pidx):
		_say("game source: terrain layers, %s" % pal.error)
		return {}
	note_phase("ground: layer palette", Time.get_ticks_msec() - t0,
		pal.layers.size(), "layers", FROM_INSTALL,
		# The offset search inside this phase is what froze a user's editor for
		# 2 m 34 s. Carrying its cost on the SUCCESS path too, so a log can show
		# the fix holding rather than only showing it failing.
		"layer graph chain; offset search %d ms over %d candidates"
			% [pal.scan_ms, pal.scan_candidates])

	# ---- the splat -----------------------------------------------------------
	t0 = Time.get_ticks_msec()
	var comp := sp.composite(chunks, fetch, sres, func(done: int, total: int):
		if progress.is_valid():
			progress.call(ST_SPLAT, done, total))
	var t_splat := Time.get_ticks_msec() - t0
	_say("game source: terrain splat composite, %.1fs" % (t_splat / 1000.0))
	note_phase("ground: splat composite", t_splat, int(comp.get("pages", 0)),
		"pages", FROM_INSTALL,
		"into a %dx%d index and weight raster; fetch %.1fs decode %.1fs "
			% [sres, sres, float(comp.get("us_fetch", 0)) / 1e6,
				float(comp.get("us_decode", 0)) / 1e6]
		+ "paint %.1fs over %s texels, tally %.1fs; "
			% [float(comp.get("us_paint", 0)) / 1e6,
				_grouped_i(int(comp.get("texels", 0))),
				float(comp.get("us_tally", 0)) / 1e6]
		+ "in %d band(s)" % int(comp.get("bands", 0)))
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
			base = mt.rasterize(sres,
				func(cx, cz, w): return sp.base_list_at(cx, cz, w),
				sp.full_list(), _linked_of(pal), Vector2.INF, 0.0,
				sp.global_base_list())
			var t_base := Time.get_ticks_msec() - t0
			_say("game source: terrain base field, %d pairs, %d nodes, %.1fs"
				% [mt.pairs.size(), mt.nodes.size(), t_base / 1000.0])
			note_phase("ground: street materials", t_base, mt.nodes.size(),
				"tree nodes", FROM_INSTALL,
				"%d material pairs rasterised to %dx%d"
				% [mt.pairs.size(), sres, sres])
		else:
			_say("game source: terrain base field, %s" % mt.error)

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
	if base.size() == sres * sres:
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
		_say("game source: terrain base field placed on %.2f%% of texels"
			% (100.0 * float(placed) / float(maxi(1, base.size()))))

	var per_layer := {}
	var idx_c: PackedByteArray = comp["idx"]
	var wgt_c: PackedByteArray = comp["w"]
	for i in range(sres * sres):
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

	# VIRTUAL SLICES for the computed layers (task #86, as far as the data
	# goes). A layer whose record binds no colour sheet is computed inside the
	# game's compiled layer-graph shader - measured to the end on mp_aftermath:
	# no textures behind unknown slots, no colour constants, and the lg res is
	# only the record table, so the look is colour map plus shader-internal
	# detail. What the record DOES hold is the layer's own authored TILING and
	# SMOOTHNESS (aftermath's dominant layer tiles at 20 m where others take
	# 50 or 100), and 87% of that map's ground rendered as ONE texture because
	# every computed layer collapsed to the same fallback at the same 4 m
	# tile. Each gets an id of its own (32..63, above the texture slices) that
	# drives the fallback detail at the layer's own scale and roughness - all
	# of it authored numbers, none of it invented.
	var virt_of := {}
	var virt_meta: Array = []
	for l in by_area:
		var li := int(l)
		if pal.albedo_of(li) != "" or virt_meta.size() >= 32:
			continue
		var lay23: Dictionary = pal.layers[li]
		virt_of[li] = 32 + virt_meta.size()
		virt_meta.append({
			"layer": li,
			"metres_per_repeat": pal.metres_per_repeat(li, 20.0),
			"smoothness": float(lay23.get("smoothness", -1.0)),
		})

	var slice_meta: Array = []
	var written := 0
	var t_slices := Time.get_ticks_msec()
	# THE ENCODES GO WIDE. Two decodes and two PNG encodes per slice, run one
	# after another, is what makes this phase sit at "85%" for a minute and a
	# half: a PNG encode at 1024px is not fast, there are two per slice, and
	# nothing about slice 4 depends on slice 3.
	#
	# The decodes stay serial because they read the install and the reader
	# serialises that anyway; the encodes are pure CPU on an Image nobody else
	# holds, so they go to the pool and the phase costs one encode instead of
	# fourteen.
	var pend_img: Array = []
	var pend_path: PackedStringArray = PackedStringArray()
	for s in range(picked.size()):
		var li: int = picked[s]
		var alb := _layer_image(pal.albedo_of(li), false)
		var nrm := _layer_image(pal.normal_of(li), true)
		if alb == null:
			# REPORTED ANYWAY, so a skipped slice cannot stall the readout on
			# the count before it.
			if progress.is_valid():
				progress.call(ST_LAYERS, s + 1, picked.size())
			continue
		if nrm == null:
			# A flat normal rather than dropping the slice: the albedo is the
			# part that carries the look, and Texture2DArray refuses a set with
			# a hole in it.
			nrm = Image.create_empty(LAYER_TEX_DIM, LAYER_TEX_DIM, false,
				Image.FORMAT_RGB8)
			nrm.fill(Color(0.5, 0.5, 1.0))
		pend_img.append(alb)
		pend_path.append("%s/l%02d_alb.png" % [dir_splat, s])
		pend_img.append(nrm)
		pend_path.append("%s/l%02d_nrm.png" % [dir_splat, s])
		written += 1
		slice_meta.append({
			"layer": li,
			"albedo": pal.albedo_of(li).get_file(),
			"metres_per_repeat": pal.metres_per_repeat(li),
			"texels": int(per_layer.get(li, 0)),
		})
		# COUNTED AFTER THE WORK, and one-based. It used to report `s` BEFORE
		# the slice was done, so the last of seven showed 6/7 - "85%" - for the
		# whole time that slice took, and the phase never displayed 100% at
		# all. Both of those read as a hang and neither was one.
		if progress.is_valid():
			progress.call(ST_LAYERS, s + 1, picked.size())
	if not pend_img.is_empty():
		var enc := func(i: int) -> void:
			(pend_img[i] as Image).save_png(pend_path[i])
		var gid := WorkerThreadPool.add_group_task(enc, pend_img.size(),
			HighpolyVitals.work_tasks(pend_img.size()), false,
			"bf6 layer slice png")
		WorkerThreadPool.wait_for_group_task_completion(gid)

	# Two decodes and two PNG encodes per slice, so the per-item figure is what
	# says whether a map with 32 textured layers is going to cost twice what one
	# with 16 does. It does, and this row is where that shows.
	note_phase("ground: layer textures", Time.get_ticks_msec() - t_slices,
		written, "slices", FROM_INSTALL,
		"albedo + normal decoded and written at %dpx" % LAYER_TEX_DIM)

	# Remap the composited layer indices to slice indices. A texel whose layer
	# has no texture is left pointing past the end of the array on purpose: the
	# shader's `id < splat_slices` test then falls back for it, which is the
	# right answer for a shader-computed layer we cannot reproduce.
	#
	# Through a 256-entry lookup rather than a dictionary. This runs over 16.7
	# million bytes; a Dictionary.get per byte is about a minute of GDScript, and
	# a PackedByteArray index is the same answer for free.
	var t_remap := Time.get_ticks_msec()
	var lut := PackedByteArray()
	lut.resize(256)
	lut.fill(255)
	for l in slice_of.keys():
		lut[int(l)] = int(slice_of[l])
	for l in virt_of.keys():
		lut[int(l)] = int(virt_of[l])
	var idx: PackedByteArray = comp["idx"]
	var wgt: PackedByteArray = comp["w"]
	# THE TRUE COVERAGE, KEPT. The loop below overwrites idx IN PLACE through a
	# LUT that collapses every textureless layer to 255 — right for the shader,
	# which can only sample slices it has, and it used to be the only copy: on
	# Tungsten that threw away 27 painted layers' identities to keep 3. The raw
	# palette indices are what per-layer work needs — scatter placement by the
	# game's own painted coverage instead of a satellite-greenness guess, and
	# the per-layer scatter densities after it — and they are in hand RIGHT
	# HERE for the cost of a duplicate and one PNG. (w.png is not mutated, so
	# idx_raw.png + w.png together are the complete true coverage.)
	var idx_raw := idx.duplicate()
	var out_of_slice := 0
	for i in range(idx.size()):
		if wgt[i] == 0:
			idx[i] = 255
		else:
			var s := int(lut[idx[i]])
			idx[i] = s
			if s == 255 and (i & 3) == 0:
				out_of_slice += 1

	# THREE 4096x4096 PNG ENCODES, which do not depend on each other. Encoding
	# them one after another is the same shape that made the layer slices cost
	# ninety seconds; each Image is its own object and each writes its own
	# file, so they go to the pool together.
	var img_idx := Image.create_from_data(sres, sres, false,
		Image.FORMAT_RGBA8, idx)
	var img_w := Image.create_from_data(sres, sres, false,
		Image.FORMAT_RGBA8, wgt)
	var img_raw := Image.create_from_data(sres, sres, false,
		Image.FORMAT_RGBA8, idx_raw)
	var enc_img: Array = [img_idx, img_w, img_raw]
	var enc_path := PackedStringArray(["%s/idx.png" % dir_splat,
		"%s/w.png" % dir_splat, "%s/idx_raw.png" % dir_splat])
	var enc_one := func(i: int) -> void:
		(enc_img[i] as Image).save_png(enc_path[i])
	var enc_gid := WorkerThreadPool.add_group_task(enc_one, enc_img.size(),
		HighpolyVitals.work_tasks(enc_img.size()), false, "bf6 splat png")
	WorkerThreadPool.wait_for_group_task_completion(enc_gid)
	# 16.7 million bytes through a lookup table plus two PNG encodes. It is pure
	# GDScript over a byte array, which is the shape that used to be a minute
	# before the LUT went in, so it is worth a row of its own to keep honest.
	note_phase("ground: slice remap + write", Time.get_ticks_msec() - t_remap,
		idx.size(), "texel bytes", FROM_MEMORY, "idx.png, w.png and idx_raw.png")

	# ---- the slope fallback, also from the game ------------------------------
	var t_fb := Time.get_ticks_msec()
	_write_fallback_layers(pal, picked, "%s/terrain_layers" % cache_dir)
	note_phase("ground: slope fallback", Time.get_ticks_msec() - t_fb,
		picked.size(), "layers", FROM_INSTALL, "terrain_layers/")

	var meta := {
		"slices": written,
		"world": {"x0": sp.root_min.x, "z0": sp.root_min.y,
			"size": sp.root_max.x - sp.root_min.x},
		"cmap_v": CMAP_VERSION,
		"splat_v": SPLAT_VERSION,
		# The linked-layer list, persisted so the near-field window can
		# rasterise the street materials without reloading the palette (the
		# palette's offset search is the expensive part, and the window runs
		# per camera move).
		"linked": _linked_of(pal),
		"colormap": {"file": "colormap.png", "res": cres,
			"x0": sp.root_min.x, "z0": sp.root_min.y,
			"size": sp.root_max.x - sp.root_min.x,
			# The Z span under its own name: the shader's cmap_bounds used the X
			# span for both axes, silently wrong on any non-square footprint.
			"size_z": sp.root_max.y - sp.root_min.y},
		"layers": slice_meta,
		# The computed layers' authored tiling/smoothness, in virtual-id order
		# (id 32 + row index). See the virtual-slice note above.
		"virtual": virt_meta,
		# THE WHOLE PALETTE, not just the textured slices: one row per layer
		# with a NAME the scatter can classify (grass vs gravel), taken from
		# any texture the layer binds - detail and AO slots carry names even
		# when the colour lives in the shader. idx_raw.png's indices mean
		# nothing without this table; together they are the game's own painted
		# coverage, which is what replaces the satellite-greenness guess
		# (task #93). Additive: an old cache without it keeps the heuristic.
		"palette": _palette_rows(pal),
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
		   100.0 * float(out_of_slice) / float(maxi(1, sres * sres))])
	return meta


# The palette layers that resolve through a link, persisted into layers.json
# so the near-field window can rasterise streets without reloading the palette.
static func _linked_of(pal) -> Array:
	var out: Array = []
	for l in pal.layers:
		if int((l as Dictionary)["link"]) >= 0:
			out.append(int((l as Dictionary)["index"]))
	out.sort()
	return out


# ---------------------------------------------------------------------------
# THE NEAR-FIELD DETAIL WINDOW - high definition where the camera is.
#
# The whole-footprint raster tops out at 2 m per texel, and that ceiling is
# VRAM, not data: the game's own weight pages are ~1 m or finer, dropped to
# whatever one flat raster can afford. This recomposites JUST a window around
# the camera from the same pages at 0.5 m per texel - four times the whole-map
# raster, eight times the pre-v4 look - and the shader blends it over the far
# raster inside its bounds. The map context recenters it from a worker task as
# the camera moves, so nothing here may touch the scene or block a frame.
#
# The parsed tree state is kept per source: parsing block 1 and detecting the
# page layout once costs the same as the bake paid, and paying it per recenter
# would put seconds where a quarter of one belongs.
# ---------------------------------------------------------------------------
const NEAR_RES := 2048
const NEAR_SPAN := 1024.0              # metres the window covers (0.5 m/texel)

var _win_state = null                  # Dictionary, or false after a failed open


func _window_state(cache_dir: String):
	if _win_state != null:
		return _win_state if _win_state is Dictionary else null
	_win_state = false
	var meta_path := "%s/splat/layers.json" % cache_dir
	if not FileAccess.file_exists(meta_path):
		return null
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	if not (meta is Dictionary) \
			or int((meta as Dictionary).get("splat_v", 0)) != SPLAT_VERSION:
		return null                    # window density must match the bake's lut
	var pick := ""
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = src.snap_res()
	for rn in t_res.keys():
		var n := str(rn)
		if n.contains("streamingtree") and n.to_lower().contains(level):
			pick = n
			break
	if pick == "":
		return null
	var res := src.get_res(pick)
	if res.is_empty():
		return null
	var t := BF6Terrain.new()
	var b1 := t.find_block(res, 1)
	if b1.is_empty():
		return null
	var sp := BF6Splat.new()
	if not sp.parse(b1):
		return null
	var chunks := t.read_chunk_directory(res)
	if chunks.is_empty() or not sp.detect_layout(chunks):
		return null
	# The SAME palette->slice mapping the bake wrote, reconstructed from its
	# slice rows: a window remapped through a different lut would paint the
	# right ground with the wrong textures inside the window only.
	var lut := PackedByteArray()
	lut.resize(256)
	lut.fill(255)
	var rows: Array = (meta as Dictionary).get("layers", [])
	for s in range(rows.size()):
		var li := int((rows[s] as Dictionary).get("layer", -1))
		if li >= 0 and li < 256:
			lut[li] = s
	var vrows: Array = (meta as Dictionary).get("virtual", [])
	for s in range(vrows.size()):
		var li := int((vrows[s] as Dictionary).get("layer", -1))
		if li >= 0 and li < 256:
			lut[li] = 32 + s
	# THE FAR RASTER IS THE SEED. idx_raw.png + w.png are the bake's complete
	# pre-remap coverage - every coarse page AND the street materials, already
	# merged - so a window upsamples its region of them (a C++ image op) and
	# only the pages FINER than the far raster's density are composited on
	# top. Without this seed every coarse record repainted the whole window
	# through a per-texel insert, 32 s a window; with it a window is the fine
	# pages alone.
	var fi := Image.load_from_file(
		ProjectSettings.globalize_path("%s/splat/idx_raw.png" % cache_dir))
	var fw := Image.load_from_file(
		ProjectSettings.globalize_path("%s/splat/w.png" % cache_dir))
	if fi == null or fw == null or fi.get_width() != fw.get_width():
		return null
	fi.convert(Image.FORMAT_RGBA8)     # the composite arrays are 4 bytes/texel
	fw.convert(Image.FORMAT_RGBA8)
	var wj: Dictionary = (meta as Dictionary).get("world", {})
	_win_state = {"t": t, "sp": sp, "chunks": chunks, "lut": lut,
		"far_idx": fi, "far_w": fw, "far_res": fi.get_width(),
		"wx0": float(wj.get("x0", sp.root_min.x)),
		"wz0": float(wj.get("z0", sp.root_min.y)),
		"wsize": float(wj.get("size", sp.root_max.x - sp.root_min.x))}
	return _win_state


# One recomposited window, centred as near (cx, cz) as the footprint allows.
# Returns {idx: Image, w: Image, x0, z0, size} or {} when the map has no
# usable splat bake. Safe on a worker thread; creates Images, never Textures.
func terrain_window(cache_dir: String, cx: float, cz: float) -> Dictionary:
	var st = _window_state(cache_dir)
	if st == null:
		return {}
	var sp: BF6Splat = st["sp"]
	var span := sp.root_max - sp.root_min
	if span.x <= NEAR_SPAN or span.y <= NEAR_SPAN:
		return {}                      # the far raster already outresolves us
	var half := NEAR_SPAN * 0.5
	var x0 := clampf(cx - half, sp.root_min.x, sp.root_max.x - NEAR_SPAN)
	var z0 := clampf(cz - half, sp.root_min.y, sp.root_max.y - NEAR_SPAN)
	var wmin := Vector2(x0, z0)
	var fetch := func(g): return src.get_chunk(str(g))
	var t0 := Time.get_ticks_msec()
	# Seed from the far raster's window region (C++ ops - milliseconds): it
	# already holds every coarse page and the street materials, merged.
	var far_res := int(st["far_res"])
	var wsize := float(st["wsize"])
	var fx := int((x0 - float(st["wx0"])) / wsize * float(far_res))
	var fz := int((z0 - float(st["wz0"])) / wsize * float(far_res))
	var fspan := maxi(1, int(NEAR_SPAN / wsize * float(far_res)))
	fx = clampi(fx, 0, far_res - fspan)
	fz = clampi(fz, 0, far_res - fspan)
	var seed_i := (st["far_idx"] as Image).get_region(Rect2i(fx, fz, fspan, fspan))
	var seed_w := (st["far_w"] as Image).get_region(Rect2i(fx, fz, fspan, fspan))
	seed_i.resize(NEAR_RES, NEAR_RES, Image.INTERPOLATE_NEAREST)
	seed_w.resize(NEAR_RES, NEAR_RES, Image.INTERPOLATE_NEAREST)
	# Only the pages FINER than the far raster's texel: everything coarser is
	# already in the seed, texel for texel.
	var max_span := (wsize / float(far_res)) * float(BF6Splat.PAGE_SIDE)
	# smooth=true: the window is 4x denser than the pages, and the apron is
	# exactly what makes bilinear page sampling seamless across records.
	var comp := sp.composite(st["chunks"], fetch, NEAR_RES, Callable(),
		wmin, NEAR_SPAN, seed_i.get_data(), seed_w.get_data(), max_span, true)
	if comp.is_empty():
		return {}
	var idx: PackedByteArray = comp["idx"]
	var wgt: PackedByteArray = comp["w"]
	var lut: PackedByteArray = st["lut"]
	for i in range(idx.size()):
		idx[i] = 255 if wgt[i] == 0 else lut[idx[i]]
	_say("game source: near window recomposited at (%.0f, %.0f) in %.1f s"
		% [x0 + half, z0 + half, (Time.get_ticks_msec() - t0) / 1000.0])
	return {
		"idx": Image.create_from_data(NEAR_RES, NEAR_RES, false,
			Image.FORMAT_RGBA8, idx),
		"w": Image.create_from_data(NEAR_RES, NEAR_RES, false,
			Image.FORMAT_RGBA8, wgt),
		"x0": x0, "z0": z0, "size": NEAR_SPAN,
	}


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
# THE GENERIC GROUND MUST BE A NATURAL SURFACE. It used to be the top
# textured layer by coverage, and on mp_aftermath that is COBBLESTONE - and
# because every computed layer tiles the generic ground (the virtual slices
# made that most of the map), the city AND the seabed under its ocean came
# out as bricks. The words are picked in priority order so "grass" beats
# "sand" when both exist, and the architectural surfaces are barred from
# both roles outright: a cobble cliff is as wrong as a cobble seabed.
const FB_NATURAL := ["grass", "dirt", "soil", "mud", "sand", "forest",
	"meadow", "moss", "snow", "gravel"]
const FB_HARD := ["rock", "cliff", "scree", "rubble", "gravel", "stone"]
const FB_EXCLUDE := ["cobble", "asphalt", "concrete", "tile", "brick",
	"paving", "pavement", "curb", "defaulttexture", "debug"]


func _fb_pick(pal, by_area: Array, words: Array, not_this: int) -> int:
	for w in words:
		for l in by_area:
			var i := int(l)
			if i == not_this:
				continue
			var nm: String = pal.albedo_of(i)
			if nm == "":
				continue
			var leaf := nm.get_file().to_lower()
			var barred := false
			for e in FB_EXCLUDE:
				if leaf.contains(e):
					barred = true
					break
			if barred:
				continue
			if leaf.contains(str(w)):
				return i
	return -1


func _write_fallback_layers(pal, by_area: Array, out_dir: String) -> void:
	var ground := _fb_pick(pal, by_area, FB_NATURAL, -1)
	if ground < 0:
		# nothing natural on this map: any non-barred textured layer at all
		ground = _fb_pick(pal, by_area, [""], -1)
	var cliff := _fb_pick(pal, by_area, FB_HARD, ground)
	if ground < 0:
		return
	if cliff < 0:
		cliff = ground
	_say("game source: slope fallback ground=%s cliff=%s" % [
		pal.albedo_of(ground).get_file(), pal.albedo_of(cliff).get_file()])
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
# How far the decal subdivision may go. Each level HALVES the edge length and
# quadruples the triangles, so two levels is a quarter of the step and sixteen
# times the triangles. Held at two because the re-projection pass costs time per
# decal VERTEX, and the user already notices that pass running - buying a finer
# step by making the projection four times longer is a bad trade. The records
# that stay coarse at this cap are the big flat road fills, where there is no
# detail to miss.
const DECAL_SUBDIV_MAX := 3
# Per record, so one enormous fill cannot dominate the whole network.
const DECAL_SUBDIV_MAX_TRIS := 60000

const ROAD_Y_BIAS := 0.01

# COVERAGE IS A SECOND TEXTURE, not an alpha channel, so this cannot be a
# StandardMaterial3D. The markings — lane lines, crosswalks, arrows — live ONLY
# in the `op` slot; without it they paint as solid blocks over the road surface.
#
# The alternative was compositing op into cv's alpha at load. That means
# decompressing two BC7 images, resizing one and writing a million bytes per
# material group in GDScript, for a result a sampler gives away free.
# THE PROJECTOR. Draws the swept volume, not the decal: the decal is wherever
# the depth buffer says the world is inside that volume.
#
# depth_test_disabled is not a trick - the volume is usually BEHIND the surface
# it paints (it starts above the ground and ends below it), so a depth test
# would reject the very fragments that do the work. cull_front picks the back
# faces so each pixel is covered exactly once; drawing both faces would blend
# the decal onto itself and double its opacity.
const ROAD_DECAL_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_front,
	diffuse_burley;
uniform sampler2D cv : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D op : filter_linear_mipmap, repeat_enable;
uniform bool has_cv = false;
uniform bool has_op = false;
uniform bool opaque_alpha = false;
uniform vec4 flat_col : source_color = vec4(0.35, 0.35, 0.35, 1.0);
// THE DEPTH BUFFER, which is the whole mechanism: it is what tells this shader
// where the world actually is. Godot 4 removed the DEPTH_TEXTURE built-in in
// favour of a hinted uniform. filter_nearest because a depth value must be read
// exactly - interpolating between two depths invents a surface that is at
// neither, and the reconstructed position would drift at every silhouette.
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

// The triangle this prism was swept from, constant across all six of its
// vertices: plan-view corners, the height band, and the authored UV at each
// corner. CUSTOM channels rather than uniforms because every triangle in a
// material group carries different ones and they draw in a single call.
varying flat vec4 tri_ab;      // A.x A.z B.x B.z
varying flat vec4 tri_c_band;  // C.x C.z  ybot ytop
varying flat vec4 uv_ab;       // uvA.xy uvB.xy
varying flat vec4 uv_c_fade;   // uvC.xy  packed corner alphas, spare

void vertex() {
	tri_ab = CUSTOM0;
	tri_c_band = CUSTOM1;
	uv_ab = CUSTOM2;
	uv_c_fade = CUSTOM3;
}

void fragment() {
	// WHERE THE WORLD ACTUALLY IS at this pixel. Everything else follows from
	// this one reconstruction; nothing depends on where the prism itself sits.
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	view.xyz /= view.w;
	vec3 w = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;

	// IS IT IN THE BAND. This is the rooftop guard: a record authored on a deck
	// carries a band around that deck, so the street underneath is outside it
	// and receives nothing.
	if (w.y < tri_c_band.z || w.y > tri_c_band.w) discard;

	// IS IT INSIDE THE TRIANGLE, in plan view. Same barycentric solve the
	// projector's geometry pass uses, done per pixel against the real surface.
	vec2 a = tri_ab.xy;
	vec2 b = tri_ab.zw;
	vec2 c = tri_c_band.xy;
	float den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
	if (abs(den) < 1e-9) discard;
	float w0 = ((b.y - c.y) * (w.x - c.x) + (c.x - b.x) * (w.z - c.y)) / den;
	float w1 = ((c.y - a.y) * (w.x - c.x) + (a.x - c.x) * (w.z - c.y)) / den;
	float w2 = 1.0 - w0 - w1;
	if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) discard;

	// The weights that proved containment are the same ones that place the
	// texture, so the art lands exactly where the authored spline put it.
	vec2 uvp = uv_ab.xy * w0 + uv_ab.zw * w1 + uv_c_fade.xy * w2;

	// The authored edge fade, three corner alphas packed into one float
	// because the four CUSTOM channels were full.
	float p = uv_c_fade.z;
	float f2 = floor(p / 65536.0);
	float rem = p - f2 * 65536.0;
	float f1 = floor(rem / 256.0);
	float f0 = rem - f1 * 256.0;
	float fade = (f0 * w0 + f1 * w1 + f2 * w2) / 255.0;

	vec4 col = has_cv ? texture(cv, uvp) : flat_col;
	ALBEDO = col.rgb * COLOR.rgb;
	ALPHA = (opaque_alpha ? 1.0 : (has_op ? texture(op, uvp).r : col.a)) * fade;
	// The surface underneath is what is being painted, and its normal is not
	// recoverable here. Up is the honest approximation for road markings and
	// keeps them lit like the ground they sit on rather than flat-bright.
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
}
"""

# OFF UNTIL IT CAN BE RUN BEFORE IT SHIPS.
#
# The projector locked the editor at 92 percent of the terrain build. The cause
# is NOT known - reading the code found nothing, and the two theories that felt
# obvious were both tested and both wrong (packed arrays pass by reference, so
# the emit is not quadratic; _say is already thread-safe off the main thread).
# Shipping a fourth guess would cost another rebuild to disprove.
#
# The drape has its own defect - the clamp against the authored AABB band holds
# decals up where our terrain sits lower than the terrain they were compiled on,
# which is the floating the user reported - but it WORKS, and a map with some
# decals too high beats an editor that will not finish a build.
const ROADS_PROJECTED := false

# How far a ground record's volume reaches DOWN to find our terrain. This is
# the number that undoes the floating: the authored band stops at the height
# the decal was compiled at, and our rebuilt ground can sit below it.
const PROJECT_DOWN := 6.0
# And up, to catch a sidewalk slab or kerb standing proud of the terrain.
const PROJECT_UP := 1.5
# A record whose authored floor stands this far above our terrain was authored
# on a deck or a roof, not on the ground, so its volume stays tight to itself.
const ELEVATED_OVER := 2.0

const ROAD_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley;
// HELD OFF THE SURFACE ALONG THE LINE OF SIGHT, not upward. A vertical lift
// buys almost no depth separation at the grazing angles a road is normally
// seen at, so the ground pokes through the markings; a few centimetres toward
// the camera separates them by the same amount at every angle and moves the
// decal's apparent position by almost nothing, because the shift is along the
// direction it is being viewed from. The roads mesh is authored in world
// space, so VERTEX here is already world.
uniform float view_bias = 0.04;
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX += normalize(CAMERA_POSITION_WORLD - w) * view_bias;
}
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
	// The authored per-vertex RGBA multiplies in; its alpha is the edge
	// fade (mud strips feathering out), its rgb an occasional tint.
	ALBEDO = c.rgb * COLOR.rgb;
	// R, not A. Of this map's 33 op textures, 30 vary on R and one on A.
	ALPHA = (opaque_alpha ? 1.0 : (has_op ? texture(op, UV).r : c.a)) * COLOR.a;
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
	# PER CALL. Left accumulating, this reported the sum of every run this
	# session as though it were one build's triangle count.
	_road_subdiv_tris = 0
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
	var gfirst := {}                     # group key -> earliest record index
	var ri := -1
	for r in td.records:
		ri += 1
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
			gfirst[key] = ri
		(groups[key] as Array).append(rec)

	# A TOTAL DRAW ORDER, not two classes. Every group needs its OWN priority:
	# two coplanar detail decals (a manhole over a mud strip) that share one
	# priority are a sorting tie, and Godot breaks transparent-draw ties by
	# nothing stable - the overlap shimmers as the camera moves. The order
	# within each class is the authored record sequence (earliest record
	# first), which is the only ordering the file carries; fills still go
	# under all detail. Priorities stay negative so the water overlays
	# (priority 1 and 2) keep drawing over flooded roads.
	var fills: Array = []
	var detail: Array = []
	for key in groups:
		(fills if str(key).begins_with("layer:") else detail).append(key)
	fills.sort_custom(func(a, b): return int(gfirst[a]) < int(gfirst[b]))
	detail.sort_custom(func(a, b): return int(gfirst[a]) < int(gfirst[b]))
	var gprio := {}
	var rank := 0
	for key in fills + detail:
		gprio[key] = mini(-100 + rank, -1)
		rank += 1

	var am := ArrayMesh.new()
	var tris := 0
	for key in groups:
		var recs: Array = groups[key]
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		var cols := PackedColorArray()
		# The projector's per-triangle constants (four vec4 per vertex) and a
		# real index buffer: a prism is six vertices and twenty-four indices,
		# where emitting it unindexed would be twenty-four vertices.
		var custom := PackedFloat32Array()
		var idx := PackedInt32Array()
		# THE AUTHORED HEIGHT BAND, per vertex, so it survives into the merged
		# mesh. The projector runs at the end of the objects build, long after
		# the records are gone, and without this it has no way to tell a
		# sidewalk slab from a crate lid. UV2 because no road shader reads it.
		var bands := PackedVector2Array()
		for r in recs:
			var rec: Dictionary = r
			var vs := td.vertices(rec)
			var n := vs.size() / 8
			# A record whose vertex count disagrees with its triangle count means
			# the VB is being read at the wrong place, and a wrong VB still
			# produces plausible floats. Dropped rather than drawn as confetti.
			if n != int(rec["tri_count"]) * 3:
				continue
			# THE STORED UVS ARE THE ANSWER - decoded 2026-08-10. Every vertex
			# carries full f32 (u across, v along-the-spline) at +0x10/+0x14;
			# emit UV = (v, u) and the stripes follow every curve. The old
			# stamp-vs-fill split and the per-record direction projection were
			# workarounds for a misread of these very bytes (the "1.875
			# normaliser" was f32 1.0's top half decoded as f16). The one real
			# regime split left is PLANAR fills, which store world X/Z verbatim
			# and tile at Tiling0/Tiling1 metres.
			var planar := BF6Decals.is_planar(vs)
			var t0 := float(rec["tiling0"])
			if absf(t0) < 1e-3:
				t0 = 10.0
			var t1 := float(rec["tiling1"])
			if absf(t1) < 1e-3:
				t1 = t0
			# THE RECORD'S AABB-Y IS THE DRAPE BAND, verified fleet-wide
			# 2026-08-10 (96% of records track it within 0.15 m; 9 aftermath /
			# 11 dumbo / 23 abbasid records are ELEVATED - authored on rooftops
			# and decks, 13-17% bit-exact flat planes). Terrain-only draping
			# put aftermath's rooftop tennis court 10.9 m down inside its
			# building; clamping the sampled ground into the band puts every
			# street exactly where it was and lifts the elevated records onto
			# their decks.
			var ylo := float((rec["aabb_min"] as Vector3).y)
			var yhi := float((rec["aabb_max"] as Vector3).y)
			# IS THIS RECORD ACTUALLY OFF THE GROUND? Only an elevated one may
			# be clamped into its authored band; for anything else the clamp
			# holds the decal in the air wherever our terrain came out lower
			# than the terrain it was compiled on. Decided from the ground we
			# actually built, once per record.
			var gnd_hi := -INF
			for i in range(n):
				gnd_hi = maxf(gnd_hi, _height_at(vs[i * 8], vs[i * 8 + 1]))
			var elevated := ylo - gnd_hi > ELEVATED_OVER
			# THE TERRAIN'S STEP, NOT THE DECAL'S. Draping only moves vertices,
			# so a ribbon two metres between vertices runs straight across
			# ground the terrain draws with several. Subdivide first, then
			# every new vertex gets draped too.
			var lvl := _decal_subdiv(vs)
			if lvl > 0:
				vs = _subdivide_tris(vs, lvl)
				n = vs.size() / 8
				_road_subdiv_tris += n / 3
			if ROADS_PROJECTED:
				# THE VOLUME THIS RECORD MAY PROJECT INTO. Decided per record
				# from OUR terrain, not from the authored band alone, because
				# the two disagreeing is the whole reason decals floated.
				var tlo := INF
				var thi := -INF
				for i in range(n):
					var h := _height_at(vs[i * 8], vs[i * 8 + 1])
					tlo = minf(tlo, h)
					thi = maxf(thi, h)
				var ybot: float
				var ytop: float
				if ylo - thi > ELEVATED_OVER:
					# Authored on a deck or a roof. Tight to its own geometry so
					# the street below it receives nothing.
					ybot = ylo - 1.0
					ytop = yhi + PROJECT_UP
				else:
					ybot = minf(ylo, tlo) - PROJECT_DOWN
					ytop = maxf(yhi, thi) + PROJECT_UP
				var ti := 0
				while ti + 2 < n:
					_emit_prism(verts, uvs, cols, custom, idx, vs, ti,
						planar, t0, t1, ybot, ytop)
					ti += 3
				continue
			for i in range(n):
				var x := vs[i * 8]
				var z := vs[i * 8 + 1]
				# THE GROUND, not the authored band. The band only gets a say
				# for a record that is genuinely on a deck or a roof, where it
				# is the only thing that knows the decal is not on the ground.
				var gh := _height_at(x, z)
				verts.push_back(Vector3(x,
					(clampf(gh, ylo, yhi) if elevated else gh)
						+ ROAD_Y_BIAS, z))
				# TEXTURE X IS ACROSS, TEXTURE Y IS ALONG. The art is authored
				# with the road's length running down the sheet, so the stored
				# across-u samples texture x and along-v samples texture y.
				# The transposed emit drew every stripe 90 degrees off -
				# user-verified on the live map, which outranks any notation.
				if planar:
					uvs.push_back(Vector2(x / t1, z / t0))
				else:
					uvs.push_back(Vector2(vs[i * 8 + 2], vs[i * 8 + 3]))
				# Vertex RGBA rides along; alpha is the authored edge fade
				# (mud strips feathering into the ground).
				cols.push_back(Color(vs[i * 8 + 4], vs[i * 8 + 5],
					vs[i * 8 + 6], vs[i * 8 + 7]))
				bands.push_back(Vector2(ylo, yhi))
		if verts.is_empty():
			continue
		if not ROADS_PROJECTED:
			idx.resize(verts.size())
			for i in range(verts.size()):
				idx[i] = i
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_TEX_UV] = uvs
		arr[Mesh.ARRAY_COLOR] = cols
		arr[Mesh.ARRAY_INDEX] = idx
		if bands.size() == verts.size():
			arr[Mesh.ARRAY_TEX_UV2] = bands
		var sflags := 0
		if ROADS_PROJECTED:
			# Four RGBA_FLOAT custom channels, split out of one flat buffer.
			# The shader reads them as CUSTOM0..CUSTOM3.
			arr[Mesh.ARRAY_CUSTOM0] = _custom_slice(custom, 0)
			arr[Mesh.ARRAY_CUSTOM1] = _custom_slice(custom, 1)
			arr[Mesh.ARRAY_CUSTOM2] = _custom_slice(custom, 2)
			arr[Mesh.ARRAY_CUSTOM3] = _custom_slice(custom, 3)
			sflags = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT
					<< Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT
					<< Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT
					<< Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
				| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT
					<< Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
			sflags)
		am.surface_set_material(am.get_surface_count() - 1,
			_road_material(str(key), int(gprio[key])))
		# Indices, not vertices: a prism shares six vertices across eight
		# triangles, so counting vertices would under-report it fourfold.
		tris += (idx.size() / 3) if ROADS_PROJECTED else (verts.size() / 3)
	road_stats["groups"] = am.get_surface_count()
	road_stats["subdivided_triangles"] = _road_subdiv_tris
	road_stats["drawn_triangles"] = tris
	if am.get_surface_count() == 0:
		return null
	if _road_subdiv_tris > 0:
		_say(("game source: roads — subdivided to the terrain's own step "
			+ "(%.1f m), %d triangles from %d authored")
			% [maxf(1.0, float(drape_step)), _road_subdiv_tris, td.total_tris])
	_say("game source: roads — %d records in %d material group(s), %d triangles%s"
		% [td.records.size(), am.get_surface_count(), tris,
		   "" if int(td.truncated_at) < 0
		   else "  (TRUNCATED at record %d — partial)" % td.truncated_at])
	return am


# One decal triangle -> one prism, swept through the band it may project into.
#
# Six vertices and twenty-four indices: the two triangle caps and three quad
# sides. The positions are the ONLY thing that varies between them; all six
# carry the same per-triangle constants, because the fragment shader needs the
# whole triangle to solve any pixel of it.
func _emit_prism(verts: PackedVector3Array, uvs: PackedVector2Array,
		cols: PackedColorArray, custom: PackedFloat32Array,
		idx: PackedInt32Array, vs: PackedFloat32Array, ti: int,
		planar: bool, t0: float, t1: float, ybot: float, ytop: float) -> void:
	var ax := vs[(ti) * 8]
	var az := vs[(ti) * 8 + 1]
	var bx := vs[(ti + 1) * 8]
	var bz := vs[(ti + 1) * 8 + 1]
	var cx := vs[(ti + 2) * 8]
	var cz := vs[(ti + 2) * 8 + 1]
	# A triangle with no area in plan view can never contain a surface point,
	# so it would discard every pixel it drew. Dropped instead of drawn.
	var den := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
	if absf(den) < 1e-9:
		return
	var ua: Vector2
	var ub: Vector2
	var uc: Vector2
	if planar:
		ua = Vector2(ax / t1, az / t0)
		ub = Vector2(bx / t1, bz / t0)
		uc = Vector2(cx / t1, cz / t0)
	else:
		ua = Vector2(vs[(ti) * 8 + 2], vs[(ti) * 8 + 3])
		ub = Vector2(vs[(ti + 1) * 8 + 2], vs[(ti + 1) * 8 + 3])
		uc = Vector2(vs[(ti + 2) * 8 + 2], vs[(ti + 2) * 8 + 3])
	# The three corner alphas packed into one float: the four CUSTOM channels
	# were already full, and 24-bit integers are exact in a float32.
	var fa := int(round(clampf(vs[(ti) * 8 + 7], 0.0, 1.0) * 255.0))
	var fb := int(round(clampf(vs[(ti + 1) * 8 + 7], 0.0, 1.0) * 255.0))
	var fc := int(round(clampf(vs[(ti + 2) * 8 + 7], 0.0, 1.0) * 255.0))
	var fade := float(fa + fb * 256 + fc * 65536)
	# The occasional authored rgb tint, flat across the triangle. Only the
	# alpha varies meaningfully corner to corner, and only alpha got a slot.
	var tint := Color(
		(vs[(ti) * 8 + 4] + vs[(ti + 1) * 8 + 4] + vs[(ti + 2) * 8 + 4]) / 3.0,
		(vs[(ti) * 8 + 5] + vs[(ti + 1) * 8 + 5] + vs[(ti + 2) * 8 + 5]) / 3.0,
		(vs[(ti) * 8 + 6] + vs[(ti + 1) * 8 + 6] + vs[(ti + 2) * 8 + 6]) / 3.0,
		1.0)
	var base := verts.size()
	for k in range(6):
		var top := k < 3
		var y := ytop if top else ybot
		match k % 3:
			0: verts.push_back(Vector3(ax, y, az))
			1: verts.push_back(Vector3(bx, y, bz))
			_: verts.push_back(Vector3(cx, y, cz))
		uvs.push_back(ua)
		cols.push_back(tint)
		custom.append_array(PackedFloat32Array([
			ax, az, bx, bz,
			cx, cz, ybot, ytop,
			ua.x, ua.y, ub.x, ub.y,
			uc.x, uc.y, fade, 0.0]))
	# Caps then sides. Winding is consistent so cull_front keeps exactly one
	# face per pixel; the volume must be closed for that to hold.
	idx.append_array(PackedInt32Array([
		base + 0, base + 1, base + 2,
		base + 5, base + 4, base + 3,
		base + 0, base + 4, base + 1, base + 0, base + 3, base + 4,
		base + 1, base + 5, base + 2, base + 1, base + 4, base + 5,
		base + 2, base + 3, base + 0, base + 2, base + 5, base + 3]))


# Pull one RGBA_FLOAT channel out of the interleaved sixteen-float record.
# Godot wants each CUSTOM channel as its own tightly packed array.
func _custom_slice(custom: PackedFloat32Array, ch: int) -> PackedFloat32Array:
	var n := custom.size() / 16
	var out := PackedFloat32Array()
	out.resize(n * 4)
	for i in range(n):
		var s := i * 16 + ch * 4
		var d := i * 4
		out[d] = custom[s]
		out[d + 1] = custom[s + 1]
		out[d + 2] = custom[s + 2]
		out[d + 3] = custom[s + 3]
	return out


# Triangles emitted after subdivision, for the log. A subdivision that quietly
# did nothing and one that worked look identical on screen.
var _road_subdiv_tris := 0


# How many times to halve this record's edges to reach the terrain's step.
#
# PER RECORD, NOT PER TRIANGLE, and that is a correctness requirement rather
# than a shortcut: midpoint subdivision splits all three edges, so two triangles
# sharing an edge agree on the vertices along it only if they subdivided the
# same number of times. Different levels either side of an edge is a crack.
func _decal_subdiv(vs: PackedFloat32Array) -> int:
	# CLAMPED, not just floored. drape_step is the terrain's lattice and one of
	# the user's builds reported it at EIGHT METRES; a decal triangle that
	# coarse cannot follow a kerb 0.15 m high, so it cuts through or floats
	# over whatever it crosses. One to two metres follows a kerb closely enough
	# that the remaining bend reads as a chamfer.
	var target := clampf(float(drape_step), 1.0, 2.0)
	var longest := 0.0
	var i := 0
	while i + 2 < vs.size() / 8:
		for e in [[0, 1], [1, 2], [2, 0]]:
			var a: int = (i + e[0]) * 8
			var b: int = (i + e[1]) * 8
			var dx := vs[a] - vs[b]
			var dz := vs[a + 1] - vs[b + 1]
			longest = maxf(longest, sqrt(dx * dx + dz * dz))
		i += 3
	if longest <= target:
		return 0
	var lvl := int(ceil(log(longest / target) / log(2.0)))
	lvl = clampi(lvl, 0, DECAL_SUBDIV_MAX)
	# BOUNDED, and it drops a level rather than refusing: a huge fill record
	# would otherwise turn 4,000 triangles into a quarter of a million on its
	# own, for ground that is flat anyway.
	var tris := vs.size() / 24
	while lvl > 0 and tris * int(pow(4, lvl)) > DECAL_SUBDIV_MAX_TRIS:
		lvl -= 1
	return lvl


# Midpoint subdivision in the decal's own 8-float vertex layout (x, z, u, v,
# r, g, b, a). Every attribute interpolates linearly, which is exact: the
# stored spline UVs and the planar world-XZ UVs are both affine within a
# triangle, so a midpoint vertex lands where the authored art says it does.
func _subdivide_tris(vs: PackedFloat32Array, level: int) -> PackedFloat32Array:
	var cur := vs
	for _pass in range(level):
		var out := PackedFloat32Array()
		out.resize(cur.size() * 4)
		var w := 0
		var i := 0
		while (i + 3) * 8 <= cur.size():
			var a := i * 8
			var b := (i + 1) * 8
			var c := (i + 2) * 8
			var ab := PackedFloat32Array()
			var bc := PackedFloat32Array()
			var ca := PackedFloat32Array()
			ab.resize(8)
			bc.resize(8)
			ca.resize(8)
			for k in range(8):
				ab[k] = (cur[a + k] + cur[b + k]) * 0.5
				bc[k] = (cur[b + k] + cur[c + k]) * 0.5
				ca[k] = (cur[c + k] + cur[a + k]) * 0.5
			for tri in [[a, -1, -2], [-1, b, -3], [-2, -3, c], [-1, -3, -2]]:
				for slot in tri:
					var src: PackedFloat32Array
					var off := 0
					match slot:
						-1: src = ab
						-2: src = ca
						-3: src = bc
						_:
							src = cur
							off = slot
					for k in range(8):
						out[w] = src[off + k]
						w += 1
			i += 3
		out.resize(w)
		cur = out
	return cur


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


func _road_material(key: String, priority := -1) -> Material:
	# KEYED ON THE CODE, NOT ON NULLNESS. The game source outlives a rebuild, so
	# a shader built once was reused for the rest of the session no matter what
	# changed - which is how the projector's volumes ended up being drawn by the
	# drape shader, as solid grey boxes.
	var _want := ROAD_DECAL_SHADER if ROADS_PROJECTED else ROAD_SHADER
	if _road_shader == null or _road_shader.code != _want:
		_road_shader = Shader.new()
		_road_shader.code = _want
		_say("game source: roads use the %s shader"
			% ("PROJECTOR (decals land on whatever surface is under them)"
				if ROADS_PROJECTED else "drape (decals are geometry on the "
					+ "heightfield)"))
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
	# So: fills under detail - and every GROUP on its own rung within that
	# (see roads(): the rung comes from the authored record order, and a
	# shared rung is a sorting tie that shimmers).
	mat.render_priority = clampi(priority, -128, -1)
	# The terrain-layer route. The palette is the same one the ground reads, so
	# a pavement decal and the pavement under it are painted from one source
	# rather than two that can disagree.
	if key.begins_with("layer:"):
		var li := int(key.substr(6))
		var alb = _road_layer_albedo(li)
		if alb != null:
			mat.set_shader_parameter("cv", alb)
			mat.set_shader_parameter("has_cv", true)
		# Full coverage: the layer carries no `_op` of its own (checked - the
		# four layers these records point at bind only cv/ao/nhs) and its
		# basecolor alpha is a blend field rather than a mask.
		mat.set_shader_parameter("opaque_alpha", true)
		# NAMED, so the decal projector does not have to re-derive this from a
		# shader uniform. A fill is the road SURFACE and must stay on the
		# ground: it draws opaque, so projecting one onto a prop repaints that
		# prop instead of marking it.
		mat.resource_name = "bf6_road_fill"
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
	mat.resource_name = "bf6_road_mark"
	return mat


# Bilinear world height, the same formula the terrain build uses.
# Metres per terrain vertex, in texels of the height grid. Set by the map
# context from its own `terrain_step` so the drape and the mesh cannot drift
# apart; 2 is that context's default.
var drape_step := 2

# THE ADAPTIVE LATTICE, computed once while the heights are resident (they
# are released after the roads drape) and read by BOTH consumers: the map
# context's terrain mesh build takes this table instead of scanning again,
# and _height_at picks each sample's step from it - so the drape evaluates
# the exact triangles the sharpened cliff tiles draw. Same classification
# as the mesh build by construction, because this IS the mesh build's table.
const TILE_CHUNKS := 16
var _tsteps := PackedInt32Array()
var _tcpx := 0

# This session's assembled colour map, so consumers never wait on (or race)
# the background PNG write that persists it for the next session.
var _cmap_mem: Image = null
var _cmap_mem_level := ""


func colormap_image(map: String) -> Image:
	return _cmap_mem if _cmap_mem_level == map.to_lower() else null


func tile_steps() -> Dictionary:
	return {"steps": _tsteps, "cpx": _tcpx}


func _build_tile_steps() -> void:
	_tsteps = PackedInt32Array()
	_tcpx = 0
	var res: int = int(_hm.get("res", 0))
	var d: PackedByteArray = _hm.get("data", PackedByteArray())
	if res < 33 or d.size() < res * res * 2:
		return
	var base := maxi(1, int(round(float(res - 1) / 2048.0)))
	var cpx := int(ceil(float(res - 1) / float(TILE_CHUNKS)))
	cpx = int(ceil(float(cpx) / 16.0)) * 16
	var yscale := float(_hm.get("scale", 1.0)) / 65535.0
	var curv := PackedFloat32Array()
	curv.resize(TILE_CHUNKS * TILE_CHUNKS)
	var lat := int(float(res - 1) / float(base))
	for gz in range(1, lat):
		var pz := gz * base
		var row := pz * res
		var ti_row := int(float(pz) / float(cpx)) * TILE_CHUNKS
		for gx in range(1, lat):
			var px := gx * base
			var h0 := float(d.decode_u16((row + px) * 2))
			var cxv := absf(float(d.decode_u16((row + px - base) * 2))
				+ float(d.decode_u16((row + px + base) * 2)) - 2.0 * h0)
			var czv := absf(float(d.decode_u16((row - base * res + px) * 2))
				+ float(d.decode_u16((row + base * res + px) * 2)) - 2.0 * h0)
			var c := maxf(cxv, czv) * yscale
			var ti := ti_row + int(float(px) / float(cpx))
			if c > curv[ti]:
				curv[ti] = c
	var steps := PackedInt32Array()
	steps.resize(TILE_CHUNKS * TILE_CHUNKS)
	var ranked: Array = []
	for i in range(curv.size()):
		steps[i] = base
		if curv[i] > 2.0:
			ranked.append(i)
	ranked.sort_custom(func(a, b): return curv[a] > curv[b])
	if base >= 4:
		for j in range(ranked.size()):
			var i2: int = ranked[j]
			if j < 12 and curv[i2] > 3.0:
				steps[i2] = maxi(int(float(base) / 4.0), 2)
			elif j < 44:
				steps[i2] = maxi(int(float(base) / 2.0), 2)
	for i in range(curv.size()):
		if curv[i] < 0.12 and steps[i] == base:
			steps[i] = mini(base * 2, 16)
	_tsteps = steps
	_tcpx = cpx


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
	var fx: float = clampf((x - wmin) / span * (res - 1), 0.0, res - 1.001)
	var fz: float = clampf((z - wmin) / span * (res - 1), 0.0, res - 1.001)
	# THE TILE'S OWN STEP, not one step for the map. The terrain mesh is
	# adaptive - cliff tiles draw at 2-4x finer vertices - and a drape that
	# keeps evaluating the base lattice diverges from the drawn surface by
	# exactly the error the sharpening removed: on the steep tiles the road
	# ribbons sank into or floated over the sharpened ground. tile_steps()
	# is the ONE table both the mesh build and this drape read.
	var st: int = maxi(1, drape_step)
	if not _tsteps.is_empty() and _tcpx > 0:
		var ti := clampi(int(fz / float(_tcpx)), 0, TILE_CHUNKS - 1) \
			* TILE_CHUNKS + clampi(int(fx / float(_tcpx)), 0, TILE_CHUNKS - 1)
		st = maxi(1, int(_tsteps[ti]))
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
	# Snapshot: walking the live member races the catalogue republish.
	var t_ebx: Dictionary = src.snap_ebx()
	for k in t_ebx.keys():
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


# ---------------------------------------------------------------------------
# THE RIVER, out of terrain streaming-tree BLOCK 2.
#
# Block 2 is a second, ABSOLUTE-Y u16 heightfield: the water surface, decoded
# with block 0's own codec (u16/65536 x WorldSizeY). It was mislabeled
# "density" from an engine binder slot name, which is why no water search ever
# looked at it - while the user could SEE the river in game. Measured
# (MAP-TUNGSTEN.md §U): every decoded sample lands inside its node's stored
# AABB-Y band, the water-above-ground raster reproduces the braided channels
# one-for-one, the level descends monotonically downstream (76.4 -> 66.9 m),
# and on Eastwood the wet plateaus match the LakeData authored levels to the
# centimetre. Dry texels hold a constant fill just below the terrain floor, so
# the wet mask is simply "above the fill".
#
# Ships on tungsten, eastwood and isolated; every other map has no block 2 and
# returns {} here, which costs one find_block call.
#
# -> {"mesh": ArrayMesh, "y0", "y1", "wet_km2"} or {}
# ---------------------------------------------------------------------------
const WATER_GRID := 1024               # ~4 m per sample on a 4 km map: the
                                       # water surface is smooth, unlike ground

func terrain_water(cache_dir := "") -> Dictionary:
	if src == null:
		return {}
	var pick := ""
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = src.snap_res()
	for rn in t_res.keys():
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
	var b2 := t.find_block(res, BF6Terrain.BLOCK_DENSITY)
	if b2.is_empty():
		return {}                      # no block 2: this map's water is elsewhere
	if not t.read_block_header(b2) or not t.walk_nodes(b2):
		return {}
	var dir := t.read_chunk_directory(res)
	if dir.is_empty():
		return {}
	# The block-2 payload is NOT at the chunk head: the primary chunk is
	# [block-0][pages][block-2][tiles]. The wrapped fetch hands resolve_external
	# the block-2 window as if it were the whole chunk, picked from the tail
	# candidates by which slice's interior u16s scale into the node's own
	# stored AABB-Y band - pages and tiles do not.
	var band := {}
	for n in t.nodes:
		var nd: Dictionary = n
		if not nd["external"]:
			continue
		var e = dir.get(int(nd["key"]))
		if e == null:
			continue
		var g := str((e as Dictionary)["primary"])
		var yb := Vector2((nd["min"] as Vector3).y, (nd["max"] as Vector3).y)
		band[g] = yb
		band[BF6Terrain._reverse_guid(g)] = yb
	var xs := t.xs
	var dsz := t.data_size
	var wy := t.world_size_y
	var want := xs * xs * 2
	var fetch2 := func(g) -> PackedByteArray:
		var gs := str(g)
		if not band.has(gs):
			return PackedByteArray()   # a paired chunk: block 2 has none
		var raw: PackedByteArray = src.get_chunk(gs)
		if raw.size() < 2 * dsz:
			return PackedByteArray()   # single-payload chunk: block 0 only
		var yb: Vector2 = band[gs]
		var lo16 := int(maxf(0.0, (yb.x - 0.5) / wy * 65536.0))
		var hi16 := int(minf(65535.0, (yb.y + 0.5) / wy * 65536.0))
		var best_off := -1
		var best := -1.0
		# Every colour-trailer size any map family ships (BC7 68/132/260, BC1
		# 132, the granite mixed pair, the mip pair) - mp_isolated's tails are
		# {8712, 26136} and the original short list dropped ALL of its nodes
		# (RESEARCH-WATER2.md). The in-band score still decides.
		for tail in [0, 4624, 8712, 17424, 26136, 34848, 67600, 85024]:
			var off: int = raw.size() - int(tail) - dsz
			if off < dsz:
				continue
			var okn := 0
			var cnt := 0
			var j := 4
			while j < xs - 4:
				var i := 4
				while i < xs - 4:
					var v := raw.decode_u16(off + (j * xs + i) * 2)
					if v >= lo16 and v <= hi16:
						okn += 1
					cnt += 1
					i += 13
				j += 13
			var f := float(okn) / maxf(1.0, float(cnt))
			if f > best:
				best = f
				best_off = off
		if best_off < 0 or best < 0.9:
			return PackedByteArray()
		return raw.slice(best_off, best_off + want)
	# EXTERNAL NODES ONLY, exactly as the discovery probes measured. Inline
	# block-2 payloads bypass the per-node AABB-Y vetting the wrapped fetch
	# applies, and letting them into the composite painted junk water at
	# 522 m over the mountains. The externals are the river; a node the game
	# did not spill to a chunk carries no water worth trusting.
	for n0 in t.nodes:
		var nd0: Dictionary = n0
		if not bool(nd0["external"]):
			nd0["values"] = PackedByteArray()
	t.resolve_external(dir, fetch2)
	var g := t.composite(WATER_GRID)
	if g.is_empty():
		return {}
	# WET = WATER ABOVE GROUND, per texel, never a modal fill. The first cut
	# clipped against the map's most common block-2 value plus half a metre,
	# which RESEARCH-WATER2.md measured failing in both directions: eastwood
	# over-selects 113x (3.4 vs 0.03 km2) because its dry fill sits far below
	# its many small ponds, and mp_isolated's water VANISHES entirely because
	# its dry fill IS the water level (a flat 100.5 m fjord). The ground is
	# right there in height_game.r16 - the block-0 heightfield #72 caches -
	# and block2 > block0 + 2 cm is the same test the probes validated the
	# discovery with.
	var grid: PackedByteArray = g["data"]
	var gnd := PackedByteArray()
	var gres := 0
	var gmin := 0.0
	var gspan := 1.0
	var gscale := 1.0
	if cache_dir != "":
		var mv: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			"%s/height_game.json" % cache_dir))
		if mv is Dictionary:
			var md: Dictionary = mv
			gnd = FileAccess.get_file_as_bytes("%s/height_game.r16" % cache_dir)
			gres = int(md.get("res", 0))
			gmin = float(md.get("world_min", 0.0))
			gspan = float(md.get("world_max", 0.0)) - gmin
			gscale = float(md.get("scale", 1.0))
			if gres <= 1 or gnd.size() != gres * gres * 2:
				gnd = PackedByteArray()
	if gnd.is_empty():
		# No ground grid to clip against (the heightfield has not been built
		# for this map yet). Refusing is honest; the water layer asks again
		# after the terrain exists, and a wrong clip is worse than a late one.
		_say("game source: block-2 water present but the terrain heightfield "
			+ "is not built yet - switch Extended Terrain on first")
		return {}
	var ground_at := func(wx: float, wz: float) -> float:
		var fx := clampf((wx - gmin) / gspan, 0.0, 1.0) * float(gres - 1)
		var fz := clampf((wz - gmin) / gspan, 0.0, 1.0) * float(gres - 1)
		var x0i := int(fx)
		var z0i := int(fz)
		var x1i := mini(x0i + 1, gres - 1)
		var z1i := mini(z0i + 1, gres - 1)
		var tx := fx - float(x0i)
		var tz := fz - float(z0i)
		var h00 := float(gnd.decode_u16((z0i * gres + x0i) * 2))
		var h10 := float(gnd.decode_u16((z0i * gres + x1i) * 2))
		var h01 := float(gnd.decode_u16((z1i * gres + x0i) * 2))
		var h11 := float(gnd.decode_u16((z1i * gres + x1i) * 2))
		return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz) \
			* gscale / 65535.0
	var lo: Vector3 = g["min"]
	var hi: Vector3 = g["max"]
	# The block-2 ROOT's own AABB-Y is the authored envelope of every water
	# level on the map (tungsten 64.0..76.5, isolated 100.5..109.1, eastwood's
	# lakes inside 215..238). Values outside it are stray texels in coarse
	# nodes - one on tungsten claimed a 50 m-deep lake on a mountainside at
	# 522 m, inside its node's band but outside the root's.
	var env_lo := lo.y - 0.5
	var env_hi := hi.y + 0.5
	var step_x := (hi.x - lo.x) / float(WATER_GRID - 1)
	var step_z := (hi.z - lo.z) / float(WATER_GRID - 1)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	var y0 := 1.0e9
	var y1 := -1.0e9
	for gz in range(WATER_GRID - 1):
		for gx in range(WATER_GRID - 1):
			var v00 := grid.decode_u16((gz * WATER_GRID + gx) * 2)
			var v10 := grid.decode_u16((gz * WATER_GRID + gx + 1) * 2)
			var v01 := grid.decode_u16(((gz + 1) * WATER_GRID + gx) * 2)
			var v11 := grid.decode_u16(((gz + 1) * WATER_GRID + gx + 1) * 2)
			var x0 := lo.x + gx * step_x
			var z0 := lo.z + gz * step_z
			# Per corner: wet keeps its water level (and counts toward the
			# stats); a DRY corner of a wet quad is the bank, and it sits at
			# its own ground plus the epsilon - never at the raw grid value,
			# which at composite holes is zero and at coarse texels can be
			# anything. That is what put 0 m and 522 m into the first mesh's
			# vertex range while the wet area was already correct.
			var cy := PackedFloat32Array()
			var wets := 0
			for c in [[v00, x0, z0], [v10, x0 + step_x, z0],
					[v01, x0, z0 + step_z], [v11, x0 + step_x, z0 + step_z]]:
				var wyv := float((c as Array)[0]) / 65536.0 * wy
				var gv: float = ground_at.call(float((c as Array)[1]),
					float((c as Array)[2]))
				if wyv > gv + 0.02 and wyv >= env_lo and wyv <= env_hi:
					wets += 1
					cy.push_back(wyv)
					y0 = minf(y0, wyv)
					y1 = maxf(y1, wyv)
				else:
					cy.push_back(gv + 0.02)
			if wets == 0:
				continue
			var p00 := Vector3(x0, cy[0], z0)
			var p10 := Vector3(x0 + step_x, cy[1], z0)
			var p01 := Vector3(x0, cy[2], z0 + step_z)
			var p11 := Vector3(x0 + step_x, cy[3], z0 + step_z)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(x0, z0) * 0.05)
			st.add_vertex(p00)
			st.set_uv(Vector2(x0, z0 + step_z) * 0.05)
			st.add_vertex(p01)
			st.set_uv(Vector2(x0 + step_x, z0) * 0.05)
			st.add_vertex(p10)
			st.set_uv(Vector2(x0 + step_x, z0) * 0.05)
			st.add_vertex(p10)
			st.set_uv(Vector2(x0, z0 + step_z) * 0.05)
			st.add_vertex(p01)
			st.set_uv(Vector2(x0 + step_x, z0 + step_z) * 0.05)
			st.add_vertex(p11)
			quads += 1
	if quads == 0:
		return {}
	var mesh := st.commit()
	var km2 := quads * step_x * step_z / 1.0e6
	_say(("game source: river/lake surface from terrain block 2 - %d wet cells "
		+ "(%.2f km2), water level %.1f..%.1f m") % [quads, km2, y0, y1])
	return {"mesh": mesh, "y0": y0, "y1": y1, "wet_km2": km2}


func water(cache_dir := "") -> Array:
	if src == null or types == null:
		return []
	var out: Array = []
	# THE TERRAIN'S OWN WATER FIRST - the block-2 river/lake surface, which is
	# per-texel truth. The flat entity plane on these maps is authored
	# UNDERGROUND (tungsten y=0 vs floor 64.8) and acts as the render/material
	# entity; block 2 is what you actually see in game. cache_dir is where the
	# block-0 heightfield lives, which the wet clip compares against.
	var hf := terrain_water(cache_dir if cache_dir != "" else surface_cache)
	if not hf.is_empty():
		hf["kind"] = "river"
	var name := _water_partition()
	if name == "":
		if hf.is_empty():
			return []
		# a block-2 map whose entity partition eluded the name scan still
		# renders its river; the look falls back to the default water shader
		out.append(hf)
		return out
	var raw := src.get_ebx(name)
	if raw.is_empty():
		if not hf.is_empty():
			out.append(hf)
		return out
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
	if not hf.is_empty():
		# The river wears the map's own water look: the buried plane IS the
		# material entity (full-ocean shader on tungsten/eastwood), block 2 the
		# shape. Marry them.
		if not out.is_empty():
			var first: Dictionary = out[0]
			if first.has("look"):
				hf["look"] = first["look"]
			if first.has("sim"):
				hf["sim"] = first["sim"]
		out.append(hf)
	if out.is_empty():
		# SAY WHICH KIND OF NOTHING. The fleet measured ten maps with no water
		# entity at all, and two more (battery, contaminated) whose sea is
		# ordinary backdrop GEOMETRY placed from the level root - present in
		# the walk, drawn by the Backdrops layer, invisible to this reader by
		# design. "Water shows nothing" is correct on all of them, but the two
		# reasons deserve two sentences, because one of them has a chip the
		# user can press.
		var sea := 0
		if walk != null:
			for row in walk.rows:
				var mn := str((row as Dictionary).get("mesh", "")).get_file()
				if mn.contains("oceanplane") or mn.contains("water"):
					sea += 1
		if sea > 0:
			_say(("game source: no water entity - this map's sea/water is %d "
				+ "scenery mesh(es); the Backdrops layer draws them") % sea)
		else:
			_say("game source: this map ships no water at all - an empty Water "
				+ "layer is the correct answer, not a failure")
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
	# Snapshot: walking the live member races the catalogue republish.
	var t_ebx: Dictionary = src.snap_ebx()
	for k in t_ebx.keys():
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


# ---------------------------------------------------------------------------
# ENVIRONMENT DECAL VOLUMES (task #52): soot, graffiti, floor markings, gobo
# light splashes - projected boxes placed by the same walk as everything else.
#
# HOW A VOLUME FINDS ITS TEXTURE, measured on retail mp_capstone rather than
# taken from the fleet's write-up (which claimed the template partition carries
# the texture - it does not: the template has ZERO imports and an empty Shader
# struct). The real chain:
#
#   volume's Template import -> guid index -> decalvol_*/edv_* template EBX
#   -> the template's unnamed u64 field 0x4A98C1F8
#   -> that u64 IS a ShaderBlockDepot state key, present in the depot of the
#      SUBWORLD SCOPE that mounted the volume (verified by key-table membership:
#      decalvol_sootnoisy_triprojected_c's key sits in area_01's depot,
#      edv_gobolight_fluorescentlamp's in area_04/05/06's)
#   -> textures_for(key) -> the decal_ca / decal_nrm slots the prop-decal
#      family already decodes (RGB colour, A coverage).
#
# So the volume needs exactly what _collect already records: its composed world
# transform, its scope, and the fields below. The box extents ride the
# transform's basis as scale (measured 0.7..11.8 m axis lengths on capstone).
const EDV_TYPES := {
	"d67bc416-8540-47d7-8aae-e01c50f1b8c1": "EnvironmentDecalVolumeData",
	"47d78540-ae8a-1ce0-50f1-b8c137f95afb": "EnvironmentDecalVolumeData",
}
# The template type's guid pair, compared raw against instance_type() when the
# template partition is opened - names are not resolved there.
const EDV_TEMPLATE_TYPES: Array = [
	"d084b894-08af-902e-d29a-460fecbea4fb",
	"902e08af-9ad2-0f46-ecbe-a4fb5acee8bd",
]
const F_EDV_TEMPLATE := 0xA9AC5095   # import PointerRef to the template EBX
const F_EDV_ENABLE := 0x48C97D5E     # authored off stays off
const F_EDV_ALPHA := 0x40B21230      # per-instance opacity
const F_EDV_CULL := 0xC3B610EC       # OverrideTemplateCullingDistance, metres
const F_EDVT_KEY := 0x4A98C1F8       # the template's depot state key (u64)

const EDV_FIELDS: Array = [F_EDV_TEMPLATE, F_EDV_ENABLE, F_EDV_ALPHA,
	F_EDV_CULL]


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
# ENVIRONMENT DECAL VOLUMES, read off the walk's collected entities. See the
# chain documented at EDV_TYPES. Returns records the map context turns into
# Decal nodes; textures are fetched at build time through decal_sheet(), so the
# records stay pure data.
# ---------------------------------------------------------------------------
# template partition (lower, no .ebx) -> {"key": int, "name": leaf} or null.
# Null is cached too: a template that cannot be read once cannot be read
# per-instance either, and capstone places one template 22 times.
var _edv_tpl_cache := {}


func _edv_template(ptr):
	if not (ptr is Dictionary):
		return null
	var path := str((ptr as Dictionary).get("path", ""))
	if path == "" or path == "<not indexed>":
		# The pointer decoded before the guid index was warm; the import guid
		# still names the partition.
		var g := str((ptr as Dictionary).get("import", ""))
		var nm = walk.gi.get(g) if walk != null else null
		if nm == null:
			return null
		path = str(nm)
	var key := path.to_lower().trim_suffix(".ebx")
	if _edv_tpl_cache.has(key):
		return _edv_tpl_cache[key]
	var info = null
	var e = walk.open_ebx(key)
	if e != null:
		for i in range((e as BF6Ebx).exported_instance_count):
			if not EDV_TEMPLATE_TYPES.has((e as BF6Ebx).instance_type(i)):
				continue
			var rec: Dictionary = (e as BF6Ebx).read_instance(i)
			var sk = rec.get(F_EDVT_KEY)
			# The key is a u64 the depot table stores verbatim; GDScript holds
			# it as a (possibly negative) 64-bit int and BF6Depot compares it
			# the same way, so no masking here (see BF6Depot.key_hex).
			if (sk is int or sk is float) and int(sk) != 0:
				info = {"key": int(sk), "name": key.get_file()}
			break
	_edv_tpl_cache[key] = info
	return info


func _edv_records() -> Array:
	if walk == null or walk.ents.is_empty():
		return []
	var out: Array = []
	var seen := 0
	var no_tpl := 0      # template unreadable or without a state key
	var no_depot := 0    # the entity's scope owns no depot
	var no_rec := 0      # depot present but the key has no record there
	var no_sheet := 0    # record resolves but binds neither decal slot
	for e in walk.ents:
		if not (e is Dictionary):
			continue
		var ent: Dictionary = e
		if str(ent.get("tag", "")) != "edv":
			continue
		seen += 1
		var f: Dictionary = ent.get("f", {})
		if f.get(F_EDV_ENABLE) == false:
			continue
		var info = _edv_template(f.get(F_EDV_TEMPLATE))
		if info == null:
			no_tpl += 1
			continue
		var scope := str(ent.get("scope", ""))
		var pair = _depot_for(scope)
		if pair == null:
			no_depot += 1
			continue
		var dep: BF6Depot = pair[0]
		var skey := int(info["key"])
		if not dep.key_to_record.has(skey):
			no_rec += 1
			continue
		var slots: Dictionary = dep.textures_for(skey, pair[1])
		slots.erase("constants")
		# WHICH SHEET, AND WHAT IT MEANS. Measured across capstone's 24 distinct
		# templates (test_edvslots.gd), the family decides the binding:
		#   graffiti/checkpoint/dirt   decal_ca + decal_nrm     a real colour sheet
		#   ashdust                    the *_ca sheet arrives in the WRAP slot
		#   gobolight                  the fixture's *_e emissive plane - the
		#                              light pattern itself, in an unnamed slot
		#   soot/plaster/dust noisy    ONLY t_3dperlinnoise - the smudge is
		#                              shader-computed, colour from constants
		# So: prefer decal_ca, then classify the unnamed slots by the bound
		# texture's NAME rather than by more slot hashes - the suffix convention
		# (_ca colour, _e emissive, _nms normal) holds install-wide.
		var kind := ""
		var ca = slots.get("decal_ca")
		var nrm = slots.get("decal_nrm")
		if ca != null:
			kind = "albedo"
		else:
			var emit = null
			var noise = null
			for k in slots.keys():
				var nm = walk.gi.get(str(slots[k]))
				if nm == null:
					continue
				var leaf := str(nm).get_file().to_lower().trim_suffix(".ebx")
				if leaf.ends_with("_ca"):
					ca = slots[k]
				elif leaf.ends_with("_e"):
					emit = slots[k]
				elif leaf.contains("noise"):
					noise = slots[k]
			if ca != null:
				kind = "albedo"
			elif emit != null:
				kind = "emit"
				ca = emit
			elif noise != null:
				kind = "smudge"
				ca = noise
		if ca == null:
			no_sheet += 1
			continue
		var xf: Array = ent["xf"]
		out.append({
			"xf": xf,
			"kind": kind,
			"ca": str(ca),
			"nrm": str(nrm) if nrm != null else "",
			"alpha": clampf(float(f.get(F_EDV_ALPHA, 1.0)), 0.0, 1.0),
			"cull": float(f.get(F_EDV_CULL, 0.0)),
			"tpl": str(info["name"]),
		})
	if seen > 0:
		_say(("game source: %d decal volumes (%d placeable; dropped: "
			+ "%d template, %d no depot, %d no record, %d no sheet)")
			% [seen, out.size(), no_tpl, no_depot, no_rec, no_sheet])
	return out


# The build-time texture fetch for a record's "ca"/"nrm" guid. Public because
# the map context calls it per distinct sheet while it builds the Decal nodes.
func decal_sheet(file_guid: String):
	if file_guid == "":
		return null
	return _decal_sheet(file_guid, false)


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
	if _mesh_trace:
		HighpolyLog.info("mesh trace: OBJECT-NODE enter %s" % portal_name)
		HighpolyLog.flush()
	var _n := _object_node_body(portal_name)
	if _mesh_trace:
		HighpolyLog.info("mesh trace: OBJECT-NODE leave %s -> %s"
			% [portal_name, "null" if _n == null else "node"])
		HighpolyLog.flush()
	return _n


func _object_node_body(portal_name: String) -> Node3D:
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
# SOME PREFABS CARRY AN ART-CATEGORY PREFIX THE SDK NAME DROPS.
#
# OrdinanceCrate_01 draws nothing because the game calls it
# pf_portal_com_ordinancecrate_01. The categories are the same ones the texture
# names use: com_ (common), mil_ (military), fed_, naf_, ind_ and so on.
#
# Surveyed over the same 4,620 objects the _a rule was measured on: this
# resolves a further 16 - com_ 9, fed_ 6, ind_ 1 - and NOT ONE of them is
# ambiguous. That matters more than the count. Returning a match only when
# exactly one category has it keeps this from becoming the fuzzy name matching
# that put a wrong model on a renamed node earlier: if two categories both
# carried the name there would be no way to know which, and the honest answer
# would be the proxy.
const NAME_PREFIXES := ["com_", "mil_", "fed_", "naf_", "cas_", "ind_",
	"psd_", "ter_", "veg_", "ob_"]


# THE ONE PLACE THAT DECIDES WHETHER A PORTAL NAME EXISTS.
#
# This was written out twice - once in object_rows and once in has_object - and
# widening only object_rows fixed nothing: _asset_id asks has_object first, got
# "no" from the copy that had not been widened, and never even tried to build the
# overlay. BackroomStorageShe01 stayed blank through two deploys because of it.
#
# Both callers go through here now, so a name rule cannot be half-applied again.
func _resolve_object(key: String):
	if walk == null:
		return null
	for cand in [PORTAL_PREFIX + key, key, PORTAL_PREFIX + key + "_a"]:
		var r = walk.resolve_name(cand)
		if r != null:
			return r
	return _resolve_prefixed(key)


func _resolve_prefixed(key: String):
	var found: Array = []
	for pre in NAME_PREFIXES:
		for cand in [PORTAL_PREFIX + pre + key, PORTAL_PREFIX + pre + key + "_a"]:
			var r = walk.resolve_name(cand)
			if r != null:
				found.append(r)
				break
	return found[0] if found.size() == 1 else null


func object_rows(portal_name: String) -> Array:
	if walk == null or src == null:
		return []
	var key := portal_name.to_lower()
	if _obj_cache.has(key):
		return _obj_cache[key]

	# pf_portal_<name> first, then the bare name: a few placeables are their own
	# prefab rather than a wrapped one. Then <name>_a, because some objects the
	# SDK offers under one name exist in the game ONLY as lettered variants.
	#
	# Surveyed over 4,620 SDK objects: 4,290 resolve directly, 109 have no game
	# asset at all (AI_Spawner, CombatArea, CapturePoint - gameplay logic with no
	# geometry, correctly absent), and 221 resolve only with a suffix. All 221
	# are "_a"; no other suffix fixes anything.
	#
	# TAKING _a IS SAFE BECAUSE THE LETTERS ARE VARIANTS, NOT PARTS. That was the
	# risk worth checking - picking one half of a split prop is worse than
	# drawing the proxy - and the user's own BackroomStorageShe01 settles it:
	# _a and _b have identical size (3.21, 3.13, 0.82) AND identical centre
	# (1.60, 1.56, 0.40). They occupy the same space, so they are two dressings
	# of one object and either is the whole thing.
	#
	# Last in the list, so it can never override a direct hit.
	var ref = _resolve_object(key)
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
		# Kept in step with the level walk's collector set: a lamp fixture
		# dropped into a scene carries the same embedded decal volume it
		# carries on the map, and two walkers with different field lists is
		# how one of them silently loses a collector later.
		for gd in EDV_TYPES:
			_obj_walk.want_types[str(gd)] = "edv"
		_obj_walk.want_fields = LIGHT_FIELDS + EDV_FIELDS
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
	return _resolve_object(key) != null


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
# Of those surfaces, how many carry a REAL second unwrap (declB TexCoord4 on its
# own stream). AN INSTANCE VAR LIKE ITS SIBLINGS, not a static one: it has to be
# reset with the game source each build, or the second build in a session
# reports a running total and reads as a doubling.
#
# This is the number that decides whether sampling anything through UV2 is worth
# building. The livery already maps correctly through UV0 on car BODIES - proven
# by rasterising the wrap through every channel, tools/test_uv32.gd - so the only
# open case is the door/panel one, where UV0 tiles and the wrap currently falls
# back to solid paint. dfanz0r measured 3 batches in 72 on his sample. If this
# comes back as small, the honest answer is that the fallback stays.
var n_uv2_surfaces := 0
# And what the colour-table split costs: meshes built with their surfaces cut by
# palette entry, and meshes that had to be read from the game again because the
# cached copy was merged.
var n_pal_split := 0
var n_pal_rebuilt := 0

# WHERE THE MATERIAL TIME GOES, split out of t_mat, in microseconds.
#
# t_mat is one number covering a depot parse, a per-key record lookup, a texture
# decode and a GPU upload, and those want four different fixes. The texture
# decode is the only one that is obviously heavy, which is exactly why it should
# be measured instead of assumed: on a map whose textures all dedup, the decode
# can be a rounding error and the cost is the depot parse nobody suspected.
var t_tex := 0                         # decode + compress + ImageTexture upload
var t_depot := 0                       # reading and parsing a ShaderBlockDepot
var n_depot_parsed := 0
var n_mat_built := 0                   # material_for reached the depot
var n_mat_cached := 0                  # material_for answered from _mat_cache
# Geometry provenance per mesh ask, so "props: load mesh" can be read as a cache
# hit rate rather than as a total. A build that is 90% cache hits and one that is
# 10% have completely different next steps.
var n_geom_hit := 0                    # served from user://bf6_geom
var n_geom_miss := 0                   # read from the install and parsed


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
# GIVE THE MEMORY BACK.
#
# Godot frees a Resource when its last reference drops, and every mesh, material
# and texture we ever built is still referenced by a cache below - so turning
# every layer off frees the NODES and releases almost nothing. A user watched
# the editor reach 16 GB with everything on and sit at 14 GB with everything
# off; that 14 GB is this. The only _tex_cache.clear() in the file lives inside
# invalidate_materials(), which teardown never calls.
#
# Measured at full build: 2,402 textures (~2.9 GB), 16,125 materials, 7,222
# meshes. None of it evicts.
#
# THE COST IS HONEST AND WORTH STATING: dropping these means the next build
# re-reads from the install. That is ~10.7 s with the on-disk geometry cache
# still in place, not the 63 s of a cold read - the disk caches are deliberately
# NOT touched here, only the in-memory ones.
#
# Returns what was released so a caller can say so rather than claiming it.
# Drop every cached mesh and material the built scene does not reference.
#
# NOT AN LRU BUDGET. Dropping a cache slot frees nothing while the scene still
# holds the resource, so evicting by recency spends evictions on live entries
# and frees nothing. The freeable set is precisely "what the finished scene does
# not use", and that is knowable by looking at what was built.
#
# Textures come along for free: a surplus material holds its textures, so a
# texture used only by surplus materials dies with them. Nothing here has to
# reason about GPU bytes, which is just as well - they are not readable from
# GDScript.
#
# -> a Dictionary of what went, so a caller can report it rather than claim it.
func compact_caches(root: Node) -> Dictionary:
	if root == null:
		return {}
	# What the scene actually draws, by instance id. Meshes and materials both,
	# in one walk.
	var live_mesh := {}
	var live_mat := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var m: Mesh = null
		if n is MeshInstance3D:
			m = (n as MeshInstance3D).mesh
			var ov := (n as MeshInstance3D).material_override
			if ov != null:
				live_mat[ov.get_instance_id()] = true
		elif n is MultiMeshInstance3D:
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm != null:
				m = mm.mesh
			var ov2 := (n as MultiMeshInstance3D).material_override
			if ov2 != null:
				live_mat[ov2.get_instance_id()] = true
		if m == null:
			continue
		live_mesh[m.get_instance_id()] = true
		for i in range(m.get_surface_count()):
			var sm := m.surface_get_material(i)
			if sm != null:
				live_mat[sm.get_instance_id()] = true

	var out := {"materials_before": _mat_cache.size(),
		"meshes_before": _mesh_by_sig.size(),
		"dressed_before": _dressed.size()}

	var keep_mat := {}
	for k in _mat_cache.keys():
		var v = _mat_cache[k]
		if v is Material and live_mat.has((v as Material).get_instance_id()):
			keep_mat[k] = v
	_mat_cache = keep_mat

	var keep_mesh := {}
	for k in _mesh_by_sig.keys():
		var v = _mesh_by_sig[k]
		if v is Mesh and live_mesh.has((v as Mesh).get_instance_id()):
			keep_mesh[k] = v
	_mesh_by_sig = keep_mesh

	# _dressed holds a STRONG ArrayMesh reference per row (see its note), so a
	# row for a mesh the scene dropped keeps that mesh resident on its own. The
	# rows kept are still enough to re-dress what is on screen, which is all
	# that list is for.
	var keep_dressed: Array = []
	for row in _dressed:
		var am = (row as Array)[0]
		if am is ArrayMesh and live_mesh.has((am as ArrayMesh).get_instance_id()):
			keep_dressed.append(row)
	_dressed = keep_dressed

	out["materials_after"] = _mat_cache.size()
	out["meshes_after"] = _mesh_by_sig.size()
	out["dressed_after"] = _dressed.size()
	return out


func release_caches() -> Dictionary:
	var before := cache_stats()
	_tex_cache.clear()
	_mat_cache.clear()
	_mesh_by_sig.clear()
	_obj_cache.clear()
	_depot_cache.clear()
	_sky_cache.clear()
	_water_look_cache.clear()
	_decal_tex_cache.clear()
	# _dressed WAS MISSING, and it is the one that made the mesh half of this a
	# lie. It holds [ArrayMesh, keys, scope, variation, name] for every mesh ever
	# dressed, so clearing _mesh_by_sig above freed nothing: every one of the
	# 7,222 meshes this function then REPORTED as released was still strongly
	# referenced from here. Written from a shorter list than
	# invalidate_materials() keeps, which is where the rest of these came from.
	_dressed.clear()
	_keys_for.clear()
	_group_meta.clear()
	_mask_cache.clear()
	_mask_cut.clear()
	_tint_mask_cache.clear()
	_smooth_cache.clear()
	_litpack_cache.clear()
	# THE TWO THAT MADE CLEARING THE OTHERS POINTLESS.
	#
	# _mat_by_look and _emissive_mats hold MATERIALS, and a material holds its
	# textures. So dropping _tex_cache and _mat_cache above freed nothing at all
	# while these still referenced the same objects: measured, release_caches
	# gave back 1,617 MB of a 4,379 MB build and the rest was here.
	#
	# Everything else on this list is the same mistake in smaller print - a
	# dictionary added next to the code that fills it, never added to the code
	# that empties it. Compiled from the member list rather than from memory,
	# because that is how the first seven got missed.
	_mat_by_look.clear()
	_emissive_mats.clear()
	_res_for.clear()
	_var_live.clear()
	_sec_keys.clear()
	_hidden_cache.clear()
	_pal_canon_cache.clear()
	_scatter_cache.clear()
	_obj_lights.clear()
	_water_sim.clear()
	_hm.clear()
	# Windows will often hold the freed pages rather than returning them to the
	# OS, so Task Manager can stay high while this genuinely worked. Judge it by
	# Performance.MEMORY_STATIC and VRAM, not by RSS.
	return {
		"textures": before.get("textures", 0),
		"materials": before.get("materials", 0),
		"meshes": before.get("meshes", 0),
		"texture_mb_est": before.get("texture_mb_est", 0.0),
	}


# WHAT OUR CACHES ARE HOLDING, in entries and in estimated bytes.
#
# Users report the editor sitting at 3.3 GB with only the menu open, and a run
# with every layer off measured 3,001 MB of TEXTURE memory with no map built.
# That number alone cannot say whether it is ours or the SDK scene's, and the
# caches below have no eviction and no size bound, so nothing here is ever
# given back. This attributes the total instead of leaving it to inference.
#
# Texture bytes are ESTIMATED from dimensions and format, never by calling
# get_image(): that forces a GPU readback, which on a few thousand textures
# would stall the editor for seconds - the exact failure this is investigating.
func cache_stats() -> Dictionary:
	var tex_bytes := 0
	var tex_n := 0
	var mips := 0
	for k in _tex_cache.keys():
		var t = _tex_cache[k]
		if t == null or not (t is Texture2D):
			continue
		tex_n += 1
		var t2 := t as Texture2D
		var px: int = t2.get_width() * t2.get_height()
		# 4 bytes/px is the honest upper bound for the RGBA8 we decode to; a
		# compressed texture is less, so this over-reports rather than flatters.
		tex_bytes += px * 4
		# THERE WAS A get_image() HERE, doing precisely what the note above says
		# must never happen, inside a `pass` that made it look inert. It is not
		# inert: the call is what forces the readback, and the discarded result
		# is only the result. On 2,402 textures that is a full CPU copy of the
		# entire set, allocated at the exact moment we are measuring memory.
		#
		# Two paths made it costly rather than merely wasteful. release_caches()
		# calls this FIRST, so a map switch did the readback at peak memory
		# immediately before freeing - the same map switch that was reported
		# reaching 16 GB. And the panel's memory report calls it on log save,
		# where nothing is freed afterwards at all, so the users most likely to
		# hit this are exactly the users who sent us a log.
	mips = 0
	# EVERY CACHE release_caches() CLEARS, not the six this used to report.
	# A ceiling cannot be attributed from a third of what is held, and the
	# largest holder - _dressed, one ArrayMesh per dressed mesh - was not in the
	# list at all. Counts rather than bytes: GPU-side sizes are not readable
	# from here, and a count that is honest beats a byte figure that is not.
	var side := {
		"dressed_meshes": _dressed.size(),
		"keys_for": _keys_for.size(),
		"group_meta": _group_meta.size(),
		"mask": _mask_cache.size(),
		"mask_cut": _mask_cut.size(),
		"tint_mask": _tint_mask_cache.size(),
		"decal_tex": _decal_tex_cache.size(),
		"smooth": _smooth_cache.size(),
		"litpack": _litpack_cache.size(),
		"water_look": _water_look_cache.size(),
	}
	var meshes := 0
	var surfaces := 0
	for k in _mesh_by_sig.keys():
		var m = _mesh_by_sig[k]
		if m is Mesh:
			meshes += 1
			surfaces += (m as Mesh).get_surface_count()
	var objs := 0
	for k in _obj_cache.keys():
		if _obj_cache[k] != null:
			objs += 1
	return {
		"textures": tex_n,
		"texture_mb_est": snappedf(tex_bytes / 1048576.0, 0.1),
		"materials": _mat_cache.size(),
		"meshes": meshes,
		"mesh_surfaces": surfaces,
		"objects": objs,
		"depot_entries": _depot_cache.size(),
		"lookaside": side,
		# What eviction could actually free: a cached material on no built
		# surface is surplus, and a cached one that IS on a surface cannot be
		# freed by dropping the cache slot because the scene holds it too.
		"materials_over_surfaces": maxi(0,
			_mat_cache.size() - int(surfaces)),
		"sky_entries": _sky_cache.size(),
		# None of these caches evicts. Recorded so the number is not mistaken
		# for a working set that would come back under pressure.
		"evicts": false,
	}


# THE OBJECT DEBUGGER'S RAW FEED: one mesh re-read from the install with
# EVERY UV channel kept, one entry per renderable section (not merged - the
# debugger wants parts, the build wants draw calls). Nothing is cached: this
# runs once per Debug press on one prop, and holding a second copy of a mesh
# the build already holds would be pure weight.
func debug_sections(res_name: String) -> Array:
	if src == null:
		return []
	var d := src.get_res(res_name)
	if d.is_empty():
		return []
	var info := _ms.parse(d)
	if info.is_empty():
		return []
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return []
	var L: Dictionary = lods[0]
	var chunk := PackedByteArray()
	var cid: PackedByteArray = L.get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	var secs = _ms.read_lod(d, 0, chunk, false, true)
	return secs if secs is Array else []


# THE LIVERY SHELF: every wrap sheet shipped in this prop's own folder. A
# vehicle's liveries are separate wrap textures chosen per placement through
# an ObjectVariation - the police SUV's folder carries the police wrap, the
# sedan's the taxi wrap - so the record the picked instance resolves through
# only ever names ONE of them. The debugger lists the folder's whole shelf
# so a user can try the others on.
func debug_livery_options(res_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	if src == null:
		return out
	var dir := res_name.get_base_dir().to_lower() + "/"
	for n in src.snap_res().keys():
		var s := str(n)
		if s.to_lower().begins_with(dir) and s.get_file().to_lower().contains("wrap"):
			out.append(s)
	out.sort()
	return out


# The debugger's view of the twin-pair rule: which part indices this prop
# hides at spawn. Same table, same rule, same cache as the build's own
# filter - the debugger only needs it separately because it draws raw
# sections the build never emits.
func debug_hidden_parts(res_name: String) -> Dictionary:
	if src == null:
		return {}
	var d := src.get_res(res_name)
	if d.is_empty():
		return {}
	var info := _ms.parse(d)
	if info.is_empty():
		return {}
	return _hidden_parts(res_name, info)


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
		# The record's own switch first, then the content test - the same
		# order material_for applies. A real mask behind a switched-off gate
		# is the truckpickup-wheel case: foreign slot filler, never sampled.
		if not _alpha_gate(dconsts):
			d["masked"] = false
			d["cut"] = 0.0
			d["note"] += ("  alpha slot bound but the record's alpha-test "
				+ "switch (0x77d10576) is OFF - the game never cuts this "
				+ "surface, the sheet is slot filler")
		else:
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


# Set BF6_MESH_TRACE=1 to have every mesh name written and FLUSHED before it
# is touched. Off by default because it is a line and a disk flush per mesh.
#
# It exists for one failure: the editor dies inside the first mesh read from
# the install, taking the whole process with it, and the plugin session log is
# renamed from its .tmp only on a clean close - so a crashed run leaves the
# .tmp behind with everything up to the LAST FLUSH in it. Batched lines are
# lost; flushed ones are not. This turns "it died somewhere in the build" into
# the name of the mesh it died on.
static var _mesh_trace := OS.get_environment("BF6_MESH_TRACE") == "1"


# PAIRED, so the .tmp says whether it died INSIDE this or after it returned.
#
# The entry-only trace could not tell those apart: the last line was always a
# mesh name, which is equally consistent with "crashed parsing that mesh" and
# "handed that mesh back and crashed instancing it". A trailing "enter" with no
# "leave" means the former; a trailing "leave" means the caller.
#
# Wrapped rather than instrumented at each of the nine returns, because a
# ninth-return-forgotten is exactly how this kind of trace lies.
func mesh_for(group_key: String, lod := 0) -> Mesh:
	if not _mesh_trace:
		return _mesh_for_body(group_key, lod)
	HighpolyLog.info("mesh trace: ENTER %s lod=%d" % [group_key, lod])
	HighpolyLog.flush()
	var _m := _mesh_for_body(group_key, lod)
	HighpolyLog.info("mesh trace: leave %s -> %s"
		% [group_key, "null" if _m == null else "mesh"])
	HighpolyLog.flush()
	return _m


# WHICH LOD RUNG PROPS ARE BUILT FROM. 0 is what the game shows up close.
#
# MEASURED on 250 mp_aftermath meshes, renderable geometry only (the shadow and
# ZOnly subsets are already dropped, so they are not in these numbers):
#     LOD0  198.9 MB vertex bytes  100%
#     LOD1   58.8 MB                29.6%
#     LOD2   31.0 MB                15.6%
# and 99.8% of that memory lives in meshes UNDER 3 m - the small props that are
# everywhere the camera is. So this is a global choice and not a distance one:
# "coarser when far away" reaches almost none of the memory, because the far
# cells are nearly empty (2 to 9 groups against roughly 800 downtown).
#
# It buys NO draw calls. A coarse rung keeps every material split - measured, the
# section count is identical on 194 of 200 meshes - so this is memory and parse
# time only. See lod-rungs-share-lod0-section-count in the research repo.
#
# Left at 0 because it is a visible quality choice and belongs to the user, not
# to a constant I picked. 1 is the artist-authored "slightly less" rung and
# would give back roughly 70% of the vertex memory.
const PROP_LOD := 0


func _mesh_for_body(group_key: String, lod := 0) -> Mesh:
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
			# NAME IT BEFORE DRESSING IT. _dress records _dress_name, and the
			# only assignment sat further down the read-from-the-game path,
			# which a cache hit returns before ever reaching. So every mesh
			# served from the cache was recorded under whatever was dressed
			# BEFORE it, and describe() - which is what Pick mode prints - named
			# another object entirely.
			#
			# That is how a backdrop smoke plume was reported as
			# "euu_manhattanbridge_01_floor_01_mesh". The geometry, the state key
			# and the material were all correct; only the LABEL was wrong, and it
			# sent this investigation after a mesh-resolution bug that does not
			# exist.
			_dress_name = res_name
			_dress(cached as ArrayMesh, ckeys, scope, var_hash)
			_mesh_by_sig[_sig_for(kc, ckeys, scope, var_hash)] = cached
			n_geom_hit += 1
			return cached as ArrayMesh
		n_pal_rebuilt += 1

	var d := src.get_res(res_name)
	if d.is_empty():
		return null
	n_geom_miss += 1
	t_res += Time.get_ticks_usec() - _t0
	var _t1 := Time.get_ticks_usec()
	var mat_us := 0
	var info := _ms.parse(d)
	if info.is_empty():
		return null
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return null
	# PROP_LOD biases the request rather than replacing it: a caller that asks
	# for a specific rung (the skyline already asks for a coarse one) keeps what
	# it asked for, and the floor only ever coarsens.
	var li: int = clampi(maxi(lod, PROP_LOD), 0, lods.size() - 1)
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
	_wrap_channel_fix(secs, scope, var_hash, res_name)

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
	# Only ever true for a group whose every section carried a REAL second
	# unwrap (uv2_src "tc4"). See the uv2 read below for why the other two
	# sources are not unwraps at all.
	var want_uv2 := {}
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
					PackedVector2Array(), PackedInt32Array(),
					PackedVector2Array()]
				order.append(bid)
				want_normals[bid] = true
				want_uvs[bid] = true
				want_uv2[bid] = true
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
			# Pulled out for the reason the comment above gives: appending through
			# acc[4] would append to a temporary and throw it away.
			var au2: PackedVector2Array = acc[4]
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
			# THE SECOND UNWRAP, and only when it IS one. The reader hands back
			# three kinds of thing under "uv2" and only one of them is an unwrap:
			# "tc4" is a genuine second set on its own stream; "uv0" means TC4 is
			# aliased onto TC0 so the unwrap already IS UV0 and there is nothing
			# to carry; "second" is the fallback to the second declared set, which
			# is the atlas slice that turns retail-sign art 90 degrees. Shipping
			# either of the last two would put a texture somewhere art was never
			# authored for.
			#
			# Gated per group like the others, and for the same reason: one
			# section short would silently misalign every section after it.
			if str(sec.get("uv2_src", "")) == "tc4":
				var u2 = sec.get("uv2")
				if u2 is PackedVector2Array and (u2 as PackedVector2Array).size() == n:
					au2.append_array(u2)
				else:
					want_uv2[bid] = false
			else:
				want_uv2[bid] = false
			by_mat[bid] = [av, an, au, acc[3], au2]
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
		if bool(want_uv2.get(key, false)) and acc.size() > 4 \
				and (acc[4] as PackedVector2Array).size() == verts.size():
			arr[Mesh.ARRAY_TEX_UV2] = acc[4]
			n_uv2_surfaces += 1
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
	# THE LOD RUNG IS PART OF THE DIRECTORY, or PROP_LOD silently does nothing.
	# This cache holds BUILT geometry, so a directory written from LOD0 is served
	# to a LOD1 build unchanged - which is exactly what happened the first time
	# this was measured: zero new sidecars, identical mesh and surface counts,
	# memory unmoved, and nothing to say why. Absent at rung 0 so every existing
	# cache directory stays valid and nobody pays a rebuild for a default.
	var lodsfx := "" if PROP_LOD <= 0 else "_l%d" % PROP_LOD
	# THE TEXTURE MODE BELONGS IN THE KEY TOO, and for the same reason the LOD
	# rung does: this directory holds BUILT geometry with its materials and
	# pixels baked in. Low mode halves every texture before compressing it, so a
	# directory written in compressed mode hands full-resolution pixels to a low
	# build and the setting appears to do nothing at all. That is exactly what
	# the first measurement of each showed - identical counts, memory unmoved,
	# nothing in the log to say why. Absent in the default mode, so no existing
	# cache is orphaned by adding this.
	var vsfx := ""
	if HighpolyMapContext.vram_mode == HighpolyMapContext.VRAM_LOW:
		vsfx = "_vlow"
	elif HighpolyMapContext.vram_mode == HighpolyMapContext.VRAM_FULL:
		vsfx = "_vfull"
	var d := "user://bf6_geom/%s_%s_g%d%s%s" % [level, sig, GEOM_EPOCH,
		lodsfx, vsfx]
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
# NOT WEAK. A GDScript Array holds STRONG references, so every ArrayMesh listed
# here is kept alive by this list alone - a mesh dropped from the scene stays
# resident until release_caches() runs. This comment used to claim the opposite
# ("weak by nature"), and release_caches was written from a list that omitted
# _dressed as a result; its own note records that the omission "made the mesh
# half of this a lie", because clearing _mesh_by_sig freed nothing while all
# 7,222 meshes were still held here.
#
# Anything that bounds memory has to treat this as the largest holder, not as a
# bookkeeping list.
var _dressed: Array = []
# The mesh currently being built, so _dress can record what it dressed without
# every caller having to pass it.
var _dress_name := ""
# Does the surface being dressed RIGHT NOW carry a real second unwrap?
#
# Read from the ArrayMesh's own surface format in _dress, never from a table
# built during parse: a cached-geometry build never parses, so a table would be
# empty and the doors would come out different cold and warm. The mesh carries
# the fact into the cache with it.
var _dress_uv2 := false


func _dress(am: ArrayMesh, keys: Array, scope: String, var_hash := 0) -> void:
	if not build_materials:
		return
	_dressed.append([am, keys, scope, var_hash, _dress_name])
	var _t := Time.get_ticks_usec()
	# The bundle that shipped this mesh, as a second place to look when the
	# walk's scope has no record. See the note in _dress_only.
	var alt := _scope_of(_dress_name) if _dress_name != "" else ""
	if alt == scope:
		alt = ""
	for i in range(mini(keys.size(), am.get_surface_count())):
		# PER SURFACE, not per mesh: a van's body and its door panels are
		# separate surfaces and only some of them carry the second unwrap.
		_dress_uv2 = (int(am.surface_get_format(i))
			& int(Mesh.ARRAY_FORMAT_TEX_UV2)) != 0
		var mat = _material_any(_mkey(keys[i]), scope, alt, var_hash,
			_mpal(keys[i]))
		if mat != null:
			am.surface_set_material(i, mat)
	# Cleared, so a later caller that reaches a material path WITHOUT going
	# through _dress cannot inherit the last surface's answer.
	_dress_uv2 = false
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
	_smooth_cache.clear()
	_emissive_mats.clear()
	# THE ASSEMBLED-OBJECT CACHE, AND ESPECIALLY ITS FAILURES.
	#
	# object_rows caches a NOT-FOUND as an empty array, and nothing was clearing
	# it - so widening the name rules fixed nothing for anyone whose session had
	# already asked. The user pressed Check for updates after the _a fallback
	# shipped and BackroomStorageShe01 was still blank, because the empty answer
	# from before the fix was still sitting in this dictionary.
	#
	# It is derived from OUR name rules, not from the game, so it belongs here
	# with the other things a code change invalidates.
	_obj_cache.clear()
	_obj_lights.clear()
	_foliage_shader = null
	_prop_tint_shader = null
	# HELD SHADERS MUST BE DROPPED HERE OR AN EDIT TO ONE NEVER REACHES THE
	# SCREEN. Every shader this file loads is cached in a member and reused, so
	# after a live reload the material is rebuilt around the OLD compiled shader
	# and the user sees their update do nothing. Missing this line is why the
	# decals did not change when decal.gdshader did.
	_decal_shader = null
	_smoke_shader = null
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
		_dress_only(am as ArrayMesh, row[1] as Array, str(row[2]), int(row[3]),
			str(row[4]) if row.size() > 4 else "")
	_dressed = live
	return {"meshes": meshes, "surfaces": surfaces, "gone": gone,
		"ms": Time.get_ticks_msec() - t0}


# _dress without the bookkeeping, so re-dressing does not grow the list it is
# iterating.
# Depot scopes belonging to the same level as `scope`.
#
# A level ships several subworlds side by side - default_event, winter_event,
# the gameplay layers, the level's own bundle - and a placement's shader records
# do not always live in the one the walk reached it through. The marked London
# plane tree on MP_Aftermath was walked under default_event and all three of its
# surfaces have their records in winter_event, a seasonal sibling.
#
# Computed once per level directory. On MP_Aftermath that is 72 scopes, and only
# surfaces that have already failed twice ever look at them.
var _sib_scopes := {}

func _siblings_of(scope: String) -> Array:
	var dir := scope.get_base_dir()
	if dir == "":
		return []
	if _sib_scopes.has(dir):
		return _sib_scopes[dir]
	var out: Array = []
	for k in _depot_bundles.keys():
		var s := str(k)
		if s != scope and s.begins_with(dir + "/"):
			out.append(s)
	_sib_scopes[dir] = out
	return out


# The material for one surface, trying the scopes in order of authority:
# the walk's, then the bundle that ships the mesh, then the level's siblings.
# Returns null only when none of them holds a record.
func _material_any(state_key: int, scope: String, alt: String, var_hash: int,
		pal: PackedInt32Array) -> Variant:
	var mat = material_for(state_key, scope, var_hash, pal)
	if mat != null:
		return mat
	if alt != "":
		mat = material_for(state_key, alt, var_hash, pal)
		if mat != null:
			tex_stats["scope_shipping"] = \
				int(tex_stats.get("scope_shipping", 0)) + 1
			return mat
	for s in _siblings_of(scope):
		mat = material_for(state_key, str(s), var_hash, pal)
		if mat != null:
			tex_stats["scope_sibling"] = \
				int(tex_stats.get("scope_sibling", 0)) + 1
			return mat
	# A FOURTH TIER — ANY DEPOT OF THIS LEVEL — WAS TRIED HERE AND REMOVED.
	#
	# The reasoning was good: a surface whose key none of the three tiers holds
	# gets NO MATERIAL AT ALL (_dress only calls surface_set_material when the
	# lookup returned something), and the recorded Dumbo measurement says 213 of
	# 214 absent keys turn up in another subworld's depot of the same level.
	#
	# It fired ZERO times over 900 meshes and 1,852 surfaces on MP_Aftermath,
	# and it did not rescue com_billboard_sign's bare face, which is the prop
	# that prompted it. The shipping and sibling tiers above were already
	# catching those cases (5 and 3 hits on the same sample). What is left bare
	# is 22 surfaces on 13 meshes — 1.19% — and they are curbs, a cinematic
	# helicopter, a killcam-only C4 and a light blocker: assets with no material
	# record anywhere, not assets we are failing to look up.
	#
	# tools/probe_bare.gd is that measurement, if the question comes back.
	return null


func _dress_only(am: ArrayMesh, keys: Array, scope: String, var_hash: int,
		res_name := "") -> void:
	# THE BUNDLE THAT SHIPPED THE MESH, as a second place to look.
	#
	# The scope comes from the WALK - the subworld that mounted the prefab - and
	# that is usually right and occasionally is not. A London plane tree on
	# MP_Aftermath was walked under .../default_event, which is a real depot and
	# holds no record for the tree's surfaces, so all three drew white. The
	# resource itself ships in .../mp_aftermath, whose depot does hold them.
	#
	# res_bundle records who shipped each resource at mount time, so the right
	# answer was already in hand. Tried only when the walk's scope produces
	# nothing: the walk stays authoritative, this is a fallback, not a
	# replacement.
	var alt := _scope_of(res_name) if res_name != "" else ""
	if alt == scope:
		alt = ""
	for i in range(mini(keys.size(), am.get_surface_count())):
		am.surface_set_material(i, _material_any(_mkey(keys[i]), scope, alt,
			var_hash, _mpal(keys[i])))


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
	# THE SECOND UNWRAP IS PART OF THE KEY. One record dresses a van's body and
	# its door panels alike, and the carpaint path below now builds a different
	# material when the surface has a real second unwrap. Without this the first
	# one built would be handed to the other - the same class of collision the
	# palette suffix above exists to prevent. Only appended when true, so the
	# 99.4% of surfaces that have no second unwrap keep sharing exactly as now.
	if _dress_uv2:
		ck += "|uv2"
	if _mat_cache.has(ck):
		n_mat_cached += 1
		return _mat_cache[ck]
	n_mat_built += 1

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
		# THE LIVERY, which the depot has been handing us all along.
		#
		# A carpaint shell binds no colour sheet by design - the body is the
		# constant above - so a police car, an ambulance and a taxi all came out
		# as flat paint. But the record ALSO binds a `wrap` sheet naming the
		# livery outright:
		#
		#   wrap=t_com_carsuv_wrap_policeusny_01.ebx
		#
		# SLOT_WRAP was declared in bf6_depot.gd and read by nothing in the whole
		# plugin, so that texture was resolved, named in the diagnostic, and
		# thrown away. Four of the eleven props a user marked are this: "police
		# car does not have its livery", "supposed to have a custom decal",
		# "supposed to have a custom livery/decal", "ambulance is supposed to
		# have a livery".
		#
		# Used as the albedo over the body colour. That is the honest simple
		# reading: the wrap IS the car's visible surface where it covers, and
		# albedo_color still multiplies it, so an unwrapped area keeps the paint.
		# The reference pipeline layers it as a decal with the paint showing
		# through the wrap's own alpha, which is a better approximation of a real
		# vinyl wrap; this is the first order of it, and the difference will show
		# on wraps that do not cover the whole shell.
		# THE WRAP GOES ON THE BODY ONLY. The reference implementation is explicit
		# about why (impl/pipeline/member_mesh.py, the carpaint branch):
		#
		#   secondary member (door/hood/trunk): its UV0 islands do NOT share the
		#   body's wrap layout - decals land as garbage. Solid family paint only.
		#
		# Reported as "the liveries are showing up now but they are not mapped
		# correctly", which is exactly that: a police stripe authored for the
		# shell's unwrap, sampled through a door's own unrelated unwrap.
		#
		# Body and member are told apart by name. The family meshes end at their
		# index - com_carsuv_01_mesh - and every separate panel carries a part
		# after it: com_carsuv_01_door_frontright_mesh, com_metrobus_01_wreck_
		# roof_mesh. So a name that does not end in its index is a member.
		var wrap = _texture_for(slots.get("wrap"), false) if _is_body_member() else null
		# A MEMBER with a wrap-bearing record (door, hood, trunk) takes SOLID
		# paint - its UV0 does not share the body's wrap layout - but the
		# paint is the LIVERY's ground colour, not the carpaint constant. The
		# reference (member_mesh.py) reads the dominant lit colour of the
		# variant's vst bake; the wrap sheet's own dominant lit colour is the
		# same answer from data already in hand - ambulance and police white,
		# taxi yellow - where the constant is a near-black 0.02..0.36 that
		# painted every door primer-grey against a white liveried body. That
		# contrast is the user's MP_Aftermath marker: "livery is correct but
		# the mapping doesnt match the model" (task #32; measured by
		# software-rasterising the wrap through every texcoord channel -
		# tools/test_uv32.gd - the body maps correctly through UV0 and the
		# doors are the only mismatch left).
		var member_painted := false
		if wrap == null and slots.has("wrap"):
			var mp = _wrap_paint_of(slots.get("wrap"))
			if mp is Color:
				cm.albedo_color = mp
				member_painted = true
				tex_stats["carpaint_member_paint"] = \
					int(tex_stats.get("carpaint_member_paint", 0)) + 1
			elif not _dress_uv2:
				# A PICTORIAL livery on a member with no tc4 unwrap: the
				# ambulance door and hood. The old reasoning - a member's UV
				# does not share the body's wrap layout - stopped holding the
				# moment the mesh reader started picking the WRAP CHANNEL for
				# carpaint sections by v-fit: where such a channel exists the
				# member's carpaint UV IS the wrap layout, and a user's
				# object-debug recipe confirmed the door and hood both map
				# the wrap correctly through it. Members that carry a real
				# tc4 unwrap (the firetruck doors) keep the detail-overlay
				# path below instead; flat-paint wraps keep the paint above.
				var mtex = _texture_for(slots.get("wrap"), false)
				if mtex != null:
					cm.albedo_texture = mtex
					cm.albedo_color = Color(1, 1, 1)
					member_painted = true
					tex_stats["carpaint_member_wrap"] = \
						int(tex_stats.get("carpaint_member_wrap", 0)) + 1
			# AND WHERE THE MEMBER HAS A REAL SECOND UNWRAP, the wrap goes on
			# over that paint through it. Solid paint is the fallback for a door
			# whose UV0 does not share the body's layout; it is not the answer
			# where the mesh ships a set that DOES.
			#
			# Measured over all 11,875 meshes on this map (tools/fb_uv2census.py):
			# 117 sections of 19,476 carry declB TexCoord4 on its own stream, on
			# 32 meshes, and every one of those meshes is a door or a panel -
			# firetruck doors, delivery-van door panels, semi-trailer rear doors,
			# licence plates. The same set this path already documents as the
			# remaining mismatch, and the same trailer doors dfanz0r found.
			#
			# DETAIL, not albedo_texture, for two reasons that happen to agree:
			# albedo_texture can only sample UV1, and the detail slot composites
			# by the overlay's own alpha - which is what the reference does and
			# what the note below says is missing. The wrap's alpha is already
			# known to be a binary cutout, so paint shows wherever the wrap does
			# not cover.
			#
			# The BODY is deliberately not touched. It is measured correct
			# through UV0, and it is the 0..1 case dfanz0r's rule says must not
			# be redirected - doing so rendered his backdrop impostors flat red.
			if _dress_uv2:
				var wtex = _texture_for(slots.get("wrap"), false)
				if wtex != null:
					cm.detail_enabled = true
					cm.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
					cm.detail_albedo = wtex
					cm.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MIX
					tex_stats["carpaint_member_uv2"] = \
						int(tex_stats.get("carpaint_member_uv2", 0)) + 1
		if wrap != null:
			cm.albedo_texture = wrap
			# The body constant is often near-black (0.0199 on the police SUV),
			# which would multiply the livery down to nothing. Where a wrap is
			# present it is the surface, so the constant stops being a tint.
			#
			# NOT WHAT THE REFERENCE DOES, and worth saying: it composites the
			# wrap over a paint colour taken from the variant's own vst bake
			# (median of the lit pixels - police white, taxi yellow) using the
			# wrap's alpha, so paint shows wherever the wrap does not cover.
			# White is the stand-in until that bake is read; it is right for a
			# wrap that covers the shell and wrong for one that does not.
			cm.albedo_color = Color(1, 1, 1)
			tex_stats["carpaint_wrap"] = int(tex_stats.get("carpaint_wrap", 0)) + 1
		elif slots.has("wrap") and not member_painted:
			tex_stats["carpaint_wrap_skipped"] = \
				int(tex_stats.get("carpaint_wrap_skipped", 0)) + 1
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

	# ---- BACKDROP SMOKE ------------------------------------------------
	# Before the look-key share, like glass and carpaint: a smoke record binds
	# no basecolor, so every one of them keys alike and they would collapse onto
	# whichever material was built first.
	var smk = _smoke_of(slots, consts)
	if smk != null:
		_mat_cache[ck] = smk
		tex_stats["smoke"] = int(tex_stats.get("smoke", 0)) + 1
		tex_stats["materials"] = int(tex_stats["materials"]) + 1
		return smk

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
	#
	# AND THE RECORD'S OWN SWITCH COMES FIRST. The bool constant 0x77d10576 is
	# the shader's alpha-test gate, and a record can bind a REAL, varying mask
	# with the gate OFF: the truckpickup's offroad wheel carries the VAN
	# wheel's cutout sheet as slot filler (the offroad wheel ships no _a of
	# its own), and honouring that mask punched the van wheel's silhouette
	# through the offroad wheel's UVs — tyres that read as damaged on an
	# intact prop. Measured over every record carrying the flag in
	# mp_aftermath's portal_gameplay depot: 182 of 193 records with a real _a
	# sheet set it to 1, and all 11 with it at 0 are exactly this
	# foreign-filler class. Content answers "is it a mask"; the flag answers
	# "does this record USE it". Absent flag = old behaviour, so maps or
	# shader families that never write it are untouched.
	var mask = null
	var gate := _alpha_gate(consts)
	if gate:
		mask = _mask_for(slots.get("alpha"))
	# Material-side decisions ride the trace at surface -1: this resolves per
	# material STATE, not per surface, and the gate is the single most
	# expensive thing to re-derive by hand (it needs the depot record AND a
	# content test on the bound sheet).
	if slots.has("alpha"):
		decide(_dress_name, state_key, var_hash, -1, str(look), [{
			"r": "alpha.gate",
			"in": {"const": "0x%08x" % C_ALPHA_TEST, "v": (1 if gate else 0),
				"bound": str(slots.get("alpha", ""))},
			"out": ("mask" if mask != null else "opaque"),
			"why": ("gate on, " + ("the bound sheet reads as a real mask"
					if mask != null else "the bound sheet is not a mask")
				if gate else
				"gate off, so the bound alpha sheet is foreign filler"),
		}])
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

	# ---- does this sheet carry a smoothness map? -----------------------
	# _cs is colour+smoothness and its ALPHA is the smoothness, which nothing
	# read: every prop drew at a flat roughness 1, so painted metal, glass-fibre
	# panels and bare concrete all came out equally matte. A StandardMaterial3D
	# cannot express it - its roughness_texture MULTIPLIES, and this needs
	# 1 - alpha - so it takes the same shader the masked tint uses, which already
	# samples the sheet and gets the channel for one subtract and no extra fetch.
	#
	# Content test, once per texture, like every other channel here. A sheet with
	# a constant alpha says nothing per texel and keeps the plain material, so
	# this does not convert the whole map to shaders for nothing.
	var bc_guid = slots.get("basecolor_veg", slots.get("basecolor"))
	if bc_guid != null and not slots.has("basecolor_veg") and _smooth_varies(bc_guid):
		var sm = _smooth_material(slots, tint)
		if sm != null:
			_mat_cache[ck] = sm
			_mat_by_look[look] = sm
			tex_stats["smooth"] = int(tex_stats.get("smooth", 0)) + 1
			tex_stats["materials"] = int(tex_stats["materials"]) + 1
			return sm

	var mat := StandardMaterial3D.new()
	var any := false
	# basecolor_veg is the vegetation sheet and takes precedence where both are
	# bound; normal_vt is the architecture normal paired with a tiling basecolor.
	var albedo = _texture_for(slots.get("basecolor_veg", slots.get("basecolor")))
	if albedo != null:
		mat.albedo_texture = albedo
		any = true
	# TERRAIN-BLEND KEYING, from the DATA. nh_89d3ad5e is the depot's terrain
	# colour slot (the engine's object-terrain blending, decoded 2026-08-10);
	# a material that binds it and has NO real base colour of its own - the
	# curb aprons and skirts that drew the flat t_ter_defaulttexture white -
	# exists only to wear the ground. The name is the contract: GLTF export
	# keeps it, and the load-time swap in the map context replaces any
	# material named M_TerrainBlend with the ground-colour shader. Materials
	# with real albedo AND the slot (rocks, rubble) keep their look for now -
	# their partial height-faded blend is the open v1.5.
	if slots.has("nh_89d3ad5e"):
		var bg = slots.get("basecolor_veg", slots.get("basecolor"))
		var bcn := "" if bg == null or walk == null \
			else str(walk.gi.get(str(bg), "")).get_file().to_lower()
		n_blend_slot += 1
		if albedo == null or bcn.begins_with("t_ter_defaulttexture"):
			mat.resource_name = "M_TerrainBlend"
			n_blend_named += 1
	var nrm = _texture_for(slots.get("normal", slots.get("normal_vt")), true)
	if nrm != null:
		mat.normal_enabled = true
		mat.normal_texture = nrm
		any = true
	var emis = _texture_for(slots.get("emissive"))
	if emis == null:
		emis = _lit_sheet(slots)      # a light fixture's glow lives in its own slot
	if emis != null:
		mat.emission_enabled = true
		mat.emission_texture = emis
		# The same switch as the shader path, so a lamp does not depend on which
		# material class it happened to take.
		mat.emission_energy_multiplier = prop_emission
		_emissive_mats.append(mat)
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
		# A TERRAIN-BLEND SKIRT IS THE EXCEPTION to the no-albedo null: it binds
		# nothing precisely because its whole job is to wear the ground, and a
		# null here drew it as Godot's default white - the user's marked curb.
		# The NAMED empty material goes through so the load-time swap can find
		# it and replace it with the ground-colour shader.
		if mat.resource_name == "M_TerrainBlend":
			_mat_cache[ck] = mat
			_mat_by_look[look] = mat
			tex_stats["materials"] = int(tex_stats["materials"]) + 1
			return mat
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
# Is the mesh being dressed the vehicle's BODY, rather than a door, hood, roof
# or other separate panel?
#
# The family meshes end at their index - com_carsuv_01_mesh, com_metrobus_01_mesh
# - and every separate member carries a part name after it:
# com_carsuv_01_door_frontright_mesh, com_metrobus_01_wreck_roof_mesh. So the
# test is whether the name, with "_mesh" removed, ends in a numeric index.
#
# Only the body's UV0 matches the wrap sheet's layout. A member sampled through
# the body's wrap gets a stripe across the wrong place.
func _is_body_member() -> bool:
	if _dress_name == "":
		return true          # unknown: behave as before rather than silently drop it
	var stem := _dress_name.get_file().trim_suffix("_mesh")
	var bits := stem.split("_")
	if bits.is_empty():
		return true
	var last := str(bits[bits.size() - 1])
	return last.is_valid_int()


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


# The wrap's DOMINANT lit colour - the livery's ground paint. A member panel
# (door, hood, trunk) cannot wear the wrap itself (its UV0 islands do not
# share the wrap layout), so it takes solid paint, and this is the paint the
# game family shows: white for an ambulance or police car, yellow for a taxi.
#
# A true mode rather than a median: the ambulance wrap is roughly half red,
# and a per-channel median across a near-even split blends toward pink. Lit
# pixels bucket to a coarse 4-bit grid, the most populous bucket wins, and the
# answer is the average of exactly the pixels in it. Cached per sheet; a
# vehicle family asks once and its doors, hood and trunk all reuse it.
var _wrap_paint_cache := {}


func _wrap_paint_of(file_guid):
	if file_guid == null or str(file_guid) == "":
		return null
	var k := str(file_guid)
	if _wrap_paint_cache.has(k):
		return _wrap_paint_cache[k]
	var out = null
	var tex = _texture_for(file_guid, false, TINT_MASK_PROBE_DIM)
	var an0 = walk.gi.get(k) if walk != null else null
	if an0 != null:
		var an := str(an0).to_lower().trim_suffix(".ebx")
		_tex_cache.erase("%s@%d" % [an, TINT_MASK_PROBE_DIM])
	var img: Image = (tex as Texture2D).get_image() if tex is Texture2D else null
	if img != null:
		var c := img.duplicate() as Image
		if not c.is_compressed() or c.decompress() == OK:
			c.convert(Image.FORMAT_RGBA8)
			var buckets := {}          # 12-bit rgb key -> [count, r, g, b]
			for y in range(c.get_height()):
				for x in range(c.get_width()):
					var p := c.get_pixel(x, y)
					if p.a < 0.5 or maxf(p.r, maxf(p.g, p.b)) < 0.35:
						continue
					var bk := (int(p.r * 15.0) << 8) \
						| (int(p.g * 15.0) << 4) | int(p.b * 15.0)
					var acc: Array = buckets.get(bk, [0, 0.0, 0.0, 0.0])
					acc[0] += 1
					acc[1] += p.r
					acc[2] += p.g
					acc[3] += p.b
					buckets[bk] = acc
			var best: Array = []
			for bk in buckets:
				var acc2: Array = buckets[bk]
				if best.is_empty() or int(acc2[0]) > int(best[0]):
					best = acc2
			if not best.is_empty() and int(best[0]) >= 32:
				var n := float(best[0])
				out = Color(best[1] / n, best[2] / n, best[3] / n)
	_wrap_paint_cache[k] = out
	return out


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
	# AND THE SMOKE AND LIT SHEETS, for the third time and the same reason. A
	# backdrop plume binds none of the slots below either, so every one of them
	# keyed alike and the look-key share answered BEFORE _smoke_of was reached -
	# handing them whatever slotless material was built first, or the null a
	# procedural record had already cached under that key. The smoke block own
	# comment says it must come before the share; it did not.
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
		str(slots.get("basecolor_veg", slots.get("basecolor", ""))),
		str(slots.get("normal", slots.get("normal_vt", ""))),
		str(slots.get("emissive", "")),
		str(slots.get("alpha", "")), t,
		str(slots.get("decal_ca", "")), str(slots.get("decal_nrm", "")),
		str(slots.get("smoke_ca", "")), str(slots.get("emissive_lit", ""))]


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
# The rule, and the reason for it: "alpha is only honored when it looks
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
# three placeholders as cutouts, and that warning is exactly what that
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


# PROP LIGHTING, the emission half. Read by every material builder that binds an
# emissive sheet. 1.0 is the sheet as authored; the panel raises it. Static so
# the dock can set it and re-dress without threading it through every call.
static var prop_emission := 1.0

# EVERY MATERIAL THAT CARRIES A GLOW, so the switch can change one number on a
# few dozen of them instead of rebuilding the map.
#
# Toggling Prop Lighting used to call invalidate_materials, which re-resolves
# every surface from the depot: 13,097 surfaces, MEASURED AT 12.7 SECONDS in the
# user's own log. All of that to change an emission multiplier - and only 53 of
# 1,075 sampled records bind a lit sheet at all, so 99% of the work could not
# change a pixel.
#
# The materials are shared between the map context and the props the builder
# placed (both resolve through _mat_cache), so setting the parameter in place
# updates everything at once with no rebuild and no re-dress.
var _emissive_mats: Array = []


# Returns how many materials it touched. Dead ones are dropped as they are found,
# so a scene change does not leak them.
func set_prop_emission(v: float) -> int:
	prop_emission = v
	var alive: Array = []
	for m in _emissive_mats:
		if not is_instance_valid(m):
			continue
		if m is ShaderMaterial:
			(m as ShaderMaterial).set_shader_parameter("emission_energy", v)
		elif m is StandardMaterial3D:
			(m as StandardMaterial3D).emission_energy_multiplier = v
		alive.append(m)
	_emissive_mats = alive
	return alive.size()

var _smooth_cache := {}                # texture asset -> bool, does its alpha vary


# THE COLOUR SHEETS SMOOTHNESS, or false when its alpha says nothing per texel.
#
# Same instrument and the same law as every other channel test in this file:
# decided on CONTENT, cached per texture, and the probe copy dropped as soon as
# it has answered so it does not sit in video memory behind the full-size sheet.
func _smooth_varies(file_guid) -> bool:
	if file_guid == null or str(file_guid) == "":
		return false
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return false
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	if _smooth_cache.has(an):
		return bool(_smooth_cache[an])
	var small = _texture_for(file_guid, false, TINT_MASK_PROBE_DIM)
	_tex_cache.erase("%s@%d" % [an, TINT_MASK_PROBE_DIM])
	var img: Image = (small as ImageTexture).get_image() if small != null else null
	if img == null:
		_smooth_cache[an] = false
		return false
	var c := img.duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		_smooth_cache[an] = false
		return false
	var lo := 2.0
	var hi := -1.0
	for y in range(0, c.get_height(), maxi(1, int(c.get_height() / 32))):
		for x in range(0, c.get_width(), maxi(1, int(c.get_width() / 32))):
			var a := c.get_pixel(x, y).a
			lo = minf(lo, a)
			hi = maxf(hi, a)
	var varies := (hi - lo) > TINT_MASK_MIN_RANGE
	_smooth_cache[an] = varies
	tex_stats["smooth_checked"] = int(tex_stats.get("smooth_checked", 0)) + 1
	return varies


# THE FIXTURE'S LIT SHEET, or null when the slot holds a placeholder.
#
# 30 of the 53 records that bind this slot bind t_red - constant, alpha 0 - so
# "the slot is bound" means nothing on its own, exactly as with the alpha slot
# and the decal sheets. Rejected on CONTENT: a glow that is the same everywhere
# is not a glow, it is a default.
func _lit_sheet(slots: Dictionary):
	var guid = slots.get("emissive_lit")
	if guid == null:
		return null
	if not _decal_sheet_varies(guid):
		return null
	return _texture_for(guid)


# The same flat-or-not question the decal sheets ask, without the decal-specific
# wrapping, so both can use it.
func _decal_sheet_varies(file_guid) -> bool:
	if file_guid == null or str(file_guid) == "":
		return false
	var asset = walk.gi.get(str(file_guid))
	if asset == null:
		return false
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	if _decal_tex_cache.has(an):
		return bool(_decal_tex_cache[an])
	var small = _texture_for(file_guid, false, TINT_MASK_PROBE_DIM)
	_tex_cache.erase("%s@%d" % [an, TINT_MASK_PROBE_DIM])
	var img: Image = (small as ImageTexture).get_image() if small != null else null
	if img == null:
		_decal_tex_cache[an] = false
		return false
	var c := img.duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		_decal_tex_cache[an] = false
		return false
	var lo := [2.0, 2.0, 2.0, 2.0]
	var hi := [-1.0, -1.0, -1.0, -1.0]
	for y in range(0, c.get_height(), maxi(1, int(c.get_height() / 40))):
		for x in range(0, c.get_width(), maxi(1, int(c.get_width() / 40))):
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
	return varies


var _smoke_shader = null

# BACKDROP SMOKE, or null when this record is not one.
#
# Exclusive in the same way the decal family is: a record that binds a real
# basecolor is a surface that happens to sit near smoke, not the smoke itself.
const C_SMOKE_TINT := 0xD021807F      # the only non-neutral float3 in the record
const C_SMOKE_SCROLL_A := 0xC4C39A0C  # (0.000, 0.100)
const C_SMOKE_SCROLL_B := 0xC4C39A0D  # (0.000, 0.500), the sibling hash
# SIGNED, and per material. 0.080 on the horizontal family, -0.030 and -0.100 on
# the vertical one - which is what a hardcoded 0.08 was standing in for, in the
# wrong direction on two of the three.
const C_SMOKE_DISTORT := 0x4315DC37
# 1.000 on the horizontal plumes, 2.000 on the vertical body, 1.000 on its ramp
# surface. Read as an overall strength; that reading is OURS.
const C_SMOKE_GAIN := 0x3B6C99D6


# The record's alpha-test switch: bool constant 0x77d10576. 1 (or absent, or
# unreadably short) = the mask may be honoured; an explicit 0 = the shader
# never alpha-tests this record, whatever the alpha slot carries. See the
# masked? branch in material_for for the measurement behind it. The name the
# developers gave it is unknown - a 5,000-candidate FNV1 brute force found
# nothing - so it lives here as the hash the depot actually stores.
const C_ALPHA_TEST := 0x77D10576

# THE WRAP TEXCOORD SELECTOR: bool constant 0x4f5f0664 on a carpaint record
# picks which texcoord the livery samples - TexCoord1 when set, TexCoord3
# otherwise. Measured across every real wrap on mp_aftermath: the ambulance
# is the lone 1 and its livery aligns on TC1; the police SUV, the sedan's
# police and taxi wraps and the firetruck are all 0-or-absent and align on
# TC3 (each verified by rasterising the wrap through every channel). Found
# because a user reported "both channels don't map the police livery right"
# from the object debugger - both channels the reader USED to read, that is.
const C_WRAP_TEXCOORD := 0x4F5F0664

# ---------------------------------------------------------------------------
# THE DECISION TRACE
#
# Resolving one section makes a dozen silent choices: which depot record,
# which texcoord, whether the alpha-test gate is on, which textures bound,
# whether a destruction twin hides it. None were recorded, so every "this
# looks wrong" restarted from raw game bytes. The police SUV cost a whole
# session to answer something a trace states in one line: uv.primary chose
# tc3 because wrap flag 0x4f5f0664 was 0.
#
# Rows dedupe on (mesh, state key, variation, surface), because a decision is
# a property of the material STATE and not of the 400 instances sharing it -
# a whole map collapses to a few thousand rows. Instance members rather than
# statics so a live reload cannot leave two half-filled copies (law C4).
var _dec_rows: Array = []
var _dec_seen := {}
var _dec_mx := Mutex.new()      # meshes resolve on the walk's worker threads


func decide(mesh: String, state_key: int, var_hash: int, surface: int,
		material: String, rules: Array, extra := {}) -> void:
	var key := "%s|0x%016x|%d|%d" % [mesh, state_key, var_hash, surface]
	_dec_mx.lock()
	if _dec_seen.has(key):
		_dec_mx.unlock()
		return
	_dec_seen[key] = true
	var row := {
		"key": key, "mesh": mesh, "state": "0x%016x" % state_key,
		"var": var_hash, "surface": surface, "material": material,
		"rules": rules,
	}
	row.merge(extra, true)
	_dec_rows.append(row)
	_dec_mx.unlock()


# Written once per build beside the map's other sidecars. NDJSON so it can be
# streamed and grepped rather than parsed whole (`hp.py decisions <MAP>`).
func flush_decisions(map_name: String) -> String:
	_dec_mx.lock()
	var rows: Array = _dec_rows.duplicate()
	_dec_mx.unlock()
	if rows.is_empty() or map_name == "":
		return ""
	var dir := "user://mapcontext/%s" % map_name
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/decisions.jsonl" % dir
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	for r in rows:
		f.store_line(JSON.stringify(r))
	f.close()
	HighpolyLog.event("build.decisions",
		{"map": map_name, "rows": rows.size(), "path": path})
	return path


func decision_count() -> int:
	return _dec_rows.size()


# Applied after the parse, because the reader has no depot: for each carpaint
# section, resolve its record (variation-derived key first, exactly like
# material_for) and swap the section's uvs to the texcoord the record names.
# uv_all rides along on carpaint sections precisely for this. A section whose
# record or texcoord is missing keeps TC0, which is what it shipped before.
func _wrap_channel_fix(secs: Array, scope: String, var_hash: int,
		mesh_name := "") -> void:
	var pair = null
	var pair_tried := false
	for si in range(secs.size()):
		var sec: Dictionary = secs[si]
		var mat := str(sec.get("material", ""))
		# Every section reports the rule the READER applied, whether or not
		# the depot has anything to say about it: a trace that only covers
		# the interesting cases cannot answer "why is this one normal".
		var rules: Array = [{
			"r": "uv.primary",
			"in": {"family": _uv_family(mat),
				"declared": Array(sec.get("uv_declared", PackedInt32Array()))},
			"out": _tc_name(int(sec.get("uv_usage", -1))),
			"why": "reader rule %s" % str(sec.get("uv_rule", "none")),
		}]
		if not mat.to_lower().contains("carpaint"):
			decide(mesh_name, int(sec.get("state_key", 0)), var_hash, si, mat,
				rules)
			continue
		var all: Array = sec.get("uv_all", [])
		if all.is_empty():
			decide(mesh_name, int(sec.get("state_key", 0)), var_hash, si, mat,
				rules)
			continue
		if not pair_tried:
			pair_tried = true
			pair = _depot_for(scope)
		if pair == null:
			return
		var dep: BF6Depot = pair[0]
		var base := int(sec.get("state_key", 0))
		var key := base
		var derived := false
		if var_hash != 0 and dep.key_to_record.has(key + var_hash):
			key += var_hash
			derived = true
		if not dep.key_to_record.has(key):
			rules.append({"r": "uv.wrap", "in": {"state": "0x%016x" % base},
				"out": "kept " + _tc_name(int(sec.get("uv_usage", -1))),
				"why": "no depot record for this state key"})
			decide(mesh_name, base, var_hash, si, mat, rules)
			continue
		var t: Dictionary = dep.textures_for(key, pair[1])
		var consts: Dictionary = t.get("constants", {})
		var raw = consts.get(C_WRAP_TEXCOORD)
		var present := raw is PackedByteArray \
			and (raw as PackedByteArray).size() >= 1
		var tc1 := present and (raw as PackedByteArray)[0] != 0
		var want := 34 if tc1 else 36
		var applied := false
		for e in all:
			if int((e as Array)[0]) == want:
				var uv: PackedVector2Array = (e as Array)[1]
				var nv: PackedVector3Array = sec.get("verts", PackedVector3Array())
				if uv.size() == nv.size():
					sec["uvs"] = uv
					secs[si] = sec
					applied = true
				break
		rules.append({
			"r": "uv.wrap",
			"in": {"const": "0x%08x" % C_WRAP_TEXCOORD,
				"v": (1 if tc1 else 0), "present": present,
				"key": "derived" if derived else "base"},
			"out": _tc_name(want) if applied else \
				"kept " + _tc_name(int(sec.get("uv_usage", -1))),
			"why": ("wrap flag %s so %s" % ["1" if tc1 else ("0" if present
				else "absent"), _tc_name(want)])
				+ ("" if applied else "; that channel is not on this section"),
		})
		decide(mesh_name, base, var_hash, si, mat, rules)


static func _uv_family(material: String) -> String:
	var m := material.to_lower()
	if m.contains("unique"):
		return "unique"
	if m.contains("carpaint"):
		return "carpaint"
	return "default"


static func _tc_name(usage: int) -> String:
	if usage < 33 or usage > 37:
		return "none"
	return "tc%d" % (usage - 33)


func _alpha_gate(consts: Dictionary) -> bool:
	var raw = consts.get(C_ALPHA_TEST)
	if not (raw is PackedByteArray) or (raw as PackedByteArray).size() < 1:
		return true
	return (raw as PackedByteArray)[0] != 0


func _vec2_const(consts: Dictionary, hash_id: int, fallback: Vector2) -> Vector2:
	var raw = consts.get(hash_id)
	if not (raw is PackedByteArray) or (raw as PackedByteArray).size() < 8:
		return fallback
	return Vector2((raw as PackedByteArray).decode_float(0),
		(raw as PackedByteArray).decode_float(4))


# Mean saturation over the sheet, on a 32x32 reduction. Real smoke albedo is
# near-neutral; a directional-lighting pack is not.
var _litpack_cache := {}

func _is_lighting_packed(tex) -> bool:
	if tex == null:
		return false
	var id: int = tex.get_instance_id()
	if _litpack_cache.has(id):
		return _litpack_cache[id]
	var img: Image = tex.get_image()
	if img == null:
		_litpack_cache[id] = false
		return false
	var s2 := (img.duplicate() as Image)
	if s2.is_compressed():
		s2.decompress()
	s2.resize(32, 32, Image.INTERPOLATE_BILINEAR)
	var tot := 0.0
	var n := 0
	for y in range(32):
		for x in range(32):
			var c := s2.get_pixel(x, y)
			if c.a < 0.05:
				continue
			var mx := maxf(c.r, maxf(c.g, c.b))
			var mn := minf(c.r, minf(c.g, c.b))
			if mx > 0.02:
				tot += (mx - mn) / mx
				n += 1
	var sat := tot / maxf(float(n), 1.0)
	var packed := n > 0 and sat > 0.10
	_litpack_cache[id] = packed
	return packed


func _smoke_of(slots: Dictionary, consts: Dictionary):
	if not slots.has("smoke_ca"):
		return null
	if slots.has("basecolor") or slots.has("basecolor_veg"):
		return null
	var sheet = _texture_for(slots.get("smoke_ca"))
	if sheet == null:
		return null
	if _smoke_shader == null:
		var dir2 := (get_script() as Script).resource_path.get_base_dir()
		var sh = load("%s/smoke.gdshader" % dir2)
		if not (sh is Shader):
			return null
		_smoke_shader = sh
	var m := ShaderMaterial.new()
	m.shader = _smoke_shader
	m.set_shader_parameter("smoke_tex", sheet)
	# IS THIS SHEET COLOUR, OR IS IT LIGHTING? The horizontal family binds a
	# real colour+alpha sheet; the vertical one binds directional lighting
	# packed across RGB, and drawing that as albedo gives a rainbow column.
	# Measured rather than guessed from the filename: a lighting-packed sheet
	# carries chroma a smoke sheet has no reason to have.
	# RAINBOW IS THE PROOF. Whatever these channels mean, they are not colour:
	# drawn as RGB the plume comes out rainbow, which is the one thing every
	# reading agrees is wrong. Averaging them gives one scalar; the download
	# build's crossfade shows one channel at a time. BOTH are greyscale, and the
	# only way to get rainbow is to treat three same-shape channels as a colour.
	#
	# I turned this off an hour ago reasoning from the download build's shader,
	# which reads them as three animation-time samples. That reading may well be
	# right, but it does not license drawing them as colour, and switching it off
	# put the rainbow back. Averaging is the correct STILL of a three-sample
	# sheet; the crossfade adds the animation on top and is the fuller fix.
	m.set_shader_parameter("lighting_packed", _is_lighting_packed(sheet))
	# EITHER NOISE. The horizontal family binds t_tilingnoise_01_rgbm and the
	# vertical one t_tilingnoises_curly_01_d, in different slots; both are the
	# same job.
	var nz = _texture_for(slots.get("smoke_noise", slots.get("smoke_noise2")))
	m.set_shader_parameter("has_noise", nz != null)
	if nz != null:
		m.set_shader_parameter("noise_tex", nz)
	# THE GAME'S OWN EDGE MASK, which replaces an edge fade that was invented.
	var edge = _texture_for(slots.get("smoke_edge"))
	m.set_shader_parameter("has_edge", edge != null)
	if edge != null:
		m.set_shader_parameter("edge_tex", edge)
	# THE BLACKBODY RAMP: a temperature-to-colour strip, and the reason the
	# vertical plumes have a lit base rather than a flat warm tint.
	var ramp = _texture_for(slots.get("smoke_ramp"))
	m.set_shader_parameter("has_ramp", ramp != null)
	if ramp != null:
		m.set_shader_parameter("ramp_tex", ramp)
	var dv = consts.get(C_SMOKE_DISTORT)
	if dv is PackedByteArray and (dv as PackedByteArray).size() >= 4:
		m.set_shader_parameter("distort_amount", (dv as PackedByteArray).decode_float(0))
	var gv = consts.get(C_SMOKE_GAIN)
	if gv is PackedByteArray and (gv as PackedByteArray).size() >= 4:
		m.set_shader_parameter("gain", (gv as PackedByteArray).decode_float(0))
	var t = _albedo_tint({C_SMOKE_TINT: consts.get(C_SMOKE_TINT)}) \
		if consts.has(C_SMOKE_TINT) else null
	var raw = consts.get(C_SMOKE_TINT)
	if raw is PackedByteArray and (raw as PackedByteArray).size() >= 12:
		m.set_shader_parameter("tint", Color(
			(raw as PackedByteArray).decode_float(0),
			(raw as PackedByteArray).decode_float(4),
			(raw as PackedByteArray).decode_float(8)))
	m.set_shader_parameter("scroll_a",
		_vec2_const(consts, C_SMOKE_SCROLL_A, Vector2(0.0, 0.10)))
	m.set_shader_parameter("scroll_b",
		_vec2_const(consts, C_SMOKE_SCROLL_B, Vector2(0.0, 0.50)))
	m.render_priority = 2      # transparent, and it sits over the skyline
	return m


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
	# THE DECAL FAMILY IS EXCLUSIVE, and getting this wrong hijacked ordinary
	# props. An ELECTRICAL BOX binds decal_ca for the warning stickers printed on
	# it, ALONGSIDE its real basecolor t_metalpaintedwhite_02_cs and its
	# normal_vt. Treating "binds a decal slot" as "is a decal" drew the sticker
	# sheet over the whole box, which is exactly what the user reported: the base
	# right, the top wrapped in warning stickers.
	#
	# A real decal binds the decal family and NOTHING ELSE that says "surface":
	# a puddle has no basecolor and no normal, which is the whole reason it needs
	# this path. A prop that has either of those is a prop, and the ordinary path
	# below already knows what to do with it - including ignoring a sticker slot
	# it has no way to project, which is a missing detail rather than a wrong
	# material.
	if slots.has("basecolor") or slots.has("basecolor_veg") \
			or slots.has("normal") or slots.has("normal_vt"):
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
	if emis == null:
		emis = _lit_sheet(slots)      # a light fixture's glow lives in its own slot
	if emis != null:
		m.set_shader_parameter("emission_tex", emis)
		m.set_shader_parameter("use_emission", true)
		m.set_shader_parameter("emission_energy", prop_emission)
		_emissive_mats.append(m)
	return m


# The same shader as the masked tint, used only for its smoothness. Everything
# else is exactly what the plain StandardMaterial3D path builds, so a prop that
# takes this route must not shade differently from its neighbour that does not.
func _smooth_material(slots: Dictionary, tint):
	var albedo = _texture_for(slots.get("basecolor"))
	if albedo == null:
		return null
	if _prop_tint_shader == null:
		var dir := (get_script() as Script).resource_path.get_base_dir()
		var sh = load("%s/prop_tint.gdshader" % dir)
		if not (sh is Shader):
			return null
		_prop_tint_shader = sh
	var m := ShaderMaterial.new()
	m.shader = _prop_tint_shader
	m.set_shader_parameter("albedo_tex", albedo)
	m.set_shader_parameter("use_smooth", true)
	var nrm = _texture_for(slots.get("normal", slots.get("normal_vt")), true)
	if nrm != null:
		m.set_shader_parameter("normal_tex", nrm)
		m.set_shader_parameter("use_normal", true)
	var emis = _texture_for(slots.get("emissive"))
	if emis == null:
		emis = _lit_sheet(slots)      # a light fixture's glow lives in its own slot
	if emis != null:
		m.set_shader_parameter("emission_tex", emis)
		m.set_shader_parameter("use_emission", true)
		m.set_shader_parameter("emission_energy", prop_emission)
		_emissive_mats.append(m)
	# Uniform, as the plain path applies it: the per-texel paint mask is the
	# masked-tint path above and is a separate decision from smoothness.
	if tint is Color:
		m.set_shader_parameter("tint", Vector3((tint as Color).r,
			(tint as Color).g, (tint as Color).b))
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
	# EVERYTHING FROM HERE IS THE TEXTURE COST, and it is timed as one block
	# because that is how it is paid: a miss reads the resource, decodes it,
	# maybe compresses it and uploads it, and there is no useful place to stop
	# the clock in the middle. A hit above costs nothing and is counted, not
	# timed, which is why the two are on opposite sides of this line.
	var _tt := Time.get_ticks_usec()
	var raw := src.get_res(an.get_slice("@", 0) if cap >= 0 else an)
	if raw.is_empty():
		_tex_cache[an] = null
		tex_stats["failed"] = int(tex_stats["failed"]) + 1
		t_tex += Time.get_ticks_usec() - _tt
		return null
	var got := _tex.decode(raw, func(form): return src.get_chunk(str(form)),
		texture_max_dim if cap < 0 else cap)
	if got.is_empty() or not (got.get("image") is Image):
		t_tex += Time.get_ticks_usec() - _tt
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
	# DID THE CAP ACTUALLY CAP. It did not, for a long time: decode() swapped to
	# the embedded chunk and then took that chunk's top level, so a 1024 cap on a
	# 4096 texture returned 2048 and called it done. Counted now, because the
	# whole point of the setting is a memory ceiling and a ceiling that silently
	# lets things through is worse than no ceiling.
	var _cap := texture_max_dim if cap < 0 else cap
	if _cap > 0:
		if img.get_width() > _cap or img.get_height() > _cap:
			tex_stats["over_cap"] = int(tex_stats.get("over_cap", 0)) + 1
		else:
			tex_stats["at_cap"] = int(tex_stats.get("at_cap", 0)) + 1
	# get_data() RETURNED A COPY of every texture, once each, purely to read its
	# length: 3,701 textures on a real map, so 4.1 GB allocated and thrown away
	# to count 4.1 GB. Same defect as the readback in cache_stats, in a place
	# that reads as harmless arithmetic. The size is a function of dimensions and
	# format, so compute it.
	tex_stats["bytes"] = int(tex_stats.get("bytes", 0)) \
		+ HighpolyBcTex.img_bytes(img.get_width(), img.get_height(),
			int(img.get_format()))
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
	t_tex += Time.get_ticks_usec() - _tt
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
	# ONE PARSE PER SCOPE, and a map touches a few dozen of the 15,391 depots the
	# mount carries. Timed anyway: a depot is a large blob and "a few dozen" is a
	# guess that has been wrong before. If this row is seconds rather than
	# milliseconds, the scope index is resolving more scopes than the map has.
	var _td := Time.get_ticks_usec()
	var b := src.get_res(str(name))
	if b.is_empty():
		_depot_cache[scope] = null
		t_depot += Time.get_ticks_usec() - _td
		return null
	var dep := BF6Depot.new()
	_depot_cache[scope] = [dep, b] if dep.parse(b) else null
	n_depot_parsed += 1
	t_depot += Time.get_ticks_usec() - _td
	return _depot_cache[scope]
