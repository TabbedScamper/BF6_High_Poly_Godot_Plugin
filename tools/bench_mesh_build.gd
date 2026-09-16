extends SceneTree
# Time building every placed mesh of a map (geometry + materials), as a map open does.
#   -- <install> <level> <cache:0|1> <native:0|1>
const Source = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const Cache = preload("res://addons/highpoly_toggle/highpoly_install_cache.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var install := str(a[0])
	var level := str(a[1])
	Cache.accept(install, Cache.inspect(install))
	var gs = Source.new()
	gs.geom_cache = a[2] == "1"
	gs.geom_cache_read = a[2] == "1"
	var t0 := Time.get_ticks_msec()
	if not gs.open_map(level, install, func(_s, _d, _t): pass):
		push_error("open_map failed: " + str(gs.error))
		quit(3)
		return
	var t_open := Time.get_ticks_msec() - t0
	gs._ms.use_native_sections = a[3] == "1"
	var data: Dictionary = gs.map_data("", {"objects": true, "water": false, "lights": false, "fx": false, "edv": false, "sky": false})
	var props: Array = data.get("props", []).duplicate()
	props.append_array(data.get("backdrop", []))
	var keys := {}
	for p in props:
		keys[str(p.get("mesh", ""))] = true
	var t1 := Time.get_ticks_msec()
	var built := 0
	for key in keys:
		if gs.mesh_for(str(key)) != null:
			built += 1
	var t_mesh := Time.get_ticks_msec() - t1
	print("level %s cache=%s native=%s: open %.1f s, %d groups -> %d meshes in %.1f s (geom hit %d miss %d, native reads %d)" % [
		level, a[2], a[3], t_open / 1000.0, keys.size(), built, t_mesh / 1000.0,
		int(gs.n_geom_hit), int(gs.n_geom_miss), int(gs._ms.native_section_reads)])
	print("  t_res %.1f s  t_parse %.1f s  t_mat %.1f s  t_tex %.1f s (res %.1f dec %.1f chunk %.1f post %.1f up %.1f)  t_depot %.1f s  t_geom_load %.1f s  save %.1f s" % [
		gs.t_res / 1e6, gs.t_parse / 1e6, gs.t_mat / 1e6, gs.t_tex / 1e6, gs.t_tex_res / 1e6, gs.t_tex_dec / 1e6,
		gs.t_tex_chunk / 1e6, gs.t_tex_post / 1e6, gs.t_tex_up / 1e6, gs.t_depot / 1e6, gs.t_geom_load / 1e6, gs.t_geom_save / 1e6])
	print("  meshes %d sections %d surfaces %d mat built %d cached %d depots %d" % [gs.n_meshes, gs.n_sections, gs.n_surfaces, gs.n_mat_built, gs.n_mat_cached, gs.n_depot_parsed])
	print("  asm hidden %.1f s call %.1f s decide %.1f s build %.1f s (native %d) precache served %d batch %.1f s" % [gs.t_asm_hidden / 1e6, gs.t_asm_call / 1e6, gs.t_asm_decide / 1e6, gs.t_asm_build / 1e6, gs.n_native_assembled, gs.n_precache_meshes, gs.t_precache / 1e6])
	print("  texture chunks %d, %.1f MB" % [gs.n_tex_chunks, gs.n_tex_chunk_bytes / 1048576.0])
	print("  precache textures %d read ahead in %.1f s, requested %d, decoded %d" % [gs.n_precache_textures, gs.t_precache_tex / 1e6, gs.n_tex_readahead_requested, int(gs.tex_stats.get("decoded", 0))])
	quit(0)
