@tool
extends RefCounted

# THE OBJECT DEBUG MENU: take the thing pick mode confirmed, stand it alone,
# show everything the game has on it, and let the user turn the knobs until
# it looks right - then export exactly what they dialed in, so "make it look
# like THIS" arrives as data instead of a description.
#
# WHY A PREVIEW CLONE AND NOT THE REAL SURFACES. The overlay's meshes are
# SHARED - one ArrayMesh drawn by every instance of that prop on the map, and
# cached on disk under the geometry epoch. Editing it in place would repaint
# forty trucks to debug one and could leak an experiment into the cache. The
# clone is rebuilt from the install with EVERY UV channel kept, one surface
# per section (the debugger wants parts; the build wants draw calls), and the
# original instance is zero-scaled out of the way so the two never overlap.
#
# ISOLATION is visibility, not surgery: the map context's child groups
# remember their flags and get them back on close. The per-cell distance
# streaming keeps toggling cells underneath - harmlessly, because a child's
# visibility cannot override a hidden parent.
#
# NO class_name, deliberately: this file arrives through the staged lane,
# and a freshly registered global class may not resolve until the editor
# rescans. It is preloaded by the dock instead, like the other late files.

const HL_NAME := "_HP_OBJDEBUG"

var gs = null                      # the open HighpolyGameSource
var root: Node = null
var win: Window = null
var preview: MeshInstance3D = null
var provenance := ""
var res_name := ""
var scope := ""
var vh := 0

var secs: Array = []               # debug_sections rows (one per part)
var ov: Array = []                 # per-section knob state
var cur := 0                       # section shown in the panel
var solo := false

var _hidden: Array = []            # [[node, was_visible]] for the isolation
var _inst_mmi: MultiMeshInstance3D = null
var _inst_i := -1
var _inst_xf := Transform3D()      # original transform of the hidden instance

# UI handles the refresh path writes
var _sec_pick: OptionButton = null
var _info: RichTextLabel = null
var _uv_pick: OptionButton = null
var _alb_pick: OptionButton = null
var _cut_chk: CheckBox = null
var _cut_sl: HSlider = null
var _tint_btn: ColorPickerButton = null
var _rough_sl: HSlider = null
var _emis_sl: HSlider = null
var _solo_chk: CheckBox = null
var _syncing := false              # writing controls must not fire knobs


func is_open() -> bool:
	return win != null and is_instance_valid(win)


# -> "" on success, else the user-facing reason it could not open.
#
# CHECKPOINTED, flushed each step. GDScript cannot catch a runtime error, so
# a fault inside this sequence kills the call silently and the button reads
# as doing nothing - the last checkpoint in the log is then the answer to
# "where did it die", which is worth far more than clean silence.
func open(p_gs, p_root: Node, focus: Dictionary) -> String:
	close()
	gs = p_gs
	root = p_root
	if gs == null or not gs.has_method("debug_sections"):
		return "Nothing is read from the install yet - build the map context once."
	if focus.is_empty():
		return "Pick an object first."
	var mesh = focus.get("mesh")
	var d: Dictionary = gs.describe(mesh)
	if not bool(d.get("found", false)):
		return "That mesh was not built by the install reader, so there is nothing to debug."
	res_name = str(d["mesh"])
	scope = str(d["scope"])
	vh = int(d.get("variation", 0))
	provenance = "mesh=%s scope=%s%s" % [res_name, scope,
		(" var=%d" % vh) if vh != 0 else ""]
	HighpolyLog.info("Object Debug: opening on %s" % provenance)
	HighpolyLog.flush()
	secs = gs.debug_sections(res_name)
	if secs.is_empty():
		return "The install would not re-read %s." % res_name.get_file()
	HighpolyLog.info("Object Debug: %d part(s) re-read with all UV channels"
		% secs.size())
	HighpolyLog.flush()
	ov = []
	for i in range(secs.size()):
		ov.append(_fresh_ov(i))
	cur = 0
	solo = false
	_spawn_preview(focus.get("xform", Transform3D()))
	HighpolyLog.info("Object Debug: preview built (%d surfaces)"
		% (preview.mesh.get_surface_count() if preview.mesh != null else -1))
	HighpolyLog.flush()
	_hide_original(focus)
	_isolate(true)
	HighpolyLog.info("Object Debug: isolated, building the window")
	HighpolyLog.flush()
	_build_window()
	_sync_controls()
	HighpolyLog.info("Object Debug: window up")
	HighpolyLog.flush()
	return ""


func close() -> void:
	_isolate(false)
	_restore_original()
	if preview != null and is_instance_valid(preview):
		if preview.get_parent() != null:
			preview.get_parent().remove_child(preview)
		preview.queue_free()
	preview = null
	if win != null and is_instance_valid(win):
		win.queue_free()
	win = null
	secs = []
	ov = []


# ---------------------------------------------------------------------------
# knob state
# ---------------------------------------------------------------------------

func _fresh_ov(i: int) -> Dictionary:
	var s: Dictionary = secs[i]
	return {"uv": _build_channel(s), "albedo": "",       # "" = the record's own
		"cutout": -1,                                    # -1 = as the build decides
		"cut": 0.5, "tint": Color.WHITE, "rough": -1.0, "emis": -1.0,
		"touched": false}


# Which declared channel the BUILD would ship as the primary - the same rule
# bf6_meshset._bake_uv_channel applies, recovered here by comparing ranges.
func _build_channel(s: Dictionary) -> int:
	var all: Array = s.get("uv_all", [])
	for k in range(1, all.size()):
		var uv: PackedVector2Array = all[k]
		var lo := Vector2(1e20, 1e20)
		var hi := Vector2(-1e20, -1e20)
		for p in uv:
			lo = lo.min(p)
			hi = hi.max(p)
		if lo.x >= -0.05 and hi.x <= 1.05 and lo.y >= -0.05 and hi.y <= 1.05 \
				and maxf(hi.x - lo.x, hi.y - lo.y) > 0.05:
			return k
	return 0


# ---------------------------------------------------------------------------
# the preview clone
# ---------------------------------------------------------------------------

func _spawn_preview(xf: Transform3D) -> void:
	preview = MeshInstance3D.new()
	preview.name = HL_NAME
	root.add_child(preview)
	preview.owner = null
	preview.global_transform = xf
	_rebuild_mesh()


func _rebuild_mesh() -> void:
	if preview == null:
		return
	var am := ArrayMesh.new()
	var mats: Array = []
	for i in range(secs.size()):
		if solo and i != cur:
			continue
		var s: Dictionary = secs[i]
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s["verts"]
		var nrm: PackedVector3Array = s.get("normals", PackedVector3Array())
		if nrm.size() == (s["verts"] as PackedVector3Array).size():
			arr[Mesh.ARRAY_NORMAL] = nrm
		var all: Array = s.get("uv_all", [])
		var pick := int((ov[i] as Dictionary)["uv"])
		var uv2: PackedVector2Array = s.get("uv2", PackedVector2Array())
		if pick == 99 and uv2.size() == (s["verts"] as PackedVector3Array).size():
			arr[Mesh.ARRAY_TEX_UV] = uv2
		elif pick >= 0 and pick < all.size():
			arr[Mesh.ARRAY_TEX_UV] = all[pick]
		else:
			arr[Mesh.ARRAY_TEX_UV] = s.get("uvs", PackedVector2Array())
		arr[Mesh.ARRAY_INDEX] = s["indices"]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mats.append(_material_for_section(i))
	preview.mesh = am
	for k in range(mats.size()):
		am.surface_set_material(k, mats[k])


func _material_for_section(i: int) -> Material:
	var s: Dictionary = secs[i]
	var o: Dictionary = ov[i]
	if not bool(o["touched"]):
		# untouched = exactly what the build would do, body/member rule included
		gs._dress_name = res_name
		var m = gs.material_for(int(s.get("state_key", 0)), scope, vh,
			PackedInt32Array())
		gs._dress_name = ""
		if m is Material:
			return m
	# A touched surface gets a plain debug material built from the knobs, so
	# every slider maps one to one onto something visible.
	var tex := _record_textures(i)
	var m2 := StandardMaterial3D.new()
	var alb: String = str(o["albedo"])
	if alb == "":
		for k in ["basecolor", "basecolor_veg"]:
			if tex.has(k):
				alb = k
				break
	if alb != "" and tex.has(alb):
		m2.albedo_texture = gs._texture_for(tex[alb], false)
	if tex.has("normal"):
		var nt = gs._texture_for(tex["normal"], true)
		if nt != null:
			m2.normal_enabled = true
			m2.normal_texture = nt
	m2.albedo_color = o["tint"]
	var cutm := int(o["cutout"])
	if cutm == 1 and tex.has("alpha"):
		var at = gs._texture_for(tex["alpha"], false)
		if at != null and m2.albedo_texture == null:
			m2.albedo_texture = at
		m2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m2.alpha_scissor_threshold = float(o["cut"])
	var r := float(o["rough"])
	if r >= 0.0:
		m2.roughness = r
	var e := float(o["emis"])
	if e > 0.0 and tex.has("emissive"):
		var et = gs._texture_for(tex["emissive"], false)
		if et != null:
			m2.emission_enabled = true
			m2.emission_texture = et
			m2.emission_energy_multiplier = e
	return m2


# {slot label: file guid} for one section's depot record, nh_ hashes included.
func _record_textures(i: int) -> Dictionary:
	var out := {}
	var dep = gs._depot_for(scope)
	if dep == null:
		return out
	var t: Dictionary = (dep as Array)[0].textures_for(
		int((secs[i] as Dictionary).get("state_key", 0)), (dep as Array)[1])
	for k in t.keys():
		if str(k) == "constants":
			continue
		out[str(k)] = t[k]
	return out


func _tex_label(guid) -> String:
	var nm = gs.walk.gi.get(str(guid)) if gs.walk != null else null
	return str(nm).get_file() if nm != null else str(guid)


# ---------------------------------------------------------------------------
# isolation
# ---------------------------------------------------------------------------

func _isolate(on: bool) -> void:
	if on:
		var ctx := root.get_node_or_null(HighpolyMapContext.NODE)
		if ctx == null:
			return
		for c in ctx.get_children():
			if c is Node3D:
				_hidden.append([c, (c as Node3D).visible])
				(c as Node3D).visible = false
	else:
		for e in _hidden:
			var n = (e as Array)[0]
			if n != null and is_instance_valid(n):
				(n as Node3D).visible = (e as Array)[1]
		_hidden = []


func _hide_original(focus: Dictionary) -> void:
	var node = focus.get("node")
	var inst := int(focus.get("inst", -1))
	if node is MultiMeshInstance3D and inst >= 0 \
			and (node as MultiMeshInstance3D).multimesh != null:
		_inst_mmi = node
		_inst_i = inst
		_inst_xf = _inst_mmi.multimesh.get_instance_transform(inst)
		_inst_mmi.multimesh.set_instance_transform(inst,
			Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -1e5, 0)))


func _restore_original() -> void:
	if _inst_mmi != null and is_instance_valid(_inst_mmi) \
			and _inst_mmi.multimesh != null and _inst_i >= 0 \
			and _inst_i < _inst_mmi.multimesh.instance_count:
		_inst_mmi.multimesh.set_instance_transform(_inst_i, _inst_xf)
	_inst_mmi = null
	_inst_i = -1


# ---------------------------------------------------------------------------
# the window
# ---------------------------------------------------------------------------

func _build_window() -> void:
	win = Window.new()
	win.title = "Object Debug: %s" % res_name.get_file()
	win.size = Vector2i(420, 640)
	win.close_requested.connect(close)
	EditorInterface.get_base_control().add_child(win)
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	win.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	var head := Label.new()
	head.text = provenance
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(head)

	_sec_pick = OptionButton.new()
	for i in range(secs.size()):
		var s: Dictionary = secs[i]
		_sec_pick.add_item("part %d  %s" % [i,
			str(s.get("material", "")).get_file()], i)
	_sec_pick.item_selected.connect(func(i: int):
		cur = i
		_sync_controls()
		if solo:
			_rebuild_mesh())
	v.add_child(_sec_pick)

	_solo_chk = CheckBox.new()
	_solo_chk.text = "Solo this part"
	_solo_chk.toggled.connect(func(onn: bool):
		solo = onn
		_rebuild_mesh())
	v.add_child(_solo_chk)

	_info = RichTextLabel.new()
	_info.fit_content = true
	_info.selection_enabled = true
	_info.custom_minimum_size = Vector2(0, 170)
	v.add_child(_info)

	v.add_child(_row_label(v, "UV channel"))
	_uv_pick = OptionButton.new()
	_uv_pick.item_selected.connect(func(ix: int):
		_knob("uv", _uv_pick.get_item_id(ix)))
	v.add_child(_uv_pick)

	v.add_child(_row_label(v, "Albedo from slot"))
	_alb_pick = OptionButton.new()
	_alb_pick.item_selected.connect(func(ix: int):
		_knob("albedo", _alb_pick.get_item_text(ix).split(" ")[0]
			if ix > 0 else ""))
	v.add_child(_alb_pick)

	_cut_chk = CheckBox.new()
	_cut_chk.text = "Alpha cutout"
	_cut_chk.toggled.connect(func(onn: bool): _knob("cutout", 1 if onn else 0))
	v.add_child(_cut_chk)
	_cut_sl = _slider(v, "Cutout threshold", 0.0, 1.0, 0.05,
		func(val: float): _knob("cut", val))
	_tint_btn = ColorPickerButton.new()
	_tint_btn.text = "Tint"
	_tint_btn.custom_minimum_size = Vector2(0, 28)
	_tint_btn.color_changed.connect(func(c: Color): _knob("tint", c))
	v.add_child(_tint_btn)
	_rough_sl = _slider(v, "Roughness", 0.0, 1.0, 0.05,
		func(val: float): _knob("rough", val))
	_emis_sl = _slider(v, "Emission energy", 0.0, 8.0, 0.25,
		func(val: float): _knob("emis", val))

	var row := HBoxContainer.new()
	v.add_child(row)
	var reset := Button.new()
	reset.text = "Reset part"
	reset.pressed.connect(func():
		ov[cur] = _fresh_ov(cur)
		_sync_controls()
		_rebuild_mesh())
	row.add_child(reset)
	var rep := Button.new()
	rep.text = "Copy report"
	rep.tooltip_text = "Writes the dialed-in recipe (every changed knob per part, with the object's identity) into the log and the clipboard, ready to paste."
	rep.pressed.connect(func():
		var t := _report()
		DisplayServer.clipboard_set(t)
		HighpolyLog.info(t))
	row.add_child(rep)
	var done := Button.new()
	done.text = "Close"
	done.pressed.connect(close)
	row.add_child(done)
	win.popup_centered(Vector2i(420, 640))


func _row_label(_v: VBoxContainer, t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 11)
	return l


func _slider(v: VBoxContainer, label: String, lo: float, hi: float,
		step: float, cb: Callable) -> HSlider:
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 11)
	v.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value_changed.connect(cb)
	v.add_child(s)
	return s


func _knob(key: String, val) -> void:
	if _syncing or cur >= ov.size():
		return
	var o: Dictionary = ov[cur]
	o[key] = val
	o["touched"] = true
	ov[cur] = o
	if key == "uv":
		_rebuild_mesh()
	else:
		# material-only change: re-dress the one surface in place
		var si := cur
		if solo:
			si = 0
		var am := preview.mesh as ArrayMesh
		if am != null and si < am.get_surface_count():
			am.surface_set_material(si, _material_for_section(cur))


func _sync_controls() -> void:
	_syncing = true
	var s: Dictionary = secs[cur]
	var o: Dictionary = ov[cur]
	# the info block: everything the game has on this part
	var tex := _record_textures(cur)
	var lines: Array = []
	lines.append("[b]%s[/b]" % str(s.get("material", "")))
	lines.append("state %016x" % int(s.get("state_key", 0)))
	lines.append("%d verts, %d uv channel(s)%s" % [
		(s["verts"] as PackedVector3Array).size(),
		(s.get("uv_all", []) as Array).size(),
		"  + tc4 unwrap" if str(s.get("uv2_src", "")) == "tc4" else ""])
	var ks: Array = tex.keys()
	ks.sort()
	for k in ks:
		lines.append("%s = %s" % [k, _tex_label(tex[k])])
	_info.text = "\n".join(PackedStringArray(lines))
	# uv options
	_uv_pick.clear()
	var build_ch := _build_channel(s)
	var all: Array = s.get("uv_all", [])
	for k in range(all.size()):
		_uv_pick.add_item("channel %d%s" % [k,
			"  (build's choice)" if k == build_ch else ""], k)
	if str(s.get("uv2_src", "")) == "tc4":
		_uv_pick.add_item("tc4 unwrap", 99)
	for ix in range(_uv_pick.item_count):
		if _uv_pick.get_item_id(ix) == int(o["uv"]):
			_uv_pick.select(ix)
	# albedo options
	_alb_pick.clear()
	_alb_pick.add_item("(record's own)")
	var sel := 0
	var n := 1
	for k in ks:
		_alb_pick.add_item("%s  (%s)" % [k, _tex_label(tex[k])])
		if str(o["albedo"]) == str(k):
			sel = n
		n += 1
	_alb_pick.select(sel)
	_cut_chk.set_pressed_no_signal(int(o["cutout"]) == 1)
	_cut_sl.set_value_no_signal(float(o["cut"]))
	_tint_btn.color = o["tint"]
	_rough_sl.set_value_no_signal(maxf(0.0, float(o["rough"])))
	_emis_sl.set_value_no_signal(maxf(0.0, float(o["emis"])))
	_syncing = false


# The export: only what was CHANGED, against the object's full identity, so
# the recipe reads as instructions rather than a state dump.
func _report() -> String:
	var out: Array = []
	out.append("=== OBJECT DEBUG RECIPE ===")
	out.append(provenance)
	var any := false
	for i in range(secs.size()):
		var o: Dictionary = ov[i]
		if not bool(o["touched"]):
			continue
		any = true
		var s: Dictionary = secs[i]
		out.append("part %d  %s  state %016x" % [i,
			str(s.get("material", "")).get_file(), int(s.get("state_key", 0))])
		var base := _fresh_ov(i)
		for k in ["uv", "albedo", "cutout", "cut", "tint", "rough", "emis"]:
			if str(o[k]) != str(base[k]):
				out.append("   %s: %s -> %s" % [k, str(base[k]), str(o[k])])
	if not any:
		out.append("(no knobs changed - everything is as the build made it)")
	return "\n".join(PackedStringArray(out))