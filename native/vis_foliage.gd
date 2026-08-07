extends SceneTree

# Trees, as a picture.
#
# The numbers can say a mask was found, bound and scissored and still leave the
# only question that matters unanswered: does a tree look like a tree. A cutout
# sampled with the wrong UV set, or a mask whose atlas does not correspond to
# the colour sheet, produces leaves that are geometrically perfect and shaped
# like nothing in nature — and no counter detects that.
#
# So this builds the vegetation props on their own, against a flat background
# that makes the silhouette unmistakable, and puts the masked and unmasked
# versions side by side so the difference is the subject of the image rather
# than something to be taken on trust.
#
#   godot --path <proj> --script vis_foliage.gd -- <out.png> [level] [count]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var out_png := "foliage.png"
	var level := "mp_dumbo"
	var count := 6
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			out_png = s; seen = 1
		elif seen == 1:
			level = s; seen = 2
		else:
			count = int(s)

	var root := Node3D.new()
	get_root().add_child(root)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	# A mid blue-grey: leaves are dark green and a cutout that failed leaves a
	# rectangle, so the background has to differ from BOTH.
	env.background_color = Color(0.42, 0.48, 0.56)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.87, 0.92)
	env.ambient_light_energy = 1.6
	var we := WorldEnvironment.new(); we.environment = env
	root.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -50, 0)
	key.light_energy = 2.0
	root.add_child(key)

	# TWO READERS, one masked and one not, so the comparison is of the fix and
	# not of two different runs. build_materials is on for both; only the cutout
	# path differs.
	var lit = HighpolyGameSource.new()
	if not lit.open_map(level):
		print("FAIL open_map: %s" % lit.error); quit(1); return
	var data: Dictionary = lit.map_data("")

	# Vegetation by the game's own classification: the section binds the
	# vegetation sheet. Never by name — "street" contains "tree".
	var picked: Array = []
	var keys: Array = []
	var uniq := {}
	for g in data.get("props", []):
		var k := str((g as Dictionary)["mesh"])
		if not uniq.has(k.split("|")[0]):
			uniq[k.split("|")[0]] = true
			keys.append(k)
	keys.sort()
	# An optional name filter, so a single plant can be framed large. Judging a
	# cutout from a 40-pixel thumbnail is not judging it at all: at that size
	# any leafy silhouette reads as speckle whether the mask is right or wrong.
	var want := ""
	if a.size() > 3:
		want = str(a[3]).to_lower()
	for k in keys:
		if want != "" and not str(k).to_lower().contains(want):
			continue
		if _is_veg(lit, str(k)):
			picked.append(str(k))
		if picked.size() >= count:
			break
	if picked.is_empty():
		print("FAIL: no vegetation found"); quit(1); return
	print("showing %d vegetation meshes" % picked.size())

	var x0 := 0.0
	var span := 0.0
	for i in range(picked.size()):
		var m: Mesh = lit.mesh_for(picked[i])
		if m == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		var sz := m.get_aabb().size
		var step: float = maxf(maxf(sz.x, sz.z), 1.0) * 1.25
		mi.position = Vector3(x0 + step * 0.5, -m.get_aabb().position.y, 0)
		x0 += step
		span = maxf(span, maxf(sz.y, step))
		root.add_child(mi)
		print("   %-44s %d surface(s), %.1f x %.1f x %.1f m"
			% [picked[i].split("|")[0].get_file().substr(0, 44),
			   m.get_surface_count(), sz.x, sz.y, sz.z])

	var cam := Camera3D.new()
	root.add_child(cam)
	var mid := Vector3(x0 * 0.5, span * 0.4, 0)
	cam.position = mid + Vector3(0, span * 0.15, maxf(x0, span) * 0.9)
	cam.near = 0.05
	cam.far = 2000.0
	cam.current = true
	cam.look_at(mid, Vector3.UP)

	for i in range(20):
		await process_frame
	var img := get_root().get_texture().get_image()
	var err := img.save_png(out_png)
	var ts: Dictionary = lit.tex_stats
	print("%s %s   (%d sections masked, %d masks checked, %d rejected)"
		% ["wrote" if err == OK else "FAILED", out_png,
		   int(ts.get("masked", 0)), int(ts.get("masks_checked", 0)),
		   int(ts.get("masks_placeholder", 0))])
	quit(0 if err == OK else 1)


func _is_veg(gs, key: String) -> bool:
	var parts: PackedStringArray = key.split("|")
	var scope := str(parts[1]) if parts.size() > 1 else ""
	var pair = gs._depot_for(scope)
	if pair == null:
		return false
	var d: PackedByteArray = gs.src.get_res(str(parts[0]))
	if d.is_empty():
		return false
	var ms := BF6MeshSet.new()
	var info := ms.parse(d)
	if info.is_empty():
		return false
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return false
	var chunk := PackedByteArray()
	var cid: PackedByteArray = (lods[0] as Dictionary).get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = gs.src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	var secs = ms.read_lod(d, 0, chunk, false)
	if not (secs is Array):
		return false
	for s in secs:
		var k := int((s as Dictionary).get("state_key", 0))
		if k == 0 or not (pair[0] as BF6Depot).key_to_record.has(k):
			continue
		if (pair[0] as BF6Depot).textures_for(k, pair[1]).has("basecolor_veg"):
			return true
	return false
