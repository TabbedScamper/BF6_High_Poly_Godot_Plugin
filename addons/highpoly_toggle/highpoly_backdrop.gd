@tool
extends RefCounted
# A visible dock and a visible floating panel have the same animated backdrop.
# Pause only when their actual host is hidden. Reparenting the panel can stop
# the player while retaining paused=true, so play() alone is not a resume.
static func sync(player: VideoStreamPlayer, host: Control) -> void:
	if not is_instance_valid(player) or not is_instance_valid(host):
		return
	if not player.is_inside_tree() or not host.is_inside_tree():
		return
	var window := host.get_window()
	var shown := host.is_visible_in_tree() and window != null and window.visible
	player.paused = not shown
	if shown and player.stream != null and not player.is_playing():
		player.play()

static func settle(tint: ColorRect, controls: Control, opacity: float) -> void:
	if is_instance_valid(tint):
		tint.color.a = opacity
	if is_instance_valid(controls):
		controls.modulate.a = 1.0
