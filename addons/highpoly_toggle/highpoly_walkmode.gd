@tool
class_name HighpolyWalkMode
extends Node
# STANDING IN A SPAWNER'S BOOTS: the half that reads the game.
#
# The walking itself is not here. BF6FpsController collides against whatever the
# open scene draws, moves the editor camera and reads the keyboard, and it does
# all of that without touching the player's BF6 install - so it belongs in the
# base plugin and is written to be lifted there unchanged.
#
# THIS file is the High Poly half, and it is small on purpose: which soldier
# stands at this spawner, how tall they are, and what they are holding. Every
# one of those answers comes out of the install, which is exactly the line the
# add-on is supposed to sit on.
#
# The seam between them is two calls: set `eye_height`, then `attach()` whatever
# should travel with the view. The controller never learns what a loadout is.

# The fallback hold, used only when the first-person build is unavailable.
# AUTHORED, not read - and the 1P record below is what replaces it, so this is
# a last resort rather than a number to keep tuning.
const WEAPON_OFFSET := Vector3(0.18, -0.16, -0.38)

var _controller: BF6FpsController = null


func is_active() -> bool:
	return _controller != null and _controller.is_active()


func handle_input(event: InputEvent) -> bool:
	return _controller.handle_input(event) if _controller != null else false


func stop() -> void:
	if _controller != null:
		_controller.stop()


# Begin walking as the soldier this spawner stands for. Returns "" or a reason.
func start(gs, spawner: Node3D, scene_root: Node) -> String:
	if is_active():
		return "Already walking."
	var core = HighpolyLoadout.core_for(gs)
	if core == null:
		return "The game reader is not available."
	if _controller == null:
		_controller = BF6FpsController.new()
		add_child(_controller)
	# THIS SOLDIER'S OWN EYE HEIGHT, measured from the eye joints at the pose
	# they stand in, rather than the controller's documented 1.72 default. It
	# varies by character and by role, so a constant is visibly wrong for most
	# of them. A record that cannot say leaves the default alone.
	var request := HighpolyLoadout.soldier_request(
		HighpolyLoadout.type_of(spawner), HighpolyLoadout.values_of(spawner),
		str(spawner.name))
	request = HighpolyLoadout.resolve_role(core, request)
	var eye := HighpolyLoadout.soldier_eye(gs, request)
	if eye > 0.0:
		_controller.eye_height = eye
	var why: String = _controller.start(core, spawner.global_position,
		spawner.global_rotation.y, scene_root)
	if why != "":
		return why
	# WHAT THE PLAYER SEES OF THEMSELVES: their own arms holding their own
	# weapon, built on the first-person skeleton and already anchored on the
	# eye - so it attaches to the camera at identity and needs no offset from
	# this file at all.
	var view: Dictionary = HighpolyLoadout.build_soldier_1p(gs, request)
	if str(view.get("error", "")) == "":
		_controller.attach(view.node, Transform3D())
		return ""
	# Failing that, the weapon alone at an authored offset. Worse, and said out
	# loud rather than passed off as the real thing.
	HighpolyLog.info("no first-person arms (%s); holding the weapon only" % view.error)
	var weapon := _weapon_for(gs, spawner)
	if weapon != null:
		_controller.attach(weapon, Transform3D(Basis.from_euler(Vector3(0, PI, 0)), WEAPON_OFFSET))
	return ""


# The spawner's own configured weapon. Not a first-person viewmodel: the game's
# 1P arms need ske_soldier_1p, its own rig and the 1P clip set, all of which are
# located and verified but not built yet. This is the real weapon held in view,
# which is what makes the loadout legible while walking.
func _weapon_for(gs, spawner: Node3D) -> Node3D:
	var values: Dictionary = HighpolyLoadout.values_of(spawner)
	var built: Dictionary = HighpolyLoadout.build_weapon(gs, values)
	if str(built.get("error", "")) != "":
		HighpolyLog.info("walk mode has no weapon: %s" % built.error)
		return null
	return built.node
