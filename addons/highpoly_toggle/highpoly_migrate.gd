@tool
extends RefCounted
class_name HighpolyMigrate
# One-time reorganization of pre-1.5 installs: move models out of
# res://highpoly (where every GLB cost an editor import) into the user://
# store. Shown to the user as a wizard with real numbers BEFORE anything is
# touched; idempotent (a crash mid-move just re-runs — moved files are
# skipped); store.json is only written as entries land, and legacy mode stays
# fully usable until the user confirms.

const LEGACY_DIR := "res://highpoly"

static func legacy_present() -> bool:
	var da := DirAccess.open(LEGACY_DIR)
	return da != null and da.get_directories().size() > 0

static func needed() -> bool:
	return legacy_present() and not HighpolyStore.initialized()

# Pre-scan for the wizard dialog. Nothing is modified.
# {models, model_bytes, med_files, med_bytes, import_files, obj_only, total_files}
static func scan() -> Dictionary:
	var out := {"models": 0, "model_bytes": 0, "med_files": 0, "med_bytes": 0,
		"import_files": 0, "obj_only": 0, "total_files": 0}
	var da := DirAccess.open(LEGACY_DIR)
	if da == null: return out
	for sub in da.get_directories():
		var dir := "%s/%s" % [LEGACY_DIR, sub]
		var glb := "%s/%s.glb" % [dir, sub]
		var has_glb := FileAccess.file_exists(glb)
		if has_glb:
			out.models += 1
			out.model_bytes += _fsize(glb)
		elif FileAccess.file_exists("%s/%s.obj" % [dir, sub]):
			out.obj_only += 1
		for f in DirAccess.get_files_at(dir):
			out.total_files += 1
			if f.ends_with(".import"):
				out.import_files += 1
			elif f.ends_with("_med.glb"):
				out.med_files += 1
				out.med_bytes += _fsize("%s/%s" % [dir, f])
	return out

static func _fsize(p: String) -> int:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null: return 0
	var n := f.get_length()
	f.close()
	return n

# Execute the migration. host is any in-tree node (used to yield so the
# editor stays responsive); status gets human progress lines.
# Returns {moved, deleted, redownload: Array[String]}.
static func run(host: Node, status: Callable) -> Dictionary:
	var moved := 0
	var deleted := 0
	var redl: Array = []
	DirAccess.make_dir_recursive_absolute(HighpolyStore.MODELS_DIR)
	var da := DirAccess.open(LEGACY_DIR)
	if da == null:
		return {"moved": 0, "deleted": 0, "redownload": redl}
	var subs := da.get_directories()
	var i := 0
	for sub in subs:
		i += 1
		if i % 20 == 0:
			status.call("Reorganizing… %d / %d" % [i, subs.size()])
			await host.get_tree().process_frame
		var dir := "%s/%s" % [LEGACY_DIR, sub]
		var glb := "%s/%s.glb" % [dir, sub]
		# carry the sidecar's hash + nofit into the store index; a missing or
		# empty hash simply means the sync manager re-verifies it against the
		# manifest (worst case: one re-download, never a wrong model)
		var h := ""
		var nofit := false
		var side := "%s/%s.json" % [dir, sub]
		if FileAccess.file_exists(side):
			var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(side))
			if j is Dictionary:
				h = str((j as Dictionary).get("hash", ""))
				nofit = bool((j as Dictionary).get("nofit", false))
		if FileAccess.file_exists(glb):
			if _move_file(glb, HighpolyStore.model_path(sub)):
				HighpolyStore.record(sub, h, nofit)
				moved += 1
		elif FileAccess.file_exists("%s/%s.obj" % [dir, sub]):
			redl.append(sub)   # legacy OBJ-only prop: re-syncs as GLB
		# everything left in the folder is retired (med tier, obj, sidecars,
		# .import files) — delete the whole prop dir
		for f in DirAccess.get_files_at(dir):
			if DirAccess.remove_absolute("%s/%s" % [dir, f]) == OK:
				deleted += 1
		DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(LEGACY_DIR)
	HighpolyStore.save()
	# the last EditorFileSystem scan this plugin will ever trigger: makes the
	# editor forget the deleted res://highpoly tree and its import remaps
	EditorInterface.get_resource_filesystem().scan()
	status.call("Reorganized: %d model(s) moved, %d file(s) cleaned up" % [moved, deleted])
	return {"moved": moved, "deleted": deleted, "redownload": redl}

static func _move_file(src: String, dst: String) -> bool:
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(src)   # already migrated (re-run after a crash)
		return true
	# rename first (instant on the same volume), byte-copy fallback across volumes
	var gs := ProjectSettings.globalize_path(src)
	var gd := ProjectSettings.globalize_path(dst)
	if DirAccess.rename_absolute(gs, gd) == OK:
		return true
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty(): return false
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null: return false
	f.store_buffer(data)
	f.close()
	DirAccess.remove_absolute(src)
	return true
