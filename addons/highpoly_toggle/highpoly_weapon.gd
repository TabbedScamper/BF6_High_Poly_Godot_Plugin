@tool
extends Object
class_name HighpolyWeapon

# The weapon a LootSpawner drops, assembled from the game.
#
# Same shape of problem as the soldiers: a LootSpawner is spawn logic with no
# mesh blueprint, so has_object() finds nothing and it draws as the SDK marker.
# The visual lives in the hardware library, and weapon parts SELF-ASSEMBLE AT
# IDENTITY in weapon space - base receiver, a barrel variant, magazine, sights,
# muzzle - so the build is again "add these meshes at the origin".
#
# The M4A1 is a CARBINE, not an assaultrifle: common/hardware/weapons/carbine/.
# A first search under assaultrifle found only the M16A3 and nearly had me
# report that the game ships no M4A1 at all. It ships 21 _3p part meshes.
#
# THE DEPOT SCOPE IS PER PART, not per weapon. Characters have one bundle each
# (cd_<cha>_bundle_3p); weapons have one per part, named dpf_<part>_<weapon>_
# <hash>_bundle_3p - e.g. dpf_m16a3_barrel16indpms_7s4uq7_bundle_3p. The hash
# is unguessable, so the scopes are DISCOVERED by filtering the depot table for
# the weapon's name and trying them, rather than being constructed.

const SPAWNERS := {"LootSpawner": "m4a1"}

const WEAPONS := {
	"m4a1": {
		"dir": "common/hardware/weapons/carbine/m4a1/art/",
		"stem": "ob_wep_carbine_m4a1_",
		# a default loadout: receiver, the short barrel, magazine, irons, muzzle.
		# Attachments are the same mechanism - another _3p part at identity -
		# which is what makes swapping them later a data change, not a rewrite.
		"parts": ["base", "barrelshort", "magazine", "ironsights", "muzzle"],
	},
}

# THE PICKUP OFFSET IS NOT RECOVERED YET.
#
# The download build baked a display transform into its LootSpawner GLB so the
# weapon hovered at pickup height, and that GLB is not in the backed-up library
# on this machine - I looked. Identity puts the weapon at the marker's origin,
# which is honest and visibly provisional, rather than a number I made up that
# would look deliberate and be wrong. One measurement from the old build sets
# this correctly.
const DISPLAY_OFFSET := Vector3.ZERO
const DISPLAY_ROT_DEG := Vector3.ZERO


static func weapon_for(key: String) -> String:
	return str(SPAWNERS.get(key, ""))


static func build(gs, id: String) -> Node3D:
	if gs == null or not WEAPONS.has(id):
		return null
	var w: Dictionary = WEAPONS[id]
	var scopes := _scopes_for(gs, id)
	var root := Node3D.new()
	root.name = "HP_Weapon_%s" % id
	root.position = DISPLAY_OFFSET
	root.rotation_degrees = DISPLAY_ROT_DEG
	var built := 0
	for part in w["parts"]:
		var res := "%s%s%s_3p_mesh" % [w["dir"], w["stem"], part]
		var m = gs.mesh_for(res)
		if m == null:
			continue
		_dress(gs, m, scopes)
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.name = str(part)
		root.add_child(mi)
		mi.owner = null
		built += 1
	if built == 0:
		push_warning("[highpoly] weapon %s: no part could be built" % id)
		root.queue_free()
		return null
	return root


# Every depot scope whose name mentions this weapon. Small - a few dozen out of
# ~17,000 - so trying them is cheap, and it beats constructing a name around a
# hash nobody can derive.
static func _scopes_for(gs, id: String) -> Array:
	var out: Array = []
	if not ("_depot_bundles" in gs):
		return out
	for k in gs._depot_bundles.keys():
		var ks := str(k)
		if ks.findn(id) >= 0 and ks.ends_with("_bundle_3p"):
			out.append(ks)
	return out


static func _dress(gs, m, scopes: Array) -> void:
	var am := m as ArrayMesh
	if am == null or scopes.is_empty() or not gs.has_method("material_for"):
		return
	for i in range(am.get_surface_count()):
		if am.surface_get_material(i) != null:
			continue
		var nm := am.surface_get_name(i)
		if nm == "":
			continue
		# THE PART AFTER "@" IS THE PALETTE, NOT A VARIATION HASH. A surface is
		# named "<state key>@<colour table entries>", so int() on "0,1" gave 0
		# and the palette was discarded - harmless on a single-entry surface,
		# and on a multi-entry one it asks the record about entries the surface
		# does not use. Found on the vehicles, which were copied from here and
		# came out grey; fixed in both.
		var key: int = gs._mkey(nm)
		var pal: PackedInt32Array = gs._mpal(nm)
		for sc in scopes:
			var mat = gs.material_for(key, str(sc), 0, pal)
			if mat != null:
				am.surface_set_material(i, mat)
				break
