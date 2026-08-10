@tool
extends SceneTree
# The hot-reload member heal, on a purpose-built script: an untyped member
# nulled the way a swap can leave one, healed back to its default. (Typed
# members refuse set(null) outright, so they cannot be in this failure class.)
func _init() -> void:
	var sc := GDScript.new()
	sc.source_code = "extends RefCounted\nvar cache = {}\nvar name2 = \"x\"\nvar typed := 5\n"
	if sc.reload() != OK:
		print("FAIL script did not compile")
		quit(1)
		return
	var o = sc.new()
	o.set("cache", null)
	o.set("name2", null)
	var healed: int = HighpolyReload.heal_new_members(o)
	print("healed %d; cache %s, name2 %s" % [healed,
		str(o.get("cache") is Dictionary), str(o.get("name2") is String)])
	if healed != 2 or not (o.get("cache") is Dictionary):
		print("FAIL")
		quit(1)
		return
	print("ALL OK")
	quit(0)
