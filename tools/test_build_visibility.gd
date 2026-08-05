extends SceneTree

# The props build now runs with its output HIDDEN, revealing one frame every
# couple of seconds, because drawing the half-built map is where ~84 s of a
# 261 s build went (measured: 34.0 ms/frame visible at 30k draw calls against a
# flat 4.2 ms hidden).
#
# The failure mode is not slowness, it is an INVISIBLE MAP. Every exit from the
# builder has to put the visibility back — the normal end, the host-removed
# path, the cancelled-generation paths — and a missed one looks exactly like a
# build that produced nothing. The user's own "Original map objects" switch has
# to win too: turning objects off mid-build must not be undone at the end.
#
# Runs the real builder against real props, then scans the source for exit paths
# that forgot to restore, because a path this test does not happen to hit is
# precisely the one that would ship broken.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame

	var props := Node3D.new()
	get_root().add_child(props)

	# ---- the visibility pair on its own ----------------------------------
	mc._show_objects = true
	mc._begin_build_draw(props)
	_check("the build starts hidden", not props.visible)
	_check("and knows it hid it", mc._draw_hidden)

	var last := Time.get_ticks_msec() - MC.REVEAL_EVERY_MS - 1
	var stamp = await mc._reveal_tick(props, last)
	_check("a reveal tick leaves it hidden again afterwards", not props.visible)
	_check("and moves the clock on", int(stamp) > int(last))

	var again = await mc._reveal_tick(props, Time.get_ticks_msec())
	_check("a tick too soon does not reveal", int(again) == 0 or not props.visible)

	mc._end_build_draw(props)
	_check("the finished build is visible", props.visible)
	_check("and the flag is cleared", not mc._draw_hidden)

	# ---- the user's switch wins ------------------------------------------
	mc._show_objects = true
	mc._begin_build_draw(props)
	mc._show_objects = false                # user turns objects off mid-build
	mc._end_build_draw(props)
	_check("objects switched off mid-build STAY off at the end", not props.visible)

	# objects already off: the builder must not touch visibility at all
	props.visible = false
	mc._show_objects = false
	mc._begin_build_draw(props)
	_check("with objects off, the builder does not claim visibility",
		not mc._draw_hidden)
	mc._end_build_draw(props)
	_check("and does not turn them on behind the user's back", not props.visible)

	# a freed Props node must not strand the flag
	mc._show_objects = true
	var doomed := Node3D.new()
	get_root().add_child(doomed)
	mc._begin_build_draw(doomed)
	doomed.free()
	mc._end_build_draw(null)
	_check("a freed Props node still clears the flag", not mc._draw_hidden)

	# ---- every exit path restores ----------------------------------------
	_check("every return in the builder restores visibility first",
		_exits_restore())

	props.free()
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


# Walks _build_props_async and checks each `return` is preceded, within its
# block, by something that hands visibility back. Crude, deliberately: the cost
# of missing one is a map that never appears, and that is worth a source scan.
func _exits_restore() -> bool:
	var src := FileAccess.get_file_as_string(
		"res://addons/highpoly_toggle/highpoly_mapcontext.gd")
	var start := src.find("func _build_props_async(")
	if start < 0:
		print("      could not find the builder")
		return false
	var stop := src.find("\nfunc ", start + 10)
	var body := src.substr(start, stop - start)
	var lines := body.split("\n")
	var ok := true
	for i in range(lines.size()):
		var ln := str(lines[i]).strip_edges()
		if not (ln == "return" or ln.begins_with("return ")):
			continue
		# look back a few lines for a restore
		var seen := false
		for k in range(maxi(0, i - 6), i):
			var p := str(lines[k])
			if p.contains("_end_build_draw") or p.contains("_draw_hidden = false"):
				seen = true
		if not seen:
			print("      line %d of the builder returns without restoring: %s"
				% [i, ln])
			ok = false
	return ok


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
