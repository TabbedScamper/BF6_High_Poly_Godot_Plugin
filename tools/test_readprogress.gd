extends SceneTree

# The read-progress checklist model. Static, and takes its clock as an argument,
# precisely so it can be driven here: the panel itself lives on an EditorPlugin
# and cannot be built outside a running editor.
#
# What is worth testing is not "does it format a line" but the two ways the list
# lies to you: a stage that is skipped entirely (a cached walk never calls back)
# must not sit on "waiting" for the rest of the read, and a stage that took no
# time must say WHY it took no time.

const Dock = preload("res://addons/highpoly_toggle/highpoly_toggle.gd")
const GS = preload("res://addons/highpoly_toggle/highpoly_gamesource.gd")

var fails: Array = []

func ck(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		fails.append(what)


func line_for(m: Dictionary, stage: String, now: int) -> String:
	for l in Dock.read_model_lines(m, now):
		if str(l).contains(stage):
			return str(l)
	return "<missing>"


func _initialize() -> void:
	var S: Array = GS.OPEN_STAGES
	print("\n--- stage list ---")
	ck(S.size() >= 5, "there are %d declared stages" % S.size())
	ck(str(S[0]) == GS.ST_MOUNT, "the first stage is the mount")

	print("\n--- a fresh model ---")
	var m := Dock.read_model_new("MP_Dumbo", true, 1000)
	ck(str(m["stage"]) == GS.ST_MOUNT, "starts on the first stage")
	var l0 := Dock.read_model_lines(m, 1000)
	ck(l0.size() == S.size(), "one line per stage, always (%d)" % l0.size())
	ck(str(l0[0]).contains("NOW"), "the first stage is the running one")
	ck(str(l0[1]).contains("waiting"), "the rest are waiting")
	ck(Dock.read_model_title(m, 4000).contains("MP_Dumbo"), "the title names the map")

	print("\n--- a stage with a real fraction ---")
	Dock.read_model_stage(m, GS.ST_INDEX, 55, 220, 3000)
	ck(line_for(m, GS.ST_INDEX, 3000).contains("25%"), "55/220 reads as 25%")
	ck(line_for(m, GS.ST_MOUNT, 3000).contains("done"),
		"the stage it left is done: %s" % line_for(m, GS.ST_MOUNT, 3000))
	# ST_TYPES was jumped over entirely and must not be left hanging
	ck(line_for(m, GS.ST_TYPES, 3000).contains("done"),
		"a stage that never reported is still marked done, not left waiting")
	ck(line_for(m, GS.ST_TYPES, 3000).contains("cached"),
		"…and says 'cached' rather than showing a bogus 0s")

	print("\n--- a stage that can only count ---")
	Dock.read_model_stage(m, GS.ST_WALK, 21437, 0, 9000)
	var wl := line_for(m, GS.ST_WALK, 39000)
	ck(wl.contains("21,437"), "a count is grouped for reading: %s" % wl.strip_edges())
	ck(not wl.contains("%"), "and claims no percentage it cannot know")
	ck(wl.contains("30s"), "the stage clock runs from when the stage started")
	ck(Dock.read_model_title(m, 39000).contains("38s"),
		"the total clock runs from when the read started")

	print("\n--- elapsed formatting ---")
	ck(Dock._clock(0) == "0s", "0")
	ck(Dock._clock(45_000) == "45s", "45s")
	ck(Dock._clock(60_000) == "1:00", "a minute rolls over")
	ck(Dock._clock(95_400) == "1:35", "1:35")
	ck(Dock._grouped(1) == "1", "1")
	ck(Dock._grouped(999) == "999", "999")
	ck(Dock._grouped(1000) == "1,000", "1,000")
	ck(Dock._grouped(268587) == "268,587", "268,587")

	print("\n--- the warm case, where every stage is skipped ---")
	var w := Dock.read_model_new("MP_Dumbo", false, 0)
	Dock.read_model_stage(w, str(S[S.size() - 1]), 0, 0, 1200)
	var left := 0
	for l in Dock.read_model_lines(w, 1200):
		if str(l).contains("waiting"):
			left += 1
	ck(left == 0, "nothing is left on 'waiting' once the last stage is running, got %d" % left)

	print("\n%s  (%d failure(s))" % ["PASS" if fails.is_empty() else "FAILED", fails.size()])
	quit(0 if fails.is_empty() else 1)
