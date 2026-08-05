extends SceneTree

# Every layer toggle goes through apply(), which tears the whole map context
# down and builds it again. The skyline has been lifted out and re-parented
# across that teardown for a while; the props never were.
#
# So switching Extended Terrain on AFTER the map objects had finished threw away
# all 2,761 of them and rebuilt from scratch. A recorded Dumbo session:
#
#    51.9s  props: build started, 2761 entries
#   133.4s  map_context: off -> on
#   138.4s  props: build started, 2761 entries      <- again
#   369.6s  props: build finished, 2761 built in 231.2 s
#
# `props: load mesh` ran 5,522 times instead of 2,761, and the fast-load sidecar
# write was paid three times over at 311 s — the largest phase in the run.
#
# The decision has to fail in BOTH directions safely. Too strict and a terrain
# toggle costs four minutes; too loose and the map keeps props that no longer
# match what was asked for — or worse, keeps a HALF-BUILT set whose builder has
# already been cancelled, stranding the map with however many props happened to
# be placed when the toggle was hit.

const MC = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

var fails := 0
var mc


func _init() -> void:
	await process_frame
	mc = MC.new()
	get_root().add_child(mc)
	await process_frame

	# a finished build of MP_Dumbo at detail mode 2
	_finished(2761)

	_check("a terrain toggle keeps the props that are already placed",
		_keep(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2))

	# --- the ways it must NOT keep them -----------------------------------
	_check("a different map rebuilds",
		not _keep(true, true, "MP_Plaza", "MP_Dumbo", 2, 2))
	_check("a detail-mode change rebuilds (materials are baked per mode)",
		not _keep(true, true, "MP_Dumbo", "MP_Dumbo", 0, 2))
	_check("turning the layer ON from off builds, it does not 'keep'",
		not _keep(true, false, "MP_Dumbo", "MP_Dumbo", 2, 2))
	_check("turning the layer OFF keeps nothing",
		not _keep(false, true, "MP_Dumbo", "MP_Dumbo", 2, 2))

	# THE ONE THAT WOULD STRAND A MAP. The builder is cancelled by the
	# generation bump in _clear, so a partial set never gets finished.
	_partial(2761, 900)
	_check("a build still running is rebuilt, not kept half-done",
		not _keep(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2))

	_stopped_partway(2761, 900)
	_check("a build that stopped partway is rebuilt too",
		not _keep(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2))

	# A map with no props at all must not report a keepable set.
	_finished(0)
	_check("a map with no props rebuilds rather than keeping nothing",
		not _keep(true, true, "MP_Dumbo", "MP_Dumbo", 2, 2))

	print("\n%s" % ("ALL PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _keep(show: bool, prev_show: bool, map: String, prev_map: String,
		tex: int, prev_tex: int) -> bool:
	return mc._can_keep_props(show, prev_show, map, prev_map, tex, prev_tex)


func _finished(n: int) -> void:
	mc._build_total = n
	mc._build_done = n
	mc._building = false


func _partial(n: int, done: int) -> void:
	mc._build_total = n
	mc._build_done = done
	mc._building = true


func _stopped_partway(n: int, done: int) -> void:
	mc._build_total = n
	mc._build_done = done
	mc._building = false


func _check(what: String, ok: bool) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails += 1
