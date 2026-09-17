extends SceneTree

# DOES EVERY POSE ACTUALLY BUILD A SOLDIER?
#
#   python tools/run_addon_script.py native/probe_soldier_roles.gd --args <steam root>
#
# Reported as "when i change the pose of the spawners now they disappear". The
# inspector's "Pose" picker sets the soldier request's ROLE, which becomes part
# of the overlay's asset id; a changed id makes the builder drop the existing
# overlay and make a new one. If the new one fails to build, the old one is
# already gone and the spawner shows nothing.
#
# That is two separate questions and this answers the first: are there roles the
# catalogue offers that the core cannot actually build? If every role builds,
# the disappearance is somewhere else and the destroy-before-build ordering is
# the whole story.

const Loadout := preload("res://addons/highpoly_toggle/highpoly_loadout.gd")

func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	if a.is_empty():
		print("usage: probe_soldier_roles.gd -- <steam root>"); quit(2); return
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered"); quit(1); return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0])):
		print("FAIL open"); quit(1); return
	if not core.has_method("loadout_soldier"):
		print("FAIL: this binding has no loadout_soldier"); quit(1); return

	var roles: Array = Loadout.catalogue_list(core, "roles")
	var chars: Array = Loadout.catalogue_list(core, "characters")
	var factions: Array = Loadout.catalogue_list(core, "factions")
	print("catalogue: %d roles, %d characters, %d factions" % [roles.size(), chars.size(), factions.size()])
	print("roles offered by the picker:")
	for r in roles:
		print("   id=%-18s label=%s" % [str((r as Dictionary).get("id","")), str((r as Dictionary).get("label",""))])

	if roles.is_empty():
		print("\nThe picker offers NO roles - changing Pose can only ever set an empty one.")
		quit(1); return

	# Build the same request the inspector would, once per role, and report
	# which come back empty. DEFAULT_CHARACTER is what an untouched spawner uses.
	var fails := 0
	print("\nbuilding one soldier per role (character=%s outfit=%s faction=alliance):"
		% [Loadout.DEFAULT_CHARACTER, Loadout.DEFAULT_OUTFIT])
	for r in roles:
		var rid := str((r as Dictionary).get("id", ""))
		var req := {
			"character": Loadout.DEFAULT_CHARACTER,
			"outfit": Loadout.DEFAULT_OUTFIT,
			"faction": "alliance",
			"role": rid,
			"item": Loadout.DEFAULT_ITEM,
			"fits": {},
		}
		# The REAL call: two arguments, and it returns a BLWP byte record, not
		# JSON. A probe that invents the signature measures its own mistake -
		# the first version of this reported all four roles failing because it
		# passed one argument and expected a String.
		var blob: PackedByteArray = core.call("loadout_soldier",
			JSON.stringify(req), Loadout.attachment_enums_text())
		var ok := false
		var note := ""
		if blob.size() < 12 or blob.decode_u32(0) != 0x50574C42:
			note = "not a BLWP record (%d bytes)" % blob.size()
		else:
			var jl := blob.decode_u32(8)
			var parsed: Variant = JSON.parse_string(blob.slice(12, 12 + jl).get_string_from_utf8())
			if parsed is Dictionary:
				var rec: Dictionary = parsed
				if str(rec.get("error", "")) != "":
					note = str(rec.error)
				else:
					var secs: Array = rec.get("sections", [])
					ok = not secs.is_empty()
					var verts := 0
					for sec in secs: verts += int((sec as Dictionary).get("vertex_count", 0))
					note = "%d section(s), %d vertices" % [secs.size(), verts]
			else:
				note = "record header parsed but its JSON did not"
		print("   %-18s %s  %s" % [rid, "OK  " if ok else "FAIL", note])
		if not ok: fails += 1

	print("\n%d of %d roles fail to build" % [fails, roles.size()])
	print("If that is 0, the pose itself is fine and the disappearance is the")
	print("builder dropping the old overlay before knowing the new one works.")
	quit(0)
