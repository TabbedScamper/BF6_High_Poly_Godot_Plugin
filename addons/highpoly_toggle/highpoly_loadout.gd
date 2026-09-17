@tool
class_name HighpolyLoadout
extends RefCounted
# What a LootSpawner drops, chosen per spawner and drawn from the game, the
# way the Unreal add-on's Loadout does it. The catalogue, the attachment join
# and the configured weapon all come from the shared core (bf6_loadout_*), so
# both editors offer the same choices and draw the same weapon.
#
# THE CHOICES LIVE ON THE NODE, as metadata named LOADOUT_META, and are saved
# with the scene. The keys are the Unreal add-on's preview tag keys:
#   item             <class>/<name>, e.g. "carbine/m4a1"
#   attachment_<slot> a Portal WeaponAttachments member, e.g. "Scope_1p87_150x"
#   portalitem       the Portal item, e.g. "Weapons.Carbine_M4A1"
# The SDK's own LootSpawner script is not touched.

const LOADOUT_META := &"highpoly_loadout"
const DEFAULT_ITEM := "carbine/m4a1"
const SLOTS := ["scp", "sca", "brl", "mzl", "mag", "amo", "erg", "btm", "top", "lft", "rgt"]
const SLOT_LABELS := {"scp": "Optic", "sca": "Canted optic", "brl": "Barrel", "mzl": "Muzzle",
	"mag": "Magazine", "amo": "Ammunition", "erg": "Ergonomics", "btm": "Underbarrel",
	"top": "Top rail", "lft": "Left rail", "rgt": "Right rail"}
const LOOT_KINDS := ["Weapons", "Gadgets", "AmmoTypes", "ArmorTypes"]

# THE SOLDIER SPAWNERS, which carry the same choices plus who is standing there:
#   character  cha0001wisp     outfit  001
#   faction    alliance | pax  role    assault | engineer | support | recon
# Unset fields take the core's defaults, except AI_Spawner, whose side is PAX
# (Unreal's RequestFor), so a placed player/bot pair reads as two forces.
# HQ_PlayerSpawner is deliberately NOT here: it is a deployment post the SDK
# draws as a low-poly flag post, not something that previews a character.
# Offering it operator and outfit choices is what invited the soldier that
# replaced its flag. See the note on HighpolySoldier.SPAWNERS, which drops it
# for the same reason.
const SOLDIER_TYPES := ["PlayerSpawner", "AI_Spawner", "SpawnPoint"]
const DEFAULT_CHARACTER := "cha0001wisp"
const DEFAULT_OUTFIT := "001"
const DEFAULT_ROLE := "assault"

static var _enum_cache := {}
static var _catalogue: Array = []
static var _catalogue_doc := {}
static var _record_mats := {}
static var _attachments := {}
static var _mutex := Mutex.new()


# ------------------------------------------------------------------ choices

static func values_of(node: Node) -> Dictionary:
	var v: Variant = node.get_meta(LOADOUT_META, {}) if node != null else {}
	return (v as Dictionary).duplicate() if v is Dictionary else {}


static func item_of(values: Dictionary) -> String:
	var item := str(values.get("item", ""))
	return item if item != "" else DEFAULT_ITEM


# "slot=member" lines in slot order, the fits the core takes.
static func fits_of(values: Dictionary) -> String:
	var out := PackedStringArray()
	for slot in SLOTS:
		var id := str(values.get("attachment_" + slot, ""))
		if id != "": out.append("%s=%s" % [slot, id])
	return "\n".join(out)


# The identity of what this node should draw; the overlay rebuilds when it changes.
static func request_key(node: Node) -> String:
	var values := values_of(node)
	return "%s|%s" % [item_of(values), fits_of(values).replace("\n", ",")]


static func is_soldier_type(type: String) -> bool:
	return SOLDIER_TYPES.has(type)


static func type_of(node: Node) -> String:
	return (node as Node3D).scene_file_path.get_file().get_basename() if node is Node3D else ""


# The request bf6_loadout_soldier takes, from a spawner type and its choices.
# The id the Pose picker uses for "let the tool choose". It is resolved to a
# real role at build time, never sent to the core.
const ROLE_RANDOM := "random"


# A STABLE HASH, not randi(). A pose picked freshly each build would change
# every time the overlay rebuilt and every time the project reopened, so the
# same spawner would be a different soldier each session and no screenshot
# would ever match. Seeded from the node's own name, it is arbitrary across
# spawners and fixed for any one of them.
static func seed_of(text: String) -> int:
	var h := 5381
	for i in range(text.length()):
		h = ((h << 5) + h + text.unicode_at(i)) & 0x7FFFFFFF
	return h


# Turn ROLE_RANDOM into one of the catalogue's real roles. Anything else is
# passed through untouched, so an explicit choice always wins.
static func resolve_role(core: Object, request: Dictionary) -> Dictionary:
	if str(request.get("role", "")) != ROLE_RANDOM:
		return request
	var roles := catalogue_list(core, "roles")
	var out := request.duplicate()
	if roles.is_empty():
		# No catalogue, no invented list: fall back to the documented default
		# rather than guessing at role names the install may not have.
		out["role"] = DEFAULT_ROLE
		return out
	var pick: Dictionary = roles[seed_of(str(request.get("role_seed", ""))) % roles.size()]
	out["role"] = str(pick.get("id", DEFAULT_ROLE))
	return out


static func soldier_request(type: String, values: Dictionary, seed_text: String = "") -> Dictionary:
	return {
		"character": str(values.get("character", DEFAULT_CHARACTER)),
		"outfit": str(values.get("outfit", DEFAULT_OUTFIT)),
		"faction": str(values.get("faction", "pax" if type == "AI_Spawner" else "alliance")),
		# RANDOM BY DEFAULT. Every spawner used to come back `assault`, so a row
		# of them stood in one identical pose - reported as "every soldier got
		# the same stance", and it was precisely what the default said to do.
		# Random resolves from the spawner's own NAME, so it varies across a map
		# and never changes for a given spawner. An explicit choice still wins.
		"role": str(values.get("role", ROLE_RANDOM)),
		# Carried so the asset id differs per spawner when the pose is random -
		# without it every random soldier would share one id, and the first one
		# built would be reused for all of them.
		"role_seed": seed_text,
		# A SKELETON INSTEAD OF A FROZEN FRAME, and now on by default.
		#
		# It was off because an animated soldier costs a 341-bone skeleton and
		# eight-weight skinning per spawner and nothing bounded that cost. The
		# 50 m radius bounds it: past that the clock stops and a soldier costs a
		# distance check. Charging a whole map for animation nobody can see was
		# the thing worth avoiding, and it is not what happens any more.
		"animated": bool(values.get("animated", true)),
		"item": item_of(values),
		"fits": fits_of(values),
	}


# Stable text for a soldier request: the overlay's asset id, parsed back by the
# library when it builds.
static func soldier_key(node: Node) -> String:
	return JSON.stringify(
		soldier_request(type_of(node), values_of(node), str(node.name)), "", true)


# ------------------------------------------------------------- Portal enums

# The SDK's own TypeScript declarations, beside the Godot project. The Unreal
# add-on reads the same members from its Blocks definitions; the two lists are
# identical (371 attachment members on SDK 1.4.2.0).
static func _types_path() -> String:
	var project := ProjectSettings.globalize_path("res://").simplify_path()
	for candidate in [project.path_join("../code/types/mod/index.d.ts"),
			project.path_join("code/types/mod/index.d.ts")]:
		var p := (candidate as String).simplify_path()
		if FileAccess.file_exists(p): return p
	return ""


static func enum_members(enum_name: String) -> PackedStringArray:
	_mutex.lock()
	if _enum_cache.has(enum_name):
		var hit: PackedStringArray = _enum_cache[enum_name]
		_mutex.unlock()
		return hit
	_mutex.unlock()
	var out := PackedStringArray()
	var path := _types_path()
	if path != "":
		var text := FileAccess.get_file_as_string(path)
		var at := text.find("export enum %s {" % enum_name)
		if at >= 0:
			var end := text.find("}", at)
			for line in text.substr(at, end - at).split("\n").slice(1):
				var member := (line as String).strip_edges().trim_suffix(",")
				if member != "" and not member.begins_with("//"): out.append(member)
	_mutex.lock()
	_enum_cache[enum_name] = out
	_mutex.unlock()
	return out


static func attachment_enums_text() -> String:
	var members := enum_members("WeaponAttachments")
	var sorted := Array(members)
	sorted.sort()
	return "\n".join(PackedStringArray(sorted))


static func loot_items() -> PackedStringArray:
	var all: Array = []
	for kind in LOOT_KINDS:
		for m in enum_members(kind): all.append("%s.%s" % [kind, m])
	all.sort()
	return PackedStringArray(all)


static func _normalize(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"): out += ch
	return out


# The Portal item a game item maps to, when exactly one does (Unreal's rule).
static func portal_match(item: Dictionary) -> String:
	var id := str(item.get("id", ""))
	var token := id.get_slice("/", 1)
	var label := str(item.get("label", ""))
	var found := ""
	for p in loot_items():
		var member := p.get_slice(".", 1)
		var at := member.find("_")
		var name := member.substr(at + 1) if at >= 0 else member
		if _normalize(name) == _normalize(token) or _normalize(name) == _normalize(label):
			if found != "": return ""
			found = p
	return found


# --------------------------------------------------------------- the core

static func core_for(gs) -> Object:
	if gs == null: return null
	# A BARE CORE IS ENOUGH. The loadout reads the front-end mount, not a level,
	# so nothing here needs a map opened - and a test that had to open one paid
	# minutes for geometry it never looked at. A game source is still the normal
	# caller; this just stops it being the only possible one.
	if gs.has_method("loadout_soldier"): return gs
	if not gs.has_method("_ensure_native_core") or not gs._ensure_native_core(): return null
	var core: Object = gs.get("_native_core")
	return core if core != null and core.has_method("loadout_weapon") else null


static func catalogue(core: Object) -> Array:
	_mutex.lock()
	if not _catalogue.is_empty():
		var hit := _catalogue
		_mutex.unlock()
		return hit
	_mutex.unlock()
	if core == null: return []
	var parsed: Variant = JSON.parse_string(str(core.call("loadout_catalogue")))
	var doc: Dictionary = parsed if parsed is Dictionary else {}
	var items: Array = doc.get("items", [])
	_mutex.lock()
	_catalogue = items
	_catalogue_doc = doc
	_mutex.unlock()
	return items


# The catalogue's other lists: "characters" [{id,label}], "outfits"
# [{character,id,label}], "factions" and "roles" [{id,label}].
static func catalogue_list(core: Object, name: String) -> Array:
	catalogue(core)
	_mutex.lock()
	var out: Array = _catalogue_doc.get(name, [])
	_mutex.unlock()
	return out


static func outfits_for(core: Object, character: String) -> Array:
	var out: Array = []
	for o in catalogue_list(core, "outfits"):
		if str((o as Dictionary).get("character", "")) == character: out.append(o)
	return out


static func find_item(core: Object, id: String) -> Dictionary:
	for it in catalogue(core):
		if str((it as Dictionary).get("id", "")) == id: return it
	return {}


static func attachments(core: Object, item: String) -> Array:
	_mutex.lock()
	if _attachments.has(item):
		var hit: Array = _attachments[item]
		_mutex.unlock()
		return hit
	_mutex.unlock()
	if core == null: return []
	var parsed: Variant = JSON.parse_string(str(core.call("loadout_attachments", item, attachment_enums_text())))
	var rows: Array = (parsed as Dictionary).get("attachments", []) if parsed is Dictionary else []
	_mutex.lock()
	_attachments[item] = rows
	_mutex.unlock()
	return rows


static func slot_choices(core: Object, item: String, slot: String) -> Array:
	var out: Array = []
	for a in attachments(core, item):
		if str((a as Dictionary).get("slot", "")) == slot: out.append(a)
	return out


# ------------------------------------------------------------ the weapon

static func _key_from_hex(hex: String) -> int:
	if hex.length() != 16: return 0
	return (("0x" + hex.substr(0, 8)).hex_to_int() << 32) | ("0x" + hex.substr(8, 8)).hex_to_int()


# The configured weapon as a Node3D of game geometry, aligned to the marker the
# way Unreal aligns it (bounds centre on the marker's bounds centre is done by
# the caller, which knows the marker). {} fields: "node", "anchors", "error".
static func build_weapon(gs, values: Dictionary) -> Dictionary:
	var core := core_for(gs)
	if core == null: return {"error": "The game reader has no loadout support; update the add-on."}
	var item := item_of(values)
	var blob: PackedByteArray = core.call("loadout_weapon", item, fits_of(values), attachment_enums_text())
	return _from_record(gs, blob, "HP_Loadout_%s" % item.replace("/", "_"), "weapon", false)


# The posed soldier holding its configured weapon (bf6_loadout_soldier): the same
# character parts, pose, skinning, faction badge, face and weapon grip Unreal
# draws, standing with its feet on the spawner's origin. Materials come from the
# record's own texture bindings, as Unreal's do, because the badge and the face
# sheet exist nowhere else. {} fields: "node", "error".
static func build_soldier(gs, request: Dictionary) -> Dictionary:
	var core := core_for(gs)
	if core == null or not core.has_method("loadout_soldier"):
		return {"error": "The game reader has no soldier support; update the add-on."}
	var blob: PackedByteArray = core.call("loadout_soldier", JSON.stringify(request), attachment_enums_text())
	return _from_record(gs, blob, "HP_Soldier_%s" % str(request.get("character", "")), "soldier", true)


# WHAT THE PLAYER SEES OF THEMSELVES: this soldier's own arms on the
# first-person skeleton, holding their configured weapon. The record is already
# anchored on CameraJoint, so the node attaches to a camera at identity - no
# offset, no guessing where a rifle sits. {} fields: "node", "error".
static func build_soldier_1p(gs, request: Dictionary) -> Dictionary:
	var core := core_for(gs)
	if core == null or not core.has_method("loadout_soldier"):
		return {"error": "The game reader has no soldier support; update the add-on."}
	var req := request.duplicate()
	req["view"] = "1p"
	var blob: PackedByteArray = core.call("loadout_soldier", JSON.stringify(req),
		attachment_enums_text())
	return _from_record(gs, blob, "HP_Soldier1P_%s" % str(req.get("character", "")),
		"first-person soldier", true)


# HOW TALL THIS SOLDIER'S EYES ARE, measured from the ground they stand on, at
# the pose they are shown in. 0.0 when the record cannot say, which a caller
# must read as "use your own default" rather than as "this soldier has no head".
#
# Worth reading rather than assuming: it varies by character and by pose (1.686
# to 1.718 m across four operators and two roles), and a camera parked at a
# single constant sits visibly wrong for most of them.
static func soldier_eye(gs, request: Dictionary) -> float:
	var core := core_for(gs)
	if core == null or not core.has_method("loadout_soldier"):
		return 0.0
	var blob: PackedByteArray = core.call("loadout_soldier", JSON.stringify(request),
		attachment_enums_text())
	if blob.size() < 12 or blob.decode_u32(0) != 0x50574C42:
		return 0.0
	var json_len := blob.decode_u32(8)
	var parsed: Variant = JSON.parse_string(
		blob.slice(12, 12 + json_len).get_string_from_utf8())
	if not (parsed is Dictionary):
		return 0.0
	return float((parsed as Dictionary).get("eye", 0.0))


# A BLWP record (see bf6_loadout_weapon in bf6_core.h) as one mesh.
static func _from_record(gs, blob: PackedByteArray, node_name: String, what: String,
		record_materials: bool) -> Dictionary:
	if blob.size() < 12 or blob.decode_u32(0) != 0x50574C42:
		return {"error": "The configured %s could not be read." % what}
	var json_len := blob.decode_u32(8)
	var parsed: Variant = JSON.parse_string(blob.slice(12, 12 + json_len).get_string_from_utf8())
	if not (parsed is Dictionary): return {"error": "The configured %s record is invalid." % what}
	var rec: Dictionary = parsed
	if str(rec.get("error", "")) != "": return {"error": str(rec.error)}
	var body := 12 + json_len
	var am := ArrayMesh.new()
	for s in rec.get("sections", []):
		var sec: Dictionary = s
		var vc := int(sec.vertex_count)
		var ic := int(sec.index_count)
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		var p := body + int(sec.positions) * 4
		arr[Mesh.ARRAY_VERTEX] = blob.slice(p, p + vc * 12).to_vector3_array()
		if int(sec.normals) >= 0:
			var n := body + int(sec.normals) * 4
			arr[Mesh.ARRAY_NORMAL] = blob.slice(n, n + vc * 12).to_vector3_array()
		if int(sec.uvs) >= 0:
			var u := body + int(sec.uvs) * 4
			arr[Mesh.ARRAY_TEX_UV] = blob.slice(u, u + vc * 8).to_vector2_array()
		var i := body + int(sec.indices) * 4
		arr[Mesh.ARRAY_INDEX] = blob.slice(i, i + ic * 4).to_int32_array()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		am.surface_set_material(am.get_surface_count() - 1,
			section_material(gs, sec, record_materials))
	if am.get_surface_count() == 0: return {"error": "The configured %s has no drawable geometry." % what}
	var root := Node3D.new()
	root.name = node_name
	var mi := MeshInstance3D.new()
	mi.name = "Weapon" if what == "weapon" else "Soldier"
	mi.mesh = am
	root.add_child(mi)
	var anchors := {}
	var raw_anchors: Variant = rec.get("anchors", {})
	if raw_anchors is Dictionary:
		for slot in raw_anchors:
			var a: Array = raw_anchors[slot]
			anchors[slot] = Vector3(float(a[0]), float(a[1]), float(a[2]))
	root.set_meta("hp_slot_anchors", anchors)
	return {"node": root, "anchors": anchors, "error": ""}


# ------------------------------------------------ materials from the record

# The material for one record section, in the order the record makes available:
# the section's own texture bindings first (the badge and the face sheet exist
# nowhere else), then the map's shared material cache, then flat base colour.
#
# The static soldier and the skinned one must not make this decision
# separately - a difference here would read as a skinning bug while actually
# being two copies of the same code drifting apart - so both call this.
static func section_material(gs, sec: Dictionary, record_materials: bool = true) -> Material:
	var mat: Material = _record_material(gs, sec) if record_materials else null
	var key := _key_from_hex(str(sec.get("state_key", "")))
	var bundle := str(sec.get("bundle", "")).trim_prefix("win32/")
	if mat == null and gs != null and gs.has_method("material_for") and key != 0 and bundle != "":
		mat = gs.material_for(key, bundle, 0, PackedInt32Array())
	if mat == null:
		var fallback := StandardMaterial3D.new()
		var bc: Array = sec.get("base_color", [0.5, 0.5, 0.5])
		fallback.albedo_color = Color(float(bc[0]), float(bc[1]), float(bc[2]))
		fallback.roughness = float(sec.get("roughness", 0.6))
		mat = fallback
	return mat

# The eye's shader textures, by parameter name hash (the renderer slots Unreal
# gives them in BF6HighPolyLoadoutDecode.cpp).
const EYE_IRIS := 0x0370914E
const EYE_SCLERA := 0x1419F025
const EYE_IRIS_NORMAL := 0x71828BD1
const EYE_SCLERA_NORMAL := 0xEC2DE079
const EYE_MASK := 0xE15F84CE

static var _eye_shader: Shader = null
static var _cut_shader: Shader = null


# A section's material from the textures the record names, following the Unreal
# add-on's material kinds: an eye joins its iris and sclera sheets by the mask; an
# alpha test that takes its alpha from the albedo (the faction badge) cuts on it;
# an alpha test with a cutout sheet (slot 4) cuts on that sheet's red; translucent
# blends. Null when the record binds nothing, so the depot path can try.
static func _record_material(gs, sec: Dictionary) -> Material:
	if gs == null or not gs.has_method("texture_named") or not sec.has("textures"): return null
	var slots := {}
	for t in sec.get("textures", []):
		slots[int((t as Array)[0])] = str((t as Array)[2])
	var shader_tex := {}
	for t in sec.get("shader_textures", []):
		shader_tex[int((t as Array)[0])] = str((t as Array)[2])
	var alpha_test := int(sec.get("alpha_test", 0)) != 0
	var from_albedo := int(sec.get("alpha_from_albedo", 0)) != 0
	var translucent := int(sec.get("translucent", 0)) != 0
	var bc: Array = sec.get("base_color", [1.0, 1.0, 1.0])
	var roughness := float(sec.get("roughness", 0.6))
	var eye := shader_tex.has(EYE_IRIS) and shader_tex.has(EYE_SCLERA) and shader_tex.has(EYE_MASK)
	var look := JSON.stringify([slots, shader_tex if eye else {}, alpha_test, from_albedo, translucent, bc, roughness])
	_mutex.lock()
	var hit: Variant = _record_mats.get(look)
	_mutex.unlock()
	if hit is Material: return hit
	var mat: Material = null
	if eye:
		mat = _eye_material(gs, shader_tex)
	elif slots.is_empty():
		return null
	elif alpha_test and not from_albedo and slots.has(4):
		var sm := ShaderMaterial.new()
		sm.shader = _cut()
		var albedo = gs.texture_named(slots.get(0, ""))
		sm.set_shader_parameter("albedo", albedo)
		sm.set_shader_parameter("has_albedo", albedo != null)
		sm.set_shader_parameter("base_color", Color(float(bc[0]), float(bc[1]), float(bc[2])))
		var nrm = gs.texture_named(slots.get(1, ""), true)
		sm.set_shader_parameter("normal_tex", nrm)
		sm.set_shader_parameter("has_normal", nrm != null)
		sm.set_shader_parameter("cut", gs.texture_named(slots[4]))
		sm.set_shader_parameter("roughness", roughness)
		mat = sm
	else:
		var m := StandardMaterial3D.new()
		var albedo = gs.texture_named(slots.get(0, ""))
		if albedo != null:
			m.albedo_texture = albedo
		else:
			m.albedo_color = Color(float(bc[0]), float(bc[1]), float(bc[2]))
		var nrm = gs.texture_named(slots.get(1, ""), true)
		if nrm != null:
			m.normal_enabled = true
			m.normal_texture = nrm
		m.roughness = roughness
		if alpha_test and from_albedo:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			m.alpha_scissor_threshold = 0.5
		elif translucent:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat = m
	if mat != null:
		_mutex.lock()
		_record_mats[look] = mat
		_mutex.unlock()
	return mat


static func _eye_material(gs, shader_tex: Dictionary) -> Material:
	if _eye_shader == null:
		_eye_shader = Shader.new()
		# Unreal's eye: lerp(sclera, iris, saturate(1 - 2 * mask.r)) for colour and
		# for the normal's xy, roughness max(0.04, 1 - colour alpha).
		_eye_shader.code = """shader_type spatial;
uniform sampler2D iris : source_color, filter_linear_mipmap;
uniform sampler2D sclera : source_color, filter_linear_mipmap;
uniform sampler2D mask : hint_default_white, filter_linear_mipmap;
uniform sampler2D iris_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D sclera_normal : hint_normal, filter_linear_mipmap;
void fragment() {
	float t = clamp(1.0 - 2.0 * texture(mask, UV).r, 0.0, 1.0);
	vec4 c = mix(texture(sclera, UV), texture(iris, UV), t);
	ALBEDO = c.rgb;
	ROUGHNESS = max(0.04, 1.0 - c.a);
	NORMAL_MAP = vec3(mix(texture(sclera_normal, UV).rg, texture(iris_normal, UV).rg, t), 1.0);
}
"""
	var sm := ShaderMaterial.new()
	sm.shader = _eye_shader
	sm.set_shader_parameter("iris", gs.texture_named(shader_tex[EYE_IRIS]))
	sm.set_shader_parameter("sclera", gs.texture_named(shader_tex[EYE_SCLERA]))
	sm.set_shader_parameter("mask", gs.texture_named(shader_tex[EYE_MASK]))
	if shader_tex.has(EYE_IRIS_NORMAL):
		sm.set_shader_parameter("iris_normal", gs.texture_named(shader_tex[EYE_IRIS_NORMAL], true))
	if shader_tex.has(EYE_SCLERA_NORMAL):
		sm.set_shader_parameter("sclera_normal", gs.texture_named(shader_tex[EYE_SCLERA_NORMAL], true))
	return sm


static func _cut() -> Shader:
	if _cut_shader == null:
		_cut_shader = Shader.new()
		_cut_shader.code = """shader_type spatial;
uniform sampler2D albedo : source_color, filter_linear_mipmap;
uniform bool has_albedo = false;
uniform vec3 base_color : source_color = vec3(1.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform bool has_normal = false;
uniform sampler2D cut : hint_default_white, filter_linear_mipmap;
uniform float roughness = 0.6;
void fragment() {
	ALBEDO = has_albedo ? texture(albedo, UV).rgb : base_color;
	if (has_normal) { NORMAL_MAP = texture(normal_tex, UV).rgb; }
	ROUGHNESS = roughness;
	ALPHA = texture(cut, UV).r;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
"""
	return _cut_shader
