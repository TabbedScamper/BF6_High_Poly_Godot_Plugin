extends SceneTree

# _tris() called ArrayMesh-only methods on any Mesh. On a PlaneMesh that THROWS
# rather than returning zero, and the throw escaped _attribute(), abandoning the
# whole scan — so a third of a 17-minute recording's attribution silently went
# missing while the report still printed. A parse check cannot see this; only
# calling it with a primitive can.

const P = preload("res://addons/highpoly_toggle/highpoly_profiler.gd")

var fails := 0


func _init() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	var box := BoxMesh.new()
	var sphere := SphereMesh.new()

	var arr := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
			Vector3(1, 1, 0), Vector3(2, 0, 0), Vector3(2, 1, 0)]:
		st.add_vertex(v)
	st.commit(arr)

	_check("PlaneMesh does not throw and reports triangles", P._tris(plane) > 0)
	_check("BoxMesh reports triangles", P._tris(box) > 0)
	_check("SphereMesh reports triangles", P._tris(sphere) > 0)
	_check("ArrayMesh reports its 2 triangles", P._tris(arr) == 2)
	_check("null mesh is 0, not a crash", P._tris(null) == 0)
	# second call must come from the cache and agree with the first
	_check("cached result matches", P._tris(plane) == P._tris(plane))

	print("  plane=%d box=%d sphere=%d arraymesh=%d"
		% [P._tris(plane), P._tris(box), P._tris(sphere), P._tris(arr)])
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
