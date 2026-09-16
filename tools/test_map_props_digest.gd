extends SceneTree
# A digest of everything a map open decides before building meshes: every prop
# and backdrop row (mesh group key, transform, scope) and the mesh group table.
# Run it before and after a reader change; the digests must match.
#   -- <install> <level> [build]
# With "build", every mesh group is also built and each surface's material
# texture bindings join the digest.
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var install := str(a[0])
	var level := str(a[1])
	var build := a.size() > 2 and a[2] == "build"
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = false
	gs.geom_cache_read = false
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed: " + str(gs.error))
		quit(3)
		return
	var open_ms := Time.get_ticks_msec() - t0
	var data: Dictionary = gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
	var rows: Array = data.get("props", []).duplicate()
	rows.append_array(data.get("backdrop", []))
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for p in rows:
		ctx.update(var_to_str(p).to_utf8_buffer())
	var keys: Array = gs._group_meta.keys()
	keys.sort()
	for k in keys:
		ctx.update((str(k) + "=" + var_to_str(gs._group_meta[k])).to_utf8_buffer())
	var built := 0
	if build:
		var mesh_keys := {}
		for p in rows:
			mesh_keys[str(p.get("mesh", ""))] = true
		var sorted: Array = mesh_keys.keys()
		sorted.sort()
		for key in sorted:
			var mesh: Mesh = gs.mesh_for(str(key))
			if mesh == null:
				ctx.update((str(key) + ":null").to_utf8_buffer())
				continue
			built += 1
			for s in range(mesh.get_surface_count()):
				var m = mesh.surface_get_material(s)
				var line := "%s#%d:%d" % [key, s, mesh.surface_get_array_len(s)]
				if m is ShaderMaterial:
					for u in (m as ShaderMaterial).shader.get_shader_uniform_list():
						var v = (m as ShaderMaterial).get_shader_parameter(u["name"])
						if v is Texture2D:
							line += "|%s=%s" % [u["name"], (v as Texture2D).resource_name]
				elif m is BaseMaterial3D:
					var bm := m as BaseMaterial3D
					line += "|albedo=%s" % (bm.albedo_texture.resource_name if bm.albedo_texture else "")
				ctx.update(line.to_utf8_buffer())
			if built % 256 == 0:
				var scopes: Dictionary = gs._group_meta.duplicate()
				gs.release_caches()
				gs._group_meta = scopes
	print("MAP DIGEST %s: open %.1f s, %d rows, %d groups, %d built, from core index %s: %s" % [
		level, open_ms / 1000.0, rows.size(), keys.size(), built,
		str(gs.src.stats.get("native_core", false)) if gs.src != null else "?",
		ctx.finish().hex_encode()])
	quit(0)
