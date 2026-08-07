extends SceneTree

# The GDScript MeshSet reader over the SAME meshes the Python one dumped.
#
# Reads the name list out of the Python dump rather than picking its own, so the
# two are compared on identical input. Picking independently would let a
# difference in SELECTION masquerade as agreement — both readers succeeding on
# whatever each found easy.
#
#   godot --path <proj> --script ms_gddump.gd -- <python.json> <out.json> [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")


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

	var src := BF6Source.new()
	if not src.open():
		print("cannot open the game: %s" % src.error)
		quit(1); return
	if not src.mount(level):
		print("cannot mount %s: %s" % [level, src.error])
		quit(1); return
	print("mounted %s: %d res" % [level, src.res.size()])

	var ms := BF6MeshSet.new()
	var recs: Array = []
	var ok := 0
	for r in ref["records"]:
		var name := str(r["name"])
		var rec := {"name": name}
		var d: PackedByteArray = src.get_res(name)
		if d.is_empty():
			rec["error"] = "no res bytes"
			recs.append(rec)
			continue
		var info := ms.parse(d)
		if info.is_empty():
			rec["error"] = ms.error if ms.error != "" else "parse failed"
			recs.append(rec)
			continue
		rec["lods"] = (info["lods"] as Array).size()
		rec["mesh_type"] = info["mesh_type"]
		rec["ms_name"] = info["name"]
		rec["lod_stride"] = info["lod_stride"]
		if rec["lods"] > 0:
			var L: Dictionary = info["lods"][0]
			var cid: PackedByteArray = L["chunk_id"]
			rec["chunk"] = cid.hex_encode()
			var zero := true
			for b in cid:
				if b != 0:
					zero = false
					break
			rec["inline"] = zero
			var chunk := PackedByteArray()
			if not zero:
				for form in BF6MeshSet.chunk_forms(cid):
					var c: PackedByteArray = src.get_chunk(str(form))
					if not c.is_empty():
						chunk = c
						break
				if chunk.is_empty():
					rec["error"] = "chunk not in the mount"
					recs.append(rec)
					continue
			rec["sections"] = _summarize(ms.read_lod(d, 0, chunk))
			if ms.error != "":
				rec["error"] = ms.error
		if not rec.has("error"):
			ok += 1
		recs.append(rec)
		print("  %-70s %s" % [name.right(70),
				rec["error"] if rec.has("error") else "ok"])

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"level": level, "records": recs}, " "))
	f.close()
	print("\nwrote %s: %d record(s), %d readable" % [out_path, recs.size(), ok])
	quit(0)


# The same summary the Python dump writes. Rounded before summing, because the
# two readers reach the same bytes through different float paths and comparing
# raw doubles would fail on the last bit for reasons that are not correctness.
func _summarize(secs: Array) -> Array:
	var out: Array = []
	for s in secs:
		var V: PackedVector3Array = s["verts"]
		var UV: PackedVector2Array = s["uvs"]
		var F: PackedInt32Array = s["indices"]
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		var vsum := 0.0
		for v in V:
			mn = Vector3(minf(mn.x, v.x), minf(mn.y, v.y), minf(mn.z, v.z))
			mx = Vector3(maxf(mx.x, v.x), maxf(mx.y, v.y), maxf(mx.z, v.z))
			vsum += snappedf(v.x, 0.001) + snappedf(v.y, 0.001) \
					+ snappedf(v.z, 0.001)
		var uvsum := 0.0
		for u in UV:
			uvsum += snappedf(u.x, 0.001) + snappedf(u.y, 0.001)
		var fsum := 0
		for i in F:
			fsum += i
		out.append({
			"material": s["material"],
			"verts": V.size(),
			"faces": int(F.size() / 3),
			"min": [snappedf(mn.x, 0.001), snappedf(mn.y, 0.001),
					snappedf(mn.z, 0.001)],
			"max": [snappedf(mx.x, 0.001), snappedf(mx.y, 0.001),
					snappedf(mx.z, 0.001)],
			"vsum": snappedf(vsum, 0.01),
			"fsum": fsum,
			"uvsum": snappedf(uvsum, 0.01),
		})
	return out
