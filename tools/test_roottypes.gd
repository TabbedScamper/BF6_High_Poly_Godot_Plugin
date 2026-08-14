@tool
extends SceneTree
# DO THE TYPES THEIR LEVEL ASKS FOR EXIST IN OUR EXECUTABLE?
#
# Their log named the exact partition and the exact failure:
#
#   SP/bf6.exe: 0 rows, 39 instances seen, 0 skipped,
#               root game/glaciermp/levels/mp_badlands/mp_badlands.ebx
#   SP/bf6.exe: 22 type(s) could not be described by this executable
#
# A lookup already falls back from the typeinfo section to a scan of the whole
# file, so a miss means the type id is absent from all 176 MB of their
# executable. That leaves two possibilities and their machine cannot tell them
# apart: their read came back short, or their executable genuinely lacks ids
# that their level data references.
#
# This settles it WITHOUT them. Same level, same partition, our install: take
# every instance's type id out of the root partition and look each one up. If
# all of them resolve here, the ids exist, their copy is missing them, and their
# game files are inconsistent rather than our reader being wrong. If some fail
# here too, the fault is ours and I can fix it without involving them at all.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_roottypes.gd -- MP_Badlands

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _init() -> void:
	var map := "MP_Badlands"
	for a in OS.get_cmdline_user_args():
		if str(a) != "":
			map = str(a)

	var gs = GS.new()
	if not gs.open_map(map, "", Callable(), {"placements": false}):
		print("open failed: ", gs.error)
		quit(1)
		return
	var w = gs.walk
	print("exe in use: %s" % str(gs._exe_used))
	print("read %d of %d bytes, typeinfo %d bytes"
		% [gs.types.data.size(), gs.types.file_size, gs.types.ti_size])

	# The same resolution ladder run() uses, so this lands on the partition their
	# log named rather than on something merely similar.
	var leaf := map.to_lower()
	var start = null
	for cand in ["%s/%s" % [leaf, leaf], leaf,
			"game/glaciermp/levels/%s/%s" % [leaf, leaf]]:
		start = w.resolve_name(cand)
		if start != null:
			print("root resolved via: %s" % cand)
			break
	if start == null:
		print("could not resolve the level root, so this proves nothing")
		quit(1)
		return

	var dz = w.open_ebx(str(start))
	if dz == null:
		print("could not open the root partition")
		quit(1)
		return

	var n: int = dz.instance_offsets.size()
	print("root partition holds %d instance(s)" % n)
	var seen := {}
	var ok := 0
	var bad: Array[String] = []
	for i in range(n):
		var tb: PackedByteArray = dz.instance_type_bytes(i)
		if tb.is_empty():
			continue
		var g := BF6Types.guid_str(tb)
		if seen.has(g):
			continue
		seen[g] = true
		var lay: Dictionary = gs.types.layout_full(tb)
		if lay.is_empty():
			bad.append(g)
		else:
			ok += 1
	print("")
	print("distinct types in that partition: %d" % seen.size())
	print("  resolved by our executable:     %d" % ok)
	print("  NOT resolved:                   %d" % bad.size())
	for g in bad:
		print("      %s" % g)
	print("")
	if bad.is_empty():
		print("VERDICT: every type this level asks for exists in our executable.")
		print("Their copy cannot find 22 of them, so their game files and their")
		print("executable are from different builds. A repair of the install is")
		print("the fix, and there is nothing to change in the reader.")
	else:
		print("VERDICT: %d of these fail HERE too, on a known-good install, so"
			% bad.size())
		print("this is our lookup and not their install. Fixable without them.")
	quit(0)
