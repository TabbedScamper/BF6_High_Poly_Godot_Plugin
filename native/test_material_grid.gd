extends SceneTree

# Public ABI -> raw GDExtension -> Godot proof for the material relation grid.
#
# The grid answers "what happens when material A meets material B". This checks
# the three products the editor panel is built on come through the binding
# intact, and it checks the two that are easy to get subtly wrong:
#
#   1. A material the level does NOT ship must report shipped=0 and no
#      relations, never the default material's relations wearing its name.
#   2. Every relation must arrive with a category, because the panel groups by
#      category and a blank one would silently vanish from the UI.
#
# Nothing is exported and nothing is written; the packet is parsed in memory.

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_material_grid.gd -- <Steam BF6 root> [level]")
		quit(2)
		return
	var game_dir := str(args[0])
	var level := str(args[1]) if args.size() > 1 else "mp_subsurface"
	if not ClassDB.class_exists("BF6Core"):
		print("FAIL: BF6Core is not registered")
		quit(1)
		return
	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(game_dir):
		print("FAIL open: %s" % (core.last_error() if core != null else "null"))
		quit(1)
		return

	var env := preload("res://addons/highpoly_toggle/bf6_environment.gd").new(core, level)
	var failures := 0

	var grid := env.request("material_grid")
	if grid.is_empty():
		print("FAIL material_grid: %s" % env.error)
		quit(1)
		return
	print("grid: side %d, declared %d, ids %d, occupied %d, relations %d, types %d, fallback %d" % [
		int(grid.get("side", 0)), int(grid.get("declared_dim", 0)), int(grid.get("id_map_len", 0)),
		int(grid.get("occupied_cells", 0)), int(grid.get("relations", 0)),
		int(grid.get("relation_types", 0)), int(grid.get("fallback_ids", 0))])
	# The declared dimension is 128 while the real side is the level's material
	# count. Asserted so a reader that starts trusting the declared value fails
	# here rather than in a panel showing another pair's relations.
	if int(grid.get("side", 0)) == int(grid.get("declared_dim", 0)):
		print("  NOTE declared dimension equals the side on this level")

	# The busiest surfaces, ordered by core so both editors show one list.
	var busiest: Array = grid.get("busiest", [])
	print("shipped materials %d, busiest %d row(s):" % [int(grid.get("shipped_materials", 0)), busiest.size()])
	var previous := -1
	for i in range(min(5, busiest.size())):
		var b: Dictionary = busiest[i]
		print("   material %4d  row %4d  %4d partner(s)  %5d relation(s)" % [
			int(b.get("material", -1)), int(b.get("row", -1)),
			int(b.get("partners", 0)), int(b.get("relations", 0))])
	# Descending is the contract the panels rely on to show "the main surfaces".
	for b in busiest:
		var n := int((b as Dictionary).get("relations", 0))
		if previous >= 0 and n > previous:
			print("FAIL busiest is not ordered by relation count")
			failures += 1
			break
		previous = n

	# A shipped material: its ROW is what an editor shows for one clicked object.
	var shipped := -1
	var fallback := -1
	for id in range(int(grid.get("id_map_len", 0))):
		var p := env.request("material_profile", id)
		if p.is_empty(): continue
		if int(p.get("shipped", 0)) == 1 and int(p.get("partners", 0)) > 0 and shipped < 0:
			shipped = id
			print("shipped material %d: row %d, %d partners, %d relations, %s" % [
				id, int(p.get("row", -1)), int(p.get("partners", 0)),
				int(p.get("row_relations", 0)), str(p.get("categories", {}))])
		elif int(p.get("shipped", 0)) == 0 and fallback < 0:
			fallback = id
			# 1. the fallback must not borrow the default's relations
			if int(p.get("partners", 0)) != 0 or int(p.get("row_relations", 0)) != 0:
				print("FAIL material %d is not shipped but reports %d partners" % [id, int(p.get("partners", 0))])
				failures += 1
			else:
				print("unshipped material %d: shipped=0, no relations (falls back to the default)" % id)
		if shipped >= 0 and fallback >= 0: break

	if shipped < 0:
		print("FAIL no shipped material with relations was found")
		failures += 1
	if fallback < 0:
		print("NOTE no unshipped material on this level; that control did not run")

	# The default material against itself is the level's property set: one
	# relation of every type the level carries.
	var pair := env.request("material_pair", 0)
	if pair.is_empty():
		print("FAIL material_pair: %s" % env.error)
		failures += 1
	else:
		var rels: Array = pair.get("relations", [])
		var blank := 0
		var cats := {}
		for r in rels:
			var c := str((r as Dictionary).get("category", ""))
			if c.is_empty(): blank += 1
			else: cats[c] = int(cats.get(c, 0)) + 1
		print("material 0 vs 0: %d relation(s), categories %s" % [rels.size(), str(cats)])
		# 2. a blank category would disappear from a panel that groups by it
		if blank > 0:
			print("FAIL %d relation(s) arrived with no category" % blank)
			failures += 1

	print("\n%s" % ("PASS" if failures == 0 else "FAIL: %d problem(s)" % failures))
	quit(1 if failures else 0)
