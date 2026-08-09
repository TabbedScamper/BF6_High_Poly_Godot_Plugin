@tool
extends SceneTree
# Which depot scope SHOULD dress a mesh, and what the reader picks.
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	gs.upgrade_catalogue()
	var mesh := "common/environment/generic/common/vegetation/londonplanetree_01/tr_com_londonplanetree_01_l_b_mesh"
	print("mesh in res table : ", gs.src.res.has(mesh))
	print("_scope_of()       : '", gs._scope_of(mesh), "'")
	print("res_bundle        : '", str(gs.src.res_bundle.get(mesh, "")), "'")
	print("\ndepot scopes naming 'londonplanetree':")
	var n := 0
	for k in gs._depot_bundles.keys():
		if str(k).findn("londonplanetree") >= 0:
			print("   ", k); n += 1
	print("   (%d)" % n)
	print("\ndepot scopes naming 'planetree' or 'vegetation':")
	n = 0
	for k in gs._depot_bundles.keys():
		var ks := str(k)
		if ks.findn("planetree") >= 0 or ks.findn("vegetation") >= 0:
			print("   ", ks); n += 1
			if n > 12: break
	print("   (%d shown)" % n)
	print("\nis 'default_event' a real depot scope? ",
		gs._depot_bundles.has("default_event"))
	# every res under the tree's directory
	var dir := "common/environment/generic/common/vegetation/londonplanetree_01/"
	var cnt := 0
	for rn in gs.src.res.keys():
		if str(rn).begins_with(dir): cnt += 1
	print("res under the tree dir: ", cnt)
	print("
depot scopes containing default_event:")
	for k in gs._depot_bundles.keys():
		if str(k).findn("default_event") >= 0: print("   ", k)
	print("
mp_aftermath level scopes:")
	var m := 0
	for k in gs._depot_bundles.keys():
		if str(k).findn("aftermath") >= 0:
			print("   ", k); m += 1
			if m > 6: break
	quit(0)
