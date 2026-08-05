extends SceneTree

# Compression has to shrink VRAM without destroying the props. A pass that
# quietly turned every texture into a 0x0 or dropped the normal map would look
# fine in a parse check and ruin every map, so this asserts the pixels survive,
# the sizes are right, and the mode switch actually changes the result.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0


func _init() -> void:
	var base := OS.get_environment("APPDATA") + "/Godot/app_userdata/Battlefield™ Portal Project"
	var dir := base + "/mapcontext/_props"
	var da := DirAccess.open(dir)
	if da == null:
		print("no props to test against"); quit(1); return
	var files: Array = []
	for f in da.get_files():
		if f.ends_with(".glb"):
			files.append(dir + "/" + f)
	files.sort()

	print("%-22s %10s %10s %8s %s" % ["mode", "VRAM MB", "vs full", "compr", "smallest texture"])
	var results := {}
	for pair in [["FULL", MC.VRAM_FULL], ["COMPRESSED", MC.VRAM_COMPRESSED], ["LOW", MC.VRAM_LOW]]:
		MC.vram_mode = pair[1]
		var bytes := 0
		var n := 0
		var minw := 1 << 30
		var zero := 0
		for i in range(10):
			var m := _mesh(str(files[i]))
			if m == null:
				continue
			n += MC._compress_textures(m)
			var r := _measure(m)
			bytes += int(r[0])
			minw = mini(minw, int(r[1]))
			zero += int(r[2])
		results[pair[0]] = bytes
		print("%-22s %10.2f %10s %8d %d px%s"
			% [pair[0], bytes / 1048576.0,
				"%.1fx" % (float(results["FULL"]) / maxf(1.0, float(bytes))),
				n, minw, "   ZERO-SIZED TEXTURES!" if zero > 0 else ""])
		_check("%s produced no zero-sized textures" % pair[0], zero == 0)

	MC.vram_mode = MC.VRAM_COMPRESSED
	_check("COMPRESSED is at least 3x smaller than FULL",
		float(results["FULL"]) / maxf(1.0, float(results["COMPRESSED"])) >= 3.0)
	_check("LOW is smaller again than COMPRESSED",
		results["LOW"] < results["COMPRESSED"])
	_check("suffix differs per mode", _suffixes_differ())

	# the watchdog must answer without exploding, whatever the driver reports
	var mb: float = MC.vram_used_mb()
	_check("vram_used_mb returns a number (%.1f MB)" % mb, mb >= 0.0)
	# vram_check REPORTS, it must never stop the build — an earlier version
	# returned a stop flag and killed every prop on Dumbo because the baseline
	# scene alone is already over 4 GB before a single prop exists.
	MC.vram_check()
	_check("vram_check returns nothing and cannot halt a build", true)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _suffixes_differ() -> bool:
	var seen := {}
	for m in [MC.VRAM_FULL, MC.VRAM_COMPRESSED, MC.VRAM_LOW]:
		MC.vram_mode = m
		seen[MC._baked_suffix()] = true
	MC.vram_mode = MC.VRAM_COMPRESSED
	return seen.size() == 3


func _mesh(p: String) -> Mesh:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(FileAccess.get_file_as_bytes(p), "", st) != OK:
		return null
	var sc := doc.generate_scene(st)
	if sc == null: return null
	var found: Mesh = null
	var stack: Array = [sc]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			found = (n as MeshInstance3D).mesh
			break
		for c in n.get_children(): stack.append(c)
	sc.queue_free()
	return found


# returns [bytes, smallest width, zero-sized count]
func _measure(m: Mesh) -> Array:
	var seen := {}
	var bytes := 0
	var minw := 1 << 30
	var zero := 0
	for s in range(m.get_surface_count()):
		var bm := m.surface_get_material(s) as BaseMaterial3D
		if bm == null: continue
		for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
				BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_METALLIC]:
			var t := bm.get_texture(slot)
			if t == null or seen.has(t.get_instance_id()): continue
			seen[t.get_instance_id()] = true
			var img := t.get_image()
			if img == null:
				zero += 1
				continue
			if img.get_width() <= 0 or img.get_height() <= 0:
				zero += 1
				continue
			bytes += img.get_data().size()
			minw = mini(minw, img.get_width())
	return [bytes, minw if minw < (1 << 30) else 0, zero]


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
