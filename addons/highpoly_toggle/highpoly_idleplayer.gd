@tool
class_name HighpolyIdlePlayer
extends AnimationPlayer
# AN ANIMATION THAT RUNS IN THE EDITOR, AND ONLY WHERE IT CAN BE SEEN.
#
# AnimationPlayer.autoplay and play() are RUNTIME behaviour. The Godot editor
# does not tick the scene it is editing, so a player dropped into the edited
# scene by a plugin sits on frame 0 forever. That is what "the idle animation
# doesn't do anything" looks like, and checking the animation resource never
# finds it, because the resource is fine.
#
# WHO ADVANCES IT. The plugin does, through tick_all(), NOT this node's own
# _process. A @tool script's _process is supposed to run for nodes in the edited
# scene and the water in this same add-on relies on it - but "supposed to" was
# the whole problem once already, and an EditorPlugin's _process is not in
# doubt. One owner also means one camera lookup per frame for every soldier on
# the map instead of one each, and no chance of two things advancing the same
# clock. Outside the editor there is no plugin, so the node drives itself.
#
# THE RADIUS IS THE POINT. Posing a 341-bone skeleton and re-skinning eight
# weights per vertex costs the same whether the soldier is in front of the
# camera or half a map away, and a map can hold a lot of spawners. Beyond the
# radius the clock stops and nothing is seeked, so the soldier keeps its pose
# and costs nothing but a distance check. Walking back resumes where it left
# off rather than snapping.

const RADIUS_M := 50.0
# A little further before it stops again, so a camera parked exactly on the
# boundary does not start and stop every frame.
const RADIUS_RELEASE_M := 54.0

# HOW THE PLUGIN FINDS THESE: a group, not a static registry.
#
# The obvious `static var _live: Array` deadlocked. Not slowly - touching the
# static side AT ALL never returned: a probe that called only the static
# live_count(), constructing nothing, hung on that line. A group is what Godot
# offers for exactly this, costs nothing, and cannot take the editor down with
# it.
const GROUP := &"hp_idle_players"

var _t := 0.0
var _clip := ""
var _near := false


func _enter_tree() -> void:
	add_to_group(GROUP)
	# Outside the editor nothing else is going to drive this.
	if not Engine.is_editor_hint():
		set_process(true)


func _process(delta: float) -> void:
	# Runtime only; in the editor the plugin calls tick_idle().
	if not Engine.is_editor_hint():
		tick_idle(delta, Vector3.ZERO, false)


# Start driving `name`. `phase` (0..1) offsets the starting time so a row of
# spawners does not breathe in unison. Safe to call before entering the tree.
func drive(name: String, phase: float = 0.0) -> void:
	_clip = name
	if not has_animation(name):
		_clip = ""
		return
	var anim := get_animation(name)
	_t = fposmod(phase, 1.0) * anim.length if anim != null and anim.length > 0.0 else 0.0
	# assigned_animation, not play(): it makes the clip current without starting
	# runtime playback that would then be fighting this clock.
	assigned_animation = name
	seek(_t, true)


# One step. Returns true when the pose was actually moved.
func tick_idle(delta: float, camera: Vector3, have_camera: bool) -> bool:
	if _clip == "" or not has_animation(_clip):
		return false
	if have_camera:
		var anchor := get_parent() as Node3D
		if anchor != null and anchor.is_inside_tree():
			var d := camera.distance_to(anchor.global_position)
			_near = d <= (RADIUS_RELEASE_M if _near else RADIUS_M)
			if not _near:
				return false
	var anim := get_animation(_clip)
	if anim == null or anim.length <= 0.0:
		return false
	_t = fmod(_t + delta, anim.length)
	seek(_t, true)
	return true
