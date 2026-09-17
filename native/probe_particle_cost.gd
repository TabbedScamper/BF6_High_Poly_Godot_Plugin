extends SceneTree

# WHY DOES THE FX BUILD TIME OUT NOW?
#
# The end-to-end FX test ran in about four minutes for several rounds, then
# started timing out at 800-900 s. The change most likely to account for it is
# mine: the density fix took `amount` from a median of 5 particles per emitter
# to 64, across about 1,950 emitters - roughly 125,000 particles where there
# were 10,000.
#
# That is a hypothesis, and the last two times I reasoned about a slowdown from
# circumstantial evidence I was wrong (once blaming the user's editor, once
# suspecting colour ramps that turned out to cost 2 ms). So this measures it:
# build the real number of emitters at the old amount and the new one, and time
# both. If the difference is minutes, the density is the cost and the cap needs
# thought. If it is milliseconds, the cause is elsewhere and I should stop
# guessing at it.

func _init() -> void:
	await process_frame
	var n := 1950
	for amount in [5, 64, 192]:
		var t0 := Time.get_ticks_msec()
		var made: Array = []
		for i in range(n):
			var g := GPUParticles3D.new()
			var pm := ParticleProcessMaterial.new()
			pm.damping_min = 0.3
			var qm := QuadMesh.new()
			qm.size = Vector2(1.0, 1.0)
			g.process_material = pm
			g.draw_pass_1 = qm
			g.amount = amount
			g.lifetime = 5.0
			made.append(g)
		var build := Time.get_ticks_msec() - t0
		# Adding to the tree is where a renderer actually allocates, so the
		# number that matters is with the nodes live, not merely constructed.
		var t1 := Time.get_ticks_msec()
		var root := Node3D.new()
		get_root().add_child(root)
		for g in made:
			root.add_child(g)
		var attach := Time.get_ticks_msec() - t1
		print("amount=%-4d  construct %6d ms   attach %6d ms   total %6d ms  (%d emitters, %d particles)"
			% [amount, build, attach, build + attach, n, n * amount])
		root.queue_free()
		await process_frame
	quit(0)
