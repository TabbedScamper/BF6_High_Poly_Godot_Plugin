@tool
extends SceneTree
const LibScript = preload("res://addons/highpoly_toggle/highpoly_lib.gd")

func _aabb(n: Node) -> AABB:
	var out := AABB(); var first := true; var st: Array = [n]
	while not st.is_empty():
		var c: Node = st.pop_back()
		if c is GeometryInstance3D:
			var g := c as GeometryInstance3D
			var ab: AABB = g.transform * g.get_aabb()
			if first: out = ab; first = false
			else: out = out.merge(ab)
		for k in c.get_children(): st.append(k)
	return out

func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s: String) -> void: print("   ", s)
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	LibScript.game_source = gs
	var keys := PackedStringArray(["VEH_Abrams","VEH_Cheetah","VEH_AH6M","VEH_F22",
		"VEH_Marauder","VEH_Quadbike","VEH_Golfcart","VEH_Stationary_BGM71TOW"])
	var ok := 0
	for k in keys:
		var id: String = LibScript._asset_id(k)
		if id == "":
			print("%-26s no asset id (keeps its proxy)" % k); continue
		var n = LibScript._instance_for(k, id)
		if n == null:
			print("%-26s id %s but build returned null" % [k, id]); continue
		get_root().add_child(n)
		var ab := _aabb(n)
		var surf := 0
		var dressed := 0
		for c in n.get_children():
			if c is MeshInstance3D:
				var am := (c as MeshInstance3D).mesh as ArrayMesh
				if am != null:
					surf += am.get_surface_count()
					for i in range(am.get_surface_count()):
						if am.surface_get_material(i) != null: dressed += 1
		print("%-26s %6.2f x %6.2f x %6.2f m   %d surfaces, %d dressed"
			% [k, ab.size.x, ab.size.y, ab.size.z, surf, dressed])
		ok += 1
		n.queue_free()
	print("\nbuilt %d of %d" % [ok, keys.size()])
	quit(0)
