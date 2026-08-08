@tool
extends Node
class_name HighpolyJobs
# One download at a time, and one bar that describes it.
#
# Before this, asking for two things at once started two transfers. Over one
# connection that is slower overall than doing them in turn, and it left the
# panel trying to describe two moving numbers at once. Now every download takes
# a turn: the second one waits, and the bar reads "45%  1/2" — this job's
# progress, and which of the queued jobs it is.
#
# The gate is a token rather than a name, so two downloads that happen to be
# called the same thing cannot both decide it is their turn on the same frame.

signal changed

const Log = preload("highpoly_log.gd")

var _waiting: Array = []        # [{id, name}] in the order they asked
var _active_id := 0
var _active := ""
var _ratio := 0.0
var _completed := 0             # finished so far in this run of work
var _batch := 0                 # how many the run started out with
var _next_id := 0
# Long work that is not a download — building the scenery meshes, for one. It
# shows on the same bar, because from the outside "it is working on my level"
# is one idea, and a second bar elsewhere in the panel just splits attention.
# A real download outranks it: transfers can fail, local work only takes time.
# KEYED by label, not a single slot. Two long jobs can genuinely run at once —
# building the level's scenery while models download — and with one slot each
# overwrote the other every frame, so the bar jumped between two unrelated
# ratios ("going nuts") and either one's clear_activity() wiped the other's
# display. Each caller now owns its own key and clears only that.
var _acts: Dictionary = {}        # label -> ratio

func busy() -> bool:
	return _active_id != 0 or not _waiting.is_empty() or not _acts.is_empty()

func _shown_activity() -> String:
	# Deterministic pick: the least-finished job. Whichever is furthest from
	# done is the one the user is actually waiting on, and a stable choice stops
	# the label flickering between two jobs on alternate frames.
	var best := ""
	var best_r := 2.0
	for k in _acts.keys():
		var r: float = _acts[k]
		if r < best_r:
			best_r = r
			best = k
	return best

func active_label() -> String:
	if _active != "": return _active
	var k := _shown_activity()
	if k == "": return ""
	return k if _acts.size() <= 1 else "%s  (+%d more)" % [k, _acts.size() - 1]

func ratio() -> float:
	if _active_id != 0: return _ratio
	var k := _shown_activity()
	return float(_acts[k]) if k != "" else 0.0

# EVERY bar in the panel opens and closes through these two, which is why the
# profiler is told here rather than at each of the dozen call sites. A recording
# can then say which bars were up when, which overlapped, and which never
# closed — the last being a bar stuck on screen for the rest of the session,
# invisible to every other kind of instrumentation.
#
# TIMED because of what changed.emit() reaches: _refresh_job_bar in the dock,
# which writes three Labels and a ProgressBar. Callers report progress from
# inside their own loops, so the emit rate is set by whatever is loading, not by
# the frame rate, and several updates can land in one frame. If the panel gets
# choppy while something is building, this bucket is where it shows.
func set_activity(label: String, done: int, total: int) -> void:
	HighpolyProfile.begin("job bar: progress update")
	if not _acts.has(label):
		HighpolyProfiler.lane_open(label)
	_acts[label] = clampf(float(done) / float(total), 0.0, 1.0) if total > 0 else 0.0
	changed.emit()
	HighpolyProfile.end("job bar: progress update")

# label defaults to clearing EVERYTHING only for teardown; normal callers pass
# their own label so they cannot cancel somebody else's progress.
func clear_activity(label := "") -> void:
	if label == "":
		if _acts.is_empty(): return
		for k in _acts.keys():
			HighpolyProfiler.lane_close(str(k))
		_acts.clear()
	else:
		if not _acts.has(label): return
		HighpolyProfiler.lane_close(label)
		_acts.erase(label)
	changed.emit()
func index() -> int: return _completed + 1        # 1-based, for "1/2"
func count() -> int: return maxi(_batch, 1)
func acquire(name: String) -> int:
	_next_id += 1
	var id := _next_id
	_waiting.append({"id": id, "name": name})
	_batch = maxi(_batch, _completed + _waiting.size() + (1 if _active_id != 0 else 0))
	if _active_id != 0:
		Log.info("Queued: %s: waiting for %s" % [name, _active])
	changed.emit()
	# One bucket per spin, so the CALL COUNT is the number of frames this job sat
	# in the queue. The time per spin is near nothing; the count is the number
	# worth reading, because a job that spun for 900 frames means the queue, not
	# the work, is what the user was waiting on.
	while _active_id != 0 or (_waiting.size() > 0 and int(_waiting[0]["id"]) != id):
		HighpolyProfile.begin("job queue: waiting for its turn")
		if not is_inside_tree():
			HighpolyProfile.end("job queue: waiting for its turn")
			return id                             # panel closed mid-wait
		HighpolyProfile.end("job queue: waiting for its turn")
		await get_tree().process_frame
	if _waiting.size() > 0 and int(_waiting[0]["id"]) == id:
		_waiting.pop_front()
	_active_id = id
	_active = name
	_ratio = 0.0
	Log.info("Started: %s  (%d of %d)" % [name, index(), count()])
	HighpolyProfiler.lane_open(name)
	HighpolyProfiler.crumb("download", "start %s" % name)
	changed.emit()
	return id

# Same emit cost as set_activity, kept separate because this one is driven by a
# transfer's chunk size rather than by a build's loop, and the two are worth
# telling apart when reading a recording.
func report(done: int, total: int) -> void:
	HighpolyProfile.begin("job bar: download progress")
	_ratio = clampf(float(done) / float(total), 0.0, 1.0) if total > 0 else 0.0
	changed.emit()
	HighpolyProfile.end("job bar: download progress")

func release(id: int, ok: bool, note := "") -> void:
	if _active_id != id:
		return                                    # already released, or never held
	var name := _active
	HighpolyProfiler.lane_close(name)
	HighpolyProfiler.crumb("download", "%s %s" % ["done" if ok else "FAILED", name])
	_active_id = 0
	_active = ""
	_ratio = 0.0
	_completed += 1
	if ok:
		Log.info("Finished: %s%s" % [name, (" (" + note + ")") if note != "" else ""])
	else:
		Log.error("FAILED: %s%s" % [name, (" (" + note + ")") if note != "" else ""])
	# the run is over once nothing is left, so the next one counts from 1 again
	if _waiting.is_empty():
		_completed = 0
		_batch = 0
	changed.emit()

# Panel teardown: whoever was mid-transfer will never call release(), so the
# gate has to be opened here or the next session's first download waits forever.
func reset() -> void:
	if _active_id != 0:
		Log.warn("Interrupted: %s" % _active)
		HighpolyProfiler.lane_close(_active)
		HighpolyProfiler.crumb("download", "interrupted %s" % _active)
	for k in _acts.keys():
		HighpolyProfiler.lane_close(str(k))
	_waiting.clear()
	_active_id = 0
	_active = ""
	_ratio = 0.0
	_completed = 0
	_batch = 0
	_acts.clear()
	changed.emit()
