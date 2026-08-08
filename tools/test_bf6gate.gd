extends SceneTree

# Does the gate actually gate, and does lifting it put the panel back as it was?
#
# Two failures matter and they are opposite:
#
#   too weak  - the panel greys out but its buttons still take clicks, so
#               someone with no Battlefield 6 starts a build that can only fail
#               and the red line above it reads as decoration.
#   too eager - lifting the gate enables everything it finds, including controls
#               the panel had disabled for their own reasons. Those come back
#               live when they should not be, and nothing disables them again.
#
# The second is the one worth a test: it only appears after a user locates their
# install, which is the moment everything is meant to start working, so an extra
# live button reads as normal.
#
# The verdict half is covered by exercising HighpolyGameDir.verify directly -
# it is what decides detected/not-detected, and it is pure.
#
#   godot --headless --path <proj> --script test_bf6gate.gd

const Toggle := preload("res://addons/highpoly_toggle/highpoly_toggle.gd")
const GameDir := preload("res://addons/highpoly_toggle/highpoly_gamedir.gd")


func _init() -> void:
	await process_frame
	var fails := 0

	# ---- the verdict ------------------------------------------------------
	print("verdict:")
	fails += _is(not bool(GameDir.verify("")["ok"]), "an empty path is not an install")
	fails += _is(not bool(GameDir.verify("C:/definitely/not/battlefield")["ok"]),
		"a folder that does not exist is not an install")
	# A folder that EXISTS but is not the game: the interesting near-miss, since
	# "the folder is there" is the check a weaker version would have made.
	var tmp := OS.get_environment("TEMP").path_join("bf6gate_probe")
	DirAccess.make_dir_recursive_absolute(tmp)
	var r: Dictionary = GameDir.verify(tmp)
	fails += _is(not bool(r["ok"]), "an existing folder with no game data is not an install")
	fails += _is(str(r["why"]).contains("layout.toc"), "and it says which file is missing")
	DirAccess.remove_absolute(tmp)

	var real: String = GameDir.autodetect()
	if real == "":
		print("   SKIP  no Battlefield 6 on this machine")
	else:
		fails += _is(bool(GameDir.verify(real)["ok"]), "the real install verifies")

	# ---- the gate ---------------------------------------------------------
	print("\ngate:")
	var section := VBoxContainer.new()
	get_root().add_child(section)
	var normal := Button.new()
	section.add_child(normal)
	var already_off := Button.new()
	already_off.disabled = true
	section.add_child(already_off)
	var slider := HSlider.new()
	section.add_child(slider)
	var line := LineEdit.new()
	section.add_child(line)
	# Nested, because the panel's controls live inside rows inside sections and
	# a walk that only looks at direct children would miss almost all of them.
	var nested_row := HBoxContainer.new()
	section.add_child(nested_row)
	var nested := Button.new()
	nested_row.add_child(nested)

	var was := {}
	Toggle.gate_interactive(section, false, was)
	fails += _is(normal.disabled, "a live button is disabled")
	fails += _is(nested.disabled, "a button nested two levels down is disabled")
	fails += _is(not line.editable, "a text box is made read-only")
	fails += _is(not slider.editable, "a slider is disabled")
	fails += _is(already_off.disabled, "an already-disabled button stays disabled")

	Toggle.gate_interactive(section, true, was)
	fails += _is(not normal.disabled, "the live button comes back")
	fails += _is(not nested.disabled, "the nested button comes back")
	fails += _is(line.editable, "the text box comes back")
	fails += _is(already_off.disabled,
		"THE ONE THAT MATTERS: a control the panel disabled stays disabled")
	fails += _is(was.is_empty(), "the memo is emptied, so a second cycle is clean")

	# A second full cycle: hiding twice must not record `true` as the value to
	# restore and quietly free a control the panel wanted off.
	Toggle.gate_interactive(section, false, was)
	Toggle.gate_interactive(section, false, was)
	Toggle.gate_interactive(section, true, was)
	fails += _is(already_off.disabled, "still disabled after two gate cycles")
	fails += _is(not normal.disabled, "and the live one is still live")

	section.queue_free()
	print("\n%s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)


func _is(cond: bool, what: String) -> int:
	print("   %-5s %s" % ["ok" if cond else "FAIL", what])
	return 0 if cond else 1
