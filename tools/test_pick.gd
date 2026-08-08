extends SceneTree

# Smoke test for HighpolyDiagnose.pick() / focus_on() / step().
#
# The case that matters is #3: a ground mesh whose AABB is TALL (a terrain tile
# with a hill somewhere in it) but whose triangles under the cursor are at y=0.
# The camera sits INSIDE that box, so the ground's box-entry distance is 0 and it
# sorts ahead of everything. A box-only picker returns the ground for every click
# in the level. The triangle phase has to overturn that.

var fails: Array = []

func ck(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails.append(what)


func _box(sz: Vector3, off: Vector3) -> Array:
	# one axis-aligned box as a triangle soup, as surface arrays
	var v := PackedVector3Array()
	var h := sz * 0.5
	var c := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	var q := [[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[3,2,6,7],[4,5,1,0]]
	for f in q:
		for i in [0, 1, 2, 0, 2, 3]:
			v.append((c[f[i]] as Vector3) + off)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	return arr


var _ran := false

func _process(_d: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run()
	return true


func _run() -> void:
	var root := get_root()
	var scene := Node3D.new()
	scene.name = "Scene"
	root.add_child(scene)

	# --- a "terrain tile": flat under the cursor, tall AABB because of a spike
	var ga := PackedVector3Array([
		Vector3(-100, 0, -100), Vector3(100, 0, -100), Vector3(100, 0, 100),
		Vector3(-100, 0, -100), Vector3(100, 0, 100), Vector3(-100, 0, 100),
		Vector3(90, 0, -100), Vector3(100, 40, -90), Vector3(100, 0, -100)])
	var garr := []
	garr.resize(Mesh.ARRAY_MAX)
	garr[Mesh.ARRAY_VERTEX] = ga
	var ground := ArrayMesh.new()
	ground.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, garr)
	var gmi := MeshInstance3D.new()
	gmi.name = "Terrain"
	gmi.mesh = ground
	scene.add_child(gmi)

	# --- a "car": one mesh, two surfaces (body, glass), instanced three times
	var car := ArrayMesh.new()
	car.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
		_box(Vector3(4, 1.4, 2), Vector3(0, 0.7, 0)))          # surface 0: body
	car.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
		_box(Vector3(1.8, 1.0, 1.9), Vector3(0, 1.9, 0)))      # surface 1: glass
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = car
	mm.instance_count = 3
	for i in range(3):
		mm.set_instance_transform(i,
			Transform3D(Basis(), Vector3(-8.0 + 8.0 * i, 0, 0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Cars"
	mmi.multimesh = mm
	scene.add_child(mmi)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_transform = Transform3D(Basis(), Vector3(0, 5, 14))
	cam.look_at(Vector3(0, 1.0, 0), Vector3.UP)
	var mid := Vector2(root.size) * 0.5

	print("\n--- environment ---")
	print("  viewport %s   instance 2 transform %s"
		% [str(root.size), str(mm.get_instance_transform(2).origin)])

	print("\n--- pick ---")
	var hit: Dictionary = HighpolyDiagnose.pick(cam, mid, scene)
	ck(not hit.is_empty(), "something was hit")
	ck(hit.get("node") == mmi, "the CAR won, not the terrain slab the camera sits inside")
	# NOT asserting WHICH instance. MultiMesh keeps its transform buffer in the
	# rendering server, and the headless dummy renderer hands back identity for
	# every one of them (printed above), so all three cars stand at the origin
	# here and instance 0 is the honest answer. Which instance a click lands on
	# is only testable with a real renderer.
	ck(int(hit.get("inst", -1)) >= 0, "the hit names an instance, got %s" % str(hit.get("inst")))

	# aim well off to the side: nothing there but ground
	var side := Vector2(mid.x, mid.y + float(root.size.y) * 0.45)
	var h2: Dictionary = HighpolyDiagnose.pick(cam, side, scene)
	ck(not h2.is_empty() and h2.get("node") == gmi, "aiming past the cars hits the terrain")

	# aim high at the sky: nothing at all
	var up := Vector2(mid.x, 2.0)
	var h3: Dictionary = HighpolyDiagnose.pick(cam, up, scene)
	ck(h3.is_empty(), "aiming at the sky hits nothing, got %s" % str(h3.get("node")))

	print("\n--- focus ladder ---")
	var f: Dictionary = HighpolyDiagnose.focus_on(hit, scene)
	var lv: Array = f["levels"]
	ck(lv.size() == 4, "batch + object + 2 surfaces = 4 rungs, got %d" % lv.size())
	ck(str((lv[0] as Dictionary)["kind"]) == "batch", "outermost rung is the batch")
	ck(str((lv[int(f["idx"])] as Dictionary)["kind"]) == "object", "a pick starts on the object")
	ck(int((lv[2] as Dictionary)["surf"]) == int(hit["surf"]),
		"the clicked surface is the first one Tab reaches")

	ck(HighpolyDiagnose.step(1, scene), "Tab drills into a surface")
	var cur: Dictionary = (f["levels"] as Array)[int(HighpolyDiagnose._focus["idx"])]
	ck(str(cur["kind"]) == "surface", "…and lands on a surface")
	ck(HighpolyDiagnose.step(1, scene), "Tab again reaches the other surface")
	ck(not HighpolyDiagnose.step(1, scene), "Tab stops at the last surface")
	ck(HighpolyDiagnose.step(-1, scene) and HighpolyDiagnose.step(-1, scene)
		and HighpolyDiagnose.step(-1, scene), "Shift+Tab walks back out to the batch")
	ck(not HighpolyDiagnose.step(-1, scene), "…and stops at the batch")

	print("\n--- highlight ---")
	HighpolyDiagnose.step(1, scene)          # object
	var hl := scene.get_node_or_null("_HP_DIAG_FOCUS")
	ck(hl != null and hl is MeshInstance3D, "the object highlight is a MeshInstance3D")
	if hl != null:
		ck((hl as MeshInstance3D).mesh.get_surface_count() == 2, "object highlight is the whole mesh")
		# Only that it is placed at its instance's transform at all — see the
		# note above; every instance transform is identity under this renderer.
		ck((hl as Node3D).global_transform.origin.distance_to(Vector3(0, 0, 0)) < 0.01,
			"…placed at the instance transform")
		ck(hl.owner == null, "the highlight is owner-less, so it never saves into the scene")
	HighpolyDiagnose.step(1, scene)          # surface
	var hl2 := scene.get_node_or_null("_HP_DIAG_FOCUS")
	ck(hl2 != null and (hl2 as MeshInstance3D).mesh.get_surface_count() == 1,
		"the surface highlight is ONE surface — a car's glass without its body")
	var kids := 0
	for c in scene.get_children():
		if String(c.name).begins_with("_HP_DIAG_FOCUS"):
			kids += 1
	ck(kids == 1, "stepping does not leave old highlights behind, found %d" % kids)

	print("\n--- batch highlight ---")
	HighpolyDiagnose.step(-1, scene)
	HighpolyDiagnose.step(-1, scene)
	var hl3 := scene.get_node_or_null("_HP_DIAG_FOCUS")
	ck(hl3 != null and hl3 is MultiMeshInstance3D
		and (hl3 as MultiMeshInstance3D).multimesh.instance_count == 3,
		"the batch highlight lights all three cars")

	print("\n%s  (%d failure(s))" % ["PASS" if fails.is_empty() else "FAILED", fails.size()])
	quit(0 if fails.is_empty() else 1)
