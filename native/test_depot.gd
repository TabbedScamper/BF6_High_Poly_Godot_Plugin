extends SceneTree

# Does the GDScript ShaderBlockDepot parser agree with shaderblock.py?
#
# This is the link that decides what a prop LOOKS like, so agreement has to be
# per section and per slot, not "we both found some textures":
#
#   CONTAINER  the same record count and the same key count. A container parse
#              that drifts by one record still produces plausible output for
#              every key that happens to land in the right blob.
#   JOIN       the same state key per section, and the same found/missed
#              verdict. The key lives at +0x130 of a 368-byte section and a
#              wrong offset reads a neighbouring field that also looks like a
#              hash.
#   SLOTS      the same texture file guid in the same slot. Comparing slot
#              COUNTS would pass while basecolor and normal were swapped —
#              and the full 32-bit name hash is what separates them, because
#              BaseColor/BaseColorVeg share their top half and so do
#              Emissive/Alpha.
#
#   godot --headless --path <proj> --script test_depot.gd -- <ref.json> <level>

const BF6Source := preload("res://bf6_source.gd")
const BF6Depot := preload("res://bf6_depot.gd")
const BF6MeshSet := preload("res://bf6_meshset.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var pos: Array = []
	for x in a:
		if str(x) != "":
			pos.append(str(x))
	if pos.size() < 1:
		print("usage: test_depot.gd -- <ref.json> [level]")
		quit(2); return
	var ref_path := str(pos[0])
	var level := str(pos[1]) if pos.size() > 1 else "mp_dumbo"

	var f := FileAccess.open(ref_path, FileAccess.READ)
	if f == null:
		print("FAIL no reference at %s" % ref_path)
		quit(1); return
	var ref = JSON.parse_string(f.get_as_text())
	f.close()
	if not (ref is Dictionary):
		print("FAIL reference is not an object")
		quit(1); return
	var rdep: Dictionary = (ref as Dictionary)["depot"]
	var rmeshes: Array = (ref as Dictionary)["meshes"]
	print("reference %s\n   %d records, %d keys, %d meshes"
		% [str(rdep["name"]).get_file(), int(rdep["records"]),
		   int(rdep["keys"]), rmeshes.size()])

	var src = BF6Source.new()
	if not src.open():
		print("FAIL open: %s" % src.error); quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error()); quit(1); return

	# THE SAME depot the reference read, by name.
	var dbytes := src.get_res(str(rdep["name"]))
	if dbytes.is_empty():
		print("FAIL could not read %s: %s" % [rdep["name"], src.last_error()])
		quit(1); return
	var dep = BF6Depot.new()
	var t0 := Time.get_ticks_msec()
	if not dep.parse(dbytes):
		print("FAIL depot parse: %s" % dep.error)
		quit(1); return
	print("ours      %d records, %d keys  (%d ms, %d bytes)"
		% [dep.records.size(), dep.key_to_record.size(),
		   Time.get_ticks_msec() - t0, dbytes.size()])

	var container_ok: bool = dep.records.size() == int(rdep["records"]) \
		and dep.key_to_record.size() == int(rdep["keys"])
	print("\nCONTAINER %s" % ("MATCH" if container_ok else "DIFFER"))

	# ---- join + slots ------------------------------------------------------
	var ms := BF6MeshSet.new()
	var sec_total := 0
	var key_bad := 0
	var found_bad := 0
	var slot_missing := 0
	var slot_extra := 0
	var slot_wrong := 0
	var slot_same := 0
	var examples: Array = []
	for m in rmeshes:
		var mm: Dictionary = m
		var md := src.get_res(str(mm["name"]))
		if md.is_empty():
			continue
		var info := ms.parse(md)
		if info.is_empty():
			continue
		# Flatten our sections in the same (lod, index) order the reference used.
		var ours := {}
		var lods: Array = info.get("lods", [])
		for li in range(lods.size()):
			for s in (lods[li] as Dictionary).get("sections", []):
				ours["%d:%d" % [li, int((s as Dictionary)["index"])]] = s
		for rs in (mm["sections"] as Array):
			var r: Dictionary = rs
			sec_total += 1
			var k := "%d:%d" % [int(r["lod"]), int(r["index"])]
			if not ours.has(k):
				key_bad += 1
				continue
			var o: Dictionary = ours[k]
			var our_key := BF6Depot.key_hex(int(o["state_key"]))
			if our_key != str(r["state_key"]):
				key_bad += 1
				if examples.size() < 6:
					examples.append("key %s: ours %s python %s"
						% [str(r["material"]).left(30), our_key, r["state_key"]])
				continue
			var our_found: bool = dep.key_to_record.has(int(o["state_key"]))
			if our_found != bool(r["found"]):
				found_bad += 1
				if examples.size() < 6:
					examples.append("found %s: ours %s python %s"
						% [str(r["material"]).left(30), our_found, r["found"]])
				continue
			if not our_found:
				continue
			var tex: Dictionary = dep.textures_for(int(o["state_key"]), dbytes)
			tex.erase("constants")
			# Ours is keyed by slot NAME where known; the reference is keyed by
			# the raw name32 hex. Compare on the hash, which is what both
			# actually decided from.
			var ours_by_hash := {}
			for slot in tex:
				var h := -1
				for kk in BF6Depot.SLOT_NAME:
					if str(BF6Depot.SLOT_NAME[kk]) == str(slot):
						h = int(kk)
						break
				if h < 0 and str(slot).begins_with("nh_"):
					h = str(slot).substr(3).hex_to_int()
				if h >= 0:
					ours_by_hash["%08x" % h] = str(tex[slot])
			var rt: Dictionary = r["textures"]
			for h in rt:
				if not ours_by_hash.has(h):
					slot_missing += 1
					if examples.size() < 6:
						examples.append("missing slot %s on %s"
							% [h, str(r["material"]).left(30)])
				elif str(ours_by_hash[h]) != str(rt[h]):
					slot_wrong += 1
					if examples.size() < 6:
						examples.append("slot %s differs on %s:\n      ours   %s\n      python %s"
							% [h, str(r["material"]).left(30),
							   ours_by_hash[h], rt[h]])
				else:
					slot_same += 1
			for h in ours_by_hash:
				if not rt.has(h):
					slot_extra += 1
					if examples.size() < 6:
						examples.append("extra slot %s on %s -> %s"
							% [h, str(r["material"]).left(30), ours_by_hash[h]])

	print("JOIN      %d sections; %d state keys differ, %d found/missed differ"
		% [sec_total, key_bad, found_bad])
	print("SLOTS     %d identical, %d missing, %d extra, %d pointing elsewhere"
		% [slot_same, slot_missing, slot_extra, slot_wrong])
	for e in examples:
		print("   %s" % e)

	var ok: bool = container_ok and key_bad == 0 and found_bad == 0 \
		and slot_missing == 0 and slot_extra == 0 and slot_wrong == 0 \
		and slot_same > 0
	print("\n%s" % ("PASS — the GDScript depot agrees with Python"
		if ok else "FAIL — see above"))
	quit(0 if ok else 1)
