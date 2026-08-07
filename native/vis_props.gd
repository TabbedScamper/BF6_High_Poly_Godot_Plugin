extends SceneTree

# Render real props from the install and SAVE A PICTURE.
#
# Everything so far is numbers: counts matching Python, 100% of texture guids
# resolving, 40/40 decoding. All of that can be true while the map looks wrong —
# normals inverted, albedo read as linear, UV channel 1 bound where 0 belongs,
# a texture correct but on the wrong slot. None of those move a counter.
#
# So this builds a row of the map's most-placed props, lights them, points a
# camera at them and writes a PNG. Run it WITHOUT --headless: the dummy renderer
# draws nothing and would produce a blank image that looks like a bug in the
# meshes.
#
#   godot --path <proj> --script vis_props.gd -- <out.png> [level] [count]

const BF6Source := preload("res://bf6_source.gd")
const HighpolyGameSource := preload("res://highpoly_gamesource.gd")

const SHOT_SIZE := Vector2i(1600, 900)


func _init() -> void:
	# BEFORE TOUCHING get_root(). _init runs before the tree is usable, so
	# look_at errored with "Node not inside tree" and left the camera at its
	# default orientation — which framed the props as specks along the bottom
	# edge and read as "the meshes are tiny" rather than "the camera never
	# turned". Every other harness here opens with this line for the same reason.
	await process_frame

	var a := OS.get_cmdline_user_args()
	var out_png := "props.png"
	var level := "mp_dumbo"
	var count := 8
	var only := ""
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if s.begins_with("only="):
			# Inspecting one prop is the point of this tool as often as not: a
			# row of six fits the frame by being six times smaller than any of
			# them, which is fine for "did it build" and useless for "does it
			# look right".
			only = s.substr(5).to_lower()
		elif s.is_valid_int():
			count = int(s)
		elif seen == 0:
			out_png = s
			seen = 1
		else:
			level = s

	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data()
	var props: Array = data["props"]
	props.sort_custom(func(x, y):
		return (x as Dictionary)["xf"].size() > (y as Dictionary)["xf"].size())

	var root := Node3D.new()
	get_root().add_child(root)

	# A neutral studio: one key light, one fill, a mid-grey ground. Nothing
	# coloured, so anything coloured in the picture came out of the game.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.18, 0.19, 0.21)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.52, 0.56)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	var key := DirectionalLight3D.new()
	key.light_energy = 2.0
	key.rotation_degrees = Vector3(-45, -35, 0)
	key.shadow_enabled = true
	root.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.5
	fill.rotation_degrees = Vector3(-20, 140, 0)
	root.add_child(fill)

	# Placed in a row, each scaled to a common height and sitting on y=0, so one
	# 40 m prop cannot push everything else into the distance.
	var built := 0
	var x := 0.0
	var placed: Array = []
	var placed_keys: Array = []
	var world_box := AABB()
	for p in props:
		if built >= count:
			break
		var gkey := str((p as Dictionary)["mesh"])
		if only != "" and not gkey.to_lower().contains(only):
			continue
		var m: Mesh = gs.mesh_for(gkey)
		if m == null:
			continue
		var aabb := m.get_aabb()
		var longest: float = maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z)
		if longest <= 0.001 or longest > 500.0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		var s := 2.0 / longest
		mi.scale = Vector3(s, s, s)
		mi.position = Vector3(x, -aabb.position.y * s, 0)
		root.add_child(mi)
		var wb := AABB(mi.position + aabb.position * s, aabb.size * s)
		world_box = wb if built == 0 else world_box.merge(wb)
		# The group key is "<mesh res>|<scope>", so get_file() on the whole thing
		# returns the SCOPE's leaf — the first run listed eight props as
		# "sub_art_10_oob, world, sub_art_00_global…", which are subworlds.
		placed.append(str(gkey).split("|")[0].get_file())
		placed_keys.append(gkey)
		x += 2.6
		built += 1
	if built == 0:
		print("FAIL nothing built")
		quit(1); return

	var cam := Camera3D.new()
	var centre := (x - 2.6) * 0.5
	# ADDED TO THE TREE BEFORE look_at. Node3D.look_at needs a global transform
	# and errors out on a node that has none — the first run left the camera at
	# its default orientation, which framed the props as specks in the distance
	# and looked like the meshes were tiny rather than the camera being wrong.
	root.add_child(cam)
	# FRAMED FROM THE ACTUAL BOUNDS, not from a guess at the row's length.
	# Hand-tuned offsets put the props in a corner twice; the bounding box knows
	# where they are. Three-quarter view because a dead-on elevation shows flat
	# props — curbs, window panels — edge-on as a line, which looks exactly like
	# a mesh that failed to build.
	var span := world_box.size
	var radius: float = maxf(0.5, maxf(maxf(span.x, span.y), span.z) * 0.5)
	var mid := world_box.get_center()
	var fov := deg_to_rad(cam.fov)
	var dist: float = radius / maxf(0.05, tan(fov * 0.5)) * 1.25
	cam.position = mid + Vector3(0.45, 0.42, 1.0).normalized() * dist
	cam.look_at(mid, Vector3.UP)
	cam.current = true

	print("built %d props: %s" % [built, ", ".join(placed)])
	print("textures: %s" % gs.tex_stats)

	# WHICH SLOTS EACH SURFACE GOT. The first render came back mostly white with
	# 13 materials over 8 props, and "white" has two very different causes: no
	# material at all, or a material whose albedo slot never resolved and is
	# showing StandardMaterial3D's default. The counts cannot tell them apart.
	print("\nper prop:")
	for gk in placed_keys:
		var m2: Mesh = gs.mesh_for(str(gk))
		if m2 == null:
			continue
		var with_mat := 0
		var with_albedo := 0
		for si in range(m2.get_surface_count()):
			var mm = m2.surface_get_material(si)
			if mm == null:
				continue
			with_mat += 1
			if mm is BaseMaterial3D and (mm as BaseMaterial3D).albedo_texture != null:
				with_albedo += 1
		print("   %-46s %d surfaces, %d with a material, %d with albedo"
			% [str(gk).split("|")[0].get_file().left(46), m2.get_surface_count(),
			   with_mat, with_albedo])

	# Several frames: the first has nothing uploaded yet, and a screenshot of it
	# is a black rectangle that reads as "the meshes are broken".
	for i in range(12):
		await process_frame
	var img := get_root().get_texture().get_image()
	if img == null:
		print("FAIL no viewport image — was this run with --headless?")
		quit(1); return
	var err := img.save_png(out_png)
	print("%s %s (%dx%d)" % ["wrote" if err == OK else "FAILED to write",
		out_png, img.get_width(), img.get_height()])
	quit(0 if err == OK else 1)
