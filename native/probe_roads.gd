extends SceneTree

# WHAT THE ROAD SPLINES ATTACH TO, AND HOW THEIR TEXTURES GET APPLIED.
#
# First, the thing worth knowing before looking: the splines are NOT in the
# shipped data. TERRAIN.md §10 calls the decals RES "the pre-tessellated
# compiled output of the TerrainFillDecalData / TerrainQuadDecalData authoring
# instances (spline points are stripped from runtime EBX)". So what ships is the
# ribbon already turned into triangles. This checks that claim rather than
# repeating it, by looking for the authoring types and for any control-point
# array in the level's own partitions.
#
# Then the questions that DO have answers in the data:
#
#   ATTACH TO GEOMETRY — the vertex format carries world X and Z and no Y at
#   all, so a road is not attached to anything positionally; it is DRAPED on the
#   heightfield wherever it passes. Reported as the AABB Y span, which should be
#   near zero if Y is genuinely absent from the record too.
#
#   ATTACH TO A MATERIAL — two different ways, and the second is the interesting
#   one. A record with a property stream names its own textures by slot hash. A
#   PROP-LESS record instead has an AssetSlot that IS a terrain layer-graph
#   layer index, so its surface is that layer's own material — the same palette
#   the terrain reads. That is a real join between two systems and it is where
#   our roads currently fall back to flat grey.
#
#   godot --headless --path native/_testproj --script probe_roads.gd -- [level]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Decals := preload("res://bf6_decals.gd")
const BF6TerrainLayers := preload("res://bf6_terrainlayers.gd")
const BF6Ebx := preload("res://bf6_ebx.gd")

const SLOT_NAMES := {
	0x399AC0336ACFE03C: "cv  (basecolor)",
	0x567A9BC35CCBB1B2: "nhs (normal/height/smooth)",
	0x3A411B3E209FC9E2: "ao",
	0x3810287D4CE70B49: "op  (coverage/markings)",
}


func _init() -> void:
	await process_frame
	var level := "mp_dumbo"
	for x in OS.get_cmdline_user_args():
		if str(x) != "":
			level = str(x); break

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return

	# --- 1. is anything spline-shaped still in the level? --------------------
	print("\n=== are the splines shipped? ===")
	var authoring := 0
	var decal_parts := 0
	for name in gs.src.ebx.keys():
		var n := str(name).to_lower()
		if n.contains("decal") and n.contains(level):
			decal_parts += 1
			if authoring < 4:
				print("   decal partition: %s" % n)
	print("   level decal EBX partitions: %d" % decal_parts)

	# Open one and look at what is actually in it. The claim to test is that the
	# authored spline survives nowhere: if control points were kept there would
	# be instances carrying long Vec3 arrays, one per road.
	var probe := ""
	for name in gs.src.ebx.keys():
		var n := str(name).to_lower()
		if n.contains("_decals") and n.contains(level) and not n.contains("ecsprefab"):
			probe = str(name); break
	if probe != "":
		var eb: PackedByteArray = gs.src.get_ebx(probe)
		var e = BF6Ebx.new(gs.types, gs.walk.gi)
		if not eb.is_empty() and e.parse(eb):
			print("\n   opened %s" % probe.get_file())
			print("   %d instances, %d imports" % [e.instance_offsets.size(), e.imports.size()])
			var kinds := {}
			var biggest_vec3 := 0
			for i in range(e.instance_offsets.size()):
				var inst = e.read_instance(i)
				if not (inst is Dictionary):
					continue
				var ty := str((inst as Dictionary).get("__type", "?"))
				kinds[ty] = int(kinds.get(ty, 0)) + 1
				for k in (inst as Dictionary).keys():
					var v = (inst as Dictionary)[k]
					if v is Array and (v as Array).size() > 3 \
							and (v as Array)[0] is Vector3:
						biggest_vec3 = maxi(biggest_vec3, (v as Array).size())
			print("   distinct instance types: %d" % kinds.size())
			print("   longest Vec3 array found in any instance: %d" % biggest_vec3)
			if biggest_vec3 < 8:
				print("   -> no control-point arrays survive here; the authored")
				print("      spline really is compiled away")

	# --- 2. the compiled records ---------------------------------------------
	var res := BF6Decals.find_res(gs.src, level)
	if res == "":
		print("\nno TerrainDecals resource on %s" % level); quit(1); return
	var raw: PackedByteArray = gs.src.get_res(res)
	var td = BF6Decals.new()
	if not td.parse(raw):
		print("FAIL decals: %s" % td.error); quit(1); return
	print("\n=== the compiled ribbons ===")
	print("records %d, vertex buffer %d bytes at %d, slot table %d entries"
		% [td.records.size(), td.vb_size, td.vb_start, td.slots.size()])

	var y_span_max := 0.0
	var with_props := 0
	var propless := 0
	var slot_hist := {}
	var tiling := {}
	var layer_hist := {}
	var tex_by_slot := {}
	for r in td.records:
		var rec: Dictionary = r
		var lo: Vector3 = rec["aabb_min"]
		var hi: Vector3 = rec["aabb_max"]
		y_span_max = maxf(y_span_max, hi.y - lo.y)
		var props: Dictionary = rec["props"]
		var any := false
		for h in props.keys():
			var e = props[h]
			if e is Array and str((e as Array)[0]) == "tex":
				any = true
				slot_hist[int(h)] = int(slot_hist.get(int(h), 0)) + 1
				if not tex_by_slot.has(int(h)):
					tex_by_slot[int(h)] = BF6Decals.guid_str((e as Array)[1])
		if any:
			with_props += 1
		else:
			propless += 1
			layer_hist[int(rec["asset_slot"])] = \
				int(layer_hist.get(int(rec["asset_slot"]), 0)) + 1
		var t0 := "%.1f" % float(rec["tiling0"])
		tiling[t0] = int(tiling.get(t0, 0)) + 1

	print("\n--- how a record is attached to the ground ---")
	print("largest AABB Y span over all %d records: %.3f m" % [td.records.size(), y_span_max])
	print("(the vertex format stores world X and Z and NO Y — a road is draped on")
	print(" the heightfield wherever it passes, not positioned in 3D)")

	print("\n--- how a record is attached to a material ---")
	print("records with their own property stream: %d" % with_props)
	print("PROP-LESS records (AssetSlot is a terrain LAYER index): %d" % propless)
	print("\ntexture slots bound across the property streams:")
	var sk: Array = slot_hist.keys()
	sk.sort_custom(func(a, b): return int(slot_hist[a]) > int(slot_hist[b]))
	for h in sk:
		print("   %-30s %4d records   e.g. %s"
			% [str(SLOT_NAMES.get(int(h), "0x%016X" % int(h))), int(slot_hist[h]),
			   _asset(gs, str(tex_by_slot.get(int(h), ""))).get_file()])

	print("\nUV tiling (Tiling0, world metres per tile):")
	var tk: Array = tiling.keys()
	tk.sort_custom(func(a, b): return int(tiling[a]) > int(tiling[b]))
	for t in tk.slice(0, 10):
		print("   %8s m   %4d records" % [str(t), int(tiling[t])])

	# --- 3. where the prop-less records point --------------------------------
	if propless > 0:
		var pidx: Dictionary = gs.walk.gi if gs.walk != null else {}
		var pal = BF6TerrainLayers.new()
		var ok: bool = pal.load(gs.src, level, pidx)
		print("\n--- what the prop-less records resolve to ---")
		print("terrain layer palette loaded: %s" % ok)
		var lk: Array = layer_hist.keys()
		lk.sort_custom(func(a, b): return int(layer_hist[a]) > int(layer_hist[b]))
		for l in lk:
			var i := int(l)
			var nm := pal.albedo_of(i) if ok else ""
			print("   AssetSlot %2d -> L%02d  %4d records   %s"
				% [i, i, int(layer_hist[l]),
				   nm.get_file() if nm != "" else "(layer binds no albedo)"])
		print("\nThat is the join: a road with no textures of its own is painted")
		print("with the TERRAIN LAYER its AssetSlot names — the same palette the")
		print("ground uses. Ours currently draws those flat grey.")

	quit(0)


func _asset(gs, guid: String) -> String:
	if guid == "":
		return ""
	var a = gs.walk.gi.get(guid)
	return str(a) if a != null else guid
