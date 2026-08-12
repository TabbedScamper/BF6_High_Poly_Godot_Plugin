@tool
extends Object
class_name HighpolyVehicle

# The vehicle a VEH_* object stands for, assembled from the game.
#
# Same shape of problem as the soldiers and the weapons, and it is why a vehicle
# dropped into the scene never gained an overlay: there is no mesh blueprint to
# find. Every Portal vehicle shares ONE generic spawner blueprint and is told
# apart by a field the native code reads, so has_object() answers no and the SDK
# proxy stays. Nothing in this plugin mentioned VehicleSpawner or VEH_ at all.
#
# The geometry was reachable the whole time. Measured on this install:
#
#   127 res under common/hardware/vehicles/tank/abrams/art/
#   21 depot scopes naming 'abrams'
#   resolve_mesh("...ob_veh_tank_abrams_base") -> ..._base_mesh
#
# So the route is mesh-first, exactly like the weapons: name the directory, ask
# for the base mesh, discover the depot scopes by filtering for the vehicle's
# name, and dress the surfaces with them.
#
# THE DIRECTORY TABLE IS DERIVED FROM THE INSTALL, not written down here. A
# hardcoded table is how this breaks: the reference implementation's list still
# names car/golfcart and helicopter/mh350, and NEITHER EXISTS in the current
# game. Scanning gives 37 real directories and matches 23 of the SDK's 28 by
# name; the rest are listed below with a reason, or reported as unmatched rather
# than guessed at.
#
# WHAT THIS DOES NOT DO YET: wheels, tracks, turrets and other separate parts.
# Those are stored AT THE ORIGIN and get their real positions from the base
# skeleton's bind pose (ske_veh_*_base.ebx), which is a reader this does not have
# yet. The base mesh is Skinned and its bind pose already carries hull, turret
# and barrel assembled, so a vehicle looks like itself without them - it is
# missing its wheels, not misplaced. Said out loud in the log rather than left
# for someone to notice.

const ART := "common/hardware/vehicles/"

# Only where a name cannot be matched by name. Each one needs a reason.
const OVERRIDES := {
	# The reference implementation maps these CROSSED, and it is not a typo:
	# the M1030 is dirtbike02 and the TMO450 is dirtbike01.
	"VEH_DirtBike_M1030": "motorcycle/dirtbike02",
	"VEH_DirtBike_TMO450": "motorcycle/dirtbike01",
	# "Stationary_" is an SDK prefix, not part of the asset name.
	"VEH_Stationary_BGM71TOW": "stationary/bgm71tow",
	"VEH_Stationary_GDF009": "stationary/gdf009",
}

# Names whose asset this cannot identify. Listed so they keep their proxy and
# say why, instead of being pointed at a plausible-looking neighbour: drawing a
# PTV where a golf cart belongs is a worse failure than drawing nothing, because
# it looks deliberate.
const UNRESOLVED := {
	"VEH_Golfcart": "the install has no car/golfcart; car/ptv is a different vehicle",
	"VEH_ScoutHelicopter_MH350": "the install has no helicopter/mh350; md530 and trv150 are both candidates and neither is confirmed",
	"VEH_Stationary_AutomaticAA": "several stationary AA mounts exist and none is confirmed as this one",
}

static var _dirs: Dictionary = {}      # VEH_ key -> "<class>/<name>", per source
static var _dirs_for := 0              # which game source _dirs was built from


# Is this key a vehicle we can draw? Returns "<class>/<name>" or "".
static func vehicle_for(gs, key: String) -> String:
	if not str(key).begins_with("VEH_"):
		return ""
	if UNRESOLVED.has(key):
		return ""
	_build_dirs(gs)
	return str(_dirs.get(key, ""))


# Why a vehicle we cannot draw is not drawn. "" when there is no reason to give.
static func unresolved_reason(key: String) -> String:
	return str(UNRESOLVED.get(key, ""))


# Scan the install once per game source for the vehicle art directories it
# actually has, and match the SDK's names against them.
static func _build_dirs(gs) -> void:
	if gs == null:
		return
	var id: int = gs.get_instance_id()
	if _dirs_for == id and not _dirs.is_empty():
		return
	_dirs = {}
	_dirs_for = id
	var have: Dictionary = {}
	# Snapshot: walking the live member races the catalogue republish.
	var t_res: Dictionary = gs.src.snap_res()
	for rn in t_res.keys():
		var n := str(rn)
		if not n.begins_with(ART):
			continue
		var bits := n.substr(ART.length()).split("/")
		if bits.size() >= 3 and bits[2] == "art":
			have["%s/%s" % [bits[0], bits[1]]] = true
	var missing := PackedStringArray()
	for f in DirAccess.get_files_at("res://objects/gameplay/vehicles"):
		var key := str(f).get_basename()
		if not key.begins_with("VEH_") or not str(f).ends_with(".tscn"):
			continue
		if OVERRIDES.has(key):
			if have.has(OVERRIDES[key]):
				_dirs[key] = OVERRIDES[key]
			continue
		if UNRESOLVED.has(key):
			continue
		var want := key.trim_prefix("VEH_").to_lower().replace("_", "")
		for d in have.keys():
			var leaf := str(d).get_file().replace("_", "")
			if leaf == want or want.begins_with(leaf) or leaf.begins_with(want):
				_dirs[key] = str(d)
				break
		if not _dirs.has(key):
			missing.append(key)
	if missing.size() > 0:
		# Not an error: a vehicle the install does not carry keeps its proxy.
		# Named so it is a fact rather than a mystery.
		HighpolyLog.info("vehicles: %d of the SDK's names matched an install "
			% _dirs.size() + "directory; no match for %s" % ", ".join(missing))


static func build(gs, key: String) -> Node3D:
	var dir := vehicle_for(gs, key)
	if gs == null or dir == "":
		return null
	var cls := dir.get_base_dir()          # tank
	var nm := dir.get_file()               # abrams
	var base := "%s%s/art/ob_veh_%s_%s_base" % [ART, dir, cls, nm]
	var res: String = gs.resolve_mesh(base)
	if res == "":
		HighpolyLog.warn("vehicle %s: no base mesh at %s" % [key, base])
		return null
	var scopes := _scopes_for(gs, nm)
	var scope: String = gs._scope_of(res)
	var m = gs.mesh_for("%s|%s|0" % [res, scope]) if scope != "" else gs.mesh_for(res)
	if m == null:
		HighpolyLog.warn("vehicle %s: %s did not build" % [key, res])
		return null
	# The bundle that SHIPPED the mesh goes on the end of the scope list. The
	# hull's record is not always in a bundle named after the vehicle - on the
	# Abrams the shell surface found nothing among the 21 scopes naming
	# "abrams" and drew with no material at all, which is the grey. Same fix as
	# the white tree: res_bundle knows who shipped it.
	if scope != "" and not scopes.has(scope):
		scopes.append(scope)
	_dress(gs, m, scopes)
	var root := Node3D.new()
	root.name = "HP_Vehicle_%s" % nm
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.name = "base"
	root.add_child(mi)
	mi.owner = null
	return root


# Every depot scope naming this vehicle. A few dozen out of ~17,000, so trying
# them is cheap, and the hash in the middle of the name cannot be derived.
static func _scopes_for(gs, nm: String) -> Array:
	var out: Array = []
	if not ("_depot_bundles" in gs):
		return out
	for k in gs._depot_bundles.keys():
		var ks := str(k)
		if ks.findn(nm) >= 0 and ks.ends_with("_bundle_3p"):
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
		# THE PART AFTER "@" IS THE PALETTE, NOT A VARIATION HASH.
		#
		# A surface is named "<state key>@<colour table entries>" - "7778057341
		# 684822587@0,1" - and this read the entries as a variation hash. int()
		# on "0,1" is 0, so the hash came out right by accident on every
		# single-entry surface and the PALETTE WAS THROWN AWAY on every
		# multi-entry one. Those are exactly the surfaces that came back with no
		# material at all: the Abrams hull, the Marauder body, the F22 fuselage.
		# Reported as "all of the vehicles are showing up grey".
		#
		# The reader already has the two parsers the props path uses. This is the
		# same bug in highpoly_weapon.gd, which is where it was copied from.
		var skey: int = gs._mkey(nm)
		var pal: PackedInt32Array = gs._mpal(nm)
		for sc in scopes:
			var mat = gs.material_for(skey, str(sc), 0, pal)
			if mat != null:
				am.surface_set_material(i, mat)
				break
