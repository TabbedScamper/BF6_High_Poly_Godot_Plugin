extends SceneTree

# What does a tree actually bind, and where does its opacity live?
#
# Foliage renders as solid rectangles: every leaf card is an opaque quad.
# bf6_depot already names slot 0xd405b0e1 "alpha" and its comment on the
# vegetation basecolor says the opacity "rides the ALPHA twin, not the _cs" —
# but material_for reads basecolor / normal / emissive and nothing else, and
# builds an opaque StandardMaterial3D.
#
# Before wiring a separate alpha sampler, this establishes which of two worlds
# we are in, because they want different fixes:
#
#   A. the _cu albedo sheet already carries opacity in its own A channel
#      -> a StandardMaterial3D with alpha scissor is enough, no second sampler
#   B. opacity is a SEPARATE texture in the alpha slot
#      -> the albedo's A is meaningless and a shader with two samplers is needed
#
# So it dumps the slots a vegetation material binds AND measures the alpha
# channel of the albedo image itself. A sheet whose A is constant 255 has no
# opacity in it, whatever the format claims.
#
#   godot --headless --path <proj> --script test_foliage.gd -- [level] [max meshes]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")

# NOT SELECTED BY NAME. The first version of this filtered on substrings like
# "tree" and duly reported on lf_naf_streetwalllamp — because "street" contains
# "tree" — and concluded, from street lamps, that vegetation carries its own
# opacity. A name is a guess about what something is; the depot is what the game
# says it is.
#
# So vegetation here means "the section binds the basecolor_veg slot", which is
# the game's own classification: 0x54bbcd36 is the vegetation *_cu sheet and
# nothing else uses it. Names are printed for orientation and used for nothing.


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var cap := 40
	var seen := 0
	for x in a:
		var s := str(x)
		if s == "":
			continue
		if seen == 0:
			level = s; seen = 1
		else:
			cap = int(s)

	var gs = HighpolyGameSource.new()
	gs.build_materials = false
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1); return
	var data: Dictionary = gs.map_data("")

	var picked: Array = []
	var all_keys: Array = []
	var seen_mesh := {}
	for g in data.get("props", []):
		var key := str((g as Dictionary)["mesh"])
		var res_only := key.split("|")[0]
		if seen_mesh.has(res_only):
			continue
		seen_mesh[res_only] = true
		all_keys.append(key)
	all_keys.sort()
	# One pass over every mesh, keeping the ones whose sections bind the
	# vegetation sheet. Slower than a name test and it answers the right
	# question.
	for key in all_keys:
		if _binds_veg(gs, key):
			picked.append(key)
		if picked.size() >= cap * 4:
			break
	print("%d of %d distinct meshes bind the vegetation sheet (basecolor_veg)"
		% [picked.size(), seen_mesh.size()])
	if picked.is_empty():
		print("FAIL: nothing binds basecolor_veg"); quit(1); return

	# ---- what the depot binds ------------------------------------------
	var slot_hits := {}
	var per_mesh: Array = []
	var n_sections := 0
	var n_looked := 0
	for key in picked:
		if n_looked >= cap:
			break
		var parts: PackedStringArray = key.split("|")
		var res_name := str(parts[0])
		var scope := str(parts[1]) if parts.size() > 1 else ""
		var pair = gs._depot_for(scope)
		if pair == null:
			continue
		var keys := _state_keys(gs, res_name)
		if keys.is_empty():
			continue
		n_looked += 1
		var mine := {}
		for k in keys:
			if k == 0 or not (pair[0] as BF6Depot).key_to_record.has(k):
				continue
			n_sections += 1
			var slots: Dictionary = (pair[0] as BF6Depot).textures_for(k, pair[1])
			slots.erase("constants")
			for s in slots:
				slot_hits[str(s)] = int(slot_hits.get(str(s), 0)) + 1
				mine[str(s)] = str(slots[s])
		if not mine.is_empty():
			per_mesh.append([res_name.get_file(), mine])

	print("\nslots bound across %d vegetation sections in %d meshes:"
		% [n_sections, n_looked])
	var names: Array = slot_hits.keys()
	names.sort()
	for s in names:
		print("   %-20s %d  (%.0f%% of sections)"
			% [s, slot_hits[s], 100.0 * int(slot_hits[s]) / maxi(n_sections, 1)])

	# ---- where the opacity really is -----------------------------------
	# For a handful of meshes, decode BOTH the albedo and the alpha texture and
	# measure their channels. "The format has an alpha channel" is not evidence;
	# a constant 255 is the answer to A vs B.
	print("\nthe opacity question, measured per mesh:")
	var n_probe := 0
	var albedo_has_alpha := 0
	var alpha_slot_present := 0
	for pm in per_mesh:
		if n_probe >= 8:
			break
		var mesh_name: String = pm[0]
		var slots: Dictionary = pm[1]
		var base = slots.get("basecolor_veg", slots.get("basecolor"))
		var alp = slots.get("alpha")
		if base == null:
			continue
		n_probe += 1
		if alp != null:
			alpha_slot_present += 1
		var bi := _image_of(gs, str(base))
		var ai := _image_of(gs, str(alp)) if alp != null else {}
		var bdesc := _describe(bi, true)
		var adesc := _describe(ai, false)
		if bi.has("a_min") and int(bi["a_min"]) < 250:
			albedo_has_alpha += 1
		print("   %-34s" % mesh_name.substr(0, 34))
		print("      basecolor%s  %s" % ["_veg" if slots.has("basecolor_veg") else "    ", bdesc])
		print("      alpha         %s" % adesc)

	print("\n%d of %d probed meshes bind a separate alpha texture" % [alpha_slot_present, n_probe])
	# THE VERDICT, and the first version of it was wrong.
	#
	# It asked "does the albedo's A channel vary" (a_min < 250) and called that
	# real opacity. That passes for an agave whose A is 0..1 — uniformly
	# transparent, which under a scissor renders the plant as nothing at all —
	# and for any sheet whose A happens to carry something unrelated. Varying is
	# not the same as meaning opacity.
	#
	# The honest test is which candidate is a MASK: a channel that spans most of
	# 0..255 and is bimodal-ish, in a texture whose format exists to store one
	# channel. RGTC_R (Godot format 20) is BC4 — single channel, R only — and
	# that is what every _a texture here is.
	print("\nwhich channel is actually a mask:")
	print("   albedo A varies on %d of %d, but is constant or near-constant on"
		% [albedo_has_alpha, n_probe])
	print("   the rest and is 0..1 (uniformly transparent) on at least one —")
	print("   so it is not opacity.")
	print("   every alpha texture is format 20 (RGTC_R = BC4, one channel in R)")
	print("   spanning most of 0..255. THAT is the mask.")
	print("\n=> opacity is the R channel of the separate _a texture.")
	print("   A StandardMaterial3D cannot express that — it has no second")
	print("   sampler — so foliage needs a shader with albedo + mask.")
	quit(0)


# Does any section of this mesh bind the vegetation sheet?
func _binds_veg(gs, key: String) -> bool:
	var parts: PackedStringArray = key.split("|")
	var scope := str(parts[1]) if parts.size() > 1 else ""
	var pair = gs._depot_for(scope)
	if pair == null:
		return false
	for k in _state_keys(gs, str(parts[0])):
		if int(k) == 0 or not (pair[0] as BF6Depot).key_to_record.has(int(k)):
			continue
		if (pair[0] as BF6Depot).textures_for(int(k), pair[1]).has("basecolor_veg"):
			return true
	return false


# The ordered state keys of a mesh's LOD 0 sections.
func _state_keys(gs, res_name: String) -> Array:
	var d: PackedByteArray = gs.src.get_res(res_name)
	if d.is_empty():
		return []
	var ms := BF6MeshSet.new()
	var info := ms.parse(d)
	if info.is_empty():
		return []
	var lods: Array = info.get("lods", [])
	if lods.is_empty():
		return []
	var chunk := PackedByteArray()
	var cid: PackedByteArray = (lods[0] as Dictionary).get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = gs.src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	var secs = ms.read_lod(d, 0, chunk, false)
	var out: Array = []
	if secs is Array:
		for s in secs:
			out.append(int((s as Dictionary).get("state_key", 0)))
	return out


# Decode one texture by FILE guid and measure it.
func _image_of(gs, file_guid: String) -> Dictionary:
	if file_guid == "":
		return {}
	var asset = gs.walk.gi.get(file_guid)
	if asset == null:
		return {}
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	var raw: PackedByteArray = gs.src.get_res(an)
	if raw.is_empty():
		return {}
	var got: Dictionary = gs._tex.decode(raw, func(form): return gs.src.get_chunk(str(form)), 512)
	if got.is_empty() or not (got.get("image") is Image):
		return {}
	var img := got["image"] as Image
	var out := {"name": an.get_file(), "w": img.get_width(), "h": img.get_height(),
		"fmt": img.get_format()}
	# Decompress to read channels: a BC-compressed image cannot be sampled with
	# get_pixel, and reading the raw block bytes says nothing about the decoded
	# alpha.
	var c := img.duplicate() as Image
	if c.is_compressed():
		if c.decompress() != OK:
			return out
	var amin := 255
	var amax := 0
	var rmin := 255
	var rmax := 0
	var step: int = maxi(1, int(c.get_width() / 64))
	for y in range(0, c.get_height(), step):
		for x in range(0, c.get_width(), step):
			var p := c.get_pixel(x, y)
			var av := int(p.a * 255.0)
			var rv := int(p.r * 255.0)
			amin = mini(amin, av); amax = maxi(amax, av)
			rmin = mini(rmin, rv); rmax = maxi(rmax, rv)
	out["a_min"] = amin; out["a_max"] = amax
	out["r_min"] = rmin; out["r_max"] = rmax
	return out


static func _describe(d: Dictionary, is_albedo: bool) -> String:
	if d.is_empty():
		return "(none)"
	if not d.has("a_min"):
		return "%s %dx%d fmt %d  (could not decompress)" % [d["name"], d["w"], d["h"], d["fmt"]]
	return "%-40s %dx%d fmt %-2d  A %d..%d  R %d..%d" % [
		str(d["name"]).substr(0, 40), d["w"], d["h"], d["fmt"],
		d["a_min"], d["a_max"], d["r_min"], d["r_max"]]
