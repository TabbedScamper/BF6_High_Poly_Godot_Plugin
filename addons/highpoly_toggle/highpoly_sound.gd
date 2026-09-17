@tool
class_name HighpolySound
extends Node

# THE LEVEL'S AMBIENT BED: the spatial sound emitters the game places.
#
# Until now every rebuild was silent while the game's world is full of authored
# sound - the sea, the wind, a burning vehicle, water dripping in a tunnel. These
# are the placeable emitters (DiceSoundSpatialEntityData): about 100 on a busy
# map, present on 25 of 28 levels.
#
# NOT every audio instance in the level. A level also ships a soundshapegrid
# whose thousands of entries are acoustics cells with no transform and no sound;
# placing those would put thousands of silent markers in the scene. The core
# reads only the emitters. See docs/MAP-PARITY-LEDGER.md.
#
# EVERY NUMBER HERE COMES FROM THE GAME. Position and orientation from the
# emitter, radius and loudness from the sound CONFIG it points at - read by the
# core so this and the Unreal add-on attenuate the same way rather than each
# inventing a falloff. The only local decision is how many to stream at once.

const HOLDER := "_MAP_SOUND"

# STREAMED ON DEMAND, not all at once. A level's bed is up to ~100 emitters over
# ~50 distinct sounds, and a single ambience can be 1.4 million samples: pulling
# every wave across on build would cost tens of megabytes and seconds of stall
# for sound the user may never switch on. The nearest few are loaded first.
const STREAM_BUDGET := 24


static func clear(root: Node) -> void:
	for c in root.get_children():
		if String(c.name).contains(HOLDER):
			root.remove_child(c)
			c.queue_free()


# Returns a short status line, the same shape the light and water builders use.
static func build(root: Node, env, play := false) -> String:
	clear(root)
	if env == null:
		return "Ambient sound: no native environment"
	var data: Dictionary = env.request("sound_emitters")
	if data.is_empty():
		return "Ambient sound: %s" % str(env.error)
	var rows: Array = data.get("emitters", [])
	if rows.is_empty():
		# A real answer: several levels place none.
		return "Ambient sound: this level places none"

	var holder := Node3D.new()
	var placed := 0
	var streamed := 0
	var silent := 0
	for i in range(rows.size()):
		var e: Dictionary = rows[i]
		var xf: Array = e.get("xform", [])
		if xf.size() < 12:
			continue
		var p := AudioStreamPlayer3D.new()
		# THE GAME'S OWN FALLOFF. radius is the source size and loudness the
		# level it plays at; neither is invented here, and a level with a
		# missing config reads as 0 rather than as a default that looks right.
		var radius := float(e.get("radius", 0.0))
		var loudness := float(e.get("loudness", 0.0))
		p.unit_size = maxf(radius, 1.0)
		# Loudness is an authored level, not decibels of gain: it is mapped so
		# the quietest beds stay quiet without the loud ones clipping, and the
		# emitter's own Amplitude multiplies it as the game does.
		p.volume_db = linear_to_db(clampf(float(e.get("amplitude", 1.0)), 0.0, 1.0))
		p.max_distance = maxf(loudness, 1.0)
		p.autoplay = false
		p.bus = "Master"
		holder.add_child(p)
		p.owner = null
		p.position = Vector3(float(xf[9]), float(xf[10]), float(xf[11]))
		p.set_meta("bf6_sound", str(e.get("sound", "")))
		p.set_meta("bf6_radius", radius)
		p.set_meta("bf6_loudness", loudness)
		placed += 1

		# The wave itself, for the nearest few only.
		if play and streamed < STREAM_BUDGET:
			var pcm: Dictionary = env.request("sound_emitters", i + 1)
			var stream := _stream_of(pcm)
			if stream != null:
				p.stream = stream
				p.play()
				streamed += 1
			else:
				silent += 1
	root.add_child(holder)
	holder.name = HOLDER
	holder.owner = null
	var note := ""
	if play:
		note = ", %d playing" % streamed
		if silent > 0:
			# Some configs are graphs referencing other sounds and decode at no
			# variation. The emitter is still real and still placed.
			note += ", %d with no wave" % silent
	return "Ambient sound: %d emitter(s) placed%s" % [placed, note]


# One decoded emitter as a Godot stream. Null when the config carries no wave.
static func _stream_of(packet: Dictionary) -> AudioStreamWAV:
	if packet.is_empty():
		return null
	var samples := int(packet.get("pcm_samples", 0))
	var channels := int(packet.get("pcm_channels", 0))
	var rate := int(packet.get("pcm_rate", 0))
	if samples <= 0 or channels <= 0 or rate <= 0:
		return null
	var blob: Variant = packet.get("pcm", null)
	if not blob is PackedByteArray:
		return null
	var bytes: PackedByteArray = blob
	if bytes.size() < samples * 2:
		return null
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.stereo = channels >= 2
	s.mix_rate = rate
	s.data = bytes
	# Ambience is a bed: it loops, which is what the game does with these.
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = int(samples / maxi(channels, 1))
	return s
