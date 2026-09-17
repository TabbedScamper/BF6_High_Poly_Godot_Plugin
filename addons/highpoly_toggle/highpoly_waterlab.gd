@tool
extends Object
class_name HighpolyWaterLab
# LIVE WATER CONTROLS: every dial on the ocean shader, adjustable while you look.
#
# WHY THIS EXISTS. Tsuru Reef's water read as "boiling - tiny waves inside the
# swells moving really fast", and three separate diagnoses of it were wrong. Each
# one was reasoned from the shader source, shipped, and then cost a round trip to
# find out it had changed nothing. Reading code is a bad instrument for a
# question about motion; looking at it while turning one dial is a good one.
#
# So this exposes the uniforms rather than guessing which one matters. Turn a
# slider, see the water change, and the culprit names itself. Everything here is
# LIVE - it writes straight to the material, no rebuild - and RESET restores the
# values the level authored, so nothing here can permanently alter what the map
# says.
#
# Nothing in this file decides what the water should look like. It is an
# instrument, not a source of truth; the authored values still come from the
# core, and anything changed here is lost on the next build by design.

const SHADER_MARK := "water_native"

static var _authored: Dictionary = {}     # uniform name -> Variant, as built
static var _mats: Array = []


# Every live water material under `root`. Walks rather than asking the driver,
# because the driver is a private node and a surface can exist without it.
static func materials_of(root: Node) -> Array:
	var out: Array = []
	if root == null: return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		var m: Variant = null
		if n is GeometryInstance3D:
			m = (n as GeometryInstance3D).material_override
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			if sm.shader != null and str(sm.shader.resource_path).contains(SHADER_MARK):
				if not out.has(sm): out.append(sm)
	return out


static func _read(name: String, fallback: float) -> float:
	for m in _mats:
		var v: Variant = (m as ShaderMaterial).get_shader_parameter(name)
		if v != null: return float(v)
	return fallback


static func _set_all(name: String, value: Variant) -> void:
	for m in _mats:
		(m as ShaderMaterial).set_shader_parameter(name, value)


# One component of a vec4 uniform, so per-cascade values (choppiness lives in
# cascadeN.y) are reachable without a separate uniform for each.
static func _set_component(name: String, index: int, value: float) -> void:
	for m in _mats:
		var sm := m as ShaderMaterial
		var v: Variant = sm.get_shader_parameter(name)
		if v is Vector4:
			var q: Vector4 = v
			q[index] = value
			sm.set_shader_parameter(name, q)


static func _capture() -> void:
	_authored.clear()
	if _mats.is_empty(): return
	var sm := _mats[0] as ShaderMaterial
	if sm.shader == null: return
	for u in sm.shader.get_shader_uniform_list():
		var n := str((u as Dictionary)["name"])
		_authored[n] = sm.get_shader_parameter(n)


static func _restore() -> void:
	for n in _authored.keys():
		# A uniform the material never set comes back null; writing null clears
		# the override and the shader's own default applies, which is what
		# "authored" meant for it in the first place.
		_set_all(n, _authored[n])


# ---------------------------------------------------------------- the dialog

static func open(root: Node) -> void:
	_mats = materials_of(root)
	var dlg := AcceptDialog.new()
	dlg.title = "Water Lab"
	dlg.ok_button_text = "Close"
	dlg.min_size = Vector2i(460, 640)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(440, 560)
	dlg.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

	if _mats.is_empty():
		var none := Label.new()
		none.text = "No water surface in this scene.\n\nBuild a map with Water on, then reopen this."
		box.add_child(none)
		EditorInterface.get_base_control().add_child(dlg)
		dlg.popup_centered()
		dlg.confirmed.connect(dlg.queue_free)
		dlg.canceled.connect(dlg.queue_free)
		return

	_capture()
	var head := Label.new()
	head.text = "%d water material(s). Changes are live and are lost on the next build." % _mats.size()
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(head)

	# WHICH WAVE SOURCE. The first question for anything moving wrongly: turn
	# them off one at a time until the motion stops.
	_group(box, "Wave sources — turn off to find what is moving")
	for i in range(4):
		_mask_toggle(box, i, "Cascade %d" % i,
			"One of the four FFT wave simulations the level authors. "
			+ "Cascade 0 is the big swell; 3 is the finest detail.")
	_check(box, "Interactive waves", "interactive_mask",
		"A separate Gerstner wave sum, not one of the four cascades.")

	_group(box, "Choppiness — per cascade")
	for i in range(4):
		_vec_slider(box, "Cascade %d choppiness" % i, "cascade%d" % i, 1, 0.0, 3.0,
			"How sharp the wave crests are. Above about 1.0 the surface can fold "
			+ "through itself, which reads as churn.")

	_group(box, "Speed")
	_slider(box, "Detail sheet flow", "micro_flow_speed", 0.0, 3.0, 0.9,
		"How fast the fine surface detail scrolls.")
	_slider(box, "Broad pattern speed", "broad_time_scale", 0.0, 3.0, 0.0,
		"How fast the broad crest sheet scrolls. 0 holds it still, which is "
		+ "correct - it marks WHERE crests form rather than animating. A "
		+ "placeholder of 1.0 here was the 'boiling water'.")
	_slider(box, "Interactive wave rate", "interactive_rate", 0.0, 2.0, 0.35,
		"How fast the Gerstner sum advances. This is a default, not a value read "
		+ "from the game.")

	_group(box, "Shape")
	_slider(box, "Wave amplitude", "amplitude", 0.0, 3.0, 1.0, "Overall wave height.")
	_slider(box, "Interactive height", "interactive_height", 0.0, 3.0, 0.0, "")
	_slider(box, "Interactive length", "interactive_length", 4.0, 300.0, 120.0,
		"Base wavelength of the Gerstner sum, in metres.")

	_group(box, "Surface detail")
	_check(box, "Detail sheets", "use_sheets", "")
	_slider(box, "Detail strength", "detail_strength", 0.0, 2.0, 1.0, "")
	_slider(box, "Detail tiling", "micro_uv_scale", 0.001, 0.3, 0.0464,
		"How small the fine detail is. Larger tiles it tighter.")
	_slider(box, "Detail fade start (m)", "detail_fade_start", 0.0, 500.0, 100.0, "")
	_slider(box, "Detail fade end (m)", "detail_fade_end", 0.0, 1500.0, 300.0,
		"Beyond this distance the fine detail is gone. Bring it in to stop "
		+ "distant shimmer.")
	_check(box, "Broad pattern", "use_broad", "")
	_slider(box, "Broad wave size", "broad_wave_size", 0.0, 5.0, 1.0, "")

	_group(box, "Foam")
	_check(box, "Foam chain", "foam_chain", "")
	_slider(box, "Foam sheet strength", "foam_sheet_strength", 0.0, 2.0, 0.35, "")
	_slider(box, "Foam contrast", "foam_contrast", 0.0, 4.0, 1.0, "")
	_slider(box, "Foam wave height", "foam_wave_height", 0.0, 5.0, 0.0, "")
	_check(box, "Contact foam", "use_contact", "")
	_slider(box, "Contact gain", "contact_gain", 0.0, 2.0, 0.916, "")

	_group(box, "Material")
	_slider(box, "Water roughness", "water_roughness", 0.0, 1.0, 0.04, "")
	_slider(box, "Foam roughness", "foam_roughness", 0.0, 1.0, 0.3, "")
	_slider(box, "Specular", "water_specular", 0.0, 2.0, 0.4, "")

	var reset := Button.new()
	reset.text = "Reset to the level's authored values"
	reset.tooltip_text = "Puts every dial back to what the map says. Nothing here is saved."
	box.add_child(reset)
	reset.pressed.connect(func():
		_restore()
		# Rebuilding the rows is simpler than tracking every control, and this
		# dialog is an instrument - reopening it costs nothing.
		dlg.queue_free()
		open(root))

	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_centered()
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)


# ------------------------------------------------------------------ controls

static func _group(box: VBoxContainer, title: String) -> void:
	var sep := HSeparator.new()
	box.add_child(sep)
	var l := Label.new()
	l.text = title
	box.add_child(l)


static func _slider(box: VBoxContainer, title: String, uniform: String,
		lo: float, hi: float, fallback: float, tip: String) -> void:
	var row := HBoxContainer.new()
	box.add_child(row)
	var l := Label.new()
	l.text = title
	l.custom_minimum_size = Vector2(170, 0)
	l.tooltip_text = tip
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = (hi - lo) / 200.0
	s.value = clampf(_read(uniform, fallback), lo, hi)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.tooltip_text = tip
	row.add_child(s)
	var v := Label.new()
	v.text = "%.3f" % s.value
	v.custom_minimum_size = Vector2(56, 0)
	row.add_child(v)
	s.value_changed.connect(func(x: float):
		v.text = "%.3f" % x
		_set_all(uniform, x))


static func _vec_slider(box: VBoxContainer, title: String, uniform: String,
		index: int, lo: float, hi: float, tip: String) -> void:
	var cur := 0.0
	for m in _mats:
		var q: Variant = (m as ShaderMaterial).get_shader_parameter(uniform)
		if q is Vector4:
			cur = (q as Vector4)[index]
			break
	var row := HBoxContainer.new()
	box.add_child(row)
	var l := Label.new()
	l.text = title
	l.custom_minimum_size = Vector2(170, 0)
	l.tooltip_text = tip
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = (hi - lo) / 200.0
	s.value = clampf(cur, lo, hi)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.tooltip_text = tip
	row.add_child(s)
	var v := Label.new()
	v.text = "%.3f" % s.value
	v.custom_minimum_size = Vector2(56, 0)
	row.add_child(v)
	s.value_changed.connect(func(x: float):
		v.text = "%.3f" % x
		_set_component(uniform, index, x))


static func _check(box: VBoxContainer, title: String, uniform: String, tip: String) -> void:
	var c := CheckBox.new()
	c.text = title
	c.tooltip_text = tip
	c.button_pressed = _read(uniform, 1.0) > 0.5
	box.add_child(c)
	c.toggled.connect(func(on: bool): _set_all(uniform, 1.0 if on else 0.0))


# The four cascade switches are components of one vec4, so they get their own
# toggle rather than going through _check.
static func _mask_toggle(box: VBoxContainer, index: int, title: String, tip: String) -> void:
	var cur := 1.0
	for m in _mats:
		var q: Variant = (m as ShaderMaterial).get_shader_parameter("cascade_mask")
		if q is Vector4:
			cur = (q as Vector4)[index]
			break
	var c := CheckBox.new()
	c.text = title
	c.tooltip_text = tip
	c.button_pressed = cur > 0.5
	box.add_child(c)
	c.toggled.connect(func(on: bool):
		_set_component("cascade_mask", index, 1.0 if on else 0.0))
