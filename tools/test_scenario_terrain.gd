@tool
extends SceneTree
# THE NECESSITY BENCH, scenario "terrain only". The timing bench can say a
# phase is slow; only a scenario run can say a phase should not exist. This
# opens a map exactly as the dock does when Extended Terrain alone is on
# (want placements=false) and asserts two things:
#
#   1. NO placement-walk phase ran - the walk feeds props/skyline/lights/FX,
#      none of which terrain reads. Its presence here is the regression this
#      test exists to catch (it lived for months as a fast, well-measured,
#      completely unrequested 50 s cold phase).
#   2. The terrain products still built - the ground cannot secretly depend
#      on the thing we skipped.
#
# Run it after any change to open_map's gating, _wants_map_layers, or what
# the terrain family consumes.

func _init() -> void:
	var gs = HighpolyGameSource.new()
	var cache := "user://scenario_terrain"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cache))
	gs.surface_cache = ProjectSettings.globalize_path(cache)
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("SCENARIO FAIL: open refused: ", gs.error)
		quit(1)
		return
	var bad := false
	if gs.phases.has("placement walk"):
		print("SCENARIO FAIL: terrain-only open ran the placement walk")
		bad = true
	if gs.placements_ready:
		print("SCENARIO FAIL: placements_ready without a placements request")
		bad = true
	var tr := gs.terrain(ProjectSettings.globalize_path(cache))
	if tr.is_empty():
		print("SCENARIO FAIL: terrain heightfield did not build without the walk")
		bad = true
	var sf := gs.terrain_surface(ProjectSettings.globalize_path(cache))
	if sf.is_empty():
		print("SCENARIO FAIL: ground surface did not build without the walk")
		bad = true
	if bad:
		quit(1)
		return
	print("SCENARIO OK: terrain-only open - no placement walk, heightfield %dx%d, %d ground slices"
		% [int(tr.get("res", 0)), int(tr.get("res", 0)), int(sf.get("slices", 0))])
	quit(0)
