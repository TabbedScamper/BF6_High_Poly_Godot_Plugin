extends SceneTree

# DOES THE WALKER ACTUALLY WALK?
#
#   python tools/run_addon_script.py native/test_walkmode.gd
#
# The walk binding hands world-space triangles to the core's ray scene and steps
# through bf6_walk_step_scene. Everything that can go wrong here is silent: a
# handle that never opens, an array laid out in the wrong order, a Y/Z swap, a
# step that returns the state unchanged. All of those look identical from the
# outside - the player simply does not move, or falls forever - so this checks
# behaviour rather than return codes.
#
# No game install and no map: the world is a few triangles built here, which
# makes the expected answers exact rather than approximate.

var fails := 0

func bad(what: String) -> void:
	print("  FAIL %s" % what)
	fails += 1


# A quad on the XZ plane at height y, from (x0,z0) to (x1,z1), as two triangles.
func _quad(x0: float, z0: float, x1: float, z1: float, y: float) -> PackedFloat32Array:
	return PackedFloat32Array([
		x0, y, z0,  x1, y, z0,  x1, y, z1,
		x0, y, z0,  x1, y, z1,  x0, y, z1])


# A vertical wall across X at x, spanning z0..z1, from y0 up to y1.
func _wall(x: float, z0: float, z1: float, y0: float, y1: float) -> PackedFloat32Array:
	return PackedFloat32Array([
		x, y0, z0,  x, y1, z0,  x, y1, z1,
		x, y0, z0,  x, y1, z1,  x, y0, z1])


func _state(pos: Vector3, eye: float) -> PackedFloat32Array:
	return PackedFloat32Array([pos.x, pos.y, pos.z, 0, 0, 0, 0, 0, eye, 0])


func _input(st: PackedFloat32Array, wish: Vector3, run: bool, crouch: bool,
		jump: bool, dt: float) -> PackedFloat32Array:
	var a := PackedFloat32Array(st)
	a.append_array(PackedFloat32Array([wish.x, wish.y, wish.z,
		1.0 if run else 0.0, 1.0 if crouch else 0.0, 1.0 if jump else 0.0, dt]))
	return a


func _init() -> void:
	await process_frame
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.has_method("walk_open"):
		print("FAIL: this binding has no walk mode"); quit(1); return

	# A 40 m floor, a 0.30 m ledge over half of it, and a wall at x = 6.
	var world := PackedFloat32Array()
	world.append_array(_quad(-20, -20, 20, 20, 0.0))
	world.append_array(_quad(-20, 2, 20, 20, 0.30))
	world.append_array(_wall(6.0, -2.0, 2.0, 0.0, 3.0))
	var handle := int(core.call("walk_open", world))
	print("walk handle: %d (%d triangles)" % [handle, world.size() / 9])
	if handle == 0:
		print("FAIL: the world could not be opened"); quit(1); return

	var eye := 1.72

	# ---- gravity and ground ------------------------------------------------
	# Dropped from 5 m, the walker must land and stay on the floor, not sink
	# through it and not hover.
	var st := _state(Vector3(0, 5.0, 0), eye)
	for _i in range(180):
		st = core.call("walk_step", handle, _input(st, Vector3.ZERO, false, false, false, 1.0 / 60.0))
		if st.size() < 10:
			bad("the core rejected a step"); break
	if st.size() >= 10:
		print("after falling 5 m: eye y = %.4f, grounded = %d" % [st[1], int(st[7])])
		if absf(st[1] - eye) > 0.05:
			bad("the walker did not settle at eye height over the floor")
		if int(st[7]) == 0:
			bad("the walker never became grounded")

	# ---- walking moves you -------------------------------------------------
	var before := Vector3(st[0], st[1], st[2])
	for _i in range(60):
		st = core.call("walk_step", handle, _input(st, Vector3(0, 0, -1), false, false, false, 1.0 / 60.0))
	var walked := Vector3(st[0], st[1], st[2])
	var d := Vector2(walked.x - before.x, walked.z - before.z).length()
	print("one second of walking covered %.3f m" % d)
	if d < 0.5:
		bad("walking forward barely moved the walker")

	# ---- running is faster than walking ------------------------------------
	st = _state(Vector3(0, eye, 0), eye)
	for _i in range(30):
		st = core.call("walk_step", handle, _input(st, Vector3(0, 0, -1), false, false, false, 1.0 / 60.0))
	var slow := absf(st[2])
	st = _state(Vector3(0, eye, 0), eye)
	for _i in range(30):
		st = core.call("walk_step", handle, _input(st, Vector3(0, 0, -1), true, false, false, 1.0 / 60.0))
	var fast := absf(st[2])
	print("half a second: walking %.3f m, running %.3f m" % [slow, fast])
	if fast <= slow:
		bad("running is not faster than walking")

	# ---- a wall stops you --------------------------------------------------
	st = _state(Vector3(3.0, eye, 0), eye)
	for _i in range(180):
		st = core.call("walk_step", handle, _input(st, Vector3(1, 0, 0), true, false, false, 1.0 / 60.0))
	print("ran at a wall at x = 6.0, ended at x = %.3f" % st[0])
	if st[0] > 6.0:
		bad("the walker went through the wall")
	if st[0] < 4.5:
		bad("the walker never reached the wall - it is stuck on flat ground")

	# ---- a 0.30 m ledge is climbed, not blocked ----------------------------
	# The game's authored StepHeight is 0.32, so a 0.30 ledge must be walkable.
	st = _state(Vector3(0, eye, 0), eye)
	for _i in range(240):
		st = core.call("walk_step", handle, _input(st, Vector3(0, 0, 1), false, false, false, 1.0 / 60.0))
	print("walked at a 0.30 m ledge, ended z = %.3f, eye y = %.3f" % [st[2], st[1]])
	if st[2] < 2.5:
		bad("the walker could not climb a 0.30 m step")
	elif absf(st[1] - (eye + 0.30)) > 0.08:
		bad("the walker climbed the step but is not standing on top of it")

	# ---- the game's own numbers reach Godot --------------------------------
	# The step above already uses them; this is about the ones the ENGINE has to
	# apply itself. Field of view above all: BF6 authors it as a player option
	# and a camera left at the editor's 75 shows a visibly wider world than the
	# game does.
	var tune: PackedFloat32Array = core.call("walk_tuning", handle)
	if tune.size() < 10:
		bad("the walk reports no tuning")
	else:
		print("\nfov %.1f vertical (%.0f..%.0f), step %.3f, jump cap %.1f, vault %.2f"
			% [tune[0], tune[1], tune[2], tune[3], tune[4], tune[6]])
		print("speeds walk %.2f run %.2f crouch %.2f  (no install open: fallbacks, not the measured gaits)"
			% [tune[7], tune[8], tune[9]])   # no install open here, so these are the fallbacks
		# No install is open in this test, so these are the defaults - which
		# carry the authored values decoded from the current install.
		if tune[0] < 40.0 or tune[0] > 120.0:
			bad("the field of view is not a plausible vertical angle")
		if tune[1] >= tune[2]:
			bad("the field of view range is inverted")
		if absf(tune[3] - 0.32) > 0.001:
			bad("step height is not the authored 0.32")

	# ---- closing -----------------------------------------------------------
	# After everything that needs the handle: closing it first is what made the
	# tuning check above report "no tuning" on its first run.
	if not bool(core.call("walk_close", handle)):
		bad("the walk handle would not close")
	var after: PackedFloat32Array = core.call("walk_step", handle,
		_input(_state(Vector3(0, eye, 0), eye), Vector3.ZERO, false, false, false, 0.016))
	if after.size() >= 10:
		bad("a closed handle still steps - it was not really released")

	# ---- the boundary ------------------------------------------------------
	# THE WALK MUST NOT NEED THE GAME. A feature that does not read the real
	# install belongs in the base plugin, and this one is meant to be lifted
	# there unchanged - so the claim is worth a check rather than a comment.
	# Everything above ran on a core that was never opened against an install:
	# no bf6_open, no mount, no game directory anywhere in this file.
	if core.has_method("is_open") and bool(core.call("is_open")):
		bad("the test core has a game open - this proved nothing about the boundary")
	print("\nthe whole walk ran on a core with no game opened")

	# And the base controller must not reach for anything that does.
	var src := FileAccess.open("res://addons/highpoly_toggle/bf6_fps_controller.gd",
		FileAccess.READ)
	if src == null:
		bad("the base controller is missing")
	else:
		var text := src.get_as_text()
		src.close()
		for forbidden in ["HighpolyLoadout", "HighpolyGameSource", "loadout_",
				"HighpolySoldier", "build_weapon", "game_source"]:
			if text.find(forbidden) >= 0:
				bad("the base controller mentions %s - it is no longer asset-free" % forbidden)
		print("base controller: no reference to any game-reading call")

	print("\n%s: %d failure(s)" % ["FAIL" if fails else "PASS", fails])
	quit(1 if fails else 0)
