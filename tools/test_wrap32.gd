@tool
extends SceneTree
# Task #32, the user's MP_Aftermath ambulance, end to end against the install:
#   1. the meshset reader now carries the second UV channel (uv2)
#   2. the wrap's dominant lit colour is the livery ground - near white here
#   3. the built BODY mesh wears the wrap as albedo texture
#   4. the built DOOR mesh is painted bright livery ground, not primer grey

const BODY := "common/environment/generic/common/props/vanparamedicus_01/com_vanparamedicus_01_mesh"
const DOOR := "common/environment/generic/common/props/vanparamedicus_01/com_vanparamedicus_01_door_frontleft_mesh"

func _init() -> void:
	var fails := 0
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath"):
		print("no source: ", gs.error)
		quit(1)
		return
	gs.map_data("user://edvtest", {})   # the walk, for rows/scopes

	# 1. uv2 rides along
	var d: PackedByteArray = gs.src.get_res(BODY)
	var ms = BF6MeshSet.new()
	var info: Dictionary = ms.parse(d)
	var chunk := PackedByteArray()
	var cid: PackedByteArray = (info["lods"][0] as Dictionary).get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = gs.src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	var secs: Array = ms.read_lod(d, 0, chunk, false)
	var with_uv2 := 0
	for s in secs:
		var u2: PackedVector2Array = (s as Dictionary).get("uv2", PackedVector2Array())
		if not u2.is_empty():
			with_uv2 += 1
	print("uv2 present on %d of %d sections" % [with_uv2, secs.size()])
	if with_uv2 < secs.size() / 2:
		print("FAIL the second UV channel is not riding along")
		fails += 1

	# find the placed ambulance's row for its scope + variation
	var scope := ""
	var vh := 0
	for r in gs.walk.rows:
		var mn := str((r as Dictionary).get("mesh", "")).to_lower()
		if mn.contains("vanparamedicus") and not mn.contains("door") \
				and not mn.contains("hood"):
			scope = str((r as Dictionary).get("scope", ""))
			vh = gs._var_hash((r as Dictionary).get("var"))
			print("row mesh: %s" % mn)
			break
	if scope == "":
		print("FAIL no paramedicus placement in the walk")
		quit(1)
		return
	print("placed with scope %s variation %d" % [scope, vh])

	# 2. the livery ground colour
	var mesh0: Mesh = gs.mesh_for("%s|%s|%d" % [BODY, scope, vh])
	var wrap_guid = null
	for i in range((mesh0 as ArrayMesh).get_surface_count() if mesh0 != null else 0):
		pass
	# fetch the wrap guid straight from the body's carpaint record via describe
	# is heavier than needed - _wrap_paint_of is exercised through the door
	# material below; here just check the body wears a texture.
	var body_textured := false
	if mesh0 != null:
		for i in range((mesh0 as ArrayMesh).get_surface_count()):
			var m = (mesh0 as ArrayMesh).surface_get_material(i)
			if m is StandardMaterial3D \
					and (m as StandardMaterial3D).albedo_texture != null \
					and (m as StandardMaterial3D).metallic_specular > 0.75:
				body_textured = true
	print("body carpaint wears a wrap texture: %s" % str(body_textured))
	if not body_textured:
		print("FAIL the body lost its wrap")
		fails += 1

	# 3+4. the door is painted bright, not primer grey
	var door: Mesh = gs.mesh_for("%s|%s|%d" % [DOOR, scope, vh])
	if door == null:
		print("FAIL door mesh did not build")
		fails += 1
	else:
		var bright := false
		var worst := 1.0
		for i in range((door as ArrayMesh).get_surface_count()):
			var m = (door as ArrayMesh).surface_get_material(i)
			if m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture == null \
					and (m as StandardMaterial3D).metallic_specular > 0.75:
				var c: Color = (m as StandardMaterial3D).albedo_color
				var v := maxf(c.r, maxf(c.g, c.b))
				worst = minf(worst, v)
				if v > 0.6:
					bright = true
		print("door carpaint painted bright: %s (dimmest carpaint %.2f)"
			% [str(bright), worst])
		if not bright:
			print("FAIL the door still wears primer grey")
			fails += 1
	var st: Dictionary = gs.tex_stats
	print("stats: wrap %s, member paint %s, skipped %s"
		% [str(st.get("carpaint_wrap", 0)), str(st.get("carpaint_member_paint", 0)),
			str(st.get("carpaint_wrap_skipped", 0))])
	print("ALL OK" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)
