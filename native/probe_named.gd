extends SceneTree

# WHAT DOES THE DEPOT ACTUALLY GIVE the things that are white on screen?
#
# The reports name them: banners, cop cars, trees, vehicle wrecks, windows. So
# rather than reasoning about aggregate percentages over every state key in
# every depot — most of which this map never draws — this looks up those exact
# meshes and prints, per section, what came back.
#
# A surface with no material is drawn by Godot's default, which is white. So
# "white on screen" and "material_for returned null" are the same event, and the
# question is only ever which of the three ways it can happen:
#   the scope has no depot, the depot has no record for the key, or the record
#   has no albedo in it.
#
#   godot --headless --path native/_testproj --script probe_named.gd -- [level] [pattern..]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")
const BF6Depot := preload("res://bf6_depot.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var pats: Array = []
	for i in range(a.size()):
		if i == 0:
			level = str(a[0])
		else:
			pats.append(str(a[i]).to_lower())
	if pats.is_empty():
		pats = ["banner", "police", "cop", "tree", "foliage", "veh_", "window",
			"glass", "flag"]

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return

	# one representative row per (mesh, scope)
	var groups := {}
	for r in gs.walk.rows:
		var rd: Dictionary = r
		var nm := str(rd["mesh"]).to_lower()
		var leaf := nm.get_file()
		var hit := false
		for p in pats:
			if leaf.contains(str(p)):
				hit = true; break
		if not hit:
			continue
		var k := "%s|%s" % [nm, str(rd.get("scope", ""))]
		if not groups.has(k):
			groups[k] = rd
	print("\n%d matching (mesh, scope) groups" % groups.size())

	var shown := 0
	var tally := {"no_depot": 0, "no_record": 0, "no_albedo": 0, "dressed": 0}
	var keys: Array = groups.keys()
	keys.sort()
	for k in keys:
		var rd: Dictionary = groups[k]
		var scope := str(rd.get("scope", ""))
		var res: String = gs.resolve_mesh(str(rd["mesh"]))
		if res == "":
			continue
		var secs := _sections(gs, res)
		if secs.is_empty():
			continue
		var pair = gs._depot_for(scope)
		var line := "\n%s   (%d sections)" % [str(rd["mesh"]).get_file(), secs.size()]
		if rd.get("var") != null:
			line += "   variation %s" % str(rd["var"]).get_file()
		if pair == null:
			tally["no_depot"] = int(tally["no_depot"]) + secs.size()
			if shown < 24:
				print(line + "\n   NO DEPOT for scope '%s'" % scope)
				shown += 1
			continue
		var dep: BF6Depot = pair[0]
		var blob: PackedByteArray = pair[1]
		var bits: Array = []
		for s in secs:
			var key := int((s as Dictionary).get("state_key", 0))
			var mname := str((s as Dictionary).get("name", ""))
			if not dep.key_to_record.has(key):
				tally["no_record"] = int(tally["no_record"]) + 1
				bits.append("%s: NO RECORD" % mname)
				continue
			var slots: Dictionary = dep.textures_for(key, blob)
			var consts: Dictionary = slots.get("constants", {})
			slots.erase("constants")
			var names: Array = slots.keys()
			names.sort()
			var has_alb: bool = slots.has("basecolor") or slots.has("basecolor_veg")
			if has_alb:
				tally["dressed"] = int(tally["dressed"]) + 1
			else:
				tally["no_albedo"] = int(tally["no_albedo"]) + 1
			var tags: Array = []
			if slots.has("glass_volume"):
				tags.append("GLASS-VOL")
			if consts.has(0xA0106346):
				tags.append("GLASS-TINT")
			if consts.has(0x6BB97444):
				tags.append("ARCH-GLASS")
			bits.append("%s: %s%s%s" % [mname, ", ".join(names),
				"" if has_alb else "   <- NO ALBEDO (white)",
				("   [" + ", ".join(tags) + "]") if not tags.is_empty() else ""])
		if shown < 24:
			print(line)
			for b in bits:
				print("   %s" % b)
			shown += 1

	print("\n--- over every matching group ---")
	print("sections with no depot for their scope: %d" % int(tally["no_depot"]))
	print("sections whose key is not in the depot:  %d" % int(tally["no_record"]))
	print("sections resolving but with NO albedo:   %d" % int(tally["no_albedo"]))
	print("sections that dress properly:            %d" % int(tally["dressed"]))
	quit(0)


var _cache := {}


func _sections(gs, res_name: String) -> Array:
	if _cache.has(res_name):
		return _cache[res_name]
	var out: Array = []
	var d: PackedByteArray = gs.src.get_res(res_name)
	if not d.is_empty():
		var ms = BF6MeshSet.new()
		var info: Dictionary = ms.parse(d)
		var lods: Array = info.get("lods", [])
		if not lods.is_empty():
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
				out = secs
	_cache[res_name] = out
	return out
