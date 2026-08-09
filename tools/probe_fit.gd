@tool
extends SceneTree

# WHAT THE FITTER DECIDES, AND WHY, for one prop.
#
# _fit_scale compares two bounding boxes and, when they disagree, permutes the
# model's axes and rescales it. That is a guess. This prints the guess and its
# inputs so "the rotation and scale are wrong" can be attributed to the fitter
# misfiring on a correct model, or to the model genuinely arriving wrong.
#
#   --headless --script tools/probe_fit.gd -- ACModule_02 [more keys...]

const LibScript = preload("res://addons/highpoly_toggle/highpoly_lib.gd")


func _aabb_of(n: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is GeometryInstance3D:
			var g := c as GeometryInstance3D
			var ab: AABB = g.transform * g.get_aabb()
			if first:
				out = ab
				first = false
			else:
				out = out.merge(ab)
		for k in c.get_children():
			stack.append(k)
	return out


func _init() -> void:
	var keys := PackedStringArray(["ACModule_02"])
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		keys = PackedStringArray(args)

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	var map := "MP_Dumbo"
	print("opening %s for the install..." % map)
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("open failed: ", gs.error)
		quit(1)
		return
	gs.upgrade_catalogue()
	LibScript.game_source = gs
	print("catalogue ready: %s\n" % gs.catalogue_ready)

	for key in keys:
		print("=== %s ===" % key)
		# --- the SDK proxy ---
		var tp := "res://objects/props/%s.tscn" % key
		if not ResourceLoader.exists(tp):
			print("  no SDK scene at %s" % tp)
			continue
		var ps := load(tp) as PackedScene
		var proxy := ps.instantiate() as Node3D
		get_root().add_child(proxy)
		var pa := _aabb_of(proxy)
		print("  proxy    size %8.3f %8.3f %8.3f   centre %7.2f %7.2f %7.2f"
			% [pa.size.x, pa.size.y, pa.size.z,
			   pa.get_center().x, pa.get_center().y, pa.get_center().z])

		# --- the high-poly model, straight from the install ---
		var hp = gs.object_node(key)
		if hp == null:
			print("  the install has no object for this key")
			proxy.queue_free()
			continue
		get_root().add_child(hp)
		var ha := _aabb_of(hp)
		print("  highpoly size %8.3f %8.3f %8.3f   centre %7.2f %7.2f %7.2f"
			% [ha.size.x, ha.size.y, ha.size.z,
			   ha.get_center().x, ha.get_center().y, ha.get_center().z])

		# --- what _fit_scale would do -------------------------------------
		var pd := pa.size
		var hd := ha.size
		var ident: Array = LibScript._fit_eval(pd, hd)
		print("  identity fit: spread %.3f  scale %.3f   (rotates above 1.35, "
			% [ident[0], ident[1]] + "rescales outside 0.9-1.1)")
		var best_spread: float = ident[0]
		var best_scale: float = ident[1]
		var rotated := false
		var which := -1
		if ident[0] > 1.35:
			var i := 0
			for b in LibScript._perm_bases():
				var ev: Array = LibScript._fit_eval(pd, (b * hd).abs())
				print("    perm %d: spread %.3f  scale %.3f%s"
					% [i, ev[0], ev[1], "   <-- best so far" if ev[0] < best_spread else ""])
				if ev[0] < best_spread:
					best_spread = ev[0]
					best_scale = ev[1]
					rotated = true
					which = i
				i += 1
		var vetoed: bool = best_spread > 1.35
		var need_scale: bool = best_scale < 0.9 or best_scale > 1.1
		print("  VERDICT: %s" % (
			"VETOED, the proxy is kept and the model thrown away" if vetoed
			else "rotated by permutation %d, " % which if rotated else "not rotated, ")
			+ ("" if vetoed else ("rescaled by %.3f" % best_scale if need_scale
				else "not rescaled")))
		print("  nofit exempt: %s" % LibScript._nofit_for(key))
		proxy.queue_free()
		hp.queue_free()
		print("")
	quit(0)
