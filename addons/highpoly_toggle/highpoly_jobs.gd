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

func busy() -> bool: return _active_id != 0 or not _waiting.is_empty()
func active_label() -> String: return _active
func ratio() -> float: return _ratio
func index() -> int: return _completed + 1        # 1-based, for "1/2"
func count() -> int: return maxi(_batch, 1)
func queued() -> int: return _waiting.size()

# Wait for the slot. Await this before starting a transfer; hold the returned
# token and hand it back to release().
func acquire(name: String) -> int:
	_next_id += 1
	var id := _next_id
	_waiting.append({"id": id, "name": name})
	_batch = maxi(_batch, _completed + _waiting.size() + (1 if _active_id != 0 else 0))
	if _active_id != 0:
		Log.info("Queued: %s — waiting for %s" % [name, _active])
	changed.emit()
	while _active_id != 0 or (_waiting.size() > 0 and int(_waiting[0]["id"]) != id):
		if not is_inside_tree(): return id        # panel closed mid-wait
		await get_tree().process_frame
	if _waiting.size() > 0 and int(_waiting[0]["id"]) == id:
		_waiting.pop_front()
	_active_id = id
	_active = name
	_ratio = 0.0
	Log.info("Started: %s  (%d of %d)" % [name, index(), count()])
	changed.emit()
	return id

func report(done: int, total: int) -> void:
	_ratio = clampf(float(done) / float(total), 0.0, 1.0) if total > 0 else 0.0
	changed.emit()

func release(id: int, ok: bool, note := "") -> void:
	if _active_id != id:
		return                                    # already released, or never held
	var name := _active
	_active_id = 0
	_active = ""
	_ratio = 0.0
	_completed += 1
	if ok:
		Log.info("Finished: %s%s" % [name, ("  — " + note) if note != "" else ""])
	else:
		Log.error("FAILED: %s%s" % [name, ("  — " + note) if note != "" else ""])
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
	_waiting.clear()
	_active_id = 0
	_active = ""
	_ratio = 0.0
	_completed = 0
	_batch = 0
	changed.emit()
