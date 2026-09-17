@tool
extends EditorInspectorPlugin
# The Loadout panel for a selected LootSpawner, in the Inspector: the Unreal
# add-on's Loadout window (BF6HighPolyLoadoutPanel.cpp) for Godot. Weapon,
# gadget and throwable pickers, the weapon seen side-on with a button on each
# attachment point, one picker per attachment slot and the Portal gameplay
# item. Every change is one undoable edit of the node's loadout metadata
# (HighpolyLoadout.LOADOUT_META), after which the viewport overlay rebuilds.

const Loadout := preload("highpoly_loadout.gd")

var undo: EditorUndoRedoManager = null
var refresh_node := Callable()    # (node) -> void: rebuild the node's overlay


func _can_handle(object: Object) -> bool:
	var type := Loadout.type_of(object as Node) if object is Node else ""
	return type == "LootSpawner" or Loadout.is_soldier_type(type)


func _parse_begin(object: Object) -> void:
	var panel := LoadoutPanel.new()
	panel.setup(object as Node3D, self)
	add_custom_control(panel)


# The one place a loadout is written, so undo and redo never call into a panel
# the Inspector has since rebuilt.
func store_loadout(target: Node, values: Dictionary) -> void:
	if not is_instance_valid(target): return
	if values.is_empty(): target.remove_meta(Loadout.LOADOUT_META)
	else: target.set_meta(Loadout.LOADOUT_META, values)
	if refresh_node.is_valid(): refresh_node.call(target)


class LoadoutPanel extends VBoxContainer:
	var node: Node3D = null
	var host = null
	var status := Label.new()
	var fields := VBoxContainer.new()
	var preview := SubViewport.new()
	var preview_holder := Control.new()
	var preview_mesh := MeshInstance3D.new()
	var camera := Camera3D.new()
	var slot_layer := Control.new()
	var core: Object = null
	var loading := false

	var soldier := false

	func setup(target: Node3D, inspector) -> void:
		node = target
		host = inspector
		# Unreal's panel: a soldier spawner picks who stands there and what they
		# hold; only a LootSpawner has the side-on weapon view and loot pickers.
		soldier = Loadout.is_soldier_type(Loadout.type_of(target))
		var title := Label.new()
		title.text = "Loadout"
		title.add_theme_font_size_override("font_size", 18)
		add_child(title)
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(status)
		if not soldier:
			_build_preview()
		add_child(fields)
		if not soldier:
			var note := Label.new()
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			note.text = "Connect this spawner using its ObjId. The spawn rule, TypeScript helper and weapon card exports use the same choices."
			add_child(note)
		status.text = "Reading available loadouts..."
		_load_async()

	func _build_preview() -> void:
		preview.size = Vector2i(560, 280)
		preview.transparent_bg = false
		preview.own_world_3d = true
		preview.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
		var env := WorldEnvironment.new()
		var e := Environment.new()
		e.background_mode = Environment.BG_COLOR
		e.background_color = Color(0.025, 0.035, 0.04)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = Color(0.55, 0.55, 0.6)
		env.environment = e
		preview.add_child(env)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-35, -35, 0)
		sun.light_energy = 1.2
		preview.add_child(sun)
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		preview.add_child(camera)
		preview.add_child(preview_mesh)
		var label := Label.new()
		label.text = "Select an attachment point on the weapon"
		add_child(label)
		var texture_rect := TextureRect.new()
		texture_rect.texture = preview.get_texture()
		texture_rect.custom_minimum_size = Vector2(280, 140)
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		preview_holder.custom_minimum_size = Vector2(280, 140)
		preview_holder.add_child(preview)
		preview_holder.add_child(texture_rect)
		slot_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		slot_layer.mouse_filter = Control.MOUSE_FILTER_PASS
		preview_holder.add_child(slot_layer)
		add_child(preview_holder)

	func _load_async() -> void:
		if loading: return
		loading = true
		var gs = HighpolyLib.game_source
		core = Loadout.core_for(gs)
		if core == null:
			status.text = "Open a map in High Poly to choose this spawner's loadout."
			loading = false
			return
		var item := Loadout.item_of(Loadout.values_of(node))
		WorkerThreadPool.add_task(func():
			Loadout.catalogue(core)
			Loadout.attachments(core, item)
			Loadout.loot_items()
			call_deferred("_populate"))

	func _populate() -> void:
		loading = false
		if not is_instance_valid(node) or not is_inside_tree(): return
		for c in fields.get_children(): c.queue_free()
		var values := Loadout.values_of(node)
		var item := Loadout.item_of(values)
		var items := Loadout.catalogue(core)
		status.text = "%d equipment items" % items.size() if not items.is_empty() else "No equipment catalogue could be read from the install."
		if soldier:
			var characters := Loadout.catalogue_list(core, "characters")
			var request := Loadout.soldier_request(Loadout.type_of(node), values)
			status.text = "%d characters, %d outfits, %d equipment items" % [characters.size(),
				Loadout.catalogue_list(core, "outfits").size(), items.size()]
			_add_picker("Character", characters, str(request.character), func(chosen: Dictionary):
				_apply({"character": str(chosen.id), "outfit": Loadout.DEFAULT_OUTFIT}))
			_add_picker("Side", Loadout.catalogue_list(core, "factions"), str(request.faction), func(chosen: Dictionary):
				_apply({"faction": str(chosen.id)}))
			_add_picker("Outfit", Loadout.outfits_for(core, str(request.character)), str(request.outfit), func(chosen: Dictionary):
				_apply({"outfit": str(chosen.id)}))
			# "Random" is resolved from this spawner's own name, so it is a
			# different soldier per spawner and the SAME one every time this
			# project is opened.
			var poses: Array = [{"id": Loadout.ROLE_RANDOM, "label": "Random"}]
			poses.append_array(Loadout.catalogue_list(core, "roles"))
			_add_picker("Pose", poses, str(request.role), func(chosen: Dictionary):
				_apply({"role": str(chosen.id)}))
			# STILL or MOVING. "Still" is the soldier frozen at the first frame
			# of the pose above; "Idle animation" is the same soldier built as a
			# skeleton and played through the whole clip that frame came from.
			_add_picker("Motion", [{"id": "", "label": "Still"},
					{"id": "1", "label": "Idle animation"}],
				"1" if bool(request.animated) else "", func(chosen: Dictionary):
					_apply({"animated": str(chosen.id) != ""}))
		for kind in ([["Weapon", "Weapon"]] if soldier else [["Weapon", "Weapon"], ["Gadget", "Gadget"], ["Throwable", "Throwable"]]):
			var options: Array = []
			for it in items:
				if str((it as Dictionary).get("group", "")) == kind[0]: options.append(it)
			_add_picker(kind[1], options, item, func(chosen: Dictionary):
				var changes := {"item": str(chosen.id), "portalitem": Loadout.portal_match(chosen)}
				for slot in Loadout.SLOTS: changes["attachment_" + slot] = ""
				_apply(changes))
		for slot in Loadout.SLOTS:
			var choices := Loadout.slot_choices(core, item, slot)
			var current := str(values.get("attachment_" + slot, ""))
			if choices.is_empty() and current == "": continue
			var options: Array = [{"id": "", "label": "Factory"}]
			options.append_array(choices)
			_add_picker(Loadout.SLOT_LABELS[slot], options, current, func(chosen: Dictionary):
				_apply({"attachment_" + slot: str(chosen.id)}))
		if soldier:
			return
		var portal_options: Array = []
		for p in Loadout.loot_items(): portal_options.append({"id": p, "label": p.replace("_", " ")})
		var portal := str(values.get("portalitem", ""))
		if portal == "" and item == Loadout.DEFAULT_ITEM: portal = "Weapons.Carbine_M4A1"
		_add_picker("Portal gameplay item", portal_options, portal, func(chosen: Dictionary):
			_apply({"portalitem": str(chosen.id)}))
		_refresh_preview()

	func _add_picker(label_text: String, options: Array, current: String, on_pick: Callable) -> void:
		var label := Label.new()
		label.text = label_text
		fields.add_child(label)
		var button := OptionButton.new()
		button.fit_to_longest_item = false
		button.disabled = options.is_empty()
		var selected := -1
		button.add_item("Choose...")
		button.set_item_metadata(0, {})
		for o in options:
			var d: Dictionary = o
			button.add_item(str(d.get("label", d.get("id", ""))))
			var idx := button.item_count - 1
			button.set_item_metadata(idx, d)
			if str(d.get("description", "")) != "": button.set_item_tooltip(idx, str(d.description))
			if str(d.get("id", "")) == current: selected = idx
		button.select(maxi(selected, 0))
		button.item_selected.connect(func(index: int):
			var d: Variant = button.get_item_metadata(index)
			if d is Dictionary and not (d as Dictionary).is_empty(): on_pick.call(d))
		fields.add_child(button)

	func _apply(changes: Dictionary) -> void:
		if not is_instance_valid(node): return
		var before := Loadout.values_of(node)
		var after := before.duplicate()
		for k in changes:
			if str(changes[k]) == "": after.erase(k)
			else: after[k] = changes[k]
		var undo: EditorUndoRedoManager = host.undo if host != null else null
		if undo != null:
			undo.create_action("Change soldier spawner loadout" if soldier else "Change loot spawner loadout",
				UndoRedo.MERGE_DISABLE, node)
			undo.add_do_method(host, "store_loadout", node, after)
			undo.add_undo_method(host, "store_loadout", node, before)
			undo.commit_action()
		elif host != null:
			host.store_loadout(node, after)
		if is_instance_valid(node) and is_inside_tree():
			Loadout.attachments(core, Loadout.item_of(after))
			_populate()

	func _refresh_preview() -> void:
		for c in slot_layer.get_children(): c.queue_free()
		var mesh: Mesh = null
		var anchors := {}
		var hp := node.get_node_or_null(HighpolyLib.HP_NODE)
		if hp != null and hp.has_meta("hp_slot_anchors"):
			var w := hp.get_node_or_null("Weapon") as MeshInstance3D
			if w != null: mesh = w.mesh
			anchors = hp.get_meta("hp_slot_anchors")
		if mesh == null:
			var built := Loadout.build_weapon(HighpolyLib.game_source, Loadout.values_of(node))
			if str(built.get("error", "")) != "":
				status.text = str(built.error)
				preview_mesh.mesh = null
				return
			var root: Node3D = built.node
			mesh = (root.get_node("Weapon") as MeshInstance3D).mesh
			anchors = built.anchors
			root.free()
		preview_mesh.mesh = mesh
		var box := mesh.get_aabb()
		var center := box.get_center()
		# The barrel runs along game +Z; a camera on -X looks at the weapon's
		# side with the barrel to the right.
		var width := maxf(maxf(box.size.z * 1.22, box.size.y * 2.44), 0.2)
		camera.size = width * 0.5
		camera.position = center + Vector3(-5.0 - box.size.x, 0, 0)
		camera.rotation_degrees = Vector3(0, -90, 0)
		var holder := preview_holder.size if preview_holder.size.x > 1 else preview_holder.custom_minimum_size
		var used: Array = []
		for slot in ["scp", "sca", "brl", "mzl", "mag", "btm"]:
			if not anchors.has(slot): continue
			var options := Loadout.slot_choices(core, Loadout.item_of(Loadout.values_of(node)), slot)
			if options.is_empty(): continue
			var p: Vector3 = anchors[slot]
			var pt := Vector2(0.5 * holder.x + (p.z - center.z) * holder.x / width,
				0.5 * holder.y - (p.y - center.y) * holder.x / width)
			pt.x = clampf(pt.x, 15.0, holder.x - 15.0)
			pt.y = clampf(pt.y, 8.0, holder.y - 8.0)
			for other in used:
				if absf(pt.x - (other as Vector2).x) < 30 and absf(pt.y - (other as Vector2).y) < 12:
					pt.y = clampf((other as Vector2).y + 14, 8.0, holder.y - 8.0)
			used.append(pt)
			var button := MenuButton.new()
			button.text = {"scp": "Optic", "sca": "Canted", "brl": "Barrel", "mzl": "Muzzle", "mag": "Mag", "btm": "Grip"}[slot]
			button.flat = false
			button.position = pt - Vector2(24, 10)
			var popup := button.get_popup()
			popup.add_item("Factory")
			popup.set_item_metadata(0, "")
			for o in options:
				popup.add_item(str((o as Dictionary).label))
				popup.set_item_metadata(popup.item_count - 1, str((o as Dictionary).id))
			popup.id_pressed.connect(func(id: int):
				var index := popup.get_item_index(id)
				_apply({"attachment_" + slot: str(popup.get_item_metadata(index))}))
			slot_layer.add_child(button)
