extends SceneTree

# Does MeshScatteringDatabase parse, and are its names real?
#
# Two checks, both from dfanz0r's finding, because they are the two that a
# variable-length walk can actually fail:
#
#   EXACT END. Each record starts with a nul-terminated name, so nothing after
#   it is aligned and a wrong offset or stride desynchronises within a record
#   or two. Landing on the final byte of the payload is therefore near-proof;
#   his figures are 44 records / 17,972 bytes on mp_dumbo, 88 / 57,603 on
#   granite, 49 / 20,221 on aftermath, 43 / 26,745 on contaminated.
#
#   REAL NAMES. Every record name should resolve in the same mount to a
#   resource of type MeshSet (0x49B156D4) — 44 of 44 on dumbo. A name that does
#   not resolve means the string was read at the wrong place, which an exact
#   end alone would not catch if the error were self-cancelling.
#
#   godot --headless --path <proj> --script test_scatter.gd -- [level]

const BF6Source := preload("res://bf6_source.gd")
const BF6Scatter := preload("res://bf6_scatter.gd")

const MESHSET_RES_TYPE := 0x49B156D4


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	for x in a:
		if str(x) != "":
			level = str(x)
			break

	var src = BF6Source.new()
	if not src.open() or not src.mount(level):
		print("FAIL mount: %s" % src.error)
		quit(1); return

	var name := BF6Scatter.find_res(src, level)
	if name == "":
		print("FAIL: no MeshScatteringDatabase in the mount for %s" % level)
		quit(1); return
	print("resource: %s" % name)
	var raw := src.get_res(name)
	print("          %d bytes" % raw.size())

	var sc = BF6Scatter.new()
	var ok: bool = sc.parse(raw)
	if not ok:
		print("FAIL parse: %s" % sc.error)
		quit(1); return
	var st: Dictionary = sc.stats()
	print("\nheader: %s" % str(sc.header))
	print("records          %d (declared %d)" % [st["records"], st["declared"]])
	print("with point lists %d, %d points total" % [st["with_points"], st["points"]])
	print("walk ended at    %d of %d bytes" % [st["consumed"], raw.size()])

	var fail := 0
	if not sc.exact(raw.size()):
		print("\nFAIL: the walk did not land on the final byte — %d of %d"
			% [st["consumed"], raw.size()])
		fail += 1
	if int(st["records"]) != int(st["declared"]):
		print("\nFAIL: found %d records, header declares %d"
			% [st["records"], st["declared"]])
		fail += 1

	# Every name a real MeshSet in this mount.
	var resolved := 0
	var wrong_type := 0
	var missing: Array = []
	for nm in sc.names():
		var info = src.res_info(str(nm))
		if info == null:
			if missing.size() < 6:
				missing.append(str(nm))
			continue
		resolved += 1
		if int((info as Dictionary)["type"]) != MESHSET_RES_TYPE:
			wrong_type += 1
	print("\nnames resolving to a resource: %d of %d" % [resolved, sc.records.size()])
	print("of those, NOT a MeshSet:       %d" % wrong_type)
	for m in missing:
		print("   missing: %s" % m)
	if resolved != sc.records.size():
		print("\nFAIL: %d name(s) do not resolve" % (sc.records.size() - resolved))
		fail += 1
	if wrong_type > 0:
		print("\nFAIL: %d name(s) are not MeshSets" % wrong_type)
		fail += 1

	print("\nthe catalogue:")
	for i in range(mini(14, sc.records.size())):
		var r: Dictionary = sc.records[i]
		print("   %-58s dist %6.0f  ratio %.2f  %d pts"
			% [str(r["name"]).get_file().substr(0, 58), r["distance"],
			   r["ratio"], (r["points"] as PackedVector3Array).size()])

	print("\n%s" % ("PASS" if fail == 0 else "FAIL"))
	quit(0 if fail == 0 else 1)
