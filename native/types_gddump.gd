extends SceneTree

# The GDScript type reader over the SAME types the Python one dumped.
#
# Reads the GUID list out of the Python dump rather than picking its own, so
# both are judged on identical input.
#
#   godot --path <proj> --script types_gddump.gd -- <python.json> <out.json> [exe]

const BF6Types := preload("res://bf6_types.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var ref_path := str(a[0]) if a.size() > 0 else ""
	var out_path := str(a[1]) if a.size() > 1 else ""
	var exe := str(a[2]) if a.size() > 2 else \
			"C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6/SP/bf6.exe"

	var ref = JSON.parse_string(FileAccess.get_file_as_string(ref_path))
	if ref == null or not ref.has("records"):
		print("cannot read the reference dump at %s" % ref_path)
		quit(1); return

	var T := BF6Types.new()
	var t0 := Time.get_ticks_msec()
	if not T.open(exe):
		print("cannot open %s: %s" % [exe, T.error])
		quit(1); return
	print("loaded %s in %d ms" % [exe.get_file(), Time.get_ticks_msec() - t0])

	var recs: Array = []
	t0 = Time.get_ticks_msec()
	for r in ref["records"]:
		var gh := str(r["guid_hex"])
		var g := _unhex(gh)
		var rec := {"guid_hex": gh}
		rec["own"] = _summarize(T.layout(g))
		rec["full"] = _summarize(T.layout_full(g))
		var full: Dictionary = T.layout_full(g)
		if not full.is_empty():
			var res: Array = []
			var fields: Array = full["fields"]
			for i in range(mini(24, fields.size())):
				var f: Dictionary = fields[i]
				var tv := int(f["typeVA"])
				var e := {"typeVA": tv, "r": null}
				if tv != 0:
					var t: Dictionary = T.resolve(tv)
					if not t.is_empty():
						e["r"] = {"guid": t["guid"], "te": t["te"],
								  "cat": t["cat"], "elemVA": t["elemVA"]}
				res.append(e)
			rec["resolved"] = res
		recs.append(rec)
	var ms := Time.get_ticks_msec() - t0
	var st: Dictionary = T.stats()
	# Parenthesised: % binds tighter than +, so without these the format applies
	# to the second fragment alone and prints the literal template.
	print(("resolved %d type(s) in %d ms  (%d searches, %d fell back to the "
			+ "whole file, %d cached)")
			% [recs.size(), ms, int(st["searches"]), int(st["fallbacks"]),
			   int(st["cached"])])

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"exe": exe, "records": recs}, " "))
	f.close()
	print("wrote %s" % out_path)
	quit(0)


func _summarize(lay: Dictionary):
	if lay.is_empty():
		return null
	var fs: Array = []
	for x in lay["fields"]:
		fs.append({"nameHash": int(x["nameHash"]), "flags": int(x["flags"]),
				   "offset": int(x["offset"]), "typeVA": int(x["typeVA"])})
	return {
		"guid": lay["guid"], "nameHash": int(lay["nameHash"]),
		"flags": int(lay["flags"]), "size": int(lay["size"]),
		"align": int(lay["align"]), "type_enum": int(lay["type_enum"]),
		"fieldCount": int(lay["fieldCount"]),
		"signature": int(lay["signature"]),
		"superClassVA": int(lay["superClassVA"]),
		"fields": fs,
	}


func _unhex(h: String) -> PackedByteArray:
	var b := PackedByteArray()
	for i in range(0, h.length(), 2):
		b.append(h.substr(i, 2).hex_to_int())
	return b
