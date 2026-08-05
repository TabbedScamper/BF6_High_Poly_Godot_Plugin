extends SceneTree

# _load_external_glb used to return a PackedScene and now returns a LIVE node
# the caller owns. Three places consume it and only one of them — the props
# path — is exercised by the other tests. The other two are roads (adopts the
# node straight into the scene tree) and the vegetation scatter (reads one mesh
# off it and frees it), and both are per-map: a map with no roads.glb or no
# scatter.json never touches them, so a break there would show up on SOME maps
# and not on the one being tested.
#
# Ownership is the thing that can go wrong quietly. A node returned already
# parented cannot be add_child'd; a node the caller forgets to free leaks a full
# scene per prop; a mesh read off a node that is then freed must survive, since
# Resources are refcounted and Nodes are not.
#
# Run with "-- <dir of .glb>" to point it at a sample.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const Scatter = preload("res://addons/highpoly_toggle/highpoly_scatter.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var files := _glbs()
	if files.is_empty():
		print("no glbs to test against"); quit(1); return

	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame
	mc.vram_mode = MC.VRAM_COMPRESSED

	# ---- what the loader hands back ---------------------------------------
	var n0: Node = mc._load_external_glb(str(files[0]))
	_check("returns a Node", n0 != null and is_instance_valid(n0))
	if n0 == null:
		_done(); return
	_check("the node is an ORPHAN, so a caller can add_child it",
		not n0.is_inside_tree() and n0.get_parent() == null)
	_check("it is a Node3D with geometry under it", _count_meshes(n0) > 0)

	# ---- the roads path: adopt it into the tree ---------------------------
	var host := Node3D.new()
	get_root().add_child(host)
	n0.name = "Roads"
	host.add_child(n0)
	n0.owner = null
	_check("adopting it into a scene tree works", n0.is_inside_tree())
	var layered := 0
	var stack: Array = [n0]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		for cc in c.get_children():
			stack.append(cc)
		if c is GeometryInstance3D:
			(c as GeometryInstance3D).layers = 2
			layered += 1
	_check("its GeometryInstance3D children are reachable and settable (%d)" % layered,
		layered > 0)
	host.queue_free()

	# ---- the scatter path: one mesh off it, then free the node ------------
	# the mesh has to outlive the node it came from, or the scatter caches a
	# freed resource and every blade of grass on the map disappears
	var n1: Node = mc._load_external_glb(str(files[0]))
	var pair: Array = mc._first_mesh_and_xf(n1, Transform3D())
	var kept: Mesh = null
	if not pair.is_empty():
		kept = mc._bake_mesh(pair[0], pair[1])
		if kept == pair[0]:
			kept = kept.duplicate()
	n1.free()
	_check("a mesh read off the node survives freeing the node",
		kept != null and is_instance_valid(kept) and kept.get_surface_count() > 0)
	if kept != null:
		var tris := 0
		for s in range(kept.get_surface_count()):
			var arr := kept.surface_get_arrays(s)
			if not arr.is_empty() and arr[Mesh.ARRAY_VERTEX] != null:
				tris += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		_check("and still carries its vertices (%d)" % tris, tris > 0)

	# ---- prefetched and unprefetched must be interchangeable --------------
	# roads and scatter never go through the prefetch, so they always take the
	# uncached branch; props usually take the cached one. Both must behave the
	# same way to their caller.
	mc._pf_release()
	await mc._prefetch([str(files[0])])
	var n2: Node = mc._load_external_glb(str(files[0]))
	_check("a prefetched node is an orphan too",
		n2 != null and is_instance_valid(n2) and not n2.is_inside_tree())
	_check("a prefetched node has the same mesh count as a fresh parse",
		n2 != null and _count_meshes(n2) == _count_meshes_of(mc, str(files[0])))
	if n2 != null:
		n2.free()

	# ---- releasing an unclaimed batch -------------------------------------
	mc._pf_release()
	var some: Array = files.slice(0, mini(4, files.size()))
	await mc._prefetch(some)
	_check("prefetch filled the cache (%d)" % mc._pf.size(), mc._pf.size() == some.size())
	mc._pf_release()
	_check("releasing an unclaimed batch empties it", mc._pf.is_empty())

	_done()


func _done() -> void:
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _count_meshes(n: Node) -> int:
	var c := 0
	var stack: Array = [n]
	while not stack.is_empty():
		var x: Node = stack.pop_back()
		for cc in x.get_children():
			stack.append(cc)
		if x is MeshInstance3D and (x as MeshInstance3D).mesh != null:
			c += 1
	return c


func _count_meshes_of(mc, p: String) -> int:
	var n: Node = mc._load_external_glb_uncached(p)
	if n == null:
		return -1
	var c := _count_meshes(n)
	n.free()
	return c


func _glbs() -> Array:
	var base := OS.get_environment("APPDATA") + "/Godot/app_userdata/Battlefield™ Portal Project"
	var dirs: Array = []
	for a in OS.get_cmdline_user_args():
		dirs.append(str(a))
	dirs.append(base + "/mapcontext/_props")
	for d in dirs:
		var da := DirAccess.open(str(d))
		if da == null:
			continue
		var out: Array = []
		for f in da.get_files():
			if f.ends_with(".glb"):
				out.append(str(d) + "/" + f)
		if not out.is_empty():
			out.sort()
			return out
	return []


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
