@tool
extends SceneTree

# CAN THE PLUGIN SEE A VEHICLE AT ALL, and if not, is the geometry reachable by
# another route?
#
# Nothing in the addon mentions VehicleSpawner or VEH_, so a vehicle dropped in
# the scene gets no overlay. This asks the two questions that decide how much
# work fixing that is:
#
#   1. does the prop route (has_object on the scene's basename) resolve?
#   2. is the mesh reachable by name under common/hardware/vehicles/?
#
#   --headless --script tools/probe_vehicle.gd

const DIRS := {
	"VEH_Abrams": "tank/abrams",
	"VEH_Cheetah": "tank/cheetah",
	"VEH_AH6M": "helicopter/ah6m",
	"VEH_F22": "airplane/f22",
	"VEH_Marauder": "car/marauder",
}


func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	if not gs.open_map("MP_Dumbo", "", Callable(), {"placements": false}):
		print("open failed: ", gs.error); quit(1); return
	gs.upgrade_catalogue()
	print("catalogue ready: %s, %d ebx\n" % [gs.catalogue_ready, gs.src.ebx.size()])

	print("=== 1. THE PROP ROUTE, which is what a placed scene uses ===")
	for k in DIRS.keys():
		print("  %-22s has_object: %s" % [k, gs.has_object(k)])

	print("\n=== 2. IS THE GEOMETRY THERE UNDER ANOTHER NAME ===")
	for k in DIRS.keys():
		var dir: String = "common/hardware/vehicles/%s/art/" % DIRS[k]
		# every res under this vehicle's art directory
		var meshes: Array = []
		var depots: Array = []
		var stem := str(DIRS[k]).get_file()
		for rn in gs.src.res.keys():
			var n := str(rn)
			if n.begins_with(dir):
				meshes.append(n)
		for b in gs._depot_bundles.keys():
			if str(b).contains(stem):
				depots.append(str(b))
		print("  %-22s %d res under %s" % [k, meshes.size(), dir])
		for m in meshes.slice(0, 4):
			print("      %s" % m)
		if meshes.size() > 4:
			print("      ... +%d more" % (meshes.size() - 4))
		print("      %d depot scopes naming '%s'" % [depots.size(), stem])
		for d in depots.slice(0, 2):
			print("      scope: %s" % d)
		# the base mesh, resolved the way a prop's mesh is
		var base := "%sob_veh_%s_%s_base" % [dir, str(DIRS[k]).get_base_dir(), stem]
		var got := gs.resolve_mesh(base)
		print("      resolve_mesh(%s) -> %s" % [base.get_file(), got if got != "" else "NOTHING"])
		print("")
	quit(0)
