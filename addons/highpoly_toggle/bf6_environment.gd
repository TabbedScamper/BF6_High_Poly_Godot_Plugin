@tool
extends RefCounted
class_name BF6Environment

# One native context, selected level only. Binary arrays remain binary across
# the extension boundary; metadata is versioned JSON produced in memory.
var core: Object
var level: String
var error := ""
var ground: Dictionary = {}
var terrain: Dictionary = {}
var water_height: Dictionary = {}
var water: Dictionary = {}
var mask: Dictionary = {}
var textures: Dictionary = {}
# Where prepared ground answers may be kept, and the install recipe they belong
# to. Both are set by the caller that knows the map's cache folder; empty means
# no cache, which is the old behaviour exactly.
var cache_dir := ""
var cache_key := ""
var _mutex := Mutex.new()

# WHY THE PACKET AND NOT THE PARSED RESULT. What comes back from the core is a
# JSON header followed by binary blocks, and unpack() is a few milliseconds of
# slicing. Keeping the packet means the cache stores exactly what the core
# produced, with no object serialisation and nothing to keep in step with the
# protocol - a packet from a version we no longer understand simply fails the
# same version check a live one would.
func _packet_path(kind: String, detail: int) -> String:
	if cache_dir.is_empty() or cache_key.is_empty() or level.is_empty():
		return ""
	var safe := kind.replace(":", "_").replace("/", "_").replace("\\", "_")
	if safe.is_empty() or safe.contains(".."):
		return ""
	return "%s/env/%s/%s_%d.pkt" % [cache_dir, cache_key, safe, detail]


# ONE KEY'S WORTH OF CACHE, NEVER FIFTEEN.
#
# The key covers the game AND the add-on's own recipe, so every plugin update
# mints a new one - and the old folder, about 390 MB per map, was simply left
# behind. On this machine that reached 5.8 GB for a single map across 15 keys in
# one afternoon of editing, and it would have done the same on every user's disk
# on every update. The current key is the only one that can be served, so the
# others are deleted the first time this key writes anything.
#
# Deletes only inside this map's own env folder, and only entries that look like
# a key (64 hex characters): anything else there is not ours to remove.
func _drop_other_keys(keep_dir: String) -> void:
	var root := keep_dir.get_base_dir()
	var keep := keep_dir.get_file()
	var dir := DirAccess.open(root)
	if dir == null:
		return
	var hex := RegEx.new()
	hex.compile("^[0-9a-f]{64}$")
	for name in dir.get_directories():
		if name == keep or hex.search(name) == null:
			continue
		var doomed := root.path_join(name)
		var inner := DirAccess.open(doomed)
		if inner == null:
			continue
		for f in inner.get_files():
			DirAccess.remove_absolute(doomed.path_join(f))
		DirAccess.remove_absolute(doomed)


func cached_request(kind: String, detail := 0) -> Dictionary:
	var path := _packet_path(kind, detail)
	if path.is_empty():
		return request(kind, detail)
	if FileAccess.file_exists(path):
		var kept := FileAccess.get_file_as_bytes(path)
		var parsed := unpack(kept)
		if bool(parsed.get("ok", 0)):
			return parsed
	_mutex.lock()
	var packet: PackedByteArray = core.call("environment", level, kind, detail) if core != null and core.has_method("environment") else PackedByteArray()
	var result := unpack(packet)
	_mutex.unlock()
	if not bool(result.get("ok", 0)):
		error = str(result.get("error", "Environment read failed"))
		return {}
	# Written to a temporary name and moved, so a cancelled or crashed run can
	# never leave a half-written packet that reads as a valid short one.
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_drop_other_keys(path.get_base_dir())
	var staged := "%s.%d.part" % [path, OS.get_process_id()]
	var file := FileAccess.open(staged, FileAccess.WRITE)
	if file != null:
		file.store_buffer(packet)
		file.close()
		if DirAccess.rename_absolute(staged, path) != OK:
			DirAccess.remove_absolute(staged)
	return result

func _init(native_core: Object = null, selected_level := "") -> void:
	core = native_core
	level = selected_level

static func unpack(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 4: return {"ok": 0, "error": "short environment packet"}
	var count := bytes.decode_u32(0)
	if count > bytes.size() - 4: return {"ok": 0, "error": "truncated environment metadata"}
	var parsed: Variant = JSON.parse_string(bytes.slice(4, 4 + count).get_string_from_utf8())
	if not parsed is Dictionary: return {"ok": 0, "error": "invalid environment metadata"}
	var result: Dictionary = parsed
	if int(result.get("version", 0)) != 1: return {"ok": 0, "error": "unsupported environment protocol"}
	var start := 4 + count
	for key in result.keys():
		var field: Variant = result[key]
		if field is Dictionary and field.has("offset") and field.has("bytes"):
			var offset := int(field.offset)
			var size := int(field.bytes)
			if offset < 0 or size < 0 or offset > bytes.size() - start or size > bytes.size() - start - offset:
				return {"ok": 0, "error": "environment block exceeds packet"}
			result[key] = bytes.slice(start + offset, start + offset + size)
	return result

func request(kind: String, detail := 0) -> Dictionary:
	if core == null or not core.has_method("environment"):
		error = "Native environment binding is unavailable"
		return {}
	_mutex.lock()
	var packet: PackedByteArray = core.call("environment", level, kind, detail)
	var result := unpack(packet)
	_mutex.unlock()
	if not bool(result.get("ok", 0)):
		error = str(result.get("error", "Environment read failed"))
		push_warning("High Poly %s: %s" % [kind, error])
		return {}
	return result

func read_terrain() -> Dictionary:
	if terrain.is_empty() or (bool(terrain.get("present", false)) and not terrain.has("heights")):
		terrain = request("terrain")
	return terrain

func read_water() -> Dictionary:
	if not water.is_empty(): return water
	water = request("water")
	if water.is_empty(): return {}
	water_height = request("water_height", 2048)
	mask = request("water_mask")
	for surface in water.get("surfaces", []):
		for name in ["detail_normal", "foam_normal", "foam_rgb", "noise", "perlin", "contact_foam", "foam_rgb2"]:
			var id := int(surface.get(name, -1))
			if id >= 0 and not textures.has(id):
				var item := request("texture", id)
				if not item.is_empty(): textures[id] = texture_image(item)
	return water

static func texture_image(item: Dictionary) -> Image:
	const FORMATS := {0: Image.FORMAT_RGBA8, 1: Image.FORMAT_DXT1, 2: Image.FORMAT_DXT5,
		3: Image.FORMAT_RGTC_R, 4: Image.FORMAT_RGTC_RG, 5: Image.FORMAT_BPTC_RGBA,
		6: Image.FORMAT_BPTC_RGBFU, 7: Image.FORMAT_BPTC_RGBF, 8: Image.FORMAT_R8, 9: Image.FORMAT_RGBAH}
	var format := int(item.get("format", -1))
	if not FORMATS.has(format): return null
	return Image.create_from_data(int(item.width), int(item.height), int(item.get("mip_count", 1)) > 1,
		FORMATS[format], item.pixels)

func prepare_ground(progress := Callable(), size := 4096, sheet_size := 512) -> bool:
	if not ground.is_empty(): return true
	if progress.is_valid(): progress.call("Reading native terrain materials", 0, 1)
	# TIMED IN THREE PARTS, because they have three different answers: the
	# ground record, the per-layer sheets (a handful of textures asked for over
	# and over), and the distant ground. This whole function was reported as one
	# 18.4 s line of a 48 s cached build with no breakdown at all.
	var _t_record := Time.get_ticks_msec()
	var data := cached_request("ground", size)
	_t_record = Time.get_ticks_msec() - _t_record
	# CLOSE THE STAGE YOU OPENED. The panel's lanes clear only when a stage
	# reports done == total; every stage here opened one and none of them ever
	# finished it, so the bar sat on the last label ("Reading distant terrain")
	# for the rest of the session with nothing running behind it. It went
	# unnoticed while the ground took 15 s and the next job painted over it;
	# with the ground cached at 0.3 s there is nothing after it to hide it.
	if progress.is_valid(): progress.call("Reading native terrain materials", 1, 1)
	if data.is_empty(): return false
	var _t_sheets := Time.get_ticks_msec()
	var _n_decoded := 0
	var layers: Array = data.materials
	var albedo: Array[Image] = []
	var normals: Array[Image] = []
	var masks: Array[Image] = []
	# A sheet can be referenced by several layers. Decode/resample it once for
	# this preparation and share the immutable image, including its mip chain.
	var sheets: Dictionary = {}
	for i in range(layers.size()):
		if progress.is_valid(): progress.call("Reading ground material sheets", i, layers.size())
		var row: Dictionary = layers[i]
		for entry in [["albedo_res", albedo, Color(0.5, 0.5, 0.5, 1)],
			["normal_res", normals, Color(0.5, 0.5, 0.5, 1)],
			["coverage_res", masks, Color.WHITE]]:
			var image: Image = null
			var name := str(row.get(entry[0], ""))
			if not name.is_empty():
				if sheets.has(name):
					image = sheets[name]
				else:
					var sheet := cached_request("sheet:" + name, sheet_size)
					if not sheet.is_empty():
						image = texture_image(sheet)
						if image != null:
							image.generate_mipmaps()
							sheets[name] = image
							_n_decoded += 1
			if image == null:
				image = Image.create(sheet_size, sheet_size, false, Image.FORMAT_RGBA8)
				image.fill(entry[2])
			if not image.has_mipmaps(): image.generate_mipmaps()
			entry[1].append(image)
	data["albedo_images"] = albedo
	data["normal_images"] = normals
	data["mask_images"] = masks
	_t_sheets = Time.get_ticks_msec() - _t_sheets
	if progress.is_valid():
		progress.call("Reading ground material sheets", layers.size(), layers.size())
		progress.call("Reading distant terrain", 0, 1)
	var _t_far := Time.get_ticks_msec()
	data["far"] = cached_request("far_ground", 1024)
	_t_far = Time.get_ticks_msec() - _t_far
	if progress.is_valid(): progress.call("Reading distant terrain", 1, 1)
	print("BF6 ground: record %.1f s, %d sheet(s) for %d layer(s) %.1f s, distant %.1f s"
		% [_t_record / 1000.0, _n_decoded, layers.size(), _t_sheets / 1000.0, _t_far / 1000.0])
	ground = data
	return true
