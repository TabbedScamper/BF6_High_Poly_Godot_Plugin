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
const FONT_SIZE := 12

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
	_lbl.add_theme_font_size_override("font_size", FONT_SIZE)
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

# Where the box goes and how big it is. Split out from the animation so the
# geometry can be checked without waiting on a tween.
func layout_for(target_rect: Rect2, text: String) -> Rect2:
	var w: float = maxf(40.0, size.x - MARGIN * 2.0)
	var font := _lbl.get_theme_font("font")
	var fs := _lbl.get_theme_font_size("font_size")
	var text_h := font.get_multiline_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, w - PAD * 2.0, fs).y
	var h := text_h + PAD * 2.0
	# below the control by default; above it when there is no room below, so a
	# description never hangs off the bottom of the panel
	var y := target_rect.end.y + GAP
	if y + h > size.y - MARGIN:
		y = target_rect.position.y - GAP - h
	y = clampf(y, MARGIN, maxf(MARGIN, size.y - MARGIN - h))
	return Rect2(MARGIN, y, w, h)

func _present() -> void:
	if _target == null or not is_instance_valid(_target): return
	if not _target.is_visible_in_tree(): return
	var text := str(_target.get_meta("hp_tip", ""))
	if text == "": return
	_lbl.text = text
	var origin := get_global_rect().position
	var r := layout_for(Rect2(_target.get_global_rect().position - origin,
		_target.size), text)
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
