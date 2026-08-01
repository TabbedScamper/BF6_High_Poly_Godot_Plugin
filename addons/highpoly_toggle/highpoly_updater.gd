@tool
extends RefCounted
class_name HighpolyUpdater
# Registry plumbing shared by the sync manager + map context (manifest URL,
# throttling-aware fetch) and the plugin's SELF-update. Model downloading
# itself moved to highpoly_sync.gd in 1.5 — models now sync automatically in
# the background instead of behind buttons.

const SETTING := "highpoly/manifest_url"
const DEFAULT_MANIFEST := "https://pub-45114dae448e4a059f488662e3d47b19.r2.dev/plugin-manifest.json"

# Godot's HTTPRequest.timeout defaults to 0 = wait forever. A connection that is
# accepted and then goes quiet (dropped wifi, a NAT that forgets the flow, r2.dev
# holding a throttled socket) never fires request_completed, so `await` never
# returns and the caller is wedged for the rest of the session. Every request
# here gets a deadline; a timeout surfaces as RESULT_TIMEOUT, which the retry
# loops below already treat as a normal retryable failure.
const FETCH_TIMEOUT := 120.0     # a single model GLB / small payload
const HEAD_TIMEOUT := 30.0       # metadata only
const Log = preload("highpoly_log.gd")

static func manifest_url() -> String:
	if ProjectSettings.has_setting(SETTING):
		return str(ProjectSettings.get_setting(SETTING))
	return DEFAULT_MANIFEST

# GET with retry/backoff — the public r2.dev host throttles rapid bursts, so a
# single failed attempt (403/429/5xx) is usually transient.
static func _fetch(http: HTTPRequest, url: String) -> PackedByteArray:
	http.timeout = FETCH_TIMEOUT
	for attempt in range(4):
		if attempt > 0:
			# 0.4s, 0.8s, 1.6s between retries
			await http.get_tree().create_timer(0.4 * pow(2, attempt - 1)).timeout
		var rq := http.request(url)
		if rq != OK:
			Log.warn("Could not start download of %s — %s" % [url, error_string(rq)])
			continue
		var res: Array = await http.request_completed
		# res = [result, response_code, headers, body]
		if res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200:
			return res[3]
	return PackedByteArray()

# HEAD request returning the response ETag ("" on failure) — used by map
# context to detect republished map packages without downloading them.
static func remote_etag(http: HTTPRequest, url: String) -> String:
	http.timeout = HEAD_TIMEOUT
	for attempt in range(3):
		if attempt > 0:
			await http.get_tree().create_timer(0.4 * pow(2, attempt - 1)).timeout
		var rqh := http.request(url, PackedStringArray(), HTTPClient.METHOD_HEAD)
		if rqh != OK:
			Log.warn("Could not check %s for a newer version — %s" % [url, error_string(rqh)])
			continue
		var res: Array = await http.request_completed
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
			continue
		for h in res[2]:
			var s := String(h)
			if s.to_lower().begins_with("etag:"):
				return s.substr(5).strip_edges()
		return ""
	return ""

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
# ---------- files that used to be part of the plugin ----------
# An update overwrites what is in the zip and touches nothing else, so a file
# that has been REMOVED from the plugin stays on disk forever. None of these do
# harm — nothing references them and they still parse — but they are litter in
# a folder people read, and a stale class_name stays registered in the editor.
#
# Add a name here whenever one is deleted. The list is explicit rather than
# "anything not in the zip": this deletes from the user's addons folder, and
# the blast radius of a wrong answer there is somebody's install.
const REMOVED_FILES := [
	"highpoly_jobbars.gd",     # 1.21.0: one universal bar replaced the stacked ones
	"highpoly_turbo.gd",       # long gone
]

# Returns how many it removed. Safe by construction: named files only, only
# inside the plugin's own folder, never directories.
static func sweep_removed() -> int:
	var dir := plugin_dir()
	var n := 0
	var names: PackedStringArray = []
	for f in REMOVED_FILES:
		var p := "%s/%s" % [dir, f]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
			names.append(f)
			n += 1
		# Godot writes a .uid beside every script; it outlives the script it
		# belonged to and points at nothing
		var uid := p + ".uid"
		if FileAccess.file_exists(uid):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(uid))
	if n > 0:
		Log.info("Tidied %d file(s) left behind by an earlier version: %s"
			% [n, ", ".join(names)])
	return n

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
	var zerr := zr.open(ProjectSettings.globalize_path(tmp))
	if zerr != OK:
		Log.error("Plugin update downloaded but the archive would not open — %s"
			% error_string(zerr))
	if zerr != OK:
		status.call("Update archive unreadable"); return false
	var pdir := plugin_dir()
	var n := 0
	for path in zr.get_files():
		# the zip is rooted at addons/highpoly_toggle/ — ignore anything else,
		# and extract into wherever THIS install actually lives
		if path.ends_with("/") or not path.begins_with("addons/highpoly_toggle/"):
			continue
		var dest := "%s/%s" % [pdir, path.trim_prefix("addons/highpoly_toggle/")]
		HighpolyStore.ensure_dir(dest.get_base_dir())
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out:
			out.store_buffer(zr.read_file(path)); out.close(); n += 1
	zr.close()
	DirAccess.remove_absolute(tmp)
	if n == 0:
		status.call("Update archive had no plugin files"); return false
	status.call("Plugin updated (%d files) — restart the editor to finish" % n)
	return true
