@tool
extends Window
# MATERIAL INTERACTIONS: what the game does when two surfaces meet.
#
# The level authors a square matrix over the game's material ids deciding the
# impact sound, effect, decal, footprint and penetration for every surface pair.
# This window reads it through the core and shows it; the Unreal add-on shows
# the same rows from the same calls, because the ordering, the categories and
# the "is this material shipped" decision all live in the core rather than here.
#
# Audio is the densest kind by a wide margin: 20,001 of 49,356 relations on
# mp_subsurface, more than effects, decals and everything else combined.
#
# Everything is read on demand. The core parses the level's grid once and caches
# it, so the first query pays for the decode and the rest are lookups.

const BUSIEST_ROWS := 24

var _env = null
var _level := ""
var _summary: Label = null
var _list: Tree = null
var _detail: RichTextLabel = null
var _a: SpinBox = null
var _b: SpinBox = null
var _pair: RichTextLabel = null
var _id_max := 784


static func open(parent: Node, env, level: String) -> Window:
	var w = new()
	w._env = env
	w._level = level
	parent.add_child(w)
	w.popup_centered(Vector2i(940, 620))
	return w


func _init() -> void:
	title = "Material interactions"
	close_requested.connect(func(): queue_free())

	var root := VBoxContainer.new()
	root.anchor_right = 1.0
	root.anchor_bottom = 1.0
	root.offset_left = 8
	root.offset_top = 8
	root.offset_right = -8
	root.offset_bottom = -8
	add_child(root)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_summary)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(left)
	var busiest_label := Label.new()
	busiest_label.text = "Busiest surfaces on this level"
	left.add_child(busiest_label)
	_list = Tree.new()
	_list.columns = 3
	_list.column_titles_visible = true
	_list.set_column_title(0, "material")
	_list.set_column_title(1, "partners")
	_list.set_column_title(2, "relations")
	_list.hide_root = true
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_pick)
	left.add_child(_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right)
	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_detail)

	var pair_row := HBoxContainer.new()
	right.add_child(pair_row)
	var l1 := Label.new(); l1.text = "when material"; pair_row.add_child(l1)
	_a = SpinBox.new(); _a.max_value = _id_max; pair_row.add_child(_a)
	var l2 := Label.new(); l2.text = "meets"; pair_row.add_child(l2)
	_b = SpinBox.new(); _b.max_value = _id_max; pair_row.add_child(_b)
	var go := Button.new()
	go.text = "what happens"
	go.pressed.connect(_on_pair)
	pair_row.add_child(go)

	_pair = RichTextLabel.new()
	_pair.bbcode_enabled = true
	_pair.custom_minimum_size = Vector2(0, 190)
	right.add_child(_pair)


func _ready() -> void:
	_refresh()


func _refresh() -> void:
	if _env == null:
		_summary.text = "The native core is not available, so the material grid cannot be read."
		return
	# detail caps the ranked rows the core returns.
	var grid: Dictionary = _env.request("material_grid", BUSIEST_ROWS)
	if grid.is_empty():
		_summary.text = "Material grid unavailable: %s" % str(_env.error)
		return
	_id_max = max(0, int(grid.get("id_map_len", 785)) - 1)
	_a.max_value = _id_max
	_b.max_value = _id_max
	# The declared dimension is 128 while the real side is the level's own
	# material count. Both are shown because a reader that trusts the declared
	# one reads the wrong rectangle, and that trap is worth keeping visible.
	_summary.text = ("%s: %d materials shipped of %d in the game-wide id space (%d fall back to the default). "
		+ "Grid %d x %d, declared dimension %d. %d cells authored, %d relations, %d relation types.") % [
		_level, int(grid.get("shipped_materials", 0)), int(grid.get("id_map_len", 0)),
		int(grid.get("fallback_ids", 0)), int(grid.get("side", 0)), int(grid.get("side", 0)),
		int(grid.get("declared_dim", 0)), int(grid.get("occupied_cells", 0)),
		int(grid.get("relations", 0)), int(grid.get("relation_types", 0))]

	_list.clear()
	var root := _list.create_item()
	for entry in grid.get("busiest", []):
		var e: Dictionary = entry
		var item := _list.create_item(root)
		item.set_text(0, str(int(e.get("material", -1))))
		item.set_text(1, str(int(e.get("partners", 0))))
		item.set_text(2, str(int(e.get("relations", 0))))
		item.set_metadata(0, int(e.get("material", -1)))
	var first := root.get_first_child()
	if first != null:
		first.select(0)


func _on_pick() -> void:
	var item := _list.get_selected()
	if item == null: return
	var id := int(item.get_metadata(0))
	_a.value = id
	var p: Dictionary = _env.request("material_profile", id)
	if p.is_empty():
		_detail.text = "Profile unavailable: %s" % str(_env.error)
		return
	# shipped=0 is a real answer, not an empty one: the level does not carry this
	# material and the game falls back to the default. Saying so beats showing
	# the default material's relations under this material's name.
	if int(p.get("shipped", 0)) == 0:
		_detail.text = "[b]Material %d[/b]\nThis level does not ship it. The game falls back to the default material (0)." % id
		return
	var lines := "[b]Material %d[/b]  row %d\n%d partner material(s), %d relation(s) in its row\n\n" % [
		id, int(p.get("row", -1)), int(p.get("partners", 0)), int(p.get("row_relations", 0))]
	var cats: Dictionary = p.get("categories", {})
	var names := cats.keys()
	names.sort_custom(func(x, y): return int(cats[x]) > int(cats[y]))
	for n in names:
		lines += "  %-14s %d\n" % [str(n), int(cats[n])]
	_detail.text = lines


func _on_pair() -> void:
	var a := int(_a.value)
	var b := int(_b.value)
	# The ordered pair is packed as (a << 10) | b, which fits because a material
	# id is 10 bits. Ordered on purpose: four pairs per level are authored one
	# way, and symmetrising would invent relations on exactly those.
	var r: Dictionary = _env.request("material_pair", (a << 10) | b)
	if r.is_empty():
		_pair.text = "Pair unavailable: %s" % str(_env.error)
		return
	var rels: Array = r.get("relations", [])
	if rels.is_empty():
		_pair.text = "Material %d meeting material %d: nothing authored." % [a, b]
		return
	var by := {}
	for entry in rels:
		var e: Dictionary = entry
		var c := str(e.get("category", ""))
		if not by.has(c): by[c] = []
		(by[c] as Array).append(e)
	var text := "[b]Material %d meets material %d[/b]  %d relation(s)\n" % [a, b, rels.size()]
	var keys := by.keys()
	keys.sort()
	for c in keys:
		text += "\n[b]%s[/b]\n" % str(c)
		for entry in (by[c] as Array):
			var e: Dictionary = entry
			var name := str(e.get("name", ""))
			text += "  %s\n" % (name if not name.is_empty() else str(e.get("type", "")))
	_pair.text = text
