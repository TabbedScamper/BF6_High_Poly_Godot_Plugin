extends SceneTree

# What a live reload tells the user to do about the meshes already on screen.
#
# The thing being pinned down: which FILE changed is not the same question as
# whether the built geometry is stale, and answering the first as if it were the
# second charges the user a full map rebuild for a change that cannot move a
# vertex. The epoch is the deliberate answer; the file lists only say WHERE to
# look.

const Reload = preload("res://addons/highpoly_toggle/highpoly_reload.gd")
const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")

var fails: Array = []

func ck(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails.append(what)


func _initialize() -> void:
	print("\n--- nothing changed ---")
	ck(Reload.impact([], false) == "none", "an empty list is 'none'")

	print("\n--- the epoch did NOT move ---")
	ck(Reload.impact(["bf6_walk.gd"], false) == "materials",
		"a geometry file whose output did not change asks for a re-dress, not a rebuild")
	ck(Reload.impact(["highpoly_gamesource.gd"], false) == "materials",
		"same for a mixed file")
	ck(Reload.impact(["highpoly_toggle.gd"], false) == "code",
		"a cosmetic file still touches nothing built")
	ck(Reload.impact(["highpoly_toggle.gd", "bf6_splat.gd"], false) == "materials",
		"a cosmetic file alongside a geometry one does not hide it")

	print("\n--- the epoch DID move ---")
	ck(Reload.impact(["bf6_walk.gd"], true) == "geometry",
		"then a geometry file does mean rebuild")
	ck(Reload.impact(["highpoly_gamesource.gd"], true) == "mixed",
		"and a mixed file means re-dress plus rebuild")
	ck(Reload.impact(["highpoly_toggle.gd"], true) == "code",
		"a cosmetic file is still cosmetic: the epoch alone proves nothing about it")

	print("\n--- the default ---")
	# A caller that cannot answer the epoch question must get the pessimistic
	# verdict. Telling someone to rebuild when they need not costs a minute;
	# not telling them when they must leaves a map that is quietly wrong.
	ck(Reload.impact(["bf6_walk.gd"]) == "geometry",
		"an unqualified call still says rebuild")

	print("\n--- the epoch itself ---")
	ck(GS.geom_epoch() == GS.GEOM_EPOCH, "the call agrees with the constant")
	ck(GS.geom_epoch() > 0, "and is a real value (%d)" % GS.geom_epoch())

	print("\n%s  (%d failure(s))" % ["PASS" if fails.is_empty() else "FAILED", fails.size()])
	quit(0 if fails.is_empty() else 1)
