@tool
extends Object
class_name HighpolyCarrierExport
# CARRIER LAYOUTS AS FLAT ORANGE MESHES.
#
# The Portal SDK ships no carrier, so a creator building a Carrier Strike or
# Portal-carrier experience has nothing to place objects against: the deck is
# where the gameplay is and the editor shows empty sea. This writes one glTF per
# carrier LAYOUT, built from the level's own placements, with every game material
# stripped and one flat colour in their place.
#
# WHAT IT IS NOT. There are no game textures or materials in the output - the
# meshes carry a single untextured StandardMaterial3D whose colour is sampled
# from the SDK's own blockout sheet, so the result matches the orange the map
# already comes in with and contains none of the game's art.
#
# ONE FILE PER LAYOUT, because the layouts genuinely differ and that difference
# is the point. On MP_Isolated (Tsuru Reef):
#
#   carrierstrike                          668 meshes  15,927 instances
#   portal_aircraftcarriers_carrierstrike   the same ships, the Portal twin
#   portal_aircraftcarriers_conquest       184 meshes   1,814 instances
#   conquest / escalation                  109 meshes     335 instances
#
# Only the carrierstrike layouts carry the interior, which is correct and
# authored, not a gap in the export.
#
# LOD IS THE LOW-POLY LEVER. Rung 0 is what the game draws up close and is
# 22.4 million triangles for carrierstrike - unusable in an editor viewport and
# absurd as a file. The game's own coarser rungs are measured at 29.6% (LOD1)
# and 15.6% (LOD2) of LOD0's vertex bytes, so the export defaults to LOD2 and
# says which rung it used.

const CARRIER_MARK := "carrier"
# Sampled from the map's own static/<MAP>_Assets blockout sheet at export time
# when it can be read; this is the fallback when it cannot.
const FALLBACK_ORANGE := Color(0.93, 0.51, 0.20)
const DEFAULT_LOD := 2


# Every carrier layout on the open map: layer key -> {meshes: {name: xf Array}}.
#
# Grouped by the LAYER the walk assigned, because that is what the game switches
# on and therefore what "a layout" means. A mesh in two layers is in two layouts.
static func layouts(gs) -> Dictionary:
	var out := {}
	if gs == null: return out
	var data: Dictionary = gs.map_data()
	for p in data.get("props", []):
		var rec: Dictionary = p
		var mesh_name := str(rec.get("mesh", ""))
		if not mesh_name.to_lower().contains(CARRIER_MARK):
			continue
		var layer := str(rec.get("layer", ""))
		if layer == "": layer = "always_visible"
		if not out.has(layer): out[layer] = {}
		(out[layer] as Dictionary)[mesh_name] = rec.get("xf", [])
	return out


# The blockout orange, taken from the SDK's own map assets rather than chosen.
#
# The map scenes instance static/<MAP>_Assets.tscn, whose material is a white
# albedo over a 256x256 sheet at roughness 0.30. Averaging that sheet gives the
# colour the creator already sees, so the carrier matches the rest of the
# blockout without carrying the sheet itself.
static func blockout_colour(level: String) -> Color:
	var path := "res://static/%s_Assets.tscn" % level
	if not ResourceLoader.exists(path):
		return FALLBACK_ORANGE
	var ps: PackedScene = load(path)
	if ps == null: return FALLBACK_ORANGE
	var root: Node = ps.instantiate()
	var found := FALLBACK_ORANGE
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children(): stack.append(c)
		if not (n is MeshInstance3D): continue
		var m: Mesh = (n as MeshInstance3D).mesh
		if m == null: continue
		for i in range(m.get_surface_count()):
			var mat := m.surface_get_material(i)
			if not (mat is StandardMaterial3D): continue
			var tex: Texture2D = (mat as StandardMaterial3D).albedo_texture
			if tex == null: continue
			var img: Image = tex.get_image()
			if img == null: continue
			img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var n_px := 0
			# Every 4th texel in each direction: the sheet is flat colour blocks,
			# so a full scan buys nothing.
			for y in range(0, img.get_height(), 4):
				for x in range(0, img.get_width(), 4):
					var px := img.get_pixel(x, y)
					if px.a < 0.5: continue
					r += px.r; g += px.g; b += px.b; n_px += 1
			if n_px > 0:
				found = Color(r / n_px, g / n_px, b / n_px)
				stack.clear()
				break
	root.queue_free()
	return found


static func _material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	# No texture, by design: the point of this export is geometry without the
	# game's art. Roughness matches the SDK blockout so it sits under the same
	# lighting as everything else in the scene.
	m.albedo_color = colour
	m.roughness = 0.30
	m.metallic = 0.0
	return m


static func _xform(a: Array, o: int) -> Transform3D:
	# 12 floats = basis ROWS then origin; the columns are the transpose. Same
	# decode the map builder uses - a private copy here would be a second
	# convention waiting to disagree with the first.
	var t := Transform3D()
	t.basis.x = Vector3(a[o + 0], a[o + 3], a[o + 6])
	t.basis.y = Vector3(a[o + 1], a[o + 4], a[o + 7])
	t.basis.z = Vector3(a[o + 2], a[o + 5], a[o + 8])
	t.origin = Vector3(a[o + 9], a[o + 10], a[o + 11])
	return t


# One layout as a scene tree. Every instance is its own MeshInstance3D sharing
# the group's Mesh resource, so glTF writes the geometry ONCE and the instances
# become cheap node transforms.
static func build_layout(gs, name: String, meshes: Dictionary, mat: Material,
		lod: int, stats: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = name
	var tris := 0
	var instances := 0
	var missing := 0
	for mesh_name in meshes.keys():
		var mesh: Mesh = gs.mesh_for(str(mesh_name), lod)
		if mesh == null:
			missing += 1
			continue
		var per := 0
		for si in range(mesh.get_surface_count()):
			per += mesh.surface_get_array_index_len(si) / 3
		var xf: Array = meshes[mesh_name]
		var count := int(xf.size() / 12)
		var group := Node3D.new()
		group.name = str(mesh_name).get_file()
		root.add_child(group)
		for i in range(count):
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			# material_override replaces EVERY surface's material at once, which
			# is exactly the intent: nothing of the game's shading survives.
			mi.material_override = mat
			mi.transform = _xform(xf, i * 12)
			mi.name = "%s_%d" % [group.name, i]
			group.add_child(mi)
		tris += per * count
		instances += count
	stats["triangles"] = tris
	stats["instances"] = instances
	stats["missing"] = missing
	stats["meshes"] = meshes.size()
	return root


# Write one layout to <dir>/Carrier_Layout_<name>.glb. Returns "" or an error.
static func export_layout(root: Node3D, dir: String, file_name: String) -> String:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	# The scene must be inside a tree for the exporter to resolve it.
	var err := doc.append_from_scene(root, state)
	if err != OK:
		return "could not read the layout scene (%d)" % err
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(file_name)
	err = doc.write_to_filesystem(state, path)
	if err != OK:
		return "could not write %s (%d)" % [path, err]
	return ""


# THE MAP'S REAL NAME, from the SDK's own catalogue.
#
# mp_isolated is Tsuru Reef and mp_atoll is Wake Island, and neither is guessable
# from the level id. The SDK already ships the mapping in its map-selection
# catalogue, keyed by the id spelling (MP_Isolated), so it is read rather than
# copied here - a hardcoded table would be a second list to keep in step with the
# season, and it would be wrong the first time a map is renamed or added.
static func map_display_name(level: String) -> String:
	const CATALOG := "res://addons/bf6_map_selection/data/map_catalog.json"
	var want := level.to_lower()
	if FileAccess.file_exists(CATALOG):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
		var found := _find_name(raw, want)
		if found != "":
			return found
	# No catalogue (a bare project, or the add-on moved): the level id is a
	# truthful folder name even if it is not the friendly one.
	return level


static func _find_name(node: Variant, want: String) -> String:
	if node is Array:
		for x in (node as Array):
			var got := _find_name(x, want)
			if got != "": return got
	elif node is Dictionary:
		var d: Dictionary = node
		if str(d.get("id", "")).to_lower() == want and str(d.get("name", "")) != "":
			return str(d["name"])
		for k in d.keys():
			var got := _find_name(d[k], want)
			if got != "": return got
	return ""


# A folder name from a map name: "Tsuru Reef" -> "Tsuru Reef" is fine on disk,
# but strip anything a filesystem will not take.
static func safe_folder(name: String) -> String:
	var out := ""
	for i in range(name.length()):
		var ch := name[i]
		out += ch if ch.is_valid_identifier() or ch == " " or ch == "-" or ch.is_valid_int() else "_"
	out = out.strip_edges()
	return out if out != "" else "Unknown"


# A readable name for a layer key, so the files say what they are.
static func layout_file_name(layer: String) -> String:
	var clean := layer.replace(",", "_").replace("/", "_").strip_edges()
	var parts := clean.split("_", false)
	var titled := ""
	# Title-case each token: portal_aircraftcarriers_conquest becomes
	# PortalAircraftcarriersConquest, which reads in a file list.
	for p in parts:
		if p.is_empty(): continue
		titled += p.substr(0, 1).to_upper() + p.substr(1)
	if titled.is_empty(): titled = "Unnamed"
	return "Carrier_Layout_%s.glb" % titled
