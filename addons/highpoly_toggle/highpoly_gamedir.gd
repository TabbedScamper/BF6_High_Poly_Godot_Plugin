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


static func saved() -> String:
	var v: Variant = EditorInterface.get_editor_settings().get_project_metadata(
			"highpoly_mapctx", SETTING, "")
	return str(v)


static func save(path: String) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(
			"highpoly_mapctx", SETTING, path)


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


# The best guess available without asking: whatever was saved, then the usual
# install locations, then every Steam library listed in libraryfolders.vdf.
static func autodetect() -> String:
	var s := saved()
	if s != "" and bool(verify(s)["ok"]):
		return s
	var seen: Array[String] = []
	seen.assign(CANDIDATES)
	var vdf := "C:/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
	if FileAccess.file_exists(vdf):
		var txt := FileAccess.get_file_as_string(vdf)
		var re := RegEx.create_from_string('"path"\\s+"([^"]+)"')
		for m in re.search_all(txt):
			var base: String = m.get_string(1).replace("\\\\", "/").replace("\\", "/")
			seen.append(base.path_join("steamapps/common/Battlefield 6"))
	for p in seen:
		if bool(verify(p)["ok"]):
			return p
	return ""
