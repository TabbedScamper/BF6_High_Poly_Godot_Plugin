@tool
extends SceneTree
# THE EXPERIMENT: walk a per-mode subworld AS A ROOT and see whether the
# gameplay entities appear. If they do, the default walk simply never visits
# them; if they do not, conquest uses types other than these.
const WANT := {
	"f7fbc419-e145-394f-7086-b81c1935e8ab": "Spawn",
	"9fc7ba2d-7564-b0a6-8a9c-61f3fd93e55d": "VolumeShape",
	"c8e55f62-8409-c039-a6bb-fbd11cb03739": "OBB",
	"e529dbe3-1ef0-5632-37a6-82f9a3ac003f": "Objective",
	"e36c4110-716c-d05f-7615-8f7b8a5d620b": "CombatArea",
}
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	for g in WANT: gs.walk.want_types[g] = WANT[g]
	var pre := "game/glaciermp/levels/mp_aftermath/_layers_gameplay/"
	var roots: Array = []
	for k in gs.src.ebx.keys():
		var s := str(k)
		if s.begins_with(pre) and (s.findn("conquest") >= 0 or s.findn("domination") >= 0
				or s.findn("rush") >= 0 or s.findn("gameplay") >= 0):
			roots.append(s)
	roots.sort()
	print("mode-ish roots: %d" % roots.size())
	for r in roots.slice(0, 10): print("   ", r.substr(pre.length()))
	var total := 0
	var found := {}
	for r in roots:
		gs.walk.ents.clear()
		var ref = gs.walk.resolve_name(r)
		if ref == null: continue
		gs.walk.walk(ref, BF6Walk.IDENT, {}, 0)
		if gs.walk.ents.size() > 0:
			for e in gs.walk.ents:
				var t := str((e as Dictionary).get("type", "?"))
				var nm := str(gs.walk.want_types.get(t, t.substr(0, 8)))
				found[nm] = int(found.get(nm, 0)) + 1
			total += gs.walk.ents.size()
			print("  %-46s -> %d ents" % [r.substr(pre.length()).left(46), gs.walk.ents.size()])
	print("\ntotal entities from mode roots: %d" % total)
	for k in found: print("   %-16s %d" % [k, found[k]])
	quit(0)
