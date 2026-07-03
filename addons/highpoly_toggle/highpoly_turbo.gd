@tool
extends Node
class_name HighpolyTurbo
# Editor viewport performance tools (non-destructive, never saved):
#  - Distance cull: global visibility_range_end on all scene geometry
#    (renderer-native, zero per-frame cost)
#  - Frustum cull (aggressive): hides STATIC map geometry behind the camera
#    so it also skips shadow passes; placed pieces are never touched
#  - Static shadows toggle: stop static map geometry from casting shadows
# All effects are runtime-only property tweaks on unowned instanced nodes —
# Godot does not serialize them into the level scene.

var cull_distance: float = 0.0        # 0 = off (meters)
var frustum_cull: bool = false
var static_shadows: bool = true

var _timer: Timer
var _all_geo: Array = []              # every GeometryInstance3D (distance/shadows)
var _static_geo: Array = []           # [node, global_center] static-map only (frustum)
var _cached_root: Node = null
var _saved_ranges: Dictionary = {}    # node -> original visibility_range_end
var _saved_shadows: Dictionary = {}   # node -> original cast_shadow

func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 0.25
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_timer.start()

func _root() -> Node:
	return EditorInterface.get_edited_scene_root()

func _is_static_branch(n: Node) -> bool:
	var p := n
	while p != null:
		var nm := String(p.name).to_lower()
		if nm == "static" or nm.contains("_terrain") or nm.contains("_assets"):
			return true
		p = p.get_parent()
	return false

func _rebuild_cache() -> void:
	_all_geo.clear(); _static_geo.clear()
	var root := _root()
	_cached_root = root
	if root == null: return
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			_all_geo.append(n)
			if _is_static_branch(n):
				var g := n as GeometryInstance3D
				var c: Vector3 = (g.global_transform * g.get_aabb()).get_center()
				_static_geo.append([g, c])
		for c in n.get_children():
			stack.append(c)

func refresh() -> void:
	_rebuild_cache()
	apply_distance()
	apply_shadows()

func apply_distance() -> void:
	for n in _all_geo:
		if not is_instance_valid(n): continue
		var g := n as GeometryInstance3D
		if cull_distance > 0.0:
			if not _saved_ranges.has(g):
				_saved_ranges[g] = g.visibility_range_end
			g.visibility_range_end = cull_distance
			g.visibility_range_end_margin = cull_distance * 0.08
			g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		elif _saved_ranges.has(g):
			g.visibility_range_end = _saved_ranges[g]
			g.visibility_range_end_margin = 0.0
	if cull_distance <= 0.0:
		_saved_ranges.clear()

func apply_shadows() -> void:
	for n in _all_geo:
		if not is_instance_valid(n): continue
		if not _is_static_branch(n): continue
		var g := n as GeometryInstance3D
		if not static_shadows:
			if not _saved_shadows.has(g):
				_saved_shadows[g] = g.cast_shadow
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif _saved_shadows.has(g):
			g.cast_shadow = _saved_shadows[g]
	if static_shadows:
		_saved_shadows.clear()

func _tick() -> void:
	var root := _root()
	if root != _cached_root:
		# scene switched: forget old state, re-cache, re-apply
		_saved_ranges.clear(); _saved_shadows.clear()
		refresh()
		return
	if not frustum_cull:
		return
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp == null: return
	var cam := vp.get_camera_3d()
	if cam == null: return
	var cpos := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var cos_limit := cos(deg_to_rad(clamp(cam.fov, 30.0, 110.0) * 0.75 + 15.0))
	for e in _static_geo:
		var g: GeometryInstance3D = e[0]
		if not is_instance_valid(g): continue
		var to: Vector3 = e[1] - cpos
		var d := to.length()
		var in_view: bool = d < 15.0 or (to / max(d, 0.001)).dot(fwd) > cos_limit
		if g.visible != in_view:
			g.visible = in_view

func set_frustum(on: bool) -> void:
	frustum_cull = on
	if not on:
		for e in _static_geo:
			if is_instance_valid(e[0]) and not (e[0] as GeometryInstance3D).visible:
				(e[0] as GeometryInstance3D).visible = true
