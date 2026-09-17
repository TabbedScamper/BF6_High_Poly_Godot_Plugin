extends SceneTree

# BISECT: adding a HighpolyIdlePlayer to the tree never returns.
#
# The idle build reaches "library: 0.00 s" and then hangs on the next line,
# which is root.add_child(player). A plain AnimationPlayer is the control: if
# that is instant and ours is not, the cost is in what our _enter_tree does.

const MARK := "user://player_add_probe.txt"


func mark(what: String) -> void:
	var f := FileAccess.open(MARK, FileAccess.READ_WRITE) if FileAccess.file_exists(MARK) \
		else FileAccess.open(MARK, FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line("%7.2f s  %s" % [Time.get_ticks_msec() / 1000.0, what])
		f.close()
	print(what)


func _init() -> void:
	await process_frame
	var host := Node3D.new()
	get_root().add_child(host)

	mark("adding a plain AnimationPlayer")
	var plain := AnimationPlayer.new()
	host.add_child(plain)
	mark("plain AnimationPlayer added")

	# Touch the STATIC side first. If this hangs, the cost is script/static
	# initialisation rather than anything to do with constructing a node.
	mark("calling the static live_count()")
	var n := HighpolyIdlePlayer.live_count()
	mark("static call returned %d" % n)

	mark("constructing HighpolyIdlePlayer")
	var ours := HighpolyIdlePlayer.new()
	mark("constructed; live=%d" % HighpolyIdlePlayer.live_count())

	mark("adding HighpolyIdlePlayer to the tree")
	host.add_child(ours)
	mark("added; live=%d" % HighpolyIdlePlayer.live_count())

	mark("removing it")
	host.remove_child(ours)
	mark("removed; live=%d" % HighpolyIdlePlayer.live_count())

	mark("DONE")
	quit(0)
