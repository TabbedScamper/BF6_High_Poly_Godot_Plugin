@tool
extends Control
class_name HighpolyTips
# Hover descriptions, as a box that slides down inside the panel.
#
# Godot's own tooltip sizes itself to its text and floats in a free-standing
# popup, so the long explanations this plugin carries come out as a ribbon
# stretching well past the panel and off the side of the screen. It also cannot
# be styled or delayed per control - the delay is a single project-wide setting,
# and changing that would alter every tooltip in the editor.
#
# So the descriptions are handled here instead: adopted off the controls (their
# tooltip_text is moved into metadata and cleared, which is what stops Godot
# drawing its own), shown after a deliberate hover pause, wrapped to the panel's
# own width, and animated down from under the control being hovered. The box is
# a sibling of the scroller inside a clipped root, so it physically cannot leave
# the panel.

const Pal = preload("highpoly_theme.gd")

const DELAY := 0.65        # hover pause before it appears; long enough not to flicker
const SLIDE := 10.0        # how far it travels on the way in
const FADE := 0.16
const MARGIN := 8.0        # gap to the panel edges
const PAD := 8.0           # text inset inside the box
const GAP := 6.0           # gap between the control and its description

var _box: Panel
var _lbl: Label
var _timer: Timer
var _target: Control = null
var _tween: Tween

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE     # never steal hover from the controls

func _ready() -> void:
	_box = Panel.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_stylebox_override("panel", Pal.tip_box())
	_box.visible = false
	add_child(_box)
	_lbl = Label.new()
	_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# no font or size override: the description reads in the same face and size
	# as the panel it belongs to
	_lbl.add_theme_color_override("font_color", Color.WHITE)
	_box.add_child(_lbl)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = DELAY
	_timer.timeout.connect(_present)
	add_child(_timer)

# Take the descriptions off every control under `n` and listen for hover.
# Returns how many it adopted. Run once the panel is fully built.
func adopt(n: Node) -> int:
	var count := 0
	for c in n.get_children():
		if c is Control:
			var ctl := c as Control
			if ctl.tooltip_text != "":
				ctl.set_meta("hp_tip", ctl.tooltip_text)
				ctl.tooltip_text = ""      # this is what suppresses Godot's own
				count += 1
				# Labels ignore the mouse by default and would never report a
				# hover; PASS lets them notice it without swallowing clicks or
				# the scroll wheel.
				if ctl.mouse_filter == Control.MOUSE_FILTER_IGNORE:
					ctl.mouse_filter = Control.MOUSE_FILTER_PASS
			if not ctl.mouse_entered.is_connected(_on_enter):
				ctl.mouse_entered.connect(_on_enter.bind(ctl))
				ctl.mouse_exited.connect(_on_exit.bind(ctl))
		count += adopt(c)
	return count

func hide_now() -> void:
	_target = null
	if _timer: _timer.stop()
	if _tween and _tween.is_valid(): _tween.kill()
	if _box: _box.visible = false

func shown() -> bool:
	return _box != null and _box.visible

func _on_enter(c: Control) -> void:
	# a control whose description was set after adopt() ran still gets picked up
	if c.tooltip_text != "":
		c.set_meta("hp_tip", c.tooltip_text)
		c.tooltip_text = ""
	if not c.has_meta("hp_tip"): return
	_target = c
	if _box: _box.visible = false
	if _timer: _timer.start(DELAY)

func _on_exit(c: Control) -> void:
	if _target == c: hide_now()

func text_width() -> float:
	return maxf(24.0, size.x - MARGIN * 2.0 - PAD * 2.0)

# Where the box goes, given how tall the wrapped text turned out. Pure geometry,
# separate from measuring and animating so it can be checked directly.
func layout_for(target_rect: Rect2, text_h: float) -> Rect2:
	var w: float = maxf(40.0, size.x - MARGIN * 2.0)
	# clamped to the panel: a description is never worth growing past the edges
	var h: float = minf(text_h + PAD * 2.0, maxf(40.0, size.y - MARGIN * 2.0))
	# below the control by default; above it when there is no room below, so a
	# description never hangs off the bottom of the panel
	var y := target_rect.end.y + GAP
	if y + h > size.y - MARGIN:
		y = target_rect.position.y - GAP - h
	y = clampf(y, MARGIN, maxf(MARGIN, size.y - MARGIN - h))
	return Rect2(MARGIN, y, w, h)

func _present() -> void:
	var tgt := _target
	if tgt == null or not is_instance_valid(tgt) or not tgt.is_visible_in_tree(): return
	var text := str(tgt.get_meta("hp_tip", ""))
	if text == "": return
	_lbl.text = text
	_lbl.size = Vector2(text_width(), 10.0)
	# A Label reports one line until it has been shaped, which happens on the
	# next frame — measuring any sooner gives a box less than half the height it
	# needs and the description gets cut off. Font metrics can't answer this
	# either: get_multiline_string_size() ignores the label's line spacing and
	# under-reports by the same margin.
	await get_tree().process_frame
	if _target != tgt or not is_instance_valid(tgt): return
	var r := layout_for(Rect2(
		tgt.get_global_rect().position - get_global_rect().position, tgt.size),
		_lbl.get_minimum_size().y)
	_box.position = Vector2(r.position.x, r.position.y - SLIDE)
	_box.size = r.size
	_lbl.position = Vector2(PAD, PAD)
	_lbl.size = Vector2(r.size.x - PAD * 2.0, r.size.y - PAD * 2.0)
	_box.modulate.a = 0.0
	_box.visible = true
	if _tween and _tween.is_valid(): _tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_box, "position:y", r.position.y, FADE) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_box, "modulate:a", 1.0, FADE)
