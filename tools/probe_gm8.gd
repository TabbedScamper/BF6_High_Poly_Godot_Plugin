@tool
extends SceneTree
# What a gamemode entity ACTUALLY carries.
#
# The miner records an origin and nothing else, which is why the overlay can
# only draw a fixed-size orb. To instance a real CapturePoint + PolygonVolume we
# need the polygon points, the OBB extents, the spawn's facing, and a name to
# label it with. Field names are not resolvable (ebx_typehashes.tsv is type
# names only), so find them STRUCTURALLY: dump every field of every instance of
# the four types and look for the array of vectors and the extents vector.

const WANT := {
	"f7fbc419-e145-394f-7086-b81c1935e8ab": "AlternateSpawnEntityData",
	"9fc7ba2d-7564-b0a6-8a9c-61f3fd93e55d": "VolumeVectorShapeData",
	"c8e55f62-8409-c039-a6bb-fbd11cb03739": "OBBData",
	"e36c4110-716c-d05f-7615-8f7b8a5d620b": "CombatAreaEntityData",
}

func _init() -> void:
	var mode := "conquest"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		mode = str(args[0])
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return

	var pre := ""
	for k in gs.src.ebx.keys():
		var s := str(k)
		var at := s.findn("/levels/mp_aftermath/_layers_gameplay/")
		if at >= 0:
			pre = s.substr(0, at) + "/levels/mp_aftermath/_layers_gameplay/"
			break
	if pre == "":
		print("no _layers_gameplay"); quit(1); return

	var parts: Array = []
	for k in gs.src.ebx.keys():
		var s := str(k)
		if s.begins_with(pre + mode):
			parts.append(s)
	parts.sort()
	print("%d partitions under %s%s\n" % [parts.size(), pre, mode])

	# one worked example per type is enough to read the layout off
	var seen := {}
	for p in parts:
		var eb = gs.walk.open_ebx(p)
		if eb == null:
			continue
		var n: int = eb.instance_offsets.size()
		for i in range(n):
			var tg := str(eb.instance_type(i))
			var nm = WANT.get(tg)
			if nm == null:
				continue
			if int(seen.get(nm, 0)) >= 3:
				continue
			seen[nm] = int(seen.get(nm, 0)) + 1
			var inst: Dictionary = eb.read_instance(i)
			print("=== %s   [%s inst %d]" % [nm, p.get_file(), i])
			_dump(inst, "    ")
			print("")
	print("counts: %s" % str(seen))
	quit(0)


func _dump(inst: Dictionary, ind: String) -> void:
	var keys: Array = inst.keys()
	keys.sort()
	for k in keys:
		if str(k) == "__type":
			continue
		print("%s%-12s %s" % [ind, "0x%08X" % int(k) if k is int else str(k),
			_describe(inst[k], ind)])


func _describe(v, ind: String) -> String:
	if BF6Walk.is_lt(v):
		var m := BF6Walk.lt_to_mat(v)
		return "LinearTransform  o=(%.2f, %.2f, %.2f)  r=(%.2f,%.2f,%.2f) f=(%.2f,%.2f,%.2f)" % [
			m[3].x, m[3].y, m[3].z, m[0].x, m[0].y, m[0].z, m[2].x, m[2].y, m[2].z]
	if v is Dictionary:
		var d := v as Dictionary
		if d.has(BF6Walk.K_VEC_X) and d.has(BF6Walk.K_VEC_Y):
			var vv := BF6Walk.vec_of(d)
			return "Vec  (%s)" % str(vv)
		return "Dict{%s}" % ", ".join(d.keys().slice(0, 6).map(
			func(x): return ("0x%08X" % int(x)) if x is int else str(x)))
	if v is Array:
		var a := v as Array
		var head := "Array[%d]" % a.size()
		if a.is_empty():
			return head
		var lines := PackedStringArray([head])
		for j in range(mini(a.size(), 6)):
			var e = a[j]
			if e is Dictionary and (e as Dictionary).has(BF6Walk.K_VEC_X):
				lines.append("%s      [%d] %s" % [ind, j, str(BF6Walk.vec_of(e))])
			elif e is Dictionary:
				lines.append("%s      [%d] Dict{%s}" % [ind, j,
					", ".join((e as Dictionary).keys().slice(0, 8).map(
						func(x): return ("0x%08X" % int(x)) if x is int else str(x)))])
			else:
				lines.append("%s      [%d] %s" % [ind, j, str(e).left(60)])
		if a.size() > 6:
			lines.append("%s      ... %d more" % [ind, a.size() - 6])
		return "\n".join(lines)
	if v is String:
		return '"%s"' % str(v).left(70)
	return str(v).left(70)
