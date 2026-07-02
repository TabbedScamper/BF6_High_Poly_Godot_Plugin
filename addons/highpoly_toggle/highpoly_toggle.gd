@tool
extends EditorPlugin
# Interchange placed pieces between low-poly (proxy, exports) and high-poly (editor-only view).
# Build in low-poly for performance; flip to high-poly any time. Per-selection or whole scene.

var dock: VBoxContainer
var lbl: Label

func _enter_tree() -> void:
	dock = VBoxContainer.new()
	dock.name = "High-Poly"

	var title := Label.new()
	title.text = "Low / High-Poly Interchange"
	dock.add_child(title)

	var all_hi := Button.new(); all_hi.text = "Scene → High-Poly"
	all_hi.pressed.connect(func(): _do(false, true))
	dock.add_child(all_hi)

	var all_lo := Button.new(); all_lo.text = "Scene → Low-Poly"
	all_lo.pressed.connect(func(): _do(false, false))
	dock.add_child(all_lo)

	var sep := HSeparator.new(); dock.add_child(sep)

	var sel_hi := Button.new(); sel_hi.text = "Selected → High-Poly"
	sel_hi.pressed.connect(func(): _do(true, true))
	dock.add_child(sel_hi)

	var sel_lo := Button.new(); sel_lo.text = "Selected → Low-Poly"
	sel_lo.pressed.connect(func(): _do(true, false))
	dock.add_child(sel_lo)

	var sep2 := HSeparator.new(); dock.add_child(sep2)

	var upd := Button.new(); upd.text = "Update Models"
	upd.tooltip_text = "Pull corrected models from the community registry (only props deployed locally)"
	upd.pressed.connect(func(): HighpolyUpdater.run(dock, func(msg: String): lbl.text = msg))
	dock.add_child(upd)

	lbl = Label.new()
	lbl.text = "%d high-poly assets available" % HighpolyLib.keys().size()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dock.add_child(lbl)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

func _exit_tree() -> void:
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()

func _do(selected_only: bool, high: bool) -> void:
	var roots: Array = []
	if selected_only:
		roots = EditorInterface.get_selection().get_selected_nodes()
		if roots.is_empty():
			lbl.text = "Nothing selected"
			return
	else:
		var r := EditorInterface.get_edited_scene_root()
		if r == null:
			lbl.text = "No scene open"
			return
		roots = [r]
	var n := 0
	for root in roots:
		n += HighpolyLib.apply(root, high)
	lbl.text = "%s %d piece(s)" % ["High-poly:" if high else "Low-poly:", n]
