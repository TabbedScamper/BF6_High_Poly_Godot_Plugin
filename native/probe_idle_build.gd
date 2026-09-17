extends SceneTree

# BISECT: which half of the idle build is slow - the core's clip, or Godot's
# track insertion?
#
# The rig test reaches "building the idle animation" in 1.4 s and then does not
# finish inside six minutes. That call does two very different things: it asks
# the core for the whole clip, and it inserts a keyframe per bone per frame into
# a Godot Animation. Timing them apart is one run; guessing is not.

const Rig := preload("res://addons/highpoly_toggle/highpoly_soldierrig.gd")
const MARK := "user://idle_build_probe.txt"


# A killed run loses every buffered print, including the ones from before the
# hang - which is how the last attempt reported nothing at all.
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
	var a := OS.get_cmdline_user_args()
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(a[0]) if a.size() > 0 else ""):
		mark("FAIL could not open the game"); quit(1); return

	var t0 := Time.get_ticks_msec()
	var blob: PackedByteArray = core.call("loadout_soldier_clip", JSON.stringify({"role": "assault"}))
	var t1 := Time.get_ticks_msec()
	mark("core clip record: %d bytes in %.2f s" % [blob.size(), (t1 - t0) / 1000.0])
	if blob.size() < 12:
		mark("FAIL no clip record"); quit(1); return

	var json_len := blob.decode_u32(8)
	var rec: Dictionary = JSON.parse_string(blob.slice(12, 12 + json_len).get_string_from_utf8())
	var frames := int(rec.get("frames", 0))
	var tracks: Array = rec.get("tracks", [])
	mark("   %d frames, %d driven bone(s) -> %d keys to insert"
		% [frames, tracks.size(), frames * tracks.size() * 2])

	# Now the Godot half, on its own.
	var t2 := Time.get_ticks_msec()
	var anim := Animation.new()
	anim.length = float(frames - 1) / 60.0
	var body := 12 + int(json_len)
	var made := 0
	for t in tracks:
		var at := int((t as Dictionary).get("track", -1))
		if at < 0: continue
		var pos := anim.add_track(Animation.TYPE_POSITION_3D)
		var rot := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(pos, ":bone%d" % made)
		anim.track_set_path(rot, ":bone%d" % made)
		for f in range(frames):
			var off := body + (at + f * 12) * 4
			var m := blob.slice(off, off + 48).to_float32_array()
			var time := float(f) / 60.0
			anim.position_track_insert_key(pos, time, Vector3(m[9], m[10], m[11]))
			anim.rotation_track_insert_key(rot, time, Quaternion.IDENTITY)
		made += 1
		if made == 1:
			print("   first bone's track took %.2f s" % ((Time.get_ticks_msec() - t2) / 1000.0))
	mark("track insertion: %d bones in %.2f s" % [made, (Time.get_ticks_msec() - t2) / 1000.0])

	# Both halves are fast in isolation, so the cost is in what add_idle does
	# AROUND them: a real skeleton, a real player, real track paths. Replicate
	# its steps one at a time against the actual built soldier.
	mark("\n--- against a real soldier ---")
	var t3 := Time.get_ticks_msec()
	var built: Dictionary = Rig.build(core, {"character": "cha0001wisp", "outfit": "001",
		"faction": "alliance", "role": "assault"})
	if str(built.get("error", "")) != "":
		mark("FAIL build: %s" % built.error); quit(1); return
	var root: Node3D = built.node
	var skel: Skeleton3D = built.skeleton
	get_root().add_child(root)
	mark("built and added: %.2f s, %d bones" % [(Time.get_ticks_msec() - t3) / 1000.0,
		skel.get_bone_count()])

	var t4 := Time.get_ticks_msec()
	var real: Dictionary = Rig.animation(core, skel, "assault")
	mark("Rig.animation(): %.2f s, error=%s" % [(Time.get_ticks_msec() - t4) / 1000.0,
		str(real.get("error", ""))])
	if str(real.get("error", "")) != "": quit(1); return
	var built_anim: Animation = real["animation"]

	var t5 := Time.get_ticks_msec()
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", built_anim)
	mark("library: %.2f s" % ((Time.get_ticks_msec() - t5) / 1000.0))

	var t6 := Time.get_ticks_msec()
	var player := HighpolyIdlePlayer.new()
	player.name = "Idle"
	root.add_child(player)
	mark("player added: %.2f s" % ((Time.get_ticks_msec() - t6) / 1000.0))

	var t7 := Time.get_ticks_msec()
	player.root_node = player.get_path_to(skel)
	mark("root_node set: %.2f s" % ((Time.get_ticks_msec() - t7) / 1000.0))

	var t8 := Time.get_ticks_msec()
	player.add_animation_library("", lib)
	mark("add_animation_library: %.2f s" % ((Time.get_ticks_msec() - t8) / 1000.0))

	var t9 := Time.get_ticks_msec()
	player.drive("idle", 0.25)
	mark("drive(): %.2f s" % ((Time.get_ticks_msec() - t9) / 1000.0))
	quit(0)
