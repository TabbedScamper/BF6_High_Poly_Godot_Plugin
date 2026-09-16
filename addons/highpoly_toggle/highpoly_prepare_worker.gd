extends SceneTree

# Separate process: preparation never opens, saves or modifies an editor scene.
const Cache = preload("highpoly_install_cache.gd")
const Source = preload("highpoly_gamesource.gd")
var job: Dictionary = {}
var status_path := ""
var cancel_path := ""
var report: Dictionary = {}
var _last_status := 0
var _last_stage := ""
var _lease: RefCounted
var _cancel_reason := ""
var _next_parent_check := 0

func _init() -> void:
	call_deferred("_run")

func _cancelled() -> bool:
	if not _cancel_reason.is_empty():
		return true
	if FileAccess.file_exists(cancel_path):
		_cancel_reason = "Cancelled from the editor. Completed resources are retained." if FileAccess.get_file_as_string(cancel_path).strip_edges() == "cancel" else "Paused from the editor."
		return true
	var parent := int(job.get("parent_pid", 0))
	if parent > 0 and Time.get_ticks_msec() >= _next_parent_check:
		_next_parent_check = Time.get_ticks_msec() + 500
		# Godot's process query returned false for the running parent editor in
		# a separate worker. Ask Windows through the binding instead.
		var state := int(_lease.call("process_status", parent)) if _lease != null and _lease.has_method("process_status") else -1
		if state == 0:
			_cancel_reason = "The editor that started preparation closed."
		elif state < 0:
			_cancel_reason = "Could not check the parent editor. Restart Godot with the updated native binding."
	return not _cancel_reason.is_empty()

func _status(stage: String, done := 0, total := 0) -> void:
	var now := Time.get_ticks_msec()
	if stage == _last_stage and now - _last_status < 250 and done != total:
		return
	_last_stage = stage
	_last_status = now
	report.merge({"stage": stage, "done": done, "total": total,
		"updated": Time.get_unix_time_from_system()}, true)
	Cache.write_record(status_path, report)

func _finish(state: String, why: String) -> void:
	report["state"] = state
	report["error"] = why
	_status(state)
	quit(0 if state == "prepared" else 1)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		quit(2)
		return
	job = Cache.read_record(str(args[0]))
	status_path = str(job.get("status", ""))
	cancel_path = str(job.get("cancel", ""))
	if status_path.is_empty() or cancel_path.is_empty():
		quit(2)
		return
	preload("highpoly_log.gd").preparation_logs(status_path.trim_suffix(".json") + ".logs")
	var install := str(job.get("install", ""))
	var level := str(job.get("level", ""))
	report = {"state": "preparing", "level": level, "scope": "source geometry",
		"identity": str(job.get("identity", "")), "meshes": 0, "uncached": 0}
	_status("Checking game files")
	var initial := Cache.inspect(install)
	if not initial.get("ok", false) or initial.get("identity", "") != report["identity"]:
		_finish("stale", "Game files changed or could not be verified. Check the installation again.")
		return
	# Index-only jobs are keyed on the reader scripts alone (Cache.reader_recipe).
	var recipe: String = Cache.reader_recipe() if bool(job.get("index_only", false)) else Cache.recipe(true)
	if recipe.is_empty() or recipe != str(job.get("recipe", "")):
		_finish("stale", "The add-on changed. Check updates and prepare with the current reader.")
		return
	report["recipe"] = recipe
	Cache.accept(install, initial)
	_lease = ClassDB.instantiate("BF6Core") as RefCounted
	# ONE MAP, ONE LOCK. The supervisor runs up to three index jobs at once, and a
	# single lock for the whole cache refused all but one of them as "another
	# editor is preparing"; each refusal went back on the queue and was launched
	# again. What must not happen is two processes indexing the SAME map into the
	# same files, so an index job locks its map. A geometry job still takes the
	# whole-cache lock.
	var lock_scope := ProjectSettings.globalize_path("user://highpoly").replace("\\", "/").to_lower()
	if bool(job.get("index_only", false)):
		lock_scope += "|index|" + level.to_lower()
	var lock_key := lock_scope.sha256_text()
	if _lease == null or not _lease.has_method("preparation_lock") or not _lease.call("preparation_lock", lock_key):
		_finish("paused", "Another editor is preparing this cache, or the preparation lock is unavailable. Resume after it finishes.")
		return
	if _cancelled():
		_finish("paused", _cancel_reason)
		return
	var gs = Source.new()
	var index_only := bool(job.get("index_only", false))
	# Index-only: the map's mount index, partition index and placement walk.
	# Geometry comes from the shared up-front cache, so nothing else is built.
	gs.geom_cache = not index_only
	gs.geom_cache_read = not bool(job.get("force", false))
	gs.prepare_geometry_only = true
	if not gs.open_map(level, install, func(stage, done, total): _status(str(stage), done, total)):
		_finish("failed", gs.error)
		return
	if _cancelled():
		_finish("paused", _cancel_reason)
		return
	if gs.walk == null or gs.walk.rows.is_empty():
		_finish("failed", "No map placements were decoded. This installation's schema may be unavailable.")
		return
	if index_only:
		report["signature"] = str(gs.src.signature()) if gs.src != null else ""
		report["placements"] = gs.walk.rows.size()
		report["recipe"] = recipe
		if bool(job.get("record_textures", false)):
			# The order this map asks for textures in, for the editor's read-ahead.
			# Materials are built against placeholders; nothing is decoded or kept.
			_status("Recording texture order")
			gs.record_textures = true
			gs.prepare_geometry_only = false
			var tdata: Dictionary = gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
			var tprops: Array = tdata.get("props", []).duplicate()
			tprops.append_array(tdata.get("backdrop", []))
			var seen := {}
			for p in tprops:
				var key := str(p.get("mesh", ""))
				if key.is_empty() or seen.has(key):
					continue
				seen[key] = true
				if _cancelled():
					_finish("paused", _cancel_reason)
					return
				gs.mesh_for(key)
				if seen.size() % 256 == 0:
					# Drop built meshes in batches; keep the placement scope table.
					var scopes: Dictionary = gs._group_meta.duplicate()
					gs.release_caches()
					gs._group_meta = scopes
					await process_frame
			report["textures"] = gs.texture_requests.size()
			Source.save_texture_order(level, gs.texture_requests)
		_finish("prepared", "")
		return
	var data: Dictionary = gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
	var props: Array = data.get("props", []).duplicate()
	props.append_array(data.get("backdrop", []))
	if props.is_empty() or str(gs._geom_dir).is_empty():
		_finish("failed", "No cacheable map geometry was found.")
		return
	var assets: Dictionary = {}
	var missing: Array = []
	var reserve := int(job.get("reserve_bytes", 8 * 1024 * 1024 * 1024))
	var memory_reserve := maxi(2 * 1024 * 1024 * 1024, int(job.get("memory_reserve_bytes", 4 * 1024 * 1024 * 1024)))
	var release_batch := 8 if bool(job.get("foreground", false)) else 32
	var directory := DirAccess.open(gs._geom_dir)
	var limit := int(job.get("test_limit", 0))
	report["props_total"] = props.size()
	report["props_done"] = 0
	for i in range(props.size()):
		if _cancelled():
			_finish("paused", _cancel_reason)
			return
		var free_memory := int(OS.get_memory_info().get("free", -1))
		if free_memory >= 0 and free_memory < memory_reserve:
			gs.release_caches()
			_finish("paused", "Preparation stopped to preserve free memory. Close other applications, then resume.")
			return
		if directory == null or directory.get_space_left() < reserve:
			_finish("paused", "Cache preparation stopped to preserve free disk space.")
			return
		if limit > 0 and i >= limit:
			_finish("partial", "Test sample only. This map is not fully prepared.")
			return
		var key := str(props[i].get("mesh", ""))
		_status("Preparing geometry", i, props.size())
		var saved_before := int(gs.n_geom_saved)
		var mesh: Mesh = gs.mesh_for(key)
		if mesh == null:
			missing.append(key)
		else:
			var resource_name := key.get_slice("|", 0)
			if gs._group_meta.has(key):
				resource_name = str(gs._group_meta[key][0])
			var file := str(gs._geom_path("%s#0" % resource_name))
			var persisted: Resource = ResourceLoader.load(file, "ArrayMesh", ResourceLoader.CACHE_MODE_IGNORE) if FileAccess.file_exists(file) else null
			var force_saved := not bool(job.get("force", false)) or int(gs.n_geom_saved) > saved_before
			if force_saved and persisted is ArrayMesh and persisted.get_surface_count() > 0:
				assets[file] = true
			else:
				missing.append(key)
		mesh = null
		report["meshes"] = assets.size()
		report["uncached"] = missing.size()
		report["props_done"] = i + 1
		# Drop rendered resources in batches; keep the placement scope table.
		if i % release_batch == release_batch - 1:
			var scopes: Dictionary = gs._group_meta.duplicate()
			gs.release_caches()
			gs._group_meta = scopes
			await process_frame
	_status("Verifying game files")
	var final := Cache.inspect(install)
	if not final.get("ok", false) or final.get("identity", "") != initial["identity"] or Cache.recipe(true) != recipe:
		_finish("stale", "The game changed during preparation. Rebuild against the updated installation.")
		return
	if _cancelled():
		_finish("paused", _cancel_reason)
		return
	# Explicit artifacts, so deleting or truncating caches is not mistaken for ready.
	var files: Array = []
	for path in assets:
		var file := FileAccess.open(str(path), FileAccess.READ)
		if file == null or file.get_length() <= 0:
			_finish("failed", "A prepared resource could not be verified.")
			return
		files.append({"path": path, "bytes": file.get_length()})
	report["artifacts"] = files
	report["uncached_assets"] = missing
	_finish("prepared" if missing.is_empty() else "partial",
		"" if missing.is_empty() else "%d objects still require live decoding." % missing.size())
