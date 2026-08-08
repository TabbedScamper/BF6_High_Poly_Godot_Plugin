extends SceneTree

# Can the object library be built from the game instead of downloaded?
#
# The library replaces the SDK's grey proxy on objects the USER places, and it
# has always been a download: GLBs baked by the pipeline and fetched from a
# registry. Every one of them was assembled from a pf_portal_<name> prefab in
# the game, so the question is whether that assembly can happen in the editor
# instead of ahead of time.
#
# What has to be true, in order:
#   1. the prefab resolves by name at all
#   2. walking it yields member rows with meshes that resolve to MeshSets
#   3. the members have DIFFERENT transforms — a composite whose parts all sit
#      at the origin is the failure that still produces a plausible-looking
#      single blob, and it is what a naive assembler produces
#   4. the assembled node has real geometry with a sane size
#
#   godot --headless --path <proj> --script test_objects.gd -- [level] [names...]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")

# A deliberate spread: a composite wreck (the one NOFIT is hardcoded for), a
# building, a vehicle, and small props.
const DEFAULT_NAMES := ["WreckTank_Abra01", "WreckCar_Sedan01", "Container_01",
	"Barrier_Concrete_01", "Crate_01", "Sandbag_01"]


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var names: Array = []
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			names.append(s)
	if names.is_empty():
		names = DEFAULT_NAMES.duplicate()

	var gs = HighpolyGameSource.new()
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return

	# How many pf_portal_* prefabs does this mount even carry? If the answer is
	# zero the whole approach is wrong, and that is worth knowing before any
	# individual name is blamed for not resolving.
	var n_pf := 0
	var samples: Array = []
	for k in gs.walk.by_name.keys():
		var s := str(k)
		if s.get_file().begins_with(HighpolyGameSource.PORTAL_PREFIX):
			n_pf += 1
			if samples.size() < 8:
				samples.append(s.get_file())
	print("mount carries %d pf_portal_* prefabs" % n_pf)
	for s in samples:
		print("   %s" % s)
	if n_pf == 0:
		print("\nFAIL: no Portal prefabs in this mount — the object library")
		print("      cannot be assembled from it")
		quit(1); return

	print("\nassembling %d object(s):" % names.size())
	var built := 0
	var missing := 0
	var flat := 0
	for nm in names:
		var name := str(nm)
		if not gs.has_object(name):
			print("   %-26s no prefab" % name)
			missing += 1
			continue
		var t0 := Time.get_ticks_msec()
		var rows: Array = gs.object_rows(name)
		var node: Node3D = gs.object_node(name)
		var ms := Time.get_ticks_msec() - t0
		if node == null:
			print("   %-26s prefab found, no geometry" % name)
			missing += 1
			continue
		built += 1
		# Distinct transforms: a composite whose members share one transform has
		# been assembled wrongly in a way that still renders.
		var distinct := {}
		for r in rows:
			distinct[str((r["xf"] as Transform3D).origin)] = true
		var aabb := AABB()
		var first := true
		for c in node.get_children():
			var mi := c as MeshInstance3D
			var b: AABB = (mi.mesh as Mesh).get_aabb()
			b = mi.transform * b
			aabb = b if first else aabb.merge(b)
			first = false
		if rows.size() > 1 and distinct.size() == 1:
			flat += 1
		print("   %-26s %2d member(s), %2d distinct pos, %.1f x %.1f x %.1f m, %d ms"
			% [name, rows.size(), distinct.size(), aabb.size.x, aabb.size.y,
			   aabb.size.z, ms])
		node.queue_free()

	print("\n%d assembled, %d with no prefab, %d suspicious (members stacked at one point)"
		% [built, missing, flat])
	var fail := 0
	if built == 0:
		print("FAIL: nothing assembled")
		fail += 1
	if flat > 0:
		print("FAIL: %d composite(s) put every member at the same place" % flat)
		fail += 1
	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)
