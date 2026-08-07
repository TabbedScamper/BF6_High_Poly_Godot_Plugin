extends SceneTree

# The GDScript EBX deserializer over the SAME partitions the Python one dumped.
#
#   godot --path <proj> --script ebx_gddump.gd -- <python.json> <out.json> [level] [exe]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Ebx := preload("res://bf6_ebx.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var ref_path := str(a[0]) if a.size() > 0 else ""
	var out_path := str(a[1]) if a.size() > 1 else ""
	var level := str(a[2]) if a.size() > 2 else "mp_dumbo"
	var exe := str(a[3]) if a.size() > 3 else \
			"C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6/SP/bf6.exe"

	var ref = JSON.parse_string(FileAccess.get_file_as_string(ref_path))
	if ref == null or not ref.has("records"):
		print("cannot read %s" % ref_path); quit(1); return

	var src := BF6Source.new()
	if not src.open() or not src.mount(level):
		print("cannot mount %s: %s" % [level, src.error]); quit(1); return
	var T := BF6Types.new()
	if not T.open(exe):
		print("cannot open %s: %s" % [exe, T.error]); quit(1); return
	print("mounted %s (%d ebx), types from %s" % [level, src.ebx.size(),
			exe.get_file()])

	var recs: Array = []
	var ok := 0
	var t0 := Time.get_ticks_msec()
	for r in ref["records"]:
		var name := str(r["name"])
		var rec := {"name": name}
		var raw: PackedByteArray = src.get_ebx(name)
		if raw.is_empty():
			rec["error"] = "no ebx bytes"
			recs.append(rec)
			continue
		# ONE types reader shared across every partition: it holds a 169 MB exe
		# and the layout cache that makes the walk affordable at all.
		var E = BF6Ebx.new(T, {})
		if not E.parse(raw):
			rec["error"] = E.error
			recs.append(rec)
			continue
		rec["partition"] = E.partition_guid
		rec["instances"] = E.instance_offsets.size()
		rec["exported"] = E.exported_instance_count
		rec["imports"] = E.imports.size()
		var tg: Array = []
		for g in E.type_guids:
			tg.append(BF6Ebx.guid_str(g))
		rec["type_guids"] = tg
		var rr: Array = []
		for x in E.resource_refs:
			rr.append("%016x" % x)
		rec["res_refs"] = rr
		var insts: Array = []
		for i in range(E.instance_offsets.size()):
			var v: Dictionary = E.read_instance(i)
			insts.append({
				"i": i,
				"guid": E.instance_guid(i),
				"type": E.instance_type(i),
				"fields": _jsonable(v, 0) if not v.is_empty() else null,
			})
		rec["inst"] = insts
		ok += 1
		recs.append(rec)
		print("  %-64s %d inst" % [name.right(64), rec["instances"]])

	print("read %d partition(s) in %d ms" % [recs.size(),
			Time.get_ticks_msec() - t0])
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"level": level, "records": recs}, " "))
	f.close()
	print("wrote %s: %d readable" % [out_path, ok])
	quit(0)


# Match the Python dump's shaping exactly, including the float rounding — the
# two reach the same bytes through different float paths and full precision
# would differ in the last bit for reasons that are not correctness.
func _jsonable(v, depth: int):
	if depth > 8:
		return "<deep>"
	if v is float:
		return snappedf(v, 0.0001)
	if v is bool or v is int or v == null:
		return v
	if v is String:
		return v
	if v is Array:
		var out: Array = []
		for x in v:
			out.append(_jsonable(x, depth + 1))
		return out
	if v is Dictionary:
		var out := {}
		for k in v:
			out[str(k)] = _jsonable(v[k], depth + 1)
		return out
	return str(v)
