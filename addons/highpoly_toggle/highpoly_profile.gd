@tool
extends Object
class_name HighpolyProfile
# Named-bucket frame timer. Answers "what ate that frame", not "what is slow on
# average".
#
# WHY A SECOND TIMER WHEN highpoly_profiler.gd EXISTS: that one is a session
# recorder. It samples fps twice a second, attributes triangles to owners and
# writes a CSV, and its span() takes MILLIseconds, so anything under 1 ms reads
# as zero and a burst that lands inside one 0.5 s sample is averaged away. The
# complaint we are chasing is a stutter: a run that averages 90 fps and drops to
# 12 four times. That is invisible to a mean, so this measures in MICROseconds,
# keys everything by frame, and keeps the worst frames whole rather than
# summarising them.
#
# COST WHEN OFF is the whole design constraint. Every entry point in the plugin
# calls into here, so `enabled` is a plain static bool tested first and nothing
# else happens: no allocation, no clock read, no dictionary touch.
#
# MEASURED, not assumed (Godot 4.6.3, 200k iterations, this machine):
#   two calls to an EMPTY static function taking a String   0.154 us
#   begin/end pair with the profiler OFF                    0.209 us
#   begin/end pair with the profiler ON                     1.410 us
# So three quarters of the off cost is GDScript's own call overhead and the
# guard itself is around 0.06 us per pair. The ~25 pairs the panel's half-second
# tick makes therefore add roughly 5 us to a 500,000 us interval. Switched on,
# the same tick pays about 35 us, which is still under a thousandth of a frame.
#
# ALWAYS REACH THIS THROUGH THE class_name, never through a preload of the file.
# A live plugin reload leaves two copies of the script in memory, and a caller
# holding a preload writes its statics into the copy nobody reads. Same reason
# highpoly_toggle.gd keeps LibScript around only for assignments.
#
# SELF TIME IS WHAT THE FRAME ACCOUNTING USES. Buckets nest (the panel tick
# contains the light cull contains nothing), so summing inclusive times would
# count the same microsecond several times over and the "frame total" would be a
# fiction. Each bucket is charged only the time not spent inside a bucket nested
# under it, which means the per-frame totals add up and the biggest contributor
# to a bad frame is the code that actually ran, not its outermost caller.

# One frame at 60 fps. A frame whose instrumented work exceeds this cannot have
# hit 60 even if the renderer were free, so it is counted separately: a count of
# blown frames is the number the "steady 60+" target is really about.
const BUDGET_US := 16667
# How many bad frames to keep whole. Eight is enough to tell a repeating pattern
# (the same bucket every time) from a one-off (a build finishing).
const TOP_FRAMES := 8
# Below this a frame is not a hitch and keeping its breakdown only pads the list.
# Without a floor the "worst frames" section fills up with 0.3 ms frames on a
# quiet session and reads as if something were wrong.
const HITCH_FLOOR_US := 4000

# Row layout, by index rather than a nested Dictionary: this is written on every
# single end() and an Array index is markedly cheaper than a string key.
const _CALLS := 0
const _INCL := 1        # wall time including nested buckets
const _SELF := 2        # wall time excluding nested buckets
const _MAXC := 3        # slowest single call, inclusive
const _MAXF := 4        # worst single frame, self

# DEFAULT FALSE. Anything that flips this on by itself is a bug: a profiler the
# user did not ask for is just overhead.
static var enabled := false

# Where the frame boundary comes from. Negative means Engine.get_process_frames(),
# which is what the editor uses. A headless `--script` run has no process frames
# at all (the counter sits at 0 forever), so the tests set this by hand; so could
# anything that genuinely owns the frame and wants a hard boundary.
static var frame_override := -1

static var _tot: Dictionary = {}        # bucket name -> row Array, see indices above
static var _frame: Dictionary = {}      # bucket name -> self us so far THIS frame
static var _cur_frame := -1
static var _frames := 0                 # frames in which at least one bucket ran
static var _over := 0                   # of those, how many blew BUDGET_US
static var _worst: Array = []           # kept sorted worst first, at most TOP_FRAMES
static var _worst_min := 0              # us of the weakest kept frame; below this, do not copy
static var _mismatch := 0               # end() with no matching begin()
static var _t_start := 0                # ticks_usec when recording was switched on
static var _t_stop := 0

# The open-bucket stack. Three packed arrays rather than one Array of Arrays so
# that a begin() allocates nothing after the first few frames have grown them.
static var _s_name: PackedStringArray = PackedStringArray()
static var _s_t0: PackedInt64Array = PackedInt64Array()
static var _s_child: PackedInt64Array = PackedInt64Array()
static var _depth := 0


# ---------- switching on and off ----------

static func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	# The stack cannot survive the switch: whatever was open when recording
	# stopped will call end() with `enabled` false and never be closed, and the
	# next run would then charge its time to a stranger.
	_depth = 0
	_s_name.clear()
	_s_t0.clear()
	_s_child.clear()
	if on:
		reset()
		_t_start = Time.get_ticks_usec()
	else:
		_t_stop = Time.get_ticks_usec()


static func reset() -> void:
	_tot.clear()
	_frame.clear()
	_worst.clear()
	_worst_min = 0
	_cur_frame = -1
	_frames = 0
	_over = 0
	_mismatch = 0
	_depth = 0
	_s_name.clear()
	_s_t0.clear()
	_s_child.clear()
	_t_start = Time.get_ticks_usec()
	_t_stop = 0


# ---------- the two calls everything else uses ----------
#
# NO SCOPE OBJECT. The tidy version of this is a RefCounted that closes itself
# when the local goes out of scope, and it was not built: it allocates an object
# per measurement, which is the one cost this must not have. A begin/end pair is
# uglier at the call site and free. The name argument to end() buys back most of
# what the scope object would have given, which is surviving an early return.

# Open a bucket. Name it after WHAT THE CODE DOES, not after the function: the
# report is read by someone deciding what to switch off, and "map light culling"
# tells them that where "tick_lights" does not.
static func begin(name: String) -> void:
	if not enabled:
		return
	if _depth == 0:
		_roll(frame_override if frame_override >= 0 else Engine.get_process_frames())
	_s_name.append(name)
	_s_child.append(0)
	# Clock read LAST, so the array growth above is charged to nobody rather than
	# to the bucket being opened.
	_s_t0.append(Time.get_ticks_usec())
	_depth += 1


# Close a bucket. The name is required so a function that returns early without
# closing is survivable: the stack is unwound down to the name given rather than
# left permanently one deep, which would otherwise make every later bucket look
# like a child of the leaked one.
static func end(name: String) -> void:
	if not enabled:
		return
	var t := Time.get_ticks_usec()
	if _depth == 0:
		_mismatch += 1
		return
	var i := _depth - 1
	if _s_name[i] != name:
		var j := i
		while j >= 0 and _s_name[j] != name:
			j -= 1
		if j < 0:
			_mismatch += 1
			return
		while _depth - 1 > j:
			_close(_depth - 1, t)
		i = j
	_close(i, t)


# Time an already-measured span without wrapping the code. For call sites that
# already had a Time.get_ticks_* pair around them.
static func add(name: String, us: int) -> void:
	if not enabled:
		return
	if _depth == 0:
		_roll(frame_override if frame_override >= 0 else Engine.get_process_frames())
	var row: Array = _row(name)
	row[_CALLS] += 1
	row[_INCL] += us
	row[_SELF] += us
	if us > row[_MAXC]:
		row[_MAXC] = us
	_frame[name] = int(_frame.get(name, 0)) + us


static func _row(name: String) -> Array:
	# One dictionary lookup on the hit path, and the default form of get() is
	# avoided on purpose: get(name, []) builds a throwaway Array on every call,
	# and this runs on every end().
	var row = _tot.get(name)
	if row == null:
		row = [0, 0, 0, 0, 0]
		_tot[name] = row
	return row


static func _close(i: int, t: int) -> void:
	var incl: int = t - _s_t0[i]
	var self_us: int = incl - _s_child[i]
	var nm: String = _s_name[i]
	var row: Array = _row(nm)
	row[_CALLS] += 1
	row[_INCL] += incl
	row[_SELF] += self_us
	if incl > row[_MAXC]:
		row[_MAXC] = incl
	_frame[nm] = int(_frame.get(nm, 0)) + self_us
	_depth -= 1
	_s_name.resize(_depth)
	_s_t0.resize(_depth)
	_s_child.resize(_depth)
	if _depth > 0:
		_s_child[_depth - 1] += incl


# ---------- per-frame accounting ----------
#
# The frame boundary comes from Engine.get_process_frames() rather than from a
# node's _process, because this is a static with no node of its own and the code
# it measures runs from Timer callbacks, input forwarding and signal handlers
# that have no single owner. Checked only when the stack is empty, so it costs
# one engine call per outermost bucket rather than one per begin().
#
# A frame in which nothing instrumented ran is simply not recorded. That is
# deliberate: those frames are the renderer's, and this timer has nothing to say
# about them.
static func _roll(f: int) -> void:
	if _cur_frame == f:
		return
	if _cur_frame >= 0 and not _frame.is_empty():
		_frames += 1
		var tot := 0
		var top := ""
		var top_us := 0
		for k in _frame:
			var v: int = _frame[k]
			tot += v
			if v > top_us:
				top_us = v
				top = k
			var row: Array = _tot[k]
			if v > row[_MAXF]:
				row[_MAXF] = v
		if tot > BUDGET_US:
			_over += 1
		# The breakdown is only copied for a frame bad enough to be kept, so the
		# common case costs nothing but the walk above.
		if tot >= HITCH_FLOOR_US and (_worst.size() < TOP_FRAMES or tot > _worst_min):
			_worst.append({"frame": _cur_frame, "us": tot, "top": top,
				"top_us": top_us, "rows": _frame.duplicate()})
			_worst.sort_custom(func(a, b): return int(a["us"]) > int(b["us"]))
			if _worst.size() > TOP_FRAMES:
				_worst.resize(TOP_FRAMES)
			_worst_min = int(_worst[_worst.size() - 1]["us"])
	_frame.clear()
	_cur_frame = f


# ---------- reading it back ----------

static func has_data() -> bool:
	return not _tot.is_empty()


# Raw numbers, for a test or a caller that wants to draw its own view.
# {buckets: {name: {calls, incl_us, self_us, max_call_us, max_frame_us}},
#  frames, over_budget, worst: [...]}
static func stats() -> Dictionary:
	var b := {}
	for k in _tot:
		var r: Array = _tot[k]
		b[k] = {"calls": r[_CALLS], "incl_us": r[_INCL], "self_us": r[_SELF],
			"max_call_us": r[_MAXC], "max_frame_us": r[_MAXF]}
	return {"buckets": b, "frames": _frames, "over_budget": _over,
		"mismatched": _mismatch, "worst": _worst.duplicate(true),
		"span_us": (_t_stop if _t_stop > 0 else Time.get_ticks_usec()) - _t_start}


static func _pad(s: String, w: int) -> String:
	return s + " ".repeat(maxi(0, w - s.length()))


static func _rpad(s: String, w: int) -> String:
	return " ".repeat(maxi(0, w - s.length())) + s


static func _ms(us: int) -> String:
	return "%.2f" % (float(us) / 1000.0)


static func report() -> String:
	if _tot.is_empty():
		return "Frame profiler: nothing recorded. It is %s." \
			% ("on, so either nothing ran or nothing is instrumented" if enabled else "off")
	# Bound to a local before the lambdas below touch it: a lambda inside a static
	# function has no `self` to resolve class members through, so the statics are
	# handed to it explicitly. Dictionaries are references, so this is the same data.
	var tot: Dictionary = _tot
	var keys: Array = tot.keys()
	keys.sort_custom(func(a, b): return int(tot[a][_SELF]) > int(tot[b][_SELF]))
	var span_us: int = (_t_stop if _t_stop > 0 else Time.get_ticks_usec()) - _t_start
	var out: Array = []
	out.append("Frame profiler over %.1f s: %d frames did instrumented work, %d of them went over %.1f ms."
		% [float(span_us) / 1000000.0, _frames, _over, float(BUDGET_US) / 1000.0])
	if _over > 0:
		out.append("The over-budget frames are the stutter. The table below is sorted by total time, which is NOT where a stutter shows, so read the worst frames underneath it instead.")
	out.append("")
	out.append("%s %s %s %s %s %s" % [_pad("bucket", 40), _rpad("calls", 8),
		_rpad("total ms", 10), _rpad("self ms", 10), _rpad("avg us", 9),
		_rpad("worst call", 11)])
	out.append("=".repeat(92))
	for k in keys:
		var r: Array = tot[k]
		var calls: int = r[_CALLS]
		out.append("%s %s %s %s %s %s" % [
			_pad(str(k), 40), _rpad(str(calls), 8),
			_rpad(_ms(r[_INCL]), 10), _rpad(_ms(r[_SELF]), 10),
			_rpad(str(int(float(r[_INCL]) / float(maxi(calls, 1)))), 9),
			_rpad(_ms(r[_MAXC]) + " ms", 11)])
	out.append("")
	out.append("Worst single frame per bucket, self time. A bucket that is cheap in total")
	out.append("and expensive here is a stutter you would never find in the table above.")
	var byframe: Array = tot.keys()
	byframe.sort_custom(func(a, b): return int(tot[a][_MAXF]) > int(tot[b][_MAXF]))
	for i in mini(byframe.size(), 12):
		var k = byframe[i]
		var r: Array = tot[k]
		if int(r[_MAXF]) <= 0:
			break
		out.append("  %s %s ms" % [_pad(str(k), 44), _rpad(_ms(r[_MAXF]), 8)])
	out.append("")
	if _worst.is_empty():
		out.append("No frame went over %.1f ms of instrumented work, so there is no hitch to break down."
			% (float(HITCH_FLOOR_US) / 1000.0))
	else:
		out.append("The worst %d frame(s), whole:" % _worst.size())
		for w in _worst:
			var rows: Dictionary = w["rows"]
			var names: Array = rows.keys()
			names.sort_custom(func(a, b): return int(rows[a]) > int(rows[b]))
			var parts: Array = []
			for i in mini(names.size(), 4):
				parts.append("%s %s ms" % [names[i], _ms(int(rows[names[i]]))])
			out.append("  frame %d: %s ms total, worst is %s"
				% [int(w["frame"]), _ms(int(w["us"])), ", ".join(parts)])
	if _mismatch > 0:
		out.append("")
		out.append("%d unmatched end() call(s): a bucket was closed that was never opened. Its time is missing from the totals."
			% _mismatch)
	return "\n".join(out)


static func print_report() -> void:
	print(report())
