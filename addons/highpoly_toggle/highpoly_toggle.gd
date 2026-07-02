@tool
extends EditorPlugin
# Low / Medium / High-poly interchange for Portal SDK level building.
# - Mode selector drives the whole scene AND newly placed pieces (placement
#   stays the low-poly proxy; the visual overlay attaches automatically).
# - Object Library thumbnails render the active tier's asset.
# - Textured toggle swaps overlays to flat gray (geometry study mode).

var dock: VBoxContainer
var lbl: Label
var mode_btn: OptionButton
var tex_chk: CheckBox
const PreviewsScript = preload("res://addons/highpoly_toggle/highpoly_previews.gd")
var previews: Node

const META_MODE := "highpoly_mode"
const META_TEX := "highpoly_textured"

func _mode() -> int:
	return mode_btn.get_selected_id() if mode_btn else HighpolyLib.Tier.LOW

func _textured() -> bool:
	return tex_chk.button_pressed if tex_chk else true

func _enter_tree() -> void:
	dock = VBoxContainer.new()
	dock.name = "High-Poly"

	var title := Label.new()
	title.text = "Detail Mode"
	dock.add_child(title)

	mode_btn = OptionButton.new()
	mode_btn.add_item("Low-Poly (proxies)", HighpolyLib.Tier.LOW)
	mode_btn.add_item("Medium-Poly", HighpolyLib.Tier.MEDIUM)
	mode_btn.add_item("High-Poly", HighpolyLib.Tier.HIGH)
	mode_btn.item_selected.connect(func(_i): _mode_changed())
	dock.add_child(mode_btn)

	tex_chk = CheckBox.new()
	tex_chk.text = "Textured"
	tex_chk.button_pressed = true
	tex_chk.toggled.connect(func(_v): _mode_changed())
	dock.add_child(tex_chk)

	var apply_btn := Button.new(); apply_btn.text = "Re-apply Scene"
	apply_btn.pressed.connect(_apply_scene)
	dock.add_child(apply_btn)

	var sep := HSeparator.new(); dock.add_child(sep)

	var sel_hi := Button.new(); sel_hi.text = "Selected → Current Mode"
	sel_hi.pressed.connect(func(): _apply_selected(_mode()))
	dock.add_child(sel_hi)

	var sel_lo := Button.new(); sel_lo.text = "Selected → Low-Poly"
	sel_lo.pressed.connect(func(): _apply_selected(HighpolyLib.Tier.LOW))
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

	previews = PreviewsScript.new()
	dock.add_child(previews)

	# restore per-project mode
	var es := EditorInterface.get_editor_settings()
	var m: Variant = es.get_project_metadata("highpoly", "mode", HighpolyLib.Tier.LOW)
	var t: Variant = es.get_project_metadata("highpoly", "textured", true)
	mode_btn.select(mode_btn.get_item_index(int(m)))
	tex_chk.button_pressed = bool(t)
	previews.tier = int(m)

	# auto-overlay for pieces placed while a detail mode is active
	get_tree().node_added.connect(_on_node_added)

func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()

func _mode_changed() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_project_metadata("highpoly", "mode", _mode())
	es.set_project_metadata("highpoly", "textured", _textured())
	previews.tier = _mode()
	_apply_scene()

func _apply_scene() -> void:
	var r := EditorInterface.get_edited_scene_root()
	if r == null:
		lbl.text = "No scene open"; return
	var n := HighpolyLib.apply(r, _mode(), _textured())
	lbl.text = "%s: %d piece(s)" % [mode_btn.get_item_text(mode_btn.selected), n]

func _apply_selected(tier: int) -> void:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	if sel.is_empty():
		lbl.text = "Nothing selected"; return
	var n := 0
	for s in sel:
		n += HighpolyLib.apply(s, tier, _textured())
	lbl.text = "Selected -> %d piece(s)" % n

func _on_node_added(node: Node) -> void:
	if _mode() == HighpolyLib.Tier.LOW: return
	if not (node is Node3D): return
	if node.name == HighpolyLib.HP_NODE: return
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root.is_ancestor_of(node): return
	if HighpolyLib.in_overlay(node): return
	if HighpolyLib.match_key_public(node) == "": return
	# defer: let the editor finish placing/naming/positioning the instance
	_swap_deferred.call_deferred(node)

func _swap_deferred(node: Node) -> void:
	if not is_instance_valid(node) or not (node is Node3D): return
	if node.get_node_or_null(HighpolyLib.HP_NODE) != null: return
	var ks := HighpolyLib.keys()
	var k := HighpolyLib.match_key_public(node)
	if k == "": return
	HighpolyLib.apply_one(node as Node3D, ks[k], _mode(), _textured())
