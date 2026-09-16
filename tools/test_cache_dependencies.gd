extends SceneTree

const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")
var failures := 0

func expect(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok:
		failures += 1

func put(path: String, value: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()

func _initialize() -> void:
	# Isolated dependency fixtures exercise the production recipe function. No
	# installed code or actual game files are modified by the changed controls.
	var root := "user://cache-dependency-test-%d" % OS.get_process_id()
	var contract := Cache.read_record("res://addons/highpoly_toggle/cache_dependencies.json")
	put(root.path_join("cache_dependencies.json"), JSON.stringify(contract))
	for required in contract["godot"]["required"]:
		put(root.path_join(required), "fixture dependency: " + required)
	put(root.path_join("highpoly_menu.gd"), "menu before")
	var baseline := Cache.recipe_for_root(root, "test-engine")
	expect(not baseline.is_empty(), "complete dependency set has a recipe")
	expect(Cache.recipe_for_root(root, "test-engine") == baseline, "unchanged inputs keep recipe")
	put(root.path_join("highpoly_menu.gd"), "menu after")
	expect(Cache.recipe_for_root(root, "test-engine") == baseline, "cosmetic menu change preserves cache")
	put(root.path_join("highpoly_preparation_screen.gd"), "new progress screen")
	expect(Cache.recipe_for_root(root, "test-engine") == baseline, "progress screen does not reset preparation")
	put(root.path_join("bf6_meshset.gd"), "changed geometry decoder")
	var changed := Cache.recipe_for_root(root, "test-engine")
	expect(not changed.is_empty() and changed != baseline, "geometry decoder change invalidates")
	put(root.path_join("future_reader.gd"), "unclassified new reader")
	expect(Cache.recipe_for_root(root, "test-engine") != changed, "new unclassified code defaults to invalidation")
	expect(Cache.recipe_for_root(root, "new-engine") != Cache.recipe_for_root(root, "test-engine"), "engine change invalidates")
	DirAccess.remove_absolute(root.path_join("bin/bf6_core.dll"))
	expect(Cache.recipe_for_root(root, "test-engine").is_empty(), "missing reader refuses cache reuse")
	put(root.path_join("cache_dependencies.json"), "{}")
	expect(Cache.recipe_for_root(root, "test-engine").is_empty(), "missing contract refuses cache reuse")
	print("FAILURES ", failures)
	quit(1 if failures else 0)
