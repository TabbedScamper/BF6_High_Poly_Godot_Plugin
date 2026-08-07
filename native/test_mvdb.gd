extends SceneTree

# Does the GDScript MVDB resolver agree with mvdb_v2.py?
#
# This is the half of #58 that decides what a variation LOOKS like. The walk
# says a placement is com_metrobus_01 with variation hash 2575843486; this says
# that hash means the Cairo livery and names the textures to bind. Get it wrong
# and every variant renders as the default — which looks like working code,
# because a bus with the wrong paint is still a bus.
#
# Compared per (mesh, variation) pair AND per parameter, because they fail
# separately: the pair set can be right while the bindings are empty, and a
# binding can be present but point at the wrong texture.
#
#   godot --headless --path <proj> --script test_mvdb.gd -- <ref.json> <level> [game]

const BF6Source := preload("res://bf6_source.gd")
const BF6Types := preload("res://bf6_types.gd")
const BF6Mvdb := preload("res://bf6_mvdb.gd")


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: test_mvdb.gd -- <ref.json> <level> [game_dir]")
		quit(2); return
	var ref_path := str(args[0])
	var level := str(args[1])
	var game := str(args[2]) if args.size() > 2 else ""

	var f := FileAccess.open(ref_path, FileAccess.READ)
	if f == null:
		print("FAIL no reference at %s" % ref_path)
		quit(1); return
	var ref = JSON.parse_string(f.get_as_text())
	f.close()
	if not (ref is Dictionary) or not (ref as Dictionary).has("pairs"):
		print("FAIL reference json has no 'pairs'")
		quit(1); return
	var mvdb_name := str((ref as Dictionary).get("mvdb", ""))
	var ref_pairs: Dictionary = (ref as Dictionary)["pairs"]
	print("reference %s  (%d pairs)" % [mvdb_name, ref_pairs.size()])

	var src = BF6Source.new()
	if not src.open(game):
		print("FAIL open: %s" % src.error)
		quit(1); return
	if not src.mount(level):
		print("FAIL mount: %s" % src.last_error())
		quit(1); return
	var types = BF6Types.new()
	var exe := ""
	for c in BF6Types.exe_candidates(src.game):
		if FileAccess.file_exists(c):
			exe = c
			break
	if exe == "" or not types.open(exe):
		print("FAIL types: %s" % types.error)
		quit(1); return

	# THE SAME database the reference read, by name. Picking "a" mvdb would make
	# any difference unattributable.
	var data := src.get_ebx(mvdb_name)
	if data.is_empty():
		print("FAIL could not read %s: %s" % [mvdb_name, src.last_error()])
		quit(1); return

	var gi := src.partition_index()
	var e := BF6Ebx.new(types, gi)
	if not e.parse(data):
		print("FAIL parse %s: %s" % [mvdb_name, e.error])
		quit(1); return

	var t0 := Time.get_ticks_msec()
	var m = BF6Mvdb.new(gi)
	var ours: Dictionary = m.resolve(e)
	print("ours      %d pairs in %d ms" % [ours.size(), Time.get_ticks_msec() - t0])

	# ---- pairs -------------------------------------------------------------
	var only_ours: Array = []
	var only_ref: Array = []
	for k in ours:
		if not ref_pairs.has(k):
			only_ours.append(k)
	for k in ref_pairs:
		if not ours.has(k):
			only_ref.append(k)
	print("\nPAIRS   ours %d, python %d;  %d only ours, %d only python"
		% [ours.size(), ref_pairs.size(), only_ours.size(), only_ref.size()])
	for k in only_ref.slice(0, 5):
		print("   python only: %s" % k)
	for k in only_ours.slice(0, 5):
		print("   ours only  : %s" % k)

	# ---- bindings ----------------------------------------------------------
	var same := 0
	var missing := 0
	var extra := 0
	var wrong := 0
	var with_any := 0
	var examples: Array = []
	for k in ref_pairs:
		if not ours.has(k):
			continue
		var rp: Dictionary = ref_pairs[k]
		var op: Dictionary = ours[k]
		if not rp.is_empty():
			with_any += 1
		for pn in rp:
			if not op.has(pn):
				missing += 1
				if examples.size() < 8:
					examples.append("missing %s on %s" % [pn, k])
			elif str(op[pn]) != str(rp[pn]):
				wrong += 1
				if examples.size() < 8:
					examples.append("differs %s on %s:\n      ours   %s\n      python %s"
						% [pn, k, str(op[pn]), str(rp[pn])])
			else:
				same += 1
		for pn in op:
			if not rp.has(pn):
				extra += 1
				if examples.size() < 8:
					examples.append("extra %s on %s -> %s" % [pn, k, str(op[pn])])
	print("BINDINGS %d identical, %d missing, %d extra, %d pointing elsewhere"
		% [same, missing, extra, wrong])
	print("         (%d python pairs carry any binding at all)" % with_any)
	for x in examples:
		print("   %s" % x)

	var pass_all: bool = (only_ours.is_empty() and only_ref.is_empty()
		and missing == 0 and extra == 0 and wrong == 0)
	print("\n%s" % ("PASS — the GDScript MVDB resolver agrees with Python"
		if pass_all else "FAIL — see above"))
	quit(0 if pass_all else 1)
