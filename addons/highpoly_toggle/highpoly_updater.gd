@tool
extends RefCounted
class_name HighpolyUpdater
# Pulls corrected models from the community registry.
# Compares the published plugin-manifest (proxy-name keyed, content-hashed)
# against local sidecar hashes in res://highpoly/<Name>/<Name>.json and
# re-downloads only what changed. Only props already present locally are
# updated (deploy assets for your level first).

const SETTING := "highpoly/manifest_url"
const DEFAULT_MANIFEST := "https://pub-45114dae448e4a059f488662e3d47b19.r2.dev/plugin-manifest.json"

static func manifest_url() -> String:
	if ProjectSettings.has_setting(SETTING):
		return str(ProjectSettings.get_setting(SETTING))
	return DEFAULT_MANIFEST

# GET with retry/backoff — the public r2.dev host throttles rapid bursts, so a
# single failed attempt (403/429/5xx) is usually transient.
static func _fetch(http: HTTPRequest, url: String) -> PackedByteArray:
	for attempt in range(4):
		if attempt > 0:
			# 0.4s, 0.8s, 1.6s between retries
			await http.get_tree().create_timer(0.4 * pow(2, attempt - 1)).timeout
		if http.request(url) != OK:
			continue
		var res: Array = await http.request_completed
		# res = [result, response_code, headers, body]
		if res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200:
			return res[3]
	return PackedByteArray()

# Write one downloaded model file and record its content hash in the prop's
# sidecar json (res://highpoly/<Name>/<Name>.json) so the next update check can
# skip unchanged files. job = [prox, remote_rel, hash, local_file, sidecar_key, nofit]
static func _store_model(job: Array, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute("res://highpoly/%s" % job[0])
	var f := FileAccess.open(job[3], FileAccess.WRITE)
	if f == null: return false
	f.store_buffer(data); f.close()
	var side := "res://highpoly/%s/%s.json" % [job[0], job[0]]
	var sj: Dictionary = {}
	if FileAccess.file_exists(side):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
		if j is Dictionary: sj = j
	sj[job[4]] = job[2]
	# prefab-assembled models must not be auto-fitted (exact game-space builds)
	if job.size() > 5 and job[5]:
		sj["nofit"] = true
	var s := FileAccess.open(side, FileAccess.WRITE)
	if s:
		s.store_string(JSON.stringify(sj)); s.close()
	return true

static func run(host: Node, status: Callable) -> void:
	var url := manifest_url()
	if url == "":
		status.call("Set Project Setting  %s  first" % SETTING)
		return
	var http := HTTPRequest.new()
	host.add_child(http)
	status.call("Fetching manifest…")
	var body := await _fetch(http, url)
	if body.is_empty():
		status.call("Manifest fetch failed"); http.queue_free(); return
	var man: Variant = JSON.parse_string(body.get_string_from_utf8())
	if man == null or not (man is Dictionary) or not man.has("props"):
		status.call("Manifest unreadable"); http.queue_free(); return
	var base := url.get_base_dir() + "/"
	var props: Dictionary = man["props"]
	var to_update: Array = []   # [prox, remote_glb, hash, local_file, sidecar_key]
	for prox in props.keys():
		var dir := "res://highpoly/%s" % prox
		if not DirAccess.dir_exists_absolute(dir):
			continue                                   # not deployed locally
		var remote: Dictionary = props[prox]
		var side := "%s/%s.json" % [dir, prox]
		var sj: Dictionary = {}
		if FileAccess.file_exists(side):
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
			if j is Dictionary: sj = j
		var nofit: bool = bool(remote.get("nofit", false))
		var rhash := str(remote.get("hash", ""))
		if rhash != "" and str(sj.get("hash", "")) != rhash:
			to_update.append([prox, str(remote.get("glb", "")), rhash, "%s/%s.glb" % [dir, prox], "hash", nofit])
		# (medium tier retired — high-poly is the only downloadable rendition)
	if to_update.is_empty():
		status.call("All models up to date"); http.queue_free(); return
	var done := 0
	var failed := 0
	for item in to_update:
		status.call("Downloading %s… (%d/%d)" % [item[0], done + failed + 1, to_update.size()])
		var data := await _fetch(http, base + item[1])
		if not data.is_empty() and _store_model(item, data):
			done += 1
		else:
			failed += 1
	http.queue_free()
	EditorInterface.get_resource_filesystem().scan()
	status.call("Updated %d model(s)%s — reimporting…" %
		[done, ("" if failed == 0 else ", %d failed" % failed)])

static func _scene_proxy_keys(root: Node, out: Dictionary) -> void:
	# collect every proxy key present in the edited scene (by scene_file_path or name)
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.name == "_HIPOLY_PREVIEW" or n.name == "_MAP_CONTEXT":
			continue
		var k := ""
		var sfp := n.scene_file_path
		if sfp != "":
			k = sfp.get_file().get_basename()
		if k != "": out[k] = true
		for c in n.get_children():
			stack.append(c)

static func missing_for_scene(root: Node, want_med: bool, props: Dictionary) -> Array:
	# scene proxies that the registry knows but aren't fully downloaded locally
	var keys := {}
	_scene_proxy_keys(root, keys)
	var need: Array = []
	for prox in keys.keys():
		if not props.has(prox): continue
		if not FileAccess.file_exists("res://highpoly/%s/%s.glb" % [prox, prox]):
			need.append(prox)
	return need

# Download every registry-known prop for the current scene (both tiers).
# Returns true if it downloaded at least one; status is a Callable(String).
static func download_for_scene(host: Node, root: Node, status: Callable) -> bool:
	var url := manifest_url()
	if url == "": status.call("No registry URL set"); return false
	var http := HTTPRequest.new(); host.add_child(http)
	status.call("Fetching manifest…")
	var body := await _fetch(http, url)
	if body.is_empty():
		status.call("Manifest fetch failed"); http.queue_free(); return false
	var man: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (man is Dictionary) or not man.has("props"):
		status.call("Manifest unreadable"); http.queue_free(); return false
	var base := url.get_base_dir() + "/"
	var props: Dictionary = man["props"]
	var keys := {}
	_scene_proxy_keys(root, keys)
	var jobs: Array = []   # [prox, remote_glb, hash, local_file, sidecar_key]
	for prox in keys.keys():
		if not props.has(prox): continue
		var remote: Dictionary = props[prox]
		var dir := "res://highpoly/%s" % prox
		var nofit: bool = bool(remote.get("nofit", false))
		var gh := str(remote.get("hash", ""))
		if gh != "":
			jobs.append([prox, str(remote.get("glb", "")), gh, "%s/%s.glb" % [dir, prox], "hash", nofit])
	if jobs.is_empty():
		status.call("No registry models for this scene"); http.queue_free(); return false
	var done := 0; var failed := 0
	for item in jobs:
		status.call("Downloading… (%d/%d)" % [done + failed + 1, jobs.size()])
		var data := await _fetch(http, base + item[1])
		if not data.is_empty() and _store_model(item, data):
			done += 1
		else:
			failed += 1
	http.queue_free()
	EditorInterface.get_resource_filesystem().scan()
	status.call("Downloaded %d file(s)%s — reimporting…" % [done, ("" if failed == 0 else ", %d failed" % failed)])
	return done > 0

# One-time bulk install: download the prebuilt full-library zip (every proxy's
# high + med model with hash sidecars, exact res://highpoly layout) and extract
# it. Afterwards "Update Models" is a pure delta — it only fetches changes.
static func download_bundle(host: Node, status: Callable) -> bool:
	var base := manifest_url().get_base_dir() + "/"
	var http := HTTPRequest.new(); host.add_child(http)
	status.call("Fetching bundle info…")
	var meta_raw := await _fetch(http, base + "bundles/bundles.json")
	if meta_raw.is_empty():
		status.call("Bundle info fetch failed"); http.queue_free(); return false
	var meta: Variant = JSON.parse_string(meta_raw.get_string_from_utf8())
	if not (meta is Dictionary):
		status.call("Bundle info unreadable"); http.queue_free(); return false
	var total_mb := int(int(meta.get("bytes", 0)) / 1048576.0)
	var tmp := "user://highpoly-library.zip"
	http.download_file = tmp                    # stream to disk; the zip is GBs
	status.call("Downloading full library (~%d MB)…" % total_mb)
	if http.request(base + str(meta.get("file", "bundles/highpoly-library.zip"))) != OK:
		status.call("Bundle request failed"); http.queue_free(); return false
	var tick := Timer.new(); tick.wait_time = 1.0; host.add_child(tick); tick.start()
	tick.timeout.connect(func():
		var got := http.get_downloaded_bytes()
		if got > 0: status.call("Downloading library… %d / %d MB" % [got / 1048576, total_mb]))
	var res: Array = await http.request_completed
	tick.queue_free(); http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		status.call("Bundle download failed (HTTP %d)" % res[1]); return false
	status.call("Extracting…")
	var zr := ZIPReader.new()
	if zr.open(ProjectSettings.globalize_path(tmp)) != OK:
		status.call("Bundle archive unreadable"); return false
	var files := zr.get_files()
	var n := 0
	for f in files:
		if not f.begins_with("highpoly/") or f.ends_with("/"):
			continue
		var dest := "res://" + f
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out:
			out.store_buffer(zr.read_file(f)); out.close(); n += 1
			if n % 1000 == 0: status.call("Extracting… %d / %d files" % [n, files.size()])
	zr.close()
	DirAccess.remove_absolute(tmp)
	EditorInterface.get_resource_filesystem().scan()
	status.call("Installed %d file(s) — first import will take a while…" % n)
	return n > 0

# count of scene proxies the registry can provide (for the prompt)
static func scene_available(root: Node, host: Node, cb: Callable) -> void:
	var url := manifest_url()
	if url == "": cb.call(0); return
	var http := HTTPRequest.new(); host.add_child(http)
	var body := await _fetch(http, url)
	http.queue_free()
	var man: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
	if not (man is Dictionary) or not man.has("props"): cb.call(0); return
	var need := missing_for_scene(root, true, man["props"])
	cb.call(need.size())

# ---------- plugin self-update ----------
# The plugin can update ITSELF (new features / fixes after game patches):
#  - local version  = plugin.cfg [plugin] version
#  - remote version = <registry host>/plugin/plugin-version.json
#                     {"version": "x.y.z", "zip": "plugin/highpoly_toggle.zip", "notes": "..."}
# The zip contains the whole addons/highpoly_toggle/ folder and is extracted
# over the INSTALLED location; a restart of the editor loads the new scripts.

# The plugin's install folder, derived from this script's own path — so the
# plugin works no matter where under addons/ the user placed it (e.g. dropping
# the whole repo zip in nests it one level deeper).
static func plugin_dir() -> String:
	return (HighpolyUpdater as Script).resource_path.get_base_dir()

static func plugin_version() -> String:
	var cf := ConfigFile.new()
	if cf.load(plugin_dir() + "/plugin.cfg") != OK: return "0.0.0"
	return str(cf.get_value("plugin", "version", "0.0.0"))

static func _version_tuple(v: String) -> Array:
	var out: Array = []
	for p in v.split("."):
		out.append(int(p))
	while out.size() < 3:
		out.append(0)
	return out

static func is_newer_version(remote: String, local: String) -> bool:
	var r := _version_tuple(remote)
	var l := _version_tuple(local)
	for i in range(3):
		if r[i] != l[i]: return r[i] > l[i]
	return false

# Check the registry for a newer plugin. cb.call(new_version, notes) — new_version
# is "" when already up to date (or the check failed; fail-quiet by design).
static func check_plugin_update(host: Node, cb: Callable) -> void:
	var base := manifest_url().get_base_dir() + "/"
	var http := HTTPRequest.new(); host.add_child(http)
	var body := await _fetch(http, base + "plugin/plugin-version.json")
	http.queue_free()
	var info: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
	if not (info is Dictionary):
		cb.call("", ""); return
	var remote := str(info.get("version", ""))
	if remote != "" and is_newer_version(remote, plugin_version()):
		cb.call(remote, str(info.get("notes", "")))
	else:
		cb.call("", "")

# Download the plugin zip and extract it over addons/highpoly_toggle/. Running
# scripts stay loaded in memory, so overwriting is safe; the user restarts the
# editor (or disables/re-enables the plugin) to load the new version.
static func update_plugin(host: Node, status: Callable) -> bool:
	var base := manifest_url().get_base_dir() + "/"
	var http := HTTPRequest.new(); host.add_child(http)
	status.call("Downloading plugin update…")
	var body := await _fetch(http, base + "plugin/highpoly_toggle.zip")
	http.queue_free()
	if body.is_empty():
		status.call("Plugin update download failed"); return false
	var tmp := "user://highpoly_plugin_update.zip"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		status.call("Cannot write the update file"); return false
	f.store_buffer(body); f.close()
	var zr := ZIPReader.new()
	if zr.open(ProjectSettings.globalize_path(tmp)) != OK:
		status.call("Update archive unreadable"); return false
	var pdir := plugin_dir()
	var n := 0
	for path in zr.get_files():
		# the zip is rooted at addons/highpoly_toggle/ — ignore anything else,
		# and extract into wherever THIS install actually lives
		if path.ends_with("/") or not path.begins_with("addons/highpoly_toggle/"):
			continue
		var dest := "%s/%s" % [pdir, path.trim_prefix("addons/highpoly_toggle/")]
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out:
			out.store_buffer(zr.read_file(path)); out.close(); n += 1
	zr.close()
	DirAccess.remove_absolute(tmp)
	if n == 0:
		status.call("Update archive had no plugin files"); return false
	status.call("Plugin updated (%d files) — restart the editor to finish" % n)
	return true
