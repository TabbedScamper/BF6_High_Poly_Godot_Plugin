@tool
extends RefCounted

# NO class_name ON PURPOSE. This file arrives through the staged lane, which
# copies scripts in and re-enables the plugin without a filesystem rescan, so a
# global class registered here is not guaranteed to resolve when the code that
# uses it parses. An unresolved identifier is not a broken feature, it is a
# plugin that fails to load at all. The caller does load(PATH).new() instead,
# which resolves when it is actually called.

# RE-PROJECT THE ROAD DECALS ONTO THE PROPS THEY LIE ON.
#
# THE DEFECT. roads() drapes every decal vertex on the TERRAIN heightfield and
# nothing else:
#
#     verts.push_back(Vector3(x, clampf(_height_at(x, z), ylo, yhi)
#         + ROAD_Y_BIAS, z))
#
# The engine does not do that. Decal vertices carry world X and Z and NO Y at
# all; the game lays them on whatever surface is beneath them - terrain OR a
# prop - and draws them with depth-write off. So every marking that belongs on a
# sidewalk slab, a plaza deck or a ramp is placed at the height of the DIRT
# UNDER that prop and disappears inside it. The record AABB clamp added for the
# rooftop tennis court gets the elevated records into the right BAND, which is
# why they are not metres out, but a band is not a surface: within it the decal
# still tracks the terrain rather than the thing it is painted on.
#
# THE RULE THAT MATTERS, in the user's words: "The projections are close to the
# props so be sure your not projecting to a rooftop when it should be on the
# first floor where it was very close to the ground." So this NEVER takes the
# topmost surface. For each vertex it takes the candidate surface NEAREST THE
# HEIGHT THE VERTEX ALREADY HAS - the terrain drape is the hint that says which
# storey we are on - and only within a window. A road under a flyover stays on
# the road, and a marking on a ground-floor deck never climbs the building.
#
# WHY A TRIANGLE INDEX AND NOT A RAYCAST. Raycasting needs collision shapes,
# which the props do not carry and would cost more to build than this whole
# pass. Instead the near-horizontal prop triangles near the decals are bucketed
# into an XZ grid once, and each vertex is solved against the few triangles in
# its own cell by barycentric containment. That evaluates the real triangle
# plane at the vertex's exact X/Z, so a sloped ramp or a cambered deck comes out
# smooth rather than stepped to the grid.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH. Draw order. The record chain gives the
# authored paint order and roads() already turns it into per-group priorities;
# lifting a vertex does not reorder anything. And a vertex with no prop under it
# keeps its terrain height exactly, so a map with no decals on props is
# unchanged bit for bit.

# The XZ bucket. Small enough that a cell holds a handful of triangles, large
# enough that a city block's worth of sidewalk does not explode the dictionary.
const CELL := 2.0

# The reject grid's cell. Big enough that an ordinary prop touches one or two
# of them, so throwing it out costs a couple of dictionary lookups instead of
# a sweep over the fine grid.
const COARSE := 16.0

# How far a prop surface may be from the vertex's terrain-draped height and
# still be considered the surface it is painted on. This is the rooftop guard:
# a sidewalk slab sits centimetres above the dirt and a first-floor deck a metre
# or two, while the roof that must never be chosen is storeys away.
const WINDOW := 2.5

# How far outside the record's AUTHORED band a prop surface may still be and
# count as the thing the decal is painted on. Not zero: our rebuilt ground does
# not match the shipped ground exactly, and a band held to the millimetre would
# reject the sidewalks this exists to catch.
const BAND_MARGIN := 0.6

# A decal sitting exactly ON a prop face is coplanar with it, which z-fights.
# Slightly more than the terrain drape's own bias because prop faces are flat
# and perfectly parallel to the decal, where terrain is not.
# A HAIR, not a gap. This was 0.02 - two centimetres of clear air above the
# face, which reads as the marking hovering. Four millimetres is enough to win
# the depth fight against a coplanar surface and far too little to see.
const PROP_Y_BIAS := 0.004

# Only surfaces you could walk on. 0.5 keeps ramps and cambered decks and
# rejects walls, which would otherwise catch vertices at their base.
const MIN_NORMAL_Y := 0.5

# The per-mesh prefilter's threshold, deliberately looser than the real test
# above. Rotation about Y - which is very nearly all prop placement - leaves a
# normal's Y component untouched, so a local-space test is exact for those and
# only approximate for a prop tipped over. The slack is there so the
# approximation can only ever admit too much, never discard a real receiver.
const PREFILTER_NORMAL_Y := 0.3

# A single triangle spanning half the map is a ground plane, not a sidewalk,
# and rasterising it would touch every cell. Bounded rather than dropped by
# size: the cap is what stops the pathological case, and a genuinely large
# flat plaza still gets its cells.
const MAX_CELLS_PER_TRI := 4096

# YIELD BUDGET: work this long, then give the editor a frame.
#
# It was 12 ms, chosen to keep the editor alive, and it made the editor the
# bottleneck. Measured 2026-08-13 on MP_Aftermath: 945 yields at 39.2 ms each,
# so the pass ran at a 24% duty cycle and spent 37.0 s of a 57.9 s run parked
# in `await` against 20.9 s of its own work. Twelve milliseconds of work per
# thirty-nine of waiting is not responsiveness, it is idling.
#
# 40 ms with the props hidden for the pass (see _reproject_roads): a yield now
# draws the ground and the markings rather than fifteen thousand prop draws,
# so the editor stays about as responsive as it was at 12 ms against a full
# scene while the pass gets most of its wall time back.
const MS_PER_FRAME := 40

# HOW LONG THE INDEX MAY SPEND, because get_faces() copies a mesh's entire
# triangle list and a map has thousands of props. The bounding-box and cell
# rejects below are what keep this far under the cap in practice; the cap is
# the guarantee that a map which defeats them costs a wait rather than an
# afternoon. NOT SILENT: whatever it stops short of is counted and reported,
# because a partial index and a complete one look identical on screen.
# Raised now that the reject is a coarse-grid lookup rather than a sweep of the
# fine grid. At 20 s this was stopping with 7,750 nodes unread on the user's
# map, which left most of the network draped on terrain and looked like a
# projection that only worked in places.
const MAX_INDEX_MS := 60000

var stats := {}

# Reported so the user is not left watching a finished-looking build change by
# itself a minute later. Optional: unset, the pass is silent as before.
var progress_fn := Callable()

var _tri := PackedFloat32Array()      # stride 9: ax az bx bz cx cz ay by cy
var _cells := {}                      # cell key -> PackedInt32Array of tri idx
var _cov := {}                        # cell key -> Vector2(minY, maxY) of decals
# THE SAME COVERAGE AT 16 m, for rejecting whole props. _cov holds a cell per
# two metres of road network - half a million entries on a real map - and
# sampling it per prop instance is what spent the index's whole time budget
# before it had read a third of the props.
var _cov16 := {}
# Mesh RID -> its triangles and bounding box, read once. Props arrive as
# MultiMeshes sharing one mesh across hundreds of transforms, and get_faces()
# copies the entire triangle array on every call.
var _faces := {}
var _boxes := {}

var _walked := 0

# WHERE THE MINUTE GOES, split three ways. This pass costs the same cold and
# warm, so it is neither reading the game nor missing a cache, and the two
# remaining candidates - starved by its own yield budget, or spending the time
# per vertex in GDScript - want completely different fixes. Measured rather
# than argued: guessing between two plausible causes has convicted innocent
# code on this project before.
var _await_us := 0            # inside `await tree.process_frame`
var _yields := 0
var _index_us := 0            # the whole index phase, awaits included
var _solve_us := 0            # the whole vertex phase, awaits included
var _await_index_us := 0      # of _await_us, the half spent in the index

var _xmin := 0.0
var _xmax := 0.0
var _zmin := 0.0
var _zmax := 0.0


static func _key(xi: int, zi: int) -> int:
	# 64-bit ints, so a plain pair pack is exact. Offset because map coordinates
	# are signed and a raw shift of a negative would collide.
	return (xi + 1048576) * 4194304 + (zi + 1048576)


# The whole pass. Returns a stats dictionary; never throws, never leaves the
# mesh half-rewritten (the new arrays are built complete, then swapped in).
func run(tree: SceneTree, roads_mi: MeshInstance3D,
		props_root: Node3D) -> Dictionary:
	stats = {"lifted": 0, "vertices": 0, "tris": 0, "instances": 0,
		"skipped_instances": 0, "surfaces": 0, "ms": 0}
	if roads_mi == null or props_root == null:
		return stats
	var t0 := Time.get_ticks_msec()

	# THE TERRAIN DRAPE IS THE SOURCE, ALWAYS. Kept on the node the first time
	# through so a second run (the user rebuilds objects, or switches a layer)
	# re-projects the original heights instead of lifting already-lifted
	# vertices onto themselves and creeping upward every pass.
	var base: Mesh = roads_mi.get_meta("hp_drape_mesh", null) as Mesh
	if base == null:
		base = roads_mi.mesh
		roads_mi.set_meta("hp_drape_mesh", base)
	if not (base is ArrayMesh):
		return stats

	var src := base as ArrayMesh
	var surfaces: Array = []
	for i in range(src.get_surface_count()):
		surfaces.append(src.surface_get_arrays(i))
	if surfaces.is_empty():
		return stats

	if not _coverage(surfaces):
		return stats
	var t_ix := Time.get_ticks_usec()
	await _index_props(tree, props_root)
	_index_us = Time.get_ticks_usec() - t_ix
	_await_index_us = _await_us
	if _tri.is_empty():
		stats["ms"] = Time.get_ticks_msec() - t0
		return stats

	var out := ArrayMesh.new()
	var t_sv := Time.get_ticks_usec()
	var frame := Time.get_ticks_msec()
	for i in range(surfaces.size()):
		var arr: Array = surfaces[i]
		# FILLS PROJECT TOO, and they are the point. A fill record is the road
		# SURFACE - a terrain layer's own material, drawn opaque - and a
		# receiver is a surface with no albedo of its own, which exists to wear
		# the ground. The fill IS what it is supposed to be wearing; the
		# ground-blend shader is only a metre-per-texel stand-in for it.
		#
		# These were held back when I thought an opaque fill was what made a
		# sidewalk top vanish. It was the discard shader, and the exclusion
		# outlived the reason for it. The worry behind it is also gone: back
		# then the projector accepted ANY flat prop surface, so an opaque fill
		# could repaint a crate lid. It now only ever considers receivers, and
		# a receiver has nothing of its own to repaint.
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var moved := PackedVector3Array()
		moved.resize(verts.size())
		# The authored band per vertex, laid down by the drape. Absent on a
		# mesh built by an older version, in which case every surface is
		# allowed through and this behaves exactly as it did before.
		var bands: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV2] \
			if arr[Mesh.ARRAY_TEX_UV2] is PackedVector2Array \
			else PackedVector2Array()
		if bands.size() != verts.size():
			bands = PackedVector2Array()
			stats["no_band"] = int(stats.get("no_band", 0)) + 1
		# BY TRIANGLE, NOT BY VERTEX. Moving corners independently tilts a
		# triangle that straddles a kerb - one corner up on the sidewalk, two
		# still on the road - and it slices down through the ground between
		# them. A decal is a surface lying ON something; a triangle with
		# corners on two different surfaces is not lying on either.
		#
		# Safe because the roads mesh is emitted UNINDEXED (the index buffer is
		# the identity), so consecutive triples are triangles and no vertex is
		# shared between them. Anything else falls back to the old per-vertex
		# behaviour rather than silently mangling the mesh.
		var by_tri := (verts.size() % 3) == 0
		var vi := 0
		while vi < verts.size():
			var step := 3 if by_tri else 1
			var ys := PackedFloat64Array()
			var hits := 0
			var sum := 0.0
			for k in range(step):
				var v := verts[vi + k]
				var lo := -INF
				var hi := INF
				if not bands.is_empty():
					lo = bands[vi + k].x - BAND_MARGIN
					hi = bands[vi + k].y + BAND_MARGIN
				var y := _surface_under(v.x, v.z, v.y, lo, hi)
				ys.push_back(y)
				if y != INF:
					hits += 1
					sum += y
			# EACH CORNER TAKES ITS OWN HEIGHT. Giving a corner that found
			# nothing the MEAN of the ones that did laid the triangle flat at
			# pavement height, so where it straddled a kerb its outer edge hung
			# in the air over the road. Keeping each corner where its own
			# surface is means the triangle bends down over the kerb and cuts
			# into it instead - on top, clipping in at the edge, never floating.
			#
			# Bending is what the all-three-corners rule existed to prevent, and
			# it is affordable now only because the decals are subdivided to
			# one or two metres: at that size the bend over a 0.15 m kerb is a
			# chamfer, where at eight metres it was a blade through the ground.
			for k in range(step):
				var v := verts[vi + k]
				if ys[k] == INF:
					moved[vi + k] = v
				else:
					moved[vi + k] = Vector3(v.x, ys[k] + PROP_Y_BIAS, v.z)
					stats["lifted"] = int(stats["lifted"]) + 1
			if hits > 0 and hits < step:
				# Laid flat at the receiver's height across a boundary, so its
				# outer edge floats by the kerb height rather than dropping to
				# the road. If this reads badly the answer is finer
				# subdivision near receivers, not a stricter rule.
				stats["straddling"] = int(stats.get("straddling", 0)) + 1
			vi += step
			if (vi & 2047) < step \
					and Time.get_ticks_msec() - frame > MS_PER_FRAME:
				if progress_fn.is_valid():
					progress_fn.call("laying the decals onto them",
						vi, verts.size())
				var ya := Time.get_ticks_usec()
				await tree.process_frame
				_await_us += Time.get_ticks_usec() - ya
				_yields += 1
				if not is_instance_valid(roads_mi):
					return stats
				frame = Time.get_ticks_msec()
		stats["vertices"] = int(stats["vertices"]) + verts.size()
		arr[Mesh.ARRAY_VERTEX] = moved
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1,
			src.surface_get_material(i))
	stats["surfaces"] = out.get_surface_count()
	_solve_us = Time.get_ticks_usec() - t_sv
	if is_instance_valid(roads_mi):
		roads_mi.mesh = out
	stats["ms"] = Time.get_ticks_msec() - t0
	# THE SPLIT. index vs solve are wall time including their own awaits;
	# await_ms is how much of the total was spent parked in
	# `await tree.process_frame` waiting for the editor to draw the map. What
	# is left is this script's own work, and the two want opposite fixes.
	stats["index_ms"] = _index_us / 1000
	stats["solve_ms"] = _solve_us / 1000
	stats["await_ms"] = _await_us / 1000
	stats["await_index_ms"] = _await_index_us / 1000
	stats["await_solve_ms"] = (_await_us - _await_index_us) / 1000
	stats["yields"] = _yields
	stats["work_ms"] = (_index_us + _solve_us - _await_us) / 1000
	return stats


# Where the decals are, and at what height. Both halves are needed: the XZ
# extent throws out every prop that cannot possibly matter before its geometry
# is read at all, and the per-cell height band is what lets a roof triangle be
# rejected without ever solving it.
func _coverage(surfaces: Array) -> bool:
	var any := false
	for arr in surfaces:
		var verts: PackedVector3Array = (arr as Array)[Mesh.ARRAY_VERTEX]
		for v in verts:
			if not any:
				_xmin = v.x; _xmax = v.x; _zmin = v.z; _zmax = v.z
				any = true
			else:
				_xmin = minf(_xmin, v.x); _xmax = maxf(_xmax, v.x)
				_zmin = minf(_zmin, v.z); _zmax = maxf(_zmax, v.z)
			var k16 := _key(int(floor(v.x / COARSE)), int(floor(v.z / COARSE)))
			var b16: Variant = _cov16.get(k16)
			if b16 == null:
				_cov16[k16] = Vector2(v.y, v.y)
			else:
				var bb16: Vector2 = b16
				_cov16[k16] = Vector2(minf(bb16.x, v.y), maxf(bb16.y, v.y))
			var k := _key(int(floor(v.x / CELL)), int(floor(v.z / CELL)))
			var b: Variant = _cov.get(k)
			if b == null:
				_cov[k] = Vector2(v.y, v.y)
			else:
				var bb: Vector2 = b
				_cov[k] = Vector2(minf(bb.x, v.y), maxf(bb.y, v.y))
	return any


func _index_props(tree: SceneTree, props_root: Node3D) -> void:
	var frame := Time.get_ticks_msec()
	var started := frame
	var stack: Array = [props_root]
	while not stack.is_empty():
		if Time.get_ticks_msec() - started > MAX_INDEX_MS:
			# COUNTED, NOT SWALLOWED. The caller journals this, so a map whose
			# markings come out right in one district and sunk in another names
			# its own cause instead of looking like a projection bug.
			stats["index_truncated"] = stack.size()
			return
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		# THE LONG PHASE, and it used to report nothing. Reading the receiver
		# surfaces off every prop is most of this pass's wall time; without a
		# lane of its own the wait was indistinguishable from a hang.
		_walked += 1
		if progress_fn.is_valid() and (_walked & 255) == 0:
			progress_fn.call("finding the surfaces that take a decal",
				_walked, _walked + stack.size())
		if n is MultiMeshInstance3D:
			var mmi := n as MultiMeshInstance3D
			var mm := mmi.multimesh
			# ONE TEST FOR THE WHOLE GROUP. This walked all 36,159 instances of
			# a map individually and spent its entire time budget doing it. A
			# MultiMesh knows its combined bounds, and most of a map's props are
			# nowhere near a road, so the great majority are thrown out here in
			# a single test instead of one per instance.
			if mm != null and mm.mesh != null \
					and not _near_decals(mmi.global_transform * mmi.get_aabb()):
				stats["skipped_groups"] = int(
					stats.get("skipped_groups", 0)) + 1
				mm = null
			if mm != null and mm.mesh != null:
				var base := mmi.global_transform
				# THE WHOLE GROUP'S TRANSFORMS IN ONE READ, not one call each.
				#
				# get_instance_transform() is a RenderingServer getter, and the SDK
				# runs a separate render thread, so every one of them has to sync
				# with whatever that thread is doing. Across 36,159 instances with
				# the props on screen that cost 14.1 s of what looked like this
				# script's own CPU time and was actually stalling; hiding the props
				# for the pass took the same work to 1.2 s. `buffer` is the same
				# data on the CPU side, so it is one copy per group and no sync at
				# all, and then the props do not have to be hidden.
				#
				# STRIDE IS NOT ALWAYS 12. Colours and custom data are appended per
				# instance when the MultiMesh carries them, so it is read off the
				# resource rather than assumed.
				var buf := mm.buffer
				var stride := 12
				if mm.use_colors:
					stride += 4
				if mm.use_custom_data:
					stride += 4
				# The transform is stored as three rows of four, so a column of the
				# basis is a stride apart in the buffer and the origin is the last
				# entry of each row.
				for ii in range(mm.instance_count):
					var o := ii * stride
					if o + 11 >= buf.size():
						break            # a buffer shorter than it claims
					var xf := Transform3D(
						Vector3(buf[o], buf[o + 4], buf[o + 8]),
						Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
						Vector3(buf[o + 2], buf[o + 6], buf[o + 10]),
						Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))
					_add_instance(mm.mesh, base * xf)
					if Time.get_ticks_msec() - frame > MS_PER_FRAME:
						var ya := Time.get_ticks_usec()
						await tree.process_frame
						_await_us += Time.get_ticks_usec() - ya
						_yields += 1
						frame = Time.get_ticks_msec()
		elif n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				_add_instance(mi.mesh, mi.global_transform)
		if Time.get_ticks_msec() - frame > MS_PER_FRAME:
			var ya := Time.get_ticks_usec()
			await tree.process_frame
			_await_us += Time.get_ticks_usec() - ya
			_yields += 1
			frame = Time.get_ticks_msec()


func _add_instance(mesh: Mesh, xf: Transform3D) -> void:
	# THE CHEAP REJECTS FIRST, and they do nearly all the work: reading the
	# faces copies EVERY triangle in the mesh, and a map has thousands of props.
	var rid := mesh.get_rid()
	if not _boxes.has(rid):
		_boxes[rid] = mesh.get_aabb()
	var box := xf * (_boxes[rid] as AABB)
	if box.position.x > _xmax or box.end.x < _xmin \
			or box.position.z > _zmax or box.end.z < _zmin:
		stats["skipped_instances"] = int(stats["skipped_instances"]) + 1
		return
	# THE WHOLE-MAP RECTANGLE IS NOT A FILTER. The decals are a street network,
	# so their overall bounding box is the entire playable area and the test
	# above passes almost everything. What actually separates a kerbstone from a
	# rooftop air conditioner is the CELLS: does this prop stand over ground that
	# has a marking painted on it, and does it reach the height that marking sits
	# at? Sampled rather than fully enumerated so a large prop stays cheap.
	# COARSE FIRST, THEN FINE. The coarse pass is one or two lookups and throws
	# out anything genuinely far from a road; the fine pass then asks the same
	# question at the resolution the decals are actually stored at, which is
	# what stops a prop ten metres from the kerb paying for all its triangles.
	if not _near_decals(box) or not _near_decals_fine(box):
		stats["skipped_instances"] = int(stats["skipped_instances"]) + 1
		return
	stats["instances"] = int(stats["instances"]) + 1
	if not _faces.has(rid):
		_faces[rid] = _receiver_faces(mesh)
	var faces: PackedVector3Array = _faces[rid]
	if faces.is_empty():
		return
	var i := 0
	while i + 2 < faces.size():
		var a := xf * faces[i]
		var b := xf * faces[i + 1]
		var c := xf * faces[i + 2]
		i += 3
		# Walkable only. A wall would otherwise capture every vertex along its
		# foot and pull the marking up the face.
		var nrm := (b - a).cross(c - a)
		if nrm.length_squared() < 1e-12 or absf(nrm.normalized().y) < MIN_NORMAL_Y:
			continue
		_add_tri(a, b, c)


# Does this box stand over a decal, at a height that decal could be painted on?
#
# Sampled on a lattice of at most 16 x 16 cells rather than every cell: a large
# prop would otherwise cost more to reject than to index, which defeats the
# point of a reject. A sparse-sample miss only means the prop is indexed anyway
# - the per-triangle tests downstream are the ones that have to be exact.
func _near_decals(box: AABB) -> bool:
	var x0 := int(floor(box.position.x / COARSE))
	var x1 := int(floor(box.end.x / COARSE))
	var z0 := int(floor(box.position.z / COARSE))
	var z1 := int(floor(box.end.z / COARSE))
	var sx := maxi(1, (x1 - x0) / 16)
	var sz := maxi(1, (z1 - z0) / 16)
	var xi := x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var band = _cov16.get(_key(xi, zi))
			if band != null:
				var bb: Vector2 = band
				if box.position.y <= bb.y + WINDOW and box.end.y >= bb.x - WINDOW:
					return true
			zi += sz
		xi += sx
	return false


# The same question as _near_decals, at the resolution the decals are stored at.
#
# Only ever called on boxes the coarse pass already accepted, so it runs on a
# small minority of props and its cost is bounded by the same 16 x 16 sample:
# a miss on a sparse sample only means the prop is indexed anyway, and the
# per-triangle tests downstream are the ones that have to be exact.
func _near_decals_fine(box: AABB) -> bool:
	var x0 := int(floor(box.position.x / CELL))
	var x1 := int(floor(box.end.x / CELL))
	var z0 := int(floor(box.position.z / CELL))
	var z1 := int(floor(box.end.z / CELL))
	var sx := maxi(1, (x1 - x0) / 16)
	var sz := maxi(1, (z1 - z0) / 16)
	var xi := x0
	while xi <= x1:
		var zi := z0
		while zi <= z1:
			var band = _cov.get(_key(xi, zi))
			if band != null:
				var bb: Vector2 = band
				if box.position.y <= bb.y + WINDOW and box.end.y >= bb.x - WINDOW:
					return true
			zi += sz
		xi += sx
	return false


# Does this surface exist to take its appearance from the ground?
#
# THREE SHAPES OF THE SAME THING, because a surface looks different depending on
# when it is inspected: straight from the depot it is a BaseMaterial3D with no
# albedo (the user's "no texture white albedo"), before the ground-blend swap it
# still carries the M_TerrainBlend name, and after the swap it is a
# ShaderMaterial sampling bf6_ground_col. Missing any one of the three would
# silently drop receivers depending on build order.
func _is_receiver(mat: Material) -> String:
	if mat == null:
		return ""
	if String(mat.resource_name).to_lower().contains("terrainblend"):
		return "named M_TerrainBlend"
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if sh != null and sh.code.contains("bf6_ground_col"):
			return "already on the ground-blend shader"
		return ""
	if mat is BaseMaterial3D:
		# NOTHING OF ITS OWN TO SHOW. A surface with no albedo is not a broken
		# surface, it is one whose colour comes from somewhere else - which is
		# precisely what a decal receiver is.
		if (mat as BaseMaterial3D).albedo_texture == null:
			return "no albedo of its own"
		return ""
	return ""


# The receiver triangles of a mesh, in its own space, read once per mesh.
#
# PER SURFACE, so get_faces() is no use here: it flattens the whole mesh and
# discards the surface boundaries, which is exactly the information that
# separates a curb's ground-blended apron from its kerb face.
func _receiver_faces(mesh: Mesh) -> PackedVector3Array:
	var keep := PackedVector3Array()
	if not (mesh is ArrayMesh):
		return keep
	var am := mesh as ArrayMesh
	var why := ""
	for si in range(am.get_surface_count()):
		stats["surfaces_seen"] = int(stats.get("surfaces_seen", 0)) + 1
		var w := _is_receiver(am.surface_get_material(si))
		if w == "":
			continue
		why = w
		stats["receiver_surfaces"] = int(
			stats.get("receiver_surfaces", 0)) + 1
		var arr := am.surface_get_arrays(si)
		if arr.is_empty():
			continue
		var vtx: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if vtx.is_empty():
			continue
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] \
			if arr[Mesh.ARRAY_INDEX] is PackedInt32Array \
			else PackedInt32Array()
		var n := idx.size() if not idx.is_empty() else vtx.size()
		var j := 0
		while j + 2 < n:
			var a := vtx[idx[j]] if not idx.is_empty() else vtx[j]
			var b := vtx[idx[j + 1]] if not idx.is_empty() else vtx[j + 1]
			var c := vtx[idx[j + 2]] if not idx.is_empty() else vtx[j + 2]
			j += 3
			# Still only the flat-enough faces: a kerb's vertical apron blends
			# with the ground too, and a road marking does not belong on it.
			var ln := (b - a).cross(c - a)
			if ln.length_squared() <= 1e-12 \
					or absf(ln.normalized().y) < PREFILTER_NORMAL_Y:
				continue
			keep.push_back(a)
			keep.push_back(b)
			keep.push_back(c)
	stats["mesh_tris_kept"] = int(
		stats.get("mesh_tris_kept", 0)) + keep.size() / 3
	# WHICH MESHES, not just how many. "1,478 surfaces are receivers" cannot be
	# checked against the thing on screen; a mesh name can be, straight against
	# the name in a fault marker.
	if not keep.is_empty():
		var nm := mesh.resource_path.get_file()
		if nm == "":
			nm = String(mesh.resource_name)
		if nm == "":
			nm = "(unnamed mesh)"
		var tally: Dictionary = stats.get("receiver_meshes", {})
		var row: Array = tally.get(nm, [0, why])
		row[0] = int(row[0]) + keep.size() / 3
		tally[nm] = row
		stats["receiver_meshes"] = tally
	return keep


func _add_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var x0 := int(floor(minf(a.x, minf(b.x, c.x)) / CELL))
	var x1 := int(floor(maxf(a.x, maxf(b.x, c.x)) / CELL))
	var z0 := int(floor(minf(a.z, minf(b.z, c.z)) / CELL))
	var z1 := int(floor(maxf(a.z, maxf(b.z, c.z)) / CELL))
	if (x1 - x0 + 1) * (z1 - z0 + 1) > MAX_CELLS_PER_TRI:
		return
	var ylo := minf(a.y, minf(b.y, c.y))
	var yhi := maxf(a.y, maxf(b.y, c.y))
	var idx := -1
	for xi in range(x0, x1 + 1):
		for zi in range(z0, z1 + 1):
			var k := _key(xi, zi)
			var band: Variant = _cov.get(k)
			if band == null:
				continue                       # no decal in this cell
			# THE ROOFTOP GUARD, applied before the triangle is ever stored.
			# A roof over a street shares the street's cells and would sit in
			# the index forever, one bad candidate away from being chosen.
			var bb: Vector2 = band
			if ylo > bb.y + WINDOW or yhi < bb.x - WINDOW:
				continue
			if idx < 0:
				idx = _tri.size() / 9
				_tri.append_array(PackedFloat32Array([a.x, a.z, b.x, b.z,
					c.x, c.z, a.y, b.y, c.y]))
				stats["tris"] = int(stats["tris"]) + 1
			var lst: Variant = _cells.get(k)
			if lst == null:
				var p := PackedInt32Array()
				p.append(idx)
				_cells[k] = p
			else:
				var pp: PackedInt32Array = lst
				pp.append(idx)
				_cells[k] = pp


# The surface this vertex is painted on, or INF for "nothing under it, keep the
# terrain height". NEAREST TO THE HEIGHT IT ALREADY HAS - never the highest,
# never the first found.
func _surface_under(px: float, pz: float, py: float,
		lo: float, hi: float) -> float:
	var lst: Variant = _cells.get(_key(int(floor(px / CELL)),
		int(floor(pz / CELL))))
	if lst == null:
		stats["r_no_cell"] = int(stats.get("r_no_cell", 0)) + 1
		return INF
	var best := INF
	var best_d := WINDOW
	var hit_inside := false
	var hit_band := false
	for ti in (lst as PackedInt32Array):
		var o := ti * 9
		var ax := _tri[o]; var az := _tri[o + 1]
		var bx := _tri[o + 2]; var bz := _tri[o + 3]
		var cx := _tri[o + 4]; var cz := _tri[o + 5]
		var d := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
		if absf(d) < 1e-9:
			continue                            # degenerate in plan view
		var w0 := ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / d
		var w1 := ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / d
		var w2 := 1.0 - w0 - w1
		if w0 < -1e-4 or w1 < -1e-4 or w2 < -1e-4:
			continue                            # the point is outside this one
		hit_inside = true
		var y := w0 * _tri[o + 6] + w1 * _tri[o + 7] + w2 * _tri[o + 8]
		# THE AUTHORED BAND DECIDES WHAT COUNTS AS A RECEIVER. Without this
		# the nearest horizontal thing wins, and near a street that is a crate
		# lid or a car roof as often as it is the pavement.
		if y < lo or y > hi:
			continue
		hit_band = true
		var dist := absf(y - py)
		if dist < best_d:
			best_d = dist
			best = y
	# WHICH TEST TURNED IT AWAY. All four failures look the same on screen -
	# the marking stays on the ground - so without this the only way to tell
	# them apart is another rebuild.
	if best == INF:
		if not hit_inside:
			stats["r_not_inside"] = int(stats.get("r_not_inside", 0)) + 1
		elif not hit_band:
			stats["r_band"] = int(stats.get("r_band", 0)) + 1
		else:
			stats["r_window"] = int(stats.get("r_window", 0)) + 1
	return best
