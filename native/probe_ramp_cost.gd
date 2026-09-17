extends SceneTree

# WHAT IN THE LAST FX BATCH HANGS THE BUILD?
#
# The end-to-end FX test ran in about four minutes for several rounds and then
# timed out at 800 s after one batch of changes. The batch added, per material:
# two GradientTexture1D colour ramps, a handful of shader parameters, a render
# priority, and a preprocess value. Only the ramps ALLOCATE anything, so they
# are the first suspect - but suspecting is not measuring, and the cheapest way
# to tell is to do each one 600 times and time it.
#
# 600 is the real scale: the builder makes about 263 materials and up to two
# ramps each.

func _init() -> void:
	await process_frame
	var n := 600

	var t0 := Time.get_ticks_msec()
	var ramps: Array = []
	for i in range(n):
		var g := Gradient.new()
		g.set_color(0, Color(1, 0.5, 0.2))
		g.set_color(1, Color(0.2, 0.2, 0.25))
		var t := GradientTexture1D.new()
		t.gradient = g
		ramps.append(t)
	print("GradientTexture1D x%d: %d ms" % [n, Time.get_ticks_msec() - t0])

	# The same objects actually ASSIGNED to a process material, which is what
	# the builder does - allocation and assignment can cost very differently.
	t0 = Time.get_ticks_msec()
	var mats: Array = []
	for i in range(n):
		var pm := ParticleProcessMaterial.new()
		pm.color_ramp = ramps[i]
		pm.color_initial_ramp = ramps[i]
		mats.append(pm)
	print("assigned to ParticleProcessMaterial x%d: %d ms" % [n, Time.get_ticks_msec() - t0])

	# Turbulence, which was already live in a run that passed, as a control: if
	# this is also slow then the measurement is not telling the ramps apart.
	t0 = Time.get_ticks_msec()
	for i in range(n):
		var pm2 := ParticleProcessMaterial.new()
		pm2.turbulence_enabled = true
		pm2.turbulence_noise_strength = 0.5
	print("CONTROL turbulence x%d: %d ms" % [n, Time.get_ticks_msec() - t0])

	# And a bare material, to say what the floor is.
	t0 = Time.get_ticks_msec()
	for i in range(n):
		var pm3 := ParticleProcessMaterial.new()
		pm3.damping_min = 0.5
	print("CONTROL bare material x%d: %d ms" % [n, Time.get_ticks_msec() - t0])
	quit(0)
