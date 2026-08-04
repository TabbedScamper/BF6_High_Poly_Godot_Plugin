@tool
extends VBoxContainer
class_name HighpolySection
# A collapsible section: centred title over a line that fades out at both ends.
#
#   closed   title centred, both white. Hovering warms them to the accent and
#            drops a description of what the section is for.
#   opening  the description goes, the title settles solid accent, and the
#            contents rise out from behind the line as they fade in, starting a
#            little below it rather than flush against it.
#   closing  the same in reverse.
#
# The contents live in a clipped box whose height is what actually animates, so
# the sections below reflow as this one grows instead of being overlapped. The
# contents slide from ABOVE zero inside that box, which is what reads as coming
# out from behind the line rather than merely appearing.
#
# The line is drawn rather than themed: a StyleBox cannot fade its own ends, and
# a hard line touching both panel edges was the thing to avoid.

const Pal = preload("highpoly_theme.gd")

const LINE_GAP := 7.0      # title baseline to line
const LINE_H := 2.0
const EDGE := 22.0         # the line stops short of the panel edges
const FADE := 64.0         # length of the fade at each end
const OPEN_SECS := 0.40
const HL_SECS := 0.28
const RISE := 24.0         # how far the contents travel on the way out
const TITLE_PAD := 4.0
const CONTENT_TOP := 8.0   # breathing room between the line and the contents

signal opened_changed(open: bool)

var content: VBoxContainer
var head: Control
var title_lbl: Label
var body: Control

var _title := ""
var _desc := ""
var _open := false
var _tw: Tween
var _tw_hl: Tween

# 0 = white, 1 = accent. Drives the title colour and the line together.
var hl := 0.0:
	set(v):
		hl = v
		if head: head.queue_redraw()
		if title_lbl:
			title_lbl.add_theme_color_override("font_color",
				Color.WHITE.lerp(Pal.accent(), v))

func setup(section_title: String, description: String) -> void:
	_title = section_title
	_desc = description
	add_theme_constant_override("separation", 0)

	head = Control.new()
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.tooltip_text = description      # adopted by the description box
	head.draw.connect(_draw_head)
	head.gui_input.connect(_head_input)
	head.mouse_entered.connect(_on_hover.bind(true))
	head.mouse_exited.connect(_on_hover.bind(false))
	head.resized.connect(_place_title)
	add_child(head)

	title_lbl = Label.new()
	title_lbl.text = section_title
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_lbl.add_theme_font_size_override("font_size", Pal.fs(16))
	head.add_child(title_lbl)

	body = Control.new()
	body.clip_contents = true            # contents are hidden behind the line
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.custom_minimum_size.y = 0.0
	body.resized.connect(_fit_content)
	add_child(body)

	content = VBoxContainer.new()
	content.set_anchors_preset(Control.PRESET_TOP_WIDE)
	content.modulate.a = 0.0
	# Re-fit when the CONTENTS change height, not only when the box does.
	# body.resized alone catches the panel being resized, but not a chip row
	# wrapping onto another line, a row becoming visible, or a label growing —
	# the content got taller inside a box still sized for the old height, so it
	# was clipped while the section below kept its old gap. That is the odd
	# spacing that appears "from time to time": it tracks whatever last changed
	# the content's own minimum size.
	content.minimum_size_changed.connect(_fit_content)
	body.add_child(content)

	hl = 0.0
	_place_title()

func is_open() -> bool:
	return _open

# ---------- geometry ----------
func _line_y() -> float:
	return title_lbl.size.y + LINE_GAP if title_lbl else LINE_GAP

func _place_title() -> void:
	if title_lbl == null or head == null: return
	title_lbl.size = title_lbl.get_minimum_size()
	title_lbl.position.y = 0.0
	title_lbl.position.x = _title_x()
	# Sized here rather than at setup(): a Label reports a smaller height until
	# it has been shaped, and a header measured off that value is too short to
	# contain its own line. _place_title runs again on the first resize, by which
	# point the real height is known.
	head.custom_minimum_size.y = title_lbl.size.y + LINE_GAP + LINE_H + TITLE_PAD

# Centred in both states. Sliding it left on open read worse than it sounded —
# the title jumping sideways drew the eye away from the contents arriving.
func _title_x() -> float:
	if head == null or title_lbl == null: return 0.0
	return maxf(EDGE, (head.size.x - title_lbl.size.x) * 0.5)

func _fit_content() -> void:
	if content == null or body == null: return
	content.size.x = body.size.x
	if _open:
		# the panel may have been resized while open; keep the box on the
		# height the contents now need
		body.custom_minimum_size.y = content.get_combined_minimum_size().y + CONTENT_TOP

# ---------- drawing ----------
func _draw_head() -> void:
	if head == null: return
	var y := _line_y()
	var c := Color.WHITE.lerp(Pal.accent(), hl)
	var x0 := EDGE
	var x3: float = maxf(x0 + 4.0, head.size.x - EDGE)
	var f: float = minf(FADE, (x3 - x0) * 0.45)
	var clear := Color(c.r, c.g, c.b, 0.0)
	# three quads: fade in, solid, fade out. draw_polygon interpolates the
	# per-vertex colours, which is how the ends dissolve instead of stopping.
	_quad(x0, x0 + f, y, clear, c)
	_quad(x0 + f, x3 - f, y, c, c)
	_quad(x3 - f, x3, y, c, clear)

func _quad(xa: float, xb: float, y: float, ca: Color, cb: Color) -> void:
	if xb <= xa: return
	head.draw_polygon(
		PackedVector2Array([Vector2(xa, y), Vector2(xb, y),
			Vector2(xb, y + LINE_H), Vector2(xa, y + LINE_H)]),
		PackedColorArray([ca, cb, cb, ca]))

# ---------- interaction ----------
func _on_hover(inside: bool) -> void:
	if _open: return                     # an open section stays lit
	if _tw_hl and _tw_hl.is_valid(): _tw_hl.kill()
	_tw_hl = create_tween()
	_tw_hl.tween_property(self, "hl", 1.0 if inside else 0.0, HL_SECS)

func _head_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
			and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		set_open(not _open)

func set_open(v: bool, animate := true) -> void:
	if _open == v and animate: return
	_open = v
	# The description belongs to the closed state: opening answers the question
	# it was there to answer. Blanking the metadata is what the description box
	# reads, so it simply has nothing to show while open.
	if head:
		head.set_meta("hp_tip", "" if v else _desc)
		if head.tooltip_text != "": head.tooltip_text = ""
	opened_changed.emit(v)

	var target := 0.0
	if v:
		content.size.x = body.size.x
		# a VBox of wrapped rows only reports its true height once its children
		# have been shaped, which happens on the next frame
		await get_tree().process_frame
		if not _open: return             # closed again during that frame
		target = content.get_combined_minimum_size().y + CONTENT_TOP

	if _tw and _tw.is_valid(): _tw.kill()
	if _tw_hl and _tw_hl.is_valid(): _tw_hl.kill()
	var rest := CONTENT_TOP if v else CONTENT_TOP - RISE
	if not animate:
		body.custom_minimum_size.y = target
		content.position.y = rest
		content.modulate.a = 1.0 if v else 0.0
		hl = 1.0 if v else 0.0
		_place_title()
		return

	_tw = create_tween().set_parallel(true)
	_tw.tween_property(body, "custom_minimum_size:y", target, OPEN_SECS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_property(content, "position:y", rest, OPEN_SECS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_property(content, "modulate:a", 1.0 if v else 0.0,
		OPEN_SECS * (0.9 if v else 0.55))
	_tw.tween_property(self, "hl", 1.0 if v else 0.0, HL_SECS)
	if v: content.position.y = CONTENT_TOP - RISE
