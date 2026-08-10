@tool
extends SceneTree
# WHAT THE "EMPTY" GROUND LAYERS ACTUALLY BIND.
#
# Established so far, for MP_Aftermath: the palette declares 40 layers, 12 have
# an albedo, and the missing 28 are NOT missing from the depot - every one of
# their keys is in it, and their tiling constant reads back fine, which means
# the record is found and its parameters are being walked.
#
# So the texture parameters specifically are being dropped. Exactly three lines
# can do that:
#
#     if (pd["refs"] as Array).is_empty() or not SLOTS.has(n32): continue
#     ...
#     if nm == "": continue
#
# i.e. the parameter has no reference, its slot name hash is not in our
# hand-built SLOTS table, or the GUID it points at is not in the partition
# index. Those are three different fixes. Print every parameter of a few empty
# layers with which of the three applies.

const STRIDE := 32
const TH_TEXTURE_NAME := "TH_TEXTURE"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var map := str(args[0]) if args.size() > 0 else "MP_Aftermath"
	var want := int(args[1]) if args.size() > 1 else 6      # how many to dump

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("open failed: %s" % str(gs.error)); quit(1); return
	var low: String = gs.level
	var pidx: Dictionary = gs.walk.gi if gs.walk != null else {}

	var pal := BF6TerrainLayers.new()
	if not pal.load(gs.src, low, pidx):
		print("palette load failed: %s" % pal.error); quit(1); return

	var lg_name := ""
	for rn in gs.src.res.keys():
		var n := str(rn).to_lower()
		if n.findn("layergraphs") >= 0 and n.findn(low) >= 0 \
				and n.findn("depot") < 0:
			lg_name = str(rn)
			break
	var lg: PackedByteArray = gs.src.get_res(lg_name)
	var draw: PackedByteArray = gs.src.get_res(pal.depot_used)
	var depot := BF6Depot.new()
	if not depot.parse(draw):
		print("depot parse failed: %s" % depot.error); quit(1); return

	# a tally over EVERY empty layer, then a few dumped in full
	var reason := {"no refs": 0, "slot not in SLOTS": 0, "guid not indexed": 0,
		"would have worked": 0}
	var unknown_slots := {}
	var dumped := 0
	for i in range(pal.layers.size()):
		if pal.albedo_of(i) != "":
			continue
		var key := lg.decode_u64(pal.record_offset + i * STRIDE + 20)
		if not depot.key_to_record.has(key):
			continue
		var ps: Array = depot.params(int(depot.key_to_record[key]), draw)
		var show := dumped < want
		if show:
			dumped += 1
			print("")
			print("== layer %d, key 0x%016X, %d parameter(s)" % [i, key, ps.size()])
		for p in ps:
			var pd: Dictionary = p
			var n32 := int(pd["name32"])
			var is_tex: bool = int(pd["type_hash"]) == BF6Depot.TH_TEXTURE
			if not is_tex:
				if show:
					# Decoded as floats as well as bytes: every textureless layer
					# carries the same three unidentified constants, and if those
					# are a colour or a blend weight they are what the layer looks
					# like - the only thing left that could reproduce it.
					var raw = pd["raw"]
					var rb: PackedByteArray = raw if raw != null else PackedByteArray()
					var fs := PackedStringArray()
					var o := 0
					while o + 4 <= rb.size() and fs.size() < 4:
						fs.append("%.4f" % rb.decode_float(o))
						o += 4
					print("   const  0x%08X  %2d bytes  [%s]" % [n32, rb.size(),
						", ".join(fs)])
				continue
			var refs: Array = pd["refs"]
			var why := ""
			if refs.is_empty():
				why = "no refs"
			elif not BF6TerrainLayers.SLOTS.has(n32):
				why = "slot not in SLOTS"
				unknown_slots[n32] = int(unknown_slots.get(n32, 0)) + 1
			elif str(pidx.get(str((refs[0] as Array)[1]), "")) == "":
				why = "guid not indexed"
			else:
				why = "would have worked"
			reason[why] = int(reason.get(why, 0)) + 1
			if show:
				print("   TEX    0x%08X  %d ref(s)  ->  %s%s" % [n32, refs.size(),
					why,
					"" if refs.is_empty() else ("   " + str(pidx.get(
						str((refs[0] as Array)[1]), "(unnamed)")).get_file())])

	print("")
	print("== every texture parameter on every empty layer, by why it was dropped")
	for k in reason:
		print("   %-22s %d" % [k, int(reason[k])])
	if not unknown_slots.is_empty():
		print("")
		print("== slot name hashes NOT in SLOTS, by how often they appear")
		var rows: Array = []
		for k in unknown_slots:
			rows.append([int(unknown_slots[k]), int(k)])
		rows.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
		for r in rows:
			print("   %5d  0x%08X" % [int(r[0]), int(r[1])])
	quit(0)
