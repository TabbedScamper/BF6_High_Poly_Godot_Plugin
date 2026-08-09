@tool
extends SceneTree
# Does the walk reach the gamemode entities if we ask for their types?
const WANT := {
	"8cba5d25-59fe-fa86-1c2a-8140e224d7da": "CapturePoint",
	"e529dbe3-1ef0-5632-37a6-82f9a3ac003f": "Objective",
	"e36c4110-716c-d05f-7615-8f7b8a5d620b": "CombatArea",
}
func _init() -> void:
	var gs = HighpolyGameSource.new()
	gs.log_fn = func(_s: String) -> void: pass
	gs.catalogue_mount = false
	# open WITHOUT the walk, then run it ourselves with the extra types asked for
	if not gs.open_map("MP_Aftermath", "", Callable(), {"placements": false}):
		print("open failed"); quit(1); return
	for g in WANT: gs.walk.want_types[g] = WANT[g]
	# also the byte-rotated form the light table carries a second entry for
	for g in WANT.keys():
		var b: String = str(g).replace("-", "")
		var rot: String = b.substr(8, 4) + b.substr(4, 4) + "-" + b.substr(0, 4) + "-" \
			+ b.substr(16, 4) + "-" + b.substr(12, 4) + "-" + b.substr(20)
		gs.walk.want_types[rot] = str(WANT[g]) + "*"
	print("want_types now: %d" % gs.walk.want_types.size())
	if not gs.walk.run_cached("mp_aftermath"):
		print("walk failed"); quit(1); return
	print("walk rows %d, ents %d" % [gs.walk.rows.size(), gs.walk.ents.size()])
	var tally := {}
	for e in gs.walk.ents:
		var t := str((e as Dictionary).get("type", "?"))
		tally[t] = int(tally.get(t, 0)) + 1
	var rows: Array = []
	for k in tally: rows.append([str(k), int(tally[k])])
	rows.sort_custom(func(a,b): return int(a[1]) > int(b[1]))
	print("entities by type guid:")
	for r in rows.slice(0, 14):
		var nm := str(gs.walk.want_types.get(str(r[0]), ""))
		print("   %-40s %-14s %d" % [str(r[0]).substr(0,36), nm, r[1]])
	quit(0)
