@tool
extends SceneTree
# GENERATE THE SHIPPABLE TYPE DATABASE. Source-agnostic by design.
#
# The schema is a property of the game build, so it can be recorded once from any
# readable copy and then serves every install of that build - including EA ones,
# whose executable this reader cannot decrypt. The database is a few thousand
# type layouts, not the 176 MB executable, and it contains NO game content: field
# names, offsets and type ids only, the struct-definition layer.
#
# The one thing generation needs is a PLAIN (unencrypted) executable to read the
# types from. Two ways to have one, and this tool does not care which:
#   - a Steam install, whose bf6.exe is plain on disk, or
#   - an EA executable that has been OOA-lifted to plain by a separate tool.
# Point --exe at whichever. The --game install only supplies the level data to
# walk, so it can be the SAME EA install whose exe you lifted, which is how the
# Steam dependency is removed entirely.
#
#     Godot --headless --path C:\PortalSDK\GodotProject \
#       --script res://hp_test/gen_typedb.gd -- \
#       --exe  "<plain bf6.exe>" \
#       --game "<install dir with the level data>" \
#       --out  "res://addons/highpoly_toggle/data/bf6_types.bin" \
#       --maps MP_Badlands,MP_Aftermath,MP_Dumbo,MP_Isolated
#
# Walking several diverse maps captures the shared type set; a map that later
# hits a type not recorded degrades gracefully (that type's objects are skipped
# and counted) and tells you to regenerate with it included.

const GS := preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")


func _arg(name: String, def := "") -> String:
	var a := OS.get_cmdline_user_args()
	for i in range(a.size() - 1):
		if str(a[i]) == name:
			return str(a[i + 1])
	return def


func _init() -> void:
	var exe := _arg("--exe")
	var game := _arg("--game")
	var out := _arg("--out", "res://addons/highpoly_toggle/data/bf6_types.bin")
	var maps := _arg("--maps", "MP_Badlands").split(",", false)
	if exe == "" or game == "":
		print("need --exe <plain bf6.exe> and --game <install dir>")
		quit(1)
		return

	# READ TYPES FROM THE PLAIN EXECUTABLE, refusing an encrypted one outright so
	# a database is never silently built empty. 7.5 bits is far above real schema
	# (~3.4) and far below ciphertext (~8.0), so it cannot misfire either way.
	var types := BF6Types.new()
	if not types.open(exe):
		print("could not open %s: %s" % [exe, types.error]); quit(1); return
	var bits := float(types.ti_entropy().get("bits", 9.0))
	print("type table entropy: %.2f bits" % bits)
	if bits > 7.5:
		print("REFUSING: %s is encrypted (%.2f bits). Supply a plain executable "
			% [exe.get_file(), bits] + "- a Steam bf6.exe, or an OOA-lifted one.")
		quit(1)
		return
	types.record()

	# Walk each map with THIS type reader, against the install's data. A shared
	# BF6Types accumulates every map's types into one database.
	var total := 0
	for m in maps:
		var name := str(m).strip_edges()
		if name == "":
			continue
		var gs = GS.new()
		if not gs.open_map(name, game, Callable(), {"placements": false}):
			print("  %-16s open failed: %s" % [name, gs.error]); continue
		# Same reader across every map, so the database is cumulative. Inject it
		# everywhere the placement path looks, and block the empty-walk retry so
		# it cannot swap our readable reader back for the install's encrypted one.
		gs.types = types
		gs.walk.use_types(types)
		gs._types_retried = true
		gs.ensure_placements()
		var n: int = gs.walk.rows.size()
		total += n
		print("  %-16s %d placements, database now %d types"
			% [name, n, types._db_layouts.size()])

	if types._db_layouts.is_empty():
		print("nothing recorded - no map walked. Not writing an empty database.")
		quit(1)
		return
	var abs_out := ProjectSettings.globalize_path(out) if out.begins_with("res://") or out.begins_with("user://") else out
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
	if not types.save_db(abs_out):
		print("save failed: %s" % types.error); quit(1); return
	var sz := 0
	var fh := FileAccess.open(abs_out, FileAccess.READ)
	if fh != null:
		sz = fh.get_length(); fh.close()
	print("")
	print("WROTE %s" % abs_out)
	print("  %d types, %d resolved addresses, %.2f MB"
		% [types._db_layouts.size(), types._db_resolved.size(), sz / 1048576.0])
	print("  walked %d placements across %d map(s) to build it" % [total, maps.size()])
	quit(0)
