@tool
class_name BF6FpsController
extends Node
# WALKING A MAP IN FIRST PERSON. NO GAME ASSETS.
#
# THIS HALF READS NOTHING FROM THE PLAYER'S BF6 INSTALL, and that is deliberate
# rather than incidental. The standing rule is that a feature which does not
# read the real game belongs in the base tool, not the High Poly add-on, so this
# file is written to be lifted into the standalone plugin unchanged: it collides
# against whatever meshes the open scene already draws - the SDK's own low-poly
# proxies do fine - moves the editor camera, and reads the keyboard.
#
# Everything that DOES read the install - which soldier stands here, what they
# are holding, their eye height, first-person arms, animations - is somebody
# else's job. It reaches this through `eye_height` and `attach()`, and nothing
# in here knows what a loadout is. highpoly_walkmode.gd is that other half.
#
# THE STEP ITSELF IS THE CORE'S. bf6_walk_step_scene is the same function the
# Unreal SDK's walk mode calls: the same knee, chest and head probes, gravity,
# step-up, slope limit and stair snapping. A second walker written in GDScript
# would be a new divergence in the very system meant to show the two editors
# agree, so this gathers geometry and moves a camera and decides nothing.
#
# The core still walks on Unreal's character defaults for SPEED. BF6's own base
# speed is not an authored constant anywhere in the shipped data - its
# locomotion is motion-matched and the remixer tables carry only multipliers and
# thresholds - so this moves like a plausible soldier, not the game's. That gap
# lives in the core, where both editors share it.

const DEFAULT_EYE := 1.72           # the core's own default standing eye height
const GATHER_RADIUS := 60.0         # metres of world to collide against
const REGATHER_AT := 25.0           # re-gather once this far from the last one
const MOUSE_SENSITIVITY := 0.0022

# Set before start(); read the install to fill it in, or leave the default.
var eye_height := DEFAULT_EYE

var _core: Object = null
var _handle := 0
var _active := false
var _cam: Camera3D = null
var _saved := Transform3D()
var _saved_fov := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _gathered_at := Vector3(1e9, 1e9, 1e9)
var _root: Node = null
var _attached: Array[Node3D] = []

# pos[3] vel[3] vel_up grounded eye eye_last
var _state := PackedFloat32Array()


func is_active() -> bool:
	return _active


# `core` is any object exposing walk_open/walk_step/walk_close. It needs the
# native library but NOT an opened game: the walk is pure geometry.
func start(core: Object, from: Vector3, facing_yaw: float, scene_root: Node) -> String:
	if _active:
		return "Already walking."
	if core == null or not core.has_method("walk_open"):
		return "This build cannot walk the map; update the add-on."
	if scene_root == null:
		return "There is no open scene to walk."
	var vp := EditorInterface.get_editor_viewport_3d(0)
	_cam = vp.get_camera_3d() if vp != null else null
	if _cam == null:
		return "The 3D viewport has no camera to borrow."
	_core = core
	_root = scene_root
	_state = PackedFloat32Array([
		from.x, from.y + eye_height, from.z,
		0.0, 0.0, 0.0,
		0.0, 0.0,
		eye_height, 0.0])
	if not _regather(from):
		return "No geometry here to stand on."
	_saved = _cam.global_transform
	# THE GAME'S FIELD OF VIEW, not the editor's. BF6 authors it as a player
	# option - 59 degrees vertical by default, adjustable 55..89 - and Godot's
	# Camera3D.fov is vertical too, so it maps straight across. Inheriting the
	# editor's 75 made everything look wider and nearer than the game does.
	_saved_fov = _cam.fov
	if _core.has_method("walk_tuning"):
		var tune: PackedFloat32Array = _core.call("walk_tuning", _handle)
		if tune.size() >= 1 and tune[0] > 1.0:
			_cam.fov = tune[0]
	_yaw = facing_yaw
	# Level with the horizon. Inheriting the editor camera's pitch would drop
	# the player looking at their own feet.
	_pitch = 0.0
	_active = true
	set_process(true)
	return ""


func stop() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	for n in _attached:
		if is_instance_valid(n):
			n.queue_free()
	_attached.clear()
	if _cam != null and is_instance_valid(_cam):
		_cam.global_transform = _saved
		# The camera was borrowed, not taken: its field of view goes back too.
		if _saved_fov > 0.0:
			_cam.fov = _saved_fov
	if _handle != 0 and _core != null:
		_core.call("walk_close", _handle)
		_handle = 0


# Carry a node with the view. The controller owns it from here and frees it on
# stop; what the node IS is none of this file's business.
func attach(node: Node3D, offset: Transform3D) -> void:
	if node == null or _cam == null or not is_instance_valid(_cam):
		return
	_cam.add_child(node)
	node.transform = offset
	_attached.append(node)


# Where the eyes are right now, for a caller that wants to follow along.
func eye_position() -> Vector3:
	return Vector3(_state[0], _state[1], _state[2]) if _state.size() >= 3 else Vector3.ZERO


# Collect world-space triangles near `at` and hand them to the core as a ray
# scene. Whole-map collision would be millions of triangles; the walker only
# ever probes a couple of metres, so a local gather re-run as you move is both
# cheaper and no less correct.
func _regather(at: Vector3) -> bool:
	var tris := PackedFloat32Array()
	var r2 := GATHER_RADIUS * GATHER_RADIUS
	for m in _meshes_of(_root):
		var mi: MeshInstance3D = m
		if mi.global_position.distance_squared_to(at) > r2:
			# The mesh ORIGIN can be far from its geometry on a large piece, so
			# the AABB decides for anything that fails the cheap test.
			var box: AABB = mi.global_transform * mi.get_aabb()
			if box.get_center().distance_squared_to(at) > r2 + box.size.length_squared():
				continue
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var xf: Transform3D = mi.global_transform
		for s in range(mesh.get_surface_count()):
			var arr: Array = mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			if verts.is_empty():
				continue
			if idx.is_empty():
				for v in verts:
					var p: Vector3 = xf * v
					tris.append_array(PackedFloat32Array([p.x, p.y, p.z]))
			else:
				for i in idx:
					var p2: Vector3 = xf * verts[i]
					tris.append_array(PackedFloat32Array([p2.x, p2.y, p2.z]))
	if tris.size() < 9:
		return false
	if _handle != 0:
		_core.call("walk_close", _handle)
	_handle = int(_core.call("walk_open", tris))
	_gathered_at = at
	return _handle != 0


func _meshes_of(node: Node, out: Array = []) -> Array:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null and mi.visible:
		out.append(mi)
	for c in node.get_children():
		_meshes_of(c, out)
	return out


func _process(delta: float) -> void:
	if not _active or _cam == null or not is_instance_valid(_cam):
		return
	var here := Vector3(_state[0], _state[1], _state[2])
	if here.distance_to(_gathered_at) > REGATHER_AT:
		_regather(here)

	var fwd := 0.0
	var side := 0.0
	if Input.is_key_pressed(KEY_W): fwd += 1.0
	if Input.is_key_pressed(KEY_S): fwd -= 1.0
	if Input.is_key_pressed(KEY_D): side += 1.0
	if Input.is_key_pressed(KEY_A): side -= 1.0
	var wish := Vector3.ZERO
	if fwd != 0.0 or side != 0.0:
		var f := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		var r := Vector3(cos(_yaw), 0.0, -sin(_yaw))
		wish = (f * fwd + r * side).normalized()

	var input := PackedFloat32Array(_state)
	input.append_array(PackedFloat32Array([
		wish.x, wish.y, wish.z,
		1.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0,
		1.0 if Input.is_key_pressed(KEY_CTRL) else 0.0,
		1.0 if Input.is_key_pressed(KEY_SPACE) else 0.0,
		clampf(delta, 0.001, 0.1)]))
	var next: PackedFloat32Array = _core.call("walk_step", _handle, input)
	# An empty answer means the handle went stale or the layout was wrong. Say
	# so and stop, rather than leaving the player frozen with no explanation.
	if next.size() < 10:
		push_warning("Walk mode stopped: the core rejected the step")
		stop()
		return
	_state = next
	_cam.global_transform = Transform3D(
		Basis.from_euler(Vector3(_pitch, _yaw, 0.0)),
		Vector3(_state[0], _state[1], _state[2]))


# Mouse look and Esc, fed from the plugin's viewport input hook. Returns true
# when the event was consumed.
func handle_input(event: InputEvent) -> bool:
	if not _active:
		return false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		stop()
		return true
	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.5, 1.5)
		return true
	return false
