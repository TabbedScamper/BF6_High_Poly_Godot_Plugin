extends SceneTree

# Can the skyline's surfaces be merged, or are they all different materials?
#
# The census says the Backdrop layer carries 49,966 surfaces across 289
# instances — roughly 173 each — and a draw call is issued per surface, so the
# skyline IS the frame. Merging surfaces that share a material would collapse
# that with no visual change at all.
#
# Whether that is worth building depends entirely on a number nobody has
# looked at: how many DISTINCT materials each piece actually uses. If every
# surface has its own, merging buys nothing and the answer is elsewhere.
#
#   godot --headless --path <proj> --script probe_backdrop.gd -- <backdrop dir>

func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var dir := str(a[0]) if a.size() > 0 else ""
	var files := _glbs(dir)
	if files.is_empty():
		print("no .glb under %s" % dir); quit(1); return
	print("%d backdrop mesh(es) in %s\n" % [files.size(), dir])

	var tot_surf := 0
	var tot_mat := 0
	var tot_named := 0
	var shown := 0
	for f in files:
		var r := _inspect(f)
		if r.is_empty():
			continue
		tot_surf += int(r["surfaces"])
		tot_mat += int(r["materials"])
		tot_named += int(r["named"])
		if shown < 12:
			print("  %-56s %4d surfaces  %4d distinct materials  %4d by name"
					% [f.get_file().left(56), int(r["surfaces"]),
					   int(r["materials"]), int(r["named"])])
			shown += 1

	print("\ntotal   %d surfaces, %d distinct material objects, %d distinct names"
			% [tot_surf, tot_mat, tot_named])
	if tot_surf > 0:
		print("merging by material object would leave %.1f%% of the draw calls"
				% (100.0 * float(tot_mat) / float(tot_surf)))
		print("merging by material NAME would leave    %.1f%%"
				% (100.0 * float(tot_named) / float(tot_surf)))
	quit(0)


func _inspect(path: String) -> Dictionary:
	var b := FileAccess.get_file_as_bytes(path)
	if b.is_empty():
		return {}
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(b, path.get_base_dir(), st) != OK:
		return {}
	var surfaces := 0
	var mats := {}
	var names := {}
	for gm in st.get_meshes():
		var src: ImporterMesh = gm.get_mesh()
		if src == null:
			continue
		for s in range(src.get_surface_count()):
			surfaces += 1
			var m := src.get_surface_material(s)
			if m == null:
				continue
			mats[m.get_instance_id()] = true
			# BY CONTENT, not by identity or name. glTF hands back a separate
			# Material OBJECT per surface and names them uniquely, so both of
			# those answer "all different" about materials that may be pixel
			# for pixel the same — which is exactly the wrong answer for a
			# question about whether they can be merged.
			names[_signature(m)] = true
	return {"surfaces": surfaces, "materials": mats.size(),
			"named": names.size()}


# What a material actually LOOKS like, as a comparable string.
#
# Two surfaces can share a draw call only if the renderer would bind the same
# state for both, so the signature is the things that decide that: the textures
# bound, the base colour, and the flags that change the shader.
func _signature(m: Material) -> String:
	if not (m is BaseMaterial3D):
		return "shader:%d" % m.get_instance_id()
	var b := m as BaseMaterial3D
	var parts := PackedStringArray()
	for slot in [BaseMaterial3D.TEXTURE_ALBEDO,
				 BaseMaterial3D.TEXTURE_NORMAL,
				 BaseMaterial3D.TEXTURE_ROUGHNESS,
				 BaseMaterial3D.TEXTURE_METALLIC,
				 BaseMaterial3D.TEXTURE_EMISSION]:
		var t := b.get_texture(slot)
		# BY IMAGE CONTENT, not by RID. Two Texture2D objects wrapping the SAME
		# image are different objects with different RIDs, so keying on the RID
		# answers "all 49,966 are distinct" about a skyline that may be using a
		# handful of atlases — which is the difference between "merging is
		# impossible" and "merging is most of the frame".
		if t == null:
			parts.append("-")
		else:
			var img := t.get_image()
			if img == null:
				parts.append("rid:%s" % t.get_rid())
			else:
				parts.append("%dx%d:%d:%s" % [img.get_width(), img.get_height(),
						img.get_format(),
						img.get_data().slice(0, 4096).hex_encode().md5_text()])
	parts.append("%.3f,%.3f,%.3f,%.3f" % [b.albedo_color.r, b.albedo_color.g,
			b.albedo_color.b, b.albedo_color.a])
	parts.append("%d,%d,%d" % [b.transparency, b.cull_mode, b.shading_mode])
	return "|".join(parts)


func _glbs(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir():
			if not f.begins_with("."):
				out.append_array(_glbs(dir.path_join(f)))
		elif f.ends_with(".glb"):
			out.append(dir.path_join(f))
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out
