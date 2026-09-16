extends SceneTree
# Up-front cache supervisor contract, without a game install: a scripted core
# stands in for BF6Core's precache_* methods and the mesh worker is intercepted.
# Covers stage order, locking until ready, progress that never runs backwards,
# pause/resume, failure, generation invalidation, previews recording and the
# cover screen with 28 maps.
const Preparation = preload("res://addons/highpoly_toggle/highpoly_preparation.gd")
const Screen = preload("res://addons/highpoly_toggle/highpoly_preparation_screen.gd")
var failures := 0

class FakeCore:
	extends RefCounted
	var levels: Array = []
	var ticks := 0          # status polls until done
	var polled := 0
	var fail := false
	var cancelled := false
	var starts := 0
	var dip := true
	func precache_start(list: String, _flags: int) -> int:
		levels = list.split(",")
		polled = 0
		cancelled = false
		starts += 1
		return 0
	func precache_cancel() -> bool:
		cancelled = true
		return true
	func precache_status() -> String:
		polled += 1
		var f := clampf(float(polled) / maxf(1.0, ticks), 0.0, 1.0)
		if dip and polled == ticks / 2:
			f *= 0.5   # a stage estimate that jumps back (a map re-weighted mid-build)
		var state := 0 if cancelled else (4 if fail and f >= 1.0 else (3 if f >= 1.0 else 1))
		var maps: Array = []
		for i in levels.size():
			var mf := clampf(f * levels.size() - i, 0.0, 1.0)
			maps.append({"level": levels[i], "state": 2 if mf >= 1.0 else 1, "progress": mf, "layers": [mf, mf, mf, mf]})
		return JSON.stringify({"open": true, "key": "k1", "ready": state == 3, "state": state, "overall": f,
			"since_update": 5.0, "map_count": levels.size(), "maps_done": int(f * levels.size()),
			"current_map": levels[mini(levels.size() - 1, int(f * levels.size()))] if state == 1 else "",
			"current_layer": "meshes", "current_item": "meshes: 1 / 2", "error": "boom" if state == 4 else "",
			"layers": ["placements", "meshes", "textures", "terrain"], "maps": maps})

class Harness:
	extends "res://addons/highpoly_toggle/highpoly_preparation.gd"
	var saved := 0
	var workers: Array = []
	var fake_result: Dictionary = {}
	var screen_in_geometry: Array = []
	func _start_check() -> void:
		stage = Stage.CHECKING
		_finish_check.call_deferred(fake_result)
	func _save() -> void:
		saved += 1
	func _next_geometry() -> void:
		# Instead of a worker process, record each map as prepared immediately.
		if _pause_requested:
			_paused()
			return
		if _geometry_queue.is_empty():
			_start_previews()
			return
		var level := str(_geometry_queue.pop_front())
		screen_in_geometry.append(is_instance_valid(_screen) and _screen.visible)
		workers.append(level)
		var maps: Dictionary = _record.get("maps", {})
		maps[level] = {"state": "prepared"}
		_record["maps"] = maps
		_next_geometry()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func pump(service, frames := 1) -> void:
	for i in frames:
		service._tick()
		await process_frame

func run() -> void:
	root.size = Vector2i(1600, 1000)
	root.gui_embed_subwindows = true
	var levels: Array = []
	for i in 28:
		levels.append("mp_map_%02d" % i)
	var core := FakeCore.new()
	core.ticks = 40
	var service := Harness.new()
	service.fake_result = {"ok": true, "identity": "game-1", "recipe": "addon-1", "reader": "reader-1", "levels": levels, "core": core}
	var locks: Array = []
	var readies: Array = []
	service.editing_lock_changed.connect(func(l): locks.append(l))
	service.ready_changed.connect(func(r): readies.append(r))
	var preview_calls := [0]
	service.previews_missing = func(): return 3
	var unlocked_during_previews := [true]
	service.previews_run = func(progress: Callable) -> Dictionary:
		preview_calls[0] += 1
		unlocked_during_previews[0] = unlocked_during_previews[0] and service.cache_ready
		for i in 3:
			progress.call(i + 1, 3)
			await process_frame
		return {"total": 5, "rendered": 3, "already_cached": 0, "no_source": 2, "cancelled": false}
	root.add_child(service)
	service._timer.stop()
	check(service.API_VERSION == 2, "API version")
	check(get_first_node_in_group(Preparation.SERVICE_GROUP) == service, "service discovery")
	check(not service.cache_ready, "ready before any install")

	# ---- first run: every stage, locked until ready ----
	service.set_install("C:/Games/BF6")
	await process_frame
	await process_frame
	check(service.stage == Preparation.Stage.CORE, "core stage did not start: %s" % Preparation.Stage.keys()[service.stage])
	check(core.levels.size() == 28, "core was not given every map")
	var last := -1.0
	var backwards := 0
	var guard := 0
	while service.stage != Preparation.Stage.READY and guard < 400:
		await pump(service)
		var snap: Dictionary = service.snapshot()
		if float(snap.overall) + 1e-9 < last:
			backwards += 1
		last = float(snap.overall)
		if service.stage == Preparation.Stage.CORE:
			check(is_instance_valid(service._screen) and service._screen.visible, "cover screen not shown while the core cache works")
			check(not str(snap.core_line).is_empty() and str(snap.core_line).contains("working"), "stall line missing")
		guard += 1
	check(service.cache_ready, "never became ready")
	check(backwards == 0, "overall progress ran backwards %d times" % backwards)
	check(is_equal_approx(float(service.snapshot().overall), 1.0), "ready but overall < 100%")
	check(service.workers.size() == 28, "mesh stage did not cover every map (%d)" % service.workers.size())
	check(preview_calls[0] == 1, "previews did not run exactly once")
	check(unlocked_during_previews[0], "High Poly stayed locked while previews rendered")
	check(str(service._record.get("previews", "")) == "game-1:addon-1", "a preview run that drew was not recorded")
	check(readies == [true], "ready signal sequence %s" % str(readies))
	check(locks == [true, false], "editing lock sequence %s" % str(locks))
	check(not is_instance_valid(service._screen), "cover screen left open after ready")

	# ---- restart, same generation: verify only, no screen, no rework ----
	service.workers.clear()
	locks.clear()
	readies.clear()
	core.ticks = 1
	service.set_install("")
	check(readies == [false], "clearing the install did not relock")
	service.set_install("C:/Games/BF6")
	await process_frame
	await process_frame
	for i in 5:
		await pump(service)
	check(service.cache_ready, "complete cache did not become ready on restart")
	check(service.workers.is_empty(), "prepared maps were rebuilt: %s" % str(service.workers))
	check(preview_calls[0] == 1, "recorded previews were re-rendered")
	check(locks.is_empty(), "screen shown for a complete cache: %s" % str(locks))

	# ---- add-on update that leaves the reader alone: indexes kept, previews redone ----
	service.workers.clear()
	service.fake_result = {"ok": true, "identity": "game-1", "recipe": "addon-2", "reader": "reader-1", "levels": levels, "core": core}
	service.set_install("")
	service.set_install("C:/Games/BF6")
	await process_frame
	await process_frame
	for i in 10:
		await pump(service)
	check(service.cache_ready, "add-on update did not finish")
	check(service.workers.is_empty(), "an update that kept the reader re-ran map index jobs: %s" % str(service.workers))
	check(service._record.get("maps", {}).size() == 28, "an update that kept the reader dropped map index records")
	check(preview_calls[0] == 2, "add-on update did not re-render previews")

	# ---- reader update: map indexes rebuilt ----
	service.screen_in_geometry.clear()
	service.workers.clear()
	service.fake_result = {"ok": true, "identity": "game-1", "recipe": "addon-2", "reader": "reader-2", "levels": levels, "core": core}
	service.set_install("")
	service.set_install("C:/Games/BF6")
	await process_frame
	await process_frame
	for i in 10:
		await pump(service)
	check(service.cache_ready, "reader update did not finish")
	check(service.workers.size() == 28, "reader update did not rebuild map indexes")
	check(not service.screen_in_geometry.is_empty() and not service.screen_in_geometry.has(false), "index stage ran without the cover screen")
	check(preview_calls[0] == 2, "reader-only update re-rendered previews")

	# ---- superseded index files are swept by signature ----
	var keep := "aaaa1111bbbb2222"
	for name in ["bf6_index_mp_sweep_v4_%s.idx" % keep, "bf6_walk_mp_sweep_v4_%s.idx" % keep,
			"bf6_index_mp_sweep_v4_0000000000000001.idx", "bf6_pidx_mp_sweep_v4_0000000000000002.idx",
			"bf6_walk_mp_sweep_v3_0000000000000003.idx", "bf6_walk_mp_sweeper_v4_0000000000000004.idx"]:
		var f := FileAccess.open("user://" + name, FileAccess.WRITE)
		f.store_string("x")
		f.close()
	var swept: int = Preparation._sweep_index_files("mp_sweep", keep)
	check(swept == 3, "sweep removed %d files, expected 3" % swept)
	check(FileAccess.file_exists("user://bf6_index_mp_sweep_v4_%s.idx" % keep) and FileAccess.file_exists("user://bf6_walk_mp_sweep_v4_%s.idx" % keep), "sweep removed the current signature")
	check(FileAccess.file_exists("user://bf6_walk_mp_sweeper_v4_0000000000000004.idx"), "sweep touched another map with a shared prefix")
	check(Preparation._sweep_index_files("mp_sweep", "") == 0, "an empty signature swept files")
	for name in ["bf6_index_mp_sweep_v4_%s.idx" % keep, "bf6_walk_mp_sweep_v4_%s.idx" % keep, "bf6_walk_mp_sweeper_v4_0000000000000004.idx"]:
		DirAccess.remove_absolute("user://" + name)

	# ---- pause during the core stage, then resume ----
	core.ticks = 50
	service.fake_result = {"ok": true, "identity": "game-2", "recipe": "addon-2", "reader": "reader-2", "levels": levels, "core": core}
	service.set_install("")
	service.set_install("C:/Games/BF6")
	await process_frame
	await process_frame
	await pump(service, 3)
	check(service.stage == Preparation.Stage.CORE, "not in core stage before pause")
	service.pause()
	check(core.cancelled, "pause did not cancel the core build")
	await pump(service, 2)
	check(service.stage == Preparation.Stage.PAUSED, "pause did not settle: %s" % Preparation.Stage.keys()[service.stage])
	check(not service.cache_ready, "paused cache reported ready")
	var starts := core.starts
	service.resume()
	check(core.starts == starts + 1 and service.stage == Preparation.Stage.CORE, "resume did not restart the core build")
	guard = 0
	while not service.cache_ready and guard < 200:
		await pump(service)
		guard += 1
	check(service.cache_ready, "resumed cache did not finish")

	# ---- core failure: stays locked with the error on screen ----
	core.ticks = 2
	core.fail = true
	service.fake_result = {"ok": true, "identity": "game-3", "recipe": "addon-2", "reader": "reader-2", "levels": levels, "core": core}
	service.set_install("")
	service.set_install("C:/Games/BF6")
	await process_frame
	await process_frame
	await pump(service, 4)
	check(service.stage == Preparation.Stage.FAILED, "core failure not reported")
	check(not service.cache_ready, "failed cache unlocked High Poly")
	check(is_instance_valid(service._screen) and service._screen.visible, "failure not shown")
	check(str(service.snapshot().error).contains("boom"), "core error text lost")
	core.fail = false

	# ---- a bad installation never reaches the core ----
	service.fake_result = {"ok": false, "error": "no Data folder"}
	service.set_install("")
	service.set_install("C:/Nope")
	await process_frame
	await process_frame
	check(service.stage == Preparation.Stage.FAILED and not service.cache_ready, "unverified install was accepted")

	# ---- map selector API ----
	check(not service.prepare_levels([]), "empty selection accepted")
	check(not service.prepare_levels(["mp_fake"]), "unknown map accepted")

	# ---- the cover screen lays out 28 maps ----
	var screen: Dictionary = service.snapshot()
	check(service._screen._map_rows.size() == 28, "screen rows: %d" % service._screen._map_rows.size())

	root.remove_child(service)
	check(get_nodes_in_group(Preparation.SERVICE_GROUP).is_empty(), "service remained discoverable after leaving the tree")
	service.free()
	var adapter = load("res://addons/highpoly_toggle/highpoly_toggle.gd")
	check(adapter != null and adapter.can_instantiate(), "real plugin failed to parse")
	print("Preparation supervisor: stage order, lock until ready, monotonic progress, restart reuse, upgrade invalidation, pause/resume, failure and screen checks. Failures: ", failures)
	quit(0 if failures == 0 else 1)
