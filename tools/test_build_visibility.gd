extends SceneTree

# Layers build hidden and appear complete, because drawing the work in progress
# is where a third of the build time went (34.0 ms/frame visible at 30k draw
# calls against a flat 4.2 ms hidden). Both the props and the skyline do it —
# the skyline especially, being 3,118 draw calls from 34 nodes, which is why its
# second half crawled while its first half felt instant.
#
# Two ways this goes wrong and neither throws:
#
#   1. a layer left hidden looks exactly like a build that produced nothing, so
#      EVERY exit from a builder has to restore it;
#   2. the two layers build concurrently, so a failure in one must not restore
#      or strand the other.
#
# It also covers the progress lanes, because a cancelled build never reaches its
# final report and its bar would then sit on screen for the rest of the session
# — which is what "switching scenes locks up the progress bar" was.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")
const Jobs = preload("res://addons/highpoly_toggle/highpoly_jobs.gd")

var fails := 0


func _init() -> void:
	await process_frame
	var mc = MC.new()
	get_root().add_child(mc)
	await process_frame

	var props := Node3D.new()
	props.name = "Props"
	get_root().add_child(props)
	var bd := Node3D.new()
	bd.name = "Backdrop"
	get_root().add_child(bd)

	# ---- one layer -------------------------------------------------------
	mc._show_objects = true
	mc._begin_build_draw(props)
	_check("the build starts hidden", not props.visible)
	mc._end_build_draw(props)
	_check("the finished build is visible", props.visible)

	# no flashing: nothing may toggle visibility between begin and end
	_check("there is no periodic reveal any more",
		not mc.has_method("_reveal_tick"))

	# ---- the two layers are independent ----------------------------------
	mc._show_objects = true
	mc._show_backdrop = true
	mc._begin_build_draw(props)
	mc._begin_build_draw(bd)
	_check("both layers hide independently", not props.visible and not bd.visible)
	mc._end_build_draw(bd)
	_check("finishing the skyline shows it", bd.visible)
	_check("and leaves the props build alone", not props.visible)
	mc._end_build_draw(props)
	_check("finishing the props shows them too", props.visible)

	# a layer freed mid-build must not strand the other
	mc._begin_build_draw(props)
	mc._begin_build_draw(bd)
	var bd_id := bd.get_instance_id()
	bd.free()
	mc._forget_build_draw(bd_id)
	mc._end_build_draw(props)
	_check("losing one layer still restores the other", props.visible)

	# ---- each layer answers to its OWN switch ----------------------------
	mc._show_objects = true
	mc._begin_build_draw(props)
	mc._show_objects = false            # user turns objects off mid-build
	mc._end_build_draw(props)
	_check("objects switched off mid-build STAY off", not props.visible)

	props.visible = false
	mc._show_objects = false
	mc._begin_build_draw(props)
	_check("with objects off the builder does not claim the layer",
		mc._hidden_builds.is_empty())
	mc._end_build_draw(props)
	_check("and does not turn them on behind the user's back", not props.visible)

	# ---- every exit path restores ----------------------------------------
	_check("every return in the props builder restores first",
		_exits_restore("_build_props_async"))
	_check("every return in the skyline builder restores first",
		_exits_restore("_build_backdrop_async"))

	# ---- a cancelled build must not strand its progress bar ---------------
	var jobs = Jobs.new()
	get_root().add_child(jobs)
	mc.job_queue = jobs
	mc.build_progress.connect(func(d: int, t: int):
		if d < t: jobs.set_activity(mc.build_job, d, t)
		else: jobs.clear_activity(mc.build_job))
	mc.backdrop_progress.connect(func(d: int, t: int):
		if d < t: jobs.set_activity("Building the skyline", d, t)
		else: jobs.clear_activity("Building the skyline"))
	mc._build_total = 100
	mc._bd_total = 50
	mc.build_progress.emit(10, 100)
	mc.backdrop_progress.emit(5, 50)
	_check("a running build holds a bar", jobs.busy())
	mc._clear(get_root())               # scene switch / rebuild
	_check("cancelling the build closes its bar", not jobs.busy())

	props.free()
	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


# Walks a builder and checks each `return` is preceded, within a few lines, by
# something that hands visibility back. Crude on purpose: the cost of missing
# one is a layer that never appears, and that is worth a source scan.
func _exits_restore(fname: String) -> bool:
	var src := FileAccess.get_file_as_string(
		"res://addons/highpoly_toggle/highpoly_mapcontext.gd")
	var start := src.find("func %s(" % fname)
	if start < 0:
		print("      could not find %s" % fname)
		return false
	var stop := src.find("\nfunc ", start + 10)
	var lines := src.substr(start, stop - start).split("\n")
	var ok := true
	for i in range(lines.size()):
		var ln := str(lines[i]).strip_edges()
		if not (ln == "return" or ln.begins_with("return ")):
			continue
		var seen := false
		for k in range(maxi(0, i - 6), i):
			var p := str(lines[k])
			if p.contains("_end_build_draw") or p.contains("_forget_build_draw") \
					or p.contains("_release_build_draw"):
				seen = true
		if not seen:
			print("      %s line %d returns without restoring: %s" % [fname, i, ln])
			ok = false
	return ok


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
