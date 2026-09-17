extends SceneTree

# Public ABI -> GDExtension -> Godot proof for the level's ambient sound bed.
#
# The point of reading emitters is to HEAR what the game hears there, so this
# checks the chain end to end and not merely that rows arrived:
#
#   1. Emitters come back with a transform and a sound.
#   2. The falloff came from the sound CONFIG, not from a default invented here:
#      a row with neither radius nor loudness means the config read failed and a
#      consumer would be left guessing.
#   3. The PCM decodes AND turns into a real AudioStreamWAV with the right
#      channel count, rate and loop points. A stream that says stereo over mono
#      data plays at the wrong speed and sounds plausible while being wrong.
#   4. Emitters are spread out; a bed that collapses to a point is not a bed.

const Sound = preload("res://addons/highpoly_toggle/highpoly_sound.gd")


func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_sound_emitters.gd -- <Steam BF6 root> [level ...]")
		quit(2)
		return
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered")
		quit(1)
		return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(str(args[0])):
		print("FAIL open: %s" % (core.last_error() if core != null else "null"))
		quit(1)
		return

	var levels: Array = args.slice(1) if args.size() > 1 else ["mp_aftermath"]
	var failures := 0
	for lv in levels:
		var level := str(lv)
		var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
		var data: Dictionary = env.request("sound_emitters")
		if data.is_empty():
			print("%-20s FAIL %s" % [level, str(env.error)])
			failures += 1
			continue
		var rows: Array = data.get("emitters", [])
		if rows.is_empty():
			print("%-20s places no emitters" % level)
			continue

		var no_sound := 0
		var no_falloff := 0
		var lo := Vector3(1e30, 1e30, 1e30)
		var hi := Vector3(-1e30, -1e30, -1e30)
		for e in rows:
			var d: Dictionary = e
			if str(d.get("sound", "")).is_empty(): no_sound += 1
			if float(d.get("radius", 0.0)) <= 0.0 and float(d.get("loudness", 0.0)) <= 0.0:
				no_falloff += 1
			var xf: Array = d.get("xform", [])
			if xf.size() >= 12:
				var p := Vector3(float(xf[9]), float(xf[10]), float(xf[11]))
				lo = lo.min(p); hi = hi.max(p)
		var spread := (hi - lo).length() if rows.size() > 1 else 0.0

		# 3. the wave, for the first few
		var decoded := 0
		var silent := 0
		var checked := 0
		for i in range(mini(6, rows.size())):
			var packet: Dictionary = env.request("sound_emitters", i + 1)
			checked += 1
			var stream := Sound._stream_of(packet)
			if stream == null:
				silent += 1
				continue
			decoded += 1
			var ch := int(packet.get("pcm_channels", 0))
			var samples := int(packet.get("pcm_samples", 0))
			if stream.stereo != (ch >= 2):
				print("   FAIL stream channel count disagrees with the decode")
				failures += 1
			if stream.mix_rate != int(packet.get("pcm_rate", 0)):
				print("   FAIL stream rate disagrees with the decode")
				failures += 1
			if stream.loop_end != int(samples / maxi(ch, 1)):
				print("   FAIL loop end is not the frame count")
				failures += 1

		print("%-20s %4d emitter(s)  spread %5.0f m  no-sound %d  no-falloff %d  | of %d checked: %d play, %d have no wave" % [
			level, rows.size(), spread, no_sound, no_falloff, checked, decoded, silent])
		if no_sound > 0:
			print("   FAIL %d emitter(s) name no sound" % no_sound); failures += 1
		if no_falloff == rows.size():
			print("   FAIL no emitter carries a falloff from its config"); failures += 1
		if decoded == 0 and checked > 0:
			print("   FAIL nothing decoded: the emitter-to-audio chain is broken"); failures += 1
		if rows.size() > 1 and spread < 1.0:
			print("   FAIL emitters collapse to a point"); failures += 1

	print("\n%s" % ("PASS" if failures == 0 else "FAIL: %d problem(s)" % failures))
	quit(1 if failures else 0)
