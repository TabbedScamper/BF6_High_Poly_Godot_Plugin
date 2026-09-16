@tool
extends RefCounted
# Presentation belongs to menu.json; state and actions belong to the adapters.
# Reuse the existing controls so applying shared ordering never reconnects a
# signal, changes a toggle, or loses a conditional row's visibility.
static var _directory := "res://addons/highpoly_toggle"
static var _data: Dictionary = {}
static var _loaded := false

static func configure(directory: String) -> void:
	if directory != _directory:
		_directory = directory
		_data.clear()
		_loaded = false

static func file(name: String) -> String:
	return _directory.path_join(name)

static func data() -> Dictionary:
	if not _loaded:
		_loaded = true
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file("menu.json")))
		if parsed is Dictionary and int(parsed.get("schema", 0)) == 1:
			_data = parsed
		else:
			push_error("High-poly shared menu is missing or unsupported: " + file("menu.json"))
	return _data

static func number(key: String, fallback: float) -> float:
	var value: Variant = data().get("style", {}).get(key, fallback)
	return float(value) if value is float or value is int else fallback

static func section(id: String) -> Dictionary:
	for item in data().get("sections", []):
		if str(item.get("id", "")) == id:
			return item
	return {}

static func binding(control: Control, root: Control = null, label: Label = null) -> Dictionary:
	return {"control": control, "root": root if root != null else control, "label": label}

static func _kind_matches(control: Control, kind: String) -> bool:
	match kind:
		"toggle": return control is Button and control.toggle_mode
		"action": return control is Button and not control.toggle_mode
		"slider": return control is Slider
		# The color picker is a native choice popup, not an enumerated list.
		"choice": return control is OptionButton or control is ColorPickerButton
	return false

static func _move(node: Node, parent: Node, index: int) -> void:
	if node == null or parent == null or node == parent:
		return
	if node.get_parent() != parent:
		node.reparent(parent, false)
	parent.move_child(node, mini(index, parent.get_child_count() - 1))

static func apply(panel: Node, section_nodes: Dictionary, groups: Dictionary,
		bindings: Dictionary) -> PackedStringArray:
	var gaps := PackedStringArray()
	var defs: Dictionary = data().get("controls", {})
	for id in defs:
		var def: Dictionary = defs[id]
		if not def.get("engines", []).has("godot"):
			continue
		if not bindings.has(id):
			gaps.append("control:" + str(id))
			continue
		var bound: Dictionary = bindings[id]
		var control: Control = bound.control
		if not _kind_matches(control, str(def.get("kind", ""))):
			gaps.append("kind:" + str(id))
			continue
		control.tooltip_text = str(def.get("engine_tips", {}).get("godot", def.get("tip", control.tooltip_text)))
		if bound.get("label") != null:
			bound.label.text = str(def.get("label", ""))
		elif control is Button and not control is OptionButton and not bool(def.get("dynamic_label", false)):
			control.text = str(def.get("label", control.text))
	var first := panel.get_child_count()
	for node in section_nodes.values():
		first = mini(first, node.get_index())
	var section_index := 0
	for def in data().get("sections", []):
		var id := str(def.id)
		if not section_nodes.has(id):
			gaps.append("section:" + id)
			continue
		var sec: Node = section_nodes[id]
		_move(sec, panel, first + section_index)
		section_index += 1
		_apply_groups(def.get("groups", []), sec.content, groups, bindings, gaps)
	# Top controls stay outside the animated sections. Reorder their bound
	# contents without displacing install/status/progress rows above them.
	for def in data().get("top_groups", []):
		if groups.has(str(def.id)):
			_apply_controls(def, groups[str(def.id)].container, bindings)
		else:
			gaps.append("group:" + str(def.id))
	return gaps

static func _apply_groups(definitions: Array, parent: Node, groups: Dictionary,
		bindings: Dictionary, gaps: PackedStringArray) -> void:
	var index := 0
	for def in definitions:
		var id := str(def.id)
		if not groups.has(id):
			# An engine-only action group is absent if it has no local actions.
			var expected := bool(def.get("adapter", false))
			for control_id in def.get("controls", []):
				expected = expected or bindings.has(str(control_id))
			if expected:
				gaps.append("group:" + id)
			continue
		var bound: Dictionary = groups[id]
		if bound.root != parent:
			_move(bound.root, parent, index)
			index += 1
		_apply_controls(def, bound.container, bindings)

static func _apply_controls(def: Dictionary, container: Node, bindings: Dictionary) -> void:
	if str(def.get("layout", "")) == "native":
		return
	# Compound inline controls bind their complete row as root, keeping each
	# caption/value pair intact while allowing the shared order to move it.
	var index := 0
	for id in def.get("controls", []):
		if bindings.has(str(id)):
			_move(bindings[str(id)].root, container, index)
			index += 1
