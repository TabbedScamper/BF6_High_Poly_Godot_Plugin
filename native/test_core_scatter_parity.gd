extends SceneTree

# Row-for-row cut-over proof for the first core Godot slice.
#
# Real pairing compares every field shared by the old live GDScript decoder and
# bf6_level_scatter. Rotating the old rows is the shuffled-pair control. A fake
# level is the scope control. The GDScript path remains an oracle only while
# this cut is being proven; production consumes the native rows afterward.

const BF6Source := preload("res://bf6_source.gd")
const BF6Scatter := preload("res://bf6_scatter.gd")

func _same(native: Dictionary, old: Dictionary) -> bool:
	return str(native.get("name", "")) == str(old.get("name", "")) \
		and is_equal_approx(float(native.get("distance", -1.0)), float(old.get("distance", -2.0))) \
		and is_equal_approx(float(native.get("ratio", -1.0)), float(old.get("ratio", -2.0))) \
		and int(native.get("point_count", -1)) == (old.get("points", PackedVector3Array()) as PackedVector3Array).size()

func _init() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: test_core_scatter_parity.gd -- <Steam BF6 root> [level]")
		quit(2)
		return
	var game_dir := str(args[0])
	var level := str(args[1]) if args.size() > 1 else "mp_dumbo"

	var src = BF6Source.new()
	if not src.open(game_dir) or not src.mount(level):
		print("FAIL old live path: %s" % src.error)
		quit(1)
		return
	var res_name := BF6Scatter.find_res(src, level)
	var raw: PackedByteArray = src.get_res(res_name)
	var old = BF6Scatter.new()
	if res_name == "" or not old.parse(raw) or not old.exact(raw.size()):
		print("FAIL old scatter parse: %s" % old.error)
		quit(1)
		return

	var core = ClassDB.instantiate("BF6Core")
	if core == null or not core.open(game_dir):
		print("FAIL native open: %s" % (core.last_error() if core != null else "null"))
		quit(1)
		return
	var envelope = JSON.parse_string(str(core.scatter(level)))
	var fake = JSON.parse_string(str(core.scatter("MP_NotARealLevel")))
	if not envelope is Dictionary or not fake is Dictionary:
		print("FAIL native envelope")
		quit(1)
		return
	var rows: Array = envelope.get("rows", [])
	var real_score := 0
	var rotated_score := 0
	for i in range(mini(rows.size(), old.records.size())):
		if _same(rows[i], old.records[i]):
			real_score += 1
		if old.records.size() > 1 and _same(rows[i], old.records[(i + 1) % old.records.size()]):
			rotated_score += 1
	var fake_rows: Array = fake.get("rows", [])
	print("REAL pairing: %d/%d" % [real_score, rows.size()])
	print("CONTROL rotated pairing: %d/%d" % [rotated_score, rows.size()])
	print("CONTROL fake level: %d row(s)" % fake_rows.size())
	var ok: bool = bool(envelope.get("ok", false)) \
		and rows.size() == old.records.size() and real_score == rows.size() \
		and rotated_score == 0 and fake_rows.is_empty()
	print("PASS" if ok else "FAIL")
	quit(0 if ok else 1)
