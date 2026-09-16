extends SceneTree
const Backdrop = preload("res://addons/highpoly_toggle/highpoly_backdrop.gd")
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var adapter = load("res://addons/highpoly_toggle/highpoly_toggle.gd")
	check(adapter != null and adapter.can_instantiate(), "real editor adapter did not load")
	var home := Control.new()
	root.add_child(home)
	var host := Control.new()
	home.add_child(host)
	var player := VideoStreamPlayer.new()
	var stream := VideoStreamTheora.new()
	stream.file = "res://addons/highpoly_toggle/waves.ogv"
	player.stream = stream
	player.expand = true
	host.add_child(player)
	player.size = Vector2(480, 800)
	# Reproduce restored-dock behavior: it was paused before ever starting.
	player.paused = true
	check(not player.is_playing(), "cold player unexpectedly running")
	Backdrop.sync(player, host)
	check(player.is_playing() and not player.paused, "visible dock did not start its backdrop")
	await create_timer(0.25).timeout
	var before := player.stream_position
	await create_timer(0.25).timeout
	check(player.stream_position > before, "visible backdrop did not advance decoded time")
	# This is the previous float branch: play does not clear pause.
	player.stop()
	player.paused = true
	player.play()
	check(player.paused, "old play-only negative control no longer reproduces retained pause")
	Backdrop.sync(player, host)
	check(player.is_playing() and not player.paused, "stopped/paused backdrop was not recovered")
	host.hide()
	Backdrop.sync(player, host)
	check(player.paused, "hidden dock kept decoding")
	host.show()
	Backdrop.sync(player, host)
	check(not player.paused and player.is_playing(), "reshown dock remained paused")
	# Remove/add models the dock-to-window move, including tree exit/entry.
	home.remove_child(host)
	home.add_child(host)
	Backdrop.sync(player, host)
	check(not player.paused and player.is_playing(), "reparented backdrop did not recover")
	var tint := ColorRect.new()
	var controls := Control.new()
	tint.color.a = 0.1
	controls.modulate.a = 0.2
	Backdrop.settle(tint, controls, 0.72)
	check(is_equal_approx(tint.color.a, 0.72) and is_equal_approx(controls.modulate.a, 1.0),
		"interrupted splash did not restore final presentation")
	tint.free()
	controls.free()
	home.queue_free()
	print("Backdrop: cold dock/decoded time/hidden tab/reopen/reparent/splash passed; old play-only pause reproduced. Failures: ", failures)
	quit(0 if failures == 0 else 1)
