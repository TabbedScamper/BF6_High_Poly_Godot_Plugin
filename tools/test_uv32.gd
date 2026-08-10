@tool
extends SceneTree
# Software-render the paramedicus carpaint (wrap) section's SIDE VIEW, sampling
# the wrap sheet through each candidate texcoord channel. The channel that
# assembles "PARAMEDIC" text and the star of life legibly on the box side is
# the wrap channel. No GPU: plain barycentric rasterisation into an Image.

const MESH := "common/environment/generic/common/props/vanparamedicus_01/com_vanparamedicus_01_mesh"
const WRAP := "t_com_vanparamedicus_01_wrap"
const OUT := "C:/Users/mwalt/AppData/Local/Temp/claude/C--Users-mwalt/9b036b50-aae1-4310-8139-063d65d55375/scratchpad/edv32"
const STATE := 0x5d204a8c15b05b73
const W := 560
const H := 280

static func _proj(v3: Vector3, lo: Vector3, ext: Vector3, xa: int, za: int) -> Vector3:
	var px := (v3[xa] - lo[xa]) / maxf(ext[xa], 1e-5) * (W - 1)
	var py := (1.0 - (v3.y - lo.y) / maxf(ext.y, 1e-5)) * (H - 1)
	return Vector3(px, py, v3[za])


func _init() -> void:
	var gs = HighpolyGameSource.new()
	if not gs.open_map("MP_Aftermath"):
		print("no source: ", gs.error)
		quit(1)
		return
	# the wrap sheet, decompressed
	var wg := ""
	for g in gs.walk.gi.keys():
		if str(gs.walk.gi[g]).get_file().to_lower().begins_with(WRAP):
			wg = str(g)
			break
	var wt = gs._texture_for(wg, false, 1024)
	var wi: Image = (wt as Texture2D).get_image().duplicate()
	if wi.is_compressed():
		wi.decompress()
	wi.convert(Image.FORMAT_RGBA8)
	# the section, with every texcoord channel
	var d: PackedByteArray = gs.src.get_res(MESH)
	var ms = BF6MeshSet.new()
	var info: Dictionary = ms.parse(d)
	var L: Dictionary = info["lods"][0]
	var chunk := PackedByteArray()
	var cid: PackedByteArray = L.get("chunk_id", PackedByteArray())
	if not cid.is_empty():
		for form in BF6MeshSet.chunk_forms(cid):
			chunk = gs.src.get_chunk(str(form))
			if not chunk.is_empty():
				break
	for s in L["sections"]:
		var sec: Dictionary = s
		if int(sec.get("state_key", 0)) != STATE:
			continue
		var vcount := int(sec["vertex_count"])
		var voff := int(sec["vertex_offset"])
		var streams: Array = sec["streams"]
		var verts := PackedVector3Array()
		var chans := {}
		for el in sec["elements"]:
			var usage := int(el[0])
			if usage == 1:
				var r = ms._read_attr(chunk, voff, vcount, el, streams)
				verts.resize(vcount)
				for i in range(vcount):
					verts[i] = Vector3(r[0][i * r[1]], r[0][i * r[1] + 1],
						r[0][i * r[1] + 2])
			elif usage >= 33 and usage <= 37 and not chans.has(usage):
				var r2 = ms._read_attr(chunk, voff, vcount, el, streams)
				if not r2.is_empty() and int(r2[1]) >= 2:
					var arr := PackedVector2Array()
					arr.resize(vcount)
					for i in range(vcount):
						arr[i] = Vector2(r2[0][i * r2[1]], r2[0][i * r2[1] + 1])
					chans[usage] = arr
		var idx := ms._read_indices(chunk, int(L["vertex_size"]),
			int(L["index_size"]), bool(L["idx32"]),
			int(sec["start_index"]), int(sec["prim_count"]), vcount, voff)
		if verts.is_empty() or idx.is_empty():
			print("FAIL section geometry unreadable")
			quit(1)
			return
		# bounds: the long horizontal axis is the vehicle's length
		var lo := verts[0]
		var hi := verts[0]
		for v in verts:
			lo = lo.min(v)
			hi = hi.max(v)
		var ext := hi - lo
		var xa := 0 if ext.x >= ext.z else 2       # long axis index
		var za := 2 if xa == 0 else 0              # depth axis
		print("section verts %d ext (%.2f, %.2f, %.2f) long axis %d"
			% [vcount, ext.x, ext.y, ext.z, xa])
		for mode in ["u33", "u35", "u35h", "u36"]:
			var cu: int = 33 if mode == "u33" else (36 if mode == "u36" else 35)
			if not chans.has(cu):
				continue
			var uvs: PackedVector2Array = chans[cu]
			var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.15, 0.15, 0.18))
			var zbuf := PackedFloat32Array()
			zbuf.resize(W * H)
			zbuf.fill(-1e9)
			for k in range(0, idx.size() - 2, 3):
				var i0 := int(idx[k])
				var i1 := int(idx[k + 1])
				var i2 := int(idx[k + 2])
				var pa := _proj(verts[i0], lo, ext, xa, za)
				var pb := _proj(verts[i1], lo, ext, xa, za)
				var pc := _proj(verts[i2], lo, ext, xa, za)
				var minx := int(clampf(minf(pa.x, minf(pb.x, pc.x)), 0, W - 1))
				var maxx := int(clampf(maxf(pa.x, maxf(pb.x, pc.x)), 0, W - 1))
				var miny := int(clampf(minf(pa.y, minf(pb.y, pc.y)), 0, H - 1))
				var maxy := int(clampf(maxf(pa.y, maxf(pb.y, pc.y)), 0, H - 1))
				var den := (pb.y - pc.y) * (pa.x - pc.x) \
					+ (pc.x - pb.x) * (pa.y - pc.y)
				if absf(den) < 1e-6:
					continue
				for yy in range(miny, maxy + 1):
					for xx in range(minx, maxx + 1):
						var w0 := ((pb.y - pc.y) * (xx - pc.x) \
							+ (pc.x - pb.x) * (yy - pc.y)) / den
						var w1 := ((pc.y - pa.y) * (xx - pc.x) \
							+ (pa.x - pc.x) * (yy - pc.y)) / den
						var w2 := 1.0 - w0 - w1
						if w0 < -0.001 or w1 < -0.001 or w2 < -0.001:
							continue
						var depth := w0 * pa.z + w1 * pb.z + w2 * pc.z
						var o := yy * W + xx
						if depth <= zbuf[o]:
							continue
						zbuf[o] = depth
						var uv: Vector2 = uvs[i0] * w0 + uvs[i1] * w1 + uvs[i2] * w2
						if mode == "u35h":
							uv.y *= 0.5
						var tx := int(fposmod(uv.x, 1.0) * (wi.get_width() - 1))
						var ty := int(fposmod(uv.y, 1.0) * (wi.get_height() - 1))
						img.set_pixel(xx, yy, wi.get_pixel(tx, ty))
			img.save_png("%s/side_%s.png" % [OUT, mode])
			print("saved side_%s.png" % mode)
		quit(0)
		return
	print("FAIL carpaint section not found")
	quit(1)
