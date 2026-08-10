@tool
extends RefCounted
class_name HighpolyUpdater
# The plugin's SELF-update, and a throttling-aware fetch. Nothing else: model
# downloading went to highpoly_sync.gd in 1.5, and in 2.0 there stopped being
# any models to download at all — everything is read from the player's install.
#
# THE R2 REGISTRY IS GONE, and so is the last thing that pointed at it. Updates
# come from GitHub Releases (see github_latest). What used to sit here was a
# manifest URL on an R2 bucket plus a manifest_url() that nothing called any
# more — a const naming a host that now answers 404, kept alive by inertia.
# Left in place it would eventually be read as "the plugin still needs that
# bucket", which is the wrong conclusion: no part of this plugin fetches
# anything from R2.
#
# The one thing that URL still mattered for is people on v2.0.2 and earlier,
# whose build knows no other address and so cannot be offered an update at all.
# That is a one-off problem belonging to those installs, and it cannot be fixed
# from inside a version they are not running.

# Godot's HTTPRequest.timeout defaults to 0 = wait forever. A connection that is
# accepted and then goes quiet (dropped wifi, a NAT that forgets the flow, a CDN
# holding a throttled socket) never fires request_completed, so `await` never
# returns and the caller is wedged for the rest of the session. Every request
# here gets a deadline; a timeout surfaces as RESULT_TIMEOUT, which the retry
# loops below already treat as a normal retryable failure.
# NOT a transfer deadline. HTTPRequest.timeout caps the WHOLE transfer, which
# turns into a hard ceiling on file size: nothing larger than
# (your bandwidth x the timeout) can ever finish, however healthy the connection.
# At 120 s that ceiling sat right in the middle of the library. A user on a
# ~2 MB/s line lost every model over ~230 MB, four times each, deterministically:
#
#   Area06_Building_02_B  332.5 MB  failed      Area06_Building_03_B  214.8 MB  ok
#   Area04_Building_02    304.3 MB  failed      Area03_Building_01    164.8 MB  ok
#   Area06_Building_01_B  298.5 MB  failed
#   Area04_Building_01    245.9 MB  failed      4 attempts x 120 s = 480 s, and
#   Area04_Building_03    233.2 MB  failed      they failed at 8m02-8m04.
#
# The five that failed were the five largest, and the retries restarted from
# byte zero, so several GB were downloaded to deliver nothing. Failed models are
# then skipped for the session, so the map renders with its biggest buildings
# missing and does the same thing again next launch.
#
# What we actually care about is a transfer that stops MOVING. So: no whole-
# transfer cap, watch the byte counter instead. highpoly_mapcontext.gd already
# does exactly this for map packages and says so in a comment; the model path
# never got the same treatment.
const STALL_SECS := 45.0         # no new bytes for this long = dead socket
const MAX_TRANSFER := 1800.0     # backstop so a trickling socket cannot wedge a session
const HEAD_TIMEOUT := 30.0       # metadata only
const Log = preload("highpoly_log.gd")

# GET with retry/backoff. api.github.com rate-limits anonymous callers to 60 an
# hour per address and objects.githubusercontent.com can refuse a burst, so a
# single failed attempt (403/429/5xx) is usually transient.
static func _fetch(http: HTTPRequest, url: String,
		headers := PackedStringArray()) -> PackedByteArray:
	# Every fetch in the plugin funnels through here, so this is the one place
	# worth setting. HTTPRequest.use_threads defaults to false, which services
	# the socket from _process on the MAIN thread: downloads then run at the rate
	# the editor renders frames, and the plugin downloads precisely while it is
	# building overlays and tanking that frame rate. Safe to set here because no
	# request is in flight yet on this node.
	http.use_threads = true
	http.timeout = 0.0            # see STALL_SECS: a size ceiling, not a safety net
	for attempt in range(4):
		if attempt > 0:
			# 0.4s, 0.8s, 1.6s between retries
			await http.get_tree().create_timer(0.4 * pow(2, attempt - 1)).timeout
		var state := {"done": false, "res": []}
		# Held in a var so it can be disconnected again: CONNECT_ONE_SHOT only
		# cleans up when the signal FIRES, and cancel_request() does not fire it.
		# Without this, a stalled attempt would leave its callback attached and
		# the next attempt would resolve into the previous attempt's state.
		var on_done := func(r: int, c: int, h: PackedStringArray, b: PackedByteArray):
			state["done"] = true
			state["res"] = [r, c, h, b]
		http.request_completed.connect(on_done, CONNECT_ONE_SHOT)
		var rq := http.request(url, headers)
		if rq != OK:
			Log.warn("Could not start download of %s: %s" % [url, error_string(rq)])
			if http.request_completed.is_connected(on_done):
				http.request_completed.disconnect(on_done)
			continue
		# Poll fast at first and back off. A small JSON payload lands inside the
		# first tick or two, so this costs it ~50 ms rather than a fixed poll
		# interval x thousands of models; a long transfer settles at 1 s.
		var poll := 0.05
		var idle := 0.0
		var spent := 0.0
		var last := 0
		while not state["done"]:
			await http.get_tree().create_timer(poll).timeout
			spent += poll
			var d := http.get_downloaded_bytes()
			if d > last:
				last = d
				idle = 0.0
			else:
				idle += poll
			poll = minf(poll * 1.6, 1.0)
			if idle >= STALL_SECS or spent >= MAX_TRANSFER:
				http.cancel_request()
				Log.warn("download stalled after %s (%s), retrying: %s"
					% [Log.human_bytes(last), "no data for %ds" % int(idle)
						if idle >= STALL_SECS else "over time", url])
				break
		if http.request_completed.is_connected(on_done):
			http.request_completed.disconnect(on_done)
		if not state["done"]:
			continue
		var res: Array = state["res"]
		# res = [result, response_code, headers, body]
		# WHAT THE SERVER ACTUALLY SAID, kept for the caller.
		#
		# An empty return means "no usable body" and nothing else, so every
		# caller had to describe the failure as "could not reach" - which is a
		# lie when the host answered immediately with a 404. That exact wording
		# would have sent someone checking their internet connection over a
		# private repository.
		_last_status = int(res[1])
		_last_body = res[3]
		if res[0] == HTTPRequest.RESULT_SUCCESS and res[1] == 200:
			return res[3]
	return PackedByteArray()


# The HTTP status of the most recent _fetch, and its body even when it failed.
# 0 means the request never got an answer at all.
static var _last_status := 0
static var _last_body := PackedByteArray()

# GET straight to disk. Same retry/stall behaviour as _fetch, but the bytes go
# to a file instead of a PackedByteArray, so a 300 MB model costs no RAM.
#
# WHY IT MATTERS BEYOND MEMORY: _fetch holds the whole body, and every worker
# holds its own. At 8 workers on 200-330 MB buildings that is a multi-GB spike
# with nothing to show for it, which is the most credible explanation for the
# un-logged crashes. Streaming removes the ceiling on both file size and worker
# count at once, which is what makes raising MAX_WORKERS safe.
#
# Writes to <dest>.part and renames on success. download_file points straight at
# its target, so a transfer that dies half way would otherwise leave a truncated
# GLB sitting exactly where a valid one belongs.
static func fetch_to_file(http: HTTPRequest, url: String, dest: String) -> bool:
	http.use_threads = true
	http.timeout = 0.0
	var part := dest + ".part"
	for attempt in range(4):
		if attempt > 0:
			await http.get_tree().create_timer(0.4 * pow(2, attempt - 1)).timeout
		http.download_file = part
		var state := {"done": false, "ok": false}
		var on_done := func(r: int, c: int, _h: PackedStringArray, _b: PackedByteArray):
			state["done"] = true
			state["ok"] = r == HTTPRequest.RESULT_SUCCESS and c == 200
		http.request_completed.connect(on_done, CONNECT_ONE_SHOT)
		if http.request(url) != OK:
			if http.request_completed.is_connected(on_done):
				http.request_completed.disconnect(on_done)
			continue
		var poll := 0.05
		var idle := 0.0
		var spent := 0.0
		var last := 0
		while not state["done"]:
			await http.get_tree().create_timer(poll).timeout
			spent += poll
			var d := http.get_downloaded_bytes()
			if d > last:
				last = d
				idle = 0.0
			else:
				idle += poll
			poll = minf(poll * 1.6, 1.0)
			if idle >= STALL_SECS or spent >= MAX_TRANSFER:
				http.cancel_request()
				Log.warn("download stalled after %s, retrying: %s"
					% [Log.human_bytes(last), url])
				break
		if http.request_completed.is_connected(on_done):
			http.request_completed.disconnect(on_done)
		if bool(state["ok"]):
			if FileAccess.file_exists(dest):
				DirAccess.remove_absolute(dest)
			if DirAccess.rename_absolute(part, dest) == OK:
				return true
			Log.warn("could not move the finished download into place: %s" % dest)
			return false
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	return false


# HEAD request returning the response ETag ("" on failure) — used by map
# context to detect republished map packages without downloading them.
static func remote_etag(http: HTTPRequest, url: String) -> String:
	http.timeout = HEAD_TIMEOUT
	for attempt in range(3):
		if attempt > 0:
			await http.get_tree().create_timer(0.4 * pow(2, attempt - 1)).timeout
		var rqh := http.request(url, PackedStringArray(), HTTPClient.METHOD_HEAD)
		if rqh != OK:
			Log.warn("Could not check %s for a newer version: %s" % [url, error_string(rqh)])
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

# GITHUB RELEASES AS THE SOURCE OF TRUTH FOR "IS THERE A NEWER ONE".
#
# The releases already carry everything the check needs - a version in the tag,
# the notes in the body, and the zip as an asset - so there is nothing to publish
# separately and nothing that can drift out of step with what people actually
# download. The old path needed plugin-version.json and the zip uploaded to a
# bucket by hand, in that order, and a mismatch between them sent every client
# to a 404.
#
# THE REPO MUST BE PUBLIC. api.github.com answers 404, not 403, for a private
# repo to an unauthenticated caller - indistinguishable from "no releases yet" -
# so the failure is reported rather than swallowed. No token is used or wanted:
# an update check must not need credentials from the person being updated.
const GITHUB_REPO := "TabbedScamper/BF6_High_Poly_Godot_Plugin"
const GITHUB_LATEST := "https://api.github.com/repos/%s/releases/latest"
const ZIP_ASSET := "highpoly_toggle.zip"
const GITHUB_SETTING := "highpoly/github_repo"

# Where the last check found the zip. Held so the download uses the asset that
# belongs to the version that was offered, rather than re-deriving a URL and
# possibly fetching a different build.
static var _zip_url := ""


static func github_repo() -> String:
	if ProjectSettings.has_setting(GITHUB_SETTING):
		var s := str(ProjectSettings.get_setting(GITHUB_SETTING))
		if s != "":
			return s
	return GITHUB_REPO


# -> {version, notes, zip} or {} with `error` explaining why not.
static func github_latest(host: Node) -> Dictionary:
	var http := HTTPRequest.new()
	host.add_child(http)
	# GitHub rejects a request with no User-Agent. Godot sends one, but naming
	# ourselves means their rate-limit logs can tell this plugin apart from
	# every other Godot project on the same address.
	var body := await _fetch(http, GITHUB_LATEST % github_repo(),
		PackedStringArray(["User-Agent: bf6-highpoly-preview",
			"Accept: application/vnd.github+json"]))
	http.queue_free()
	if body.is_empty():
		# Distinguish the three, because they need three different fixes.
		if _last_status == 0:
			return {"error": "no answer from api.github.com (offline, or a "
				+ "firewall blocking it)"}
		if _last_status == 404:
			return {"error": "api.github.com returned 404 for %s. An anonymous "
				% github_repo() + "check gets 404 for a PRIVATE repository just "
				+ "as it does for one with no releases, so the usual cause is "
				+ "that the repository is not public."}
		if _last_status == 403:
			return {"error": "api.github.com returned 403, which is normally its "
				+ "rate limit (60 checks an hour per address). It will work "
				+ "again shortly."}
		return {"error": "api.github.com returned HTTP %d" % _last_status}
	var info: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (info is Dictionary):
		return {"error": "github returned something that is not a release"}
	var d: Dictionary = info
	if d.has("message") and not d.has("tag_name"):
		# 404 here means private OR no releases, and those need different fixes.
		return {"error": "github says: %s (a PRIVATE repo answers 404 to an "
			% str(d["message"]) + "anonymous check, so this is what a private "
			+ "repo looks like as well as an empty one)"}
	var tag := str(d.get("tag_name", ""))
	var ver := tag.trim_prefix("v")
	var zip := ""
	for a in (d.get("assets", []) as Array):
		if str((a as Dictionary).get("name", "")) == ZIP_ASSET:
			zip = str((a as Dictionary).get("browser_download_url", ""))
			break
	if ver == "":
		return {"error": "the latest release has no tag"}
	if zip == "":
		return {"error": "release %s has no %s attached" % [tag, ZIP_ASSET]}
	return {"version": ver, "notes": str(d.get("body", "")), "zip": zip}


# Check for a newer plugin. cb.call(new_version, notes) — new_version is "" when
# already up to date or the check failed.
static func check_plugin_update(host: Node, cb: Callable) -> void:
	var got := await github_latest(host)
	if got.has("error"):
		# Said out loud rather than failing quiet. An updater that silently does
		# nothing is indistinguishable from one that has nothing to offer, and
		# this one was broken for every user for two releases without a word.
		HighpolyLog.warn("update check failed: %s" % str(got["error"]))
		cb.call("", "")
		return
	var remote := str(got.get("version", ""))
	if remote != "" and is_newer_version(remote, plugin_version()):
		_zip_url = str(got.get("zip", ""))
		cb.call(remote, str(got.get("notes", "")))
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
	"highpoly_migrate.gd",  # 2.0: it migrated the 1.4 DOWNLOAD layout
	"highpoly_sync.gd",     # 2.0: nothing is downloaded, everything is read
	                        #      from the player's own install
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
	# The asset the CHECK found, not a URL rebuilt here. Deriving it a second
	# time is how a client ends up downloading a different build from the one it
	# was told about.
	var url := _zip_url
	if url == "":
		var got := await github_latest(host)
		if got.has("error"):
			status.call("Update failed: %s" % str(got["error"]))
			return false
		url = str(got.get("zip", ""))
	var http := HTTPRequest.new(); host.add_child(http)
	status.call("Downloading plugin update…")
	# browser_download_url redirects to GitHub's asset host; HTTPRequest follows
	# up to max_redirects, which is 8 by default.
	var body := await _fetch(http, url,
		PackedStringArray(["User-Agent: bf6-highpoly-preview"]))
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
		Log.error("Plugin update downloaded but the archive would not open: %s"
			% error_string(zerr))
	if zerr != OK:
		status.call("Update archive unreadable"); return false
	var pdir := plugin_dir()
	var n := 0
	var same := 0
	var locked: Array = []
	for path in zr.get_files():
		# the zip is rooted at addons/highpoly_toggle/ — ignore anything else,
		# and extract into wherever THIS install actually lives
		if path.ends_with("/") or not path.begins_with("addons/highpoly_toggle/"):
			continue
		var dest := "%s/%s" % [pdir, path.trim_prefix("addons/highpoly_toggle/")]
		var bytes := zr.read_file(path)
		# UNCHANGED FILES ARE NOT REWRITTEN. Most of an update is identical
		# bytes - and one of them, waves.ogv, is held OPEN by the panel's own
		# video player, so writing it fails with "file in use" and puts a Load
		# Error in every updating user's face over a file that did not change.
		# Hash first; write only what moved.
		if FileAccess.file_exists(dest):
			var hc := HashingContext.new()
			hc.start(HashingContext.HASH_MD5)
			hc.update(bytes)
			if hc.finish().hex_encode() == FileAccess.get_md5(dest):
				same += 1
				continue
		HighpolyStore.ensure_dir(dest.get_base_dir())
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if out:
			out.store_buffer(bytes); out.close(); n += 1
		else:
			# A CHANGED file that cannot be written - still held open by
			# something. Not an update failure: everything else applied, and
			# the restart the button already asks for releases the lock.
			# Named, so the log says which file waits.
			locked.append(path.get_file())
	zr.close()
	DirAccess.remove_absolute(tmp)
	if n == 0 and same == 0:
		status.call("Update archive had no plugin files"); return false
	var msg := "Plugin updated (%d changed, %d already current)." % [n, same]
	if not locked.is_empty():
		msg += " %d file(s) in use will apply on restart: %s." % [locked.size(),
			", ".join(PackedStringArray(locked))]
	status.call(msg + " Restart the editor to finish.")
	return true
