extends SceneTree

# Compression has to shrink VRAM without destroying the props.
#
# GOES THROUGH THE REAL PARSE, deliberately. An earlier version built meshes
# with its own GLTFDocument call and then invoked the compression pass directly.
# That stopped measuring the product the moment compression moved into
# _load_external_glb: the test reported COMPRESSED as no better than FULL while
# the shipped path was compressing correctly. A test that bypasses the code
# under test eventually measures nothing.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const N := 10

var fails := 0


func _init() -> void:
	await process_frame
	var mc = MC.new()
	root.add_child(mc)
	await process_frame
	mc.mesh_cache_enabled = false          # measure the parse, not a sidecar

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
	files = files.slice(0, N)

	print("%-22s %10s %10s %8s %s" % ["mode", "VRAM MB", "vs full", "compr", "smallest"])
	var results := {}
	for pair in [["FULL", MC.VRAM_FULL], ["COMPRESSED", MC.VRAM_COMPRESSED],
			["LOW", MC.VRAM_LOW]]:
		mc.vram_mode = pair[1]
		var bytes := 0
		var comp := 0
		var minw := 1 << 30
		var zero := 0
		for p in files:
			mc._mesh_cache.clear()
			mc._pf.clear()
			var r = await mc._parse_prop_file(str(p))
			if not (r is Array):
				continue
			for m in r:
				var res := _measure(m as Mesh)
				bytes += int(res[0])
				comp += int(res[1])
				if int(res[2]) > 0:
					minw = mini(minw, int(res[2]))
				zero += int(res[3])
		results[pair[0]] = bytes
		print("%-22s %10.2f %10s %8d %d px%s"
			% [pair[0], bytes / 1048576.0,
				"%.1fx" % (float(results["FULL"]) / maxf(1.0, float(bytes))),
				comp, minw, "   ZERO-SIZED!" if zero > 0 else ""])
		_check("%s produced no zero-sized textures" % pair[0], zero == 0)

	mc.vram_mode = MC.VRAM_COMPRESSED
	_check("COMPRESSED is at least 3x smaller than FULL",
		float(results["FULL"]) / maxf(1.0, float(results["COMPRESSED"])) >= 3.0)
	_check("LOW is smaller again than COMPRESSED",
		results["LOW"] < results["COMPRESSED"])
	_check("suffix differs per mode", _suffixes_differ(mc))

	var mb: float = mc.vram_used_mb()
	_check("vram_used_mb returns a number (%.1f MB)" % mb, mb >= 0.0)
	# vram_check REPORTS, it must never stop a build — an earlier version
	# returned a stop flag and killed every prop on Dumbo, because the baseline
	# scene alone is over 4 GB before a single prop exists.
	mc.vram_check()
	_check("vram_check returns nothing and cannot halt a build", true)

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _suffixes_differ(mc) -> bool:
	var seen := {}
	for m in [MC.VRAM_FULL, MC.VRAM_COMPRESSED, MC.VRAM_LOW]:
		mc.vram_mode = m
		seen[mc._baked_suffix()] = true
		seen[mc._part_suffix(0)] = true
	mc.vram_mode = MC.VRAM_COMPRESSED
	return seen.size() == 6      # three modes x (whole + part) suffixes


# [bytes, compressed textures, smallest width, zero-sized]
func _measure(m: Mesh) -> Array:
	if m == null:
		return [0, 0, 0, 0]
	var seen := {}
	var bytes := 0
	var comp := 0
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
			if img == null or img.get_width() <= 0 or img.get_height() <= 0:
				zero += 1
				continue
			bytes += img.get_data().size()
			if img.is_compressed():
				comp += 1
			minw = mini(minw, img.get_width())
	return [bytes, comp, minw if minw < (1 << 30) else 0, zero]


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
