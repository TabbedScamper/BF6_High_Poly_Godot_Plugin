@tool
extends RefCounted
class_name HighpolyGameDir

# Where Battlefield 6 is installed, and whether that is actually true.
#
# The plugin used to download everything from a registry, so it never needed to
# know where the game was. It reads from the install now, which makes the game
# folder the one setting that has to be right before anything else can work —
# and the one thing a user can get wrong in a way that produces no useful error
# anywhere else.
#
# VERIFICATION IS NOT "the folder exists". A folder can exist, be named
# "Battlefield 6", and be a shortcut, a partial download, or the wrong drive's
# leftovers. The test is whether the files the reader actually needs are there:
#
#   Data/layout.toc          the manifest every lookup starts from
#   oo2core_9_win64.dll      the decompressor; the container is Oodle Kraken and
#                            Godot cannot read it without this
#
# Both are checked and reported separately, because they fail for different
# reasons and the fixes differ: a missing layout.toc means the wrong folder, a
# missing oo2core means a broken or non-standard install.

const SETTING := "game_dir"

# Where Steam and EA usually put it. Only a starting guess — the picker exists
# because no list covers every machine.
const CANDIDATES := [
	"C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6",
	"C:/Program Files/EA Games/Battlefield 6",
	"C:/Program Files (x86)/EA Games/Battlefield 6",
]

# Parents worth trying ON EVERY FIXED DRIVE, with "Battlefield 6" under them.
#
# Steam publishes its libraries in libraryfolders.vdf, so a Steam install on any
# drive is already found. THE EA APP PUBLISHES NOTHING OF THE SORT and lets you
# install anywhere, so an EA App user on a drive other than C: was invisible to
# every check in this file: a real user's install at I:\Battlefield 6 gated the
# panel off with "No folder chosen yet", repeatedly, while the reader underneath
# was mounting it and working.
#
# One file probe per entry per drive. A machine with three fixed drives pays
# about twenty stats, which is nothing beside the mount that follows.
const DRIVE_PARENTS := [
	"",                                   # X:/Battlefield 6
	"Program Files/EA Games",
	"Program Files (x86)/EA Games",
	"EA Games",
	"Games",
	"SteamLibrary/steamapps/common",      # the usual hand-made Steam library
	"steamapps/common",
]

# EA's own registry record of where it put a game. Origin wrote these and EA
# Desktop kept them; the value name has varied, so several are tried and the
# first that points at a real install wins. Nothing here is trusted without
# verify() agreeing.
const EA_REG_KEYS := [
	"HKLM\\SOFTWARE\\WOW6432Node\\EA Games\\Battlefield 6",
	"HKLM\\SOFTWARE\\EA Games\\Battlefield 6",
	"HKLM\\SOFTWARE\\WOW6432Node\\Electronic Arts\\EA Desktop\\Battlefield 6",
	"HKLM\\SOFTWARE\\Electronic Arts\\EA Desktop\\Battlefield 6",
]


# The saved path, or "" outside the editor.
#
# EditorInterface.get_editor_settings() does not exist in a plain `--script`
# run, and calling it there throws rather than returning null. This module is
# reached from the headless harnesses through autodetect(), so the guard is not
# defensive padding: without it every harness run printed a script error and
# silently lost whatever folder the user had chosen, falling through to the
# hardcoded candidate paths instead.
static func _settings():
	# Three probes were needed to land this, which is worth recording:
	#   EditorInterface.has_method(...)   throws — outside the editor the
	#                                     identifier is a bare class, no instance
	#   Engine.has_singleton(...)         returns TRUE headlessly anyway
	#   Engine.get_singleton(...)         returns a NULL instance
	# So the only reliable test is the instance itself.
	if not Engine.has_singleton("EditorInterface"):
		return null
	var ei = Engine.get_singleton("EditorInterface")
	if ei == null:
		return null
	return ei.get_editor_settings()


# Public because the READER needs the same Steam root the gate uses: see
# BF6Container.find_game, where a hard-coded C: path was one half of a
# split-brain discovery bug.
static func steam_root() -> String:
	return _steam_root()


static func saved() -> String:
	var es = _settings()
	if es == null:
		return ""
	return str(es.get_project_metadata("highpoly_mapctx", SETTING, ""))


static func save(path: String) -> void:
	var es = _settings()
	if es == null:
		return
	es.set_project_metadata("highpoly_mapctx", SETTING, path)


# -> {ok: bool, layout: bool, oodle: bool, path: String, why: String}
static func verify(path: String) -> Dictionary:
	var r := {"ok": false, "layout": false, "oodle": false, "path": path,
			  "why": ""}
	if path == "":
		r["why"] = "No folder chosen yet."
		return r
	if not DirAccess.dir_exists_absolute(path):
		r["why"] = "That folder does not exist."
		return r
	r["layout"] = FileAccess.file_exists(path.path_join("Data/layout.toc"))
	r["oodle"] = FileAccess.file_exists(path.path_join("oo2core_9_win64.dll"))
	if not r["layout"]:
		r["why"] = ("No Data/layout.toc in that folder, so it is not a "
				+ "Battlefield 6 install. Pick the folder that CONTAINS Data, "
				+ "not Data itself.")
		return r
	if not r["oodle"]:
		r["why"] = ("Found the game data but not oo2core_9_win64.dll, which is "
				+ "what decompresses it. The install looks incomplete — "
				+ "verifying the game files usually restores it.")
		return r
	r["ok"] = true
	r["why"] = "Battlefield 6 found."
	return r


# Steam's own install root, from its registry keys. The candidate list only
# knew C:\Program Files (x86)\Steam, so a Steam living on another drive -
# common where C: is a small system SSD, and how a real user's working
# install on D: read as "Battlefield 6 not detected" - autodetected nothing.
# The registry says where Steam actually is; its libraryfolders.vdf then
# names every library on every drive. reg.exe value NAMES are not localised,
# so the parse is safe on any Windows language.
static func _steam_root() -> String:
	for args in [
			["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"],
			["query", "HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam",
				"/v", "InstallPath"]]:
		var out := []
		if OS.execute("reg", args, out) != 0 or out.is_empty():
			continue
		for line in str(out[0]).split("\n"):
			var at := line.findn("REG_SZ")
			if at < 0:
				continue
			var p := line.substr(at + 6).strip_edges().replace("\\", "/")
			if p != "" and DirAccess.dir_exists_absolute(p):
				return p
	return ""


# The best guess available without asking: whatever was saved, then the usual
# install locations, then Steam's registry-located root and every library
# listed in its libraryfolders.vdf - which is what finds a game on D: or E:.
# EVERY FIXED DRIVE ON THE MACHINE, as "C:", "D:" and so on.
#
# There is no drive enumeration in Godot, so this asks the filesystem: a letter
# whose root directory opens is a drive that exists. Removable and network
# letters answer too, which is fine - a probe on one costs a failed stat and the
# game genuinely can live on an external disk.
static func _drives() -> Array[String]:
	var out: Array[String] = []
	for c in "CDEFGHIJKLMNOPQRSTUVWXYZAB":
		var root := "%s:/" % c
		if DirAccess.dir_exists_absolute(root):
			out.append("%s:" % c)
	return out


# What EA's own registry says, or "". Origin wrote these keys and EA Desktop
# kept them, but the VALUE NAME has moved around between launcher versions, so
# every plausible one is read and the first that resolves wins.
static func _ea_registry() -> Array[String]:
	var out: Array[String] = []
	for key in EA_REG_KEYS:
		var res := []
		# No /v: dump the whole key and take any REG_SZ that looks like a path,
		# which survives the value being called "Install Dir" on one launcher
		# version and "InstallLocation" on the next.
		if OS.execute("reg", ["query", key], res) != 0 or res.is_empty():
			continue
		for line in str(res[0]).split("\n"):
			var at := line.findn("REG_SZ")
			if at < 0:
				continue
			var p := line.substr(at + 6).strip_edges().replace("\\", "/")
			if p.length() > 3 and DirAccess.dir_exists_absolute(p):
				out.append(p)
	return out


static func autodetect() -> String:
	var s := saved()
	if s != "" and bool(verify(s)["ok"]):
		return s
	var seen: Array[String] = []
	seen.assign(CANDIDATES)
	# EA's registry first among the guesses: it is a statement rather than a
	# hunch, and it costs one reg.exe call per key.
	seen.append_array(_ea_registry())
	var vdfs: Array[String] = [
		"C:/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"]
	var sr := _steam_root()
	if sr != "":
		seen.append(sr.path_join("steamapps/common/Battlefield 6"))
		vdfs.append(sr.path_join("steamapps/libraryfolders.vdf"))
	for vdf in vdfs:
		if not FileAccess.file_exists(vdf):
			continue
		var txt := FileAccess.get_file_as_string(vdf)
		var re := RegEx.create_from_string('"path"\\s+"([^"]+)"')
		for m in re.search_all(txt):
			var base: String = m.get_string(1).replace("\\\\", "/").replace("\\", "/")
			seen.append(base.path_join("steamapps/common/Battlefield 6"))
	# THE DRIVE SWEEP LAST, because it is the guess of last resort and the only
	# one that finds an EA App install nobody predicted. Everything above is
	# either a statement (the saved path, EA's registry, Steam's library list)
	# or a well known default; this is us looking.
	for d in _drives():
		for parent in DRIVE_PARENTS:
			seen.append(d.path_join(parent).path_join("Battlefield 6")
				if parent != "" else d.path_join("Battlefield 6"))
	for p in seen:
		if bool(verify(p)["ok"]):
			return p
	return ""
