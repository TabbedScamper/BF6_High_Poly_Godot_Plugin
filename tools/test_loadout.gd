extends SceneTree
# The Godot LootSpawner loadout on the shared core, against loadout_test's
# numbers for the same install: 180 items, 73 mapped attachments on the M4A1,
# a 12-section factory weapon and a 13-section weapon with a scope.
# godot --headless -s tools/test_loadout.gd -- [--game=PATH]

const Loadout := preload("res://addons/highpoly_toggle/highpoly_loadout.gd")

var failures: Array[String] = []


class FakeSource extends RefCounted:
	var _native_core: Object = null
	func _ensure_native_core() -> bool: return _native_core != null
	func material_for(_key: int, _scope: String, _var := 0, _pal := PackedInt32Array()): return null


func _init() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func run() -> void:
	var game := "C:/Program Files/EA Games/Battlefield 6"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--game="): game = arg.substr(7)
	var core: Object = ClassDB.instantiate("BF6Core")
	if core == null or not core.call("open", game):
		push_error("core open failed"); quit(1); return
	var gs := FakeSource.new()
	gs._native_core = core
	check(Loadout.core_for(gs) == core, "binding has the loadout")
	var enums := Loadout.enum_members("WeaponAttachments")
	check(enums.size() == 371, "Portal attachment members from the SDK types (%d)" % enums.size())
	check(Loadout.loot_items().has("Weapons.Carbine_M4A1"), "Portal loot items include Weapons.Carbine_M4A1")
	var items := Loadout.catalogue(core)
	check(items.size() == 180, "catalogue matches the core test (%d items)" % items.size())
	var m4 := Loadout.find_item(core, "carbine/m4a1")
	check(not m4.is_empty() and Loadout.portal_match(m4) == "Weapons.Carbine_M4A1", "M4A1 maps to its Portal item (%s)" % Loadout.portal_match(m4))
	var att := Loadout.attachments(core, "carbine/m4a1")
	check(att.size() == 73, "attachments match the core test (%d)" % att.size())
	var factory := Loadout.build_weapon(gs, {"item": "carbine/m4a1"})
	var fmesh: Mesh = null
	if factory.get("node") != null:
		fmesh = ((factory.node as Node3D).get_node("Weapon") as MeshInstance3D).mesh
	check(str(factory.get("error", "x")) == "" and fmesh != null and fmesh.get_surface_count() == 12, "factory weapon: %s surfaces" % (fmesh.get_surface_count() if fmesh else -1))
	var scopes := Loadout.slot_choices(core, "carbine/m4a1", "scp")
	var scoped := Loadout.build_weapon(gs, {"item": "carbine/m4a1", "attachment_scp": str((scopes[0] as Dictionary).id)}) if not scopes.is_empty() else {}
	var smesh: Mesh = null
	if scoped.get("node") != null:
		smesh = ((scoped.node as Node3D).get_node("Weapon") as MeshInstance3D).mesh
	check(smesh != null and smesh.get_surface_count() == 13, "weapon with %s: %s surfaces" % [str((scopes[0] as Dictionary).id) if not scopes.is_empty() else "?", smesh.get_surface_count() if smesh else -1])
	check((factory.get("anchors", {}) as Dictionary).has("mzl"), "slot anchors returned")
	var node := Node3D.new()
	node.set_meta(Loadout.LOADOUT_META, {"item": "carbine/m4a1", "attachment_scp": "Scope_X", "attachment_mzl": "Muzzle_Y"})
	check(Loadout.request_key(node) == "carbine/m4a1|scp=Scope_X,mzl=Muzzle_Y", "request key is item plus fits in slot order")
	node.free()
	var bad := Loadout.build_weapon(gs, {"item": "carbine/m4a1", "attachment_mzl": "Muzzle_NotAThing"})
	check(str(bad.get("error", "")).contains("unavailable"), "an unknown attachment is refused")
	for s in ["highpoly_loadout_inspector.gd", "highpoly_lib.gd", "highpoly_toggle.gd"]:
		var script: GDScript = load("res://addons/highpoly_toggle/" + s)
		check(script != null and script.can_instantiate(), "%s compiles" % s)
	if factory.get("node") != null: (factory.node as Node).free()
	if scoped.get("node") != null: (scoped.node as Node).free()
	print("LOADOUT %s (%d failures)" % ["PASSED" if failures.is_empty() else "FAILED", failures.size()])
	quit(0 if failures.is_empty() else 1)
