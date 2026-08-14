@tool
extends SceneTree
# RENDER A HANDFUL OF OBJECT ICONS AND WRITE THEM WHERE THEY CAN BE LOOKED AT.
#
# The library's icons are the one output of this plugin that is judged purely by
# eye, and until now the only way to see a change to them was to press "Build
# object previews" and wait for sixteen hundred. This renders the few you name,
# with the same camera the dock uses, in about as long as the map takes to open.
#
# It also times the three parts, because "it builds very slowly" deserves a
# number rather than a shrug: assembling the object out of the game, waiting for
# the viewport to draw, and writing the png.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_thumbs.gd -- MP_Aftermath Excavator_01 ...
#
# Copy this file to <project>/hp_test/ first: --script only loads from res://,
# and this repo is .gdignore'd so the editor never sees it.
#
# HEADLESS RENDERS NOTHING unless the display driver is up, so this runs with a
# window. That is deliberate: a headless viewport capture comes back empty and
# would "prove" the icons are blank.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const LIB := preload("res://addons/highpoly_toggle/highpoly_lib.gd")

const OUT_DIR := "user://thumbtest"
const SIZE := 256          # bigger than the dock's 128, so framing is judgeable


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := "MP_Aftermath"
	var keys: Array = []
	for i in range(args.size()):
		if i == 0:
			map = str(args[i])
		else:
			keys.append(str(args[i]))
	if keys.is_empty():
		keys = ["Excavator_01", "ConstructionFence_02_2m", "CeilingLamp_Rect_01",
			"Crate_02", "MetroBus_01", "TenniscourtFence_01_256"]
	await process_frame

	var gs = GS.new()
	if not gs.open_map(map, "", Callable(), {"placements": true}):
		print("could not open %s" % map)
		quit(1)
		return
	LIB.game_source = gs
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(vp)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.2
	vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.4
	vp.add_child(fill)
	var cam := Camera3D.new()
	vp.add_child(cam)

	print("")
	print("%-30s %9s %9s %9s  %s"
		% ["object", "assemble", "draw", "save", "aabb"])
	for k in keys:
		var t0 := Time.get_ticks_msec()
		var inst: Node3D = gs.object_node(str(k))
		var t_asm := Time.get_ticks_msec() - t0
		if inst == null:
			print("%-30s   (no object)" % str(k))
			continue
		vp.add_child(inst)
		var ab := _merged_aabb(inst)
		_frame(cam, ab)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		t0 = Time.get_ticks_msec()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var t_draw := Time.get_ticks_msec() - t0
		vp.remove_child(inst)
		inst.free()
		t0 = Time.get_ticks_msec()
		if img != null:
			img.save_png(ProjectSettings.globalize_path(
				"%s/%s.png" % [OUT_DIR, str(k)]))
		var t_save := Time.get_ticks_msec() - t0
		print("%-30s %8dms %8dms %8dms  %s"
			% [str(k), t_asm, t_draw, t_save,
			   "%.1f x %.1f x %.1f" % [ab.size.x, ab.size.y, ab.size.z]])
	print("")
	print("written to %s" % ProjectSettings.globalize_path(OUT_DIR))
	quit(0)


# Same rule as highpoly_previews._frame_isometric, copied rather than called so
# the test still runs if that function is mid-edit.
func _frame(cam: Camera3D, ab: AABB) -> void:
	var center := ab.get_center()
	var dir := Vector3(1, 1, 1).normalized()
	var span: float = maxf(ab.size.length(), 0.001)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.position = center + dir * span
	cam.look_at(center)
	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	var hx := 0.0
	var hy := 0.0
	for i in range(8):
		var c := ab.position + Vector3(
			ab.size.x if (i & 1) else 0.0,
			ab.size.y if (i & 2) else 0.0,
			ab.size.z if (i & 4) else 0.0) - center
		hx = maxf(hx, absf(c.dot(right)))
		hy = maxf(hy, absf(c.dot(up)))
	cam.size = maxf(maxf(hx, hy) * 2.0 * 1.06, 0.01)
	cam.near = 0.001
	cam.far = span * 4.0 + 10.0


func _merged_aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is VisualInstance3D:
			var vi := cur as VisualInstance3D
			var a := vi.get_aabb()
			var xf := vi.global_transform
			var w := xf * a
			if first:
				out = w
				first = false
			else:
				out = out.merge(w)
		for c in cur.get_children():
			stack.append(c)
	return out
