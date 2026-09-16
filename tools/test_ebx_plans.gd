extends SceneTree
# The planned struct decode (BF6Ebx._plan_for) against the generic decoder, on
# every instance of every partition under a level.
#   -- <install> <level> [max partitions]
# Each instance is decoded in full both ways and compared with var_to_str,
# which distinguishes key order, int from float and every value.
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var install := str(a[0])
	var level := str(a[1]).to_lower()
	var limit := int(a[2]) if a.size() > 2 else 0
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed: " + str(gs.error))
		quit(3)
		return
	var names: Array = []
	for n in gs.src.ebx.keys():
		if str(n).contains("/levels/%s/" % level):
			names.append(str(n))
	names.sort()
	if limit > 0 and names.size() > limit:
		names = names.slice(0, limit)
	var gi: Dictionary = gs.walk.gi
	var instances := 0
	var differ := 0
	var shown := 0
	var t_plan := 0
	var t_generic := 0
	BF6Ebx.n_planned = 0
	for name in names:
		var bytes: PackedByteArray = gs.src.get_ebx(name)
		if bytes.is_empty():
			continue
		var planned := BF6Ebx.new(gs.types, gi)
		var generic := BF6Ebx.new(gs.types, gi)
		if not planned.parse(bytes) or not generic.parse(bytes):
			continue
		for i in range(planned.instance_offsets.size()):
			# In full, then through the walk's two field filters.
			for want in [{}, gs.walk._decode_want, gs.walk._XF_ONLY]:
				BF6Ebx.use_plans = true
				var t0 := Time.get_ticks_usec()
				var x := var_to_str(planned.read_instance(i, 0, want))
				t_plan += Time.get_ticks_usec() - t0
				BF6Ebx.use_plans = false
				t0 = Time.get_ticks_usec()
				var y := var_to_str(generic.read_instance(i, 0, want))
				t_generic += Time.get_ticks_usec() - t0
				instances += 1
				if x != y:
					differ += 1
					if shown < 3:
						print("DIFFERS %s #%d want %d\n  planned %s\n  generic %s" % [name, i, want.size(), x.left(300), y.left(300)])
						shown += 1
	BF6Ebx.use_plans = true
	print("EBX PLANS %s: %d partitions, %d instances, %d planned structs, %d differ; decode+format planned %.1f s, generic %.1f s" % [
		level, names.size(), instances, BF6Ebx.n_planned, differ, t_plan / 1e6, t_generic / 1e6])
	print("EBX PLANS %s" % ("PASSED" if differ == 0 and instances > 0 else "FAILED"))
	quit(0 if differ == 0 else 1)
