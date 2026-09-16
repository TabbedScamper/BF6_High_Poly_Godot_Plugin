@tool
extends RefCounted

# Identity comes from installed files, never from the saved preparation record.
# Also used by non-editor readers so prepared and ordinary loads share keys.
static var _identities: Dictionary = {}
static var _lock := Mutex.new()
static var _recipe := ""
static var bypass := false

# Hash cache-producing code. Presentation-only dependencies are explicitly
# excluded by the shared contract; unknown code files remain included.
static func recipe(refresh := false) -> String:
	_lock.lock()
	if not _recipe.is_empty() and not refresh:
		var known := _recipe
		_lock.unlock()
		return known
	_lock.unlock()
	var computed := recipe_for_root("res://addons/highpoly_toggle", str(Engine.get_version_info().get("string", "")))
	_lock.lock()
	_recipe = computed
	_lock.unlock()
	return computed

# Also used by the dependency regression with isolated fixture files. A missing
# contract or reader produces no recipe, so stale resources cannot be reused.
static func recipe_for_root(base: String, engine_version: String) -> String:
	var contract := read_record(base.path_join("cache_dependencies.json"))
	if int(contract.get("schema", 0)) != 1 or int(contract.get("cache_contract", 0)) < 1:
		return ""
	var policy = contract.get("godot")
	if not policy is Dictionary:
		return ""
	for field in ["required", "exclude", "extensions", "roots"]:
		if not policy.get(field) is Array:
			return ""
	for field in ["required", "extensions", "roots"]:
		if policy[field].is_empty():
			return ""
	for required in policy["required"]:
		if not required is String or required.contains("..") or required.is_absolute_path() or not FileAccess.file_exists(base.path_join(required)):
			return ""
		if required in policy["exclude"] or not required.get_extension().to_lower() in policy["extensions"]:
			return ""
	var stack: Array = []
	for root in policy["roots"]:
		if not root is String or root.contains("..") or root.is_absolute_path():
			return ""
		stack.append(base if root == "." else base.path_join(root))
	var parts := PackedStringArray([engine_version, "preparation-dependencies-v1", "contract:%d" % int(contract["cache_contract"])])
	var included: Dictionary = {}
	while not stack.is_empty():
		var folder := str(stack.pop_back())
		var dir := DirAccess.open(folder)
		if dir == null:
			return ""
		for name in dir.get_directories():
			if not name.begins_with(".") and not name.begins_with("~"):
				stack.append(folder.path_join(name))
		for name in dir.get_files():
			if not name.begins_with("~") and name.get_extension().to_lower() in policy["extensions"]:
				var path := folder.path_join(name)
				var relative := path.trim_prefix(base + "/")
				if relative in policy["exclude"]:
					continue
				var hash := FileAccess.get_sha256(path)
				if hash.is_empty():
					return ""
				parts.append(relative + ":" + hash)
				included[relative] = true
	for required in policy["required"]:
		if not included.has(required):
			return ""
	parts.sort()
	return "\n".join(parts).sha256_text()

static func inspect(path: String) -> Dictionary:
	if not ClassDB.class_exists("BF6Core"):
		return {"ok": false, "error": "The native high-poly reader is missing."}
	var core = ClassDB.instantiate("BF6Core")
	if not core.has_method("install_identity"):
		return {"ok": false, "error": "Restart after updating the native high-poly reader."}
	var result = JSON.parse_string(str(core.call("install_identity", path)))
	if not (result is Dictionary):
		return {"ok": false, "error": "The game-file check returned invalid data."}
	return result

static func accept(path: String, result: Dictionary) -> void:
	_lock.lock()
	_identities[path.simplify_path().to_lower()] = result.duplicate(true)
	_lock.unlock()

static func current(path: String) -> Dictionary:
	_lock.lock()
	var result: Dictionary = _identities.get(path.simplify_path().to_lower(), {}).duplicate(true)
	_lock.unlock()
	if result.is_empty():
		result = inspect(path)
		accept(path, result)
	return result

static func key(path: String) -> String:
	if bypass:
		return ""
	var result := current(path)
	var code := recipe()
	return (str(result.get("identity", "")) + ":" + code).sha256_text() if result.get("ok", false) and not code.is_empty() else ""

# THE READER'S OWN KEY, for the mount index, partition index and placement walk.
#
# Those files depend on the installation and on the scripts that read it, not on
# the rest of the add-on. Keyed on the full recipe, every add-on update threw away
# ~150 MB and ~50 s of work per map and left the old copies on disk. Their stored
# shapes also carry explicit version constants (bf6_source CACHE_VERSION,
# bf6_walk VERSION), which remain the way to invalidate a changed format.
const READER_FILES := ["bf6_source.gd", "bf6_walk.gd", "bf6_ebx.gd", "bf6_types.gd", "bf6_cas.gd",
	"bf6_bundle.gd", "bf6_toc.gd", "bf6_container.gd", "highpoly_install_cache.gd"]
static var _reader_recipe := ""

static func reader_recipe() -> String:
	_lock.lock()
	var known := _reader_recipe
	_lock.unlock()
	if not known.is_empty():
		return known
	var parts := PackedStringArray(["reader-recipe-v1"])
	for name in READER_FILES:
		var hash := FileAccess.get_sha256("res://addons/highpoly_toggle".path_join(name))
		if hash.is_empty():
			return ""
		parts.append(name + ":" + hash)
	var computed := "\n".join(parts).sha256_text()
	_lock.lock()
	_reader_recipe = computed
	_lock.unlock()
	return computed

static func reader_key(path: String) -> String:
	if bypass:
		return ""
	var result := current(path)
	var code := reader_recipe()
	return (str(result.get("identity", "")) + ":" + code).sha256_text() if result.get("ok", false) and not code.is_empty() else ""

static func read_record(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

static func write_record(path: String, record: Dictionary) -> bool:
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return false
	var temp := path + ".%d.part" % OS.get_process_id()
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(record))
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok and DirAccess.rename_absolute(temp, path) == OK
