extends SceneTree

# How much of the map is alpha-tested, and how much of that is a placeholder?
#
# Foliage is the visible symptom, but the alpha slot is not a vegetation slot:
# fences, grates, chain link, railings and decals bind it too, and every one of
# them is currently drawn as a solid sheet. Before writing a foliage shader it
# is worth knowing whether this is a foliage fix or a map-wide one.
#
# The placeholder matters as much as the real ones. Street lamps bind the alpha
# slot to `t_debug_r` — 64x64, constant 255 — which is a default, not a mask.
# Treating those as transparent would put an alpha-blended shader (and its sort
# cost, and its scissor) on hundreds of fully opaque props for nothing.
#
#   godot --headless --path <proj> --script test_alphascope.gd -- [level] [max meshes]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var cap := 900
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			cap = int(s)

	var gs = HighpolyGameSource.new()
	gs.build_materials = false
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data("")

	var keys: Array = []
	var uniq := {}
	for g in data.get("props", []):
		var k := str((g as Dictionary)["mesh"])
		var res_only := k.split("|")[0]
		if not uniq.has(res_only):
			uniq[res_only] = true
			keys.append(k)
	keys.sort()
	if cap > 0 and keys.size() > cap:
		keys = keys.slice(0, cap)
	print("scanning %d distinct meshes" % keys.size())

	var n_mesh := 0
	var n_sec := 0
	var sec_alpha := 0
	var sec_veg := 0
	var mesh_alpha := {}
	var mesh_veg := {}
	# alpha texture asset name -> times bound. The placeholder shows up here as
	# one name with a very large count.
	var alpha_tex := {}
	var name_to_guid := {}
	var t0 := Time.get_ticks_msec()
	for key in keys:
		var parts: PackedStringArray = key.split("|")
		var res_name := str(parts[0])
		var scope := str(parts[1]) if parts.size() > 1 else ""
		var pair = gs._depot_for(scope)
		if pair == null:
			continue
		var sks := _state_keys(gs, res_name)
		if sks.is_empty():
			continue
		n_mesh += 1
		for k in sks:
			var ik := int(k)
			if ik == 0 or not (pair[0] as BF6Depot).key_to_record.has(ik):
				continue
			n_sec += 1
			var slots: Dictionary = (pair[0] as BF6Depot).textures_for(ik, pair[1])
			if slots.has("basecolor_veg"):
				sec_veg += 1
				mesh_veg[res_name] = true
			if slots.has("alpha"):
				sec_alpha += 1
				mesh_alpha[res_name] = true
				var nm := _asset_of(gs, str(slots["alpha"]))
				alpha_tex[nm] = int(alpha_tex.get(nm, 0)) + 1
				name_to_guid[nm] = str(slots["alpha"])

	print("scanned in %.1f s\n" % ((Time.get_ticks_msec() - t0) / 1000.0))
	print("meshes with a depot         %d" % n_mesh)
	print("sections                    %d" % n_sec)
	print("   bind an alpha slot       %d (%.1f%%) across %d meshes"
		% [sec_alpha, 100.0 * sec_alpha / maxi(n_sec, 1), mesh_alpha.size()])
	print("   bind the vegetation set  %d (%.1f%%) across %d meshes"
		% [sec_veg, 100.0 * sec_veg / maxi(n_sec, 1), mesh_veg.size()])

	# Which alpha textures, most-bound first, WITH the shape of their R channel.
	#
	# dfanz0r's rule is that alpha is only honoured when it looks like a cutout —
	# a mostly-opaque sheet with a meaningful fully-transparent fraction — because
	# wear and blend masks also live in this slot and scissoring one punches holes
	# in a solid surface. That is a threshold on a distribution, so the
	# distribution is what gets printed: `clear` is the fraction below 0.1 and
	# `opaque` the fraction above 0.9. Thresholds are chosen from this table, not
	# guessed and then defended.
	var rows: Array = []
	for nm in alpha_tex:
		rows.append([int(alpha_tex[nm]), str(nm)])
	rows.sort_custom(func(x, y): return int(x[0]) > int(y[0]))
	print("\nalpha textures bound, most used first, with the shape of R:")
	print("   %5s  %-46s %7s %7s  %s" % ["binds", "texture", "clear", "opaque", "verdict"])
	var placeholder := 0
	var cutouts := 0
	var cutout_binds := 0
	for i in range(mini(28, rows.size())):
		var nm: String = rows[i][1]
		var st := _shape(gs, str(name_to_guid.get(nm, "")))
		var verdict := "?"
		if st.has("clear"):
			var clear: float = st["clear"]
			var op: float = st["opaque"]
			if clear < HighpolyGameSource.CUTOUT_MIN_CLEAR:
				verdict = "placeholder (never clear)"
				placeholder += int(rows[i][0])
			elif clear > HighpolyGameSource.CUTOUT_MAX_CLEAR:
				verdict = "placeholder (ALL clear)"
				placeholder += int(rows[i][0])
			else:
				verdict = "CUTOUT"
				cutouts += 1
				cutout_binds += int(rows[i][0])
			print("   %5d  %-46s %6.1f%% %6.1f%%  %s"
				% [rows[i][0], nm.substr(0, 46), clear * 100.0, op * 100.0, verdict])
		else:
			print("   %5d  %-46s %7s %7s  %s"
				% [rows[i][0], nm.substr(0, 46), "-", "-", "unreadable"])
	print("\n%d distinct alpha textures; %d look like cutouts, carrying %d of %d bindings"
		% [rows.size(), cutouts, cutout_binds, sec_alpha])
	quit(0)


# The shape of a mask's R channel: what fraction is fully clear, what fraction
# is fully opaque. A cutout has a real population at both ends; a wear or blend
# mask sits in the middle and has almost nothing at zero.
func _shape(gs, file_guid: String) -> Dictionary:
	if file_guid == "":
		return {}
	var tex = gs._texture_for(file_guid)
	if tex == null:
		return {}
	var img: Image = (tex as ImageTexture).get_image()
	if img == null:
		return {}
	# THE READER'S OWN TEST, not a second copy of it. A probe that measures one
	# thing while the code decides on another is how a table gets quoted in a
	# commit message for behaviour that never shipped.
	return HighpolyGameSource.mask_shape(img)


func _asset_of(gs, file_guid: String) -> String:
	var asset = gs.walk.gi.get(file_guid)
	if asset == null:
		return "(unresolved %s)" % file_guid.substr(0, 8)
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	return an.get_file()


func _state_keys(gs, res_name: String) -> Array:
	var d: PackedByteArray = gs.src.get_res(res_name)
	if d.is_empty():
		return []
	var ms := BF6MeshSet.new()
	var info := ms.parse(d)
	if info.is_empty():
		return []
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return []
	var chunk := PackedByteArray()
	var cid: PackedByteArray = (lods[0] as Dictionary).get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = gs.src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	var secs = ms.read_lod(d, 0, chunk, false)
	var out: Array = []
	if secs is Array:
		for s in secs:
			out.append(int((s as Dictionary).get("state_key", 0)))
	return out
