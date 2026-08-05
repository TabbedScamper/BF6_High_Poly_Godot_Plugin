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

# Raised from 2 after measuring the host instead of assuming it. The old value
# carried the note "r2.dev throttles bursts; 2 is the sweet spot"; a cold-object
# A/B (three disjoint 24-file blocks per level, alternated so neither level got
# the warmer network) measured 2 workers at 9.9 MB/s and 8 workers at 19.8 MB/s
# — 2.0x the bytes, ~4x the FILES per second — with zero 403/429 responses at
# either level. Most models are small enough that the ~140 ms time-to-first-byte
# dominates the transfer, which is exactly the cost extra connections hide.
#
# The 403s that likely motivated "throttles bursts" reproduce with a default
# Python/urllib User-Agent and vanish with a browser one, so they were about the
# request, not the rate. _fetch() already retries 403/429/5xx with backoff, so if
# the host does start pushing back this degrades rather than fails.
#
# NOW 16. The objection to 16 was that these are HTTPRequest nodes on the
# editor's main loop, and a finished request handed its ENTIRE body across a
# signal as a PackedByteArray — a 300 MB copy landing on the main thread. Since
# models stream to disk (fetch_to_file) the completed body is empty and nothing
# large crosses over, so the cost that made 16 unattractive is gone.
#
# Re-measured on the live host, 48 small models, same connection:
#     workers    MB/s    files/s
#        1       5.67       3.6
#        4      29.43      18.9
#        8      57.13      36.7
#       16      88.44      56.9   <- +55% over 8
#       32      52.41      33.7   <- worse; the host pushes back
# 32 is past the knee, so this is near the top rather than "more is better".
#
# The reason concurrency helps this much is that the work is LATENCY-bound, not
# bandwidth-bound: one worker on small models manages 5.67 MB/s while one worker
# on a single big file manages 46 MB/s on the same line. That ~8x gap is
# per-request overhead, of which ~105 ms is connection setup that a keep-alive
# client would avoid entirely (measured: 183 ms/file fresh vs 78 ms reused).
const MAX_WORKERS := 16
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
var _scene_set: Dictionary = {}       # every name the open scene uses (drives hq tier)
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
	# LOW-POLY DOWNLOADS NOTHING. The mode shows the SDK's own proxies, so not
	# one byte of our library is needed to render it. It used to fetch the full
	# web tier anyway — gigabytes pulled to serve a mode that never displays
	# them, in the mode that is the DEFAULT for every new scene.
	#
	# The manifest refresh above still ran, deliberately: it is one small request
	# and it lets the panel say how many models are available without committing
	# to fetching them. Switching to a High-Poly mode calls this again through
	# _mode_changed(), which is where the queue actually gets built.
	if HighpolyLib.detail == HighpolyLib.Tier.LOW:
		Log.info(("Low-Poly: %d model(s) available, downloading none (the mode "
			+ "draws the SDK's own proxies)") % manifest.size())
		return
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
		var e0: Dictionary = manifest[nm]
		if str(e0.get("hash", "")) == "" and str(e0.get("hqhash", "")) == "":
			continue                    # nothing publishable under either tier
		if HighpolyStore.has_entry(nm):
			# _needs() is TIER-AWARE; the raw hash compare that used to live here
			# was not. It only ever asked "does the local file match the web
			# hash", so a prop already held at web quality looked up to date even
			# after the user switched to full — the switch queued nothing at all
			# and the panel sat on "Upgrading…" forever. The tier decision has to
			# be made HERE, where the queue is built, not only in the worker.
			if _needs(nm):
				# ...but a TIER UPGRADE is not the same as being out of date, and
				# scope must decide it. Scope "scene" means "only what open
				# scenes use"; this path ignored that and queued an hq copy of
				# EVERY model already held. Measured on this install: 1,135 held
				# models against an hq library averaging 17.4 MB each — ~20 GB
				# queued by flipping one dropdown, none of it for anything on
				# screen, because _tier_for() already fetches the OPEN SCENE at
				# hq whatever this setting says.
				#
				# Content staleness (the model was republished, so the local copy
				# matches neither tier's hash) still refreshes regardless — that
				# is a wrong file, not a smaller one.
				if full or not _tier_upgrade_only(nm):
					stale.append(nm)
		elif full or bool(e0.get("global", false)):
			# Globals come down whatever the scope. A globally-placeable prop can
			# be dropped on ANY map, so "only what this map needs" can never rule
			# one out — yet under scope=scene they were fetched only after you
			# placed one, which is the moment you least want to wait. 200 of them,
			# ~145 MB against a 25.6 GB library: 0.6% of the bytes for the props
			# that are always reachable. The publisher sets this flag from the
			# SDK proxy's maps == ["Common"], not the game mesh's own `global`
			# field; see make_plugin_manifest() for why those two disagree.
			missing.append(nm)
	var n_glob := 0
	for nm2 in missing:
		if bool((manifest[nm2] as Dictionary).get("global", false)):
			n_glob += 1
	Log.info("check: %d in manifest · %d to refresh · %d missing (%d global) · tier=%s scope=%s"
		% [manifest.size(), stale.size(), missing.size(), n_glob,
			HighpolyStore.quality(), HighpolyStore.scope()])
	if stale.is_empty() and missing.is_empty():
		# Saying "nothing to do" out loud is the difference between a working
		# no-op and the silence that made the full-quality switch undiagnosable.
		Log.info("nothing to download: everything local already matches the "
			+ "requested tier")
	enqueue(stale, true)
	enqueue(missing, false)
	if res.get("changed", false):
		manifest_refreshed.emit()       # map context re-verifies its prop meshes
	progress_changed.emit()

const MANIFEST_CACHE := "user://highpoly/manifest-cache.json"
const Log = preload("highpoly_log.gd")

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
	# Same registry keyed by game-mesh name (glb filename) for map context.
	#
	# Deliberately the WEB rendition, not hq: these are the surrounding map's
	# scenery, drawn as distance-streamed MultiMeshes in the thousands. Full
	# in-game textures there would multiply VRAM for geometry nobody is
	# inspecting, and the quality setting is about the props you place and edit.
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

# ---------- quality tiers ----------
# Two renditions are published per prop: "web" (small) and "hq" (in-game
# quality textures — identical geometry, byte for byte). A prop is fetched at
# hq when the library is set to full quality OR it belongs to the open scene,
# so the thing you are actually working on always looks right without pulling
# the whole library at full size.
func _tier_for(nm: String) -> String:
	# Low-Poly renders every model in clay, so an hq texture set is bytes nobody
	# can see. Geometry is byte-identical between the two renditions, which is
	# what makes this safe: Low-Poly gets exactly the same accurate silhouette,
	# just without the maps. This is what keeps Low-Poly the CHEAP option now
	# that it draws our geometry instead of the SDK's white proxy.
	#
	# Downgrading nothing already on disk: _should_fetch() treats hq as sticky
	# ("holding it satisfies any tier"), so switching to Low-Poly never re-fetches
	# or discards models already held at full quality. It only makes the NEXT
	# fetch small. Switching back to High-Poly re-queues the scene as a tier
	# upgrade, which is the path that already existed for the quality control.
	if HighpolyLib.detail == HighpolyLib.Tier.LOW: return "web"
	if HighpolyStore.quality() == "full": return "hq"
	return "hq" if _scene_set.has(nm) else "web"

# glb path + expected hash for a tier, falling back to the web fields so an
# older manifest without hq entries still works.
func _rendition(nm: String, tier: String) -> Dictionary:
	var e: Dictionary = manifest.get(nm, {})
	if tier == "hq":
		var hg := str(e.get("hqglb", ""))
		var hh := str(e.get("hqhash", ""))
		if hg != "" and hh != "":
			return {"glb": hg, "hash": hh}
	return {"glb": str(e.get("glb", "")), "hash": str(e.get("hash", ""))}

# ---------- queue ----------
# True when the ONLY reason this model is not current is that a bigger-texture
# rendition exists: the local copy is a valid, matching web build. Distinguishes
# "you could have a prettier one" from "the file you hold is wrong", so the
# library-wide sync can act on the second without dragging in the first.
func _tier_upgrade_only(nm: String) -> bool:
	if not manifest.has(nm): return false
	var e: Dictionary = manifest[nm]
	var web_h := str(e.get("hash", ""))
	if web_h == "" or not HighpolyStore.has_model(nm): return false
	return HighpolyStore.hash_of(nm) == web_h


func _needs(nm: String) -> bool:
	if not manifest.has(nm): return false
	var e: Dictionary = manifest[nm]
	var web_h := str(e.get("hash", ""))
	var hq_h := str(e.get("hqhash", ""))
	if web_h == "" and hq_h == "": return false
	if not HighpolyStore.has_model(nm): return true
	var local := HighpolyStore.hash_of(nm)
	# hq is sticky: holding it satisfies any tier. Without this, closing a
	# scene would demote its props back to web and re-download them, so every
	# scene switch would churn the set down and then straight back up.
	if hq_h != "" and local == hq_h: return false
	if web_h != "" and local == web_h: return _tier_for(nm) == "hq"
	return true

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
	# _scene_set drives the hq tier and must list EVERY prop the scene uses,
	# not only the ones still pending — _needs() consults it.
	_scene_set.clear()
	for nm in names:
		_scene_set[nm] = true
	for nm in names:
		if _needs(nm) or _active.has(nm):
			_scene_want[nm] = true
	enqueue(names, true)
	progress_changed.emit()

# A single just-placed prop goes to the very front (swap-in within seconds).
func prioritize_one(nm: String) -> void:
	_scene_set[nm] = true          # just-placed props belong to the scene -> hq
	if not _needs(nm) and not _active.has(nm): return
	_scene_want[nm] = true
	if _queued.has(nm):
		_queue.erase(nm)
		_queue.push_front(nm)
	else:
		enqueue([nm], true)
	progress_changed.emit()

# ---------- variant models (double-click cycling) ----------
# Variants are published NEXT TO the base model as godot/<GameMesh>__<label>.glb.
# Nothing in this file fetched them, ever: 236 proxies declare 586 variant models
# and the local folder could only ever contain zero of them, so variants_of()
# always came back empty and double-click silently did nothing for every prop.
#
# Fetched per proxy, on demand, rather than joining the main sync diff. 586
# models is a large download for a feature most props never use, and the moment
# someone double-clicks a prop is exactly when its handful are wanted.
#
# NOT recorded in the store index. The index is the currency record for BASE
# models and is diffed against the manifest; variant rows in it would look like
# local models the registry has never heard of. Discovery is a directory glob, so
# the file on disk is the whole record.
func fetch_variants(prox: String) -> int:
	var e = manifest.get(prox)
	if not (e is Dictionary): return 0
	var want: Variant = (e as Dictionary).get("variants", [])
	if not (want is Array) or (want as Array).is_empty(): return 0
	# The remote name is the GAME MESH; the local name must be the PROXY, because
	# _scan_store_variants() splits the local filename at the first "__" to
	# recover which proxy a variant belongs to. Saving under the game-mesh name
	# would file every variant under a proxy that does not exist, and discovery
	# would stay empty with the bytes sitting right there on disk.
	var stem := str((e as Dictionary).get("glb", "")).get_file().get_basename()
	if stem == "": return 0
	HighpolyStore.ensure_dir(HighpolyStore.MODELS_DIR)
	var http := HTTPRequest.new()
	http.use_threads = true
	add_child(http)
	var got := 0
	var failed := 0
	for v in (want as Array):
		if not (v is Dictionary): continue
		var label := str((v as Dictionary).get("name", ""))
		if label == "": continue
		var dst := "%s/%s__%s.glb" % [HighpolyStore.MODELS_DIR, prox, label]
		if FileAccess.file_exists(dst): continue
		var url := base + "godot/%s__%s.glb" % [stem, label]
		var data := await HighpolyUpdater._fetch(http, url)
		if data.is_empty():
			failed += 1
			Log.warn("variant download failed: %s__%s (%s)" % [prox, label, url])
			continue
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			failed += 1
			Log.error("downloaded variant '%s__%s' but could not write it to %s"
				% [prox, label, ProjectSettings.globalize_path(HighpolyStore.MODELS_DIR)])
			continue
		f.store_buffer(data)
		f.close()
		got += 1
		Log.debug("variant %s__%s %s" % [prox, label, Log.human_bytes(data.size())])
	http.queue_free()
	if got > 0:
		# variants_of() caches per proxy INCLUDING the empty answer, so without
		# this the files just written stay invisible until a plugin reload
		HighpolyLib.forget_variants(prox)
	if failed > 0 and got == 0:
		Log.warn("no variants could be fetched for %s (%d failed)" % [prox, failed])
	return got

func _pump() -> void:
	if paused or bootstrapping: return
	while _workers < MAX_WORKERS and not _queue.is_empty():
		_worker()

func _worker() -> void:
	_workers += 1
	var http := HTTPRequest.new()
	# Own thread per worker: HTTPRequest.use_threads defaults to false, which
	# pumps the socket from _process on the main thread, so model downloads ran
	# at the speed the editor was rendering. The library sync runs while overlays
	# are being built and swapped in — precisely when frames are slowest — so the
	# work being downloaded FOR was starving the download itself.
	http.use_threads = true
	add_child(http)
	while not paused and not _queue.is_empty():
		var nm: String = _queue.pop_front()
		_queued.erase(nm)
		if not _needs(nm):
			_scene_want.erase(nm)
			continue
		var e: Dictionary = manifest[nm]
		var tier := _tier_for(nm)
		var rend := _rendition(nm, tier)
		# Which tier was chosen and which file it maps to. "I asked for full
		# quality and nothing happened" is unanswerable without this line.
		Log.debug("fetch %s [%s%s] %s" % [nm, tier,
			" scene" if _scene_set.has(nm) else "", str(rend["glb"])])
		_active[nm] = true
		progress_changed.emit()
		var t0 := Time.get_ticks_msec()
		# Straight to disk. Buffering the whole body meant every worker held its
		# own copy of whatever it was fetching, so 8 workers on 200-330 MB
		# buildings was a multi-GB spike — and the bigger the file, the more
		# likely it was needed. See HighpolyUpdater.fetch_to_file.
		var dest := HighpolyStore.model_path(nm)
		HighpolyStore.ensure_dir(HighpolyStore.MODELS_DIR)
		var ok := await HighpolyUpdater.fetch_to_file(http, base + str(rend["glb"]), dest)
		_active.erase(nm)
		var got := 0
		if ok:
			var fh := FileAccess.open(dest, FileAccess.READ)
			if fh != null:
				got = fh.get_length()
				fh.close()
		if not ok:
			_failed[nm] = true
			_fail_count += 1
			Log.warn("download failed: %s (%s) after %s"
				% [nm, str(rend["glb"]), Log.human_ms(Time.get_ticks_msec() - t0)])
		elif HighpolyStore.ingest_downloaded(nm, str(rend["hash"]), bool(e.get("nofit", false))):
			_done += 1
			var ms := Time.get_ticks_msec() - t0
			# A slow model names itself, with its size, instead of "took forever".
			var line := "%s %s in %s [%s]" % [nm, Log.human_bytes(got),
				Log.human_ms(ms), tier]
			if ms >= 15000 or got >= 100 * 1048576:
				Log.info("large download: " + line)
			else:
				Log.debug("got " + line)
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
				Log.error("downloaded '%s' but could not write it to %s: "
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
			return "%d model(s) could not be saved: check free disk space and permissions on %s" \
				% [_write_failures, ProjectSettings.globalize_path(HighpolyStore.ROOT)]
		if _fail_count > 0:
			return "Library up to date (%d failed: retrying next check)" % _fail_count
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
	bootstrap_note = "Not enough disk space for the one-shot library download (%d GB free, ~%d GB needed): downloading models individually instead." \
		% [int(free / 1073741824.0), int(need / 1073741824.0)]
	Log.warn("" + bootstrap_note)
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
					bootstrap_note = "Library download stalled: retrying (%d/3)…" % (attempt + 1)
					progress_changed.emit()
					await get_tree().create_timer(2.0 * attempt).timeout
				var dl := HTTPRequest.new(); add_child(dl)
				dl.use_threads = true      # multi-GB: never pump this from _process
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
		Log.error("%d of %d models could not be written to %s: "
			% [_write_failures, _write_failures + n, ProjectSettings.globalize_path(HighpolyStore.MODELS_DIR)]
			+ "the library is incomplete; free up disk space and hit Check for Updates.")
	# whatever failed to write stays absent from the index, so the per-file queue
	# picks it up on the next diff — but the user now knows why
	return n > 0
