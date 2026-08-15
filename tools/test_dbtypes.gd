@tool
extends SceneTree
# THE WHOLE POINT, PROVEN END TO END:
#   generate a type database from a READABLE (Steam) install,
#   then read an EA install's map data through it, with the EA executable never
#   touched. If the map comes back, EA support needs no decryption at all.
#
# STEP 1  open Steam, record every layout/resolve during a real walk, save_db.
# STEP 2  open EA (its executable is encrypted and useless), swap the walk's
#         type reader for one served entirely from the database, walk again.
# STEP 3  compare row counts. Equal means the schema is storefront-independent
#         and the database carries it.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#       --script res://hp_test/test_dbtypes.gd -- \
#       "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6" \
#       "C:/Program Files/EA Games/Battlefield 6" MP_Badlands

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
const DB := "user://bf6_typedb_test.bin"

var _fail: Array[String] = []


func _ck(name: String, ok: bool, detail := "") -> void:
	print(("  PASS  " if ok else "  FAIL  ") + name + ("   " + detail if detail != "" else ""))
	if not ok:
		_fail.append(name)


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var steam := str(a[0]) if a.size() > 0 else "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	var ea := str(a[1]) if a.size() > 1 else "C:/Program Files/EA Games/Battlefield 6"
	var map := str(a[2]) if a.size() > 2 else "MP_Badlands"

	# ---- STEP 1: generate from Steam ----------------------------------------
	print("STEP 1  generating a type database from the readable install")
	print("        %s" % steam)
	var gsS = GS.new()
	if not gsS.open_map(map, steam, Callable(), {"placements": false}):
		print("  could not open Steam install: %s" % gsS.error); quit(1); return
	print("  Steam type table entropy: %.2f bits (should be plain)"
		% float(gsS.types.ti_entropy().get("bits", -1)))
	gsS.types.record()
	if not gsS.ensure_placements():
		print("  Steam walk failed: %s" % gsS.error); quit(1); return
	var steam_rows: int = gsS.walk.rows.size()
	print("  Steam walked %d placements while recording" % steam_rows)
	if not gsS.types.save_db(DB):
		print("  save_db failed: %s" % gsS.types.error); quit(1); return
	var sz := 0
	var fh := FileAccess.open(DB, FileAccess.READ)
	if fh != null:
		sz = fh.get_length(); fh.close()
	print("  database: %d types, %.1f MB on disk"
		% [gsS.types._db_layouts.size(), sz / 1048576.0])
	_ck("generated a non-empty database", steam_rows > 0 and gsS.types._db_layouts.size() > 0)

	# ---- STEP 2: read EA through the database --------------------------------
	print("")
	print("STEP 2  reading the EA install through that database")
	print("        %s" % ea)
	var gsE = GS.new()
	if not gsE.open_map(map, ea, Callable(), {"placements": false}):
		print("  could not open EA install: %s" % gsE.error); quit(1); return
	print("  EA type table entropy: %.2f bits (encrypted, expected ~8.0)"
		% float(gsE.types.ti_entropy().get("bits", -1)))

	# Confirm the EA executable really is unreadable, so the test cannot pass by
	# accidentally falling back to it.
	var direct: int = gsE.walk.rows.size()
	var db := BF6Types.new()
	if not db.open_db(DB):
		print("  open_db failed: %s" % db.error); quit(1); return
	print("  loaded database, serving from it now (from_db=%s)" % str(db.from_db))
	gsE.walk.use_types(db)
	gsE.walk.run(gsE.level)
	var ea_rows: int = gsE.walk.rows.size()
	print("  EA walked %d placements through the database" % ea_rows)

	# ---- STEP 3: verdict ----------------------------------------------------
	print("")
	_ck("EA read produced the whole map", ea_rows > 0, "%d rows" % ea_rows)
	_ck("EA matched Steam exactly", ea_rows == steam_rows,
		"EA %d vs Steam %d" % [ea_rows, steam_rows])
	_ck("the EA executable alone reads nothing (so the DB is what worked)",
		direct == 0, "direct=%d" % direct)

	print("")
	if _fail.is_empty():
		print("ALL PASS: an EA install reads its whole map through a database")
		print("generated from a Steam install. No decryption. The plugin only")
		print("ever read a data file.")
	else:
		print("FAILURES: " + ", ".join(_fail))
	DirAccess.remove_absolute(DB)
	quit(0 if _fail.is_empty() else 1)
