@tool
extends Object
class_name HighpolySoldier

# A NATO and a Pax soldier for the spawner proxies, assembled from the game.
#
# Gameplay spawners carry no mesh blueprint - they are pure spawn logic, so
# has_object() finds nothing for them and they draw as the SDK's placeholder.
# Their visuals live in the CHARACTER library instead, and every part of a
# character sits in one shared bind-pose space at identity, so the assembly is
# just "add these six meshes at the origin". Measured on cha0001wisp: body
# 46,799 v spanning y 0.00-1.63, headgear at 1.48-1.86, backpack at 0.92-1.52,
# face at 1.47-1.81. They stack into a ~1.86 m A-pose soldier with no rig work.
#
# FACTION IS A PATCH, NOT A MODEL. All 52 operators serve both sides; what is
# faction-specific is a badge. The set's `_patch_mesh` is a 243-vertex plate
# across the chest (x -0.36..0.34 at y 1.31-1.45) whose material M_Patch_A binds
# `t_base_cs` - a PLACEHOLDER, i.e. the art is substituted at runtime. That one
# slot is where the faction goes, and the game ships exactly two candidates.
# NATO is spelled "Alliance" in the data.

const PATCH := {
	"alliance": "common/characters/_shared/patches/faction/t_patch_faction_alliance_cs",
	"pax": "common/characters/_shared/patches/faction/t_patch_faction_pax_01_cs",
}
# Which operator wears each side. Arbitrary among the 52 - the faction is the
# patch, not the man - but fixed so a scene does not change between sessions.
const WEARER := {"alliance": "cha0001wisp", "pax": "cha0002know"}

# The spawner proxies these stand in for. SpawnPoint is where the player comes
# in, AI_Spawner is a bot, so they get opposite sides and a placed pair reads as
# two forces rather than as one.
const SPAWNERS := {"SpawnPoint": "alliance", "AI_Spawner": "pax"}

const PARTS := [
	["set/set_%s/%s_set_%s_mesh", true],
	["set/set_%s/%s_set_%s_headgear_mesh", false],
	["set/set_%s/%s_set_%s_backpack_mesh", false],
	["set/set_%s/%s_set_%s_patch_mesh", false],
]
const SET := "001"


static func faction_for(key: String) -> String:
	return str(SPAWNERS.get(key, ""))


# The whole soldier, or null. Meshes come through mesh_for so they arrive
# dressed by the same depot chain every prop uses.
static func build(gs, faction: String) -> Node3D:
	if gs == null or not SPAWNERS.values().has(faction):
		return null
	var cha := str(WEARER[faction])
	var base := "common/characters/mp/main/%s/" % cha
	var root := Node3D.new()
	root.name = "HP_Soldier_%s" % faction
	var built := 0

	for p in PARTS:
		var rel: String = (p[0] as String) % [SET, cha, SET]
		var res := base + rel
		var m = gs.mesh_for(res)
		if m == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.name = rel.get_file()
		# the patch is the faction badge, and its authored basecolor is a
		# placeholder - swap it, or leave the part out rather than show a blank
		if rel.ends_with("_patch_mesh"):
			var pm := _patch_material(gs, faction)
			if pm == null:
				mi.queue_free()
				continue
			mi.material_override = pm
		root.add_child(mi)
		mi.owner = null
		built += 1

	# The face is a separate subtree and its head_mat resolves to ZERO texture
	# slots through the depot, so it needs a texture named by hand. Added only
	# when that texture is actually there: a untextured head reads as a bug in
	# a way a missing one does not.
	var fb := base + "face/_base/%s_face_base_standard_mesh" % cha
	var fm = gs.mesh_for(fb)
	if fm != null:
		var fi := MeshInstance3D.new()
		fi.mesh = fm
		fi.name = "face_base"
		var ft = _face_material(gs, cha)
		if ft != null:
			fi.material_override = ft
		root.add_child(fi)
		fi.owner = null
		built += 1

	if built == 0:
		root.queue_free()
		return null
	return root


static func _patch_material(gs, faction: String) -> StandardMaterial3D:
	var t = _texture(gs, str(PATCH[faction]))
	if t == null:
		return null
	var m := StandardMaterial3D.new()
	m.albedo_texture = t
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	return m


static func _face_material(gs, cha: String) -> StandardMaterial3D:
	# the depot gives head_mat nothing, so the face sheet is named directly
	for cand in ["common/characters/mp/main/%s/face/face_001/t_%s_face_001_cs" % [cha, cha],
				 "common/characters/mp/main/%s/face/_base/textures/t_%s_face_cs" % [cha, cha]]:
		var t = _texture(gs, cand)
		if t != null:
			var m := StandardMaterial3D.new()
			m.albedo_texture = t
			return m
	return null


static func _texture(gs, res: String):
	if not gs.has_method("_texture_for_asset"):
		return null
	return gs._texture_for_asset(res)
