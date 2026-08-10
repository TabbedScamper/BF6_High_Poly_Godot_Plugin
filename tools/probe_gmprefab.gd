@tool
extends SceneTree
# The 60 SpatialPrefabReferenceObjectData in the conquest partitions, by name.
#
# No capture-point entity exists in this level's mode layers - the type dump
# shows 137 spawns, 8 volumes, 2 OBBs and 60 prefab references, and nothing that
# names a flag. If a flag pole ships as one of those prefabs then its NAME says
# so, and its position says which volume is the capture zone. That would be
# positive evidence where geometry gave none.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := str(args[0]) if args.size() > 0 else "conquest"
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed: ", gs.error); quit(1); return

	var pre := ""
	for k in gs.src.ebx.keys():
		var s := str(k)
		var at := s.findn("/levels/mp_aftermath/_layers_gameplay/")
		if at >= 0:
			pre = s.substr(0, at) + "/levels/mp_aftermath/_layers_gameplay/"
			break
	var parts: Array = []
	for k in gs.src.ebx.keys():
		if str(k).begins_with(pre + mode):
			parts.append(str(k))
	parts.sort()

	var seen := {}
	for p in parts:
		var eb = gs.walk.open_ebx(p)
		if eb == null:
			continue
		for i in range(eb.instance_offsets.size()):
			var tg := str(eb.instance_type(i))
			if tg != "6e747c11-2b0f-f724-9084-6b609eb8dd3e" \
					and tg != "53a303b0-6696-5565-b274-3a25591f19b5" \
					and tg != "0de9bfc7-a83d-8d72-a684-c3ec2650aa83":
				continue
			var inst = eb.read_instance(i)
			if not (inst is Dictionary):
				continue
			var d: Dictionary = inst
			var bp = d.get(BF6Walk.F_BLUEPRINT)
			var nm := _name_of(gs, bp)
			var lt = d.get(BF6Walk.F_BP_TRANSFORM)
			var o := Vector3.ZERO
			if BF6Walk.is_lt(lt):
				o = BF6Walk.lt_to_mat(lt)[3]
			var key := "%s|%s" % [p.get_file(), nm]
			if not seen.has(key):
				seen[key] = []
			(seen[key] as Array).append(o)

	var keys: Array = seen.keys()
	keys.sort()
	print("%d distinct prefab(s) referenced by %s\n" % [keys.size(), mode])
	for k in keys:
		var at: Array = seen[k]
		var pos := ""
		for i in range(mini(at.size(), 6)):
			pos += "(%.0f,%.0f,%.0f) " % [(at[i] as Vector3).x, (at[i] as Vector3).y,
				(at[i] as Vector3).z]
		print("%3d  %-64s %s" % [at.size(), k, pos])
	quit(0)


func _name_of(gs, ref) -> String:
	if ref == null:
		return "(none)"
	if ref is String:
		return str(ref).get_file()
	if ref is Dictionary:
		var d: Dictionary = ref
		for k in ["path", "import", "partition", "name", "ref"]:
			if d.has(k):
				return str(d[k]).get_file()
		return "Dict{%s}" % ", ".join(d.keys().slice(0, 5).map(
			func(x): return ("0x%08X" % int(x)) if x is int else str(x)))
	return str(ref).left(70)
