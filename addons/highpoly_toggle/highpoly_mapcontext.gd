@tool
extends Node
class_name HighpolyMapContext
# Editor-only "Map Context": injects the real map terrain + the game's original
# object placements as an owner=null "_MAP_CONTEXT" node under the level root.
# Nothing is saved or exported; the SDK level scene stays byte-identical.
#
# EVERYTHING IS READ FROM THE PLAYER'S OWN BATTLEFIELD 6 INSTALL. Placements,
# geometry, textures, terrain, water, roads, lights, FX and ground clutter all
# come out of the game's own files through the reader stack (bf6_source ->
# bf6_walk -> bf6_meshset), and nothing is fetched or redistributed. Derived
# results are cached under user://, keyed on the mounted TOCs' signature so a
# game patch invalidates them.
#
# Props are drawn as one MultiMeshInstance3D per unique mesh (thousands of
# placements, a few hundred draw calls), and streamed by distance from the
# editor camera via a render-radius slider.

const BcTex = preload("highpoly_bctex.gd")        # textures beside a local mesh
const NODE := "_MAP_CONTEXT"
const CACHE := "user://mapcontext"
const POLL_SECS := 0.5          # progress sampling interval
# A local mesh store left over from before the reader. Nothing writes to it now;
# it is still read so a cache built by an older version keeps working, and it is
# where the vegetation scatter's fallback kit models live.
const PROPS_CACHE := "user://mapcontext/_props"

var _active := false               # Map Context enabled at all
var _show_objects := false         # original map objects (props) layer on
var _show_backdrop := false        # distant skyline / out-of-bounds vista layer on
# OFF by default, like the two above.
#
# It shipped ON for one build, on the reasoning that roads had always arrived
# with Extended Terrain and taking that away would be a change nobody asked for.
# That was backwards: the chip exists BECAUSE someone asked to build on bare
# ground, and defaulting it on means switching the ground on and then having to
# switch the streets back off every time. A layer you have to ask for is the
# same contract as Backdrops and Water, and it is one click either way.
var _show_roads := false
var _show_water := false           # rivers / sea layer on
# Set by the dock from its own toggles, because the light and FX layers are
# switched independently of apply() and this object cannot see those buttons.
# Default TRUE so a caller that never sets them gets exactly the old behaviour:
# skipping work is opt-in, and a layer that quietly had no data would be a much
# worse bug than mining data nobody asked for.
var want_lights := true
var want_fx := true
# The Grass chip. OFF by default: the clutter had drawn nothing for months, so
# for most users its arrival would read as a change nobody asked for - and it
# costs instances. The chip makes it a choice, like Roads.
var want_grass := false
var _bd_total := 0                 # skyline build: entries queued
var _bd_done := 0                  # skyline build: entries processed
var _bd_ok := 0                    # skyline build: entries that produced a mesh
var _last_cull_pos := Vector3.ZERO # camera position at the last cull, for pacing
var radius: float = 768.0          # metres; props beyond this are hidden
var _map := ""
var _data: Dictionary = {}
var _cells: Dictionary = {}        # "cx,cz" -> Array[MultiMeshInstance3D] (props)
# Cells replaced by a single baked mesh (highpoly_hlod.gd). Their MultiMeshes
# are hidden deliberately, so the distance cull in apply_radius has to leave
# them alone or it switches the whole cell back on at the next tick.
var hlod_cells: Dictionary = {}
var _cell_size := 64.0
# 0 = use whatever the map package says (64 m today). Anything else overrides it,
# so the batching/culling trade can be measured with the profiler instead of
# argued about. Set from the dock; takes effect on the next scenery build.
static var cell_override := 0

# A casting surface is redrawn once per directional cascade, so it costs about
# five draw calls rather than one. Anything smaller than this stops casting.
#
# Raised 12 -> 20 -> 30 m. At 12 m, shadows were 17,820 of a 48,488-call frame
# on Dumbo even after the skyline left the shadow pass; 20 m took that to 5,592.
# The second raise is for a reason the first one created: once the per-mesh draw
# distance stopped drawing small props at all, what remained in view skewed
# large, and the CASTING SHARE went UP â€” 9% of visible prop surfaces at 20 m
# became 33%, so shadows cost more than the geometry did (5,592 calls against
# 4,227). Culling the small stuff concentrated the casters rather than removing
# them.
#
# What 30 m costs visually is shadows from vehicles, skips, kiosks and market
# stalls. Buildings, containers, trucks, the bridge and the elevated highway are
# all well above it, and those are the shadows that read at street scale.
#
# This constant governs SHADOW CASTING ONLY. The HLOD tier split
# (_set_mmi_lod) and the placed-object cull (highpoly_placedcull.gd) each use
# their own literal 12.0; they happen to match but are not wired to this, so
# changing it here does not quietly move the culling too. An older comment
# claimed all three were "one boundary across the plugin" â€” they never were.
const SHADOW_MIN_EXTENT := 30.0
var _world_min := -2048.0
var _mesh_cache: Dictionary = {}   # model path -> Mesh
# How many source samples to skip between terrain vertices. DERIVED, not set:
# see _step_for. The old Terrain quality dropdown wrote it directly and labelled
# its options in metres, which was wrong twice over - the value is a sample
# stride, and how many metres a sample spans depends on the level.
var terrain_step: int = 2

# THE VERTEX BUDGET, held constant instead of the stride.
#
# The reader now composites the heightfield at whatever resolution the game
# actually holds rather than a fixed 4097 (see BF6Terrain.native_size). A fixed
# stride against a variable source is a mesh whose weight changes per level: the
# same "2" would be a 4 million vertex map on one level and 16 million on the
# next, and 16 million is where the editor stops being usable. Fixing the budget
# and deriving the stride keeps every level costing the same, and on a level with
# finer data the vertices land on real samples instead of repeats.
const TERRAIN_VERTS_PER_SIDE := 2048


# The stride that spends the budget on this level.  meta is the terrain metadata
# (it carries the source resolution).
static func _step_for(meta: Dictionary) -> int:
	var res := int(meta.get("res", 4097))
	return maxi(1, int(round(float(res - 1) / float(TERRAIN_VERTS_PER_SIDE))))
# vegetation scatter (grass/shrub kits from the game's MeshScatteringDatabase);
# a strict no-op for maps whose package carries no scatter.json
const ScatterScript = preload("highpoly_scatter.gd")
var _scatter = ScatterScript.new()
var _scatter_n := 0
# self-healing (v1.5): once per session per map, HEAD the map's packages and
# STALENESS IS A GAME PATCH, and nothing else. There used to be an ETag
# comparison against a registry, and a per-session verification of prop
# hashes from a manifest, because a republished package could change under a
# cache. Nothing is published any more: every derived cache is keyed on the
# mounted TOCs' signature, so patching the game invalidates all of them at
# once and nothing else can.
var last_verify_updates := 0
var _props_verified: Dictionary = {}    # map -> true (this session)

# ---------- non-blocking props build (state) ----------
# apply() stays synchronous for terrain/backdrop/scatter (fast), but the props
# layer (~2k unique GLB parses + MultiMesh builds â€” minutes of work that used
# to freeze the editor) is handed to an incremental background builder; see
# _build_props_async. _build_gen is bumped by _clear(), cancelling any
# in-flight build; is_build_done() lets batch consumers (PhotoMatch's render
# hook) wait for a COMPLETE overlay before shooting.
signal build_progress(done: int, total: int)   # per work-slice + on completion
signal backdrop_progress(done: int, total: int)  # the skyline layer's own lane
# Still declared because the build still reports: stage_progress drives the
# panel's bar, build_finished tells the dock the scenery is up, and
# _props_refresh / _session_checked are read by cleanup_stale.
signal stage_progress(label: String, done: int, total: int)
signal build_finished(built: int)              # completed (not emitted when superseded)
var job_queue: Node = null
var _session_checked: Dictionary = {}   # map -> true
var _props_refresh: Dictionary = {}     # map -> true

# ONE JOB: build. Getting the map objects in used to be three - fetch the
# archive, unpack it, then build - and the panel showed a finished transfer
# beside a build that had not started, which read as a stall. Reading from
# the install there is only the build, so there is only one bar.
const UNPACK_JOB := "Unpacking the level's scenery (2/3)"
const BUILD_JOB_OF3 := "Building the level's scenery (3/3)"
const BUILD_JOB_OF2 := "Building the level's scenery (2/2)"
# which of the two the build should announce; set by whichever fetch path ran
var build_job := BUILD_JOB_OF3
# Per-slice work budget, then the loop hands a frame back.
#
# THE YIELD IS NOT FREE, and at 40 it was most of the build. The loop works for
# BUILD_FRAME_MS and then waits a whole frame; whatever that frame costs is
# added to every slice. With ~2,761 props at roughly 20 ms of real work each,
# a 40 ms budget means a yield every two props â€” so the build pays the frame
# cost about 1,400 times.
#
# Raising it trades editor responsiveness DURING a build for a shorter build.
# The layer is hidden while building (see _begin_build_draw) so the yielded
# frames are cheap, but they are not free, and there is nothing to look at
# while it runs anyway.
#
# Tuned by measurement rather than taste â€” see session.py history.
const BUILD_FRAME_MS := 500         # per-slice work budget (always >=1 mesh per slice)
const BUILD_REPORT_EVERY := 100     # print / progress-file cadence (meshes)
var _pressure_said := -1            # last pressure level announced, so it says it once


# THE SLICE, SHRUNK WHEN THE MACHINE IS SHORT OF MEMORY.
#
# Running out of memory is not a failure the editor reports: the allocation that
# cannot be served takes Godot down with it. So when free memory gets low the
# answer is to keep building and go slower, not to carry on at full speed and
# hope. One user's log recorded 794 MB free at its low point, a 139-second
# main-thread frame, and a map that never finished building after a switch.
#
# Smaller slices help for a reason worth stating, because it is not the obvious
# one: they do not make the finished map any smaller. What they change is the
# TRANSIENT peak and the rate of reclamation. Every yield is a frame boundary,
# and frame boundaries are where Godot frees queued objects and the driver
# retires buffers - a 500 ms slice stacks up hundreds of meshes' worth of
# intermediates before letting go of the frame, where 60 ms reaches the same
# total through eight times as many collection points.
#
# It is deliberately slower. A map that takes three minutes instead of one is a
# map you still get.
func _frame_ms() -> int:
	var p := HighpolyVitals.pressure()
	if p != _pressure_said:
		_pressure_said = p
		if p > 0:
			HighpolyLog.warn(("memory is %s (%d MB free): building in smaller "
				+ "slices, which is slower but survives. Close other "
				+ "applications, or turn off a layer, to speed it back up.")
				% ["critical" if p == 2 else "tight", int(HighpolyVitals.free_mb())])
		else:
			HighpolyLog.info("memory recovered: building at full speed again")
	match p:
		2: return 60
		1: return 150
	return BUILD_FRAME_MS
var _build_gen := 0                 # generation: _clear() bumps it, cancelling in-flight builds
var _building := false              # a background props build is in flight
var _build_done := 0                # mesh groups processed so far
var _build_total := 0               # mesh groups queued
var _build_props := 0               # meshes actually built (parse succeeded)
var _last_report := 0               # _build_done at the last print/file report
var _build_status_base := ""        # apply()'s summary minus the objects part
var _last_status := ""              # exact string the last full apply() returned
var status_label: Label = null      # set by the toggle plugin: live progress target

# ---------------------------------------------------------------------------
# WHERE A BUILD GOES, phase by phase.
#
# The profiler's TIME BY PHASE table is the older half of this and it is still
# fed (every _ph call forwards to HighpolyProfiler.span, so no existing row
# moves or disappears). It has two limits this fixes rather than replaces:
#
#   1. it only records while a RECORDING is running, which is almost never, so
#      an ordinary open leaves no trace of where its minutes went;
#   2. it records milliseconds and a call count and nothing else. "props: load
#      mesh 12.4 s" cannot tell a build that read 2,100 meshes out of the game
#      from one that loaded 2,100 out of a cache, and those are opposite
#      problems: the first wants a faster parser, the second is already solved
#      and the next person to "optimise" it will delete the cache.
#
# So a phase carries its item count and its PROVENANCE, and the table prints
# per-item cost beside the total. A phase that is fast because it was cached
# says so on its own line.
#
# KEPT LOCALLY AS WELL AS FORWARDED. HighpolyProfile.add takes every sample
# (see _ph_forward), but it is off unless someone switched profiling on and it
# does not carry item counts or provenance. This dictionary is what makes the
# table below printable on an ordinary open, which is the only kind of open
# anybody ever complains about.
const PH_INSTALL := "install"       # read out of the player's BF6 install
const PH_CACHE := "cache"           # served from a file this plugin wrote
const PH_MEMORY := "memory"         # already in this process
const PH_MIXED := "mixed"
const PH_ENGINE := "engine"         # Godot did it: parse, upload, draw

var _ph_rows := {}                  # name -> {ms, n, items, from}
var _ph_order: Array = []
var _ph_t0 := 0                     # ticks at the start of the build being timed


func _ph_reset() -> void:
	_ph_rows.clear()
	_ph_order.clear()
	_ph_t0 = Time.get_ticks_msec()
	_yield_reset()


# One phase sample. `ms` is wall time, `items` is how many of whatever the phase
# processes, `from` is where the answer came from.
func _ph(name: String, ms: float, items := 1, from := "") -> void:
	if not _ph_rows.has(name):
		_ph_order.append(name)
		_ph_rows[name] = {"ms": 0.0, "n": 0, "items": 0, "from": from}
	var e: Dictionary = _ph_rows[name]
	e["ms"] = float(e["ms"]) + maxf(0.0, ms)
	e["n"] = int(e["n"]) + 1
	e["items"] = int(e["items"]) + items
	if from != "" and str(e["from"]) != from:
		e["from"] = from if str(e["from"]) == "" else PH_MIXED
	_ph_forward(name, ms, items, from)


# THE ONE PLACE THE SHARED SINKS ARE FED.
#
# HighpolyProfiler.span is the existing phase table and is fed unconditionally,
# so extending this file never costs the old report a row. HighpolyProfile.add
# is the newer per-frame profiler and takes an already-measured span in
# microseconds, which is exactly the shape every call site here already has.
#
# BOTH ARE MAIN-THREAD ONLY. They keep static dictionaries with no lock, so a
# call from a worker is a data race that shows up as a corrupted report or a
# crash rather than a wrong number. Everything in this file runs on the main
# thread; the guard is here so that stays true if something later does not.
func _ph_forward(name: String, ms: float, _items: int, _from: String) -> void:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return
	HighpolyProfiler.span(name, ms)
	HighpolyProfile.add(name, int(ms * 1000.0))


# ---------------------------------------------------------------------------
# THE YIELDED FRAMES, counted and timed one at a time.
#
# "props/skyline: waiting for the yielded frame" was 16.8 s of a 50.9 s build
# and is still about 4 s of 26.2 s, and nobody has ever established WHAT that
# frame is doing. There are two candidates and they want opposite fixes:
#
#   A. the editor is redrawing the terrain, roads, water and whatever else is
#      still visible, which is a fixed cost per frame and only goes away by
#      yielding less often;
#   B. the RenderingServer is flushing the meshes and MultiMeshes the slice just
#      created, which is proportional to what was built and goes away by
#      creating fewer, larger instances.
#
# Both are measured here rather than argued about:
#
#   the regression   every yield records the frame's cost and how many
#                    MultiMeshInstances were created in the slice before it. A
#                    least-squares fit then splits the frame into a fixed part
#                    (A) and a per-new-instance part (B). No extra frames, no
#                    cost, runs on every build.
#   the paired probe every PROBE_EVERY yields, a SECOND frame is awaited
#                    immediately after the first. Nothing is created between the
#                    two, so the second frame is pure (A). first minus second is
#                    (B), measured directly, and it cross-checks the fit.
#
# The probe costs one extra frame per PROBE_EVERY yields and stops after
# PROBE_MAX samples, so it is bounded at a couple of seconds on the worst build
# measured. It stays on because a number nobody collects is a question nobody
# answers, and this one has been open since #70 was filed.
const PROBE_EVERY := 8
const PROBE_MAX := 48

var _yield_lanes := {}              # lane -> stats dictionary


func _yield_reset() -> void:
	_yield_lanes.clear()


func _yield_lane(lane: String) -> Dictionary:
	if not _yield_lanes.has(lane):
		_yield_lanes[lane] = {
			"n": 0, "ms": 0.0, "min": 1e9, "max": 0.0,
			"worst": [],                       # [ms, new instances, draw calls]
			"sx": 0.0, "sy": 0.0, "sxx": 0.0, "sxy": 0.0,
			"probe_n": 0, "probe_first": 0.0, "probe_second": 0.0,
			"draws_first": 0, "draws_last": 0,
			"made": 0,                         # MMIs created across the build
			"hist": [0, 0, 0, 0, 0, 0, 0],     # see YIELD_BUCKETS
		}
	return _yield_lanes[lane]


# A HISTOGRAM, NOT AN AVERAGE. The target is a steady 60 fps, which is a 16.7 ms
# frame, so what matters is how many frames blew past it and by how far. An
# average of 49 ms can be four hundred good frames and one two-second stall, and
# the stall is the only part anybody feels.
const YIELD_BUCKETS := [8.0, 16.7, 33.0, 66.0, 133.0, 500.0]
const YIELD_BUCKET_NAMES := ["under 8 ms", "8 to 16.7 ms", "16.7 to 33 ms",
	"33 to 66 ms", "66 to 133 ms", "133 to 500 ms", "over 500 ms (a stall)"]


# Record one yielded frame. `made` is how many MultiMeshInstances the slice
# before it created, which is the whole point: without it the frame cost is a
# number with no explanation attached.
func _yield_note(lane: String, ms: float, made: int) -> void:
	var e: Dictionary = _yield_lane(lane)
	e["n"] = int(e["n"]) + 1
	e["ms"] = float(e["ms"]) + ms
	e["min"] = minf(float(e["min"]), ms)
	e["max"] = maxf(float(e["max"]), ms)
	e["made"] = int(e["made"]) + made
	var x := float(made)
	e["sx"] = float(e["sx"]) + x
	e["sy"] = float(e["sy"]) + ms
	e["sxx"] = float(e["sxx"]) + x * x
	e["sxy"] = float(e["sxy"]) + x * ms
	var draws := _draw_calls()
	if int(e["draws_first"]) == 0:
		e["draws_first"] = draws
	e["draws_last"] = draws
	var hist: Array = e["hist"]
	var b := YIELD_BUCKETS.size()
	for i in range(YIELD_BUCKETS.size()):
		if ms < float(YIELD_BUCKETS[i]):
			b = i
			break
	hist[b] = int(hist[b]) + 1
	# The five worst frames, by name. An average hides a 900 ms stall inside four
	# hundred 4 ms frames, and the stall is the thing a user actually feels.
	var worst: Array = e["worst"]
	worst.append([ms, made, draws])
	worst.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	if worst.size() > 5:
		worst.resize(5)


func _yield_should_probe(lane: String) -> bool:
	var e: Dictionary = _yield_lane(lane)
	return int(e["probe_n"]) < PROBE_MAX and int(e["n"]) % PROBE_EVERY == 0


func _yield_note_probe(lane: String, first: float, second: float) -> void:
	var e: Dictionary = _yield_lane(lane)
	e["probe_n"] = int(e["probe_n"]) + 1
	e["probe_first"] = float(e["probe_first"]) + first
	e["probe_second"] = float(e["probe_second"]) + second


static func _draw_calls() -> int:
	return int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))


# How many MultiMeshInstances have been created since this LANE last yielded.
#
# PER LANE, because the props and the skyline build concurrently and a single
# counter would credit the skyline's creations to the props lane's next frame
# and ruin both fits. _add_cell_multimeshes is only ever called by the props
# loop and _add_multimesh only by the skyline loop, so attributing at the source
# is exact rather than a guess.
var _mmi_made := 0                  # both lanes, for the summary line
var _inst_made := 0                 # instances inside those MultiMeshes
var _mmi_lane := {"props": 0, "skyline": 0}
var _mmi_seen := {"props": 0, "skyline": 0}


func _mmi_add(lane: String, n: int) -> void:
	_mmi_made += n
	_mmi_lane[lane] = int(_mmi_lane.get(lane, 0)) + n


func _mmi_since_yield(lane: String) -> int:
	var now := int(_mmi_lane.get(lane, 0))
	var d := now - int(_mmi_seen.get(lane, 0))
	_mmi_seen[lane] = now
	return d


# The table. Written to the log rather than only to a profiler report, because
# the profiler has to be recording and the log always is.
func _ph_report(title: String) -> PackedStringArray:
	var out := PackedStringArray()
	if _ph_order.is_empty():
		return out
	var wall := Time.get_ticks_msec() - _ph_t0
	var total := 0.0
	for k in _ph_order:
		# Rows marked "(of which)" are a breakdown of the row above them and are
		# already counted there. Adding them to the sum would push the attributed
		# share past 100% and make the honest gap look like an error.
		if not str(k).ends_with("(of which)"):
			total += float(_ph_rows[k]["ms"])
	out.append("")
	out.append("MAP CONTEXT PHASES  %s  %.1f s wall" % [title, wall / 1000.0])
	out.append("  \"from\" says where the answer came from. A row marked cache is")
	out.append("  cheap only because an earlier run paid for it. Rows marked")
	out.append("  \"(of which)\" break down the row above and are not summed again.")
	out.append("  %-42s %9s %7s %10s %11s  %s"
		% ["phase", "wall", "calls", "items", "each", "from"])
	var keys: Array = _ph_order.duplicate()
	keys.sort_custom(func(a, b): return float(_ph_rows[a]["ms"]) > float(_ph_rows[b]["ms"]))
	for k in keys:
		var e: Dictionary = _ph_rows[k]
		var ms := float(e["ms"])
		var items := int(e["items"])
		out.append("  %-42s %8.2fs %7d %10d %11s  %s"
			% [str(k).left(42), ms / 1000.0, int(e["n"]), items,
			   "" if items <= 0 else ("%.2f ms" % (ms / float(items))),
			   str(e["from"])])
	# The percentage is only meaningful once there is a wall to divide by. It is
	# also the honest bit of the table: everything NOT instrumented lives in the
	# gap, and a low figure means the next thing to time is whatever is missing.
	out.append("  %-42s %8.2fs   of %.2f s wall%s"
		% ["sum of the above", total / 1000.0, wall / 1000.0,
		   "" if wall < 500 else (" (%.0f%% attributed)"
			   % (100.0 * total / float(wall)))])
	return out


# WHAT THE YIELDED FRAMES WERE ACTUALLY DOING. See PROBE_EVERY above for the two
# hypotheses this is built to separate.
func _yield_report(lane: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not _yield_lanes.has(lane):
		return out
	var e: Dictionary = _yield_lanes[lane]
	var n := int(e["n"])
	if n == 0:
		return out
	var ms := float(e["ms"])
	out.append("")
	out.append("YIELDED FRAMES  %s" % lane)
	out.append("  %d frames, %.2f s in total, %.1f ms each on average"
		% [n, ms / 1000.0, ms / float(n)])
	out.append("  fastest %.1f ms, slowest %.1f ms, %d MultiMeshInstances created"
		% [float(e["min"]), float(e["max"]), int(e["made"])])
	if int(e["draws_last"]) > 0:
		out.append("  draw calls in frame: %d at the first yield, %d at the last"
			% [int(e["draws_first"]), int(e["draws_last"])])
	else:
		out.append("  draw calls: none reported (no renderer, or nothing drawn)")
	var hist: Array = e["hist"]
	for i in range(hist.size()):
		if int(hist[i]) > 0:
			out.append("    %-22s %5d frames (%.0f%%)"
				% [str(YIELD_BUCKET_NAMES[i]), int(hist[i]),
				   100.0 * int(hist[i]) / float(n)])
	var worst: Array = e["worst"]
	for w in worst:
		out.append("    worst: %8.1f ms after %4d new instances, %d draw calls"
			% [float((w as Array)[0]), int((w as Array)[1]), int((w as Array)[2])])
	# Least squares over (new instances, frame ms). The intercept is what a
	# yielded frame costs when the slice before it built NOTHING, which is the
	# redraw of what is already on screen; the slope is what each newly created
	# MultiMeshInstance adds, which is the RenderingServer flushing it.
	var sn := float(n)
	var sx := float(e["sx"])
	var sy := float(e["sy"])
	var den := sn * float(e["sxx"]) - sx * sx
	if absf(den) > 1e-6:
		var slope := (sn * float(e["sxy"]) - sx * sy) / den
		var icept := (sy - slope * sx) / sn
		out.append("  fit: %.1f ms fixed per frame + %.2f ms per new instance"
			% [icept, slope])
		var flush := slope * sx
		out.append("  which splits the %.2f s into %.2f s redrawing what was already"
			% [ms / 1000.0, icept * sn / 1000.0]
			+ " there and %.2f s flushing new geometry" % (flush / 1000.0))
	if int(e["probe_n"]) > 0:
		var pn := float(e["probe_n"])
		var f1 := float(e["probe_first"]) / pn
		var f2 := float(e["probe_second"]) / pn
		out.append("  probe: %d paired frames. The frame after a slice cost %.1f ms;"
			% [int(pn), f1]
			+ " the very next frame, with nothing new created, cost %.1f ms." % f2)
		if f1 - f2 > 1.0:
			out.append("  So %.1f ms of a yielded frame is the new geometry being"
				% (f1 - f2)
				+ " flushed, and %.1f ms is the steady redraw." % f2)
		else:
			out.append("  The two are the same, so the cost is the steady redraw of"
				+ " what is already on screen, not the new geometry.")
	else:
		out.append("  probe: no paired frames were taken (the build was too short).")
	return out


func _log_build_phases(title: String, lane: String) -> void:
	for line in _ph_report(title):
		Log.info(line)
	for line in _yield_report(lane):
		Log.info(line)
	if game_source != null and game_source.has_method("build_report"):
		for line in game_source.build_report():
			Log.info(str(line))


# incremental refresh ("Check for Updates"): per-parsed-GLB source stamps plus
# which prop entries each source built, so a cache file overwritten by the
# background re-bake rebuilds JUST its own MultiMeshes â€” no full re-toggle
var _mesh_stat: Dictionary = {}     # glb path -> {"mt": int, "sz": int} at parse time
var _prop_by_src: Dictionary = {}   # glb path -> Array[prop entry] built from it
var _props_dir := ""                # last props build: per-map dir (legacy "glb" paths)
var _props_textured := false        # last props build: textured flag
var _props_mat: Material = null     # last props build: flat study material
var _props_tex_mode := -1           # last props build: detail mode (0/1/2)
var _ctx_tex_mode := -1             # last apply(): detail mode (set_context_shown key)
# WE NO LONGER PROJECT A GROUND PHOTO. The SDK ships its own map-texture
# plugin (addons/bf_portal/terrain_decal) with a toolbar button, and that one is
# the user's: it saves into their scene and they control it. Ours was an
# editor-only twin from before that existed, and keeping a second projector on
# the same ground only ever meant double darkening and a decal that tinted
# high-poly models which already carry their real textures.
#
# The extended terrain does not paint it either. It used to blend the photo in
# as a large-scale colour term, which meant the ground carried the picture
# whether the user wanted it or not and read as a decal we had placed on their
# level. The ground is now the game's own materials alone: per-layer albedo and
# normal from the terrainmaterials palette, blended by the map's real splat
# weights where they exist and by slope where they do not.
#
# The jpg is still fetched and still used — by the vegetation scatter, which
# reads its greenness to decide where grass belongs — so _tile_params,
# _maptile_tex and ensure_maptile all stay.
#
# distant flipbook cards (smoke columns / haze planes) follow the FX switch
static var show_fx_cards := false

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

# tex_mode 1 (High-Poly â€” no textures): neutral SHADED clay, so geometry reads
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
	# lighting / vertex normals â€” so the huge terrain never darkens under the
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

# The SDK's own terrain material (M_LevelTerrain â€” the shiny lime green). Reused
# verbatim on our untextured map-context terrain so it matches the shipped
# playable terrain exactly (same shader/colour/shininess), instead of our flat
# unshaded green. Fetched from the live scene; falls back to our flat green.
func _sdk_terrain_material(root: Node, map: String) -> Material:
	return _sdk_material(root, "%s_Terrain" % map, terrain_material())

# The SDK's own asset placeholder material (M_LevelAssets â€” shiny orange), reused
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

# WHERE the maptile jpg actually lives â€” it moved, and the SDK no longer ships it:
#   <= 1.3.3.0  res://raw/maptiles/<Level>.jpg, shipped with the SDK
#   >= 1.4.1.0  those files are GONE; the stock terrain_decal plugin fetches
#               per-level tiles on demand into addons/bf_portal/terrain_decal/textures/
# Upgraded projects are worse than missing: they keep a stale raw/maptiles/*.import
# whose imported .ctex was never built (1.4.1.0 ships a .gdignore in raw/), so
# ResourceLoader.exists() answers TRUE and load() then fails with three errors per
# call. So we never ask the import system anything: find the jpg ON DISK, newest
# location first, and decode the bytes ourselves (same trick as _layer_tex).
# Nothing on disk = no tile. The SDK's own terrain_decal plugin has a button
# that fetches one; this reads whatever is already there and does without.
const TILE_CACHE := "user://mapcontext/_maptiles"
const Log = preload("highpoly_log.gd")
const SDK_TILE_DIR := "res://addons/bf_portal/terrain_decal/textures/"
const LEGACY_TILE_DIR := "res://raw/maptiles/"
const SDK_CONFIG := "res://addons/bf_portal/bf_portal.config.json"
const TILE_URL_FALLBACK := "https://download.portal.battlefield.com/"

# The SDK ships its own map-texture decal (addons/bf_portal/terrain_decal). Its
# toolbar button SAVES a Decal into the level at Static/<Level>_Decal, and that
# decal projects onto everything under it â€” including high-poly models that
# already carry their real textures. Ours is the editor-only twin: same picture,
# owner=null, and layer-aware so it can't tint them. When theirs is in the scene
# we stand down instead of stacking a second projector on the same ground, since
# two decals means double darkening.
const SDK_DECAL_SUFFIX := "_Decal"
const SDK_BOUNDS := "res://addons/bf_portal/terrain_decal/bounds.json"
static var _sdk_bounds: Dictionary = {}
static var _sdk_bounds_read := false

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

func has_data(map: String) -> bool:
	# An open game source IS data for its map, and needs no download at all.
	if game_source != null and game_source.level == map.to_lower():
		return true
	return FileAccess.file_exists("%s/%s/placements.json" % [CACHE, map])

# ---------- package freshness (ETags) ----------
var _remote_tag: Dictionary = {}

func _purge_terrain_cache(map: String) -> void:
	var dir := "%s/%s" % [CACHE, map]
	var da := DirAccess.open(dir)
	if da == null: return
	for f in da.get_files():
		if f.begins_with("terrain_") and f.ends_with(".res"):
			DirAccess.remove_absolute("%s/%s" % [dir, f])

# ---------- apply / build ----------
# keep_backdrop: apply() has lifted the finished skyline out of the old context
# and will re-parent it into the new one, so its mesh list must survive â€” it is
# what the distance culling walks, and clearing it would leave the skyline
# on screen but unmanaged.
# Can the map objects already on screen be re-parented rather than rebuilt?
#
# Split out of apply() because every one of these clauses is a way to get it
# quietly wrong, and the wrong answers fail in opposite directions: too strict
# and a terrain toggle costs a 231-second rebuild, too loose and the map keeps
# props that no longer match what was asked for.
func _can_keep_props(show_objects: bool, prev_objects: bool, map: String,
		prev_map: String, tex_mode: int, prev_tex_mode: int) -> bool:
	if not show_objects or not prev_objects:
		return false                  # nothing to keep, or nothing was there
	if map != prev_map:
		return false                  # different level entirely
	if tex_mode != prev_tex_mode:
		return false                  # materials are baked per detail mode
	# A HALF-BUILT SET MUST BE REBUILT. The builder filling it is cancelled by
	# the generation bump in _clear, so keeping its partial output strands the
	# map with however many props happened to be placed when the toggle was
	# hit â€” and nothing would ever come back to finish them.
	if _building or _build_total <= 0 or _build_done < _build_total:
		return false
	return true


func _clear(root: Node, keep_backdrop := false, keep_props := false) -> void:
	# cancel any in-flight background props build: the builder re-checks this
	# generation after every await and stops dead once it changes (its nodes
	# are freed with _MAP_CONTEXT below)
	_build_gen += 1
	_building = false
	# The whole overlay is going, so the pooled GPU textures have no materials
	# left pointing at them. Keeping them would hold the map's texture memory
	# across a map switch, which is precisely the leak the pool is meant to cure.
	#
	# Only when nothing survives, though. Dropping the pool while props or the
	# skyline are being kept would leave live materials holding textures the pool
	# no longer knows about, and the layer rebuilt next would upload its own
	# second copy of each — re-introducing the duplication, on the GPU, silently.
	if not keep_backdrop and not keep_props:
		BcTex.release_all()
	# a cancelled build's sidecars describe meshes nobody is going to use; the
	# next build re-parses those props and queues them again
	_side_writes.clear()
	_release_build_draw() # layer nodes go with the overlay freed below
	# A cancelled build never reaches its final report, so its bar would stay on
	# screen for the rest of the session â€” which is what "switching scenes locks
	# up the progress bar" was. Send the terminal value the dock listens for, so
	# whoever owns those lanes closes them.
	if _build_total > 0 and not keep_props:
		build_progress.emit(_build_total, _build_total)
	if _bd_total > 0:
		backdrop_progress.emit(_bd_total, _bd_total)
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
	# The cells ARE the kept props' culling data â€” they index the very
	# MultiMeshInstance3Ds being re-parented, so dropping them would leave the
	# distance culling with nothing to cull.
	if not keep_props:
		_cells.clear()
	if not keep_backdrop:
		_bd_list.clear()
	# drop the in-RAM caches so a re-apply re-reads the on-disk files (picks up
	# prop textures / terrain layers updated since the last apply)
	_mesh_cache.clear()
	_mesh_stat.clear()     # refresh bookkeeping follows the mesh cache
	_prop_by_src.clear()
	_layer_cache.clear()
	_tile_cache.clear()    # re-look-up the maptile (the SDK may have just downloaded one)
	_splat_cache.clear()   # re-read the splat on the next apply
	_cmap_cache.clear()    # and the colour map, which is written beside it
	# remove the maptile decal (editor-only)
	_remove_maptile(root)

# ---------- maptile lookup ----------
# The jpg basename this map draws with â€” "tile" lets a variant map (e.g.
# MP_Aftermath_Portal) reuse another map's tile.
func _tile_name(map: String) -> String:
	return str(MAPTILE_DECALS[map].get("tile", map)) if MAPTILE_DECALS.has(map) else map

# The SDK's own per-level decal box. Exact matches only â€” its "_default" entry is
# a generic 1000 m cube, and a wrongly-sized box would misalign both the decal and
# the terrain shader's map_bounds, which is worse than showing no tile at all.
func _sdk_bounds_for(map: String) -> Dictionary:
	if not _sdk_bounds_read:
		_sdk_bounds_read = true
		if FileAccess.file_exists(SDK_BOUNDS):
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(SDK_BOUNDS))
			if j is Dictionary: _sdk_bounds = j
	var e: Variant = _sdk_bounds.get(map, null)
	if not (e is Dictionary): return {}
	var d: Dictionary = e
	if not (d.has("size") and d.has("position")): return {}
	var s: Array = d["size"]; var p: Array = d["position"]
	return {"pos": Vector3(p[0], p[1], p[2]), "size": Vector3(s[0], s[1], s[2]), "nf": 0.0}

# Placement for this map: our hand-tuned table first (checked against the game
# over many maps), then the SDK's own bounds.json â€” so a map added by a future
# SDK update works immediately instead of waiting on a plugin release.
func _tile_params(map: String) -> Dictionary:
	if MAPTILE_DECALS.has(map): return MAPTILE_DECALS[map]
	return _sdk_bounds_for(map)

# The SDK's saved decal for this level, or null. Its presence means the user
# pressed "Apply Texture" on the 3D toolbar and the decal lives in their scene.
func sdk_decal(root: Node) -> Decal:
	if root == null: return null
	var st := root.get_node_or_null("Static")
	if st == null: return null
	return st.get_node_or_null("%s%s" % [String(root.name), SDK_DECAL_SUFFIX]) as Decal

# First maptile jpg present ON DISK for this map ("" = none). Deliberately
# FileAccess, not ResourceLoader: a stale .import with no imported .ctex passes
# ResourceLoader.exists() and then fails inside load().
func _maptile_path(map: String) -> String:
	var nm := _tile_name(map)
	for p in [SDK_TILE_DIR + nm + ".jpg", "%s/%s.jpg" % [TILE_CACHE, nm], LEGACY_TILE_DIR + nm + ".jpg"]:
		if FileAccess.file_exists(p): return p
	return ""

# Decode it ourselves â€” bypasses Godot's import system entirely, so it works
# from res://, user://, and inside .gdignore'd folders alike.
func _maptile_tex(map: String) -> Texture2D:
	var nm := _tile_name(map)
	if _tile_cache.has(nm): return _tile_cache[nm]
	var t: Texture2D = null
	var p := _maptile_path(map)
	if p != "":
		var img := Image.load_from_file(ProjectSettings.globalize_path(p))
		if img == null:
			Log.error("Ground image for %s downloaded but could not be read (%s)"
				% [map, ProjectSettings.globalize_path(p)])
		if img != null:
			img.generate_mipmaps()
			t = ImageTexture.create_from_image(img)
	_tile_cache[nm] = t
	return t

# ---------- SDK maptile (top-down satellite) ----------
# ---------- the SDK's own ground decal ----------
# We used to inject our own Decal here, projecting the maptile straight down
# onto whatever was beneath it. It is gone: the SDK ships that feature now
# (addons/bf_portal/terrain_decal, "Apply Texture" on the 3D toolbar), it saves
# into the user's scene, and it is theirs to control. Two projectors on one
# piece of ground darken it twice, and ours also tinted high-poly models that
# already carry their real textures.
#
# What is left is the other half of getting out of their way: while Extended
# Terrain is on, THEIR decal is redundant. Our terrain underlies the whole
# footprint, the SDK bowl included, and already carries the map photo as the
# large-scale colour term inside its own shader — so their decal projects a
# second copy of the same picture onto ground that has it, and onto every
# building and prop standing on it.
#
# NON-DESTRUCTIVE, and that matters more here than anywhere else in this file:
# their decal is a SAVED node the user owns. It is hidden, never deleted, never
# reparented, and the value it had is remembered and put back — when Extended
# Terrain goes off, when the overlay is cleared, and when the scene changes.
#
# Keyed by instance id rather than held as a node reference so a freed scene
# cannot strand a dangling pointer, and STATIC so a plugin reload — which builds
# a fresh map context — still knows what it hid.
static var _sdk_decal_was := {}      # decal instance id -> the visible it had


# Hide or restore the SDK's decal. `shown` false hides it, remembering what it
# was; true puts that value back and forgets.
func _set_sdk_decal_shown(root: Node, shown: bool) -> void:
	var dec := sdk_decal(root)
	if dec == null:
		return
	var id := dec.get_instance_id()
	if shown:
		if _sdk_decal_was.has(id):
			dec.visible = bool(_sdk_decal_was[id])
			_sdk_decal_was.erase(id)
		return
	if not _sdk_decal_was.has(id):
		# Remembered BEFORE the write, and only once: hiding twice in a row must
		# not record `false` as the value to restore, which would leave the
		# user's decal off for good with nothing to say why.
		_sdk_decal_was[id] = dec.visible
	dec.visible = false


# Put back every SDK decal we hid, wherever it is. Called on teardown paths that
# do not know which scene they are unwinding.
func restore_sdk_decals() -> void:
	for id in _sdk_decal_was.keys():
		var o = instance_from_id(int(id))
		if o is Decal and is_instance_valid(o):
			(o as Decal).visible = bool(_sdk_decal_was[id])
	_sdk_decal_was.clear()


# Sweep any decal an OLDER version of this plugin injected. Ours was owner=null
# so it can never have been saved into a scene, but it does survive a plugin
# reload inside one session, and after an upgrade there is nothing left that
# would otherwise remove it.
func _remove_maptile(root: Node) -> void:
	if root == null:
		return
	for c in root.get_children():
		if c is Decal and String(c.name).contains(DECAL_NODE):
			root.remove_child(c)
			c.queue_free()


# ---------- near-exact detail terrain (real game ground-layer textures) ----------
# The maptile gives the real large-scale colour; the game's own tiling ground
# layers (albedo + normal, extracted from the terrainmaterials palette) add crisp
# close-up detail. Layer selected by surface slope (flat = ground, steep = cliff).
# Normal is applied in view space (no mesh tangents needed).
# dedicated render layer for our extended terrain, so the SDK maptile decal can
# be told to skip it (the decal only textures the SDK's own terrain + assets)
# Layer 20: "this geometry carries its own ground look". It is a TAG, and no
# longer a protection — that distinction is worth stating because the comments
# here used to claim otherwise.
#
# A Decal only affects the layers in its cull_mask, so this opted our terrain,
# roads and water out of OUR decal, which set cull_mask = ~EXT_TERRAIN_LAYER
# explicitly. Ours is gone. The SDK's decal sets its own mask and projects onto
# everything, so being on this layer buys nothing against it — which is exactly
# why their ground photo showed up on our extended terrain. Standing theirs down
# while Extended Terrain is on is the fix; see _set_sdk_decal_shown.
const EXT_TERRAIN_LAYER := 1 << 19
# layer 19 â€” geometry that already carries real textures (high-poly overlay +
# textured map-context props); the map-tile decal must not project onto it
const TEXTURED_LAYER := HighpolyLib.TEXTURED_LAYER
const TERRAIN_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D ground_alb : source_color, filter_linear_mipmap;
uniform sampler2D ground_nrm : filter_linear_mipmap;
uniform sampler2D cliff_alb : source_color, filter_linear_mipmap;
uniform sampler2D cliff_nrm : filter_linear_mipmap;
uniform float tile_scale = 4.0;          // world metres per detail-texture repeat
uniform float detail_strength = 0.5;
uniform float normal_strength = 0.7;
uniform float slope_lo = 0.35;
uniform float slope_hi = 0.70;
// EXACT splat data, out of terrain block 1's per-layer weight pages. When the
// map's cache has none, splat_slices stays 0 and the shader keeps the slope
// ground/cliff heuristic, so a map without it renders exactly as before.
uniform int splat_slices = 0;            // layer_alb/layer_nrm slice count
uniform vec4 splat_bounds;               // xmin, zmin, sizeX, sizeZ (world)
uniform sampler2D splat_idx : filter_nearest, repeat_disable;  // top-4 table idx (x255)
uniform sampler2D splat_w : filter_linear, repeat_disable;     // top-4 weights (sum=1)
uniform sampler2DArray layer_alb : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray layer_nrm : filter_linear_mipmap, repeat_enable;
uniform float layer_scale[32];           // world metres per repeat, per slice
// THE GAME'S OWN TERRAIN COLOUR MAP (TERRAIN.md 5.3): one BC7 tile per
// streaming-tree node, read out of the player's install and assembled here. The
// engine's terrain material shaders all sample it for large-scale hue, with 0.5
// as the neutral value, so this modulates the detail rather than replacing it.
//
// It is NOT the SDK's maptile. That was a jpg shipped with the SDK, which we
// redistributed and painted over their own decal's job; this is the engine's
// own input, covers the whole footprint instead of the playable bowl, and never
// leaves the machine it was read on.
uniform sampler2D colormap : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 cmap_bounds;                // xmin, zmin, sizeX, sizeZ (world)
uniform bool use_colormap = false;
uniform float cmap_strength = 1.0;
varying vec3 wpos;
varying vec3 wnorm;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	// slope-selected tiling ground detail â€” the legacy heuristic, kept as the
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
		// (linear â€” weights fall to 0 where indices change, hiding idx seams)
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
					// EACH LAYER TILES AT ITS OWN RATE. The layer-graph depot
					// carries a UV tiling constant per layer (0x5707A992,
					// repeats per metre) and dumbo's spread from 4 m to 50 m
					// per repeat. Tiling them all at one rate makes the 50 m
					// layers look like a pattern and the 4 m ones look like
					// mud, which is the visible difference between the game's
					// numbers and an invented one.
					vec2 luv = wpos.xz / max(layer_scale[id], 0.01);
					acc += wi * texture(layer_alb, vec3(luv, float(id))).rgb;
					nacc += wi * texture(layer_nrm, vec3(luv, float(id))).rgb;
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
	// THE GROUND IS THE GAME'S OWN MATERIALS, and nothing else.
	//
	// Per-layer albedo and normal from the game's own layer-graph palette,
	// blended by the map's own splat weights where they exist and by slope where
	// they do not, then modulated by the game's own terrain colour map.
	//
	// The colour map is not the SDK maptile coming back. That was a jpg we
	// shipped and painted over the SDK plugin's own job, so the ground carried
	// their photo whether the user wanted it or not. This is the raster the
	// engine itself multiplies every terrain material by, read from the player's
	// install; 0.5 is its neutral, so a texel at 0.5 leaves the detail exactly
	// as it was. It is also the only thing that gives colour to the 88% of
	// ground whose layer is shader-computed and has no texture to read.
	// IT SETS THE LEVEL, IT DOES NOT MULTIPLY IT.
	//
	// §5.3 calls the colour map 0.5-centred and §15 says the engine "modulates"
	// by it, and reading that as `det * cm / 0.5` is wrong in the way that only
	// shows up on screen: cm reaches 0.94 on this map, so bright ground came out
	// at 1.9x its own albedo, clamped, and the whole world went white.
	//
	// The photograph is a correctly exposed picture of THIS ground, so it is the
	// level; the detail texture varies around it. At a mid-grey detail (0.5) the
	// result is exactly the colour map, and the term is bounded either side so
	// no combination can blow out.
	if (use_colormap) {
		vec2 cuv = vec2((wpos.x - cmap_bounds.x) / cmap_bounds.z,
		                (wpos.z - cmap_bounds.y) / cmap_bounds.w);
		if (cuv.x >= 0.0 && cuv.x <= 1.0 && cuv.y >= 0.0 && cuv.y <= 1.0) {
			vec3 cm = texture(colormap, cuv).rgb;
			float dl = dot(det, vec3(0.3333));
			det = mix(det, cm * clamp(0.75 + 0.5 * dl, 0.5, 1.2), cmap_strength);
		}
	}
	ALBEDO = clamp(det, 0.0, 1.0);
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
static var _tile_cache: Dictionary = {}    # tile name -> Texture2D (null = no tile anywhere)
# ---------- exact splat data, from the game's own terrain layer masks ----------
# user://mapcontext/<map>/splat/{idx.png, w.png, layers.json, lNN_alb/_nrm.png}
# — written by HighpolyGameSource.terrain_surface out of terrain block 1. A map
# whose cache has not been built keeps the slope heuristic.
static var _splat_cache: Dictionary = {}   # map -> Dictionary ({} = none)
var _splat_active := false                 # last _terrain_shader_mat had splat data
var _splat_n := 0                          # its texture-array slice count
# With splat shading the extended terrain (which spans the WHOLE footprint,
# including under the SDK bowl) becomes the ground truth.
#
# Now 0.0 â€” no offset. This was 0.15 m, lifting our terrain so it would win the
# depth test against the SDK's own coincident bowl mesh. That defence is
# obsolete: SdkHide already hides the SDK terrain whenever Extended Terrain is
# shown, so there is nothing left to z-fight with, and the lift was simply
# putting the ground 15 cm above where the heightmap says it is. The heightmap
# is exact to about 5 mm, so any visible offset is ours, not the data's.
#
# If ground flicker ever reappears here, the cause is the SDK bowl becoming
# visible again â€” fix the hiding, not the height.
const SPLAT_LIFT := 0.0

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
			var side := 0
			for i in range(slices):
				var a := Image.load_from_file(ProjectSettings.globalize_path("%s/l%02d_alb.png" % [dir, i]))
				var n := Image.load_from_file(ProjectSettings.globalize_path("%s/l%02d_nrm.png" % [dir, i]))
				if a == null or n == null:
					albs.clear()
					break
				side = maxi(side, maxi(a.get_width(), a.get_height()))
				side = maxi(side, maxi(n.get_width(), n.get_height()))
				a.convert(Image.FORMAT_RGB8); albs.append(a)
				n.convert(Image.FORMAT_RGB8); nrms.append(n)
			# Every slice must be the SAME size. Texture2DArray.create_from_images
			# rejects a mismatched set outright ("All images must share the same
			# dimensions") and leaves a 0-layer texture behind â€” which is NOT null,
			# so every check downstream passes and the shader samples an EMPTY array
			# across the whole map. That is the speckled black / flat grey ground.
			# Dumbo ships l05 at 256 against 512 for l00-l04, so this is a real
			# package shape, not a hypothetical. Scale the odd slices up to the
			# largest rather than costing the good ones detail.
			var resized := 0
			for arr in [albs, nrms]:
				for im in arr:
					if im.get_width() != side or im.get_height() != side:
						im.resize(side, side, Image.INTERPOLATE_LANCZOS)
						resized += 1
					im.generate_mipmaps()
			if resized > 0:
				Log.info("%s terrain: %d splat layer image(s) were not %dx%d and were rescaled to match"
					% [map, resized, side, side])
			if idx_img != null and w_img != null and albs.size() == slices:
				idx_img.convert(Image.FORMAT_RGBA8)   # indices: MUST stay unfiltered/no mips
				w_img.convert(Image.FORMAT_RGBA8)
				var ta := Texture2DArray.new()
				var tn := Texture2DArray.new()
				var ea := ta.create_from_images(albs)
				var en := tn.create_from_images(nrms)
				# A failed array is otherwise completely silent: splat_slices stays
				# set and the shader paints the entire map from nothing. Drop back to
				# the slope-blended layers, which at least look like ground.
				if ea != OK or en != OK or ta.get_layers() == 0 or tn.get_layers() == 0:
					Log.error(("%s terrain: splat texture arrays could not be built "
						+ "(albedo err %d, normal err %d): using the slope-blended "
						+ "layers instead") % [map, ea, en])
					_splat_cache[map] = {}
					return {}
				# PER-SLICE TILING RATE, out of the layer's own shading constant
				# (§9.1's 0x5707A992, repeats per metre). Dumbo's layers run from
				# 4 m to 50 m per repeat, so one shared rate is wrong for most of
				# them. A slice whose layer set no rate keeps the shader default.
				var scales := PackedFloat32Array()
				scales.resize(32)
				scales.fill(4.0)
				var rows: Array = (meta as Dictionary).get("layers", [])
				for i in range(mini(32, rows.size())):
					var mpr := float((rows[i] as Dictionary).get("metres_per_repeat", 0.0))
					if mpr > 0.01:
						scales[i] = mpr
				out = {
					"idx": ImageTexture.create_from_image(idx_img),
					"w": ImageTexture.create_from_image(w_img),
					"alb": ta, "nrm": tn, "slices": slices, "scales": scales,
					"bounds": Vector4(float(wj.get("x0", 0.0)), float(wj.get("z0", 0.0)),
						float(wj.get("size", 1.0)), float(wj.get("size", 1.0))),
				}
	_splat_cache[map] = out
	return out

# The game's terrain colour map for this map, or {} when it has not been built.
#
# Written by HighpolyGameSource.terrain_surface as user://mapcontext/<map>/
# colormap.png, with its world box recorded in the splat set's layers.json —
# the same file, because the two come out of the same block-1 walk and a second
# metadata file is a second thing to keep in step.
#
# Compressed on load. A 4096x4096 RGBA8 is 67 MB resident and this is the
# largest single texture the map context uploads; S3TC takes it to about 11 MB,
# and the earlier VRAM work (15.5 GB -> 6.2 GB) is not worth spending back here.
static var _cmap_cache: Dictionary = {}    # map -> {tex, bounds} or {}

# Whether the ground carries the game's aerial photograph. See the comment at
# the point of use in _terrain_shader_mat for why the default is off.
# OFF, AND BACK OFF AFTER BEING TURNED ON ONCE.
#
# The finding that prompted it still stands: this was declared false and nothing
# in the plugin ever set it, so the colour map is decoded from the game, written
# to disk - 25 s of work on MP_Aftermath, 115 s on MP_Tungsten - and never handed
# to the shader. On maps where almost no splat layer resolves a texture
# (MP_Tungsten paints 27 and 3 have one) that leaves the ground with nothing to
# colour it, which is the "all one texture" complaint.
#
# The first attempt to turn this on made the terrain WORSE - random colours
# over teal - and the note that stood here concluded the shader path was
# suspect. It was not: the DECODE was wrong. detect_layout picked the wrong
# page size on nine of sixteen maps and the colour "tile" was sliced from the
# tail of a two-tile trailer, i.e. from a different raster (docs/MAP-TUNGSTEN.md
# and docs/GROUND-LAYERS.md carry the whole post-mortem, including the reverted
# red/blue swap that treated a symptom of those wrong bytes as a channel-order
# bug). The decode is now verified against pictures: corrected assemblies of
# Tungsten and Aftermath are recognisable aerial photographs whose means match
# the SDK's own overhead renders.
#
# ON, because for the majority of ground - the shader-computed layers that
# bind no texture, 72% of Tungsten - the colour map is not a decoration, it is
# the only colour the install ships for that ground, and it is the same data
# path the engine itself uses at distance. cmap_strength below is the knob:
# 1.0 would REPLACE the textured layers' own hue too, which is wrong in the
# other direction, so it ships below 1.0.
static var colormap_enabled := true
# How strongly the colour map steers the composed ground colour where textured
# detail exists (the shader mixes toward a level-set of the photo by this
# factor). Textureless fallback ground effectively has nothing else, so it
# benefits at any setting; 0.75 keeps the three-ish textured slices' detail
# visible underneath rather than flattening them into the photo.
static var colormap_strength := 0.75


func _colormap_set(map: String) -> Dictionary:
	if _cmap_cache.has(map):
		return _cmap_cache[map]
	var out: Dictionary = {}
	var png := "%s/%s/colormap.png" % [CACHE, map]
	var meta_path := "%s/%s/splat/layers.json" % [CACHE, map]
	if FileAccess.file_exists(png) and FileAccess.file_exists(meta_path):
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		var box: Variant = (meta as Dictionary).get("colormap", null) \
			if meta is Dictionary else null
		if box is Dictionary:
			var img := Image.load_from_file(ProjectSettings.globalize_path(png))
			if img != null and img.get_width() >= 4:
				img.generate_mipmaps()
				if not img.is_compressed():
					img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
				var bd: Dictionary = box
				# Per-axis spans. layers.json writes "size" from the X span and,
				# since the layout fix, "size_z" from the Z span; every observed
				# footprint is square, so the fallback to the X span is safe on
				# old caches and only a NON-square map would ever notice.
				var sz := float(bd.get("size", 8192.0))
				var sz_z := float(bd.get("size_z", sz))
				out = {
					"tex": ImageTexture.create_from_image(img),
					"bounds": Vector4(float(bd.get("x0", -4096.0)),
						float(bd.get("z0", -4096.0)), sz, sz_z),
				}
	_cmap_cache[map] = out
	return out


# Detail-layer texture for a map: prefer the PER-MAP layer shipped in the map
# package (user://mapcontext/<map>/terrain_layers/<name>.png â€” the real ground/
# cliff set that map streams in game), falling back per file to the plugin's
# bundled default set.
static var _flat_cache: Dictionary = {}


# A 1x1 stand-in, shared, so an absent detail texture is a neutral sample rather
# than an undefined sampler.
static func _flat_tex(c: Color) -> Texture2D:
	var k := c.to_html(false)
	if _flat_cache.has(k):
		return _flat_cache[k]
	var img := Image.create_empty(1, 1, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, c)
	var t := ImageTexture.create_from_image(img)
	_flat_cache[k] = t
	return t


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
	# NO BUNDLED FALLBACK. What used to be here loaded a cliff/ground set that
	# shipped inside the addon - Battlefield art, ~2 MB, and still present in an
	# install long after it left the repo. The per-map set above is derived from
	# the level's OWN palette and written to the cache, so a map that has been
	# read has real layers; one that has not gets none, and no texture is the
	# honest answer rather than another level's rock.
	_layer_cache[key] = t
	return t

# Build the detail-terrain material for this map, or null when the ground-layer
# set isn't available.
#
# IT NO LONGER NEEDS THE MAPTILE, and that is not just a dropped parameter: this
# used to return null when no maptile jpg could be found, so a map with the full
# ground-layer set and no photo got NO detail material at all and fell back to
# flat colour. The photo is the SDK's business now; the ground layers are ours,
# and they are the only thing this actually requires.
func _terrain_shader_mat(map: String) -> ShaderMaterial:
	var ga := _layer_tex(map, "ground_alb"); var gn := _layer_tex(map, "ground_nrm")
	var ca := _layer_tex(map, "cliff_alb"); var cn := _layer_tex(map, "cliff_nrm")
	# A MISSING SLOPE TEXTURE NO LONGER COSTS THE WHOLE MATERIAL.
	#
	# These four used to be a hard requirement, so a map with the game's colour
	# map and its full splat set would still fall back to flat vertex colour
	# because one fallback png had not been written. They are the fallback; the
	# splat and the colour map are the content. A neutral stand-in keeps the
	# sampler defined and lets the parts that did build do their job.
	if ga == null: ga = _flat_tex(Color(0.5, 0.5, 0.5))
	if ca == null: ca = _flat_tex(Color(0.5, 0.5, 0.5))
	if gn == null: gn = _flat_tex(Color(0.5, 0.5, 1.0))
	if cn == null: cn = _flat_tex(Color(0.5, 0.5, 1.0))
	if _tshader == null:
		_tshader = Shader.new(); _tshader.code = TERRAIN_SHADER
	var m := ShaderMaterial.new()
	m.shader = _tshader
	m.set_shader_parameter("ground_alb", ga); m.set_shader_parameter("ground_nrm", gn)
	m.set_shader_parameter("cliff_alb", ca); m.set_shader_parameter("cliff_nrm", cn)
	# THE COLOUR MAP, if the map's cache has one AND the user asked for it.
	#
	# OFF BY DEFAULT, and that is a decision rather than caution. Painting the
	# game's aerial photograph onto the ground reads as a decal being placed on
	# the user's level — it is what the SDK's own Apply Texture button does, it
	# is under their control there, and the first time this plugin did it
	# uninvited the reaction was to have it taken out. It came back the moment
	# the ground got a colour map and drew exactly the same reaction, which is
	# twice the same answer to the same question.
	#
	# So it is a switch. What is not optional is everything the same block-1 walk
	# produces underneath it: the splat, the layer palette and the base field are
	# the game's materials, not a picture of them, and those stay on.
	#
	# Deliberately independent of the splat: a map whose splat did not build
	# still gets the colour map if it is asked for. Tying the two together would
	# mean one failure costing both.
	var cm := _colormap_set(map) if colormap_enabled else {}
	if not cm.is_empty():
		m.set_shader_parameter("colormap", cm["tex"])
		m.set_shader_parameter("cmap_bounds", cm["bounds"])
		m.set_shader_parameter("use_colormap", true)
		# NEVER left at the shader's default. The uniform defaults to 1.0, and
		# mix(det, cm, 1.0) REPLACES the textured layers' colour with the photo
		# - a correct decode at full strength still flattens every layer that
		# has real detail. Set explicitly, always, from the one knob.
		m.set_shader_parameter("cmap_strength", colormap_strength)
	else:
		m.set_shader_parameter("use_colormap", false)

	# exact splat blend where the map cache holds the game's own weight pages;
	# without it splat_slices stays 0 and the shader keeps the slope heuristic
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
		if sp.has("scales"):
			m.set_shader_parameter("layer_scale", sp["scales"])
		_splat_active = true
		_splat_n = int(sp["slices"])
	return m

# READ FROM THE GAME INSTEAD OF THE DOWNLOAD.
#
# Set by whoever opened a HighpolyGameSource; null means the old path. It is
# NOT opened here on demand, deliberately: a cold open is ~85 s (mounting the
# install, indexing 223k partition guids, walking the level), and _load_data is
# called from the middle of a build on the main thread. Opening it here would
# freeze the editor for a minute and a half with no way to show progress.
#
# So the contract is: the caller opens it, asynchronously, with a progress bar,
# and hands over something already usable.
var game_source = null


# Mine one optional map_data section NOW, for a layer that is being switched on
# after a build chose not to build it.
#
# THIS IS WHAT MAKES SKIPPING SAFE. The light and FX layers read the files
# map_data writes, and they read them directly rather than through map_data - so
# without this a skipped section would mean a layer that switches on, finds
# nothing and shows nothing, which is far worse than mining data nobody asked
# for. Returns whether the section is present afterwards.
func ensure_section(name: String) -> bool:
	if game_source == null or _map == "":
		return false
	var want := {}
	want[name] = true
	var d: Dictionary = game_source.map_data("%s/%s" % [CACHE, _map], want)
	_data = d
	return d.has(name)


func _load_data(map: String) -> bool:
	# The game source carries its own placements, in this exact shape, so the
	# whole build path below is unchanged — see highpoly_gamesource.map_data().
	if game_source != null and game_source.level == map.to_lower():
		# The cache directory is passed because the terrain builder takes a
		# FILE: the heightfield is decoded from the install and written there.
		# That is a file derived from the player's own game, not a download.
		# The drape must sample the same lattice this context meshes the
		# terrain on, or the roads sit on a surface nobody draws.
		# ONLY WHAT THE LAYERS THAT ARE ON NEED. Mining lights, FX and water for
		# an apply that draws none of them was 64 s of a 74 s terrain-only apply
		# in a user's log. Anything skipped is mined the moment its layer is
		# switched on, so this costs nothing later.
		_data = game_source.map_data("%s/%s" % [CACHE, map], {
			"lights": want_lights, "fx": want_fx, "water": _show_water,
			"edv": _show_objects,
		})
		# AFTER map_data, not before: the stride is derived from the terrain
		# metadata, and map_data is what produces it. Setting drape_step from a
		# stale stride put the roads on a lattice the terrain was not meshed on.
		var _tm: Variant = (_data as Dictionary).get("heightmap", {})
		if _tm is Dictionary and not (_tm as Dictionary).is_empty():
			terrain_step = _step_for(_tm as Dictionary)
		game_source.drape_step = terrain_step
		_map = map
		_world_min = float((_data["world"] as Dictionary).get("min", -2048))
		_cell_size = float(cell_override) if cell_override > 0 else 512.0
		_load_prop_layers(map)
		return true

	var p := "%s/%s/placements.json" % [CACHE, map]
	if not FileAccess.file_exists(p): return false
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary): return false
	_data = d
	_map = map
	var w: Dictionary = d.get("world", {})
	_world_min = float(w.get("min", -2048))
	# The cell does double duty: it is the batching grain AND the culling grain.
	#
	# Props are bucketed into one MultiMesh per mesh PER CELL, so at the packaged
	# 64 m Dumbo builds 13,407 MultiMeshes for 44,925 instances, 3.4 each, and
	# 48% of them hold a SINGLE instance. That is a MultiMesh with all of the
	# overhead and none of the benefit, which is why the measured flyover showed
	# draw calls tracking object count 1:1 (0.92) and 156,177 of them at the worst
	# frame, with fps correlating at -0.87.
	#
	# Coarsening trades one cost for another and the balance is not obvious:
	#   64 m  13,407 nodes    128 m  9,055    256 m  5,755    512 m  4,230
	# but a bigger cell also shows more geometry (a 512 m cell reaches ~1.16 km at
	# an 800 m radius against ~845 m for 64 m cells, so roughly 89% more
	# instances). Instances inside a MultiMesh are nearly free while draw calls
	# are not, so the trade should be favourable -- "should" being why this is a
	# setting to measure rather than a constant to guess.
	# MEASURED, at last. The note above ends "this is a setting to measure rather
	# than a constant to guess", and nothing ever had. On the Dumbo flight,
	# everything on, no cull, after the skyline merge:
	#
	#     64 m   12,611 draws   25.2 ms median
	#    256 m    5,777 draws   16.2 ms
	#    512 m    4,472 draws   11.0 ms   <- the knee
	#   1024 m    5,299 draws   14.7 ms
	#
	# It turns back upward at 1024 exactly as the note predicted: a coarser cell
	# batches better but reaches further, so past some size the extra geometry it
	# drags into view costs more than the draw calls it saved.
	#
	# 512 is the default rather than the per-map value, because every map already
	# cached ships "cell": 64 and would otherwise keep the old behaviour forever.
	_cell_size = float(cell_override) if cell_override > 0 else 512.0
	_load_prop_layers(map)
	return true

# ---------- per-layer prop attribution (prop_layers.json) ----------
# Mined per-instance layer tags: 89.9% of placements are always-on; the rest
# belong to event layers (default summer vs winter dressing, gauntlet) or
# per-gamemode containers (Rush barriers...). The builder splits those
# instances into layer GROUPS whose visibility follows the Variant dropdown â€”
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
	# NO MODE MAP: the selection IS a layer name.
	#
	# _mode_map came from prop_layers.json, written by a miner that no longer
	# exists, so it is empty on every map - and with it empty this function
	# returned "default_event only" for every mode, which meant picking a mode
	# changed nothing at all. The layers are now discovered from the subworlds
	# the placements came out of, so the honest reading of "winter_event" or
	# "rush" is: show the normal dressing AND that layer.
	#
	# Additive, which is what highpoly_gamemode.gd's own header says these are:
	# "modes share all scenery in BF6 - these are ADDITIVE gameplay markers, not
	# prop swaps".
	if mode != "" and mode != "Off":
		act[mode] = true
	return act


# The switchable layers this map actually has, from the placements themselves.
#
# Available as soon as map data is loaded, so the dropdown can be filled before
# anything is built. Sorted, and the always-on entries ("") are not layers.
func available_layers() -> Array:
	var out := {}
	for e in (_data.get("props", []) as Array):
		var l := str((e as Dictionary).get("layer", ""))
		if l != "" and l != "default_event":
			out[l] = true
	var a: Array = out.keys()
	a.sort()
	return a

func _variant_key_visible(key: String, act: Dictionary) -> bool:
	for part in key.split(","):
		if act.has(part):
			return true
	return false

# live layer switch â€” pure visibility flips, no rebuild
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

# The distant flipbook cards â€” the big camera-facing planes the level uses for
# smoke columns and haze. They arrive as ordinary props (the baker tags their
# material "__fxanim3" and _fx_animate_materials swaps it to fx_smoke.gdshader),
# so nothing gated them: they came in with "Original map objects" and, being
# hundreds of metres across and drawn near the skyline, they sit in front of the
# surroundings you actually wanted to look at.
#
# They are an EFFECT, not scenery, so they belong to the FX switch. Routed into
# their own group under Props whose visibility follows it.
static func _is_fx_card(m: Mesh, asset_name := "") -> bool:
	# Name first: the material tag is not reliable on its own. Measured on
	# Dumbo, the level carries 4 of these sheets over 23 placements, and only
	# ONE of the four has an "__fxanim3" material â€” so tag-only detection caught
	# 2 of 23 instances and the rest still arrived with the map objects. The
	# assets are named for what they are: ob_fx_bd_* is object / FX / backdrop.
	var n := asset_name.to_lower()
	if n.begins_with("ob_fx_") or n.contains("_fx_bd_"):
		return true
	if not (m is ArrayMesh):
		return false
	var am := m as ArrayMesh
	for i in range(am.get_surface_count()):
		var mat := am.surface_get_material(i)
		# post-swap: already a ShaderMaterial running the flipbook shader
		if mat is ShaderMaterial:
			var sh: Shader = (mat as ShaderMaterial).shader
			if sh != null and String(sh.resource_path).ends_with("fx_smoke.gdshader"):
				return true
		# pre-swap (or a sidecar baked before the swap existed): the baker's tag
		elif mat is BaseMaterial3D and String(mat.resource_name).contains("__fxanim3"):
			return true
	return false


func _fx_cards_group(props_root: Node3D) -> Node3D:
	var g := props_root.get_node_or_null("FXCards")
	if g != null:
		return g as Node3D
	var n := Node3D.new()
	n.name = "FXCards"
	props_root.add_child(n)
	n.owner = null
	n.visible = show_fx_cards
	return n


# Flip the flipbook cards without rebuilding. Returns false when no card layer
# exists yet, so the caller can decide whether a rebuild is warranted.
func set_fx_cards_shown(root: Node, on: bool) -> bool:
	show_fx_cards = on
	var gs := _fx_card_groups(root)
	if gs.is_empty():
		return false
	for g in gs:
		(g as Node3D).visible = on
	return true


# Flip the water layer without rebuilding, same contract as the others.
func set_water_shown(root: Node, on: bool) -> bool:
	_show_water = on
	if root == null:
		return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null:
		return false
	var w := ctx.get_node_or_null("Water")
	if w == null:
		return false
	(w as Node3D).visible = on
	return true


# Every FXCards group under the overlay, wherever it was parented. Both the
# props and the backdrop builders can create one, because which layer a level
# files its smoke sheets under is the level's choice, not ours.
func _fx_card_groups(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	var ctx := root.get_node_or_null(NODE)
	if ctx == null:
		return out
	var stack: Array = [ctx]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c.name == "FXCards":
				out.append(c)
			else:
				stack.append(c)
	return out


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
# (preferred), `glb` = legacy per-map bundle. "" = res:// SDK proxy / none â€”
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

# A prop's mesh: the EXACT game mesh, read from the player's own install
# bundle (`glb`) when available â€” the accurate path â€” else the res:// SDK proxy
# (`model`) fallback for meshes we haven't extracted yet.
func _prop_mesh(e: Dictionary, dir: String) -> Array:
	# FROM THE INSTALL, when the map came from there. `mesh` is a MeshSet res
	# name rather than a cached file stem, and this is the only place that
	# distinction exists — everything downstream just gets a Mesh.
	#
	# TEXTURED. Each section's shader state key resolves through the
	# ShaderBlockDepot of the scope it was placed under, which is what
	# game_source.material_for does — so these arrive dressed, not bare. (This
	# note used to say the opposite; the depot chain landed and the comment did
	# not, which is exactly how a reader gets called "untextured" for a week
	# after it stopped being.)
	if game_source != null and bool(_data.get("from_game", false)):
		var key := str(e.get("mesh", ""))
		if _mesh_cache.has(key):
			return _mesh_cache[key]
		var gm: Mesh = game_source.mesh_for(key)
		var got: Array = [gm] if gm != null else []
		_mesh_cache[key] = got
		return got

	var gp := _prop_path(e, dir)
	if gp == "":
		if not e.has("model"):
			return []
		var pm := _mesh_for(str(e["model"]))
		return [pm] if pm != null else []
	if _mesh_cache.has(gp): return _mesh_cache[gp]
	# stamp the source BEFORE parsing: if the background re-bake overwrites the
	# file mid-parse, the recorded (pre-write) stamp differs from the new one
	# and refresh_changed_props still catches it. Missing files stamp mt=0, so
	# a mesh that APPEARS later counts as changed too.
	_mesh_stat[gp] = {
		"mt": FileAccess.get_modified_time(gp) if FileAccess.file_exists(gp) else 0,
		"sz": _file_size(gp),
	}
	var m: Array = await _parse_prop_file(gp)
	_mesh_cache[gp] = m
	return m

# "Fast startup cache" (Storage section): after the first parse each finished
# mesh is saved as a binary sidecar (<x>.glb.baked.res) and loaded directly on
# later builds â€” skipping the glTF parse + texture recompress + merge that made
# every editor/plugin restart re-chew ~2k GLBs for minutes. A sidecar older
# than its GLB (re-download / re-bake) is stale and re-parses, so updated
# models flow through exactly like Check for Updates. Costs ~the model cache's
# size again on disk; per-map purge removes sidecars with their GLBs.
static var mesh_cache_enabled := false

# Does this mesh still carry real texture pixels? True when it has no textured
# material at all (an untextured prop has nothing to lose), false only when a
# material points at a texture that has been reduced to a 0x0 stub. Used to
# decide whether a cached mesh may be trusted and whether one is worth writing.
# --- VRAM: compress prop textures -------------------------------------------
# Textures that arrive through GLTFDocument at runtime NEVER pass through
# Godot's importer, so nothing ever applies VRAM compression to them. Measured
# on the shipped props: every single one is uncompressed RGB8 or RGBA8, 147 MB
# of GLB decodes to 639 MB resident, and a background prop costs 10.65 MB of
# video memory. Dumbo peaked at 8526 MB, which is why a 12 GB card ran out
# during the terrain build and Godot answered VK_ERROR_OUT_OF_DEVICE_MEMORY by
# handing back a null buffer and then segfaulting.
#
# S3TC gives 5.1x on those same textures, half-res-plus-S3TC 20.4x. Measured
# cost: first bake +12%, but the sidecar is then HALF the size and reads back
# 1.9x faster, so every load after the first is quicker. Because the sidecar
# stores its materials, compressing before the save bakes it in permanently.
#
# NORMAL MAPS GET BC5 (two channels), not BC1/BC3. Compressing a normal map as
# DXT puts visible banding on every curved surface â€” it is the classic mistake
# with this optimisation, and the fix costs one branch.
enum { VRAM_FULL = 0, VRAM_COMPRESSED = 1, VRAM_LOW = 2 }
static var vram_mode := VRAM_COMPRESSED

# Sidecars are per vram mode: the pixels differ, so serving one baked under
# another would silently show the wrong quality with no way to tell.
# One numbered file per mesh of a split prop. Carries the vram mode for the same
# reason the single-mesh suffix does: the three settings must not serve each
# other's pixels.
func _part_suffix(i: int) -> String:
	return "%s.p%d.res" % [_baked_suffix().trim_suffix(".res"), i]


func _baked_suffix() -> String:
	match vram_mode:
		VRAM_LOW: return ".baked5l.res"
		VRAM_FULL: return ".baked5f.res"
		_: return ".baked5.res"


# The SHIPPED bake, as opposed to the three above which a user's own machine
# wrote. No vram mode in the name because there are no pixels in the file.
const GEOM_SUFFIX := ".geom.res"


func _geom_part_suffix(i: int) -> String:
	return ".geom.p%d.res" % i


# Set while the pipeline is baking the files we publish, so the lossy material
# passes and the texture compression are left for the client to apply.
static var bake_geometry_only := false


# Load a prop from its shipped geometry bake and hang the sidecar textures on
# it. Returns [] if there is no bake, or if it is unusable â€” every caller falls
# back to the glb, so a bad file costs a parse and never a broken prop.
func _load_geom_tier(gp: String) -> Array:
	# A BAKE WITHOUT A SIDECAR IS ONLY SAFE IF THE PROP HAS NO PIXELS TO LOSE.
	# The bake carries geometry and materials but no textures â€” they are meant
	# to come from the .bctex beside it. If that is missing while the glb still
	# holds its own images, using the bake silently renders the prop white; the
	# glb is right there and still complete, so use it.
	#
	# The pipeline never ships that pairing. A cache can still arrive at it: the
	# registry pass replaces a stripped glb with the model library's textured
	# copy and leaves the bake behind. One header read, and only for props with
	# no sidecar, which after a healthy fetch is almost none of them.
	if not BcTex.exists(gp) and not _glb_has_no_images(gp):
		return []

	# TIMED SEPARATELY from the texture work below it. "props: load mesh" is
	# 17.0 s over 2,761 props and covers this whole function; without splitting
	# it there is no way to tell reading 74 KB of geometry off disk from the
	# material and texture work that follows, and they want completely different
	# fixes.
	var _tg := Time.get_ticks_msec()
	var meshes: Array = []
	if FileAccess.file_exists(gp + _geom_part_suffix(0)):
		# A split prop ships numbered parts, exactly as the local cache does.
		# ALL OR NOTHING: a prop missing one of its meshes renders as a fragment,
		# which reads as a bad model rather than a bad file.
		var i := 0
		while FileAccess.file_exists(gp + _geom_part_suffix(i)):
			var pm := ResourceLoader.load(gp + _geom_part_suffix(i), "Mesh",
				ResourceLoader.CACHE_MODE_REPLACE)
			if not (pm is Mesh):
				return []
			meshes.append(pm)
			i += 1
	elif FileAccess.file_exists(gp + GEOM_SUFFIX):
		var bm := ResourceLoader.load(gp + GEOM_SUFFIX, "Mesh",
			ResourceLoader.CACHE_MODE_REPLACE)
		if not (bm is Mesh):
			return []
		meshes.append(bm)
	if meshes.is_empty():
		return []

	# CACHE_MODE_REPLACE above, matching the local cache tier, and for the same
	# reason: it re-reads the file into the cached object rather than handing
	# back whatever a previous build left there. Without it a mesh that had
	# already been through the wind swap and the VRAM compression would come
	# back already swapped and already compressed, and get both applied a second
	# time. Copying the meshes instead would be correct too and would also undo
	# the entire saving â€” rebuilding every vertex array is most of the work the
	# bake exists to skip.
	var own: Array = meshes

	_ph("props: ResourceLoader.load(.geom.res)",
		Time.get_ticks_msec() - _tg, meshes.size(), PH_CACHE)

	# The textures. A worker has usually decoded them already; _bind_side does
	# the same job for the glb path and says so in a recording when it has to
	# fall back to decoding inline.
	var _tx := Time.get_ticks_msec()
	var d: Variant = _bc.get(gp)
	if d is Dictionary:
		_bc.erase(gp)
	elif BcTex.exists(gp):
		var _t := Time.get_ticks_msec()
		d = _decode_side(gp)
		_ph("textures: decoded on the MAIN thread (no prefetch)",
			Time.get_ticks_msec() - _t, 1, PH_CACHE)
	if d is Dictionary and not (d as Dictionary).is_empty():
		var _tb := Time.get_ticks_msec()
		BcTex.bind_meshes(own, d as Dictionary)
		_ph("textures: bind to materials",
			Time.get_ticks_msec() - _tb, (d as Dictionary).size(), PH_ENGINE)
	_ph("props: textures, all of it (of which)",
		Time.get_ticks_msec() - _tx, 1, PH_CACHE)
	return own

const _TEX_SLOTS := [
	BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
	BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC,
	BaseMaterial3D.TEXTURE_EMISSION, BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION,
]

# ONE TEXTURE CAN FILL SEVERAL SLOTS, and every slot has to be repointed at the
# compressed copy. glTF packs roughness and metallic into a single image, so both
# slots hold the same texture; a first version compressed it once, replaced only
# the slot it happened to reach first, and left the other pointing at the
# ORIGINAL â€” which keeps the uncompressed copy resident and undoes most of the
# saving. It measured 1.8x instead of the 4.3x the per-texture ratios promised,
# which is the only reason it was caught. So: compress each distinct texture
# once, remember the replacement, then apply it everywhere it appears.
# COMPRESSION RUNS ON WORKER THREADS. Doing it inline cost 251 ms per prop on
# the main thread â€” 136 s across a Dumbo build, contributing to an editor that
# was wedged for 74% of the load with one 46-second freeze. Measured: Image
# compression is safe off-thread (51/51 correct) and 4.9x faster across cores,
# while the part that MUST stay on the main thread, create_from_image, is 4 ms
# per 51 textures. So: gather, compress in parallel, then build the textures and
# repoint the slots back here.
#
# The job arrays are static because a group task callable cannot carry state.
# That is safe only because one build runs at a time (`_building` guards it);
# if that ever stops being true this needs a real context object.
# INSTANCE, not static, because the wait below has to yield frames and a static
# function has no tree to yield to. They were static originally only because a
# group-task Callable cannot carry state, which a bound method solves anyway.
# Which layer is currently parsing, so the profiler can attribute the merge.
# _merge_meshes is shared by the prop and skyline builders and cannot tell them
# apart on its own, and the two answer very different questions.
var _merge_who := "props"

var _cj_src: Array = []              # images to compress
var _cj_norm: Array = []             # is that image a normal map (BC5, not BC1/3)
var _cj_out: Array = []              # results, index-matched

func _compress_job(i: int) -> void:
	var c := (_cj_src[i] as Image).duplicate() as Image
	if vram_mode == VRAM_LOW:
		c.resize(maxi(4, c.get_width() / 2), maxi(4, c.get_height() / 2),
			Image.INTERPOLATE_BILINEAR)
	var err: int
	if bool(_cj_norm[i]):
		err = c.compress_from_channels(Image.COMPRESS_S3TC, Image.USED_CHANNELS_RG)
	else:
		err = c.compress(Image.COMPRESS_S3TC)
	if err == OK:
		_cj_out[i] = c


func _compress_textures(m: Mesh) -> int:
	# ONLY THE LOW MODE NEEDS THIS PASS, and running it otherwise is expensive
	# rather than merely pointless. HighpolyStore.compress_scene_textures has
	# ALREADY compressed everything during the parse, with better per-slot hints
	# (COMPRESS_SOURCE_SRGB / NORMAL / GENERIC) and mipmaps. This walk would then
	# call get_image() on every texture just to discover it is already
	# compressed and skip it â€” and get_image() COPIES the data.
	#
	# On a prop with 13 textures that is a rounding error. A Dumbo skyline file
	# carries 653 materials and 706 textures, and there are 155 of them, which is
	# why the skyline stayed slow. Low mode still needs this pass because it
	# resizes, and a compressed image cannot be resized â€” so in that mode the
	# parse skips its own compression and leaves the work here.
	if m == null or vram_mode != VRAM_LOW:
		return 0
	# --- gather (main thread, cheap) ---------------------------------------
	# ONE TEXTURE CAN FILL SEVERAL SLOTS and every one has to be repointed. glTF
	# packs roughness and metallic into a single image, so both slots hold the
	# same texture; an earlier version compressed it once, replaced only the slot
	# it reached first and left the other pointing at the uncompressed original â€”
	# which keeps it resident and undoes most of the saving. It measured 1.8x
	# instead of 4.0x, which is the only reason it was caught.
	_cj_src.clear(); _cj_norm.clear(); _cj_out.clear()
	var index := {}         # texture id -> position in the job arrays
	var slots_of := {}      # texture id -> [[material, slot], ...]
	for s in range(m.get_surface_count()):
		var bm := m.surface_get_material(s) as BaseMaterial3D
		if bm == null:
			continue
		for slot in _TEX_SLOTS:
			var t := bm.get_texture(slot)
			if t == null:
				continue
			var id := t.get_instance_id()
			if not slots_of.has(id):
				slots_of[id] = []
			(slots_of[id] as Array).append([bm, slot])
			if index.has(id):
				continue
			var img := t.get_image()
			# Already-compressed images cannot be resized or re-compressed, and
			# very small ones cost nothing to leave alone â€” BC works on 4x4
			# blocks, so anything under that is not worth touching.
			if img == null or img.is_compressed() or img.get_width() < 8 or img.get_height() < 8:
				continue
			index[id] = _cj_src.size()
			_cj_src.append(img)
			_cj_norm.append(slot == BaseMaterial3D.TEXTURE_NORMAL)
	if _cj_src.is_empty():
		return 0
	_cj_out.resize(_cj_src.size())

	# --- compress (worker threads) -----------------------------------------
	# WAIT WITHOUT BLOCKING THE EDITOR. Moving compression onto worker threads
	# made it 4.9x faster but did NOT stop the freezing, because
	# wait_for_group_task_completion() parks the MAIN thread until the group is
	# done â€” the work got shorter, the stall did not go away. It still measured
	# 283 ms per prop in a session that was 70% wedged.
	#
	# Poll instead, handing the editor a frame each time round, so it keeps
	# drawing and the progress bar keeps moving while the cores grind. The
	# blocking call still has to happen once at the end: Godot requires it to
	# release the group even when it has already finished, and skipping it leaks
	# the task.
	var gid := WorkerThreadPool.add_group_task(_compress_job, _cj_src.size(),
		-1, false, "highpoly texture compression")
	if is_inside_tree():
		while not WorkerThreadPool.is_group_task_completed(gid):
			await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(gid)

	# --- publish (main thread, ~4 ms per 51) --------------------------------
	var n := 0
	for id in index:
		var img: Image = _cj_out[int(index[id])]
		if img == null:
			continue
		var tex := ImageTexture.create_from_image(img)
		for pair in (slots_of[id] as Array):
			(pair[0] as BaseMaterial3D).set_texture(pair[1], tex)
		n += 1
	_cj_src.clear(); _cj_norm.clear(); _cj_out.clear()
	return n


# --- VRAM watchdog -----------------------------------------------------------
# Godot does not survive running out of video memory. It does not raise, degrade
# or fall back: the Vulkan allocation returns VK_ERROR_OUT_OF_DEVICE_MEMORY, the
# buffer comes back null, several hundred cascading errors follow as meshes with
# no vertex data are asked for triangle data, and then it segfaults. A user gets
# a vanished editor and no explanation.
#
# IT WARNS, IT DOES NOT STOP â€” and the first version got that badly wrong.
#
# It stopped the build at 4 GB of total device memory, on the assumption that
# 4 GB was "our props". It is not: get_memory_usage(MEMORY_TOTAL) counts
# everything the rendering device holds, including the editor's own scene, the
# terrain, the maptile and the skyline. On Dumbo that baseline is already
# 4362 MB BEFORE a single prop exists, so the very first check tripped and the
# build ended with `0 built in 0.0 s`. Every prop silently missing, on every
# machine, with the only clue a line in the log.
#
# The deeper problem is that a fixed ceiling cannot be right: we cannot read the
# card's capacity (get_device_total_memory needs a debug build and
# --extra-gpu-memory-tracking, so it reports 0 for everyone), and the same
# number that protects a 4 GB card would cripple a 24 GB one. A guard that
# breaks working setups to maybe save failing ones is a bad trade â€” especially
# now that compression cuts usage 4x and Low cuts it 16x, which is the actual
# remedy.
#
# So this reports, loudly and once, and lets the build continue. The user is
# told what to change; the decision stays theirs.
const VRAM_WARN_MB := 6144.0
static var _vram_warned := false

static func vram_used_mb() -> float:
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		return float(rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL)) / 1048576.0
	return Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

# Warns ONCE per build and always returns false: the build continues. Called
# from the build loop, so a message per prop would be thousands of lines.
static func vram_check() -> void:
	if _vram_warned:
		return
	var mb := vram_used_mb()
	if mb < VRAM_WARN_MB:
		return
	_vram_warned = true
	Log.warn(("video memory is at %.0f MB. Cards run out somewhere above this, "
		+ "and Godot CRASHES rather than reporting it. If the editor closes "
		+ "itself while a map loads, pull the Range slider down. "
		+ "Carrying on for now.") % mb)


static func _mesh_keeps_textures(m: Mesh) -> bool:
	if m == null:
		return false
	var slots := 0
	for i in range(m.get_surface_count()):
		var mat := m.surface_get_material(i)
		if not (mat is BaseMaterial3D):
			continue
		for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL]:
			var t := (mat as BaseMaterial3D).get_texture(slot)
			if t == null:
				continue
			slots += 1
			if t.get_width() > 0 and t.get_height() > 0:
				return true
	return slots == 0

# Parse a prop GLB from disk into one baked/merged Mesh â€” NO cache interaction,
# so the refresh path can build-then-swap (parse first, only then evict).
# Returns null for missing/torn/unparseable files.
func _parse_prop_file(gp: String) -> Array:
	# Versioned suffix: a bump invalidates every sidecar at once, which is the
	# only way to retire caches baked under a rule that has since changed.
	#   v1 -> v2  runtime LOD generation
	#   v2 -> v3  foliage: v2 meshes were baked with leaf cards already swapped
	#             to the old albedo-only wind shader, and that swap is lossy â€”
	#             the normal/roughness/metallic/AO maps are simply not in the
	#             file any more, so no amount of re-reading a v2 sidecar can
	#             recover them. They have to come back from the GLB.
	# baked4: baked3 sidecars cache meshes baked with tangents left in the source
	# frame. The code fix alone would never reach anyone holding a cache â€” the
	# sidecar IS the geometry, so correcting it means moving the suffix.
	# baked5: the sidecar now stores VRAM-COMPRESSED textures, so a baked4 file
	# holds the wrong pixels entirely. The suffix also carries the vram mode â€”
	# switching between Full, Compressed and Low must not serve a cache baked
	# under a different one, and encoding it here means the three can coexist
	# instead of invalidating each other every time someone changes the setting.
	var baked := gp + _baked_suffix()

	# A SPLIT PROP GETS A SIDECAR TOO, one file per part. It used to get none â€”
	# "one .res holds one Resource, so caching a list would need its own
	# container format" â€” and that meant the heaviest files in the map cached
	# nothing and re-parsed on EVERY load, warm or cold. The six biggest Dumbo
	# backdrops each split into three meshes, so the whole skyline was paying
	# full parse cost forever, which is exactly the "it still takes a while"
	# complaint. A container format was never needed: numbered files are enough.
	var part0 := gp + _part_suffix(0)
	if mesh_cache_enabled and FileAccess.file_exists(part0) \
			and FileAccess.get_modified_time(part0) >= FileAccess.get_modified_time(gp):
		var parts: Array = []
		var i := 0
		var bad := false
		while true:
			var pp := gp + _part_suffix(i)
			if not FileAccess.file_exists(pp):
				break
			var pm := ResourceLoader.load(pp, "Mesh", ResourceLoader.CACHE_MODE_REPLACE)
			if not (pm is Mesh) or not _mesh_keeps_textures(pm as Mesh):
				bad = true
				break
			parts.append(pm)
			i += 1
		if not bad and parts.size() > 0:
			return parts
		# any part unusable makes the whole set unusable: a prop missing one of
		# its meshes renders as a fragment, which reads as a bad model
		var j := 0
		while FileAccess.file_exists(gp + _part_suffix(j)):
			DirAccess.remove_absolute(gp + _part_suffix(j))
			j += 1
		Log.warn("%s: split-mesh cache was incomplete, re-baking from the model"
			% gp.get_file())

	if mesh_cache_enabled and FileAccess.file_exists(baked) \
			and FileAccess.get_modified_time(baked) >= FileAccess.get_modified_time(gp):
		var bm := ResourceLoader.load(baked, "Mesh", ResourceLoader.CACHE_MODE_REPLACE)
		# Fresh-by-timestamp is not the same as USABLE. Sidecars have been found on
		# disk holding the right materials with 0x0 textures â€” the prop then draws
		# blank, which reads as "the model is bad" rather than "the cache is bad",
		# and no amount of re-downloading at higher quality fixes it because the
		# GLB is never consulted again. Verify the pixels survived; a sidecar that
		# fails is deleted so the next build re-bakes it from the GLB.
		if bm is Mesh and _mesh_keeps_textures(bm as Mesh):
			return [bm]
		if bm is Mesh:
			Log.warn("%s: cached mesh had empty textures, re-baking from the model"
				% gp.get_file())
		DirAccess.remove_absolute(baked)
	# ---- the shipped geometry bake ---------------------------------------
	# The tier above is a cache the USER built, on their machine, on a previous
	# load â€” which is why the first load of a map is the slow one. Nothing in it
	# is user-specific, so the pipeline bakes it too and ships it, and the cold
	# pull gets to be the fast path.
	#
	# Measured on real props: loading the bake is ~6x faster than parsing the
	# same stripped glb, and the file is 0.39x its size â€” 22.4 bytes per vertex
	# against 45.1, because glTF spends float32 on positions, normals and UVs
	# while Godot's own format is denser and the merge drops 21% of the vertices
	# outright. It is smaller AND faster, which is why this is worth shipping
	# rather than offering as a trade.
	#
	# NO TEXTURES IN IT, deliberately. They ride in the .bctex beside it, where
	# they are deduplicated across the whole map (Dumbo's 9,715 image references
	# are 84 distinct textures) and mostly kept as their original webp bytes.
	# That also makes this file independent of the VRAM mode: the pixels differ
	# between Full, Compressed and Low, the geometry does not, so one shipped
	# bake serves all three instead of tripling what we publish.
	var geom := _load_geom_tier(gp)
	if not geom.is_empty():
		# from_bake: do NOT write a fast-load sidecar for this one. The sidecar
		# exists to save a glTF parse on the next load, and a prop that arrived
		# from the shipped .geom.res did not do a glTF parse â€” the sidecar would
		# be a second copy of the tier it was just loaded from, and a SLOWER one
		# (8.4 ms/prop against 3.37 all in).
		#
		# Measured on Dumbo with the bake installed: 2,761 needless sidecars,
		# 8.3 GB, and roughly 50 s of writing at the end of every cold build â€”
		# which also looked like a hang, because the tail of the build emits no
		# progress while it writes them.
		return await _finish_prop(gp, baked, geom, true)

	var out: Array = []
	var inst := _load_external_glb(gp)   # a live scene root, ours to free
	if inst:
		# merge ALL mesh nodes â€” multi-part GLBs (one node per material part,
		# e.g. dump-extracted window units: glass part + wall part) used to
		# render only their FIRST part via _first_mesh_and_xf, which showed
		# floating glass panes with the wall part silently dropped
		var pairs: Array = []
		_all_meshes_and_xf(inst, Transform3D(), pairs)
		if pairs.size() == 1:
			out = [_bake_mesh(pairs[0][0], pairs[0][1])]
		elif pairs.size() > 1:
			out = _merge_meshes(pairs)          # one mesh per 255 surfaces
		# free(), NOT queue_free(). queue_free defers to the END OF THE FRAME,
		# and this runs many times per frame under BUILD_FRAME_MS â€” so every
		# source scene built in that frame stayed alive, each holding a GPU
		# vertex and index buffer per surface, until the frame ended.
		#
		# Measured over 2,871 real prop GLBs with a live renderer:
		#   queue_free  memory climbs to 40,016 MB and the process CRASHES at
		#               ~2,000 files â€” "Buffer is either invalid or this type
		#               of buffer can't be retrieved", then SIGSEGV
		#   free        stays FLAT at ~60 MB and completes all 2,871
		#
		# Headless never crashes either way, which is why this hid for so long:
		# the dummy renderer allocates no GPU buffers, so there is nothing to
		# exhaust and surface_get_arrays never becomes a readback.
		#
		# Safe because this node is never added to the tree ("ours to free"
		# above), and the meshes extracted from it are RefCounted and outlive it.
		inst.free()
	return await _finish_prop(gp, baked, out)


# The material work every prop gets, whichever tier it arrived from. Shared so a
# prop loaded from a shipped .geom.res cannot drift from one parsed out of a glb
# â€” the two must end up byte-for-byte equivalent or maps would look different
# depending on which files a user happened to have.
func _finish_prop(gp: String, baked: String, out: Array,
		from_bake := false) -> Array:
	# THE PIPELINE STOPS HERE. When this same code bakes the files we ship, it
	# must hand back the merged geometry and nothing else: the passes below swap
	# materials and compress pixels, and baking either into a shipped file is
	# permanent. The wind swap in particular is lossy â€” it drops the normal,
	# roughness, metallic and AO maps, which is what forced the v2 -> v3 sidecar
	# invalidation, and no amount of re-reading the file gets them back.
	if bake_geometry_only:
		return out

	# The other half of "props: load mesh". These passes walk every material on
	# every prop, and one of them (_compress_textures) is a fallback that should
	# now find nothing left to do — the sidecar decode compresses before pooling.
	# If this shows up large, it is doing work twice.
	var _tf := Time.get_ticks_msec()
	var done: Array = []
	for m in out:
		if m == null:
			continue
		_fx_animate_materials(m)
		_wind_swap_materials(m)
		_parallax_materials(m)
		# AFTER the material passes, so anything that swaps a material in (wind,
		# parallax, fx) has its textures compressed too, and BEFORE the sidecar
		# is written below so the saving is baked into the cache rather than
		# re-paid on every load.
		var _tc := Time.get_ticks_msec()
		var _n: int = await _compress_textures(m)
		if _n > 0:
			_ph("props: compress textures for VRAM",
				Time.get_ticks_msec() - _tc, _n, PH_ENGINE)
		done.append(_with_lods(m))
	# QUEUED, NOT WRITTEN. The fast-load sidecar is worth about 8x on a LATER
	# build and nothing at all on this one, yet it used to be written inline â€”
	# costing 10.8 s per 600 props, roughly 50 s of a 2,761-prop Dumbo build, on
	# the cold pull that is the slowest thing a user ever waits for.
	#
	# So the build hands them over and flush_sidecars() writes them once the map
	# is on screen. A build that is cancelled or interrupted simply never writes
	# its cache, which costs a re-parse next time and is strictly better than
	# making everybody wait for it every time.
	if mesh_cache_enabled and not from_bake and not done.is_empty():
		_side_writes.append({"gp": gp, "baked": baked, "m": done.duplicate()})
		# NO read-back verification here, deliberately. It used to load the file
		# straight back and delete any sidecar whose textures returned 0x0 â€”
		# reasonable-sounding, and the single biggest self-inflicted wound in
		# this file. Loading the sidecar uploads a SECOND copy of every texture
		# while the build already holds thousands, and the engine only reclaims
		# discarded ones between frames, so a long uninterrupted build starves
		# itself and the verification starts failing on perfectly good props.
		#
		# Measured on Dumbo: 942 of 2,871 props were rejected this way, and the
		# rejects were not bad models. Re-running the identical parse/save/verify
		# on 135 of them standalone passed 135/135. Re-running 60 of them inside
		# the live editor as one uninterrupted burst passed the first 40 and
		# failed the last 19 â€” a dose response, not a data problem â€” and those
		# 19 passed on a second attempt once frames had run. The check was
		# manufacturing the failure it reported, and the cost was real: every
		# rejected prop re-parsed from glTF on every scene build.
		#
		# A genuinely unreadable sidecar is still caught, one step later and for
		# free: the LOAD path above verifies _mesh_keeps_textures() before
		# trusting a cached mesh, deletes it and re-bakes from the GLB. That is
		# the same guarantee without a second texture upload at the worst
		# possible moment.
	_ph("props: material passes (of which)",
		Time.get_ticks_msec() - _tf, done.size(), PH_ENGINE)
	return done


# Sidecars waiting to be written, queued by _parse_prop_file and drained once
# the build is finished and the map is on screen.
var _side_writes: Array = []


# Write the queued fast-load sidecars, yielding so this never becomes another
# freeze. Called after a build finishes; safe to call at any time.
func flush_sidecars() -> void:
	if _side_writes.is_empty():
		return
	var n := _side_writes.size()
	var t0 := Time.get_ticks_msec()
	HighpolyProfiler.crumb("sidecars", "writing %d queued" % n)
	var slice := Time.get_ticks_msec()
	while not _side_writes.is_empty():
		var e: Dictionary = _side_writes.pop_front()
		_write_sidecar(str(e["gp"]), str(e["baked"]), e["m"] as Array)
		if Time.get_ticks_msec() - slice >= _frame_ms():
			if not is_inside_tree():
				return                  # panel closed: the rest simply re-parses
			await get_tree().process_frame
			slice = Time.get_ticks_msec()
	var ms := Time.get_ticks_msec() - t0
	_ph("sidecars: write fast-load cache", ms, n, PH_CACHE)
	HighpolyProfiler.crumb("sidecars", "wrote %d in %.1f s" % [n, ms / 1000.0])
	Log.debug("fast-load cache: %d sidecar(s) written in %.1f s" % [n, ms / 1000.0])


func _write_sidecar(gp: String, baked: String, done: Array) -> void:
	# A split prop caches as numbered parts. Written only when EVERY part is
	# usable, so a half-written set can never be loaded back as a prop missing
	# some of its meshes.
	if done.size() > 1:
		for m in done:
			if m == null or not _mesh_keeps_textures(m as Mesh):
				return
		var wrote := 0
		for i in range(done.size()):
			if ResourceSaver.save(done[i], gp + _part_suffix(i),
					ResourceSaver.FLAG_COMPRESS) == OK:
				wrote += 1
			else:
				break
		if wrote != done.size():
			for i in range(wrote):          # never leave a torn set behind
				DirAccess.remove_absolute(gp + _part_suffix(i))
		return
	if done.size() == 1 and done[0] != null and _mesh_keeps_textures(done[0]):
		if ResourceSaver.save(done[0], baked, ResourceSaver.FLAG_COMPRESS) != OK:
			DirAccess.remove_absolute(baked)   # never leave a torn cache file

# ---------- Configure Shaders (dock dialog) ----------
# live-tunable overlay shader prefs, persisted by the dock:
#   water    â€“ multiplier on each water body's AUTHORED ripple_speed (0 = still)
#   flip     â€“ multiplier on flipbook-card animation speed (smoke; 0 = static)
#   wind     â€“ subtle foliage sway on leaf-card materials
static var shader_prefs := {"water": 1.0, "flip": 1.0, "wind": false, "wind_str": 0.08}
const FLIP_BASE_SPEED := 0.25          # fx_smoke.gdshader authored default

# Backdrop-FX flipbook cards (smoke plumes): the baker tags materials whose
# sheet packs 3 animation-time samples in R/G/B with "__fxanim3" and keeps the
# packed data. Swap those for fx_smoke.gdshader, which crossfades the channels
# live â€” the smoke billows in the editor using the game's own texture data.
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
# material is alpha-cutout â€” trunks/bark stay put) for foliage_wind.gdshader.
# Always swapped; wind_strength 0 renders identical to the original, so the
# dock toggle is a pure live uniform change.
static func _wind_swap_materials(m: Mesh) -> void:
	if not (m is ArrayMesh): return
	# Do NOT replace a material for a feature that is switched off. This used to
	# run unconditionally and swap in the wind shader with wind_strength 0, so
	# every foliage prop was rendered by a substitute material even for users who
	# never enabled Foliage Wind â€” all cost, no effect. Turning the pref ON still
	# reaches already-built meshes through apply_shader_prefs(), which calls this.
	if not bool(shader_prefs.get("wind", false)): return
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
		# Carry the REST of the material across. Swapping used to drop the normal
		# map, roughness, metallic and AO on the floor, which is what made every
		# tree and hedge read flat. A substitute material that keeps only the
		# albedo is not a substitute.
		sm.set_shader_parameter("use_normal", bm.normal_enabled and bm.normal_texture != null)
		sm.set_shader_parameter("normal_tex", bm.normal_texture)
		sm.set_shader_parameter("normal_scale", bm.normal_scale)
		sm.set_shader_parameter("use_rough_tex", bm.roughness_texture != null)
		sm.set_shader_parameter("rough_tex", bm.roughness_texture)
		sm.set_shader_parameter("rough_channel", int(bm.roughness_texture_channel))
		sm.set_shader_parameter("roughness_mul", bm.roughness)
		sm.set_shader_parameter("use_metal_tex", bm.metallic_texture != null)
		sm.set_shader_parameter("metal_tex", bm.metallic_texture)
		sm.set_shader_parameter("metal_channel", int(bm.metallic_texture_channel))
		sm.set_shader_parameter("metallic_mul", bm.metallic)
		sm.set_shader_parameter("use_ao", bm.ao_enabled and bm.ao_texture != null)
		sm.set_shader_parameter("ao_tex", bm.ao_texture)
		sm.set_shader_parameter("ao_channel", int(bm.ao_texture_channel))
		sm.set_shader_parameter("ao_affect", bm.ao_light_affect)
		sm.set_shader_parameter("specular_amount", bm.metallic_specular)
		am.surface_set_material(i, sm)

# push the current shader_prefs onto every live overlay material (water plane,
# flipbook cards, foliage) â€” called by the dock's Configure Shaders dialog and
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
			# BaseMaterial3D foliage â€” swap them here so Foliage Wind reaches
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
	# water: HighpolyWater builds its Shader from TEXT (no resource_path â€” a
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
# heightmap from it and enable deep parallax â€” the "massive depth fixes" the
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

# RUNTIME MESH LODs: Godot only auto-generates LODs during editor import â€”
# runtime-loaded GLBs render FULL detail at any distance, which is why flying
# was vertex-bound even on a 4080. Rebuild each merged mesh through
# ImporterMesh.generate_lods(); the result (mesh + LOD chain) is what the
# fast-startup sidecar caches, so the generation cost is paid once.
# Only meshes with this many surfaces are considered. The signature reads every
# bound image and hashes it, and a prop with three surfaces has nothing to gain;
# the skyline composites carry 200-650 each, which is where every duplicate is.
const MERGE_MIN_SURFACES := 16


# Collapse surfaces whose materials are IDENTICAL IN CONTENT into one surface.
#
# The renderer issues a draw call per surface per visible instance, so a mesh's
# surface count IS its draw cost. Measured on the Dumbo skyline, which is where
# this matters most: the Backdrop layer is 49,966 surfaces across 289 instances
# and accounts for 61% of frame time and 56% of every draw call â€” switching it
# off takes the recorded flight from 129.4 ms a frame to 50.7.
#
# Those surfaces arrive one per original material section, and glTF hands back a
# separate Material OBJECT for each, so they look all-distinct by identity and
# by name. By CONTENT â€” the images actually bound, the albedo colour, the flags
# that change shader state â€” 28,359 of the 49,966 are unique. The rest are
# duplicates the renderer would bind identically, and merging them is invisible:
# same geometry, same pixels, 43% fewer draw calls.
#
# Only merges what is provably safe. A ShaderMaterial, a surface that is not
# PRIMITIVE_TRIANGLES, blend shapes, or any mismatch in which vertex channels
# the surfaces carry, and the mesh is returned exactly as it arrived.
static func _merge_equal_surfaces(m: Mesh) -> Mesh:
	if not (m is ArrayMesh):
		return m
	var am := m as ArrayMesh
	var n := am.get_surface_count()
	if n < MERGE_MIN_SURFACES or am.get_blend_shape_count() > 0:
		return m

	var groups: Array = []          # [signature, material, [surface indices]]
	var by_sig := {}
	for s in range(n):
		if am.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return m
		var sig := _material_signature(am.surface_get_material(s))
		if sig == "":
			return m                # a material kind not to second-guess
		if not by_sig.has(sig):
			by_sig[sig] = groups.size()
			groups.append([sig, am.surface_get_material(s), []])
		(groups[int(by_sig[sig])][2] as Array).append(s)
	if groups.size() >= n:
		return m                    # nothing shares: no work to do

	var out := ArrayMesh.new()
	out.resource_name = am.resource_name
	for g in groups:
		var idxs: Array = g[2]
		var arrays: Array = am.surface_get_arrays(int(idxs[0])) \
				if idxs.size() == 1 else _concat_surfaces(am, idxs)
		if arrays.is_empty():
			return m                # channels differed: keep the original
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, g[1])
	return out


# Append several surfaces into one array set. [] when they cannot be joined.
#
# Every surface must carry the SAME channels: merging a set that has normals
# with one that does not produces a mesh whose vertex format is a lie, and that
# renders as garbage rather than failing.
static func _concat_surfaces(am: ArrayMesh, idxs: Array) -> Array:
	var first: Array = am.surface_get_arrays(int(idxs[0]))
	var want: Array = []
	for c in range(Mesh.ARRAY_MAX):
		want.append(first[c] != null)
	if not bool(want[Mesh.ARRAY_VERTEX]) or not bool(want[Mesh.ARRAY_INDEX]):
		return []

	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	var base := 0
	for i in idxs:
		var a: Array = am.surface_get_arrays(int(i))
		for c in range(Mesh.ARRAY_MAX):
			if bool(want[c]) != (a[c] != null):
				return []
		var vcount: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		for c in range(Mesh.ARRAY_MAX):
			if not bool(want[c]):
				continue
			if c == Mesh.ARRAY_INDEX:
				var dst: PackedInt32Array = out[c] if out[c] != null \
						else PackedInt32Array()
				for v in (a[c] as PackedInt32Array):
					dst.append(v + base)    # rebased onto the joined vertex list
				out[c] = dst
			elif out[c] == null:
				out[c] = a[c]
			else:
				out[c] = out[c] + a[c]
		base += vcount
	return out


# What the renderer would BIND for this material, as a comparable string.
# "" when the material is of a kind this must not second-guess.
static func _material_signature(mat: Material) -> String:
	if mat == null:
		return "null"
	if not (mat is BaseMaterial3D):
		return ""                   # ShaderMaterial and friends: hands off
	var b := mat as BaseMaterial3D
	var parts := PackedStringArray()
	for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
				 BaseMaterial3D.TEXTURE_ROUGHNESS,
				 BaseMaterial3D.TEXTURE_METALLIC,
				 BaseMaterial3D.TEXTURE_EMISSION,
				 BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION]:
		var t := b.get_texture(slot)
		if t == null:
			parts.append("-")
			continue
		# BY THE IMAGE, not the RID. Two Texture2D objects wrapping one image
		# are different objects with different RIDs, and keying on identity
		# reports every surface as unique when most of them are not â€” which is
		# the difference between "merging is impossible" and "merging is 43%".
		var img := t.get_image()
		if img == null:
			parts.append("rid:%s" % t.get_rid())
		else:
			parts.append("%dx%d:%d:%s" % [img.get_width(), img.get_height(),
					img.get_format(),
					img.get_data().slice(0, 4096).hex_encode().md5_text()])
	parts.append("%.4f,%.4f,%.4f,%.4f" % [b.albedo_color.r, b.albedo_color.g,
			b.albedo_color.b, b.albedo_color.a])
	parts.append("%d,%d,%d,%d" % [b.transparency, b.cull_mode, b.shading_mode,
			b.blend_mode])
	parts.append("%.3f,%.3f" % [b.roughness, b.metallic])
	parts.append("%.3f,%.3f" % [b.uv1_scale.x, b.uv1_scale.y])
	return "|".join(parts)


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
# The files that ship BESIDE a prop's glb, named only if the archive has them.
# Older archives have neither, and a map is perfectly valid without them, so a
# missing companion is never an error â€” it just is not asked for.
static func _want_companions(glb: String, present: Dictionary,
		want: Dictionary) -> void:
	# HighpolyBcTex.path_for replaces the extension: Foo.glb -> Foo.bctex.
	# The bake appends instead: Foo.glb -> Foo.glb.geom.res. They differ, and
	# guessing either one wrong silently fetches nothing.
	var side := glb.get_basename() + BcTex.EXT
	if present.has(side):
		want[side] = true
	if present.has(glb + GEOM_SUFFIX):
		want[glb + GEOM_SUFFIX] = true
	var i := 0
	while present.has("%s.geom.p%d.res" % [glb, i]):
		want["%s.geom.p%d.res" % [glb, i]] = true
		i += 1


static func _glb_has_no_images(gp: String) -> bool:
	var f := FileAccess.open(gp, FileAccess.READ)
	if f == null:
		return false                      # unreadable is a different problem
	var head := f.get_buffer(20)
	if head.size() < 20 or head.decode_u32(0) != 0x46546C67:
		f.close()
		return false
	var jlen := int(head.decode_u32(12))
	if jlen <= 0 or jlen > 64 << 20:
		f.close()
		return false
	var js := f.get_buffer(jlen).get_string_from_utf8()
	f.close()
	# Cheaper than parsing: bc_strip removes the images array entirely, so its
	# absence is the marker. A file that still has one is a pre-strip prop.
	return not js.contains("\"images\"")

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

const RANGED_JOB := "Loading the level's scenery (1/2)"
const ARCHIVE_JOB := "Loading the level's scenery (1/3)"


# ---------- prop meshes ----------
func _mesh_for(model_path: String) -> Mesh:
	if _mesh_cache.has(model_path): return _mesh_cache[model_path]
	var m: Mesh = null
	if ResourceLoader.exists(model_path):
		var res = load(model_path)
		if res is PackedScene:
			var inst = (res as PackedScene).instantiate()
			# Library GLBs are MANY mesh nodes now (per-material sub-parts, swatch
			# splits) â€” taking only the first node rendered props as lone
			# fragments. Merge EVERY mesh node (its glTF import transform baked:
			# 0.01 scale / axis swap / cm verts â€” the 700 m helicopter class),
			# grouping surfaces by material to stay under MAX_MESH_SURFACES.
			var pairs: Array = []
			_all_meshes_and_xf(inst, Transform3D(), pairs)
			if pairs.size() == 1:
				m = _bake_mesh(pairs[0][0], pairs[0][1])
			elif pairs.size() > 1:
				# _merge_meshes splits past 255 surfaces. Proxy models are small
				# SDK library assets and are not expected to reach that, but say
				# so rather than drop the remainder in silence if one ever does.
				var parts := _merge_meshes(pairs)
				if parts.size() > 1:
					Log.warn(("%s needs %d meshes to hold its materials; this "
						+ "proxy path shows only the first")
						% [model_path.get_file(), parts.size()])
				m = parts[0] if parts.size() > 0 else null
			# free(), not queue_free() â€” same reason as the prop path: deferred
			# frees let every source scene built in one frame hold its GPU
			# buffers until the frame ends. Never added to the tree.
			inst.free()
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
# Returns a LIST of meshes, not one.
#
# Godot caps a Mesh at 255 surfaces, and a merged surface is created per distinct
# MATERIAL. This used to hit that cap and DROP the rest, which quietly deleted
# geometry: measured on Dumbo, 81 of the 155 backdrop clusters carry ~700
# materials each, so roughly two-thirds of the building facades, roofs and bridge
# sections in more than half the skyline were being thrown away at build time.
# Splitting across several meshes keeps every surface, with the same batching --
# the caller adds one MultiMeshInstance per mesh.
# Timed as a whole rather than per surface: this is called once per source file
# and rebuilds vertex arrays, so it is a prime suspect for the minutes that
# produce no visible nodes.
func _merge_meshes(pairs: Array) -> Array:
	var _tm := Time.get_ticks_msec()
	var _out := _merge_meshes_inner(pairs)
	# LABELLED BY CALLER, because "of which" was a lie. This runs from BOTH the
	# prop path and the skyline path, so the report showed 287.5 s nested inside
	# a 200.4 s parent â€” impossible, and it hid the actually useful question of
	# which of the two was doing the merging. The prop half genuinely is nested
	# inside "props: load mesh"; the skyline half is not nested in anything.
	_ph(
		"  of which: merge (props)" if _merge_who == "props"
			else "skyline: merge mesh nodes",
		Time.get_ticks_msec() - _tm, pairs.size(), PH_ENGINE)
	return _out


func _merge_meshes_inner(pairs: Array) -> Array:
	# NOTE: plain Arrays (reference type) as accumulators â€” packed arrays kept
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
			# BY CONTENT, NOT BY RID.
			#
			# This grouped on mat.get_rid(), and glTF hands back a SEPARATE
			# Material object per surface - so every key was unique and the
			# merge never merged anything. The skyline arrived as 49,966
			# surfaces and left as 49,966, one draw call and one material bind
			# each.
			#
			# It is invisible from here because the code is correct in shape:
			# group by material, concatenate the geometry. Only counting the
			# groups afterwards shows the grouping is a no-op.
			#
			# Measured on Dumbo's backdrop: 28,359 of the 49,966 materials are
			# distinct BY CONTENT, so keying on what the renderer would actually
			# bind collapses 43% of them. That matters more than the draw count
			# suggests - a skyline draw costs ~3 us against a prop's 0.38 us,
			# the difference being that props share one material across a
			# MultiMesh while the skyline rebinds for every surface.
			var key: Variant = _material_signature(mat) if mat != null else "null"
			if not groups.has(key):
				groups[key] = {"mat": mat, "v": [], "n": [], "uv": [], "i": [],
					"t": [], "has_uv": false, "has_tan": 0}
			var g: Dictionary = groups[key]
			var gv: Array = g["v"]
			var gn: Array = g["n"]
			var guv: Array = g["uv"]
			var gi: Array = g["i"]
			var gt: Array = g["t"]
			var base := gv.size()
			for i in range(V.size()): gv.append(xf * V[i])
			var N = arr[Mesh.ARRAY_NORMAL]
			if N != null and N.size() == V.size():
				for i in range(N.size()): gn.append((nb * N[i]).normalized())
			else:
				for i in range(V.size()): gn.append(Vector3.UP)
			# Tangents were dropped here entirely: the merged surface was built
			# from vertex/normal/uv/index only, so every normal-mapped batch made
			# Godot log "requires tangents ... doesn't contain tangents" on every
			# draw call â€” thousands of lines with map context on. They transform
			# like directions (basis), and the binormal sign in .w flips with a
			# mirrored transform, exactly as the winding does.
			var T = arr[Mesh.ARRAY_TANGENT]
			if T != null and T.size() == V.size() * 4:
				g["has_tan"] = int(g["has_tan"]) + V.size()
				for i in range(V.size()):
					var tv := Vector3(T[i * 4], T[i * 4 + 1], T[i * 4 + 2])
					tv = (xf.basis * tv).normalized()
					var w: float = T[i * 4 + 3]
					gt.append(tv.x); gt.append(tv.y); gt.append(tv.z)
					gt.append(-w if flip else w)
			else:
				# placeholder only â€” a zero tangent is degenerate, so a group
				# that ends up with any of these regenerates the whole surface
				for i in range(V.size()):
					gt.append(0.0); gt.append(0.0); gt.append(0.0); gt.append(1.0)
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
	var meshes: Array = []
	var out := ArrayMesh.new()
	var regenerated := 0
	for key in groups:
		if out.get_surface_count() >= 255:
			# Godot's per-mesh surface ceiling. Start another mesh rather than
			# discard the remaining materials.
			meshes.append(out)
			out = ArrayMesh.new()
		var g: Dictionary = groups[key]
		var arr := []; arr.resize(Mesh.ARRAY_MAX)
		var vcount: int = (g["v"] as Array).size()
		arr[Mesh.ARRAY_VERTEX] = PackedVector3Array(g["v"])
		arr[Mesh.ARRAY_NORMAL] = PackedVector3Array(g["n"])
		if g["has_uv"]: arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array(g["uv"])
		arr[Mesh.ARRAY_INDEX] = PackedInt32Array(g["i"])
		# Only ship tangents when EVERY source vertex brought one; a partially
		# zero-filled array is worse than none (a zero tangent renders wrong,
		# where a missing one at least gets regenerated below).
		var mat_nm: bool = _wants_tangents(g["mat"])
		var complete: bool = int(g["has_tan"]) == vcount and vcount > 0
		if complete:
			arr[Mesh.ARRAY_TANGENT] = PackedFloat32Array(g["t"])
		elif mat_nm and g["has_uv"]:
			# Normal-mapped with incomplete tangents: MikkTSpace them ONCE here,
			# in a scratch mesh, rather than let the renderer warn on every draw
			# call for the life of the scene.
			var tmp := ArrayMesh.new()
			tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			var st := SurfaceTool.new()
			st.create_from(tmp, 0)
			st.generate_tangents()
			arr = st.commit_to_arrays()
			regenerated += 1
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		if g["mat"] != null:
			out.surface_set_material(out.get_surface_count() - 1, g["mat"])
	if out.get_surface_count() > 0:
		meshes.append(out)
	if regenerated > 0:
		Log.debug("map context: regenerated tangents for %d merged surface(s)"
			% regenerated)
	if meshes.size() > 1:
		# THE PARENTHESES ARE LOAD-BEARING: % binds TIGHTER than +, so without them
		# only the second fragment is formatted â€” one placeholder against two
		# arguments â€” and every merge logged "String formatting error: not all
		# arguments converted" instead. 102 of them in one session. A parse check
		# cannot see this; only running it can.
		Log.debug(("map context: %d materials exceeded the 255-surface ceiling, "
			+ "split across %d meshes (no geometry dropped)")
			% [groups.size(), meshes.size()])
	return meshes

# Will this surface be drawn by something that reads TANGENT?
#
# Asking "does the material have a normal map" is not enough, because THREE
# later passes give a surface a tangent requirement it did not have when the
# mesh was built, and by then the vertex data is fixed:
#
#   _parallax_materials()  sets heightmap_enabled + deep parallax on materials
#                          tagged "__vtrparallax" â€” the backdrop/vista facades.
#                          Parallax reads TANGENT. This is the big one: a map
#                          went from a handful of backdrops to 155, and each
#                          untangented vista wall warns on every draw call.
#   _wind_swap_materials() REPLACES alpha-cutout leaf materials matching
#                          WIND_MAT_PAT with foliage_wind.gdshader.
#   _fx flipbook swap      REPLACES "__fxanim3" materials with fx_smoke.gdshader.
#
# A ShaderMaterial is assumed to want tangents: we cannot introspect a shader's
# varyings from GDScript, and generating them is cheap next to a per-draw-call
# renderer warning for the life of the scene. Tested against the same tags the
# passes above use, so the two cannot drift apart.
# Rotate a tangent array into a new frame, in place on a surface array.
#
# Tangents transform like DIRECTIONS (basis only, never the full transform), and
# the binormal sign in .w flips when the basis mirrors â€” exactly as the winding
# does. _merge_meshes has always done both; _bake_mesh and _flipped_mesh did not,
# and that omission is SILENT: the surface still has a tangent array, so nothing
# warns, the normal map is just sampled in the wrong frame. Measured on a real
# prop (ba_lf_ind_ceilinglamp_bulb_01_h_128) a 90 deg bake left the frame 30 deg
# out.
static func _xform_tangents(arr: Array, basis: Basis) -> void:
	var T = arr[Mesh.ARRAY_TANGENT]
	if T == null or T.size() < 4:
		return
	var flip: bool = basis.determinant() < 0.0
	var out := PackedFloat32Array()
	out.resize(T.size())
	for i in range(0, T.size() - 3, 4):
		var tv := (basis * Vector3(T[i], T[i + 1], T[i + 2])).normalized()
		out[i] = tv.x
		out[i + 1] = tv.y
		out[i + 2] = tv.z
		out[i + 3] = -T[i + 3] if flip else T[i + 3]
	arr[Mesh.ARRAY_TANGENT] = out


# A pure winding reversal (no basis): the tangent direction is unchanged, but the
# handedness of the frame reverses, so only .w flips.
static func _flip_binormal(arr: Array) -> void:
	var T = arr[Mesh.ARRAY_TANGENT]
	if T == null or T.size() < 4:
		return
	var out := PackedFloat32Array()
	out.resize(T.size())
	for i in range(0, T.size() - 3, 4):
		out[i] = T[i]
		out[i + 1] = T[i + 1]
		out[i + 2] = T[i + 2]
		out[i + 3] = -T[i + 3]
	arr[Mesh.ARRAY_TANGENT] = out


static func _wants_tangents(mat: Variant) -> bool:
	if mat == null:
		return false
	if mat is ShaderMaterial:
		return true
	if not (mat is BaseMaterial3D):
		return false
	var bm := mat as BaseMaterial3D
	if bm.normal_texture != null or bm.heightmap_enabled:
		return true
	var nm := String(bm.resource_name)
	if nm.contains("__vtrparallax") or nm.contains("__fxanim3"):
		return true
	# foliage wind only swaps alpha-cutout, textured, name-matched materials
	if bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED \
			and bm.albedo_texture != null \
			and RegEx.create_from_string("(?i)(" + WIND_MAT_PAT + ")").search(nm) != null:
		return true
	return false


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
		# Tangents were left in the OLD frame: this rewrote vertices and normals
		# and passed ARRAY_TANGENT straight through. Every prop GLB we ship
		# carries AUTHORED tangents (131 of 131 surfaces across a 40-prop sample),
		# so this was not a missing array, it was a wrong one â€” 30 degrees out on
		# a 90 degree bake, and completely silent.
		_xform_tangents(arr, xf.basis)
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
		# reversing the winding reverses the handedness of the tangent frame, so
		# the binormal sign has to follow. _merge_meshes already does this for
		# mirrored instances (`-w if flip`); this copy did not, so mirrored props
		# built through here had their normal maps lit inside out.
		_flip_binormal(arr)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := mesh.surface_get_material(s)   # keep materials on the flipped copy
		if mat != null: out.surface_set_material(out.get_surface_count() - 1, mat)
	_flip_cache[mesh] = out
	return out

# One MultiMeshInstance3D for a batch of placements, splitting mirrored
# (negative-determinant) instances onto a winding-flipped copy of the mesh so
# they render right-side-out. Used for backdrop entries (no distance streaming).
var _bd_list: Array = []    # backdrop MMIs â€” tied to the Range slider too

func _add_multimesh(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> void:
	var count := int(xf.size() / 12)
	if mesh == null or count == 0: return
	var pos: Array = []
	var neg: Array = []
	for i in range(count):
		var o := i * 12
		var dst: Array = neg if _det3(xf, o) < 0.0 else pos
		for j in range(12): dst.append(xf[o + j])
	# Counted for the same reason the props cells are: these are what the frame
	# after the slice has to flush. See _yield_report.
	_inst_made += count
	if not pos.is_empty():
		var m1 := _build_mmi(mesh, pos, textured, flat_mat)
		_no_backdrop_shadow(m1)
		parent.add_child(m1)
		_bd_list.append(m1)
		_mmi_add("skyline", 1)
	if not neg.is_empty():
		var m2 := _build_mmi(_flipped_mesh(mesh), neg, textured, flat_mat)
		_no_backdrop_shadow(m2)
		parent.add_child(m2)
		_bd_list.append(m2)
		_mmi_add("skyline", 1)


# The skyline never casts. _build_mmi's size rule lets it through â€” every
# backdrop cluster is 500+ m across, so it is "big enough to matter" by any
# measure of extent â€” but extent is the wrong question for geometry that exists
# only to fill the horizon.
#
# Measured on Dumbo with shadows off: the backdrop is 59 visible nodes carrying
# 6,639 surfaces for 0.1M triangles. That is 112 surfaces per node of almost no
# geometry, and a casting surface is paid once per directional cascade, so
# letting it cast costs ~33,000 draw calls â€” around half the entire frame â€” to
# render shadows from buildings that sit outside the play area and fall only on
# other backdrop buildings. Nothing in view gets a shadow it would otherwise
# have; the cost is the whole effect.
#
# Deliberately NOT routed through the Shadows checkbox or the size rule: this is
# not a quality trade the user should have to find, it is set dressing that was
# never a shadow caster in the first place.
func _no_backdrop_shadow(g: GeometryInstance3D) -> void:
	if g != null:
		mark_never_casts(g)


# "This node must never cast, whatever any toggle says."
#
# Setting cast_shadow = OFF at build time is not enough on its own: the Shadows
# checkbox walks the whole overlay and re-derives casting from the mesh's extent
# (HighpolyLighting._set_shadows), and the skyline is 500+ m across, so it sails
# past any size rule and switches straight back on. That is exactly what
# happened â€” a measured pass came back with 6,627 of 6,632 backdrop surfaces
# casting again, 26,508 draw calls, after the build had correctly turned them
# off. The terrain went with it.
#
# So the intent has to live ON THE NODE where every later pass can see it,
# rather than in a flag that the next walk overwrites.
static func mark_never_casts(g: GeometryInstance3D) -> void:
	if g == null:
		return
	g.set_meta("no_shadow", true)
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# Build the _MAP_CONTEXT subtree. Everything owner=null.
#   enabled      â€“ Map Context on at all (terrain + surroundings baseline)
#   show_objects â€“ add the game's original object placements (props layer)
#   tex          â€“ detail mode, following the dock's Detail Mode dropdown:
#                  0 = flat SDK study colours (green land, orange objects),
#                  1 = untextured grey high-poly (clay), 2 = textured.
#                  Legacy bool callers (PhotoMatch): false = 0, true = 2.
# `backdrop` defaults OFF so the teardown calls â€” apply(r, false, false, false),
# used to free the overlay â€” cannot accidentally build a skyline on their way
# out. Every call that wants layers passes what its toggles actually say.
# SAY WHAT IS RUNNING BEFORE IT RUNS. The stall table names the crumb that was
# current when a block STARTED, and apply() never set one - so its 30-44 s of
# main-thread map_data (heightfield decode, road drape, section mining) was
# reported as "frozen during: idle, nothing building", which reads as a hang
# while doing nothing and sent the diagnosis chasing the renderer. The idle
# crumb is restored only if no builder took over: the props/skyline builders
# apply() launches set their own crumbs after this returns, and stamping idle
# over one of those would re-arm the same lie in the other direction.
func apply(root: Node, enabled: bool, show_objects: bool, tex = true,
		backdrop := false, water := false) -> String:
	HighpolyVitals.crumb("applying the map context")
	var verdict := _apply_body(root, enabled, show_objects, tex, backdrop, water)
	if HighpolyVitals.crumb_now() == "applying the map context":
		HighpolyVitals.crumb("idle, nothing building")
	return verdict


func _apply_body(root: Node, enabled: bool, show_objects: bool, tex = true,
		backdrop := false, water := false) -> String:
	# The phase table covers ONE apply and the builds it launches. Reset here
	# rather than per build: the two builders run concurrently and the terrain,
	# the roads and the water are paid before either of them starts, so a table
	# that began at the props build would miss the first half of the wait.
	_ph_reset()
	var _t_apply := Time.get_ticks_msec()
	var tex_mode: int = (2 if tex else 0) if tex is bool else int(tex)
	var textured := tex_mode == 2
	# PREVIOUS state, captured before it is overwritten: the skyline salvage
	# below depends on what the LAST apply() built, not this one.
	var prev_tex_mode := _ctx_tex_mode
	var prev_map := _map
	var prev_backdrop := _show_backdrop
	var prev_objects := _show_objects
	_active = enabled
	_show_objects = show_objects
	_show_backdrop = backdrop
	_show_water = water
	_ctx_tex_mode = tex_mode
	if root == null: return "No scene open"
	var map := map_of(root)
	if map == "": return "Open a level scene (MP_â€¦) first"

	# --- KEEP THE SKYLINE ACROSS A REBUILD --------------------------------
	# Every layer toggle lands here, and this used to _clear() the entire map
	# context and rebuild all of it. The skyline is 155 files of GLB parsing
	# and texture work on Dumbo, measured at 375 SECONDS. So switching Water on
	# after the horizon had finished threw the horizon away and spent another
	# six minutes rebuilding something already on screen â€” then did it again
	# for the next toggle. In a recorded session that was two 375 s rebuilds
	# before the props were even allowed to start.
	#
	# Nothing about Water, Objects or FX changes the skyline. It genuinely has
	# to be rebuilt only when the MAP changes, when the detail mode changes
	# (its materials are baked per mode), or when it never finished. Otherwise
	# lift it out before the teardown and re-parent it afterwards.
	var saved_bd: Node3D = null
	if backdrop and prev_backdrop and map == prev_map and tex_mode == prev_tex_mode \
			and _bd_total > 0 and _bd_done >= _bd_total:
		var old_ctx := root.get_node_or_null(NODE)
		if old_ctx != null:
			var bd := old_ctx.get_node_or_null("Backdrop")
			if bd is Node3D:
				old_ctx.remove_child(bd)
				saved_bd = bd as Node3D

	# --- AND KEEP THE PROPS, for exactly the same reason -------------------
	# The skyline got this treatment and the props did not, so switching
	# Extended Terrain on AFTER the map objects had finished threw away all
	# 2,761 of them and built them again from scratch. A recorded Dumbo session
	# spent 231 s on the second build, ran `props: load mesh` 5,522 times
	# instead of 2,761, and paid the fast-load sidecar write three times over â€”
	# 311 s, the largest single phase in the run.
	#
	# Nothing about the terrain, the water or the skyline touches the props.
	# They genuinely have to be rebuilt only when the MAP changes, when the
	# detail mode changes (their materials are baked per mode), when the layer
	# was off before, or when the build never finished â€” a HALF-BUILT set must
	# be rebuilt, because the builder that was filling it has been cancelled
	# and nothing would ever finish the job.
	var saved_props: Node3D = null
	if _can_keep_props(show_objects, prev_objects, map, prev_map, tex_mode,
			prev_tex_mode):
		var old_ctx2 := root.get_node_or_null(NODE)
		if old_ctx2 != null:
			var pr := old_ctx2.get_node_or_null("Props")
			if pr is Node3D:
				old_ctx2.remove_child(pr)
				saved_props = pr as Node3D
	var _t_clear := Time.get_ticks_msec()
	_clear(root, saved_bd != null, saved_props != null)
	# THE TEARDOWN IS A PHASE. It frees every MultiMeshInstance in the overlay,
	# which on a full map is tens of thousands of nodes, and it runs on the main
	# thread inside a toggle handler where the user is waiting. It has never been
	# measured; if a "why did that toggle take four seconds" complaint has no
	# other explanation, it is this row.
	_ph("apply: clear the old overlay", Time.get_ticks_msec() - _t_clear,
		1, PH_ENGINE)

	# Load map data whenever we need geometry: terrain context OR objects.
	var need_data := enabled or show_objects or backdrop or water

	# EVERYTHING OFF MEANS GIVE THE MEMORY BACK.
	#
	# A user watched the editor reach 16 GB with everything on and sit at 14 GB
	# with everything off. _clear() frees the overlay's NODES and releases the
	# BcTex pool, but every mesh, material and texture the reader built is still
	# referenced by a cache in highpoly_gamesource, so Godot cannot free any of
	# it. Measured at full build: 2,402 textures, 16,125 materials, 7,222
	# meshes, none of which evicts.
	#
	# GATED ON need_data, NOT on _clear's keep flags. _clear also runs at the
	# start of every rebuild, and a rebuild that happens to keep nothing would
	# otherwise drop the caches and force a full re-read - turning a layer
	# toggle into a much slower operation. This fires only when no layer wants
	# geometry at all, which is the user saying they are done with it.
	#
	# The on-disk geometry cache is untouched, so switching back on is the
	# ~10.7 s cached path rather than a 63 s cold read.
	# A MAP SWITCH IS THE OTHER TIME TO LET GO, and it is the one that actually
	# kills people. A user log shows the editor dying after
	#   MP_Aftermath -> (none) -> Capital Supremacy Prefab -> MP_Abbasid
	# having reached 16 GB. Releasing only when every layer goes off never fires
	# on that path: nothing is switched off, a second map is simply built on top
	# of the first, so the old map's meshes, materials and textures stay cached
	# forever alongside the new one's. Three maps in a session is three full sets
	# of geometry in memory, and the VRAM guard was already warning at 6,146 MB
	# in the same logs.
	var switched_map: bool = map != prev_map and prev_map != ""
	if (not need_data or switched_map) and game_source != null \
			and game_source.has_method("release_caches"):
		var freed: Dictionary = game_source.release_caches()
		if int(freed.get("textures", 0)) > 0:
			Log.info(("[High-Poly] released %d textures, %d materials and %d "
				+ "meshes held for %s. %s")
				% [freed.get("textures", 0), freed.get("materials", 0),
				   freed.get("meshes", 0),
				   prev_map if switched_map else "the map context",
				   "Building the new map from the on-disk cache." if switched_map
				   else "Turning a layer back on rebuilds from the on-disk cache."])
	var have_data := false
	if need_data:
		# ASKED BEFORE THE CALL, not after: the call is what fills the cache, so
		# afterwards the answer is always yes and the row would always claim to
		# have been free.
		var _data_cached: bool = game_source != null \
			and game_source.has_method("map_data_ready") \
			and game_source.map_data_ready("%s/%s" % [CACHE, map])
		var _t_data := Time.get_ticks_msec()
		have_data = _load_data(map)
		# CACHED AFTER THE FIRST ASK, and that is exactly why it is worth a row.
		# _load_data reaches game_source.map_data, which builds the heightfield,
		# the roads, the lights and the FX the first time and returns a stored
		# dictionary afterwards. A one second row here and a ninety second row
		# here are the same call.
		_ph("apply: map data", Time.get_ticks_msec() - _t_data, 1,
			PH_MEMORY if _data_cached else PH_INSTALL)

	# `backdrop` counts here too: the skyline is a layer in its own right, so
	# wanting it is reason enough to build even with the terrain, the objects and
	# the textured ground all off.
	if not enabled and not textured and not show_objects and not backdrop \
			and not water:
		return "Map Context off"

	# one owner=null container for all editor-only overlay geometry (never saved)
	var ctx := Node3D.new(); ctx.name = NODE
	root.add_child(ctx); ctx.owner = null
	var dir := "%s/%s" % [CACHE, map]

	# --- textured ground ---
	# Two layers, kept separate:
	#  1. The SDK's shipped playable centre (MP_<Map>_Terrain + _Assets/buildings)
	#     keeps the simple maptile DECAL â€” the "easy win", untouched, still textures
	#     the buildings.
	#  2. OUR map-context terrain (the centre-fill our terrain adds + the outer
	#     tiles beyond the SDK bowl) gets the near-exact DETAIL shader: real game
	#     ground-layer albedo/normal, slope-selected, so it's no longer pixelated.
	var tmat: ShaderMaterial = null
	if textured:
		# THE GROUND'S MATERIAL, which is a stack of image loads: the splat index
		# and weight pages, the colour map, and one Texture2DArray built from up
		# to 32 layer slices. All of it comes off disk from the map's cache, so
		# it is a cache row, and it is the reason switching Extended Terrain on
		# is not instant even on a map that is otherwise fully built.
		var _t_tm := Time.get_ticks_msec()
		tmat = _terrain_shader_mat(map)               # detail material for our extended terrain
		_ph("terrain: ground material (splat + colour map)",
			Time.get_ticks_msec() - _t_tm, maxi(1, _splat_n), PH_CACHE)

	# STAND DOWN, AND STAND THEIRS DOWN TOO.
	#
	# We no longer project a ground photo at all - that is the SDK's feature now.
	# But while Extended Terrain is on, THEIR decal is projecting the same picture
	# onto ground that already carries it (the maptile is the large-scale colour
	# term inside our terrain shader) and onto every building and prop standing on
	# it. So it is hidden for the duration, and put back the moment Extended
	# Terrain goes off.
	#
	# Also sweep any decal an older version of this plugin injected, which can
	# still be sitting in a live scene after an in-session upgrade.
	var _t_dec := Time.get_ticks_msec()
	_remove_maptile(root)
	_set_sdk_decal_shown(root, not enabled)
	# Two scene walks looking for decal nodes. Cheap, and measured anyway: it
	# runs on every toggle, and "cheap" is a claim rather than a measurement
	# until a row says so.
	_ph("decals: maptile and SDK decal", Time.get_ticks_msec() - _t_dec, 1,
		PH_ENGINE)

	if not enabled and not show_objects and not backdrop and not water:
		if not textured: return "Map Context off"
		return "Map Context off (the SDK's ground texture is yours to control)"
	if not have_data:
		# The two ways to land here: no reader (the install path is wrong or was
		# never set) or a reader for a different map. Neither is "not downloaded"
		# - nothing downloads - and the old text also named a button ("Reload map
		# data") that no longer exists.
		return "%s could not be read from your game install - check the Battlefield 6 folder in Storage" % map

	# --- terrain + backdrop: "Show map context" ---
	var bd_ok := 0; var bd_total := 0
	# Shared by BOTH the terrain and the backdrop layers, so hoisted out of the
	# `if enabled:` block: Backdrops is its own toggle now, and the skyline has to
	# be renderable with the extended terrain switched off â€” it still needs `green`.
	#
	# untextured "study" material = the SDK's own M_LevelTerrain (shiny lime green
	# + its 12 m grid), matching the shipped terrain. DUPLICATE it (never touch the
	# shared SDK material). CULL_DISABLED originally hid a real bug â€” our heightmap
	# mesh was wound inside-out, so back-face culling blacked out the top and Godot
	# flipped the normal on every ground fragment, lighting the centre chunk
	# inverted next to the SDK's own terrain. The winding is correct as of v1.19.7;
	# this now only keeps the ground visible when you drop the camera below it.
	# Switching to CULL_BACK would halve the terrain's fill cost â€” untested.
	# `green` = backdrop; `green_tiled` = re-tiled to the SDK 12 m grid.
	var green_base: Material = _sdk_terrain_material(root, map)
	var green: Material = green_base
	var green_tiled: Material = green_base
	var hm: Dictionary = _data.get("heightmap", {})
	# The SDK's M_LevelAssets placeholder (shiny orange), shared by the props and
	# the backdrop. Backdrops are ASSETS, not ground: bridges, facades, towers.
	# They were being drawn in the terrain green, which made the skyline read as
	# distant hills rather than as the level's own untextured buildings, and made
	# it inconsistent with the map objects standing right in front of them.
	var orange: Material = _sdk_assets_material(root, map)
	if orange is BaseMaterial3D:
		var od := (orange as BaseMaterial3D).duplicate() as BaseMaterial3D
		od.cull_mode = BaseMaterial3D.CULL_DISABLED
		orange = od
	if tex_mode == 1:
		orange = _clay_mat()          # grey clay instead of the SDK orange
	if green_base is BaseMaterial3D:
		var span: float = float(hm.get("world_max", 2048)) - float(hm.get("world_min", -2048))
		var gb := (green_base as BaseMaterial3D).duplicate() as BaseMaterial3D
		gb.cull_mode = BaseMaterial3D.CULL_DISABLED
		green = gb
		var gt := (green_base as BaseMaterial3D).duplicate() as BaseMaterial3D
		gt.cull_mode = BaseMaterial3D.CULL_DISABLED
		gt.uv1_scale = Vector3(span / SDK_GRID_M, span / SDK_GRID_M, 1.0)
		green_tiled = gt
	if enabled:
		var terrain_lift := 0.0
		if hm.has("file"):
			# THE HEIGHTFIELD MESH: a 16-bit raw file read and turned into chunked
			# geometry on the MAIN THREAD, inside the toggle handler. Counted in
			# chunks so a change to terrain_step can be judged by what it costs
			# per chunk rather than only by whether the total moved.
			var _t_ter := Time.get_ticks_msec()
			var tmi := _build_terrain_from_heightmap(dir, hm)   # chunked full-accuracy mesh from raw 16-bit heights
			_ph("terrain: build the heightfield mesh",
				Time.get_ticks_msec() - _t_ter,
				0 if tmi == null else tmi.get_child_count(), PH_CACHE)
			if tmi:
				# exact data height, no sink (was -0.5 to dodge z-fighting under
				# the SDK bowl: read as "terrain a meter low" â€” the heightmap is
				# exact Â±5 mm). In SPLAT mode the maptile decal that visually
				# masked the coincident SDK bowl is gone, so lift our terrain a
				# hair instead: it wins the depth test and the splat ground shows
				# over the whole footprint (bowl included).
				if textured and tmat != null and _splat_active:
					terrain_lift = SPLAT_LIFT
				tmi.position.y = terrain_lift
				for tc in tmi.get_children():
					if tc is MeshInstance3D:
						var tcm := tc as MeshInstance3D
						tcm.material_override = tmat if (textured and tmat != null) else green_tiled
						tcm.layers = EXT_TERRAIN_LAYER           # tag: already carries its ground look
						_bd_list.append(tcm)                     # terrain tiles follow the Range slider
				ctx.add_child(tmi); tmi.owner = null
			# vegetation scatter: grass/shrub kits placed procedurally around the
			# editor camera (highpoly_scatter.gd). Any detail mode â€” grass reads
			# fine over the flat green too; no scatter.json â†’ strict no-op.
			if hm.has("file"):
				var _t_sc := Time.get_ticks_msec()
				_scatter.y_lift = terrain_lift    # grass sits ON the (possibly lifted) ground
				_scatter_n = _scatter.setup(self, ctx, map, dir, hm, _scatter_tile(map))
				if _scatter_n > 0:
					# The kits exist either way; whether anything DRAWS is the
					# Grass chip's call, re-applied because setup() starts cold.
					set_grass(want_grass)
					var scam := _editor_cam()
					if scam: _scatter.tick(scam.global_transform.origin)
				_ph("scatter: set up the vegetation kits",
					Time.get_ticks_msec() - _t_sc, maxi(1, _scatter_n), PH_CACHE)
	# Roads and street markings, baked from the level's TerrainDecals and draped
	# on the heightfield by roads_build.py. They belong with the ground, so they
	# follow Extended Terrain rather than getting a switch of their own: without
	# them the map is bare dirt where the street network should be.
	var _t_roads := Time.get_ticks_msec()
	var _roads_from := ""
	if enabled:
		# FROM THE INSTALL when the game source is live: same records, same
		# drape, same Y bias, read out of the player's own TerrainDecals resource
		# instead of arriving pre-baked in a GLB. Checked BEFORE the file so a
		# stale roads.glb left behind in a cache by an older version cannot win
		# over the live read.
		var rmesh = _data.get("roads") if _data is Dictionary else null
		if rmesh is Mesh:
			_roads_from = PH_MEMORY   # already built by map_data, on the worker
			var rmi := MeshInstance3D.new()
			rmi.name = "Roads"
			rmi.mesh = rmesh as Mesh
			rmi.layers = EXT_TERRAIN_LAYER      # tag: already carries its ground look
			mark_never_casts(rmi)
			ctx.add_child(rmi)
			rmi.owner = null
		var rp := "%s/roads/roads.glb" % dir
		if rmesh == null and FileAccess.file_exists(rp):
			_roads_from = PH_CACHE            # the pre-baked roads.glb on disk
			var rn := _load_external_glb(rp)   # live root, adopted into the tree
			if rn != null:
				rn.name = "Roads"
				ctx.add_child(rn)
				rn.owner = null
				# already lifted by the baker's Y bias; keep the maptile decal
				# off them so they are not tinted twice
				var rstack: Array = [rn]
				while not rstack.is_empty():
					var rc: Node = rstack.pop_back()
					for cc in rc.get_children():
						rstack.append(cc)
					if rc is GeometryInstance3D:
						(rc as GeometryInstance3D).layers = EXT_TERRAIN_LAYER
						mark_never_casts(rc as GeometryInstance3D)

	# Water is its own layer too. It is not terrain (plenty of maps have a river
	# or a harbour you may want to see without the surrounding ground, or the
	# other way round) and it is not scenery. The Configure Shaders water setting
	# still drives its ripple speed either way: apply_shader_prefs walks the whole
	# overlay, so the plane picks the pref up wherever it is parented.
	if _roads_from != "":
		# The chip's state survives a rebuild: whichever branch above placed the
		# node, it starts hidden if that is how the user left it.
		var _rd := ctx.get_node_or_null("Roads")
		if _rd is Node3D:
			(_rd as Node3D).visible = _show_roads
		_ph("roads: place the street mesh", Time.get_ticks_msec() - _t_roads,
			1, _roads_from)
	if water:
		# One plane per body plus its shader, its normal maps and its wave video.
		# It has its own toggle and its own complaint history ("Water takes a
		# moment"), so it gets its own row instead of disappearing into apply.
		var _t_w := Time.get_ticks_msec()
		_add_water_plane(ctx, textured)
		var _wn: Variant = _data.get("water", []) if _data is Dictionary else []
		_ph("water: build the surface", Time.get_ticks_msec() - _t_w,
			maxi(1, (_wn as Array).size() if _wn is Array else 1), PH_INSTALL)

	# The distant skyline / out-of-bounds vista is its OWN layer, not part of the
	# terrain. Extended Terrain gives you the ground the level sits on, Water the
	# rivers and sea, Backdrops the horizon around it, and Original map objects
	# the level's own props. Each is separately switchable because they answer
	# different questions about a build.
	# Re-parented, not rebuilt. _bd_total/_bd_done/_bd_ok and _bd_list are left
	# untouched (see _clear's keep_backdrop), so progress reporting and the
	# distance culling keep working on the meshes that are already there.
	# NOTE the two early returns above cannot strand this node: both require
	# `not backdrop`, and saved_bd is only ever set when backdrop is true.
	if backdrop and saved_bd != null:
		ctx.add_child(saved_bd)
		saved_bd.owner = null
		bd_total = _bd_total          # so the status line still counts them
		bd_ok = _bd_ok
		Log.debug("map context: kept the existing skyline (%d piece(s)) rather than rebuilding it"
			% _bd_list.size())
	elif backdrop:
		var bd_root := Node3D.new(); bd_root.name = "Backdrop"
		ctx.add_child(bd_root); bd_root.owner = null
		# NON-BLOCKING, for the same reason the props layer is. Each entry is a
		# _parse_prop_file() â€” a GLB parse plus a texture decode and S3TC
		# recompress â€” and a map can carry well over a hundred of them (Dumbo has
		# 155). Running that loop inline froze the editor solid the moment
		# Backdrops was switched on. Hand it to a frame-budgeted builder with its
		# own progress lane, exactly like the map objects.
		# nearest-first, same as the props layer: the horizon fills in outward
		# from wherever the camera is standing rather than in file order
		var _t_sort := Time.get_ticks_msec()
		var bd_entries: Array = _sorted_prop_entries(_data.get("backdrop", []))
		# Nearest-first ordering costs a distance test per instance of every
		# entry, so it scales with placements and not with entries. Small on the
		# skyline, not obviously small on the props: both are measured.
		_ph("skyline: sort the queue nearest first",
			Time.get_ticks_msec() - _t_sort, bd_entries.size(), PH_MEMORY)
		bd_total = bd_entries.size()
		_bd_total = bd_total
		_bd_done = 0
		_bd_ok = 0
		if bd_total > 0:
			_build_backdrop_async(bd_root, bd_entries, dir, textured, orange,
					_build_gen)                       # fire-and-forget

	# --- status summary base (computed BEFORE the props build launches, so the
	# background builder's very first progress report already carries it) ---
	var mt := ""
	if textured:
		var cm_on := colormap_enabled and not _colormap_set(map).is_empty()
		if tmat != null and _splat_active:
			mt = ", SPLAT terrain (%d layer slices%s)" % [_splat_n,
				", colour map" if cm_on else ""]
		elif tmat != null:
			mt = ", detail terrain%s" % (" + colour map" if cm_on else "")
		else:
			mt = " (no ground layer set)"
	var tex_lbl := "textured" if textured else ("clay" if tex_mode == 1 else "flat colour")
	# the skyline builds in the background now, so this line is written before a
	# single piece exists â€” report what was QUEUED, not a completed count that
	# would sit at 0 for the life of the message
	var surr := ", %d surroundings" % bd_total if bd_total > 0 else ""
	var sct := ", %d scatter types" % _scatter_n if _scatter_n > 0 else ""
	_build_status_base = "%s: terrain %s%s%s%s" % [map, tex_lbl, surr, sct, mt]

	# --- objects: "Original map objects" â€” independent of the terrain context, so
	# you can drop them onto the SDK's own playable terrain alone. Untextured, they
	# use the SDK's M_LevelAssets (shiny orange) placeholder to match the shipped
	# assets; textured, they keep their own material.
	if show_objects and saved_props != null:
		# Re-parented, not rebuilt. _build_total/_build_done and _cells are left
		# untouched (see _clear's keep_props), so the status line still counts
		# them and the distance culling keeps working on the meshes already
		# there. _props_dir/_props_textured/_props_mat/_props_tex_mode are still
		# describing this same set, because a change to any of them is what
		# would have disqualified the salvage.
		ctx.add_child(saved_props)
		saved_props.owner = null
		_apply_radius()
		Log.debug("map context: kept the existing map objects (%d piece(s)) rather than rebuilding them"
			% _build_total)
	elif show_objects:
		var props_root := Node3D.new(); props_root.name = "Props"
		ctx.add_child(props_root); props_root.owner = null
		# NON-BLOCKING: parsing ~2k unique GLBs + building their MultiMeshes
		# inline froze the editor for minutes. Queue the mesh groups
		# nearest-first from the editor camera and hand them to an incremental
		# builder (small time budget per frame) â€” the editor stays responsive
		# and props appear from the camera OUTWARD. apply() itself stays
		# synchronous; callers that need the COMPLETE overlay (PhotoMatch)
		# wait on is_build_done().
		_props_dir = dir              # remembered for refresh_changed_props
		_props_textured = textured
		_props_mat = orange
		_props_tex_mode = tex_mode    # set_objects_shown fast path key
		_variant_layer_groups = {}    # groups rebuild under the fresh Props node
		var _t_psort := Time.get_ticks_msec()
		var entries := _sorted_prop_entries(_data.get("props", []))
		_ph("props: sort the queue nearest first",
			Time.get_ticks_msec() - _t_psort, entries.size(), PH_MEMORY)
		_build_total = entries.size()
		_build_done = 0
		_build_props = 0
		_last_report = 0
		_building = _build_total > 0
		if _building:
			_build_props_async(props_root, entries, dir, textured, orange, _build_gen)   # fire-and-forget
		else:
			_apply_radius()
		_add_env_decals(props_root)

	var objs := ""
	if show_objects:
		if _building:
			objs = ", building %d object meshesâ€¦" % _build_total
		else:
			objs = ", %d object meshes" % _build_props
	_last_status = "%s: terrain %s%s%s%s%s" % [map, tex, surr, objs, sct, mt]
	# A BUILD WITH NO LANES STILL HAS TO REPORT.
	#
	# The phase table is printed by whichever of the props or skyline lanes
	# finishes last, so an apply that starts NEITHER - terrain on its own, which
	# is exactly what someone does first - printed nothing at all. A user spent
	# 15 minutes on a terrain-only build and their log had a four and a half
	# minute hole where the table should have been, because no lane ever ran to
	# print it.
	if not _building and bd_total <= 0:
		for line in _ph_report("%s terrain only" % map):
			Log.info(line)
		if game_source != null and game_source.has_method("build_report"):
			for line in game_source.build_report():
				Log.info(str(line))
	return _last_status

# ---------- non-blocking props build ----------
# True once the background props build has finished (or none is running).
# Batch consumers (PhotoMatch's render hook) poll this before rendering so
# they always shoot a COMPLETE overlay.
func is_build_done() -> bool:
	return not _building

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

# Incremental builder â€” launched WITHOUT await from apply() (fire-and-forget).
# Spends BUILD_FRAME_MS of GLB parsing + MultiMesh building per frame, then
# yields a frame. gen is compared against _build_gen after EVERY await: a new
# apply()/_clear() bumps the generation and this pass stops dead â€” its nodes
# were already freed with _MAP_CONTEXT, and it must never touch the state a
# newer pass now owns (so no _building/_report writes on that path).
# Same contract as _build_props_async: spend BUILD_FRAME_MS per frame, yield,
# and stop dead if _clear() bumped the generation while we were away. Its own
# counters and signal so it can run alongside the props build without the two
# fighting over one progress lane.
func _build_backdrop_async(bd_root: Node3D, entries: Array, dir: String,
		textured: bool, mat: Material, gen: int) -> void:
	var frame_start := Time.get_ticks_msec()
	# THE SKYLINE DELIBERATELY DOES NOT PREFETCH, unlike the props â€” and the
	# reason recorded here for years was wrong.
	#
	# It used to say backdrop meshes carry BLEND SHAPES and that parsing them on
	# workers produced `mesh_set_blend_shape_mode` errors. Re-tested against the
	# real files: ZERO of the 14 heaviest Dumbo backdrops carry a blend shape at
	# all. The objection was real, the explanation was not.
	#
	# What actually happens is worse. Prefetching backdrops SEGFAULTS Godot,
	# reproducibly, and bisecting the worker job by stage says exactly where:
	#
	#   parse only (append_from_buffer)     survives, 42 ms/file on workers
	#   + generate_scene                    SEGFAULT
	#   + tangents                          completed, then died freeing
	#   + compress (what props do)          SEGFAULT
	#
	# So generate_scene off the main thread is the unsafe call, and it is unsafe
	# on CONTENT, not in general: the identical job over 60 props survives five
	# runs out of five. Backdrops carry ~653 materials and ~706 textures apiece
	# against a prop's ~13, and that is the difference.
	#
	# This costs 94.6 s of a cold load, all of it on the main thread, and it is
	# the largest single item left. It is not worth an editor that dies.
	#
	# IT DOES HIDE ITSELF WHILE BUILDING, same as the props, and for the skyline
	# it matters more than anywhere else: the backdrop is 3,118 draw calls from
	# 34 nodes â€” by far the largest single source in the whole overlay â€” and it
	# was being re-rendered on every yielded frame while more of it was still
	# being added. That is why the first half of a skyline build felt instant and
	# the second half crawled: nothing about the pieces changes, only how much is
	# on screen while the next one is prepared.
	var bd_id := bd_root.get_instance_id()
	HighpolyProfiler.crumb("skyline", "build started, %d piece(s)" % entries.size())
	_begin_build_draw(bd_root)
	for ei in range(entries.size()):
		var e = entries[ei]
		var meshes: Array = []
		# FROM THE INSTALL, the same as the props. map_data() splits the walk's
		# StaticModelGroup rows emitted straight from the level root into a
		# `backdrop` list — all 155 of the packaged skyline meshes are among
		# them and all 155 resolve to a MeshSet — and this is what draws them.
		#
		# Without this branch the skyline silently does not exist on the game
		# path: an entry carries neither `glb` nor `model`, both tests fail, and
		# the loop counts it done having built nothing. It looks like a slow
		# build rather than a missing one, and the session harness waits out its
		# whole timeout for a surface census that will never move off zero.
		if game_source != null and bool(_data.get("from_game", false)) \
				and e.has("mesh"):
			# AWAITED like the props loop does. The game branch of _prop_mesh
			# returns without yielding, but _prop_mesh is a coroutine either way
			# and calling one bare hands back a state object rather than the
			# Array — which then reads as "no meshes" and builds nothing.
			#
			# TIMED, and it was not before. The game branch had no span at all,
			# so on a game-sourced map the skyline's largest cost, the one this
			# note above blames for 94.6 s, was attributed to nothing.
			var _bkey := str(e.get("mesh", ""))
			var _bwas := _mesh_cache.has(_bkey)
			var _bh0 := int(game_source.n_geom_hit)
			var _bm0 := int(game_source.n_geom_miss)
			var _tg := Time.get_ticks_msec()
			meshes = await _prop_mesh(e, dir)
			var _bms := float(Time.get_ticks_msec() - _tg)
			var _bfrom := PH_MEMORY
			if not _bwas:
				if int(game_source.n_geom_miss) > _bm0:
					_bfrom = PH_INSTALL
				elif int(game_source.n_geom_hit) > _bh0:
					_bfrom = PH_CACHE
			_ph("skyline: load mesh (game source)", _bms, 1, _bfrom)
			# A suspension point the skyline loop did not have before: the scene
			# can be closed or the layer switched off across it, and everything
			# below assumes bd_root is still there.
			if gen != _build_gen or not is_instance_valid(bd_root):
				_end_build_draw(bd_root)
				return
		elif e.has("glb"):
			var gp := "%s/%s" % [dir, e["glb"]]
			if FileAccess.file_exists(gp):
				# merge ALL mesh nodes like the props path â€” the rebuilt skyline
				# GLBs carry one node per material section (Roof, Walls...);
				# _extract_mesh took only the FIRST, which rendered the distant
				# buildings as floating rooftops
				# TIMED. Only the MERGES inside this call were instrumented, so a
				# recording showed 13 s of "skyline: merge mesh nodes" sitting
				# inside a 99 s skyline build and said nothing whatsoever about
				# the other 86 â€” the largest unexplained block in the load, and
				# invisible until the skyline got a progress lane of its own.
				var _ts := Time.get_ticks_msec()
				_merge_who = "skyline"
				meshes = await _parse_prop_file(gp)
				_merge_who = "props"
				_ph("skyline: load mesh (GLB parse + cache)",
					Time.get_ticks_msec() - _ts, 1, PH_CACHE)
		elif e.has("model"):
			var bm := _mesh_for(str(e["model"]))
			if bm != null:
				meshes = [bm]
		if meshes.size() > 0 and is_instance_valid(bd_root):
			var mesh: Mesh = meshes[0]
			# a smoke sheet filed under the backdrop layer follows the FX switch
			# too, wherever the level chose to put it
			var bdest: Node3D = bd_root
			if _is_fx_card(mesh, str(e.get("name", e.get("mesh", "")))):
				bdest = _fx_cards_group(bd_root)
			# orange, not green: the skyline is made of the level's own
			# buildings, so untextured it should match the map objects in front
			# of it rather than the ground under it
			var _tm := Time.get_ticks_msec()
			for msh: Mesh in meshes:
				_add_multimesh(bdest, msh, e.get("xf", []), textured, mat)
			_ph("skyline: place multimesh", Time.get_ticks_msec() - _tm,
				maxi(1, int((e.get("xf", []) as Array).size() / 12)), PH_ENGINE)
			_bd_ok += 1
		_bd_done += 1
		if Time.get_ticks_msec() - frame_start >= _frame_ms():
			# Cull what has just been added, every slice. Without this the
			# skyline was built fully visible and stayed that way until
			# something else happened to call _apply_radius() â€” which in
			# practice meant it only started obeying the Range slider once the
			# user touched the slider. New pieces now obey it the moment they
			# exist, exactly like the props layer.
			var _tr := Time.get_ticks_msec()
			_apply_radius()
			_ph("skyline: apply_radius on every yield",
				Time.get_ticks_msec() - _tr, maxi(1, _bd_list.size()), PH_ENGINE)
			backdrop_progress.emit(_bd_done, _bd_total)
			if not is_inside_tree():
				_end_build_draw(bd_root)
				return
			# Same unattributed cost as the props loop, and it matters more here:
			# the skyline is 3,118 draw calls from 34 nodes, by far the largest
			# single source in the overlay, so a yielded frame that draws it is
			# the most expensive frame in the build.
			var _made := _mmi_since_yield("skyline")
			var _ty := Time.get_ticks_msec()
			await get_tree().process_frame
			var _fms := float(Time.get_ticks_msec() - _ty)
			_ph("skyline: waiting for the yielded frame", _fms, 1, PH_ENGINE)
			_yield_note("skyline", _fms, _made)
			# The paired probe, exactly as in the props loop, and this is the lane
			# it was written for: 16.8 s of a 50.9 s build went here and nobody
			# has ever known whether it was the redraw or the flush.
			if _yield_should_probe("skyline"):
				var _ty2 := Time.get_ticks_msec()
				await get_tree().process_frame
				_yield_note_probe("skyline", _fms,
					float(Time.get_ticks_msec() - _ty2))
				_mmi_since_yield("skyline")   # the probe frame built nothing
			if gen != _build_gen:
				_end_build_draw(bd_root)
				return                  # superseded by a new apply()/_clear()
			if not is_instance_valid(bd_root):
				_forget_build_draw(bd_id)   # this layer only; props may still build
				return
			frame_start = Time.get_ticks_msec()
	_apply_radius()                 # final pass: the last slice obeys it too
	var _t_show := Time.get_ticks_msec()
	_end_build_draw(bd_root)        # the finished skyline appears, here
	_ph("skyline: reveal the finished layer", Time.get_ticks_msec() - _t_show,
		1, PH_ENGINE)
	var _side_n := maxi(1, _side_writes.size())
	var _t_side := Time.get_ticks_msec()
	await flush_sidecars()          # cache written after the skyline is up
	_ph("skyline: flush the fast-load sidecars",
		Time.get_ticks_msec() - _t_side, _side_n, PH_CACHE)
	HighpolyProfiler.crumb("skyline", "build finished, %d of %d" % [_bd_ok, _bd_total])
	_release_texture_images()       # no-op if the props lane is still running
	backdrop_progress.emit(_bd_total, _bd_total)
	Log.debug("map context: skyline built, %d of %d piece(s)" % [_bd_ok, _bd_total])
	# ONLY THE YIELD REPORT HERE, not the whole phase table. The props lane is
	# usually still running and shares the table, so printing it now would show
	# half a build and invite exactly the wrong conclusion. The yield lanes are
	# separate per lane, so the skyline's is complete the moment it finishes.
	for line in _yield_report("skyline"):
		Log.info(line)
	if not _building:
		# Nothing else is running, so this build IS the whole apply and the table
		# is complete. When the props lane is still going, it prints the table
		# when it finishes and the skyline's rows are in it.
		for line in _ph_report("%s skyline, %d of %d built"
				% [_map, _bd_ok, _bd_total]):
			Log.info(line)


# --- keeping the work in progress off the screen ----------------------------
# A layer is invisible while it builds and appears, complete, when it finishes.
# Drawing the work in progress is what these builds spend a third of their time
# on: every yield hands back a frame, the editor re-renders everything placed so
# far, and the cost grows as the build proceeds, so the build slows itself down.
# Measured on real props: at 30k draw calls a frame costs 34.0 ms visible and a
# FLAT 4.2 ms hidden.
#
# It used to flash the layer on for one frame every 2 s, so you could watch it
# fill in. That was worse than useless to look at â€” the whole map appeared and
# vanished twice a minute â€” and it is gone. The progress bar reports the build
# now, which is what a progress bar is for.
#
# Keyed by node, because the props and the skyline build concurrently and each
# has to be restored to ITS OWN switch. Every exit from a builder MUST call
# _end_build_draw: a layer left hidden looks exactly like a build that failed.
var _hidden_builds: Dictionary = {}     # instance id -> node


# UNTYPED PARAMETERS, and that is the fix rather than a slip.
#
# Both of these guard with is_instance_valid, and with a `node: Node3D`
# signature that guard can never run: GDScript checks the argument's type at
# the call, and a previously-freed Object fails that check with "the
# Object-derived class of argument 1 (previously freed) is not a subclass of the
# expected argument class" before the body is entered. Every exit path in both
# builders calls _end_build_draw, several of them precisely because the node was
# freed underneath them, so the one case the guard exists for was the one case
# it could not handle.
func _begin_build_draw(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not _restore_visible_for(node):
		return                # already off by the user's own switch; leave it
	node.visible = false
	_hidden_builds[node.get_instance_id()] = node


func _end_build_draw(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if not _hidden_builds.has(node.get_instance_id()):
		return
	_hidden_builds.erase(node.get_instance_id())
	# back to whatever the LAYER'S OWN SWITCH says, not unconditionally on: the
	# user can turn a layer off while its build is still running, and forcing it
	# visible at the end would undo that.
	node.visible = _restore_visible_for(node)


# Drop the CPU-side texture pool, but only once BOTH lanes have stopped.
#
# The props and the skyline build concurrently and share the pool, so releasing
# at the end of whichever finished first would make the other one re-decode
# every texture it had left — turning the saving into extra work on exactly the
# layer that is slowest. _hidden_builds is already the record of which builds are
# live, so it answers this without a second flag to keep in step.
func _release_texture_images() -> void:
	if _hidden_builds.is_empty():
		BcTex.release_images()


func _release_build_draw() -> void:
	_hidden_builds.clear()   # the whole overlay is going; every layer with it


# One layer's node was freed under its builder. Erase by the id captured when
# the build started: the other layer may still be mid-build, and clearing the
# whole table would leave IT hidden forever.
func _forget_build_draw(id: int) -> void:
	_hidden_builds.erase(id)


func _restore_visible_for(node: Node3D) -> bool:
	return _show_backdrop if String(node.name).begins_with("Backdrop") else _show_objects


func _build_props_async(props_root: Node3D, entries: Array, dir: String,
		textured: bool, flat_mat: Material, gen: int) -> void:
	var frame_start := Time.get_ticks_msec()
	var _t_build := Time.get_ticks_msec()
	_vram_warned = false
	HighpolyProfiler.mark("phase", "props: build started, %d entries" % entries.size())
	HighpolyProfiler.crumb("props", "build started, %d entries" % entries.size())
	# DON'T DRAW THE HALF-BUILT MAP. The loop below hands a frame back every
	# BUILD_FRAME_MS, and the editor spends that frame re-rendering everything
	# placed so far â€” which grows as the build proceeds, so the build slows
	# itself down. On the recorded Dumbo run draw calls climbed 4,305 -> 14,500
	# during the build, fps fell 11.6 -> 7.5, and 84 s of a 261 s build went on
	# frame waits that the phase table never attributed to anything.
	#
	# Measured on real props: at 30k draw calls a frame costs 34.0 ms visible
	# and 4.2 ms hidden â€” and the hidden cost is FLAT no matter how much has
	# been placed, because nothing is being drawn.
	#
	# See _begin_build_draw for why this does not flash the layer on periodically
	# any more. Restored on every exit path â€” a layer left hidden looks exactly
	# like a build that failed.
	var props_id := props_root.get_instance_id()
	_begin_build_draw(props_root)
	# Parse a batch ahead on the worker pool while the main thread places the
	# previous one. PREFETCH_BATCH is a compromise: bigger batches parallelise
	# better but hold more parsed scenes in memory at once, and video memory is
	# already the thing that kills low-end cards.
	# NOTHING TO PREFETCH FROM THE INSTALL. The prefetch parses GLB files on
	# worker threads, and a game-sourced entry has no GLB — but _prop_path still
	# hands back a plausible-looking path for one, so every batch queued 48 files
	# that do not exist and the pool spent 7.2 s of a recorded build failing to
	# open them. The real parse for this path is inside game_source.mesh_for,
	# which is a different problem (56.9 s, and the next one worth solving).
	var from_game: bool = game_source != null and bool(_data.get("from_game", false))
	for ei in range(entries.size()):
		var e = entries[ei]
		vram_check()      # reports once if memory is getting high; never stops
		var gp := _prop_path(e, dir)
		# WHERE THIS MESH IS ABOUT TO COME FROM, sampled before the call because
		# the call is what makes it a hit. Three answers, and they are three
		# different builds wearing the same phase name: an in-process dictionary
		# hit costs nothing, a geometry-cache hit is a file read, and an install
		# read is the CAS fetch plus a MeshSet parse that the 85 s cold figure is
		# made of. One "props: load mesh" total cannot be read without this.
		var mkey := str(e.get("mesh", "")) if from_game else gp
		var was_cached := _mesh_cache.has(mkey)
		var g_hit0 := 0
		var g_miss0 := 0
		if from_game:
			g_hit0 = int(game_source.n_geom_hit)
			g_miss0 = int(game_source.n_geom_miss)
		var _t0 := Time.get_ticks_msec()
		_merge_who = "props"
		var meshes: Array = await _prop_mesh(e, dir)  # the expensive part (GLB parse; cached)
		var _ml := Time.get_ticks_msec() - _t0
		var mesh_from := PH_MEMORY
		var mesh_row := "props: mesh, shared in memory (of which)"
		if was_cached:
			pass                              # already the memory answer
		elif from_game:
			if int(game_source.n_geom_miss) > g_miss0:
				mesh_from = PH_INSTALL
				mesh_row = "props: mesh, read from the install (of which)"
			elif int(game_source.n_geom_hit) > g_hit0:
				mesh_from = PH_CACHE
				mesh_row = "props: mesh, from the geometry cache (of which)"
		else:
			mesh_from = PH_CACHE
			mesh_row = "props: mesh, parsed from a GLB (of which)"
		_ph("props: load mesh (GLB parse + cache)", _ml, 1, mesh_from)
		_ph(mesh_row, _ml, 1, mesh_from)
		var mesh: Mesh = meshes[0] if meshes.size() > 0 else null
		if gp != "":
			# refresh bookkeeping: which entries this source file built (recorded
			# even when the parse failed, so a file that lands later refreshes in)
			if not _prop_by_src.has(gp): _prop_by_src[gp] = []
			(_prop_by_src[gp] as Array).append(e)
		if mesh != null:
			var _t1 := Time.get_ticks_msec()
			var xf: Array = e.get("xf", [])
			var em: Dictionary = _prop_layers.get(str(e.get("mesh", "")), {})
			# flipbook cards are an effect, not scenery â€” own group, FX switch
			var dest: Node3D = props_root
			if _is_fx_card(mesh, str(e.get("mesh", ""))):
				dest = _fx_cards_group(props_root)
			# THE SUBWORLD THIS GROUP CAME FROM, when the reader supplied one.
			#
			# Groups are keyed by (mesh, scope, variation), so every instance in
			# one entry shares a subworld and the whole entry belongs to one
			# layer - simpler than the per-instance table prop_layers.json used
			# to carry, and available without the miner that produced it.
			#
			# "" means always on and keeps the entry in the base group.
			elif str(e.get("layer", "")) != "":
				dest = _variant_group(props_root, str(e["layer"]))
			if em.is_empty():
				# every mesh of a split prop, or the split drops what the
				# 255-surface cap used to drop
				for msh: Mesh in meshes:
					_add_cell_multimeshes(dest, msh, xf, textured, flat_mat, gp)
			else:
				# split layer-gated instances (winter dressing, Rush barriersâ€¦)
				# into visibility groups the Variant dropdown flips live.
				# (refresh_changed_props re-merges a refreshed mesh's instances
				# into the base group until the next full build â€” minor drift.)
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
					for msh: Mesh in meshes:
						_add_cell_multimeshes(dest, msh, base, textured, flat_mat, gp)
				for k in bux:
					for msh: Mesh in meshes:
						_add_cell_multimeshes(_variant_group(props_root, str(k)),
								msh, bux[k], textured, flat_mat, gp)
			# COUNTED IN INSTANCES, not in entries. One entry can be a single
			# crate or 4,000 of them, so a per-entry cost is meaningless here and
			# a per-instance one can be compared across maps.
			_ph("props: create multimesh cells", Time.get_ticks_msec() - _t1,
				maxi(1, int((e.get("xf", []) as Array).size() / 12)), PH_ENGINE)
			_build_props += 1
		_build_done += 1
		if Time.get_ticks_msec() - frame_start >= _frame_ms():
			# SUSPECT. This walks EVERY cell built so far, and it runs on every
			# yield â€” i.e. every BUILD_FRAME_MS of work â€” with an unlimited
			# budget. The set it walks grows as the build proceeds, so the cost
			# per yield grows with it: quadratic in the number of cells, for a
			# range check that only matters once the cells exist. Timed
			# separately so the next recording either convicts it or clears it.
			var _t2 := Time.get_ticks_msec()
			_apply_radius()                 # freshly added cells obey the range slider
			# Per CELL, which is the set it walks. If this row's per-item cost is
			# flat the walk is linear and fine; if it climbs, the suspicion above
			# is confirmed and the fix is to walk only what the slice added.
			_ph("props: apply_radius on every yield",
				Time.get_ticks_msec() - _t2, maxi(1, _cells.size()), PH_ENGINE)
			_report_progress()
			# Per SLICE, not per prop: ~40 ms of work apiece, so a crash narrows
			# to a handful of props by name rather than to "somewhere in 2,761".
			HighpolyProfiler.crumb("props", "at %d/%d  %s"
				% [ei, entries.size(), str(e.get("mesh", e.get("model", "?")))])
			if not is_inside_tree():        # host removed us mid-build: no tree to await
				if gen == _build_gen:
					_building = false
					_end_build_draw(props_root)
					build_finished.emit(_build_props)
				return

			# THE YIELD ITSELF IS A COST, and it was the largest thing the phase
			# table never showed. The loop works for BUILD_FRAME_MS and then
			# hands back a frame; whatever that frame costs is build time the
			# user waits through, attributed to nothing. On the recorded Dumbo
			# run it was 84 s of a 261 s build.
			#
			# Timed here so the duty cycle becomes readable: this figure against
			# BUILD_FRAME_MS says what fraction of the build is actually
			# building. It stays small only while the layer is hidden â€” see
			# _begin_build_draw â€” so a regression there shows up as this number
			# growing rather than as a vague "builds feel slower lately".
			var _made := _mmi_since_yield("props")
			var _ty := Time.get_ticks_msec()
			await get_tree().process_frame  # keep the editor smooth
			var _fms := float(Time.get_ticks_msec() - _ty)
			_ph("props: waiting for the yielded frame", _fms, 1, PH_ENGINE)
			_yield_note("props", _fms, _made)
			# THE PAIRED PROBE. Nothing is created between these two awaits, so
			# the second frame cannot be flushing new geometry: whatever it costs
			# is the redraw of what was already on screen. See PROBE_EVERY.
			if _yield_should_probe("props"):
				var _ty2 := Time.get_ticks_msec()
				await get_tree().process_frame
				_yield_note_probe("props", _fms,
					float(Time.get_ticks_msec() - _ty2))
				_mmi_since_yield("props")   # the probe frame built nothing
			if gen != _build_gen:
				_end_build_draw(props_root)
				return                      # superseded: _clear() already released
			if not is_instance_valid(props_root):
				_building = false           # scene/ctx freed underneath us
				_forget_build_draw(props_id)  # this layer only
				build_finished.emit(_build_props)
				return
			frame_start = Time.get_ticks_msec()
	var _t_final := Time.get_ticks_msec()
	_apply_radius()
	_ph("props: final apply_radius", Time.get_ticks_msec() - _t_final,
		maxi(1, _cells.size()), PH_ENGINE)
	_building = false
	HighpolyProfiler.crumb("props", "build finished, %d built" % _build_props)
	var _t_show := Time.get_ticks_msec()
	_end_build_draw(props_root)   # the finished map appears, here
	_ph("props: reveal the finished layer", Time.get_ticks_msec() - _t_show,
		1, PH_ENGINE)
	# and only NOW write the fast-load cache, with the map already on screen
	var _side_n := maxi(1, _side_writes.size())   # drained by the flush
	var _t_side := Time.get_ticks_msec()
	await flush_sidecars()
	_ph("props: flush the fast-load sidecars",
		Time.get_ticks_msec() - _t_side, _side_n, PH_CACHE)
	_report_progress(true)
	# The CPU-side texture pool has done its job — it exists to stop the same
	# pixels being decoded once per prop, and nothing decodes after this. The GPU
	# textures it fed stay pooled, because they are what is on screen.
	var _ps := BcTex.pool_stats()
	_release_texture_images()
	HighpolyProfiler.mark("phase", "props: build finished, %d built in %.1f s"
		% [_build_props, (Time.get_ticks_msec() - _t_build) / 1000.0])
	HighpolyProfiler.mark("phase", "textures: %d distinct of %d wanted (%d reused), %d GPU"
		% [int(_ps["misses"]), int(_ps["hits"]) + int(_ps["misses"]),
		   int(_ps["hits"]), int(_ps["textures"])])
	# WHERE A GAME-SOURCED BUILD ACTUALLY WENT. "props: load mesh" is one span
	# covering three unrelated costs — the CAS read, the MeshSet parse and the
	# depot-plus-texture material work — and they want completely different
	# fixes: the first is I/O, the second could move to a worker thread, the
	# third cannot because it uploads to the GPU. A single total picks none.
	# OR THE CACHE SERVED ANY, which is the case this used to miss entirely.
	# n_meshes only counts meshes READ FROM THE INSTALL, so a fully cached build
	# reported none of this: the one run where you most want to see what the
	# geometry cache bought you was the one run that printed nothing.
	if game_source != null and (int(game_source.n_meshes) > 0
			or int(game_source.n_geom_loaded) > 0):
		_ph("props: game source, read the resource (CAS)",
			int(game_source.t_res / 1000), int(game_source.n_geom_miss), PH_INSTALL)
		_ph("props: game source, parse + build the ArrayMesh",
			int(game_source.t_parse / 1000), int(game_source.n_geom_miss), PH_INSTALL)
		_ph("props: game source, materials (depot + textures)",
			int(game_source.t_mat / 1000), int(game_source.n_mat_built), PH_INSTALL)
		_ph("props: game source, texture decode (of which)",
			int(game_source.t_tex / 1000),
			int(game_source.tex_stats.get("decoded", 0)), PH_INSTALL)
		_ph("props: game source, depot parse (of which)",
			int(game_source.t_depot / 1000), int(game_source.n_depot_parsed),
			PH_INSTALL)
		HighpolyProfiler.mark("phase",
			"game source: %d meshes — read %.1f s, parse %.1f s, materials %.1f s"
			% [int(game_source.n_meshes), game_source.t_res / 1e6,
			   game_source.t_parse / 1e6, game_source.t_mat / 1e6])
		HighpolyProfiler.mark("phase",
			"game source: %d MeshSet sections merged to %d surfaces (%.2fx)"
			% [int(game_source.n_sections), int(game_source.n_surfaces),
			   float(game_source.n_sections) / maxf(1.0, float(game_source.n_surfaces))])
		HighpolyProfiler.mark("phase",
			"game source: %d meshes parsed, %d served from another scope (%.0f%%)"
			% [int(game_source.n_meshes), int(game_source.n_mesh_shared),
			   100.0 * game_source.n_mesh_shared
			   / maxf(1.0, float(game_source.n_meshes + game_source.n_mesh_shared))])
		_ph("props: game source, load cached geometry",
			int(game_source.t_geom_load / 1000),
			int(game_source.n_geom_loaded), PH_CACHE)
		_ph("props: game source, save geometry to the cache",
			int(game_source.t_geom_save / 1000),
			int(game_source.n_geom_saved), PH_CACHE)
		HighpolyProfiler.mark("phase",
			"game source geometry cache: %d loaded (%.1f s), %d saved (%.1f s)"
			% [int(game_source.n_geom_loaded), game_source.t_geom_load / 1e6,
			   int(game_source.n_geom_saved), game_source.t_geom_save / 1e6])
		var ts: Dictionary = game_source.tex_stats
		HighpolyProfiler.mark("phase",
			"game source textures: %d decoded, %d reused, %d failed, "
			% [int(ts.get("decoded", 0)), int(ts.get("reused", 0)),
			   int(ts.get("failed", 0))]
			+ "%d materials, %.0f MB of pixels"
			% [int(ts.get("materials", 0)), float(ts.get("bytes", 0)) / 1048576.0])
	# THE TABLE, WRITTEN WHETHER OR NOT ANYONE IS RECORDING. Everything above
	# this line goes to the profiler and is therefore invisible on an ordinary
	# open, which is every open anybody actually complains about.
	Log.info("props: %d instances in %d MultiMeshInstances over %d cells"
		% [_inst_made, _mmi_made, _cells.size()])
	_log_build_phases("%s props, %d of %d built"
		% [_map, _build_props, _build_total], "props")
	build_finished.emit(_build_props)

# Progress: emit the signal (the toggle dock drives a ProgressBar off it) and
# write the host's status label when one was injected; without a label, fall
# back to print() + a tail-able user://mapcontext/build_progress.txt, both at
# a ~BUILD_REPORT_EVERY-mesh cadence so the Output panel isn't flooded.
func _report_progress(final := false) -> void:
	build_progress.emit(_build_done, _build_total)
	# The build's own breadcrumb, so a freeze during the object pass says so
	# rather than being attributed to whatever ran before it. tick_long rate
	# limits itself, so calling it per mesh costs a dictionary lookup.
	if not final:
		HighpolyVitals.crumb("building map objects")
		HighpolyVitals.tick_long("building map objects", _build_done, _build_total)
	else:
		# Hand the breadcrumb back. Left pointing at the build, a freeze that
		# happened later - flying the camera, say - would be reported against a
		# phase that finished minutes earlier, which is worse than no attribution
		# at all because it reads as evidence.
		HighpolyVitals.crumb("idle, nothing building")
	var msg: String
	if final:
		msg = "%s, %d object meshes" % [_build_status_base, _build_props]
	else:
		msg = "%s, objects %d/%dâ€¦" % [_build_status_base, _build_done, _build_total]
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
func _collect_prop_mmis(src: String) -> Array:
	var out: Array = []
	for key in _cells.keys():
		for mmi in _cells[key]:
			if is_instance_valid(mmi) and str(mmi.get_meta("src", "")) == src:
				out.append(mmi)
	return out

# queue_free (never free()) EXACTLY these MultiMeshes and forget them from the
# cell index â€” the renderer may still reference them this frame
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

# Every map with anything cached on disk, for the purge dropdown.
#
# It used to mean "maps you have downloaded". Nothing is downloaded now, so it
# means what the reader has BUILT and kept: the map's own folder plus its
# geometry cache.
static func cached_maps() -> Array:
	var out: Array = []
	var da := DirAccess.open(CACHE)
	if da != null:
		for sub in da.get_directories():
			if str(sub).begins_with("_"):
				continue        # _props, _maptiles: shared, not a map
			out.append(str(sub))
	out.sort()
	return out


# What deleting this map's cache would free.
#
# THE SHARED-MESH ACCOUNTING IS GONE and so is the reason for it. When props
# arrived as GLBs in one shared store, deleting a map meant working out which
# meshes no OTHER downloaded map still referenced, or purging one map silently
# broke another. Every cache is now per-map and per-game-build - the map folder
# and bf6_geom/<level>_<toc signature> - so nothing is shared and nothing can be
# broken by removing one.
#
# The keys the dock reads are kept, with the shared/exclusive ones zeroed,
# because a caller that expects them is not wrong to.
func purge_info(map: String, extra_keys: Dictionary = {},
		keep_keys: Dictionary = {}) -> Dictionary:
	var u: Array = await dir_usage_async("%s/%s" % [CACHE, map])
	var bytes := int(u[1])
	for p in _map_reader_caches(map):
		if p.ends_with("/"):
			var ru: Array = await dir_usage_async(p)
			bytes += int(ru[1])
		else:
			bytes += maxi(0, _file_size(p))
	return {"map_bytes": bytes, "excl": [], "excl_bytes": 0,
			"hp_excl": [], "hp_bytes": 0, "shared": 0}


# Delete this map's cache: its folder, its geometry cache, and the indexes keyed
# to it. Nothing here is downloadable, so all of it is rebuilt from the install
# the next time the map is opened - slower once, then cached again.
func purge_map(map: String, info: Dictionary) -> void:
	for p in _map_reader_caches(map):
		if p.ends_with("/"):
			_rm_dir_recursive(p.rstrip("/"))
		elif FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_rm_dir_recursive("%s/%s" % [CACHE, map])
	_mesh_cache.clear()
	_mesh_stat.clear()
	_prop_by_src.clear()
	_splat_cache.clear()
	if _map == map:
		_data = {}
		_map = ""
	Log.info("Removed the cached data for %s (it rebuilds from your game next time)" % map)


# The reader's own caches that belong to ONE map. Directories end with "/".
func _map_reader_caches(map: String) -> Array:
	var lvl := map.to_lower()
	var out: Array = []
	var da := DirAccess.open("user://bf6_geom")
	if da != null:
		for sub in da.get_directories():
			if str(sub).to_lower().begins_with(lvl + "_"):
				out.append("user://bf6_geom/%s/" % str(sub))
	var root := DirAccess.open("user://")
	if root != null:
		for f in root.get_files():
			var n := str(f)
			# bf6_walk_<level>_v<n>_<sig>.idx, bf6_index_<level>_<sig>.idx,
			# bf6_pidx_<level>_<sig>.idx
			if n.begins_with("bf6_") and n.ends_with(".idx") and n.to_lower().contains(lvl):
				out.append("user://%s" % n)
	return out
const READER_CACHE_DIR := "user://bf6_geom"


static func reader_cache_files() -> Array:
	var out: Array = ["user://bf6_geom"]
	var da := DirAccess.open("user://")
	if da != null:
		for f in da.get_files():
			# bf6_walk_*.idx, bf6_pidx_*.idx, bf6_index_*.idx — the mount, the
			# partition index and the placement walk, each keyed on the TOC
			# signature so a game patch orphans rather than staleness.
			if str(f).begins_with("bf6_") and str(f).ends_with(".idx"):
				out.append("user://%s" % f)
	return out


func purge_everything() -> int:
	var freed := 0
	for p in reader_cache_files():
		if p.ends_with(".idx"):
			freed += _file_size(p)
			DirAccess.remove_absolute(p)
		else:
			var ru: Array = await dir_usage_async(p)
			freed += int(ru[1])
			_rm_dir_recursive(p)
	for d in [CACHE, HighpolyStore.MODELS_DIR, HighpolyStore.THUMBS_DIR]:
		var u: Array = await dir_usage_async(d)
		freed += int(u[1])
		_rm_dir_recursive(d)
	# in-RAM state that would otherwise describe files that no longer exist
	_mesh_cache.clear()
	_mesh_stat.clear()
	_prop_by_src.clear()
	_flip_cache.clear()
	_session_checked.clear()
	_props_verified.clear()
	_props_refresh.clear()
	_splat_cache.clear()
	_data = {}
	_map = ""
	# and the model index, or the panel keeps reporting a library that is gone
	HighpolyStore.models().clear()
	HighpolyStore.save()
	# A transfer or a build in flight when the data went away will never report
	# again, so its bar would sit on screen for the rest of the session and the
	# next download would queue behind a slot nobody holds. jobs.reset() exists
	# for exactly this and was only ever called on panel teardown.
	if job_queue != null and job_queue.has_method("reset"):
		job_queue.reset()
	Log.info("Reset: removed every local cache (%d bytes freed); the next map open reads the install cold" % freed)
	return freed


# UPDATE-BUTTON CLEANUP: sweep stale cache artifacts so "Check for Updates"
# both delivers the new files AND reclaims what this release obsoleted â€”
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
			elif f.ends_with(".baked2.res"):
				kill = true                     # v2 sidecar (lossy foliage swap)
			elif f.ends_with(".tmp.glb"):
				kill = true                     # torn mid-write leftover
			elif f.ends_with(".baked5.res") or f.ends_with(".baked5f.res") \
					or f.ends_with(".baked5l.res"):
				# current generation: keep unless the GLB it was baked from is gone
				var stem := f.trim_suffix(".res")
				stem = stem.substr(0, stem.rfind(".baked5"))
				kill = not FileAccess.file_exists(p.get_base_dir() + "/" + stem)
			elif f.ends_with(".baked3.res") or f.ends_with(".baked4.res"):
				kill = true      # superseded: textures were left uncompressed
			if kill:
				DirAccess.remove_absolute(p)
				removed += 1
	return removed

# recursive delete â€” DirAccess has no rm -r
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
# "color" ([r,g,b] tint override) â€” see HighpolyWater. Terrain above a plane
# occludes it, so each only shows where the ground dips below its own waterline.
# Maps without a water body carry no "water" key and get no planes.
func _add_water_plane(ctx: Node3D, textured: bool) -> void:
	var wdata: Variant = _data.get("water", null)
	var planes: Array = []
	if wdata is Dictionary:
		planes = [wdata]
	elif wdata is Array:
		planes = wdata
	if planes.is_empty():
		return
	# Own group, like Props and Backdrop, so Water can be switched without
	# rebuilding: several maps carry more than one body (rivers plus a harbour),
	# and they all end up named WATER_NODE, which Godot then auto-renames. A
	# parent node is something set_water_shown() can actually find.
	var wroot := Node3D.new()
	wroot.name = "Water"
	ctx.add_child(wroot)
	wroot.owner = null
	ctx = wroot
	for wcfg in planes:
		if not (wcfg is Dictionary): continue
		# THE RIVER/LAKE SURFACE: terrain block 2, meshed per texel by the game
		# source (see terrain_water). Not a plane at one height - the water
		# level descends along the flow - so it arrives as a finished mesh in
		# world space and only needs the water look.
		if wcfg.has("mesh") and wcfg["mesh"] is Mesh:
			var rv := MeshInstance3D.new()
			rv.name = "RiverSurface"
			rv.mesh = wcfg["mesh"] as Mesh
			# THE FULL MINED LOOK IS BACK ON. RESEARCH-WATER2.md acquitted the
			# game-look mapping with numbers: tungsten's mined ocean colour is
			# BRIGHTER than the preset that renders, alpha is untouched by the
			# mapping and floors at 0.45, and dumbo/aftermath bind darker
			# colours through identical code and always rendered. The
			# "invisible" conviction came from a confounded experiment - it
			# predates the stale-answer and stale-node fixes, both of which
			# were the actual fault. The kind rides in wcfg ("river", set by
			# the game source), so the preset seeds river ripple scales before
			# the mined constants land on top.
			var rmat: Material = null
			if textured:
				rmat = HighpolyWater.material(wcfg, game_source)
			if rmat == null:
				var rfb := StandardMaterial3D.new()
				rfb.albedo_color = Color(0.11, 0.34, 0.48, 0.82)
				rfb.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				rfb.metallic = 0.55
				rfb.roughness = 0.08
				rfb.cull_mode = BaseMaterial3D.CULL_DISABLED
				rmat = rfb
			rv.material_override = rmat
			rv.layers = EXT_TERRAIN_LAYER
			ctx.add_child(rv); rv.owner = null
			# SAY SO. Every earlier stage of this hunt logged, and the one that
			# did not - this placement - is exactly where the trail went cold.
			var ab := rv.get_aabb()
			Log.info("[High-Poly] river surface placed: %d surface(s), AABB %s, visible %s, in tree %s"
				% [(rv.mesh as Mesh).get_surface_count(), str(ab), str(rv.visible),
				   str(rv.is_inside_tree())])
			continue
		if not wcfg.has("height"): continue
		var wc: Array = wcfg.get("center", [0.0, 0.0])
		var wsz: Array = wcfg.get("size", [5000.0, 5000.0])
		var wp := MeshInstance3D.new()
		wp.name = WATER_NODE
		var pm := PlaneMesh.new()
		pm.size = Vector2(float(wsz[0]), float(wsz[1]))
		wp.mesh = pm
		# Water follows the Detail Mode like everything else. Textured gets the
		# BF6-style animated shader (depth-tinted transparency, fresnel and
		# ripples, see water.gdshader). The study modes get plain translucent
		# blue: a moving, reflective ocean in a flat-colour or clay view reads as
		# the one thing in the scene that is "finished", which is misleading when
		# the point of those modes is to look at shape.
		# The game source goes in so the water can bind the map's OWN foam and
		# ripple-normal textures out of the install (HighpolyWater._apply_game_look).
		# Passing null is not an error - the mined colours ride in wcfg and apply
		# either way; only the textures need a live mount.
		var wmat: Material = HighpolyWater.material(wcfg, game_source) if textured else null
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
		wp.layers = EXT_TERRAIN_LAYER    # tag: already carries its ground look
		ctx.add_child(wp); wp.owner = null

# ---------- full-accuracy terrain from the raw 16-bit heightmap ----------
# Godot downsamples 16-bit PNGs to 8-bit, so heights ship as a raw uint16 blob
# (row-major, little-endian). Built at `terrain_step` metres/vertex as a grid of
# TERRAIN_CHUNKS x TERRAIN_CHUNKS tiles (so each tile can follow the Range
# slider like the backdrop) and cached to user:// as one PackedScene so the
# (slow) build only happens once per detail level.
const TERRAIN_CHUNKS := 16   # tiles per side (512 m tiles on an 8 km map)

func _build_terrain_from_heightmap(dir: String, meta: Dictionary) -> Node3D:
	var step: int = maxi(1, _step_for(meta))
	# v2 = corrected triangle winding. The cached mesh is the geometry itself, so
	# anyone with a v1 cache would keep their inside-out terrain forever â€” the
	# version goes in the filename and the old file is deleted below.
	var cache := "%s/terrain_ck%d_s%d_v3.res" % [dir, TERRAIN_CHUNKS, step]
	if ResourceLoader.exists(cache):
		var cached: Variant = ResourceLoader.load(cache)
		if cached is PackedScene:
			var inst := (cached as PackedScene).instantiate()
			if inst is Node3D: return inst as Node3D
	var raw := FileAccess.get_file_as_bytes("%s/%s" % [dir, meta.get("file", "height.r16")])
	if raw.is_empty(): return null
	var res: int = int(meta.get("res", 4097))
	# heightmap px per tile, aligned to the vertex step so tile edges share verts
	var cpx := int(ceil(float(res - 1) / float(TERRAIN_CHUNKS)))
	cpx = int(ceil(float(cpx) / float(step))) * step
	var troot := Node3D.new(); troot.name = "Terrain"
	for cz in range(TERRAIN_CHUNKS):
		for cx in range(TERRAIN_CHUNKS):
			# DETAIL THAT FOLLOWS THE CAMERA, which is what the Terrain quality
			# dropdown used to stand in for. That dropdown asked for one detail
			# level for the whole map and then made you live with it: sharp
			# underfoot was unaffordable across 8 km, affordable was visibly
			# stepped underfoot. Neither answer is right, because how much detail
			# the ground needs depends on how far away it is, not on a setting.
			#
			# The same LOD ladder the props already use. Godot picks a level by
			# screen-space error, so the tile under the camera draws every
			# triangle and one on the horizon draws a fraction of them.
			#
			# WHY THIS IS SAFE FOR TERRAIN specifically, which props never had to
			# care about: tiles share edges, and a simplifier that moves a shared
			# edge differently on two neighbours opens a crack you can see the sky
			# through. Measured on a test grid, the smallest level of a 129x129
			# tile is exactly 512 triangles and of a 257x257 tile exactly 1024 -
			# in both cases precisely the tile border edge count. The border is
			# locked and cannot be simplified away, so neighbours keep matching
			# edges at every level and no crack can open.
			#
			# ~23 ms per tile, so about 6 s for a map, paid once into the same
			# PackedScene cache as the tiles (hence v3 in its name). Memory does
			# not move: LODs are extra index buffers over the same vertices.
			var m := _with_lods(_heightmap_mesh(raw, res, step, meta,
				cx * cpx, cz * cpx, cpx))
			if m == null: continue
			var mi := MeshInstance3D.new()
			mi.name = "T%d_%d" % [cx, cz]
			mi.mesh = m
			mark_never_casts(mi)
			troot.add_child(mi)
			mi.owner = troot                  # PackedScene.pack needs the owner chain
	var packed := PackedScene.new()
	if packed.pack(troot) == OK:
		ResourceSaver.save(packed, cache)
	DirAccess.remove_absolute("%s/terrain_s%d.res" % [dir, step])   # legacy single-mesh cache
	# v1 chunk cache: same chunking, inside-out winding â€” reclaim the space
	DirAccess.remove_absolute("%s/terrain_ck%d_s%d.res" % [dir, TERRAIN_CHUNKS, step])
	return troot

func _heightmap_mesh(raw: PackedByteArray, res: int, step: int, meta: Dictionary,
		px0 := 0, pz0 := 0, npx := 0) -> ArrayMesh:
	var wmin: float = float(meta.get("world_min", -2048))
	var wspan: float = float(meta.get("world_max", 2048)) - wmin
	var base: float = float(meta.get("base", 0.0))
	var scale: float = float(meta.get("scale", 1.0)) / 65535.0
	if npx <= 0: npx = res - 1
	var pxe := mini(px0 + npx, res - 1)
	var pze := mini(pz0 + npx, res - 1)
	@warning_ignore("integer_division")
	var nx := (pxe - px0) / step + 1
	@warning_ignore("integer_division")
	var nz := (pze - pz0) / step + 1
	if nx < 2 or nz < 2: return null
	var inv := 1.0 / float(res - 1)
	var verts := PackedVector3Array(); verts.resize(nx * nz)
	var norms := PackedVector3Array(); norms.resize(nx * nz)
	var uvs := PackedVector2Array(); uvs.resize(nx * nz)
	var world_step := float(step) * inv * wspan
	for gz in range(nz):
		var py := pz0 + gz * step
		var rowoff := py * res
		var pym := (maxi(0, py - step)) * res
		var pyp := (mini(res - 1, py + step)) * res
		for gx in range(nx):
			var px := px0 + gx * step
			var wy := base + float(raw.decode_u16((rowoff + px) * 2)) * scale
			var i := gz * nx + gx
			verts[i] = Vector3(wmin + float(px) * inv * wspan, wy, wmin + float(py) * inv * wspan)
			uvs[i] = Vector2(float(px) * inv, float(py) * inv)
			var hxm := float(raw.decode_u16((rowoff + maxi(0, px - step)) * 2)) * scale
			var hxp := float(raw.decode_u16((rowoff + mini(res - 1, px + step)) * 2)) * scale
			var hzm := float(raw.decode_u16((pym + px) * 2)) * scale
			var hzp := float(raw.decode_u16((pyp + px) * 2)) * scale
			norms[i] = Vector3(-(hxp - hxm), 2.0 * world_step, -(hzp - hzm)).normalized()
	# WINDING: these triangles used to be wound the other way round, which made
	# every face point DOWN (confirmed against SurfaceTool.generate_normals,
	# which returns (0,-1,0) for the old order and (0,+1,0) for this one) while
	# the normals supplied above point UP. The ground was therefore drawn
	# back-facing: the SDK terrain material's culling blacked out the top, which
	# was worked around with CULL_DISABLED, and the detail shader built its
	# tangent frame from the normal Godot flips on back faces â€” so the centre
	# chunk lit inside-out next to the SDK's own terrain. Wind it correctly and
	# geometry, normals and lighting finally agree.
	var indices := PackedInt32Array(); indices.resize((nx - 1) * (nz - 1) * 6)
	var k := 0
	for gz in range(nz - 1):
		var ro := gz * nx
		for gx in range(nx - 1):
			var a := ro + gx
			indices[k] = a; indices[k+1] = a + 1; indices[k+2] = a + nx
			indices[k+3] = a + 1; indices[k+4] = a + nx + 1; indices[k+5] = a + nx
			k += 6
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

# --- parallel GLB prefetch ---------------------------------------------------
# Image work is 62% of a cold prop â€” 21.7 ms of 34.8, being 13.0 ms to decode
# the embedded webp and the rest to recompress it to S3TC. No GLTFState flag
# avoids the decode: DISCARD_TEXTURES and EXTRACT_TEXTURES cost the same as
# embedding, because Godot decodes the image first and only then decides what to
# keep. (An earlier note here claimed 95% on the strength of comparing those
# flags, which measures nothing. The honest split needs a file with the image
# bytes physically removed.) Doing that decode on workers is worth real time.
#
# It IS safe on worker threads, but only in halves. Narrowed one stage at a
# time: parse alone fine, + generate_scene fine, + PackedScene.pack fine,
# + compress_scene_textures HANGS THE PROCESS. Creating GPU textures off the
# main thread is the line, so textures are still compressed on the main thread
# when the result is consumed.
#
# THE WORKER HANDS BACK A LIVE NODE, NOT A PackedScene. It used to pack on the
# worker, and the consumer then instantiated it, compressed it, packed it AGAIN
# and handed that back for the caller to instantiate a third time. That round
# trip cost as much as the parse it was meant to save: measured over 60 real
# props, prefetching every one of them hit the cache 60 times and still cost
# 35.0 ms per prop against 34.8 ms with no prefetch at all â€” the whole feature
# bought nothing. Forcing VRAM_FULL so no compression runs gave the same
# non-result (43.1 vs 42.5 ms), ruling compression out and leaving the
# serialise/deserialise round trip as the cost. A parsed scene graph is already
# what the consumer wants; packing it is pure loss.
#
# Nodes must still be FREED on the main thread â€” freeing them on a worker is
# what hung an earlier experiment at exit â€” so unclaimed entries go through
# _pf_release() and never a plain Dictionary.clear().
var _pf: Dictionary = {}             # path -> Node, parsed and ready to use
var _pf_paths: Array = []            # batch input
var _pf_scenes: Array = []           # worker output, adopted into _pf below
# The VRAM mode the cached scenes were COMPRESSED UNDER. Textures are baked on
# the worker now, so a cache filled under Compressed and claimed after a switch
# to Full would hand back the wrong pixels â€” silently, since nothing about a
# BC-compressed texture looks wrong until you compare it. Entries built under a
# different mode are dropped rather than served.
var _pf_mode := -1

# Textures decoded off the main thread, waiting to be bound to the meshes they
# belong to. Filled by workers (BcTex.decode is pure Image work and safe
# there), drained by _load_external_glb. Keyed by GLB path, like _pf.
#
# This is the half of the job that made stripping the images worth doing: the
# skyline cannot prefetch its geometry at all â€” generate_scene segfaults on
# backdrops â€” but it can prefetch its TEXTURES, which is where the time was.
var _bc: Dictionary = {}
var _bc_paths: Array = []
var _bc_out: Array = []


# HOW MUCH OF THE PARSE THE WORKER IS ALLOWED TO DO.
#
#   0  append_from_buffer only          the decode, which is the expensive part
#   1  + generate_scene                 builds nodes, materials and textures
#   2  + tangents
#   3  + compress textures              what shipped, and what hangs
#
# A recorded crash ended on "dispatch 24 file(s) at entry 24/2761" with no
# matching "returned", and the same pattern reproduces locally with a real
# renderer: 600 props, hung solid at entry 216 for ten minutes, where headless
# does the same work in 8.7 s. Headless never reproduces it because its dummy
# renderer creates no GPU resources â€” which is the whole clue.
#
# Bisecting backdrops earlier gave the boundary: append_from_buffer survives,
# + generate_scene segfaults. This makes the boundary a setting so the same
# bisect can be run against the props reproduction rather than guessed at, and
# so a user hitting the crash has something to turn down.
#
# BISECTED AGAINST THE REPRODUCTION, 600 real Dumbo props, real renderer:
#
#   0  exit 0, 600 of 600 built in 31.2 s        clean
#   1  HUNG at entry 144, and left "Pages in use exist at exit in
#      PagedAllocator" behind it                 corrupt
#   3  finished the work in 25.1 s and then hung on teardown
#
# So the moment generate_scene runs on a worker the process is unstable â€”
# sometimes mid-run, sometimes only at exit, which is exactly why this survived
# five clean 24-prop tests and a dozen headless runs. It is the same boundary
# the backdrops gave: append_from_buffer survives, + generate_scene does not.
#
# Stage 0 costs 31.2 s against 25.1 s, about 24%, because append_from_buffer IS
# the expensive part â€” it carries the image decode, and that stays on the
# workers. A quarter slower and stable beats a quarter faster and dead.
#
# Expected to become moot: on a stripped prop generate_scene has no textures to
# create, and creating GPU resources off-thread is what appears to break. Worth
# re-bisecting once the sidecar sets ship.
static var prefetch_stage := 0


var _pf_gid := -1


func _load_external_glb(abs_or_res: String) -> Node:
	# NO PREFETCH BRANCH ANY MORE. This used to check a worker-thread cache
	# first; that pipeline existed to hide the cost of parsing thousands of
	# downloaded prop GLBs, and there are none - scenery comes from the install
	# now. What still reaches here is local and few: the vegetation scatter's
	# kit models, and a roads.glb left in an old cache.
	return _load_external_glb_uncached(abs_or_res)


# Attach the textures a stripped glb does not carry. Prefers a copy a worker
# already decoded; falls back to decoding inline, which is correct but is the
# thing this whole design exists to avoid, so it says so in a recording.
func _bind_side(inst: Node, glb_path: String) -> void:
	if inst == null:
		return
	var d: Variant = _bc.get(glb_path)
	if d is Dictionary:
		_bc.erase(glb_path)
	elif BcTex.exists(glb_path):
		var _t := Time.get_ticks_msec()
		d = _decode_side(glb_path)
		_ph("textures: decoded on the MAIN thread (no prefetch)",
			Time.get_ticks_msec() - _t, 1, PH_CACHE)
	if d is Dictionary and not (d as Dictionary).is_empty():
		var _tb := Time.get_ticks_msec()
		BcTex.bind(inst, d as Dictionary)
		_ph("textures: bind to materials",
			Time.get_ticks_msec() - _tb, (d as Dictionary).size(), PH_ENGINE)


# Free whatever the placement loop never claimed. A cancelled or finished build
# leaves live nodes in _pf, and clear() alone would leak every one of them â€”
# these are Nodes now, not refcounted resources.
# Decode a prop's texture sidecar, if it has one. Safe on a worker: nothing here
# creates a Node, an ImageTexture or anything the renderer owns. Returns {} for
# a prop that ships its textures inside the glb the old way, and every caller
# treats that as "nothing to bind" rather than an error.
func _decode_side(glb_path: String) -> Dictionary:
	if not BcTex.exists(glb_path):
		return {}
	# The block compression — "the expensive half, and the whole reason this runs
	# out here" — happens INSIDE decode() now, per image, before the image enters
	# the shared pool. It has to: a pooled image is handed to many props at once,
	# so it must arrive finished rather than be mutated in place afterwards.
	var d := BcTex.decode(BcTex.path_for(glb_path), vram_mode != VRAM_FULL)
	if d.is_empty():
		return {}
	return d


# The SKYLINE's version of a prefetch. Its geometry cannot be parsed on a worker
# â€” generate_scene segfaults on backdrops, proven twice â€” but its textures can,
# and that is where 63% of a backdrop's parse went. Decodes a batch of sidecars
# across all cores while the main thread is still placing the previous one.


func _load_external_glb_uncached(abs_or_res: String) -> Node:
	# user:// glbs aren't imported; load via runtime GLTF; res:// via normal loader
	if abs_or_res.begins_with("res://"):
		if not ResourceLoader.exists(abs_or_res):
			return null
		var rps := load(abs_or_res) as PackedScene
		return rps.instantiate() if rps != null else null
	HighpolyStore._ensure_webp_ext()   # webp-embedded basecolors (whole prop cache)
	# ONE-SHOT byte snapshot + append_from_buffer, NOT append_from_file: the
	# background re-bake rewrites these cache files continuously, and Godot's
	# Windows FileAccess opens share-all â€” a file-based parse can read a file
	# MID-OVERWRITE (torn chunk lengths â†’ native crash in the glTF parser,
	# 0xc0000005). A single read sees one consistent byte snapshot, and a
	# malformed snapshot FAILS the parse instead of crashing it.
	var bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(abs_or_res))
	# glb sanity: 12-byte header starting with the "glTF" magic â€” every file we
	# load here is a .glb; a short/other prefix = missing or torn mid-write
	if bytes.size() < 12 or bytes.decode_u32(0) != 0x46546C67:
		return null
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	# buffer loads have no filename, and trimesh GLBs carry no scenes[0].name â€”
	# generate_scene would set_name("") on the root ("p_name.is_empty()" error
	# spam, one per GLB). Naming the state names the root instead.
	st.filename = abs_or_res.get_file()
	# embed textures directly instead of routing them through the editor's
	# reimport system (which fails on user:// webp and made the parse
	# return an error â†’ whole mesh dropped). We build the scene regardless of
	# the return code because the geometry is valid even when textures don't
	# fully resolve.
	st.set_handle_binary_image(GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED)
	doc.append_from_buffer(bytes, ProjectSettings.globalize_path(abs_or_res).get_base_dir(), st)
	var scene := doc.generate_scene(st)
	if scene == null: return null
	# raw embedded textures are a memory bomb at scale â€” recompress to S3TC.
	# A stripped prop has none to recompress and this is a cheap walk over
	# nothing, so it costs the new path essentially zero.
	HighpolyStore.compress_scene_textures(scene, true, vram_mode == VRAM_COMPRESSED)
	_bind_side(scene, abs_or_res)
	return scene

func _add_cell_multimeshes(parent: Node3D, mesh: Mesh, xf: Array, textured: bool, flat_mat: Material, src := "") -> void:
	# split placements into world cells (for distance streaming), and within each
	# cell split normal vs mirrored (negative-determinant) instances â€” the game
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
			# COUNTED FOR THE YIELD ANALYSIS. A MultiMeshInstance created in a
			# slice is what the RenderingServer has to flush in the frame that
			# follows it, so this is the x axis of the fit in _yield_report.
			_mmi_add("props", 1)
			_inst_made += int(gxf.size() / 12)
			if not _cells.has(key): _cells[key] = []
			_cells[key].append(mmi)

# Build ONE layer into an overlay that already exists.
#
# Every layer toggle used to fall back to the full apply() when its layer was
# not built yet, and apply() starts with _clear(). So switching Water on â€” one
# plane â€” tore down the terrain, the skyline and all ~2,000 prop meshes and
# rebuilt them. The same was true of Backdrops, Original map objects and the FX
# cards: the fast paths only ever handled show/hide of something already there,
# and "not built yet" is the normal state the first time you press a button.
#
# Returns false when there is no overlay at all, which is the one case where a
# full apply() is genuinely the right answer.
func ensure_layer(root: Node, layer: String, tex_mode: int) -> bool:
	if root == null:
		return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null:
		return false                       # nothing built: caller does a full apply
	var map := map_of(root)
	if map == "" or not _load_data(map):
		return false
	var dir := "%s/%s" % [CACHE, map]
	var textured := tex_mode == 2
	# the study-mode material the props and skyline share (see apply())
	var flat: Material = _clay_mat() if tex_mode == 1 else _sdk_assets_material(root, map)
	if flat is BaseMaterial3D and tex_mode != 1:
		var fd := (flat as BaseMaterial3D).duplicate() as BaseMaterial3D
		fd.cull_mode = BaseMaterial3D.CULL_DISABLED
		flat = fd

	# ONE LAYER IS A BUILD TOO. ensure_layer is what a single toggle takes now
	# (apply() used to tear the whole overlay down for it), so it gets its own
	# phase table rather than appending to whatever the last full apply left
	# behind and reporting a wall time measured from minutes ago.
	#
	# NOT WHILE SOMETHING IS STILL BUILDING. Switching Water on during a props
	# build would otherwise wipe the props lane's yield history halfway through
	# and report the second half as the whole build, which is exactly the kind
	# of quietly wrong number this table exists to replace.
	if not _building and _hidden_builds.is_empty():
		_ph_reset()
	match layer:
		"water":
			# THE NODE EXISTING IS NOT PROOF IT MATCHES THE DATA. A session
			# that built Water before a reader fix kept SHOWING the stale node
			# through every later toggle - the early return here was the last
			# of the doors that held the block-2 river invisible without a
			# restart. Two corrections in one: the data is re-asked with water
			# actually WANTED (_load_data above ran with _show_water still
			# false, since the chip flips it after this call), and the built
			# node is compared against the answer by body count - a mismatch
			# rebuilds instead of shows.
			_show_water = true
			if game_source != null and game_source.level == map.to_lower():
				var wd: Dictionary = game_source.map_data(dir, {
					"lights": want_lights, "fx": want_fx, "water": true})
				if not wd.is_empty():
					_data = wd
			var bodies_v: Variant = (_data as Dictionary).get("water", []) \
				if _data is Dictionary else []
			var nbod := 0
			if bodies_v is Dictionary:
				nbod = 1
			elif bodies_v is Array:
				nbod = (bodies_v as Array).size()
			var wn := ctx.get_node_or_null("Water")
			if wn != null and wn.get_child_count() == nbod and nbod > 0:
				return true                # already there AND current: just flip
			if wn != null:
				# renamed before the free so _add_water_plane's fresh node does
				# not collide with a queue_free'd sibling still holding "Water"
				wn.name = "_WaterStale"
				wn.queue_free()
			var _t_w := Time.get_ticks_msec()
			_add_water_plane(ctx, textured)
			_ph("water: build the surface", Time.get_ticks_msec() - _t_w, 1,
				PH_INSTALL)
			return ctx.get_node_or_null("Water") != null
		"backdrop":
			if ctx.get_node_or_null("Backdrop") != null:
				return true
			var bd_root := Node3D.new()
			bd_root.name = "Backdrop"
			ctx.add_child(bd_root)
			bd_root.owner = null
			var _t_bs := Time.get_ticks_msec()
			var entries: Array = _sorted_prop_entries(_data.get("backdrop", []))
			_ph("skyline: sort the queue nearest first",
				Time.get_ticks_msec() - _t_bs, entries.size(), PH_MEMORY)
			_bd_total = entries.size()
			_bd_done = 0
			_bd_ok = 0
			_show_backdrop = true
			if _bd_total > 0:
				_build_backdrop_async(bd_root, entries, dir, textured, flat,
						_build_gen)
			return true
		"objects":
			if ctx.get_node_or_null("Props") != null:
				return true
			var props_root := Node3D.new()
			props_root.name = "Props"
			ctx.add_child(props_root)
			props_root.owner = null
			_props_dir = dir
			_props_textured = textured
			_props_mat = flat
			_props_tex_mode = tex_mode
			_variant_layer_groups = {}
			var _t_ps := Time.get_ticks_msec()
			var pe: Array = _sorted_prop_entries(_data.get("props", []))
			_ph("props: sort the queue nearest first",
				Time.get_ticks_msec() - _t_ps, pe.size(), PH_MEMORY)
			_build_total = pe.size()
			_build_done = 0
			_build_props = 0
			_last_report = 0
			_building = _build_total > 0
			_show_objects = true
			if _building:
				_build_props_async(props_root, pe, dir, textured, flat, _build_gen)
			else:
				_apply_radius()
			_add_env_decals(props_root)
			return true
	return false


# Re-skin the built overlay in place for a new Detail Mode.
#
# A mode change used to call the full apply(), which starts with _clear() and
# re-parses every prop â€” minutes of work, during which the map objects are
# simply GONE. But the "skin" is only ever two properties per instance
# (material_override for the study modes, the TEXTURED_LAYER bit for the real
# ones), so it can be swapped on the meshes already built.
#
# Returns false when there is nothing built to re-skin, or when the terrain
# material for this map cannot be resolved â€” the caller runs the full apply then.
func reskin(root: Node, tex_mode: int) -> bool:
	if root == null:
		return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null:
		return false
	var map := map_of(root)
	if map == "":
		return false
	var textured := tex_mode == 2

	# props + backdrop: MultiMeshInstance3D, flat material is the SDK asset
	# orange (or clay), matching what apply() hands the builders
	var flat: Material = _clay_mat() if tex_mode == 1 else _sdk_assets_material(root, map)
	if flat is BaseMaterial3D and tex_mode != 1:
		var fd := (flat as BaseMaterial3D).duplicate() as BaseMaterial3D
		fd.cull_mode = BaseMaterial3D.CULL_DISABLED
		flat = fd
	# terrain tiles: MeshInstance3D, flat material is the SDK terrain green
	var tmat: Material = _terrain_shader_mat(map) if textured else null
	var green_base: Material = _sdk_terrain_material(root, map)
	var green_tiled: Material = green_base
	if green_base is BaseMaterial3D:
		var hm: Dictionary = _data.get("heightmap", {})
		var span: float = float(hm.get("world_max", 2048)) - float(hm.get("world_min", -2048))
		var gt := (green_base as BaseMaterial3D).duplicate() as BaseMaterial3D
		gt.cull_mode = BaseMaterial3D.CULL_DISABLED
		gt.uv1_scale = Vector3(span / SDK_GRID_M, span / SDK_GRID_M, 1.0)
		green_tiled = gt

	var n_mm := 0
	var n_ti := 0
	var stack: Array = [ctx]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		for c in nd.get_children():
			stack.append(c)
			if c is MultiMeshInstance3D:
				var mmi := c as MultiMeshInstance3D
				mmi.material_override = null if textured else flat
				mmi.layers = TEXTURED_LAYER if textured else 1
				n_mm += 1
			elif c is MeshInstance3D and c.name != WATER_NODE:
				# terrain tiles; water keeps its own material either way
				var mi := c as MeshInstance3D
				if mi.get_parent() != null and String(mi.get_parent().name) == "Water":
					continue
				mi.material_override = tmat if (textured and tmat != null) else green_tiled
				n_ti += 1
	_ctx_tex_mode = tex_mode
	_props_tex_mode = tex_mode
	Log.debug("map context: re-skinned in place (%d instanced groups, %d terrain tiles)"
		% [n_mm, n_ti])
	return n_mm > 0 or n_ti > 0


func _build_mmi(mesh: Mesh, xf: Array, textured: bool, flat_mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh
	var count := int(xf.size() / 12); mm.instance_count = count
	for i in range(count): mm.set_instance_transform(i, _xform(xf, i * 12))
	var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm
	if not textured:
		mmi.material_override = flat_mat
	else:
		# real game textures on these meshes â€” keep the map-tile decal off them
		# (it exists to colour the SDK's untextured terrain/proxies, not to tint
		# models that are already correct). See HighpolyLib.TEXTURED_LAYER.
		mmi.layers = TEXTURED_LAYER
	# Sized from the mesh's own AABB. Computed BEFORE shadows because shadow
	# casting now depends on it.
	var _sz := mesh.get_aabb().get_longest_axis_size()
	mmi.set_meta("lod_sz", _sz)     # so the Range slider can re-derive these live
	# props/backdrop CAST shadows (the flat no-shadow overlay was an old
	# study-mode perf choice â€” with game lighting it read as "shadows don't
	# render"). Follows the dock's Shadows sub-checkbox so meshes built while
	# it's unchecked stay light. Grass scatter is always shadow-off (GPU cost).
	#
	# SIZE-AWARE, because shadows were the largest single cost measured. A
	# casting surface is redrawn once per directional cascade, so its real price
	# is five draw calls rather than one. On a Dumbo flyover: 4,264 visible
	# nodes carrying 22,482 surfaces, which at five passes is ~112,000 calls and
	# accounted for essentially the whole 156,864 the engine reported at 4 fps.
	#
	# Big structures still cast, because that is where a shadow reads and where
	# its absence would be noticed. The thousands of small props stop paying four
	# extra passes each to cast a shadow the size of a bin lid. Same 12 m
	# boundary the HLOD tiers and the placed-object cull already use, so there is
	# one notion of "big enough to matter" rather than three.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
		if (HighpolyLighting.cast_shadows and _sz >= SHADOW_MIN_EXTENT) \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# VISIBILITY RANGES (Godot's per-instance HLOD): small props stop being
	# drawn long before the Range slider would cull their cell â€” the single
	# biggest draw-call saver when flying (a trash can 1.5 km out was a full
	# draw call). Fades instead of popping.
	_set_mmi_lod(mmi, _sz)
	return mmi

# Per-mesh draw distance for one instanced group, derived from the Range slider.
#
# These used to be the constants 400 m and 1200 m, fixed at build time and never
# touched again. The slider moved the CELL cull and left them alone, so its
# tooltip promise ("the one distance that governs everything") was only true of
# half the system: at a 400 m range, small props still drew to 400 m, and pulling
# the slider down did not make the clutter any cheaper.
#
# Clutter to a FIFTH of the range, mid-size props to two fifths, big structures
# uncapped because the cell cull already bounds them and popping a building is
# far more noticeable than popping a bin.
#
# These were 0.5 / 1.0. Measured on Dumbo, 89% of visible prop surfaces come from
# props under 12 m â€” 54% from clutter under 3 m alone â€” so this band is where the
# draw calls actually are, and distance is the only thing that removes them
# without removing the object. Counting what survives each threshold put the
# saving at about a third of the prop surfaces in view.
#
# NOTE: highpoly_placedcull.gd keeps its own 0.5 / 1.0 copy of this rule, so map
# context and YOUR placed objects no longer cull alike. That is deliberate: your
# objects are a handful of nodes and a few draw calls, and having the props you
# are actively working on vanish early is a worse trade than the frames it would
# buy. An older comment here claimed the two were kept in step â€” they are not.
func _set_mmi_lod(mmi: MultiMeshInstance3D, sz: float) -> void:
	var r: float = radius
	if r >= 1.0e8:
		# "No Culling" end of the slider: honour it literally, no per-mesh limit
		mmi.visibility_range_end = 0.0
		mmi.visibility_range_end_margin = 0.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		return
	if sz < 3.0:
		# small props: HARD cull with a hysteresis buffer. Dither-fade (FADE_SELF)
		# stipples badly on small objects and reads as flicker while flying â€” a
		# clean on/off with a margin is smoother for clutter this size.
		mmi.visibility_range_end = maxf(r * 0.2, 40.0)
		mmi.visibility_range_end_margin = 40.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	elif sz < 12.0:
		mmi.visibility_range_end = maxf(r * 0.4, 60.0)
		mmi.visibility_range_end_margin = 60.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	else:
		mmi.visibility_range_end = 0.0
		mmi.visibility_range_end_margin = 0.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

# Re-derive every built group's draw distance after the Range slider moves.
# Cheap: a property write per instanced group (hundreds), not per instance.
func _refresh_mesh_lod() -> void:
	var n := 0
	for key in _cells.keys():
		for c in _cells[key]:
			if not is_instance_valid(c): continue
			if c is MultiMeshInstance3D and c.has_meta("lod_sz"):
				_set_mmi_lod(c as MultiMeshInstance3D, float(c.get_meta("lod_sz")))
				n += 1
	if n > 0:
		Log.debug("map context: re-derived draw distance on %d group(s) at %d m"
			% [n, int(radius)])

# Fast path for the "Original map objects" toggle: SHOW/HIDE the already-built
# props subtree instead of tearing the whole overlay down and re-parsing ~2k
# GLBs (7+ GB â€” the "feels like it's redownloading" wait was that rebuild).
# Returns false when there is no live props layer for this detail mode â€” the
# caller must run the full apply() then.
func set_objects_shown(root: Node, on: bool, tex_mode := -1) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return false
	var props := ctx.get_node_or_null("Props")
	if props == null: return false
	if tex_mode >= 0 and tex_mode != _props_tex_mode:
		return false                   # detail mode changed â†’ needs a rebuild
	_show_objects = on
	(props as Node3D).visible = on
	if on:
		_apply_radius()                # re-cull for wherever the camera is now
	return true


# ---------------------------------------------------------------------------
# ENVIRONMENT DECAL VOLUMES (task #52): the game's soot, graffiti, floor
# markings and gobo light splashes, as Godot Decal nodes under the Props layer.
#
# They ride "Original map objects" rather than their own chip: a graffiti
# piece belongs to the wall it is sprayed on and a light splash to the lamp
# that casts it, so decals without their props would float in the air and
# props without their decals are merely less detailed. Hiding Props hides
# these with it, and the salvage path re-parents them with the subtree.
#
# The volume's box extents ride its transform's basis as scale (measured
# 0.7..11.8 m axis lengths on capstone), so the Decal node takes the walk
# matrix verbatim - the same conversion every prop uses - and a unit `size`.
# EDV_SIZE and EDV_PROJ_AXIS carry the two authored-convention answers; both
# were measured against known volumes (see test_edv.gd) rather than assumed.
# ---------------------------------------------------------------------------
const EDV_MAX_DECALS := 2048        # runaway guard, logged when it trips
# The projection depth floor, metres. A wall graffiti volume is authored
# 0.01 m thin - it sits ON the wall plane - and a Decal box that shallow
# reaches nothing once the wall mesh is a centimetre away. Projecting
# +-0.3 m through the authored plane hits the surface without bleeding
# through to the far side of ordinary walls.
const EDV_MIN_DEPTH := 0.6

# The shader-computed smudge families have no colour sheet - the game mixes a
# constant with 3D perlin noise. A flat family colour under the noise sheet's
# coverage is the honest preview of that: right hue, right footprint, less
# procedural detail. Keyed on the template name.
static func _edv_smudge_color(tpl: String) -> Color:
	if tpl.contains("soot"):
		return Color(0.05, 0.05, 0.05)
	if tpl.contains("plaster"):
		return Color(0.82, 0.79, 0.72)
	return Color(0.35, 0.30, 0.25)      # dust / ash / generic dirt


# noise sheet guid + family colour -> a small RGBA sheet whose alpha is the
# noise, cached so 22 soot volumes build one image.
var _edv_smudge_cache := {}

func _edv_smudge_sheet(guid: String, col: Color):
	var key := "%s|%s" % [guid, col.to_html(false)]
	if _edv_smudge_cache.has(key):
		return _edv_smudge_cache[key]
	var out = null
	var tex = game_source.decal_sheet(guid)
	var img: Image = (tex as Texture2D).get_image() if tex is Texture2D else null
	if img != null:
		var c := img.duplicate() as Image
		if not c.is_compressed() or c.decompress() == OK:
			c.convert(Image.FORMAT_RGBA8)
			var w := c.get_width()
			var h := c.get_height()
			for y in range(h):
				for x in range(w):
					var n := c.get_pixel(x, y).r
					# Soft threshold: the middle of the noise range fades in,
					# so the smudge has a noisy edge rather than a square one.
					var a := clampf((n - 0.30) / 0.45, 0.0, 1.0)
					c.set_pixel(x, y, Color(col.r, col.g, col.b, a * a))
			c.generate_mipmaps()
			out = ImageTexture.create_from_image(c)
	_edv_smudge_cache[key] = out
	return out


func _add_env_decals(parent: Node3D) -> void:
	var recs: Variant = _data.get("edv", null) if _data is Dictionary else null
	if recs == null and game_source != null:
		# Built before this section existed, or objects were off when the map
		# data was mined. One ask fills just this section.
		if ensure_section("edv"):
			recs = _data.get("edv", null)
	if not (recs is Array) or (recs as Array).is_empty():
		return
	if game_source == null:
		# The packaged-placements path has no live reader to fetch sheets
		# through; decals are an install-sourced feature.
		return
	var holder := Node3D.new()
	holder.name = "EnvDecals"
	parent.add_child(holder)
	holder.owner = null
	var sheets := {}                  # ca guid -> Texture2D or null
	var built := 0
	var no_sheet := 0
	for r in recs:
		if not (r is Dictionary):
			continue
		if built >= EDV_MAX_DECALS:
			Log.info("map context: decal volumes capped at %d (map has %d)"
				% [EDV_MAX_DECALS, (recs as Array).size()])
			break
		var rec: Dictionary = r
		var ca := str(rec.get("ca", ""))
		if ca == "":
			no_sheet += 1
			continue
		var kind := str(rec.get("kind", "albedo"))
		var tpl := str(rec.get("tpl", ""))
		var tex
		if kind == "smudge":
			tex = _edv_smudge_sheet(ca, _edv_smudge_color(tpl))
		else:
			tex = sheets.get(ca, false)
			if tex is bool:
				tex = game_source.decal_sheet(ca)
				sheets[ca] = tex
		if tex == null:
			no_sheet += 1
			continue
		var b: Array = rec.get("xf", [])
		if b.size() < 4:
			continue
		# The basis rows carry the box's FULL extents as scale (measured: the
		# schoolhouse graffiti reads 1.2-4.5 m wide, exactly mural-sized; the
		# half-extent reading would double a 4.5 m piece past its wall). The
		# rotation and the size are split apart so the paper-thin projection
		# axis can take the depth floor without skewing the rotation.
		var rt: Vector3 = b[0]
		var up: Vector3 = b[1]
		var fw: Vector3 = b[2]
		var lr := rt.length()
		var lu := up.length()
		var lf := fw.length()
		if lr < 1e-4 or lf < 1e-4:
			continue
		var nu := (up / lu) if lu > 1e-3 else (fw / lf).cross(rt / lr).normalized()
		var d := Decal.new()
		d.transform = Transform3D(Basis(rt / lr, nu, fw / lf), b[3] as Vector3)
		d.size = Vector3(lr, maxf(lu, EDV_MIN_DEPTH), lf)
		# A gobo sheet IS the light pattern the fixture paints on the floor.
		# As albedo it would print a DARK lamp-shaped patch; as emission it
		# glows, which is what the game draws.
		if kind == "emit":
			d.texture_emission = tex
			d.emission_energy = 1.0
		else:
			d.texture_albedo = tex
			d.albedo_mix = 1.0
		var a := clampf(float(rec.get("alpha", 1.0)), 0.0, 1.0)
		if a < 1.0:
			d.modulate = Color(1, 1, 1, a)
		# The authored culling distance, as a fade: the game stops drawing the
		# volume past it, and matching that keeps 1,204 markings on Subsurface
		# from all being live at once.
		var cull := float(rec.get("cull", 0.0))
		if cull > 1.0:
			d.distance_fade_enabled = true
			d.distance_fade_begin = cull * 0.8
			d.distance_fade_length = cull * 0.2
		holder.add_child(d)
		d.owner = null
		built += 1
	Log.info("map context: %d decal volumes placed (%d sheets, %d without a readable sheet)"
		% [built, sheets.size(), no_sheet])


# Fast path for the Backdrops toggle, same contract as set_objects_shown():
# flip the already-built skyline layer instead of rebuilding the overlay.
# Returns false when there is no Backdrop layer yet (or the detail mode moved),
# and the caller runs the full apply() instead.
func set_backdrop_shown(root: Node, on: bool, tex_mode := -1) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return false
	var bd := ctx.get_node_or_null("Backdrop")
	if bd == null: return false
	if tex_mode >= 0 and _ctx_tex_mode >= 0 and tex_mode != _ctx_tex_mode:
		return false                   # detail mode changed â†’ needs a rebuild
	_show_backdrop = on
	(bd as Node3D).visible = on
	return true


# Roads and street markings, on their own switch.
#
# These are baked from the level's TerrainDecals and draped on the heightfield,
# and they used to follow Extended Terrain on the reasoning written a few
# hundred lines up: "without them the map is bare dirt where the street network
# should be". True, and not the whole story - they are also the thing you want
# OFF while laying out your own paths and arrays over the ground, and there was
# no way to do that short of losing the terrain along with them.
#
# Pure visibility, like the objects and backdrop chips: the mesh is already
# built, so this never triggers a rebuild. False means there is no Roads node -
# either the terrain has not been built yet or this map has no street network -
# and the caller says which rather than treating it as a failure.
func set_roads_shown(root: Node, on: bool) -> bool:
	_show_roads = on
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return false
	var rd := ctx.get_node_or_null("Roads")
	if rd == null: return false
	(rd as Node3D).visible = on
	return true


func has_roads(root: Node) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	return ctx != null and ctx.get_node_or_null("Roads") != null


# Is the ground itself built? Asked so "no roads" can be told apart from "no
# terrain yet" - the two look identical from the Roads chip and need different
# things from the user.
func has_terrain(root: Node) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	return ctx != null and ctx.get_node_or_null("Terrain") != null


# Fast path for the "Show whole map" toggle: hide/show the already-built
# terrain/backdrop/water/scatter layers instead of tearing the WHOLE overlay
# down â€” the full apply() also regenerated every map object ("why do all the
# original map objects regenerate when toggling Show Whole Map").
# Returns false when the context layers were never built for this detail
# mode â€” the caller runs the full apply() then.
func set_context_shown(root: Node, on: bool, tex_mode := -1) -> bool:
	if root == null: return false
	var ctx := root.get_node_or_null(NODE)
	if ctx == null: return false
	if tex_mode >= 0 and _ctx_tex_mode >= 0 and tex_mode != _ctx_tex_mode:
		return false                   # detail mode changed â†’ needs a rebuild
	# "IS THE TERRAIN THERE", NOT "IS ANYTHING THERE".
	#
	# This set `found` from ANY layer it touched, and the map context node holds
	# Water, Roads, Scatter and more besides Terrain. So after an apply that built
	# water and no terrain - terrain=false objects=false backdrop=false water=true,
	# which the user's log shows happening - switching Extended Terrain on found
	# the WATER node, reported success, and returned true. The caller takes true
	# as "done" and never runs the full apply, so the terrain is never built. It
	# has already hidden the SDK's own terrain slab by then, so the result is no
	# ground at all and the switch appears to do nothing.
	#
	# That is also why it was intermittent, which is what made it hard to catch.
	# With nothing built, `found` is false and the full apply runs. With terrain
	# built, showing it really is all that is needed. Only the in-between state -
	# some other layer built, terrain not - fails, and only in that state.
	var found := false
	for c in ctx.get_children():
		# "Backdrop" is its own toggle now and must not ride this one - hiding the
		# terrain should not take the horizon with it.
		if c.name == "Props" or c.name == "Backdrop" or not (c is Node3D):
			continue
		if c.name == "Terrain":
			found = true
		(c as Node3D).visible = on
	if on and not found:
		return false                   # terrain never built -> full apply
	_active = on
	return true

# ---------- distance streaming (called by the dock on a timer) ----------
func set_radius(r: float) -> void:
	radius = r
	# per-mesh draw distance first, then the cell pass: the cell pass can show
	# cells, and a freshly shown group should already carry the new distance
	# rather than drawing at the old one for a frame
	_refresh_mesh_lod()
	_apply_radius()
	# The clutter follows the same slider WHILE ITS CHIP IS ON. It was in
	# neither _cells nor _bd_list, so the one distance control the panel
	# advertises as governing "everything" governed everything except the
	# grass — and after v1.19.0 deleted the Grass slider, nothing at all
	# reached it. Scaled to a third of the scenery radius (clutter at full
	# scenery distance is sub-pixel and pure instance cost), floored so a low
	# slider thins rather than kills it; the chip off or the slider at zero
	# both mean off.
	if _scatter != null and _scatter.active:
		var cam := _editor_cam()
		if cam != null:
			_scatter.set_range(_grass_range_for(r) if want_grass else 0.0,
				cam.global_transform.origin)


func _grass_range_for(r: float) -> float:
	return 0.0 if r <= 0.0 else clampf(r / 3.0, 60.0, 300.0)


# The Grass chip's handler. Applies immediately when the clutter kits are
# already set up; before that it only records the wish, and the setup path
# reads want_grass when the ground finishes building.
func set_grass(on: bool) -> void:
	want_grass = on
	if _scatter == null or not _scatter.active:
		return
	var cam := _editor_cam()
	if cam == null:
		return
	_scatter.set_range(_grass_range_for(radius) if on else 0.0,
		cam.global_transform.origin)

func _apply_radius(budget: int = 1 << 30) -> void:
	# backdrop-only is valid (Show Whole Map without objects) â€” don't early-out
	# on empty cells or the skyline loop below never runs
	if _cells.is_empty() and _bd_list.is_empty(): return
	var cam := _editor_cam()
	var cx := 0.0; var cz := 0.0
	if cam:
		var p := cam.global_transform.origin; cx = p.x; cz = p.z
	# Flip only the cells whose state actually CHANGES, nearest first, capped at
	# `budget` cells per pass (the dock tick passes a small one; slider changes
	# and rebuilds pass unlimited). Showing a cell re-registers every instance
	# with the renderer and dirties SDFGI + the shadow atlas â€” flipping a whole
	# ring of cells in one frame was the fly-forward hitch. The old loop also
	# re-issued cast_shadow on EVERY cell EVERY tick (same value or not), which
	# dirties the render server even standing still.
	var half_diag := _cell_size * 0.7071
	var changes: Array = []
	for key in _cells.keys():
		var lst: Array = _cells[key]
		if lst.is_empty() or not is_instance_valid(lst[0]): continue
		# A BAKED CELL IS NOT THIS PASS'S BUSINESS. Its MultiMeshes are hidden
		# on purpose and a single merged mesh is drawing in their place, so
		# deciding their visibility from distance would switch all of them back
		# on. That is exactly what happened the first time: 3 cells baked, 9,530
		# nodes hidden, and the measured draw count moved 25,900 -> 25,907,
		# because this loop undid the hiding within half a second.
		if hlod_cells.has(key): continue
		var parts: PackedStringArray = String(key).split(",")
		# Euclidean distance to the cell CENTRE, margin = half the cell
		# diagonal. The old test used the cell's min corner with a square
		# metric and a whole-cell margin â€” at a 100 m slider it kept content
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
		# pass (the pass re-renders every caster per split â€” with GI + map
		# lights on, whole-map casting was THE lag). 350 m covers everything
		# a shadow is visible on at street scale.
		var casts: bool = near and dist <= 350.0 + half_diag \
			and HighpolyLighting.cast_shadows
		# Read the cell's INTENDED shadow state, not lst[0]'s actual one. The
		# two are no longer the same thing: _build_mmi() only lets a mesh cast
		# if it is at least SHADOW_MIN_EXTENT across, so a cell whose first
		# member is a small prop reports "not casting" however near it is.
		# Comparing against the actual flag made this loop re-queue every such
		# cell EVERY tick and â€” worse â€” the apply below then forced the size
		# gate back ON, which is why a measured flyover still showed ~4.9
		# shadow passes per surface after the gate went in.
		var casts_now: bool = bool((lst[0] as Node).get_meta("cell_casts", false))
		if near != vis_now or casts != casts_now:
			changes.append([0 if near else 1, dist, key, near, casts])
	changes.sort()   # lexicographic: shows before hides, nearest first
	for ch in changes:
		if budget <= 0: break
		budget -= 1
		for mmi in _cells[ch[2]]:
			if is_instance_valid(mmi):
				mmi.visible = ch[3]
				# The cell decides WHETHER shadows are in play here; the mesh's
				# own size decides whether IT is worth one. Both must agree, so
				# distance can turn a caster off but can never promote a small
				# prop into one.
				mmi.set_meta("cell_casts", ch[4])
				var big: bool = float(mmi.get_meta("lod_sz", 1e9)) >= SHADOW_MIN_EXTENT \
					and not mmi.has_meta("no_shadow")
				(mmi as GeometryInstance3D).cast_shadow = \
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON if (ch[4] and big) \
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
# detail-terrain shader uses); {} when the map has no tile â€” scatter still works
func _scatter_tile(map: String) -> Dictionary:
	var d := _tile_params(map)
	if d.is_empty(): return {}
	var img := _maptile_path(map)
	if img == "": return {}
	var pos: Vector3 = d["pos"]; var sz: Vector3 = d["size"]
	return {"img": img, "bounds": Vector4(pos.x - sz.x * 0.5, pos.z - sz.z * 0.5, sz.x, sz.z)}

func tick() -> void:
	# called by the dock timer while objects are shown (streamed by distance).
	# Gate on _show_objects ALONE: objects can be shown without "Show whole
	# map" (_active), and the old `_active and` gate froze their culling â€”
	# the radius only applied once at slider-change instead of following the
	# camera.
	# Backdrops no longer ride on _active: the skyline is its own layer and can be
	# shown with Extended Terrain off, so gating it on _active froze its culling
	# in exactly the case the new toggle makes possible.
	if _show_objects or not _bd_list.is_empty():
		# Budget scaled to how far the camera actually moved. A fixed 4 cells per
		# half-second tick is fine standing still, but it cannot keep up with
		# flying: the culling fell behind the camera and only caught up when the
		# Range slider was touched, because that path passes an unlimited budget.
		# That is the "I have to adjust the slider to load props around me" bug.
		# Standing still stays cheap; moving fast is allowed a bigger slice, still
		# capped so a whole ring never flips in one frame.
		var budget := 4
		var cam := _editor_cam()
		if cam:
			var p := cam.global_transform.origin
			var moved := p.distance_to(_last_cull_pos)
			_last_cull_pos = p
			if moved > _cell_size * 0.5:
				budget = clampi(int(moved / maxf(_cell_size, 1.0)) * 8, 8, 64)
		_apply_radius(budget)
	# vegetation scatter follows the camera (regenerates on 32 m cell crossings);
	# frozen while the context layers are hidden (set_context_shown fast path)
	if _active and _scatter != null and _scatter.active:
		var cam := _editor_cam()
		if cam: _scatter.tick(cam.global_transform.origin)
