@tool
extends RefCounted
class_name HighpolyIntegrity

# IS THIS INSTALL THE ONE WE SHIPPED?
#
# The addon has always written package-manifest.json - a SHA256 for every file
# it installs - and until 2026-09-17 nothing ever read it. When a user's install
# lost files, the editor reported it as 291 GDScript parse errors and silently
# disabled the plugin. The evidence needed to say "five files are missing,
# reinstall" was sitting in the addon folder the whole time.
#
# WHAT IT CAN AND CANNOT CATCH. A file that is absent or altered is found here
# and named. A file missing so early that this very script cannot load is not:
# highpoly_toggle.gd preloads its dependencies, and preload() of a missing path
# is a compile error before any code runs. So this covers the common damaged
# install - some files lost, the entry script still compiling - and honestly
# does not cover a total one. For that case the out-of-editor checker
# (tools/Check High-Poly Install.bat) is the answer, because it does not need
# the plugin to load at all.
#
# Hashing 190 files costs real time, so verify() is never called on the startup
# path by default; check_fast() compares presence and size only, which is what
# a lost-files install actually fails.

const MANIFEST := "res://addons/highpoly_toggle/package-manifest.json"

## One problem found with the install.
class Problem extends RefCounted:
	var path: String
	var kind: String   # "missing" or "changed"
	func _init(p: String, k: String) -> void:
		path = p
		kind = k
	func _to_string() -> String:
		return "%s  %s" % [kind.to_upper(), path]


static func _manifest_files() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST):
		return {}
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var files: Variant = (parsed as Dictionary).get("files", {})
	return files if typeof(files) == TYPE_DICTIONARY else {}


## Files the manifest lists that are not on disk. Cheap: no hashing.
## This is the startup check, because a lost file is the failure that disables
## the plugin, and presence is the whole question there.
static func missing_files() -> PackedStringArray:
	var out := PackedStringArray()
	for rel in _manifest_files().keys():
		if not FileAccess.file_exists("res://" + String(rel)):
			out.append(String(rel))
	return out


## Every problem, hashing each file. Costs a second or two over 190 files, so
## this is for the diagnostics panel and the report, not for startup.
static func verify() -> Array:
	var problems: Array = []
	for rel in _manifest_files().keys():
		var path := "res://" + String(rel)
		if not FileAccess.file_exists(path):
			problems.append(Problem.new(String(rel), "missing"))
			continue
		var want := String(_manifest_files()[rel]).to_lower()
		var got := FileAccess.get_sha256(path).to_lower()
		if got != want:
			problems.append(Problem.new(String(rel), "changed"))
	return problems


## True when there is no manifest to check against. Treated as "cannot say",
## never as "damaged": a user who installed by hand from source has no manifest
## and is not broken.
static func manifest_present() -> bool:
	return not _manifest_files().is_empty()


## The message to show a user whose install has lost files. Written to be acted
## on rather than reported: it says what is wrong and what to do about it.
static func describe(missing: PackedStringArray) -> String:
	var lines := PackedStringArray()
	lines.append("The BF6 High-Poly install is missing %d file(s)." % missing.size())
	lines.append("")
	var shown := 0
	for m in missing:
		if shown >= 12:
			lines.append("  ... and %d more" % (missing.size() - shown))
			break
		lines.append("  " + m.get_file())
		shown += 1
	lines.append("")
	lines.append("This usually means an update did not finish, or a download")
	lines.append("was interrupted.")
	lines.append("")
	lines.append("TO FIX: close Godot, DELETE the whole folder")
	lines.append("  " + ProjectSettings.globalize_path("res://addons/highpoly_toggle"))
	lines.append("then install the plugin again. Updating over it will NOT")
	lines.append("repair it - an update overwrites files, it does not restore")
	lines.append("ones that are missing.")
	return "\n".join(lines)


## Write what we know to a file the user can send back, and return its path.
##
## WHY A FILE. The failure this reports can also present as a wall of GDScript
## parse errors with the real cause scrolled off the top - on 2026-09-17 a
## user's log carried 291 of them above the twelve lines that actually named the
## missing files. A single artifact with the answer already extracted is the
## difference between a diagnosis and an afternoon of reading someone's log.
##
## Returns "" if it could not be written, which is never treated as fatal: the
## report is a convenience, not the check.
static func write_report(missing: PackedStringArray) -> String:
	var path := "user://highpoly-install-report.txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	var lines := PackedStringArray()
	lines.append("BF6 High-Poly install report")
	lines.append("generated   " + Time.get_datetime_string_from_system())
	lines.append("plugin      " + _plugin_version())
	lines.append("godot       " + str(Engine.get_version_info().get("string", "?")))
	lines.append("addon at    " + ProjectSettings.globalize_path(
		"res://addons/highpoly_toggle"))
	lines.append("manifest    " + ("present" if manifest_present() else "MISSING"))
	lines.append("")
	lines.append("MISSING FILES (%d):" % missing.size())
	for m in missing:
		lines.append("  " + String(m))
	lines.append("")
	lines.append(describe(missing))
	f.store_string("\n".join(lines) + "\n")
	f.close()
	return ProjectSettings.globalize_path(path)


static func _plugin_version() -> String:
	var cf := ConfigFile.new()
	if cf.load("res://addons/highpoly_toggle/plugin.cfg") != OK:
		return "?"
	return str(cf.get_value("plugin", "version", "?"))
