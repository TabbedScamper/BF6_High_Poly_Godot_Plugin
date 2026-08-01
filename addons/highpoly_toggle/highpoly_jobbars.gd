@tool
extends VBoxContainer
class_name HighpolyJobBars
# One progress bar per in-flight download, stacked.
#
# The plugin pulls from several places at once — a map's data zip, its prop
# meshes, its maptile, a plugin self-update, all while the background model sync
# runs — so a single shared bar would either fight over itself or hide most of
# the work. Each download gets its own row instead, keyed by its label, created
# on the first byte and freed when it ends.
#
# Lives outside highpoly_toggle.gd because EditorPlugin can only be instantiated
# by the editor, which makes anything defined there impossible to test headlessly.

const Pal = preload("highpoly_theme.gd")

var _rows: Dictionary = {}     # label -> {"bar": ProgressBar, "lbl": Label}

func _init() -> void:
	visible = false

static func fmt_size(bytes: int) -> String:
	if bytes >= 1073741824: return "%.2f GB" % (bytes / 1073741824.0)
	return "%.1f MB" % (bytes / 1048576.0)

func active() -> int:
	return _rows.size()

# Create-or-update the row for this download. total = 0 means the server sent no
# Content-Length yet: show a stub rather than a 0% or (worse) full bar.
func progress(label: String, done: int, total: int) -> void:
	var row: Dictionary = _rows.get(label, {})
	if row.is_empty():
		var lb := Label.new()
		lb.add_theme_font_size_override("font_size", 11)
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var bar: ProgressBar = Pal.bar(ProgressBar.new())
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		add_child(lb)
		add_child(bar)
		row = {"bar": bar, "lbl": lb}
		_rows[label] = row
		visible = true
	var b: ProgressBar = row["bar"]
	var l: Label = row["lbl"]
	if total > 0:
		b.value = clampf(float(done) / float(total), 0.0, 1.0)
		l.text = "%s %s / %s" % [label, fmt_size(done), fmt_size(total)]
	else:
		b.value = 0.05
		l.text = ("%s %s…" % [label, fmt_size(done)]) if done > 0 else "%s…" % label

func end(label: String) -> void:
	var row: Dictionary = _rows.get(label, {})
	if row.is_empty(): return          # unknown/duplicate end is a no-op
	(row["bar"] as Node).queue_free()
	(row["lbl"] as Node).queue_free()
	_rows.erase(label)
	visible = not _rows.is_empty()

func clear() -> void:
	for label in _rows.keys():
		end(label)
