@tool
extends RefCounted
class_name HighpolyReload

# LIVE RELOAD: new plugin code over an already-built scene, no editor restart.
#
# The loop this exists for: point at a prop that looks wrong, change the code
# that dresses it, press one button, look again. Closing and reopening the
# editor between iterations costs a 20 s boot and a 28 s rebuild, which is the
# difference between trying six things and trying one.
#
# It also has to work for someone ELSE running this plugin. "Check for updates"
# already downloads a zip and extracts it over the install; what it then said
# was "Restart the editor to finish". That restart is the part this removes, so
# a fix to one prop's material reaches a user who has that prop on screen
# without them rebuilding anything.
#
# WHY THIS IS POSSIBLE AT ALL, measured rather than hoped:
#
#   ResourceLoader.load(path, "", CACHE_MODE_REPLACE) updates the SAME Script
#   object in place — the returned reference is identical to the one already
#   held — and objects that were ALREADY INSTANCED from it start running the new
#   code immediately. Verified in this engine version: an instance created
#   before the file changed returned the new function's value after the replace.
#
# That last part is the whole trick. Without it, every long-lived object (the
# game source, the map context, the dock) would keep the old code until it was
# recreated, and recreating them is the restart we are trying to avoid.
#
# WHAT THIS CANNOT DO, said plainly rather than discovered later:
#
#   * GEOMETRY does not re-dress. A change to how a mesh is BUILT — the
#     destruction cull, the section merge — needs the mesh parsed again, and the
#     on-disk geometry cache will happily serve the old one. Those changes ship
#     with a cache epoch (see `geom_epoch`) and cost a rebuild.
#   * A change to a script's STATIC state or to a `const` that another script
#     baked in at parse time may need that other script reloaded too, which is
#     why this reloads all of them rather than the ones that look relevant.
#   * If the editor ends up confused, the fallback is the thing that always
#     worked: restart. The button says so when a reload reports errors.

const SHADER_EXTS := ["gdshader"]

# Replaced after everything else. See reload_code.
const LAST_FILES := ["highpoly_toggle.gd"]

# What THIS EDITOR currently has loaded, so the next reload can tell what moved.
#
# CONTENT HASHES, not modification times. An update that rewrites every file in
# the addon touches 40 mtimes and changes two files, and a zip extraction sets
# them all to now; reloading on mtime would replay the whole addon every time
# anyone pressed the button. A hash says what is genuinely different.
#
# IN MEMORY, NOT ON DISK, and that is a correctness point rather than a
# performance one. This baseline answers "what code is running inside THIS
# process". `user://` is shared by every Godot instance that opens the project,
# so a file there is the wrong shape for the question: with two editors open -
# yours and a benchmark harness, say - the one that reloads writes the hashes
# and the other then compares its OWN in-memory code against a baseline it never
# set, sees no difference, and never reloads. One instance silently disarms the
# other.
#
# Held per process it cannot be wrong: a freshly started editor loaded whatever
# was on disk at the time, so its baseline IS those files and it correctly has
# nothing to reload.
static var _baseline: Dictionary = {}
static var _armed := false


static func plugin_dir() -> String:
	return (HighpolyReload as Script).resource_path.get_base_dir()


# ---------------------------------------------------------------------------
# THE STAGING CHANNEL: updates written OUTSIDE res://, applied by the button.
#
# Nothing may write into res:// while the editor is open - the editor
# hot-reloads changed scripts underneath running code, which is a "Bad address
# index" crash mid-build, not a feature. But waiting for a closed editor to
# deliver every fix costs the whole iteration loop this file exists for. So
# mid-session updates land here instead: user:// is per-project, outside the
# scan, and the editor never looks at it on its own. "Check for updates" is
# what moves staged files into the addon and reloads - a moment the USER
# chose, guarded against running builds by the caller.
#
# The stage is FLAT: .gd and .gdshader files only, no subdirectories, matching
# what _hashes()/reload_code() cover. Binaries (bin/) are not hot-reloadable
# and do not belong here.
# ---------------------------------------------------------------------------
const STAGED_DIR := "user://highpoly/staged"


# How many staged files differ from what the addon holds, without applying.
static func staged_count() -> int:
	if not DirAccess.dir_exists_absolute(STAGED_DIR):
		return 0
	var n := 0
	var dst := plugin_dir()
	for f in DirAccess.get_files_at(STAGED_DIR):
		var fn := str(f)
		var ext := fn.get_extension().to_lower()
		if ext != "gd" and not SHADER_EXTS.has(ext):
			continue
		if FileAccess.get_md5("%s/%s" % [STAGED_DIR, fn]) \
				!= FileAccess.get_md5("%s/%s" % [dst, fn]):
			n += 1
	return n


# Copy staged files whose content differs into the addon, clearing the stage
# behind them. A staged file identical to the addon's is stale residue and is
# cleared without a write. -> {"applied": [names], "failed": [names]}
static func apply_staged() -> Dictionary:
	var out := {"applied": [], "failed": []}
	if not DirAccess.dir_exists_absolute(STAGED_DIR):
		return out
	var dst := plugin_dir()
	for f in DirAccess.get_files_at(STAGED_DIR):
		var fn := str(f)
		var ext := fn.get_extension().to_lower()
		if ext != "gd" and not SHADER_EXTS.has(ext):
			continue
		var sp := "%s/%s" % [STAGED_DIR, fn]
		var dp := "%s/%s" % [dst, fn]
		if FileAccess.get_md5(sp) == FileAccess.get_md5(dp):
			DirAccess.remove_absolute(sp)
			continue
		var bytes := FileAccess.get_file_as_bytes(sp)
		if bytes.is_empty():
			(out["failed"] as Array).append(fn)
			continue
		var w := FileAccess.open(dp, FileAccess.WRITE)
		if w == null:
			(out["failed"] as Array).append(fn)
			continue
		w.store_buffer(bytes)
		w.close()
		DirAccess.remove_absolute(sp)
		(out["applied"] as Array).append(fn)
	(out["applied"] as Array).sort()
	(out["failed"] as Array).sort()
	return out


static func _hashes() -> Dictionary:
	var dir := plugin_dir()
	var out := {}
	for f in DirAccess.get_files_at(dir):
		var fn := str(f)
		var ext := fn.get_extension().to_lower()
		if ext != "gd" and not SHADER_EXTS.has(ext):
			continue
		var p := "%s/%s" % [dir, fn]
		# FileAccess.get_md5 rather than hashing the bytes ourselves:
		# PackedByteArray has no md5_text, and reading the file twice to get one
		# would be the slower way to the same answer.
		var h := FileAccess.get_md5(p)
		if h != "":
			out[fn] = h
	return out


# Record what this instance has loaded. Called from the plugin's _enter_tree, so
# the baseline is the code the editor actually parsed rather than whatever
# happens to be on disk when the button is first pressed - without it, an edit
# made between startup and the first press would be silently adopted as
# "already loaded" and never applied.
static func arm() -> void:
	_baseline = _hashes()
	_armed = true


static func _load_state() -> Dictionary:
	return _baseline


static func _save_state(h: Dictionary) -> void:
	_baseline = h
	_armed = true


# What has changed since the last reload, without touching anything.
#
# -> {"changed": [names], "added": [names], "removed": [names], "first": bool}
static func pending() -> Dictionary:
	var now := _hashes()
	var was := _load_state()
	var changed: Array = []
	var added: Array = []
	var removed: Array = []
	for k in now.keys():
		if not was.has(k):
			added.append(str(k))
		elif str(was[k]) != str(now[k]):
			changed.append(str(k))
	for k in was.keys():
		if not now.has(k):
			removed.append(str(k))
	changed.sort(); added.sort(); removed.sort()
	return {"changed": changed, "added": added, "removed": removed,
		"first": not _armed}


# Replace ONLY the scripts and shaders whose contents differ, in place.
#
# The first ever call records the baseline and reloads nothing: there is no
# "before" to compare against, and replaying the whole addon on first press
# would be the one case guaranteed to have changed nothing.
#
# Order: shaders first, because a ShaderMaterial holding a Shader object picks
# up new code the moment that object is replaced, so a script that rebuilds
# materials afterwards sees the new one.
#
# -> {"scripts": n, "shaders": n, "failed": [paths], "names": [names],
#     "first": bool}
static func reload_code(force := false) -> Dictionary:
	var now := _hashes()
	var p := pending()
	var out := {"scripts": 0, "shaders": 0, "failed": [], "names": [],
		"first": bool(p["first"])}
	if bool(p["first"]) and not force:
		_save_state(now)
		return out

	var todo: Array = []
	if force:
		todo = now.keys()
	else:
		todo = (p["changed"] as Array) + (p["added"] as Array)
	# THE DOCK IS REPLACED LAST, and this is not tidiness.
	#
	# The script running this function IS the dock, and the new dock is parsed
	# against whatever else is loaded at the moment it is replaced. If it calls
	# something that exists only in the new version of another file and that file
	# has not been replaced yet, the parse fails and the reload reports a file it
	# could not load — which is the one outcome that sends the user to restart the
	# editor, i.e. the exact thing this feature exists to avoid.
	#
	# Alphabetical order happens to put highpoly_toggle.gd after every file it
	# calls into today. That is luck, and it is one rename away from not being
	# true.
	todo.sort_custom(func(a, b):
		return int(LAST_FILES.has(str(a))) < int(LAST_FILES.has(str(b))))
	var dir := plugin_dir()
	for pass_ext in [true, false]:              # shaders, then scripts
		for f in todo:
			var fn := str(f)
			var is_shader: bool = SHADER_EXTS.has(fn.get_extension().to_lower())
			if is_shader != pass_ext:
				continue
			var path := "%s/%s" % [dir, fn]
			var r := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
			if r == null:
				(out["failed"] as Array).append(path)
				continue
			(out["names"] as Array).append(fn)
			if is_shader:
				out["shaders"] = int(out["shaders"]) + 1
			else:
				out["scripts"] = int(out["scripts"]) + 1
	# Only files that actually took are recorded as current, so a file that
	# failed to parse is retried on the next press rather than being marked done.
	if not (out["failed"] as Array).is_empty():
		var partial := _load_state()
		for fn in out["names"]:
			partial[str(fn)] = str(now[str(fn)])
		_save_state(partial)
	else:
		_save_state(now)
	return out


# WHICH FILES CAN CHANGE WHAT IS ALREADY ON SCREEN.
#
# A reload should do the cheapest thing that is still correct, and the cheapest
# correct thing depends on what moved:
#
#   nothing            -> say so and stop
#   dock / UI / log    -> the code is live, nothing built needs touching
#   anything else      -> re-dress the materials, which is seconds
#   geometry readers   -> the built meshes are stale and only a rebuild fixes
#                         them, so say that rather than pretending
#
# The geometry list is deliberately short and explicit. It is the modules that
# decide what VERTICES exist; everything else can only change how they look.
const GEOMETRY_FILES := ["bf6_meshset.gd", "bf6_walk.gd", "bf6_terrain.gd",
	"bf6_splat.gd", "bf6_materialtree.gd", "bf6_decals.gd", "bf6_ebx.gd",
	"bf6_types.gd", "bf6_source.gd", "bf6_toc.gd", "bf6_cas.gd",
	"bf6_bundle.gd", "bf6_container.gd"]
# Files that cannot reach anything already built.
const COSMETIC_FILES := ["highpoly_toggle.gd", "highpoly_log.gd",
	"highpoly_theme.gd", "highpoly_tips.gd", "highpoly_splash.gd",
	"highpoly_updater.gd", "highpoly_reload.gd", "highpoly_jobs.gd"]
# FILES THAT DO BOTH, which the first version of this table pretended did not
# exist. highpoly_gamesource.gd resolves materials AND builds geometry - the
# road ribbons, the terrain drape, the prop meshes - so calling it "materials"
# meant a road-height change reported "re-dressed 6,431 meshes" and moved
# nothing. Reported as `mixed`: re-dress, which is free and might be the whole
# change, and then say a rebuild is needed for the rest.
const MIXED_FILES := ["highpoly_gamesource.gd", "highpoly_mapcontext.gd",
	"highpoly_lib.gd", "highpoly_scatter.gd"]


# `geom_changed` is whether HighpolyGameSource.geom_epoch() moved across the
# reload, and it overrides both geometry verdicts.
#
# The file lists alone cannot answer "are the meshes on screen stale". Every file
# on them contains code that builds geometry AND code that does not, so adding a
# progress callback to bf6_walk.gd came out as "rebuild the whole map" when it
# cannot move a vertex. A rebuild costs the user a minute or more, so it should
# be something the author of a change STATES, by bumping the epoch, rather than
# something inferred from which file an edit happened to land in.
#
# Defaults to true so a caller that does not know keeps the old, pessimistic
# answer. The two mistakes are not symmetrical: telling someone to rebuild when
# they need not costs a minute, and not telling them when they must leaves them
# looking at a map that is quietly wrong.
static func impact(names: Array, geom_changed := true) -> String:
	if names.is_empty():
		return "none"
	for n in names:
		if GEOMETRY_FILES.has(str(n)):
			return "geometry" if geom_changed else "materials"
	for n in names:
		if MIXED_FILES.has(str(n)):
			return "mixed" if geom_changed else "materials"
	for n in names:
		if not COSMETIC_FILES.has(str(n)):
			return "materials"
	return "code"


# AN OLD INSTANCE RUNNING NEW CODE, healed. A hot-swap replaces the CODE on a
# living object but does not run the new script's initializers on it, so a
# member the update ADDED reads null on the live instance where a fresh one
# would hold its default ({} for the caches, almost always). The next material
# build then dies on `.has()` of null, and every prop dresses white - a user
# hit exactly that after an update that grew highpoly_gamesource by three
# cache dictionaries, and it looked like a giant regression when it was one
# uninitialized member. Copying the script default into any live member that
# is null-where-the-default-is-not is idempotent, and the one case it could
# overreach - a member DEFAULTED non-null that code intentionally nulled - is
# a cache reset, not a break.
# The defaults come from a throwaway FRESH instance of the same script -
# Script.get_property_default_value answers null outside the editor's own
# resource path, but a fresh instance ran the new initializers by
# construction. Instantiated lazily (only when a null member is found) and
# freed when it is a Node; RefCounted frees itself.
static func heal_new_members(live) -> int:
	if live == null or not is_instance_valid(live):
		return 0
	var sc: Script = live.get_script()
	if sc == null or not sc.can_instantiate():
		return 0
	var healed := 0
	var fresh = null
	for p in sc.get_script_property_list():
		var nm := str(p.get("name", ""))
		if nm == "":
			continue
		if live.get(nm) != null:
			continue
		if fresh == null:
			fresh = sc.new()
			if fresh == null:
				return healed
		var d = fresh.get(nm)
		if d != null:
			live.set(nm, d)
			healed += 1
	if fresh != null and fresh is Node:
		(fresh as Node).free()
	return healed


# Everything the plugin holds that was DERIVED from the code, dropped so the
# next look at it is computed by the new code.
#
# Deliberately not a blanket "clear all caches": the walk cache, the partition
# index and the parsed geometry are derived from the GAME, not from us, and
# throwing them away turns a 2-second reload into an 85-second one for nothing.
static func drop_derived(game_source, mapctx) -> Dictionary:
	var out := {}
	if game_source != null:
		out = game_source.invalidate_materials()
	if mapctx != null and mapctx.has_method("drop_material_caches"):
		mapctx.drop_material_caches()
	return out
