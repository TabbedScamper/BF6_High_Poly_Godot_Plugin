extends SceneTree

# EYES ON THE TWO CANDIDATE MASKS.
#
# probe_vegmaskpair found the agreement between the veg basecolor's A and the
# alpha slot's R splits the corpus down the middle: 99.8% on dracaena, 61-66%
# on birch / pearcallery / locusthoney / oakpin, 50% (i.e. nothing) on
# treedestroyed. Statistics cannot say WHY two masks of the same plant would
# disagree — a different atlas packing, a different meaning, or a decode fault
# all produce the same number.
#
# So this writes them out: for each of the top pairings, one PNG strip holding
#   [ veg basecolor RGB | veg basecolor A | alpha-slot R ]
# side by side at a common height. Looking at them answers in one glance what
# the correlation could not.
#
#   godot --headless --path native/_testproj --script probe_vegdump.gd \
#         -- <outdir> [level] [pairs]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6Texture := preload("res://bf6_texture.gd")

const TILE := 384

var gs = null


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var outdir := "user://vegdump"
	var level := "mp_dumbo"
	var npairs := 6
	if a.size() > 0:
		outdir = str(a[0])
	if a.size() > 1:
		level = str(a[1])
	if a.size() > 2:
		npairs = int(a[2])
	DirAccess.make_dir_recursive_absolute(outdir)

	gs = HighpolyGameSource.new()
	gs.build_materials = false
	gs.log_fn = func(t): print("   " + str(t))
	if not gs.open_map(level):
		print("FAIL open_map: %s" % gs.error)
		quit(1)
		return

	var scopes := {}
	for r in gs.walk.rows:
		var sc := str((r as Dictionary).get("scope", ""))
		if sc != "":
			scopes[sc] = true
	var by_bundle := {}
	for sc in scopes.keys():
		var bn = gs._depot_bundles.get(str(sc))
		if bn == null or by_bundle.has(str(bn)):
			continue
		var pr = gs._depot_for(str(sc))
		if pr != null:
			by_bundle[str(bn)] = pr

	var pairs := {}
	for bn in by_bundle.keys():
		var pr: Array = by_bundle[bn]
		var dep: BF6Depot = pr[0]
		var blob: PackedByteArray = pr[1]
		for k in dep.key_to_record.keys():
			var slots: Dictionary = dep.textures_for(int(k), blob)
			if not slots.has("basecolor_veg"):
				continue
			var pk := "%s|%s" % [str(slots["basecolor_veg"]),
				str(slots.get("alpha", ""))]
			pairs[pk] = int(pairs.get(pk, 0)) + 1
	var pk_keys: Array = pairs.keys()
	pk_keys.sort_custom(func(x, y): return int(pairs[x]) > int(pairs[y]))

	var n := 0
	for p in pk_keys:
		if n >= npairs:
			break
		n += 1
		var bits: PackedStringArray = str(p).split("|")
		var vn := _name_of(str(bits[0]))
		var an := _name_of(str(bits[1])) if str(bits[1]) != "" else ""
		var vi = _decode(vn)
		var ai = _decode(an) if an != "" else null
		if vi == null:
			print("skip %s" % vn)
			continue
		var strip := Image.create_empty(TILE * 5, TILE, false, Image.FORMAT_RGB8)
		strip.fill(Color(0, 0, 1))
		_blit_rgb(strip, vi as Image, 0)
		_blit_chan(strip, vi as Image, 3, TILE)
		if ai != null:
			_blit_chan(strip, ai as Image, 0, TILE * 2)
			# the same channel thresholded. If the alpha slot holds a distance
			# field with its surface at 0.5, tile 4 is the crisp silhouette and
			# tile 3's softness is a distance ramp rather than a blur.
			_blit_thresh(strip, ai as Image, 0, TILE * 3, 0.5)
			_blit_thresh(strip, ai as Image, 0, TILE * 4, 0.25)
		var path := "%s/%02d_%s.png" % [outdir, n, vn.get_file()]
		strip.save_png(path)
		print("%s   [rgb | vegA | alphaR]  veg %s  alpha %s" % [path,
			vn.get_file(), an.get_file()])
	quit(0)


func _blit_rgb(dst: Image, src: Image, x0: int) -> void:
	var w := src.get_width()
	var h := src.get_height()
	for y in range(TILE):
		for x in range(TILE):
			var c := src.get_pixel(int(float(x) / TILE * w),
				int(float(y) / TILE * h))
			dst.set_pixel(x0 + x, y, Color(c.r, c.g, c.b))


func _blit_chan(dst: Image, src: Image, ch: int, x0: int) -> void:
	var w := src.get_width()
	var h := src.get_height()
	for y in range(TILE):
		for x in range(TILE):
			var c := src.get_pixel(int(float(x) / TILE * w),
				int(float(y) / TILE * h))
			var v: float = [c.r, c.g, c.b, c.a][ch]
			dst.set_pixel(x0 + x, y, Color(v, v, v))


func _blit_thresh(dst: Image, src: Image, ch: int, x0: int, t: float) -> void:
	var w := src.get_width()
	var h := src.get_height()
	for y in range(TILE):
		for x in range(TILE):
			var c := src.get_pixel(int(float(x) / TILE * w),
				int(float(y) / TILE * h))
			var v: float = [c.r, c.g, c.b, c.a][ch]
			var o := 1.0 if v > t else 0.0
			dst.set_pixel(x0 + x, y, Color(o, o, o))


func _name_of(file_guid: String) -> String:
	if file_guid == "":
		return ""
	var asset = gs.walk.gi.get(file_guid)
	if asset == null:
		return ""
	var an := str(asset).to_lower()
	if an.ends_with(".ebx"):
		an = an.substr(0, an.length() - 4)
	return an


func _decode(asset_name: String):
	if asset_name == "":
		return null
	var raw: PackedByteArray = gs.src.get_res(asset_name)
	if raw.is_empty():
		return null
	var tx := BF6Texture.new()
	var got: Dictionary = tx.decode(raw,
		func(form): return gs.src.get_chunk(str(form)), 0)
	if got.is_empty() or not (got.get("image") is Image):
		return null
	var c := (got["image"] as Image).duplicate() as Image
	if c.is_compressed() and c.decompress() != OK:
		return null
	return c
