@tool
extends SceneTree

# Build both faction soldiers out of the installation and measure them.
#
# The parts are identity-placed in one shared bind-pose space, so the check that
# matters is not "did a mesh load" but "do they STACK": a headgear that lands at
# the origin instead of on the shoulders means the shared-space assumption is
# wrong, and that reads as a bug only if someone measures it.
#
#   godot --headless --path <proj> --script test_soldier.gd

func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath"):
		print("could not open the game source")
		quit(1)
		return

	var bad := 0
	for faction in ["alliance", "pax"]:
		var root := HighpolySoldier.build(gs, faction)
		print("\n=== %s (%s)" % [faction.to_upper(), HighpolySoldier.WEARER[faction]])
		if root == null:
			print("   BUILD RETURNED NULL")
			bad += 1
			continue
		var whole := AABB()
		var first := true
		var tris := 0
		for c in root.get_children():
			var mi := c as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			var ab := mi.mesh.get_aabb()
			var n := 0
			for si in range(mi.mesh.get_surface_count()):
				n += mi.mesh.surface_get_array_len(si)
			tris += n
			print("   %-34s y %6.2f .. %6.2f   surfaces %d   override %s"
				% [mi.name, ab.position.y, ab.position.y + ab.size.y,
				   mi.mesh.get_surface_count(),
				   "yes" if mi.material_override != null else "-"])
			whole = ab if first else whole.merge(ab)
			first = false
		if first:
			print("   NO MESHES")
			bad += 1
			continue
		print("   whole soldier: y %.2f .. %.2f  (height %.2f m), %d verts"
			% [whole.position.y, whole.position.y + whole.size.y, whole.size.y, tris])
		# a soldier is between 1.6 and 2.1 m and stands on the origin
		if whole.size.y < 1.5 or whole.size.y > 2.2:
			print("   SUSPECT height %.2f m" % whole.size.y)
			bad += 1
		if absf(whole.position.y) > 0.15:
			print("   SUSPECT does not stand on the origin (%.2f)" % whole.position.y)
			bad += 1
		root.queue_free()

	print("\n%s" % ("OK" if bad == 0 else "%d problem(s)" % bad))
	quit(1 if bad else 0)
