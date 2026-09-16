@tool
extends Node
# THE BF6 MENU, shared by every BF6 Godot plugin.
#
# Each plugin ships a copy of this file (plugins.json shared_assets) and
# registers its own section. The first plugin to load creates the one host
# node; every later copy finds it through GROUP and calls it by name, so
# plugins installed separately never depend on each other and never collide
# on a global class (there is no class_name).
#
# Two presentations read the same registrations:
#   * a "BF6" menu in the editor's menu bar, one submenu per plugin. It needs
#     nothing else, so every plugin works on its own.
#   * the Extended Workspace radial (space bar over the 3D viewport), when that
#     plugin is enabled: one pill per plugin on the front ring, its items on a
#     sub-ring - the Unreal SDK's wheel, where add-ons register pills the same way
#     (BF6SDKExtension.h RegisterPieEntry / OpenPieSubRing).
#
# A section is registered with a provider that is asked for its items every
# time a menu or ring opens, so toggles always show their current state:
#
#   var menu := preload("bf6_plugin_menu.gd").ensure()
#   menu.register_plugin("highpoly", "High Poly", 900, _menu_items, _menu_sub)
#   ...
#   func _menu_items(context: Dictionary) -> Array:
#       return [
#           {"id": "detail", "label": "High Poly detail", "sub": "on",
#            "checked": true, "closes": false, "pick": _toggle_detail},
#           {"id": "loadout", "label": "Loadout", "sub": "choose the weapon",
#            "pick": _open_loadout},
#       ]
#   func _exit_tree(): preload("bf6_plugin_menu.gd").find().unregister_plugin("highpoly")
#
# Item keys: id, label, sub (short state or hint), pick (Callable, no
# arguments), checked (true/false for a toggle, absent otherwise), disabled
# (bool), closes (false for a toggle the radial rebuilds in place; default
# true), separator (true for a divider in the menu bar, ignored on the ring).
# context carries "selection" (Array of selected Nodes) and "surface"
# ("menu" or "radial").
#
# options (optional): "available" (Callable(context) -> bool; false keeps the
# section off the ring and greys it in the menu bar), "pick" (Callable(center:
# Vector2) run when the radial pill is chosen, instead of opening the items as a
# sub-ring - for a section that opens its own window, as Unreal's HIGH POLY pill
# does), "radial" (false keeps it in the menu bar only - the editors Unreal puts
# in its top row rather than on the wheel: Blocks, UI, Script, Maps). Order follows the Unreal wheel: its own entries are 100 apart from 100,
# add-ons sit after them (HIGH POLY 900, GAME MODE 910, LOADOUT 1050).

signal plugins_changed

const API_VERSION := 1
const GROUP := "bf6_plugin_menu_v1"
const MENU_NAME := "BF6"

var _plugins := {}   # id -> {id, title, order, items, sub}
var _menu: PopupMenu = null
var _submenus := {}  # id -> PopupMenu


static func find() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	for n in tree.get_nodes_in_group(GROUP):
		if is_instance_valid(n) and n.has_method("get_api_version") and int(n.get_api_version()) == API_VERSION:
			return n
	return null


# The host, created under the editor's base control when no plugin has made
# one yet. Null outside the editor.
static func ensure() -> Node:
	var existing := find()
	if existing != null:
		return existing
	if not Engine.is_editor_hint():
		return null
	var base := EditorInterface.get_base_control()
	if base == null:
		return null
	var host := new()
	host.name = "BF6PluginMenu"
	base.add_child(host)
	return host


# Bring a plugin's panel into view wherever it lives: the Extended Workspace
# drawer that holds it (by panel id), the editor dock tab it sits in, or the
# window it floats in. True when something was shown.
static func reveal(control: Control, workspace_panel_id := "") -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and workspace_panel_id != "":
		for n in tree.get_nodes_in_group("bf6_workspace_panels_v1"):
			if is_instance_valid(n) and n.has_method("has_panel") and bool(n.has_panel(workspace_panel_id)):
				return bool(n.show_panel(workspace_panel_id))
	if control == null or not is_instance_valid(control):
		return false
	var child: Node = control
	var parent := control.get_parent()
	while parent != null:
		if parent is TabContainer:
			(parent as TabContainer).current_tab = child.get_index()
			return true
		if parent is Window and not (parent == tree.root if tree != null else false):
			(parent as Window).show()
			(parent as Window).grab_focus()
			return true
		child = parent
		parent = parent.get_parent()
	return false


func get_api_version() -> int:
	return API_VERSION


func _enter_tree() -> void:
	add_to_group(GROUP)
	_build_menu_bar()


func _exit_tree() -> void:
	_remove_menu_bar()


# ------------------------------------------------------------------ registry

func register_plugin(id: String, title: String, order: int, items: Callable, sub: Callable = Callable(),
		options: Dictionary = {}) -> bool:
	if id == "" or not items.is_valid():
		return false
	_plugins[id] = {"id": id, "title": title, "order": order, "items": items, "sub": sub,
		"available": options.get("available", Callable()), "pick": options.get("pick", Callable()),
		"radial": bool(options.get("radial", true))}
	_refresh_menu_bar()
	plugins_changed.emit()
	return true


func unregister_plugin(id: String) -> void:
	if not _plugins.erase(id):
		return
	_refresh_menu_bar()
	plugins_changed.emit()
	if _plugins.is_empty():
		# The last plugin went away: the menu goes with it.
		queue_free()


func has_plugin(id: String) -> bool:
	return _plugins.has(id)


# Registered sections in order, each {id, title, order, radial}.
func plugins() -> Array:
	var out: Array = []
	for p in _plugins.values():
		out.append({"id": p.id, "title": p.title, "order": p.order, "radial": p.radial})
	out.sort_custom(func(a, b): return a.order < b.order if a.order != b.order else a.title < b.title)
	return out


func context(surface: String) -> Dictionary:
	var selection: Array = []
	if Engine.is_editor_hint() and EditorInterface.get_selection() != null:
		selection = EditorInterface.get_selection().get_selected_nodes()
	return {"surface": surface, "selection": selection}


func available(id: String, ctx: Dictionary) -> bool:
	var p: Dictionary = _plugins.get(id, {})
	if p.is_empty():
		return false
	var cb: Variant = p.get("available")
	return not (cb is Callable and (cb as Callable).is_valid()) or bool((cb as Callable).call(ctx))


# The section's own pill action, or an invalid Callable when it opens a sub-ring.
func pill_action(id: String) -> Callable:
	var p: Dictionary = _plugins.get(id, {})
	var cb: Variant = p.get("pick")
	return cb if cb is Callable and (cb as Callable).is_valid() else Callable()


func items_for(id: String, ctx: Dictionary) -> Array:
	var p: Dictionary = _plugins.get(id, {})
	if p.is_empty() or not (p.items as Callable).is_valid():
		return []
	var got: Variant = (p.items as Callable).call(ctx)
	return got if got is Array else []


# The pill's small line on the radial front ring.
func sub_for(id: String, ctx: Dictionary) -> String:
	var p: Dictionary = _plugins.get(id, {})
	if p.is_empty() or not (p.sub as Callable).is_valid():
		return ""
	return str((p.sub as Callable).call(ctx))


func pick(item: Dictionary) -> void:
	var cb: Variant = item.get("pick")
	if cb is Callable and (cb as Callable).is_valid() and not bool(item.get("disabled", false)):
		(cb as Callable).call()


# ------------------------------------------------------------------ menu bar

func _find_menu_bar() -> MenuBar:
	var base := EditorInterface.get_base_control() if Engine.is_editor_hint() else null
	if base == null:
		return null
	var stack: Array = [base]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MenuBar:
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _build_menu_bar() -> void:
	var bar := _find_menu_bar()
	if bar == null or _menu != null:
		return
	_menu = PopupMenu.new()
	_menu.name = MENU_NAME
	_menu.about_to_popup.connect(_refresh_menu_bar)
	_menu.id_pressed.connect(func(_i): pass)
	bar.add_child(_menu)


func _remove_menu_bar() -> void:
	if _menu != null and is_instance_valid(_menu):
		if _menu.get_parent() != null:
			_menu.get_parent().remove_child(_menu)
		_menu.free()
	_menu = null
	_submenus.clear()


func _refresh_menu_bar() -> void:
	if _menu == null or not is_instance_valid(_menu):
		return
	_menu.clear()
	for c in _menu.get_children():
		_menu.remove_child(c)
		c.queue_free()
	_submenus.clear()
	var ctx := context("menu")
	for p in plugins():
		var sub := PopupMenu.new()
		sub.name = "bf6_" + str(p.id).validate_node_name()
		_menu.add_child(sub)
		_menu.add_submenu_node_item(str(p.title), sub)
		_menu.set_item_disabled(_menu.item_count - 1, not available(str(p.id), ctx))
		_submenus[p.id] = sub
		_fill_submenu(sub, str(p.id), ctx)
		var pid := str(p.id)
		sub.about_to_popup.connect(func(): _fill_submenu(sub, pid, context("menu")))


func _fill_submenu(sub: PopupMenu, id: String, ctx: Dictionary) -> void:
	sub.clear()
	for conn in sub.id_pressed.get_connections():
		sub.id_pressed.disconnect(conn.callable)
	var items := items_for(id, ctx)
	for i in range(items.size()):
		var it: Dictionary = items[i]
		if bool(it.get("separator", false)):
			sub.add_separator(str(it.get("label", "")))
			continue
		var label := str(it.get("label", it.get("id", "")))
		var line := str(it.get("sub", ""))
		if line != "":
			label += "   (" + line + ")"
		if it.has("checked"):
			sub.add_check_item(label, i)
			sub.set_item_checked(sub.get_item_index(i), bool(it.checked))
		else:
			sub.add_item(label, i)
		sub.set_item_disabled(sub.get_item_index(i), bool(it.get("disabled", false)))
	sub.id_pressed.connect(func(index: int):
		if index >= 0 and index < items.size(): pick(items[index]))
