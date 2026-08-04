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


func _ready() -> void:
	_tick = Timer.new(); _tick.wait_time = 0.25; _tick.timeout.connect(_sample)
	add_child(_tick)
	_scan = Timer.new(); _scan.wait_time = 2.0; _scan.timeout.connect(_attribute)
	add_child(_scan)


func start() -> String:
	_samples.clear(); _attrib.clear()
	_t0 = Time.get_ticks_msec() / 1000.0
	recording = true
	_tick.start(); _scan.start()
	Log.info("performance recording started - fly the route you want measured, "
		+ "then press Stop")
	return "Recording performance. Fly around, then press Stop."


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
	_samples.append({
		"t": Time.get_ticks_msec() / 1000.0 - _t0,
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objs": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"vram": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"pos": cam.origin if cam != null else Vector3.ZERO,
	})


func _cam() -> Variant:
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null: return null
	var c := vp.get_camera_3d()
	return c.global_transform if c != null else null


# ---------- attribution walk ----------
# Counts only what is VISIBLE, because a hidden node costs nothing to draw and
# including it would blame the wrong subsystem. MultiMesh instance counts matter
# more than node counts: one node can be 4,000 drawn instances.
func _attribute() -> void:
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


static func _tris(m: Mesh) -> int:
	if m == null: return 0
	var t := 0
	for s in range(m.get_surface_count()):
		# face count without pulling the arrays: index count over 3
		t += int(m.surface_get_array_index_len(s) / 3.0)
		if m.surface_get_array_index_len(s) == 0:
			t += int(m.surface_get_array_len(s) / 3.0)
	return t


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
	f.store_line("t,fps,ms,draw_calls,primitives,objects,vram_mb,nodes,x,y,z")
	for s in _samples:
		var v: Vector3 = s["pos"]
		f.store_line("%.2f,%.1f,%.2f,%d,%d,%d,%.0f,%d,%.1f,%.1f,%.1f"
			% [s["t"], s["fps"], s["ms"], int(s["draws"]), int(s["prims"]),
				int(s["objs"]), s["vram"], int(s["nodes"]), v.x, v.y, v.z])
	f.close()
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
