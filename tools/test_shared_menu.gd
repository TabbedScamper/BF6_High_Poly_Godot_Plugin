extends SceneTree
const Menu = preload("res://addons/highpoly_toggle/highpoly_menu.gd")
const Section = preload("res://addons/highpoly_toggle/highpoly_section.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	# Force-parse the real adapter, not just the shared data helper.
	var adapter = load("res://addons/highpoly_toggle/highpoly_toggle.gd")
	check(adapter != null and adapter.can_instantiate(), "Godot editor adapter failed to load")
	var panel := VBoxContainer.new()
	root.add_child(panel)
	var sec := Section.new()
	panel.add_child(sec)
	sec.setup("Test", "Test")
	var row := HFlowContainer.new()
	sec.content.add_child(row)
	var first := Button.new()
	first.toggle_mode = true
	first.button_pressed = true
	var second := Button.new()
	second.visible = false
	row.add_child(first)
	row.add_child(second)
	var events := [0]
	first.toggled.connect(func(_v): events[0] += 1)
	var original := Menu.data().duplicate(true)
	var temp := "user://shared-menu-location-control"
	DirAccess.make_dir_recursive_absolute(temp)
	var output := FileAccess.open(temp.path_join("menu.json"), FileAccess.WRITE)
	var relocated := original.duplicate(true)
	relocated.style.chip_gap = 17
	output.store_string(JSON.stringify(relocated))
	output.close()
	Menu.configure(temp)
	check(Menu.number("chip_gap", 6) == 17, "relocated menu read the default installation")
	Menu.configure("res://addons/highpoly_toggle")
	check(Menu.number("chip_gap", 6) == float(original.style.chip_gap), "restoring menu location retained stale data")
	Menu._data = {"schema": 1, "sections": [{"id": "test", "groups": [
		{"id": "row", "layout": "chips", "controls": ["second", "first"]}]}],
		"controls": {
			"first": {"label": "Shared label", "tip": "Shared tip", "kind": "toggle", "engines": ["godot"]},
			"second": {"label": "Second", "tip": "Second tip", "kind": "action", "engines": ["godot"]}}}
	var bindings := {"first": Menu.binding(first), "second": Menu.binding(second)}
	var groups := {"row": {"root": row, "container": row}}
	var gaps := Menu.apply(panel, {"test": sec}, groups, bindings)
	check(gaps.is_empty(), "real binding reported gaps")
	check(row.get_child(0) == second, "shared order was not applied")
	check(first.text == "Shared label" and first.tooltip_text == "Shared tip", "shared copy was not applied")
	check(first.button_pressed and events[0] == 0, "presentation changed state or fired a handler")
	check(not second.visible, "presentation unhid a conditional control")
	Menu._data.controls.fake = {"label": "Fake", "tip": "Fake", "engines": ["godot"]}
	gaps = Menu.apply(panel, {"test": sec}, groups, bindings)
	check(gaps.has("control:fake"), "unbound control negative control was not reported")
	Menu._data.controls.second.kind = "slider"
	gaps = Menu.apply(panel, {"test": sec}, groups, bindings)
	check(gaps.has("kind:second"), "wrong control kind was not reported")
	Menu._data = original
	test_map_action_group()
	panel.queue_free()
	print("Shared menu: location/order/copy/state/visibility and actual shader group verified; fake binding, wrong kind and section-alias regression detected. Failures: ", failures)
	quit(0 if failures == 0 else 1)

func test_map_action_group() -> void:
	var source := FileAccess.get_file_as_string("res://addons/highpoly_toggle/highpoly_toggle.gd")
	# Run the actual small factory without instantiating the editor plugin or
	# enabling game loading. Read its actual group expression as well, so a
	# regression to shader_btn.get_parent() fails this test.
	var start := source.find("func _centred(")
	var end := source.find("\nfunc ", start + 1)
	var group_pattern := RegEx.new()
	group_pattern.compile('"map_actions": (\\{[^\\n]+\\}),')
	var matched := group_pattern.search(source)
	check(start >= 0 and end > start and matched != null, "shader factory/group not found in real adapter")
	if start < 0 or end <= start or matched == null:
		return
	var script := GDScript.new()
	script.source_code = "extends RefCounted\n" + source.substr(start, end - start) \
		+ "\nfunc group(shader_btn):\n\treturn " + matched.get_string(1) + "\n"
	check(script.reload() == OK, "actual shader factory/group did not compile")
	var factory = script.new()
	var panel := VBoxContainer.new()
	root.add_child(panel)
	var sec := Section.new()
	panel.add_child(sec)
	sec.setup("Map Context", "Test")
	var chips := HFlowContainer.new()
	sec.content.add_child(chips)
	var terrain := Button.new()
	terrain.toggle_mode = true
	chips.add_child(terrain)
	var shader := Button.new()
	sec.content.add_child(factory._centred(shader))
	var shader_group: Dictionary = factory.group(shader)
	check(shader_group.root == shader and shader_group.container == shader,
		"single-action group aliases the section instead of the shader button")
	var original := Menu.data().duplicate(true)
	var definition := Menu.section("map_context").duplicate(true)
	var selected_groups: Array = []
	for group in definition.groups:
		if group.id == "map_layers":
			group.controls = ["terrain"]
			selected_groups.append(group)
		elif group.id == "map_actions":
			group.controls = ["configure_shaders"]
			selected_groups.append(group)
	definition.groups = selected_groups
	Menu._data = {"schema": 1, "sections": [definition], "controls": {
		"terrain": original.controls.terrain,
		"configure_shaders": original.controls.configure_shaders}}
	var groups := {"map_layers": {"root": chips, "container": chips}, "map_actions": shader_group}
	var bindings := {"terrain": Menu.binding(terrain), "configure_shaders": Menu.binding(shader)}
	var gaps := Menu.apply(panel, {"map_context": sec}, groups, bindings)
	check(gaps.is_empty(), "actual single-action adapter reported gaps")
	check(chips.get_index() < shader.get_index(), "Configure Shaders moved above the layer chips")
	check(shader.get_parent() == sec.content, "single-control group reparented the action incorrectly")
	# Controlled reproduction of the original mistake must reverse their order,
	# demonstrating that the assertion above actually catches this regression.
	groups.map_actions = {"root": sec.content, "container": sec.content}
	Menu.apply(panel, {"map_context": sec}, groups, bindings)
	check(shader.get_index() < chips.get_index(), "section-alias negative control did not reproduce the regression")
	Menu._data = original
	panel.queue_free()
