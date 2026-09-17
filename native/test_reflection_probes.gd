extends SceneTree

# Public ABI -> GDExtension -> Godot proof for the level's reflection volumes.
#
# WHY THIS DOES NOT CALL highpoly_lighting.build_reflection_probes DIRECTLY:
# that script reaches the HighpolyProfiler/HighpolyProfile globals, and a
# headless --script run has no populated global class registry, so preloading it
# fails to compile before any of this can run. The builder is compile-checked
# where it belongs, by tools/gate_sandbox.py in a real plugin project. What
# cannot be checked there is the DATA and the arithmetic, which is this.
#
# The arithmetic is the part that goes wrong silently. The transform arrives as
# a full basis whose axis LENGTHS are the half-extents; reading it as
# already-normalised gives every probe a 1 m box, which still renders and
# reflects nothing useful. So the sizes are computed here exactly as the builder
# computes them and then checked:
#
#   1. Every volume has a non-degenerate box. A zero axis has no interior.
#   2. The boxes are NOT all one size, which is the normalised-basis signature.
#   3. The volumes are spread out: one box per level would also "work".
#   4. Every volume names a baked texture, and the basis axes are orthogonal,
#      which is what says the three axes were read as a basis and not as three
#      unrelated vectors.
#   5. A level that authors none says so rather than failing.


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_reflection_probes.gd -- <Steam BF6 root> [level ...]")
		quit(2)
		return
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered")
		quit(1)
		return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(args[0])):
		print("FAIL open: %s" % (core.last_error() if core != null else "null"))
		quit(1)
		return

	var levels: Array = args.slice(1) if args.size() > 1 else ["mp_isolated"]
	var failures := 0
	for lv in levels:
		var level := str(lv)
		var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
		var data: Dictionary = env.request("reflection_probes")
		if data.is_empty():
			print("%-22s FAIL %s" % [level, str(env.error)])
			failures += 1
			continue
		var probes: Array = data.get("probes", [])
		if probes.is_empty():
			print("%-22s authors no reflection volumes of its own" % level)
			continue

		var sizes: Array = []
		var lo := Vector3(1e30, 1e30, 1e30)
		var hi := Vector3(-1e30, -1e30, -1e30)
		var degenerate := 0
		var no_texture := 0
		var not_orthogonal := 0
		for entry in probes:
			var p: Dictionary = entry
			var r := _v(p.get("right"))
			var u := _v(p.get("up"))
			var f := _v(p.get("forward"))
			var half := Vector3(r.length(), u.length(), f.length())
			if half.x <= 0.001 or half.y <= 0.001 or half.z <= 0.001:
				degenerate += 1
				continue
			if str(p.get("texture", "")).is_empty():
				no_texture += 1
			# A basis, not three loose vectors: the axes must be perpendicular.
			var rn := r.normalized(); var un := u.normalized(); var fn := f.normalized()
			if absf(rn.dot(un)) > 0.02 or absf(rn.dot(fn)) > 0.02 or absf(un.dot(fn)) > 0.02:
				not_orthogonal += 1
			sizes.append(half * 2.0)          # exactly what the builder assigns
			var t := _v(p.get("translation"))
			lo = lo.min(t)
			hi = hi.max(t)

		# THE CORE'S FALLBACK CALL, checked here because both editors act on it:
		# whatever is flagged global must be the largest box, and there must be
		# at most one. Flagging a local volume would delete a real probe from
		# both editors at once, which is the kind of shared mistake putting the
		# decision in the core is supposed to prevent.
		var global_sizes: Array = []
		var local_max := 0.0
		for entry2 in probes:
			var q: Dictionary = entry2
			var vol := _v(q.get("right")).length() * _v(q.get("up")).length() * _v(q.get("forward")).length()
			if int(q.get("is_global", 0)) == 1: global_sizes.append(vol)
			elif vol > local_max: local_max = vol
		print("      flagged level-wide: %d, smallest of them %.0f m3, largest local %.0f m3" % [
			global_sizes.size(), (global_sizes.min() if global_sizes.size() > 0 else 0.0), local_max])
		if global_sizes.size() > 1:
			print("   FAIL more than one volume flagged level-wide"); failures += 1
		if global_sizes.size() == 1 and global_sizes[0] <= local_max:
			print("   FAIL the flagged volume is not the largest"); failures += 1

		var distinct := {}
		for s in sizes:
			distinct[Vector3(snappedf(s.x, 0.01), snappedf(s.y, 0.01), snappedf(s.z, 0.01))] = true
		var spread := (hi - lo).length() if sizes.size() > 1 else 0.0
		var biggest := Vector3.ZERO
		for s in sizes:
			if s.length() > biggest.length(): biggest = s
		print("%-22s %3d volume(s)  %2d distinct box size(s)  biggest %s m  spread %.0f m" % [
			level, probes.size(), distinct.size(), str(biggest.round()), spread])

		if sizes.is_empty():
			print("   FAIL rows came back but every box was degenerate"); failures += 1
		if degenerate > 0:
			print("   NOTE %d degenerate volume(s) skipped" % degenerate)
		if no_texture > 0:
			print("   FAIL %d volume(s) name no baked texture" % no_texture); failures += 1
		if not_orthogonal > 0:
			print("   FAIL %d volume(s) have a non-orthogonal basis" % not_orthogonal); failures += 1
		if sizes.size() > 1 and distinct.size() == 1:
			print("   FAIL every box is the same size: the basis was read as normalised"); failures += 1
		if sizes.size() > 1 and spread < 1.0:
			print("   FAIL volumes collapse to a point"); failures += 1

	print("\n%s" % ("PASS" if failures == 0 else "FAIL: %d problem(s)" % failures))
	quit(1 if failures else 0)


func _v(x) -> Vector3:
	if x is Array and (x as Array).size() >= 3:
		var a: Array = x
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO
