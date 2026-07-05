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

static func _fetch(http: HTTPRequest, url: String) -> PackedByteArray:
	var err := http.request(url)
	if err != OK: return PackedByteArray()
	var res: Array = await http.request_completed
	# res = [result, response_code, headers, body]
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return PackedByteArray()
	return res[3]

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
		var rhash := str(remote.get("hash", ""))
		if rhash != "" and str(sj.get("hash", "")) != rhash:
			to_update.append([prox, str(remote.get("glb", "")), rhash, "%s/%s.glb" % [dir, prox], "hash"])
		var mhash := str(remote.get("med_hash", ""))
		if mhash != "" and mhash != "null" and str(sj.get("med_hash", "")) != mhash:
			to_update.append([prox, str(remote.get("med_glb", "")), mhash, "%s/%s_med.glb" % [dir, prox], "med_hash"])
	if to_update.is_empty():
		status.call("All models up to date"); http.queue_free(); return
	var done := 0
	var failed := 0
	for item in to_update:
		status.call("Downloading %s… (%d/%d)" % [item[0], done + failed + 1, to_update.size()])
		var data := await _fetch(http, base + item[1])
		if data.is_empty():
			failed += 1; continue
		var f := FileAccess.open(item[3], FileAccess.WRITE)
		if f == null: failed += 1; continue
		f.store_buffer(data); f.close()
		var side := "res://highpoly/%s/%s.json" % [item[0], item[0]]
		var sj: Dictionary = {}
		if FileAccess.file_exists(side):
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
			if j is Dictionary: sj = j
		sj[item[4]] = item[2]
		var s := FileAccess.open(side, FileAccess.WRITE)
		if s:
			s.store_string(JSON.stringify(sj)); s.close()
		done += 1
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
		var dir := "res://highpoly/%s" % prox
		var high := "%s/%s.glb" % [dir, prox]
		var med := "%s/%s_med.glb" % [dir, prox]
		var remote: Dictionary = props[prox]
		var missing_high := not FileAccess.file_exists(high)
		var has_med_remote := str(remote.get("med_hash", "")) not in ["", "null"]
		var missing_med := want_med and has_med_remote and not FileAccess.file_exists(med)
		if missing_high or missing_med:
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
		var gh := str(remote.get("hash", ""))
		if gh != "":
			jobs.append([prox, str(remote.get("glb", "")), gh, "%s/%s.glb" % [dir, prox], "hash"])
		var mh := str(remote.get("med_hash", ""))
		if mh != "" and mh != "null":
			jobs.append([prox, str(remote.get("med_glb", "")), mh, "%s/%s_med.glb" % [dir, prox], "med_hash"])
	if jobs.is_empty():
		status.call("No registry models for this scene"); http.queue_free(); return false
	var done := 0; var failed := 0
	for item in jobs:
		status.call("Downloading… (%d/%d)" % [done + failed + 1, jobs.size()])
		var data := await _fetch(http, base + item[1])
		if data.is_empty(): failed += 1; continue
		DirAccess.make_dir_recursive_absolute("res://highpoly/%s" % item[0])
		var f := FileAccess.open(item[3], FileAccess.WRITE)
		if f == null: failed += 1; continue
		f.store_buffer(data); f.close()
		var side := "res://highpoly/%s/%s.json" % [item[0], item[0]]
		var sj: Dictionary = {}
		if FileAccess.file_exists(side):
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
			if j is Dictionary: sj = j
		sj[item[4]] = item[2]
		var s := FileAccess.open(side, FileAccess.WRITE)
		if s: s.store_string(JSON.stringify(sj)); s.close()
		done += 1
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
