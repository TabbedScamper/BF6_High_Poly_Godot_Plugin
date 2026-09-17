extends SceneTree

# THE SKINNED SOLDIER, CHECKED AGAINST THE STATIC ONE IT REPLACES.
#
#   python tools/run_addon_script.py native/test_soldier_rig.gd --args <steam>
#
# The core already proves its own record is right: soldier_skin_test skins the
# bind mesh by `posed`, shifts by `root`, and gets the static soldier back to
# 7.2e-07 m. What that CANNOT prove is that Godot reads it correctly. Every
# convention in between is a chance to be subtly wrong and not look it - the 3x4
# read as rows instead of axes, a Skin bind that should have been inverted, a
# renderbone parented into the wrong half of the skeleton, eight influences
# quietly truncated to four. Each of those produces a soldier that is recognisably
# a soldier.
#
# So this does the skinning arithmetic AGAINST THE BUILT SCENE - the actual
# Skeleton3D, its actual global bone poses, the actual Skin resource, the actual
# ARRAY_BONES and ARRAY_WEIGHTS that went onto the mesh - and requires the same
# vertices the static path produces. A pass means the two paths draw the same
# soldier, which is the checkpoint worth having before an animation is put on
# top of it.

const Rig := preload("res://addons/highpoly_toggle/highpoly_soldierrig.gd")

const REQUEST := {"character": "cha0001wisp", "outfit": "001",
	"faction": "alliance", "role": "assault"}
const TOLERANCE := 0.001      # a millimetre; the two paths differ only in float order
const STRIDE := 89            # a correctness check, not a benchmark

var fails := 0

# GODOT BLOCK-BUFFERS STDOUT WHEN IT IS REDIRECTED, so a run that is killed on a
# timeout reports nothing at all - which is exactly what happened here and cost a
# round of guessing. Progress goes to a file as well, which survives the kill.
const MARK := "user://soldier_rig_progress.txt"


func mark(what: String) -> void:
	var f := FileAccess.open(MARK, FileAccess.READ_WRITE) if FileAccess.file_exists(MARK) \
		else FileAccess.open(MARK, FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line("%7.2f s  %s" % [Time.get_ticks_msec() / 1000.0, what])
		f.close()


func bad(what: String) -> void:
	print("  FAIL %s" % what)
	fails += 1


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var steam := str(a[0]) if a.size() > 0 else ""

	# A bare core, not a game source: the loadout reads the front-end mount and
	# never touches a level, so opening a map would cost minutes for nothing.
	# Materials fall back to flat base colour here, which is the right trade -
	# this test is about where the vertices land.
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered")
		quit(1)
		return
	var gs = ClassDB.instantiate("BF6Core")
	if gs == null or not gs.open(steam):
		print("FAIL: the game could not be opened at %s" % steam)
		quit(1)
		return

	# ---- the two builds ----------------------------------------------------
	mark("building the static soldier")
	var stat: Dictionary = HighpolyLoadout.build_soldier(gs, REQUEST.duplicate())
	if str(stat.get("error", "")) != "":
		print("FAIL the static soldier: %s" % stat["error"])
		quit(1)
		return
	var want_mesh: ArrayMesh = _mesh_of(stat["node"])

	mark("building the skinned soldier")
	var got: Dictionary = Rig.build(gs, REQUEST.duplicate())
	if str(got.get("error", "")) != "":
		print("FAIL the skinned soldier: %s" % got["error"])
		quit(1)
		return
	var root: Node3D = got["node"]
	var skel: Skeleton3D = got["skeleton"]
	var mi: MeshInstance3D = skel.get_node("Soldier")
	var am: ArrayMesh = mi.mesh
	var skin: Skin = mi.skin
	var map: PackedInt32Array = root.get_meta("hp_rig_surface_section")

	print("bones %d (base %d), skinned surfaces %d, attached %d, static surfaces %d"
		% [skel.get_bone_count(), int(root.get_meta("hp_rig_base_bones")),
		   am.get_surface_count(), int(root.get_meta("hp_rig_attached")),
		   want_mesh.get_surface_count()])
	print("skeleton placed at %s" % str(skel.position))

	if skel.get_bone_count() < 100:
		bad("the skeleton is implausibly small for a 291-bone soldier")
	if int(root.get_meta("hp_rig_attached")) == 0:
		bad("nothing is attached to a bone - the weapon will not follow the hand")
	if skel.position == Vector3.ZERO:
		bad("the skeleton was never placed - the soldier will stand in rig space")

	# The bind poses, by bone. They were added in bone order, but reading the
	# binding back rather than assuming that is the point of the exercise.
	var bind := {}
	for i in range(skin.get_bind_count()):
		var b := skin.get_bind_bone(i)
		bind[b if b >= 0 else i] = skin.get_bind_pose(i)

	# ---- the arithmetic ----------------------------------------------------
	var worst := 0.0
	var worst_at := ""
	var checked := 0
	var eight := 0
	for s in range(am.get_surface_count()):
		var section := map[s]
		if section >= want_mesh.get_surface_count():
			bad("built surface %d maps to section %d, which the static soldier does not have"
				% [s, section])
			continue
		var arr := am.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
		if verts.is_empty() or bones.is_empty():
			continue
		var infl := bones.size() / verts.size()
		if infl == 8:
			eight += 1
		var want: PackedVector3Array = want_mesh.surface_get_arrays(section)[Mesh.ARRAY_VERTEX]
		if want.size() != verts.size():
			bad("surface %d has %d vertices, the static section %d has %d"
				% [s, verts.size(), section, want.size()])
			continue
		for v in range(0, verts.size(), STRIDE):
			var acc := Vector3.ZERO
			var total := 0.0
			for lane in range(infl):
				var w := weights[v * infl + lane]
				if w <= 0.0:
					continue
				var b := bones[v * infl + lane]
				if not bind.has(b):
					bad("surface %d vertex %d uses bone %d, which the skin does not bind"
						% [s, v, b])
					total = 0.0
					break
				# The renderer's own arithmetic: the bone's model pose composed
				# onto the inverted bind pose, applied to the bind vertex.
				acc += (skel.get_bone_global_pose(b) * bind[b] * verts[v]) * w
				total += w
			if total <= 0.000001:
				continue
			var d := (acc / total + skel.position).distance_to(want[v])
			if d > worst:
				worst = d
				worst_at = "surface %d vertex %d" % [s, v]
			checked += 1

	print("surfaces with eight influences: %d" % eight)
	# %g is not a GDScript format specifier - it prints the literal text and
	# eats the whole substitution, which is how a measurement turns into a
	# pass with no number beside it.
	print("POSED vs the static soldier: worst %.9f m over %d vertices (%s)"
		% [worst, checked, worst_at])
	if checked == 0:
		bad("no vertex could be skinned at all")
	if worst > TOLERANCE:
		bad("the skinned soldier does NOT stand where the static one does")

	# A control. If the pose were never applied, the bind mesh would already
	# equal the static soldier and the check above would pass on nothing.
	var spread := 0.0
	for i in range(mini(skel.get_bone_count(), 64)):
		spread = maxf(spread, skel.get_bone_pose(i).origin.distance_to(
			skel.get_bone_rest(i).origin))
	print("CONTROL pose vs rest, worst origin shift over 64 bones: %.6f m" % spread)
	if spread <= 0.0:
		bad("no bone is posed away from its rest - the comparison proves nothing")

	# ---- the animation -----------------------------------------------------
	# The rig is only worth having if something drives it. Frame 0 of the idle
	# is the pose just checked, so playing at time 0 must leave the soldier
	# exactly where it already was, and playing later must move it.
	# An AnimationPlayer only drives anything from inside the tree.
	mark("skinning checked; adding to the tree")
	get_root().add_child(root)
	# THE BUILT POSE, captured before anything animates it. add_idle starts the
	# soldier at its own phase offset rather than at frame 0, so reading this
	# afterwards would be reading the phase and calling it the build.
	var before := []
	for i in range(skel.get_bone_count()):
		before.append(skel.get_bone_pose(i))
	mark("building the idle animation")
	var idle: Dictionary = Rig.add_idle(gs, got)
	if str(idle.get("error", "")) != "":
		bad("the idle animation: %s" % idle["error"])
	else:
		var anim: Animation = idle["animation"]
		print("idle: %d frames over %d bones, %.2f s, %d track(s)"
			% [int(idle["frames"]), int(idle["bones"]), anim.length, anim.get_track_count()])
		print("      %s" % str(idle["clip"]))

		var player: HighpolyIdlePlayer = idle["player"]
		player.seek(0.0, true)
		var drift := 0.0
		for i in range(skel.get_bone_count()):
			drift = maxf(drift, skel.get_bone_pose(i).origin.distance_to(before[i].origin))
		print("time 0.0 vs the record's pose: worst bone shift %.9f m" % drift)
		if drift > TOLERANCE:
			bad("playing the idle at time 0 moves the soldier off the pose it was built in")

		player.seek(anim.length * 0.5, true)
		var travelled := 0.0
		for i in range(skel.get_bone_count()):
			travelled = maxf(travelled, skel.get_bone_pose(i).origin.distance_to(before[i].origin))
		print("halfway through the clip: worst bone shift %.6f m" % travelled)
		if travelled <= 0.0:
			bad("the idle never moves a bone - it is a still frame, not an animation")

		# DOES THE PLUGIN'S TICK MOVE IT? Seeking proves the animation data is
		# right and proves nothing about playback. The idle is advanced by
		# the group the EditorPlugin walks each frame - so that is
		# what gets called here, rather than waiting on a _process that this
		# test cannot make behave like the editor's.
		mark("driving the idle")
		player.drive("idle")
		var at_start := []
		for i in range(skel.get_bone_count()):
			at_start.append(skel.get_bone_pose(i).origin)
		var ticked := 0
		for _f in range(30):
			ticked += _tick_idles(1.0 / 60.0, root.global_position)
		var unattended := 0.0
		for i in range(skel.get_bone_count()):
			unattended = maxf(unattended, skel.get_bone_pose(i).origin.distance_to(at_start[i]))
		print("30 plugin ticks (%d moved a soldier): worst bone shift %.6f m"
			% [ticked, unattended])
		if ticked == 0:
			bad("the plugin's tick reached no idle player at all")
		if unattended <= 0.0:
			bad("the animation does not advance by itself - it will stand still in the editor")

	# ---- the route ---------------------------------------------------------
	# The builder is only useful if the spawner overlay actually reaches it.
	# This is the exact request the inspector's Motion picker produces, so a
	# pass here means flicking that picker in the editor does what it says.
	mark("the route and defaults")
	var req := HighpolyLoadout.soldier_request("PlayerSpawner", {"animated": true})
	if not bool(req.get("animated", false)):
		bad("the inspector's Motion choice does not survive into the soldier request")
	var still := HighpolyLoadout.soldier_request("PlayerSpawner", {"animated": false})
	if bool(still.get("animated", true)):
		bad("a soldier explicitly set to Still came back animated")
	if JSON.stringify(req) == JSON.stringify(still):
		bad("animated and still soldiers share an asset id, so toggling will not rebuild")

	# ---- the two things that were reported ---------------------------------
	# "every soldier got the same stance": the default was `assault` for every
	# spawner, so a row of them stood identically. The default is now Random,
	# which resolves per spawner name.
	var defaults := HighpolyLoadout.soldier_request("PlayerSpawner", {}, "PlayerSpawner")
	if str(defaults.get("role", "")) != HighpolyLoadout.ROLE_RANDOM:
		bad("the default pose is not Random, so untouched spawners will all match")
	if not bool(defaults.get("animated", false)):
		bad("soldiers are not animated by default any more")
	var poses_seen := {}
	for n in ["PlayerSpawner", "PlayerSpawner2", "AI_Spawner", "SpawnPoint",
			"SpawnPoint4", "Spawner_Bravo"]:
		var d := HighpolyLoadout.resolve_role(gs,
			HighpolyLoadout.soldier_request("PlayerSpawner", {}, n))
		poses_seen[str(d.get("role", ""))] = true
	print("untouched spawners resolve to %d distinct pose(s): %s"
		% [poses_seen.size(), str(poses_seen.keys())])
	if poses_seen.size() < 2:
		bad("untouched spawners still all resolve to one pose")
	print("request keys: %s" % str(req.keys()))
	print("animated request differs from still: %s"
		% str(JSON.stringify(req) != JSON.stringify(still)))

	# ---- the random pose ---------------------------------------------------
	# Two things, and the second is the one that bites: a random pose must be
	# ARBITRARY between spawners and FIXED for any one of them. Rolled fresh per
	# build it would change every rebuild and every reload, so the same spawner
	# would be a different soldier each session.
	var seen := {}
	var first := {}
	for n in ["PlayerSpawner", "PlayerSpawner2", "PlayerSpawner3", "AI_Spawner",
			"AI_Spawner7", "SpawnPoint", "SpawnPoint12", "Spawner_Alpha"]:
		var r := HighpolyLoadout.soldier_request("PlayerSpawner",
			{"role": HighpolyLoadout.ROLE_RANDOM}, n)
		var role := str(HighpolyLoadout.resolve_role(gs, r).get("role", ""))
		seen[role] = int(seen.get(role, 0)) + 1
		first[n] = role
		# Same name, same answer, every time it is asked.
		for _again in range(3):
			var again := str(HighpolyLoadout.resolve_role(gs,
				HighpolyLoadout.soldier_request("PlayerSpawner",
					{"role": HighpolyLoadout.ROLE_RANDOM}, n)).get("role", ""))
			if again != role:
				bad("spawner %s got %s and then %s - a random pose is not stable" % [n, role, again])
	print("random poses over 8 spawners: %s" % str(seen))
	if seen.size() < 2:
		bad("every spawner drew the same random pose - that is not a spread")
	# And an explicit choice must survive untouched.
	var explicit := HighpolyLoadout.resolve_role(gs,
		HighpolyLoadout.soldier_request("PlayerSpawner", {"role": "recon"}, "PlayerSpawner"))
	if str(explicit.get("role", "")) != "recon":
		bad("an explicitly chosen pose was overwritten by the random one")

	# ---- the radius --------------------------------------------------------
	# The whole reason the animation is affordable: posing 341 bones and
	# re-skinning costs the same at 500 m as at arm's length. Beyond the radius
	# the clock must stop; inside it the soldier must move. Uses the player the
	# soldier already has - a second one would fight the first over the same
	# skeleton and neither result would mean anything.
	if str(idle.get("error", "")) == "":
		var p2: HighpolyIdlePlayer = idle["player"]
		mark("the radius")
		var cam := Camera3D.new()
		get_root().add_child(cam)

		cam.global_position = root.global_position + Vector3(0, 0, 5)
		for _f in range(3): _tick_idles(1.0 / 60.0, cam.global_position)
		var near_start := _poses(skel)
		for _f in range(20): _tick_idles(1.0 / 60.0, cam.global_position)
		var near_moved := _moved(skel, near_start)

		cam.global_position = root.global_position + Vector3(0, 0, 500)
		for _f in range(3): _tick_idles(1.0 / 60.0, cam.global_position)
		var far_start := _poses(skel)
		for _f in range(20): _tick_idles(1.0 / 60.0, cam.global_position)
		var far_moved := _moved(skel, far_start)

		print("camera 5 m away,   20 frames: worst bone moved %.6f m" % near_moved)
		print("camera 500 m away, 20 frames: worst bone moved %.6f m" % far_moved)
		if near_moved <= 0.0:
			bad("a soldier under the camera's nose does not animate")
		if far_moved > 0.0:
			bad("a soldier 500 m away is still being animated - the radius does nothing")
		cam.queue_free()

	root.queue_free()
	print("\n%s: %d failure(s)" % ["FAIL" if fails else "PASS", fails])
	quit(1 if fails else 0)


# Every bone's posed origin, and the worst shift since such a snapshot. Over
# EVERY bone: only 146 of the 341 are driven by the clip, so watching one
# hand-picked index reports "nothing moved" for a perfectly good animation.
func _poses(skel: Skeleton3D) -> Array:
	var out := []
	for i in range(skel.get_bone_count()):
		out.append(skel.get_bone_pose(i).origin)
	return out


func _moved(skel: Skeleton3D, from: Array) -> float:
	var worst := 0.0
	for i in range(mini(skel.get_bone_count(), from.size())):
		worst = maxf(worst, skel.get_bone_pose(i).origin.distance_to(from[i]))
	return worst


func _mesh_of(node: Node) -> ArrayMesh:
	for c in node.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh is ArrayMesh:
			return mi.mesh
	return null


# The plugin advances idles by walking the group; the test does the same thing
# rather than a private path, so what is measured is what ships.
func _tick_idles(delta: float, camera: Vector3) -> int:
	var moved := 0
	for p in get_nodes_in_group(HighpolyIdlePlayer.GROUP):
		if (p as HighpolyIdlePlayer).tick_idle(delta, camera, true):
			moved += 1
	return moved
