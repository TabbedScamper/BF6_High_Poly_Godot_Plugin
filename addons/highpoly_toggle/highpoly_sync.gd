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
# No new bytes for this long means the transfer is dead, not slow. Needed because
# HTTPRequest.timeout defaults to 0 (wait forever): a socket that is accepted and
# then goes quiet never fires request_completed, and with only MAX_WORKERS
# workers, two such stalls wedge the entire library sync for the session.
const STALL_SECS := 45.0

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
var _boot_done := 0                   # bytes of the bundle fetched so far
var _boot_total := 0                  # bundle size (0 until the server says)

var _queue: Array = []                # names, front = next to download
var _queued: Dictionary = {}          # membership mirror of _queue
var _active: Dictionary = {}          # names currently downloading
var _failed: Dictionary = {}          # name -> true (skip this session unless re-prioritized)
var _scene_want: Dictionary = {}      # names the current scene is waiting on
var _workers := 0
var _done := 0
var _fail_count := 0
var _write_failures := 0              # fetched fine but couldn't be stored
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

# Manual "check for updates now": force-refreshes the manifest (cache-busted —
# the registry manifest is CDN-cached ~5 min, which the button must not wait
# out), diffs, queues, and resets the hourly timer.
func check_now() -> void:
	if _recheck != null:
		_recheck.start()
	await _diff_and_queue(false, true)

# Diff local state against the manifest and queue whatever is stale or (in
# full scope) missing. Change-only by design: an ETag HEAD decides whether the
# manifest even downloads; the diff itself is pure in-memory index lookups
# (no per-file disk stats), chunked so it never blocks a frame.
func _diff_and_queue(first := false, force := false) -> void:
	var res: Dictionary = await refresh_manifest(force)
	if not res.get("ok", false):
		return
	if not res.get("changed", false) and not first and not force:
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
func refresh_manifest(force := false) -> Dictionary:
	var url := HighpolyUpdater.manifest_url()
	if url == "": return {"ok": false, "changed": false}
	base = url.get_base_dir() + "/"
	var fetch_url := url
	if force:
		# unique query string = CDN cache miss -> the origin's current manifest
		var sep := "&" if url.contains("?") else "?"
		fetch_url = "%s%sts=%d" % [url, sep, Time.get_unix_time_from_system()]
	var http := HTTPRequest.new()
	add_child(http)
	var tag := await HighpolyUpdater.remote_etag(http, fetch_url)
	var stored := HighpolyStore.manifest_etag()
	if not force and tag != "" and tag == stored:
		if not manifest.is_empty():
			http.queue_free()
			return {"ok": true, "changed": false}   # hourly no-op
		var cached := _load_manifest_cache()        # first load this session
		if not cached.is_empty():
			http.queue_free()
			await _adopt_manifest(cached)
			return {"ok": true, "changed": true}
	var body := await HighpolyUpdater._fetch(http, fetch_url)
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
	HighpolyStore.ensure_dir(HighpolyStore.ROOT)
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
		else:
			# The bytes arrived but could NOT be written (disk full, unwritable
			# user://, path too long). This used to fall through both branches:
			# not counted done, not counted failed, no message — the model simply
			# vanished and re-queued forever on the next diff. Silent, endless,
			# and invisible to the user. Now it is a first-class failure.
			_failed[nm] = true
			_fail_count += 1
			_write_failures += 1
			if _write_failures == 1:                      # log once, not 7,670 times
				push_error("High-Poly Preview: downloaded '%s' but could not write it to %s — "
					% [nm, ProjectSettings.globalize_path(HighpolyStore.MODELS_DIR)]
					+ "check free disk space and folder permissions.")
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
		# a write failure is not a network problem and retrying won't fix it —
		# say what's actually wrong instead of "retrying next check"
		if _write_failures > 0:
			return "%d model(s) could not be saved — check free disk space and permissions on %s" \
				% [_write_failures, ProjectSettings.globalize_path(HighpolyStore.ROOT)]
		if _fail_count > 0:
			return "Library up to date (%d failed — retrying next check)" % _fail_count
		return "Library up to date · %d models local" % HighpolyStore.count()
	var sp := scene_pending()
	if sp > 0:
		return "Preparing scene · %d model(s) left" % sp
	return "Syncing library in background · %d left" % p

func progress_ratio() -> float:
	# During the bootstrap there are no queued models yet, so the model-count
	# ratio was 0/0 -> 1.0: the bar sat at 100% for the whole multi-GB download.
	# Report real bytes instead.
	if bootstrapping:
		return clampf(float(_boot_done) / float(_boot_total), 0.0, 1.0) if _boot_total > 0 else 0.0
	var total := _done + pending()
	return 1.0 if total == 0 else float(_done) / float(total)

# The bundle lands as a zip AND is then extracted beside itself, so the peak
# requirement is roughly twice its size. Downloading 5.6 GB onto a disk that
# can't hold the result used to "succeed" into a half-installed library (see
# _extract_bundle), so check first and fall back to the per-file queue, which
# needs only one model's worth of space at a time.
func _no_room_for_bundle(bytes: int) -> bool:
	if bytes <= 0: return false
	HighpolyStore.ensure_dir(HighpolyStore.ROOT)
	var da := DirAccess.open(HighpolyStore.ROOT)
	if da == null: return false                      # can't tell — let it try
	var free := da.get_space_left()
	if free <= 0: return false
	var need := int(bytes * 2.1)                     # zip + extracted + slack
	if free >= need: return false
	bootstrap_note = "Not enough disk space for the one-shot library download (%d GB free, ~%d GB needed) — downloading models individually instead." \
		% [int(free / 1073741824.0), int(need / 1073741824.0)]
	push_warning("High-Poly Preview: " + bootstrap_note)
	progress_changed.emit()
	return true

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
		if meta is Dictionary and not _no_room_for_bundle(int((meta as Dictionary).get("bytes", 0))):
			var total_mb := int(int((meta as Dictionary).get("bytes", 0)) / 1048576.0)
			var tmp := "user://highpoly-library.zip"
			_boot_total = int((meta as Dictionary).get("bytes", 0))
			# Retry like every other fetch does, and never await a signal that a dead
			# socket will not send. HTTPRequest.timeout is 0 by default (wait forever),
			# so a connection that is accepted and then abandoned used to hang the
			# bootstrap for the rest of the session with the bar frozen. A fixed timeout
			# is wrong for a multi-GB transfer, so the test is whether the byte counter
			# is still MOVING.
			var url := base + str((meta as Dictionary).get("file", "bundles/highpoly-library.zip"))
			for attempt in range(3):
				if attempt > 0:
					bootstrap_note = "Library download stalled — retrying (%d/3)…" % (attempt + 1)
					progress_changed.emit()
					await get_tree().create_timer(2.0 * attempt).timeout
				var dl := HTTPRequest.new(); add_child(dl)
				dl.download_file = tmp
				var st := {"done": false, "ok": false}
				dl.request_completed.connect(func(res: int, code: int, _h, _b):
					st["done"] = true
					st["ok"] = res == HTTPRequest.RESULT_SUCCESS and code == 200,
					CONNECT_ONE_SHOT)
				if dl.request(url) != OK:
					dl.queue_free()
					continue
				var last := 0
				var idle := 0.0
				while not st["done"]:
					await get_tree().create_timer(1.0).timeout
					var got := dl.get_downloaded_bytes()
					var bsz := dl.get_body_size()   # real Content-Length once headers land
					if bsz > 0: _boot_total = bsz
					_boot_done = got
					if got > last:
						last = got
						idle = 0.0
						bootstrap_note = "Downloading library… %d / %d MB" % [got / 1048576, total_mb]
						progress_changed.emit()
					else:
						idle += 1.0
					if idle >= STALL_SECS and not st["done"]:
						dl.cancel_request()   # does NOT emit request_completed
						break
				ok = st["ok"]
				dl.queue_free()
				if ok: break
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
	HighpolyStore.ensure_dir(HighpolyStore.MODELS_DIR)
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
		if out == null:
			# was a bare `continue`: a disk that filled up mid-extract silently
			# skipped the rest and still reported success, leaving a library that
			# looked installed but was half empty
			_write_failures += 1
			continue
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
	if _write_failures > 0:
		push_error("High-Poly Preview: %d of %d models could not be written to %s — "
			% [_write_failures, _write_failures + n, ProjectSettings.globalize_path(HighpolyStore.MODELS_DIR)]
			+ "the library is incomplete; free up disk space and hit Check for Updates.")
	# whatever failed to write stays absent from the index, so the per-file queue
	# picks it up on the next diff — but the user now knows why
	return n > 0
