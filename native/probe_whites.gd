extends SceneTree

# WHY IS SO MUCH OF THIS MAP WHITE?
#
# White is what a Godot surface looks like when its material resolved to null,
# so every white thing on screen is a state key that found no depot record or a
# record with no albedo. The reports are: destruction wrecks white AND
# overlapping the intact prop, variation objects (banners, cop cars, trees)
# white, windows opaque white, foliage cut out wrong.
#
# Those are four different causes and guessing between them is how a day goes.
# This counts them.
#
#   1. VARIATIONS. SHADERS.md §5.2: a placement with an ObjectVariation resolves
#      its material through a DERIVED key, `sectionStateKey + variationNameHash`
#      as a full 64-bit add. Our walk records the variation per instance and
#      nothing downstream reads it, so every variation placement is being looked
#      up under the base key. This measures how often the derived key resolves
#      where the base key does not.
#
#   2. GLASS. SHADERS.md §5: glass is identified by BINDING, not by name — the
#      destruction glass-volume slot 0xBB245590 or the glass tint palette
#      0xA0106346. Nothing here reads either, so glass draws opaque.
#
#   3. FOLIAGE. The vegetation sheet's opacity "rides the ALPHA twin, not the
#      _cs" per our own slot table. If a vegetation material binds basecolor_veg
#      and NO alpha slot, the cutout has to come from somewhere else.
#
#   4. DESTRUCTION. dc_ meshes should not be placed where the intact prop is.
#
#   godot --headless --path native/_testproj --script probe_whites.gd -- [level] [meshcap]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6MVDB := preload("res://bf6_mvdb.gd")


const BF6MeshSet := preload("res://bf6_meshset.gd")

var _sk_cache := {}


# The state keys of a mesh's LOD 0 sections. Geometry is not needed, only the
# keys, so this stops at the section table.
func _section_keys(gs, res_name: String) -> Array:
	if _sk_cache.has(res_name):
		return _sk_cache[res_name]
	var out: Array = []
	var d: PackedByteArray = gs.src.get_res(res_name)
	if not d.is_empty():
		var ms = BF6MeshSet.new()
		var info: Dictionary = ms.parse(d)
		var lods: Array = info.get("lods", [])
		if not lods.is_empty():
			# The geometry lives in a CAS chunk unless the MeshSet inlines it,
			# and read_lod returns nothing without it — even for the state keys.
			var chunk := PackedByteArray()
			var cid: PackedByteArray = (lods[0] as Dictionary).get("chunk_id",
				PackedByteArray())
			if not cid.is_empty():
				for form in BF6MeshSet.chunk_forms(cid):
					chunk = gs.src.get_chunk(str(form))
					if not chunk.is_empty():
						break
			var secs = ms.read_lod(d, 0, chunk, false)
			if secs is Array:
				for s in secs:
					out.append(int((s as Dictionary).get("state_key", 0)))
	_sk_cache[res_name] = out
	return out


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var cap := 120
	if a.size() > 0 and str(a[0]) != "": level = str(a[0])
	if a.size() > 1 and str(a[1]) != "": cap = int(str(a[1]))

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return
	var rows: Array = gs.walk.rows

	# ---- 4. destruction -----------------------------------------------------
	var dc_rows := 0
	var dc_meshes := {}
	var intact := {}
	for r in rows:
		var nm := str((r as Dictionary)["mesh"]).get_file()
		intact[nm] = true
	for r in rows:
		var nm := str((r as Dictionary)["mesh"]).get_file()
		if nm.begins_with("dc_"):
			dc_rows += 1
			dc_meshes[nm] = int(dc_meshes.get(nm, 0)) + 1
	print("\n=== 4. destruction ===")
	print("rows placing a dc_ mesh: %d over %d distinct meshes" % [dc_rows, dc_meshes.size()])
	var twinned := 0
	for m in dc_meshes.keys():
		if intact.has(str(m).substr(3)):
			twinned += 1
	print("of those meshes, %d also have their INTACT twin placed in the same level"
		% twinned)
	if dc_rows > 0:
		var top: Array = dc_meshes.keys()
		top.sort_custom(func(x, y): return int(dc_meshes[x]) > int(dc_meshes[y]))
		for m in top.slice(0, 6):
			print("   %-46s %4d rows   intact twin placed: %s"
				% [str(m), int(dc_meshes[m]), intact.has(str(m).substr(3))])

	# ---- 1. variations ------------------------------------------------------
	var with_var := 0
	var var_meshes := {}
	for r in rows:
		var rd: Dictionary = r
		if rd.get("var") == null:
			continue
		with_var += 1
		var k := "%s|%s|%s" % [str(rd["mesh"]), str(rd["var"]), str(rd.get("scope", ""))]
		if not var_meshes.has(k):
			var_meshes[k] = rd
	print("\n=== 1. variations ===")
	print("rows carrying an ObjectVariation: %d of %d (%.1f%%)"
		% [with_var, rows.size(), 100.0 * float(with_var) / float(maxi(1, rows.size()))])
	print("distinct (mesh, variation, scope): %d" % var_meshes.size())

	var checked := 0
	var base_hit := 0
	var derived_hit := 0
	var base_only := 0
	var derived_only := 0
	var neither := 0
	var samples: Array = []
	var skip_depot := 0
	var skip_res := 0
	var skip_secs := 0
	var why: Array = []
	for k in var_meshes.keys():
		if checked >= cap:
			break
		var rd: Dictionary = var_meshes[k]
		var scope := str(rd.get("scope", ""))
		var pair = gs._depot_for(scope)
		if pair == null:
			skip_depot += 1
			if why.size() < 4:
				why.append("no depot for scope '%s' (mesh %s)"
					% [scope, str(rd["mesh"]).get_file()])
			continue
		var dep: BF6Depot = pair[0]
		var res: String = gs.resolve_mesh(str(rd["mesh"]))
		if res == "":
			skip_res += 1
			if why.size() < 4:
				why.append("no MeshSet for %s" % str(rd["mesh"]))
			continue
		var secs: Array = _section_keys(gs, res)
		if secs.is_empty():
			skip_secs += 1
			if why.size() < 4:
				why.append("no sections in %s" % res)
			continue
		checked += 1
		var vh := BF6MVDB.djb2(str(rd["var"]).to_lower())
		var b := 0
		var d := 0
		for s in secs:
			var key := int(s)
			if key == 0:
				continue
			if dep.key_to_record.has(key):
				b += 1
			# SHADERS.md §5.2: a genuine u64 add. GDScript's int is a signed
			# 64-bit two's-complement value, so `+` produces the same bit
			# pattern a u64 add would — which is what the depot is keyed on.
			if dep.key_to_record.has(key + vh):
				d += 1
		if b > 0: base_hit += 1
		if d > 0: derived_hit += 1
		if b > 0 and d == 0: base_only += 1
		if d > 0 and b == 0: derived_only += 1
		if b == 0 and d == 0: neither += 1
		if samples.size() < 8 and d > 0 and b == 0:
			samples.append("%s + %s" % [str(rd["mesh"]).get_file(),
				str(rd["var"]).get_file()])
	print("\nskipped: %d no depot, %d no MeshSet, %d no sections"
		% [skip_depot, skip_res, skip_secs])
	for w in why:
		print("   %s" % w)
	print("\nchecked %d distinct variation placements:" % checked)
	print("   base key resolves       %d" % base_hit)
	print("   DERIVED key resolves    %d" % derived_hit)
	print("   derived ONLY (white today, dressed with the fix)  %d" % derived_only)
	print("   base ONLY               %d" % base_only)
	print("   neither                 %d" % neither)
	for s in samples:
		print("      e.g. %s" % s)

	# ---- 2 & 3. glass and foliage, over the depots this map actually uses ----
	var glass_keys := 0
	var tint_keys := 0
	var veg_keys := 0
	var veg_with_alpha := 0
	var alpha_keys := 0
	var total_keys := 0
	var no_albedo := 0
	var seen_depots := {}
	for r in rows:
		var scope := str((r as Dictionary).get("scope", ""))
		if scope == "" or seen_depots.has(scope):
			continue
		seen_depots[scope] = true
	print("\n=== 2 & 3. glass and foliage ===")
	print("depots this map places from: %d" % seen_depots.size())
	var depots_done := 0
	for scope in seen_depots.keys():
		if depots_done >= 12:
			break
		var pair = gs._depot_for(str(scope))
		if pair == null:
			continue
		depots_done += 1
		var dep: BF6Depot = pair[0]
		var blob: PackedByteArray = pair[1]
		for key in dep.key_to_record.keys():
			total_keys += 1
			var slots: Dictionary = dep.textures_for(int(key), blob)
			var consts: Dictionary = slots.get("constants", {})
			if slots.has("glass_volume"):
				glass_keys += 1
			if consts.has(0xA0106346) or consts.has(0x6BB97444):
				tint_keys += 1
			if slots.has("basecolor_veg"):
				veg_keys += 1
				if slots.has("alpha"):
					veg_with_alpha += 1
			if slots.has("alpha"):
				alpha_keys += 1
			if not (slots.has("basecolor") or slots.has("basecolor_veg")):
				no_albedo += 1
	print("state keys examined: %d over %d depots" % [total_keys, depots_done])
	print("   bind the destruction glass volume (0xBB245590):  %d" % glass_keys)
	print("   carry a glass tint constant (0xA0106346/0x6BB97444): %d" % tint_keys)
	print("   bind basecolor_veg (vegetation):                 %d" % veg_keys)
	print("      of those, ALSO bind an alpha slot:            %d" % veg_with_alpha)
	print("   bind an alpha slot at all:                       %d" % alpha_keys)
	print("   bind NO albedo of either kind (draws white):     %d (%.1f%%)"
		% [no_albedo, 100.0 * float(no_albedo) / float(maxi(1, total_keys))])

	quit(0)
