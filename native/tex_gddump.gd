extends SceneTree

# The GDScript texture reader over the SAME textures the Python one dumped.
#
# Reads the name list out of the Python dump rather than picking its own, so the
# two are judged on identical input — picking independently would let a
# difference in SELECTION masquerade as agreement.
#
#   godot --path <proj> --script tex_gddump.gd -- <python.json> <out.json> [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Texture := preload("res://bf6_texture.gd")

var _src = null


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var ref_path := str(a[0]) if a.size() > 0 else ""
	var out_path := str(a[1]) if a.size() > 1 else ""
	var level := str(a[2]) if a.size() > 2 else "mp_dumbo"

	var ref = JSON.parse_string(FileAccess.get_file_as_string(ref_path))
	if ref == null or not ref.has("records"):
		print("cannot read the reference dump at %s" % ref_path)
		quit(1); return

	_src = BF6Source.new()
	if not _src.open() or not _src.mount(level):
		print("cannot mount %s: %s" % [level, _src.error])
		quit(1); return
	print("mounted %s: %d res" % [level, _src.res.size()])

	var tex := BF6Texture.new()
	var recs: Array = []
	var ok := 0
	for r in ref["records"]:
		var name := str(r["name"])
		var rec := {"name": name}
		var d: PackedByteArray = _src.get_res(name)
		if d.is_empty():
			rec["error"] = "no res bytes"
			recs.append(rec)
			continue
		var hdr := tex.header(d)
		if hdr.is_empty():
			rec["error"] = "header too short"
			recs.append(rec)
			continue
		rec["format"] = hdr["format"]
		rec["dxgi"] = hdr["dxgi"]
		rec["width"] = hdr["width"]
		rec["height"] = hdr["height"]
		rec["slices"] = hdr["slices"]
		rec["mipcount"] = hdr["mipcount"]
		rec["streamflag"] = hdr["streamflag"]
		rec["mip_sizes"] = hdr["mip_sizes"]
		rec["embedded"] = hdr["embedded"]
		rec["streamed"] = hdr["streamed"]
		rec["which"] = tex.which_chunk(hdr)

		# Same order the decoder uses: the nominated chunk, then the other.
		var used := str(rec["which"])
		var pix := _fetch_any(BF6Texture.chunk_forms(str(hdr[used])))
		if pix.is_empty():
			used = "embedded" if used == "streamed" else "streamed"
			pix = _fetch_any(BF6Texture.chunk_forms(str(hdr[used])))
		if pix.is_empty():
			rec["error"] = "neither chunk available"
			recs.append(rec)
			continue
		var dd := tex.dims_for(hdr, pix)
		var dim: Vector2i = dd[0]
		var top: PackedByteArray = dd[1]
		rec["used"] = used
		rec["chunk_bytes"] = pix.size()
		rec["dims"] = [dim.x, dim.y]
		rec["top_bytes"] = top.size()
		rec["top_sha1"] = _sha1(top)

		# The decode itself is exercised too, so a header the port reads
		# correctly but cannot turn into an Image still shows up as a failure
		# rather than passing on the strength of its metadata.
		var res := tex.decode(d, Callable(self, "_fetch"))
		if res.is_empty():
			rec["decode_error"] = tex.error
		else:
			rec["img"] = [int(res["width"]), int(res["height"])]
			rec["srgb"] = bool(res["srgb"])
			rec["img_slices"] = int(res["slices"])
		ok += 1
		recs.append(rec)

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"level": level, "records": recs}, " "))
	f.close()
	print("wrote %s: %d record(s), %d readable" % [out_path, recs.size(), ok])
	quit(0)


func _fetch(guid_hex: String) -> PackedByteArray:
	return _src.get_chunk(guid_hex)


func _fetch_any(forms: Array) -> PackedByteArray:
	for f in forms:
		var c: PackedByteArray = _src.get_chunk(str(f))
		if not c.is_empty():
			return c
	return PackedByteArray()


func _sha1(b: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(b)
	return ctx.finish().hex_encode()
