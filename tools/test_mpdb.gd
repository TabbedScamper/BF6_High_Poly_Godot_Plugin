@tool
extends SceneTree
# WHY DOES THE MP TYPE DATABASE PRODUCE NOTHING?
#
# An EA App user's SP executable ships its type table ENCRYPTED (8.00 bits/byte
# against our 3.38), so the reader can never describe types from it. But their MP
# executable is plain and resolves every lookup. They have a readable database;
# we just get zero rows out of it, on our own known-good install too, where SP
# gives 13,447 on this map.
#
# The retail multiplayer game loads mp_badlands using that MP database, so it
# MUST be able to describe this data. Zero rows therefore looks like our bug
# rather than a real incompatibility - and if it is, fixing it unblocks every EA
# App user rather than one.
#
# So: take the level root's types and ask BOTH databases to describe each one.
#   - does the type resolve at all
#   - how many fields does it declare
#   - which of the walk's fields does it declare
# The walk keeps an instance only if it declares one of WALK_FIELDS, so a type
# that resolves but declares none is invisible to the traversal, and that is
# exactly what zero rows with zero skips looks like.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#           --script res://hp_test/test_mpdb.gd -- MP_Badlands

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
	var sp = gs.types
	var sp_path: String = gs._exe_used

	var other := ""
	for c in BF6Types.exe_candidates(gs.src.game):
		if c != sp_path and FileAccess.file_exists(c):
			other = c
			break
	var mp := BF6Types.new()
	if other == "" or not mp.open(other):
		print("no second executable")
		quit(1)
		return
	print("SP database: %s" % sp_path)
	print("MP database: %s" % other)

	var start = w.resolve_name("%s/%s" % [map.to_lower(), map.to_lower()])
	var dz = w.open_ebx(str(start))
	if dz == null:
		print("could not open the root partition")
		quit(1)
		return

	# The walk's own field set, so this measures the real gate and not a copy.
	var wf = BF6Walk.WALK_FIELDS
	print("the walk keys on %d field name hash(es)" % wf.size())
	print("")
	print("%-38s %-22s %-22s" % ["type guid", "SP", "MP"])

	var seen := {}
	var sp_ok := 0
	var mp_ok := 0
	var sp_walk := 0
	var mp_walk := 0
	for i in range(dz.instance_offsets.size()):
		var tb: PackedByteArray = dz.instance_type_bytes(i)
		if tb.is_empty():
			continue
		var g := BF6Types.guid_str(tb)
		if seen.has(g):
			continue
		seen[g] = true

		var a: Dictionary = sp.layout_full(tb)
		var b: Dictionary = mp.layout_full(tb)
		var an := _walk_fields_in(a, wf)
		var bn := _walk_fields_in(b, wf)
		if not a.is_empty():
			sp_ok += 1
			if an > 0:
				sp_walk += 1
		if not b.is_empty():
			mp_ok += 1
			if bn > 0:
				mp_walk += 1
		print("%-38s %-22s %-22s" % [g, _desc(a, an), _desc(b, bn)])

	print("")
	print("distinct types            %d" % seen.size())
	print("resolved   SP %d   MP %d" % [sp_ok, mp_ok])
	print("declare a walk field  SP %d   MP %d" % [sp_walk, mp_walk])
	print("")
	if mp_ok == 0:
		print("MP resolves NOTHING, so the two databases do not share type ids.")
	elif mp_ok > 0 and mp_walk == 0:
		print("MP describes these types but reports NONE of the walk's fields.")
		print("The gate then discards every instance and the traversal never")
		print("descends, which is exactly zero rows with zero skips. The field")
		print("name hashes are the thing to compare next.")
	elif mp_walk > 0:
		print("MP DOES report walk fields on %d type(s), so the gate is not what" % mp_walk)
		print("empties it. The loss is further in: decode or the field offsets.")
	quit(0)


func _walk_fields_in(lay: Dictionary, wf) -> int:
	if lay.is_empty():
		return 0
	var n := 0
	for f in lay.get("fields", []):
		if wf.has(int((f as Dictionary)["nameHash"])):
			n += 1
	return n


func _desc(lay: Dictionary, hits: int) -> String:
	if lay.is_empty():
		return "unresolved"
	return "%d fields, %d walk" % [(lay.get("fields", []) as Array).size(), hits]
