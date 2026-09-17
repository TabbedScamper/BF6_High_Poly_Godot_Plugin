extends SceneTree

# The Portal layer visibility rule, checked against the REAL layer names
# mp_isolated ships.
#
# mp_isolated carries its two aircraft carriers TWICE: once under the
# "carrierstrike" mode layer (15,166 placements) and once under
# "portal_aircraftcarriers_carrierstrike" (15,164) - the same ships at the same
# centre. The bug this guards is not "the carrier is missing" but its opposite:
# turning the carrier back on in a way that shows BOTH copies, which is two
# overlapping decks and worse than the bug being fixed.
#
# The rule is static, so this needs no install, no map data and no instance.

const Ctx = preload("res://addons/highpoly_toggle/highpoly_mapcontext.gd")

const CARRIER_MODE    := "carrierstrike"
const CARRIER_PORTAL  := "portal_aircraftcarriers_carrierstrike"
const CONQUEST_PORTAL := "portal_aircraftcarriers_conquest"
const CONQUEST_MODE   := "conquest"


func _act(mode: String) -> Dictionary:
	# What _active_variant_layers builds, without needing the instance: the
	# mode-map branch is dead on every map (its miner no longer exists).
	var act := {"default_event": true}
	if mode != "" and mode != "Off":
		act[mode] = true
	if Ctx.is_portal_context(mode):
		act[Ctx.PORTAL_CONTEXT] = true
	return act


func _init() -> void:
	await process_frame
	var failures := 0
	# THE PORTAL DECK IS THE CONQUEST ONE. Measured, not assumed: Custom Portal's
	# 372 authored markers match portal_aircraftcarriers_conquest on 371 of them
	# at 0.0 degrees of heading error, and the carrierstrike variant on 9 at
	# 18.9 degrees - a different ship lying across the deck Portal outlines.
	var cases := {
		"": {CONQUEST_PORTAL: true, CARRIER_PORTAL: false, CARRIER_MODE: false, "default_event": true},
		"Off": {CONQUEST_PORTAL: true, CARRIER_PORTAL: false},
		"customportal": {CONQUEST_PORTAL: true, CARRIER_PORTAL: false, CARRIER_MODE: false},
		"carrierstrike": {CARRIER_MODE: true, CARRIER_PORTAL: false, CONQUEST_PORTAL: false},
		"conquest": {CONQUEST_MODE: true, CONQUEST_PORTAL: false, CARRIER_PORTAL: false, CARRIER_MODE: false},
	}
	for mode in cases.keys():
		var act := _act(str(mode))
		var portal: bool = act.has(Ctx.PORTAL_CONTEXT)
		for layer in (cases[mode] as Dictionary).keys():
			var want: bool = (cases[mode] as Dictionary)[layer]
			var got: bool = Ctx.layer_visible(str(layer), portal, act)
			if got != want:
				failures += 1
			print("%-16s %-42s want %-5s got %-5s%s" % [
				"[" + str(mode) + "]", str(layer), str(want), str(got),
				"" if got == want else "   <-- FAIL"])

	# THE LAYER KEYS THEMSELVES, from real scopes on real levels. A key that
	# names no pickable mode is content nothing can ever show.
	var Gs = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")
	var scopes := {
		# mp_isolated: the Gauntlet extraction zone, 150 placements, leaf names
		# no mode. Must offer "gauntlet".
		"game/glaciermp/levels/mp_isolated/_layers_gameplay/gauntlet/dallasgauntlet_extraction":
			"gauntlet",
		# mp_abbasid: the mode is in the LEAF here, not the folder.
		"game/glaciermp/levels/mp_abbasid/_layers_gameplay/portalnext/customportal":
			"customportal",
		# mp_abbasid: abbreviations no mode matches - shared dressing, always on.
		"game/glaciermp/levels/mp_abbasid/_layers_gameplay/sharedassets_tdm_dom": "",
		# a plain mode layer keeps its own name.
		"game/glaciermp/levels/mp_isolated/_layers_gameplay/carrierstrike": "carrierstrike",
	}
	for scope in scopes.keys():
		var want_part := str(scopes[scope])
		var key := str(Gs.layer_of_scope_for(str(scope), "mp_isolated"))
		var parts := key.split(",")
		var ok := (key == "" and want_part == "") or (want_part in parts)
		if not ok:
			failures += 1
		print("%-16s %-52s want part %-14s got key %-28s%s" % [
			"[layer_of_scope]", str(scope).get_file(), "\"" + want_part + "\"",
			"\"" + key + "\"", "" if ok else "   <-- FAIL"])

	# THE FAILURE THAT WOULD ACTUALLY HURT: both copies on at once, in any mode.
	for mode in ["", "Off", "customportal", "carrierstrike", "conquest", "escalation", "rush"]:
		var act := _act(str(mode))
		var portal: bool = act.has(Ctx.PORTAL_CONTEXT)
		if Ctx.layer_visible(CARRIER_MODE, portal, act) \
				and Ctx.layer_visible(CARRIER_PORTAL, portal, act):
			print("FAIL both carrier copies visible in mode '%s'" % str(mode))
			failures += 1
	print("\n%s" % ("PASS" if failures == 0 else "FAIL: %d case(s)" % failures))
	quit(1 if failures else 0)
