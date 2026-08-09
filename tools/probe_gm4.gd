@tool
extends SceneTree
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	var p := "game/glaciermp/levels/mp_aftermath/_layers_gameplay/conquest/conquest_captureareavisualisation"
	var eb = gs.walk.open_ebx(p)
	if eb == null:
		print("open_ebx null"); quit(1); return
	print("instances: %d" % eb.exported_instance_count)
	for i in range(mini(eb.exported_instance_count, 14)):
		var inst: Dictionary = eb.read_instance(i)
		var tg := str(eb.instance_type(i))
		var keys: Array = inst.keys()
		print("\n[%d] type %s  (%d fields)" % [i, tg.substr(0, 13), keys.size()])
		for k in keys:
			var v = inst[k]
			var d := ""
			if BF6Walk.is_lt(v):
				var m := BF6Walk.lt_to_mat(v)
				d = "LinearTransform origin=(%.1f, %.1f, %.1f)" % [m[3].x, m[3].y, m[3].z]
			elif v is float or v is int:
				d = str(v)
			elif v is String:
				d = '"%s"' % str(v).left(48)
			elif v is Array:
				d = "Array[%d]" % (v as Array).size()
			elif v is Dictionary:
				d = "Dict{%s}" % ", ".join((v as Dictionary).keys().slice(0, 4).map(func(x): return str(x)))
			else:
				d = str(typeof(v))
			print("     %-22s %s" % [str(k), d])
	quit(0)
