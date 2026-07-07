@tool
extends Node
class_name HighpolySync
# Background model sync: replaces the 1.4 "Update Models" / "Download Full
# Library" / per-scene download prompts with one always-running, signal-driven
# queue. The scene you're editing always downloads first; the rest of the
# library (in "full" scope) trickles in behind it; changed models re-queue
# automatically on the startup + hourly manifest diff. Never blocks the editor.

signal model_ready(name: String)      # a model landed in the store (swap it in)
signal progress_changed()             # queue counters moved (update the bar)
signal manifest_refreshed()           # a NEW manifest was adopted (models changed server-side)

const MAX_WORKERS := 2                # r2.dev throttles bursts; 2 is the sweet spot
const RECHECK_SECS := 3600.0          # re-diff the manifest hourly

var manifest: Dictionary = {}         # name -> {glb, hash, nofit}
var base := ""                        # registry base url
var paused := false:
	set(v):
		if paused == v: return
		paused = v
		if not paused: _pump()
		progress_changed.emit()
var bootstrapping := false            # full-library zip download in progress
var bootstrap_note := ""

var _queue: Array = []                # names, front = next to download
var _queued: Dictionary = {}          # membership mirror of _queue
var _active: Dictionary = {}          # names currently downloading
var _failed: Dictionary = {}          # name -> true (skip this session unless re-prioritized)
var _scene_want: Dictionary = {}      # names the current scene is waiting on
var _workers := 0
var _done := 0
var _fail_count := 0
var _started := false
var _recheck: Timer = null

# ---------- lifecycle ----------
# Called once by the dock after migration/scope are settled.
func start() -> void:
	if _started: return
	_started = true
	_recheck = Timer.new()
	_recheck.wait_time = RECHECK_SECS
	_recheck.timeout.connect(func(): _diff_and_queue())
	add_child(_recheck)
	_recheck.start()
	await _diff_and_queue(true)

# Diff local state against the manifest and queue whatever is stale or (in
# full scope) missing. Change-only by design: an ETag HEAD decides whether the
# manifest even downloads; the diff itself is pure in-memory index lookups
# (no per-file disk stats), chunked so it never blocks a frame.
func _diff_and_queue(first := false) -> void:
	var res: Dictionary = await refresh_manifest()
	if not res.get("ok", false):
		return
	if not res.get("changed", false) and not first:
		return                        # nothing published since last check — zero work
	var full := HighpolyStore.scope() == "full"
	if first and full and HighpolyStore.count() == 0:
		await _bootstrap_bundle()
	var stale: Array = []
	var missing: Array = []
	var i := 0
	for nm in manifest.keys():
		i += 1
		if i % 2000 == 0:
			await get_tree().process_frame   # never stall the editor on big diffs
		var rh := str((manifest[nm] as Dictionary).get("hash", ""))
		if rh == "": continue
		if HighpolyStore.has_entry(nm):
			if HighpolyStore.hash_of(nm) != rh:
				stale.append(nm)        # a community fix landed — always refresh
		elif full:
			missing.append(nm)
	enqueue(stale, true)
	enqueue(missing, false)
	if res.get("changed", false):
		manifest_refreshed.emit()       # map context re-verifies its prop meshes
	progress_changed.emit()

const MANIFEST_CACHE := "user://highpoly/manifest-cache.json"

# Returns {ok, changed}. The manifest only downloads when its ETag moved;
# an unchanged manifest at startup loads from the disk cache (no network body,
# but still counts as "changed" once so the session gets its first diff).
func refresh_manifest() -> Dictionary:
	var url := HighpolyUpdater.manifest_url()
	if url == "": return {"ok": false, "changed": false}
	base = url.get_base_dir() + "/"
	var http := HTTPRequest.new()
	add_child(http)
	var tag := await HighpolyUpdater.remote_etag(http, url)
	var stored := HighpolyStore.manifest_etag()
	if tag != "" and tag == stored:
		if not manifest.is_empty():
			http.queue_free()
			return {"ok": true, "changed": false}   # hourly no-op
		var cached := _load_manifest_cache()        # first load this session
		if not cached.is_empty():
			http.queue_free()
			await _adopt_manifest(cached)
			return {"ok": true, "changed": true}
	var body := await HighpolyUpdater._fetch(http, url)
	http.queue_free()
	if body.is_empty(): return {"ok": false, "changed": false}
	var man: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (man is Dictionary) or not (man as Dictionary).has("props"):
		return {"ok": false, "changed": false}
	_save_manifest_cache(body)
	HighpolyStore.set_manifest_etag(tag)
	await _adopt_manifest(man["props"])
	return {"ok": true, "changed": true}

func _adopt_manifest(props: Dictionary) -> void:
	manifest = props
	HighpolyStore.remote = manifest   # lets the overlay matcher see not-yet-local props
	# same registry keyed by game-mesh name (glb filename) for map context
	var mm: Dictionary = {}
	var i := 0
	for prox in manifest.keys():
		i += 1
		if i % 2000 == 0:
			await get_tree().process_frame
		var e: Dictionary = manifest[prox]
		var g := str(e.get("glb", ""))
		if g != "":
			mm[g.get_file().get_basename()] = {"glb": g, "hash": str(e.get("hash", ""))}
	HighpolyStore.mesh_remote = mm

func _load_manifest_cache() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST_CACHE): return {}
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_CACHE))
	if j is Dictionary and (j as Dictionary).has("props"):
		return (j as Dictionary)["props"]
	return {}

func _save_manifest_cache(body: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(HighpolyStore.ROOT)
	var f := FileAccess.open(MANIFEST_CACHE, FileAccess.WRITE)
	if f: f.store_buffer(body); f.close()

# ---------- queue ----------
func _needs(nm: String) -> bool:
	if not manifest.has(nm): return false
	var rh := str((manifest[nm] as Dictionary).get("hash", ""))
	if rh == "": return false
	return not (HighpolyStore.has_model(nm) and HighpolyStore.hash_of(nm) == rh)

func enqueue(names: Array, front := false) -> void:
	var add: Array = []
	for nm in names:
		if _queued.has(nm) or _active.has(nm): continue
		if not front and _failed.has(nm): continue
		if not _needs(nm): continue
		_failed.erase(nm)
		_queued[nm] = true
		add.append(nm)
	if add.is_empty():
		_pump()
		return
	if front:
		_queue = add + _queue
	else:
		_queue.append_array(add)
	_pump()

# The edited scene's props jump the queue; they also drive the "Preparing
# scene" phase of the progress bar until they've all landed.
func prioritize_scene(names: Array) -> void:
	_scene_want.clear()
	for nm in names:
		if _needs(nm) or _active.has(nm):
			_scene_want[nm] = true
	enqueue(names, true)
	progress_changed.emit()

# A single just-placed prop goes to the very front (swap-in within seconds).
func prioritize_one(nm: String) -> void:
	if not _needs(nm) and not _active.has(nm): return
	_scene_want[nm] = true
	if _queued.has(nm):
		_queue.erase(nm)
		_queue.push_front(nm)
	else:
		enqueue([nm], true)
	progress_changed.emit()

func _pump() -> void:
	if paused or bootstrapping: return
	while _workers < MAX_WORKERS and not _queue.is_empty():
		_worker()

func _worker() -> void:
	_workers += 1
	var http := HTTPRequest.new()
	add_child(http)
	while not paused and not _queue.is_empty():
		var nm: String = _queue.pop_front()
		_queued.erase(nm)
		if not _needs(nm):
			_scene_want.erase(nm)
			continue
		var e: Dictionary = manifest[nm]
		_active[nm] = true
		progress_changed.emit()
		var data := await HighpolyUpdater._fetch(http, base + str(e.get("glb", "")))
		_active.erase(nm)
		if data.is_empty():
			_failed[nm] = true
			_fail_count += 1
		elif HighpolyStore.ingest_bytes(nm, data, str(e.get("hash", "")), bool(e.get("nofit", false))):
			_done += 1
			model_ready.emit(nm)
		_scene_want.erase(nm)
		progress_changed.emit()
	http.queue_free()
	_workers -= 1
	if _workers == 0 and _queue.is_empty():
		HighpolyStore.save()
		progress_changed.emit()

# ---------- progress (for the dock bar) ----------
func pending() -> int:
	return _queue.size() + _active.size()

func scene_pending() -> int:
	var n := 0
	for nm in _scene_want.keys():
		if _queued.has(nm) or _active.has(nm): n += 1
	return n

func status_text() -> String:
	if bootstrapping:
		return bootstrap_note
	var p := pending()
	if p == 0:
		if _fail_count > 0:
			return "Library up to date (%d failed — retrying next check)" % _fail_count
		return "Library up to date · %d models local" % HighpolyStore.count()
	var sp := scene_pending()
	if sp > 0:
		return "Preparing scene · %d model(s) left" % sp
	return "Syncing library in background · %d left" % p

func progress_ratio() -> float:
	var total := _done + pending()
	return 1.0 if total == 0 else float(_done) / float(total)

# ---------- full-library bootstrap (one zip instead of thousands of GETs) ----------
func _bootstrap_bundle() -> void:
	bootstrapping = true
	bootstrap_note = "Fetching library bundle info…"
	progress_changed.emit()
	var http := HTTPRequest.new()
	add_child(http)
	var ok := false
	var meta_raw := await HighpolyUpdater._fetch(http, base + "bundles/bundles.json")
	if not meta_raw.is_empty():
		var meta: Variant = JSON.parse_string(meta_raw.get_string_from_utf8())
		if meta is Dictionary:
			var total_mb := int(int((meta as Dictionary).get("bytes", 0)) / 1048576.0)
			var tmp := "user://highpoly-library.zip"
			http.download_file = tmp
			var tick := Timer.new(); tick.wait_time = 1.0
			add_child(tick); tick.start()
			tick.timeout.connect(func():
				var got := http.get_downloaded_bytes()
				if got > 0:
					bootstrap_note = "Downloading library… %d / %d MB" % [got / 1048576, total_mb]
					progress_changed.emit())
			if http.request(base + str((meta as Dictionary).get("file", "bundles/highpoly-library.zip"))) == OK:
				var res: Array = await http.request_completed
				ok = res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200
			tick.queue_free()
			if ok:
				bootstrap_note = "Installing library…"
				progress_changed.emit()
				ok = await _extract_bundle(tmp)
			DirAccess.remove_absolute(tmp)
	http.queue_free()
	bootstrapping = false
	bootstrap_note = ""
	progress_changed.emit()
	# on failure the normal per-file queue covers everything — just slower

# The 1.4 bundle layout is highpoly/<Name>/<Name>.glb + <Name>.json sidecars;
# extract straight into the store (skipping the retired _med tier) and lift
# the hashes out of the sidecars.
func _extract_bundle(tmp: String) -> bool:
	var zr := ZIPReader.new()
	if zr.open(ProjectSettings.globalize_path(tmp)) != OK:
		return false
	DirAccess.make_dir_recursive_absolute(HighpolyStore.MODELS_DIR)
	var files := zr.get_files()
	var side: Dictionary = {}   # name -> {hash, nofit}
	for f in files:
		if f.begins_with("highpoly/") and f.ends_with(".json"):
			var nm := f.get_file().get_basename()
			var j: Variant = JSON.parse_string(zr.read_file(f).get_string_from_utf8())
			if j is Dictionary:
				side[nm] = j
	var n := 0
	for f in files:
		if not f.begins_with("highpoly/") or not f.ends_with(".glb"): continue
		if f.ends_with("_med.glb"): continue
		var nm := f.get_file().get_basename()
		var out := FileAccess.open(HighpolyStore.model_path(nm), FileAccess.WRITE)
		if out == null: continue
		out.store_buffer(zr.read_file(f))
		out.close()
		var sj: Dictionary = side.get(nm, {})
		HighpolyStore.record(nm, str(sj.get("hash", "")), bool(sj.get("nofit", false)))
		n += 1
		if n % 500 == 0:
			bootstrap_note = "Installing library… %d models" % n
			progress_changed.emit()
			await get_tree().process_frame
	zr.close()
	HighpolyStore.save()
	return n > 0
