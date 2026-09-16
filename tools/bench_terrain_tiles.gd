extends SceneTree
# Times the extended terrain's tile build (vertices, LOD chain, skirts) from a
# map's native heightfield, into a scratch folder so no real cache is touched.
#   -- <install> <level>
# Prints tiles, surfaces, vertex and index totals of LOD 0, and a digest of
# LOD 0 geometry, so builds can be compared.
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")
const MapContext = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var install := str(a[0])
	var level := str(a[1])
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed: " + str(gs.error))
		quit(3)
		return
	var dir := OS.get_user_data_dir().path_join("bench_terrain_tiles").path_join(level)
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	var t0 := Time.get_ticks_msec()
	var meta: Dictionary = gs.terrain(dir)
	print("heightfield export: %d ms (res %s)" % [Time.get_ticks_msec() - t0, str(meta.get("res", "?"))])
	if meta.is_empty():
		quit(4)
		return
	var mc = MapContext.new()
	root.add_child(mc)
	t0 = Time.get_ticks_msec()
	var terrain: Node3D = mc._build_terrain_from_heightmap(dir, meta)
	var build_ms := Time.get_ticks_msec() - t0
	var tiles := 0
	var surfaces := 0
	var verts := 0
	var idx := 0
	var lods := 0
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for c in terrain.get_children():
		if not (c is MeshInstance3D):
			continue
		var m: Mesh = (c as MeshInstance3D).mesh
		tiles += 1
		surfaces += m.get_surface_count()
		var arr: Array = m.surface_get_arrays(0)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		verts += v.size()
		idx += ix.size()
		ctx.update(v.to_byte_array())
		ctx.update(ix.to_byte_array())
		# The LOD chain as the renderer holds it: every level's index buffer.
		for s in range(m.get_surface_count()):
			var surf: Dictionary = RenderingServer.mesh_get_surface(m.get_rid(), s)
			for lod in surf.get("lods", []):
				ctx.update((lod as Dictionary).get("index_data", PackedByteArray()))
				lods += 1
	print("TERRAIN TILES %s: build %d ms, %d tiles, %d surfaces, %d vertices, %d indices, %d lod levels, digest %s" % [
		level, build_ms, tiles, surfaces, verts, idx, lods, ctx.finish().hex_encode().substr(0, 16)])
	quit(0)
