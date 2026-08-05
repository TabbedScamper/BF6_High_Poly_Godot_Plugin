@tool
extends Node
class_name HighpolyProfiler
# Record what the viewport is actually costing, and WHO owns it.
#
# Every performance decision in this plugin so far has been reasoned from
# triangle counts, which is guesswork: a scene can be triangle-light and draw-call
# heavy, or cheap to draw and expensive to shadow. This samples the real counters
# while you fly, and attributes the load to the subsystem responsible, so the
# answer to "what is eating my frames" is measured rather than argued.
#
# Two rates, deliberately:
#   * counters every 250 ms  - cheap, just Performance.get_monitor reads
#   * attribution every 2 s  - walks the scene, so it is NOT free and must not
#                              run per frame or it becomes the thing it measures
#
# Writes a CSV next to the log. The summary at the end ranks the worst samples
# and says what was on screen at the time, which is the part you actually read.

const Log = preload("highpoly_log.gd")

# Subsystem roots, in the order we attribute them. A node is charged to the FIRST
# owner it sits under, so nothing is double counted.
# _SCATTER is listed BEFORE _MAP_CONTEXT deliberately: it lives inside the map
# context but is built and culled separately, and folding grass into the scenery
# total hides which of the two is actually costing anything.
const OWNERS := {
	"_SCATTER": "grass scatter",
	"_MAP_CONTEXT": "map context (scenery)",
	"_MAP_FX": "effects",
	"_MAP_LIGHTS": "map lights",
	"_GAME_LIGHTING": "game lighting",
	"_WATER_CHUNKS": "water",
	"_COLLISION_VIS": "collision overlay",
	"_GAMEMODE": "gamemode markers",
	"_HIPOLY_PREVIEW": "high-poly overlays",
}

# What a draw call actually costs, per visible node:
#
#   surfaces x (1 + shadow passes)
#
# NOT instances. A MultiMesh draws all its instances in one call PER SURFACE, so
# a 4,000-instance node with one surface is one call while a 2-instance node with
# five surfaces is five. The first version of this tool counted instances and
# reported 44,931 against the engine's 157,000 objects, which was unreconcilable
# and sent me looking at the wrong lever. Surfaces are the lever.
const SHADOW_PASSES := 4      # directional cascades; only counted for casters

# Children of _MAP_CONTEXT that get their own row rather than being pooled.
const MAPCTX_PARTS := {"Terrain": true, "Backdrop": true, "Props": true,
	"Roads": true, "Water": true}

var recording := false
var _samples: Array = []          # [{t, fps, ms, draws, prims, objs, vram, campos}]
var _attrib: Array = []           # [{t, fps, rows:{owner: {vis, inst, tris}}}]
var _t0 := 0.0
var _tick: Timer
var _scan: Timer
var _status := ""
var _warned_no_scene := false

# ---------------------------------------------------------------------------
# WHAT THE PLUGIN WAS DOING, not just what the frame cost.
#
# The recording this is built for is: purge everything, press record, wait for
# the whole thing to load, press stop. That question ("where did the time go
# bringing a map up from nothing") cannot be answered by frame counters alone —
# a 4 fps sample means nothing without knowing whether it was downloading,
# unzipping, building meshes or just drawing.
#
# So each tick also captures the DOWNLOAD counters and the MENU STATE, and any
# change in that state becomes a timestamped event. The report is then a
# timeline rather than a pile of samples.
# ---------------------------------------------------------------------------
var sync: Node                    # highpoly_sync.gd, for stats(); set by the dock
var state_provider: Callable      # returns the dock's toggle state as a Dictionary

var _events: Array = []           # [{t, kind, text}]
var _last_state := {}
var _last_dl := {}
var _dl_series: Array = []        # [{t, mbps, files_s, queued, active}]
var _peak := {"draws": 0, "objs": 0, "vram": 0.0, "nodes": 0}

# A frame this much worse than the recent median counts as a hitch worth naming.
const HITCH_FACTOR := 3.0
const HITCH_FLOOR_MS := 50.0      # below this, a spike is not worth reporting


# Anything can drop a marker in without depending on this class: the dock calls
# it, but a missing profiler is a no-op rather than an error.
func event(kind: String, text: String) -> void:
	if not recording:
		return
	_events.append({
		"t": Time.get_ticks_msec() / 1000.0 - _t0,
		"kind": kind, "text": text,
	})


# ---------------------------------------------------------------------------
# STATIC ENTRY POINTS, so the code being measured does not have to hold a
# reference to the recorder or know whether one exists. Both are no-ops when
# nothing is recording, which is the normal case, so instrumentation left in
# permanently costs a boolean check.
#
# The distinction that matters:
#   mark()  a moment      -> "the props archive finished extracting"
#   span()  a DURATION    -> "merging meshes cost 4.2 s", accumulated by name
#
# Only span() can answer where seventeen minutes went. A timeline of moments
# tells you the order of events; it cannot tell you which one ate the clock,
# because the gap between two markers also contains everything else.
# ---------------------------------------------------------------------------
static var _active: HighpolyProfiler = null
static var _spans: Dictionary = {}          # name -> {ms, n}

# MAIN THREAD ONLY. Both of these mutate shared Arrays/Dictionaries, and the
# build is moving onto worker threads — a span() from four threads at once is a
# data race on `_spans`, which in GDScript means a corrupted dictionary or a
# hard crash rather than a wrong number. Timing is not worth either, so work
# done off-thread is simply not attributed and the report says so by omission.
static func _on_main() -> bool:
	return OS.get_thread_caller_id() == OS.get_main_thread_id()


static func mark(kind: String, text: String) -> void:
	if _active != null and _active.recording and _on_main():
		_active.event(kind, text)

# Call with the elapsed milliseconds of a chunk of work. Costs are SUMMED per
# name across the run, and the count comes with it: 2761 calls of 8 ms is a very
# different problem from one call of 22 s, and both add up to the same total.
static func span(name: String, ms: float) -> void:
	if _active == null or not _active.recording or not _on_main():
		return
	var e: Dictionary = _spans.get(name, {"ms": 0.0, "n": 0})
	e["ms"] = float(e["ms"]) + ms
	e["n"] = int(e["n"]) + 1
	_spans[name] = e


func _ready() -> void:
	_active = self
	_tick = Timer.new(); _tick.wait_time = 0.25; _tick.timeout.connect(_sample)
	add_child(_tick)
	_scan = Timer.new(); _scan.wait_time = 2.0; _scan.timeout.connect(_attribute)
	add_child(_scan)


func start() -> String:
	_samples.clear(); _attrib.clear(); _events.clear(); _dl_series.clear()
	_last_state = {}
	_last_dl = {}
	_peak = {"draws": 0, "objs": 0, "vram": 0.0, "nodes": 0}
	# instance ids are recycled, so a stale entry could charge a new mesh the
	# triangle count of a freed one
	_tri_cache.clear()
	_spans.clear()
	_t0 = Time.get_ticks_msec() / 1000.0
	recording = true
	_tick.start(); _scan.start()
	event("start", "recording began")
	_note_state(true)
	Log.info("performance recording started - do the thing you want measured "
		+ "(loading a map from cold is a good one), then press Stop")
	return "Recording. Load/fly whatever you want measured, then press Stop."


func stop() -> String:
	if not recording:
		return "Not recording"
	recording = false
	_tick.stop(); _scan.stop()
	var txt := _summarise()
	var path := _write_csv()
	Log.info(txt)
	return "Recorded %d samples. %s" % [_samples.size(), path]


# ---------- cheap sampler ----------
func _sample() -> void:
	var cam := _cam()
	var t := Time.get_ticks_msec() / 1000.0 - _t0
	var ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var dl := _download_snapshot(t)
	var s := {
		"t": t,
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"ms": ms,
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objs": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"vram": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"mem": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"pos": cam.origin if cam != null else Vector3.ZERO,
	}
	s.merge(dl)
	_samples.append(s)

	_peak["draws"] = maxi(int(_peak["draws"]), int(s["draws"]))
	_peak["objs"] = maxi(int(_peak["objs"]), int(s["objs"]))
	_peak["nodes"] = maxi(int(_peak["nodes"]), int(s["nodes"]))
	_peak["vram"] = maxf(float(_peak["vram"]), float(s["vram"]))

	_note_state(false)
	_note_hitch(t, ms)


# Downloads, differentiated. Absolute counters cannot answer "was it fast" — the
# rate between two samples can, and it is what lines a slow patch of the
# recording up against whatever was happening at that moment.
func _download_snapshot(t: float) -> Dictionary:
	var out := {"mbps": 0.0, "files_s": 0.0, "queued": 0, "active": 0,
		"dl_done": 0, "dl_failed": 0, "dl_mb": 0.0}
	if sync == null or not sync.has_method("stats"):
		return out
	var st: Dictionary = sync.call("stats")
	out["queued"] = int(st.get("queued", 0))
	out["active"] = int(st.get("active", 0))
	out["dl_done"] = int(st.get("done", 0))
	out["dl_failed"] = int(st.get("failed", 0))
	out["dl_mb"] = float(st.get("bytes", 0)) / 1048576.0
	if not _last_dl.is_empty():
		var dt: float = t - float(_last_dl.get("t", t))
		if dt > 0.001:
			out["mbps"] = (float(out["dl_mb"]) - float(_last_dl.get("mb", 0.0))) / dt
			out["files_s"] = (int(out["dl_done"]) - int(_last_dl.get("done", 0))) / dt
	_last_dl = {"t": t, "mb": out["dl_mb"], "done": out["dl_done"]}
	if float(out["mbps"]) > 0.0 or int(out["active"]) > 0:
		_dl_series.append({"t": t, "mbps": out["mbps"], "files_s": out["files_s"],
			"queued": out["queued"], "active": out["active"]})
	return out


# Menu state, as a timeline. What is on when you press record is half the
# context; the other half is the moment something got switched on, because that
# is usually where the frame rate falls off a cliff.
func _note_state(force: bool) -> void:
	if not state_provider.is_valid():
		return
	var st: Dictionary = state_provider.call()
	if not (st is Dictionary):
		return
	if force:
		_last_state = st.duplicate()
		event("state", _describe(st))
		return
	for k in st:
		if str(st[k]) != str(_last_state.get(k, "<unset>")):
			event("state", "%s: %s -> %s" % [k, _last_state.get(k, "?"), st[k]])
	_last_state = st.duplicate()


func _describe(st: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in st:
		parts.append("%s=%s" % [k, st[k]])
	return " ".join(parts)


# A spike is only meaningful against the recent normal, so compare with the
# median of the last few seconds rather than a fixed threshold: 80 ms is a
# disaster at 120 fps and unremarkable while a map is loading.
func _note_hitch(t: float, ms: float) -> void:
	if _samples.size() < 12 or ms < HITCH_FLOOR_MS:
		return
	var recent: Array = []
	for i in range(maxi(0, _samples.size() - 41), _samples.size() - 1):
		recent.append(float(_samples[i]["ms"]))
	if recent.size() < 8:
		return
	recent.sort()
	var med: float = recent[recent.size() / 2]
	if med > 0.0 and ms > med * HITCH_FACTOR:
		event("hitch", "%.0f ms frame (%.1fx the %.0f ms running median)"
			% [ms, ms / med, med])


func _cam() -> Variant:
	# EditorInterface only carries these outside a plain script run, and a
	# missing method throws from inside a Timer callback, aborting the rest of
	# the sample. Guarding keeps the recorder runnable headlessly, which is the
	# only way its reporting gets tested at all.
	if not Engine.is_editor_hint():
		return null
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null: return null
	var c := vp.get_camera_3d()
	return c.global_transform if c != null else null


# ---------- attribution walk ----------
# Counts only what is VISIBLE, because a hidden node costs nothing to draw and
# including it would blame the wrong subsystem. MultiMesh instance counts matter
# more than node counts: one node can be 4,000 drawn instances.
func _attribute() -> void:
	if not Engine.is_editor_hint():
		return
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		# Say so instead of returning in silence. Three recordings produced a
		# header-only owners file with no indication why, which is the same
		# failure mode as every other silent no-op chased tonight.
		if not _warned_no_scene:
			_warned_no_scene = true
			Log.warn("performance recording: no scene is being edited, so the "
				+ "per-owner breakdown will be empty. The frame-rate numbers "
				+ "are still recorded. Open the level scene and record again.")
		return
	var rows: Dictionary = {}
	var blank := {"vis": 0, "inst": 0, "tris": 0, "surf": 0, "calls": 0, "shadow": 0}
	for k in OWNERS:
		rows[OWNERS[k]] = blank.duplicate()
	for k2 in MAPCTX_PARTS:
		rows["map ctx: %s" % String(k2).to_lower()] = blank.duplicate()
	rows["your placed objects"] = blank.duplicate()
	rows["SDK level geometry"] = blank.duplicate()

	var stack: Array = [[root, ""]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var owner_key: String = pair[1]
		var nm := String(n.name)
		if owner_key == "" and OWNERS.has(nm):
			owner_key = OWNERS[nm]
		elif owner_key == OWNERS["_MAP_CONTEXT"] and MAPCTX_PARTS.has(nm):
			# "map context" is five very different things sharing one row, and
			# that hid where the shadow cost lives: the skyline alone carries
			# 49,966 surfaces across 155 meshes for 0.7M triangles, so it is
			# nearly free to draw and ruinous to let cast. Splitting the row is
			# the difference between "scenery is expensive" and knowing which
			# part to fix.
			owner_key = "map ctx: %s" % nm.to_lower()
		if n is VisualInstance3D and (n as Node3D).is_visible_in_tree():
			var bucket := owner_key
			if bucket == "":
				bucket = "SDK level geometry" if nm.ends_with("_Assets") or nm.ends_with("_Terrain") \
					else "your placed objects"
			var r: Dictionary = rows.get(bucket)
			if r != null:
				# Not every VisualInstance3D is a GeometryInstance3D: lights,
				# decals and reflection probes are not, and reading cast_shadow
				# off a null cast aborts this callback silently, which would
				# empty the whole breakdown.
				var gi := n as GeometryInstance3D
				var casts := false
				if gi != null:
					casts = gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				var m: Mesh = null
				var cnt := 1
				if n is MultiMeshInstance3D:
					var mm := (n as MultiMeshInstance3D).multimesh
					if mm != null:
						m = mm.mesh
						cnt = mm.visible_instance_count
						if cnt < 0:
							cnt = mm.instance_count
				elif n is MeshInstance3D:
					m = (n as MeshInstance3D).mesh
				# A node whose distance range has culled it is still
				# visible_in_tree, and counting it inflates everything. Skip it:
				# this is the correction that made the totals reconcile with the
				# engine's own draw-call counter.
				# NOT `continue` on a null cast: that would skip the child-push at
				# the bottom of the loop, so anything nested under a light or a
				# decal would stop being walked. Skip the ACCOUNTING, keep the walk.
				if gi == null or _range_culled(gi):
					pass
				elif m != null:
					var surf: int = m.get_surface_count()
					r["vis"] += 1
					r["inst"] += cnt
					r["surf"] += surf
					r["tris"] += cnt * _tris(m)
					r["calls"] += surf * (1 + (SHADOW_PASSES if casts else 0))
					if casts:
						r["shadow"] += surf
		for c in n.get_children():
			stack.append([c, owner_key])
	_attrib.append({"t": Time.get_ticks_msec() / 1000.0 - _t0,
		"fps": Performance.get_monitor(Performance.TIME_FPS), "rows": rows})


# Is this node outside its own visibility_range right now? Godot culls it at
# render time, so counting it would blame geometry that never reached the GPU.
static func _range_culled(gi: GeometryInstance3D) -> bool:
	var e: float = gi.visibility_range_end
	var b: float = gi.visibility_range_begin
	if e <= 0.0 and b <= 0.0:
		return false
	var cam := EditorInterface.get_editor_viewport_3d(0)
	if cam == null:
		return false
	var c := cam.get_camera_3d()
	if c == null:
		return false
	var d: float = c.global_position.distance_to((gi as Node3D).global_position)
	if e > 0.0 and d > e + gi.visibility_range_end_margin:
		return true
	if b > 0.0 and d < b - gi.visibility_range_begin_margin:
		return true
	return false


# `surface_get_array_index_len` / `surface_get_array_len` are ARRAYMESH-ONLY.
# Called on a PrimitiveMesh they do not merely return 0, they THROW — and the
# throw propagated out of _attribute(), abandoning that entire scan. One
# PlaneMesh (the water surface) was enough to kill roughly a third of the
# attribution scans in a 17-minute recording, 181 errors, silently: the report
# still printed, just built from the scans that happened to die late.
#
# Results are cached per mesh because the same meshes are re-walked every 2 s,
# and the primitive path has to pull the arrays to count anything.
static var _tri_cache: Dictionary = {}

static func _tris(m: Mesh) -> int:
	if m == null: return 0
	var key := m.get_instance_id()
	if _tri_cache.has(key):
		return int(_tri_cache[key])
	var t := 0
	var am := m as ArrayMesh
	if am != null:
		for s in range(am.get_surface_count()):
			# face count without pulling the arrays: index count over 3
			var idx := am.surface_get_array_index_len(s)
			t += int(idx / 3.0) if idx > 0 else int(am.surface_get_array_len(s) / 3.0)
	else:
		for s in range(m.get_surface_count()):
			var arr: Array = m.surface_get_arrays(s)
			if arr.size() > Mesh.ARRAY_INDEX and arr[Mesh.ARRAY_INDEX] != null:
				t += int((arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3.0)
			elif arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null:
				t += int((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3.0)
	_tri_cache[key] = t
	return t


# ---------- reporting: downloads ----------
# Answers "were the downloads the bottleneck, and if so which half of the
# problem was it" — the pipe being full, or the pipe being idle while we did
# something else. Idle time with a non-empty queue is the interesting case: it
# means work was available and we were not fetching it.
func _download_report() -> PackedStringArray:
	var out := PackedStringArray()
	if _dl_series.is_empty():
		return out
	var first: Dictionary = _samples[0]
	var last: Dictionary = _samples[-1]
	var mb: float = float(last.get("dl_mb", 0.0)) - float(first.get("dl_mb", 0.0))
	var files: int = int(last.get("dl_done", 0)) - int(first.get("dl_done", 0))
	var span: float = maxf(0.001, float(last["t"]) - float(first["t"]))
	var rates: Array = []
	var busy := 0.0
	var starved := 0.0
	var peak_active := 0
	var cap := 0
	if sync != null and sync.has_method("stats"):
		cap = int((sync.call("stats") as Dictionary).get("max_workers", 0))
	for d in _dl_series:
		rates.append(float(d["mbps"]))
		peak_active = maxi(peak_active, int(d["active"]))
	# Real gaps between samples, NOT _tick.wait_time. The sampler is a 0.25 s
	# Timer, and a Timer CANNOT FIRE while the main thread is blocked. The first
	# real recording contained a single 44-second frame and averaged 0.68 s
	# between samples rather than 0.25, so charging every sample a flat quarter
	# second undercounts precisely the periods that matter most.
	for i in range(1, _samples.size()):
		var dt: float = float(_samples[i]["t"]) - float(_samples[i - 1]["t"])
		if int(_samples[i].get("active", 0)) > 0:
			busy += dt
		elif int(_samples[i].get("queued", 0)) > 0:
			starved += dt
	rates.sort()
	out.append("")
	out.append("DOWNLOADS")
	out.append("  %.1f MB in %d file(s) over %.0f s  =  %.2f MB/s averaged over the whole recording"
		% [mb, files, span, mb / span])
	if busy > 0.0:
		out.append("  %.2f MB/s while actually transferring (%.0f s of the %.0f s)"
			% [mb / busy, busy, span])
	out.append("  peak %.2f MB/s   median while active %.2f MB/s   most workers busy at once: %d of %d"
		% [rates[-1], rates[rates.size() / 2], peak_active, cap])
	if cap > 0 and peak_active < cap:
		out.append("     never used all %d workers, so the queue — not the host — was the limit" % cap)
	if starved > 1.0:
		out.append("  %.0f s had models QUEUED but nothing downloading — that is dead time,"
			% starved)
		out.append("     and it is the cheapest thing on this list to fix.")
	var failed: int = int(last.get("dl_failed", 0)) - int(first.get("dl_failed", 0))
	if failed > 0:
		out.append("  %d download(s) FAILED — those models are skipped for the session" % failed)
	return out


# ---------- reporting: where the clock actually went ----------
# The one table worth reading first. Everything else says how bad it was; this
# says what to go and fix, ranked, with the per-call cost so the shape of the
# problem is obvious: 2761 calls averaging 8 ms is a batching problem, one call
# of 22 s is a single blocking operation, and they can total identically.
func _span_report() -> PackedStringArray:
	var out := PackedStringArray()
	if _spans.is_empty():
		return out
	var keys: Array = _spans.keys()
	keys.sort_custom(func(a, b): return float(_spans[a]["ms"]) > float(_spans[b]["ms"]))
	var total := 0.0
	for k in keys:
		total += float(_spans[k]["ms"])
	var span: float = maxf(0.001, float(_samples[-1]["t"]) - float(_samples[0]["t"]))
	out.append("")
	out.append("TIME BY PHASE  %.0f s attributed across %.0f s recorded" % [total / 1000.0, span])
	out.append("  Phases marked \"of which\" are NESTED inside the phase above them, so")
	out.append("  they are already counted there — the column does not sum to the run.")
	out.append("  Anything not instrumented (drawing, engine work) is absent entirely.")
	out.append("  %-34s %9s %8s %10s" % ["phase", "total", "calls", "each"])
	for k in keys:
		var e: Dictionary = _spans[k]
		var ms := float(e["ms"])
		var n := int(e["n"])
		out.append("  %-34s %8.1fs %8d %9.1fms  %s"
			% [k.left(34), ms / 1000.0, n, ms / maxf(1.0, float(n)),
				_bar(ms / maxf(1.0, total))])
	return out


func _bar(frac: float) -> String:
	var n := int(round(clampf(frac, 0.0, 1.0) * 20.0))
	return "#".repeat(n)


# ---------- reporting: was the editor usable ----------
# A 0.25 s Timer that fails to fire for 44 seconds is not a broken timer, it is a
# main thread that was blocked for 44 seconds — so the sampler's own starvation
# measures the thing users actually complain about, and it does so without any
# instrumentation in the code being blamed. "Median fps" hides this completely:
# a run can average 5 fps and still be usable, or average 5 fps and be frozen
# solid in half-minute blocks. These are very different bugs.
func _blocking_report() -> PackedStringArray:
	var out := PackedStringArray()
	if _samples.size() < 3:
		return out
	var blocked := 0.0
	var worst := 0.0
	var worst_at := 0.0
	var freezes := 0
	for i in range(1, _samples.size()):
		var dt: float = float(_samples[i]["t"]) - float(_samples[i - 1]["t"])
		if dt > 1.0:
			blocked += dt
			freezes += 1
			if dt > worst:
				worst = dt
				worst_at = float(_samples[i]["t"])
	var span: float = maxf(0.001, float(_samples[-1]["t"]) - float(_samples[0]["t"]))
	out.append("")
	out.append("EDITOR RESPONSIVENESS")
	out.append("  sampled %d times in %.0f s — one every %.2f s, against a 0.25 s timer"
		% [_samples.size(), span, span / float(_samples.size())])
	if freezes == 0:
		out.append("  the main thread never blocked for a whole second. Nothing to fix here.")
		return out
	out.append("  %d freeze(s) over 1 s, %.0f s total = %.0f%% of the run with the editor wedged"
		% [freezes, blocked, 100.0 * blocked / span])
	out.append("  longest single freeze %.1f s at %.0fs — during it the editor drew nothing,"
		% [worst, worst_at])
	out.append("     accepted no input, and no progress bar could move.")
	return out


# ---------- reporting: what happened, when ----------
func _timeline_report() -> PackedStringArray:
	var out := PackedStringArray()
	if _events.is_empty():
		return out
	var hitches := 0
	for e in _events:
		if str(e["kind"]) == "hitch":
			hitches += 1
	out.append("")
	out.append("TIMELINE  (%d event(s), %d hitch(es))" % [_events.size(), hitches])
	# Hitches are printed in full only if there are few of them; a load from cold
	# can produce hundreds and a wall of them buries the state changes that
	# explain the shape of the run.
	var show_hitches := hitches <= 25
	var shown := 0
	for e in _events:
		if str(e["kind"]) == "hitch" and not show_hitches:
			continue
		out.append("  %7.1fs  %-6s %s" % [float(e["t"]), str(e["kind"]), str(e["text"])])
		shown += 1
		if shown > 200:
			out.append("  ... (%d more, see the events csv)" % (_events.size() - shown))
			break
	if not show_hitches:
		out.append("  %d hitches omitted here — they are all in the events csv" % hitches)
	out.append("")
	out.append("PEAKS   %d draw calls   %d objects   %d nodes   %.0f MB vram"
		% [int(_peak["draws"]), int(_peak["objs"]), int(_peak["nodes"]), float(_peak["vram"])])
	return out


# ---------- reporting ----------
func _summarise() -> String:
	if _samples.is_empty():
		return "No samples recorded"
	var fps: Array = []
	for s in _samples:
		fps.append(float(s["fps"]))
	fps.sort()
	var med: float = fps[fps.size() / 2]
	var p10: float = fps[int(fps.size() * 0.1)]
	var worst: Dictionary = _samples[0]
	for s in _samples:
		if float(s["fps"]) < float(worst["fps"]):
			worst = s
	var out := PackedStringArray()
	out.append("PERFORMANCE  %d samples over %.0f s" % [_samples.size(), float(_samples[-1]["t"])])
	out.append_array(_span_report())
	out.append_array(_blocking_report())
	out.append_array(_download_report())
	out.append_array(_timeline_report())
	out.append("  fps      median %.0f   worst 10%% %.0f   lowest %.0f"
		% [med, p10, float(worst["fps"])])
	out.append("  at the lowest: %d draw calls, %.1fM primitives, %d objects, %.0f MB vram"
		% [int(worst["draws"]), float(worst["prims"]) / 1e6, int(worst["objs"]),
			float(worst["vram"])])
	out.append("  camera was at %s" % str(worst["pos"]).left(40))
	# attribution nearest the worst moment: that is the frame worth explaining
	if not _attrib.is_empty():
		var near: Dictionary = _attrib[0]
		for a in _attrib:
			if absf(float(a["t"]) - float(worst["t"])) < absf(float(near["t"]) - float(worst["t"])):
				near = a
		out.append("  what was drawn then, ranked by DRAW CALLS (the thing that costs):")
		var rows: Dictionary = near["rows"]
		var keys: Array = rows.keys()
		keys.sort_custom(func(a, b): return int(rows[a]["calls"]) > int(rows[b]["calls"]))
		var est := 0
		for k in keys:
			var r: Dictionary = rows[k]
			if int(r["vis"]) == 0: continue
			est += int(r["calls"])
			# `shadow` is the part of `surf` that CASTS, and it is the number to
			# act on: each casting surface is paid SHADOW_PASSES extra times, so
			# a row with few surfaces but all of them casting can outweigh a much
			# larger row that casts none. It was tracked from the start and never
			# printed, which is why "47% of surfaces cast" had to be reverse
			# engineered from the totals instead of simply read.
			out.append("     %-22s %6d node(s) %6d surf %8d inst  ~%7d calls  %6.1fM tris"
				% [k, int(r["vis"]), int(r["surf"]), int(r["inst"]),
					int(r["calls"]), float(r["tris"]) / 1e6])
			out.append("       %6d of those surfaces cast shadows (%.0f%%), costing ~%d calls"
				% [int(r["shadow"]), 100.0 * float(r["shadow"]) / maxf(1.0, float(r["surf"])),
					int(r["shadow"]) * SHADOW_PASSES])
		# Reconciliation. If the estimate is nowhere near what the engine
		# reported, the attribution is wrong and nothing above should be acted
		# on -- the first version of this tool was out by 3.5x and pointed at the
		# wrong subsystem.
		out.append("  estimated %d draw calls vs engine's %d  (%.0f%%)"
			% [est, int(worst["draws"]),
				100.0 * est / maxf(1.0, float(worst["draws"]))])
		if est < int(worst["draws"]) * 0.5 or est > int(worst["draws"]) * 2.0:
			out.append("  WARNING: estimate and engine disagree by more than 2x, so the")
			out.append("           per-owner split above is not trustworthy yet.")
	return "\n".join(out)


func _write_csv() -> String:
	var dir := "user://highpoly"
	HighpolyStore.ensure_dir(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var p := "%s/perf-%s.csv" % [dir, stamp]
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return "(could not write the csv)"
	f.store_line("t,fps,ms,draw_calls,primitives,objects,vram_mb,static_mb,nodes,"
		+ "dl_mbps,dl_files_s,dl_queued,dl_active,dl_done,dl_failed,dl_total_mb,x,y,z")
	for s in _samples:
		var v: Vector3 = s["pos"]
		f.store_line("%.2f,%.1f,%.2f,%d,%d,%d,%.0f,%.0f,%d,%.3f,%.2f,%d,%d,%d,%d,%.2f,%.1f,%.1f,%.1f"
			% [s["t"], s["fps"], s["ms"], int(s["draws"]), int(s["prims"]),
				int(s["objs"]), s["vram"], s.get("mem", 0.0), int(s["nodes"]),
				s.get("mbps", 0.0), s.get("files_s", 0.0), int(s.get("queued", 0)),
				int(s.get("active", 0)), int(s.get("dl_done", 0)),
				int(s.get("dl_failed", 0)), s.get("dl_mb", 0.0), v.x, v.y, v.z])
	f.close()

	# Events beside the samples: the same timeline the summary prints, but
	# complete, so a run with 400 hitches is still fully analysable.
	var p3 := "%s/perf-%s-events.csv" % [dir, stamp]
	var f3 := FileAccess.open(p3, FileAccess.WRITE)
	if f3 != null:
		f3.store_line("t,kind,text")
		for e in _events:
			f3.store_line("%.2f,%s,\"%s\"" % [float(e["t"]), str(e["kind"]),
				str(e["text"]).replace("\"", "'")])
		f3.close()
	# the attribution table is what explains the csv, so it ships beside it
	var p2 := "%s/perf-%s-owners.csv" % [dir, stamp]
	var f2 := FileAccess.open(p2, FileAccess.WRITE)
	if f2 != null:
		f2.store_line("t,fps,owner,visible_nodes,surfaces,drawn_instances,est_draw_calls,shadow_surfaces,triangles")
		for a in _attrib:
			for k in (a["rows"] as Dictionary):
				var r: Dictionary = a["rows"][k]
				f2.store_line("%.2f,%.1f,%s,%d,%d,%d,%d,%d,%d"
					% [a["t"], a["fps"], k, int(r["vis"]), int(r["surf"]),
						int(r["inst"]), int(r["calls"]), int(r["shadow"]),
						int(r["tris"])])
		f2.close()
	return ProjectSettings.globalize_path(p)
