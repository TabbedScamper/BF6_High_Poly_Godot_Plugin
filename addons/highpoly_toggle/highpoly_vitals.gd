@tool
extends RefCounted
class_name HighpolyVitals

# WHAT THE MACHINE WAS DOING WHILE IT WENT WRONG.
#
# Every number this plugin has about memory, stalls and disk speed was measured
# on a developer machine by a harness the user never runs. So when someone
# reports "it sat at 13 GB", "it took 15 minutes" or "it locked up on terrain
# colours", their saved log contains nothing that can confirm, deny or locate
# any of it - and the last three investigations each cost several rounds of
# asking them to go and read Task Manager for us.
#
# Four things live here, all of them cheap enough to run always:
#
#   MACHINE      what they are running on. "Maxing out at 13-14 GB" means
#                something completely different on a 16 GB machine than on a
#                64 GB one, and we were not recording which.
#
#   MEMORY       a high-water mark WITH A LABEL for what was happening when it
#                was set, sampled off the panel heartbeat. A single end-of-run
#                total cannot say whether the peak was the terrain build or the
#                props, and that is the whole question in #76.
#
#   STALLS       the heartbeat is a 0.5 s Timer on the editor's main thread, so
#                if it fires 240 s late the main thread was blocked for 240 s.
#                That is a main-thread freeze detector for free, and it names
#                the breadcrumb that was set when it started. A 15 minute
#                terrain build previously left a SILENT GAP in the log: phases
#                are recorded when they finish, so a phase that never finishes
#                records nothing at all.
#
#   BREADCRUMB   the phase currently running, so the two above have something
#                to point at.
#
# The sampler must never itself be a cost worth investigating: four
# Performance.get_monitor reads and one OS.get_memory_info, twice a second.

const STALL_MS := 2000          # a heartbeat this late means the main thread stopped
const KEEP_STALLS := 40         # the worst ones are kept, not the first 40
const TIMELINE_SECS := 15       # one memory row per this many seconds
const KEEP_TIMELINE := 80       # ~20 minutes of history, then it thins
const LONG_PHASE_MS := 10000    # tick_long says "still going" no faster than this

static var _t0 := 0
static var _last_beat := 0
static var _crumb := "starting up"
static var _crumb_at := 0
static var _crumb_lock := Mutex.new()

static var _peak_static := 0.0
static var _peak_static_at := ""
static var _peak_vram := 0.0
static var _peak_vram_at := ""
static var _sys_low := -1.0      # least system memory left, in MB
static var _first_static := -1.0

static var _stalls: Array = []   # [{ms, crumb, at}]
static var _timeline: Array = [] # [{sec, static_mb, vram_mb, sys_free_mb, crumb}]
static var _last_row := -TIMELINE_SECS

static var _long_last: Dictionary = {}   # crumb -> ticks of its last "still going"

# Set once by the dock so the report can pull numbers this file has no business
# holding a reference to. Both may be unset; the report says so rather than
# guessing.
static var _cache_probe: Callable = Callable()
static var _settings_probe: Callable = Callable()


static func set_cache_probe(c: Callable) -> void: _cache_probe = c
static func set_settings_probe(c: Callable) -> void: _settings_probe = c


# ---------------------------------------------------------------------------
# THE BREADCRUMB
#
# Called at the START of anything that can take a while. note_phase records what
# a phase COST once it is over, which is the wrong half of the information when
# the complaint is that it never got over.
#
# Locked because the reader's open runs on a WorkerThreadPool task while the
# heartbeat reads this from the main thread. A String assignment across threads
# is a refcount race, and the symptom would be a crash in the diagnostic code -
# which is a uniquely bad place to have one.
static func crumb(what: String) -> void:
	_crumb_lock.lock()
	# Only a CHANGE restarts the clock. These are called once per tile and per
	# mesh with the same label, and resetting on every call would make the age
	# permanently zero - which is the one number that makes a stall legible
	# ("4 minutes into the colour map" rather than "in the colour map").
	if what != _crumb:
		_crumb = what
		_crumb_at = Time.get_ticks_msec()
		_long_last.erase(what)
	_crumb_lock.unlock()


static func crumb_now() -> String:
	_crumb_lock.lock()
	var c := _crumb
	_crumb_lock.unlock()
	return c


static func crumb_age_ms() -> int:
	_crumb_lock.lock()
	var at := _crumb_at
	_crumb_lock.unlock()
	return Time.get_ticks_msec() - at if at > 0 else 0


# A "still going" line from INSIDE a long main-thread loop.
#
# The heartbeat cannot report a main-thread stall while it is happening - the
# main thread is what is stalled - so a loop that will hold it for minutes has
# to say so itself. Rate limited per label, so dropping this into a 65,000
# iteration loop costs one dictionary lookup and one integer compare per turn.
static func tick_long(what: String, done: int, total: int) -> void:
	var now := Time.get_ticks_msec()
	var last := int(_long_last.get(what, 0))
	if last == 0:
		_long_last[what] = now
		return
	if now - last < LONG_PHASE_MS:
		return
	_long_last[what] = now
	HighpolyLog.info("  still working: %s, %d of %d (%.0f%%), %s so far"
		% [what, done, total, 100.0 * float(done) / maxf(1.0, float(total)),
		   HighpolyLog.human_ms(crumb_age_ms())])
	# STRAIGHT TO DISK. Routine lines batch twenty at a time, and the whole
	# point of this one is the case where the next thing that happens is the
	# user killing a frozen editor. A line still sitting in a buffer is a line
	# that was never written.
	HighpolyLog.flush()


static func clear_long(what: String) -> void:
	_long_last.erase(what)


# ---------------------------------------------------------------------------
# THE SAMPLE, called from the panel's 0.5 s heartbeat.
static func sample() -> void:
	var now := Time.get_ticks_msec()
	if _t0 == 0:
		_t0 = now
		_last_beat = now
	# --- the stall detector -------------------------------------------------
	# Lateness IS the stall. Nothing else in the plugin can see a main-thread
	# freeze, because everything else in the plugin is on the main thread.
	var late := now - _last_beat
	_last_beat = now
	if late >= STALL_MS:
		_stalls.append({
			"ms": late,
			"crumb": crumb_now(),
			"at": Time.get_time_string_from_system(),
		})
		# Keep the WORST, not the first: a build that stutters fifty times and
		# then freezes for four minutes must not lose the four minutes.
		if _stalls.size() > KEEP_STALLS:
			_stalls.sort_custom(func(a, b): return int(a["ms"]) > int(b["ms"]))
			_stalls.resize(KEEP_STALLS)
		# Worth a line of its own the moment it happens: a user who sends the
		# log without pressing anything else still gets this.
		if late >= 5000:
			HighpolyLog.warn("the editor was frozen for %s during: %s"
				% [HighpolyLog.human_ms(late), crumb_now()])

	# --- memory -------------------------------------------------------------
	var st := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var vr := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	if _first_static < 0.0:
		_first_static = st
	if st > _peak_static:
		_peak_static = st
		_peak_static_at = crumb_now()
	if vr > _peak_vram:
		_peak_vram = vr
		_peak_vram_at = crumb_now()
	# "free", NOT "available". On Windows those are AvailPhys and AvailPageFile,
	# and the second is physical plus the page file: this machine reports 127 GB
	# installed and 240 GB "available", which as a RAM figure is nonsense and
	# would have shipped as one. Free physical memory is what runs out.
	var mi := OS.get_memory_info()
	var freephys := float(mi.get("free", 0)) / 1048576.0
	if freephys > 0.0 and (_sys_low < 0.0 or freephys < _sys_low):
		_sys_low = freephys

	# --- the other kind of long phase ---------------------------------------
	# tick_long covers work that reports per item. A phase called once - the
	# layer palette, the type database - reports nothing while it runs, and if
	# it is on a worker thread the editor stays responsive so no stall is
	# recorded either. Then the log simply goes quiet, which is the failure
	# mode this whole file exists to end.
	var age := crumb_age_ms()
	if age >= 30000:
		var c := crumb_now()
		if int(_long_last.get(c, 0)) < now - LONG_PHASE_MS * 3:
			_long_last[c] = now
			HighpolyLog.info("  still working: %s, %s so far"
				% [c, HighpolyLog.human_ms(age)])
			HighpolyLog.flush()

	# --- the timeline -------------------------------------------------------
	# A peak on its own cannot distinguish "it climbed once and stayed there"
	# from "it climbs every time I switch maps", and those are different bugs.
	var sec := (now - _t0) / 1000
	if sec - _last_row >= TIMELINE_SECS:
		_last_row = sec
		_timeline.append({"sec": sec, "static_mb": st, "vram_mb": vr,
			"sys_free_mb": freephys, "crumb": crumb_now()})
		# Thin by dropping every other OLD row, so a long session keeps its
		# shape instead of losing its beginning.
		if _timeline.size() > KEEP_TIMELINE:
			var kept: Array = []
			for i in range(_timeline.size()):
				if i >= _timeline.size() - KEEP_TIMELINE / 2 or i % 2 == 0:
					kept.append(_timeline[i])
			_timeline = kept


# ---------------------------------------------------------------------------
# THE MACHINE, for the log header. One line each, no interpretation.
static func machine() -> PackedStringArray:
	var out := PackedStringArray()
	var mi := OS.get_memory_info()
	var phys := float(mi.get("physical", 0)) / 1073741824.0
	# "free" is AvailPhys. "available" is AvailPageFile, which on this machine
	# reads 240 GB against 127 GB installed - a number that looks like RAM, is
	# not RAM, and would have been quoted back at users as though it were.
	var freephys := float(mi.get("free", 0)) / 1073741824.0
	out.append("cpu        %s (%d threads)"
		% [OS.get_processor_name(), OS.get_processor_count()])
	if phys > 0.0:
		# Stated as a pair on purpose. "Using 13 GB" is a crash on a 16 GB
		# machine and unremarkable on a 64 GB one, and the reports we get say
		# the former without saying which machine.
		out.append("ram        %.1f GB installed, %.1f GB free right now"
			% [phys, freephys])
	else:
		out.append("ram        not reported by this OS")
	# Headless has no driver, so both of these come back empty and the line
	# would read "gpu  / ". Say nothing rather than say that.
	var vend := RenderingServer.get_video_adapter_vendor()
	var api := RenderingServer.get_video_adapter_api_version()
	if vend != "" or api != "":
		out.append("gpu        %s %s" % [vend, api])
	return out


# ---------------------------------------------------------------------------
# THE REPORT, appended to a saved log.
static func report() -> String:
	var out := PackedStringArray()
	out.append("")
	out.append("-".repeat(60))
	out.append("MEMORY AND STALLS")
	if _t0 == 0:
		out.append("  Nothing sampled: the panel heartbeat never ran this session.")
		return "\n".join(out)
	out.append("  Session length %s."
		% HighpolyLog.human_ms(Time.get_ticks_msec() - _t0))
	out.append("")
	out.append("  MEMORY_STATIC is Godot's own accounting of what it allocated.")
	out.append("  It does not include the graphics driver, so Task Manager will")
	out.append("  always read higher than this. Windows also keeps freed pages")
	out.append("  rather than handing them back, so Task Manager can stay high")
	out.append("  after memory genuinely was released.")
	out.append("  %-22s %10.0f MB   while: %s"
		% ["peak, Godot heap", _peak_static, _peak_static_at])
	# A peak of zero means the monitor never reported, which is a different
	# statement from "it peaked at nothing while doing nothing" - and the
	# blank label the second one prints reads as a bug in the report.
	if _peak_vram > 0.0:
		out.append("  %-22s %10.0f MB   while: %s"
			% ["peak, video memory", _peak_vram, _peak_vram_at])
	else:
		out.append("  %-22s %s" % ["peak, video memory", "not reported"])
	out.append("  %-22s %10.0f MB"
		% ["at session start", maxf(_first_static, 0.0)])
	out.append("  %-22s %10.0f MB"
		% ["now", Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0])
	if _sys_low >= 0.0:
		var warn := ""
		if _sys_low < 1024.0:
			warn = "   <-- the machine ran out"
		elif _sys_low < 2048.0:
			warn = "   <-- close to the limit"
		out.append("  %-22s %10.0f MB%s"
			% ["lowest free RAM", _sys_low, warn])

	# --- our caches ---------------------------------------------------------
	# The point of the section: separating "the editor is using 13 GB" from
	# "WE are using 13 GB", which no report before this could do.
	out.append("")
	if _cache_probe.is_valid():
		var cs: Dictionary = _cache_probe.call()
		if cs.is_empty():
			out.append("  Our caches hold nothing: no map has been read this session.")
		else:
			out.append("  OF THAT, WHAT OUR OWN CACHES ARE HOLDING")
			out.append("  %-22s %10d   about %.0f MB"
				% ["textures", int(cs.get("textures", 0)),
				   float(cs.get("texture_mb_est", 0.0))])
			out.append("  %-22s %10d" % ["materials", int(cs.get("materials", 0))])
			out.append("  %-22s %10d   %d surfaces"
				% ["meshes", int(cs.get("meshes", 0)),
				   int(cs.get("mesh_surfaces", 0))])
			out.append("  %-22s %10d" % ["depot entries", int(cs.get("depot_entries", 0))])
			if not bool(cs.get("evicts", false)):
				out.append("  These do not evict. They are released when you switch")
				out.append("  maps, or when every layer is switched off.")
	else:
		# THIS ELSE BELONGS TO THE PROBE, and it had drifted onto the pool check
		# below - so a report with a full cache table ended with "cache figures
		# unavailable" directly underneath it, which is a straight
		# self-contradiction in the one document people send us when confused.
		out.append("  Cache figures unavailable: the dock did not register a probe.")
	# THE SHARED TEXTURE POOLS, which the line above knows nothing about.
	#
	# These are static and live in a different file, so every memory report we
	# have produced attributed only the reader's own caches and silently omitted
	# the biggest holder in the plugin. _pool keeps a CPU Image and _tex_pool a
	# GPU texture under the SAME key, so a texture that is in both is paid for
	# twice, and being static they survive a map switch.
	var ps := HighpolyBcTex.pool_stats()
	if int(ps.get("images", 0)) > 0 or int(ps.get("textures", 0)) > 0:
		out.append("")
		out.append("  THE SHARED TEXTURE POOLS (not counted above)")
		out.append("  %-22s %10d   about %.0f MB   <-- CPU side, droppable"
			% ["decoded images", int(ps.get("images", 0)),
			   float(ps.get("image_mb", 0.0))])
		out.append("  %-22s %10d   about %.0f MB"
			% ["uploaded textures", int(ps.get("textures", 0)),
			   float(ps.get("texture_mb_est", 0.0))])
		if int(ps.get("images", 0)) > 0:
			out.append("  A non-zero image count after a build has finished means")
			out.append("  the CPU copies were never dropped. They are only needed")
			out.append("  while uploading.")

	# --- stalls -------------------------------------------------------------
	out.append("")
	if _stalls.is_empty():
		out.append("  No main-thread freeze longer than %.1f s was seen."
			% (STALL_MS / 1000.0))
	else:
		var worst := _stalls.duplicate()
		worst.sort_custom(func(a, b): return int(a["ms"]) > int(b["ms"]))
		var total := 0
		for s in _stalls:
			total += int(s["ms"])
		out.append("  THE EDITOR STOPPED RESPONDING %d TIMES, %s IN TOTAL."
			% [_stalls.size(), HighpolyLog.human_ms(total)])
		out.append("  Measured as heartbeat lateness: a 0.5 s timer that fires")
		out.append("  30 s late means the main thread was blocked for 30 s. The")
		out.append("  phase named is the one that was running when it started.")
		out.append("  %-12s %-10s %s" % ["blocked for", "at", "during"])
		for s in worst.slice(0, mini(worst.size(), 12)):
			out.append("  %-12s %-10s %s"
				% [HighpolyLog.human_ms(int(s["ms"])), str(s["at"]),
				   str(s["crumb"])])

	# --- disk ---------------------------------------------------------------
	# A user took 15 minutes for a build measured at 85 s here. Nothing in the
	# log could say whether that was our code or their disk, and it is a single
	# division away from being answerable.
	var io := BF6Cas.io_report()
	if io.size() > 0:
		out.append("")
		for l in io:
			out.append(l)

	# --- what was switched on -----------------------------------------------
	# Every "it hangs when I do X" report needs this and not one of them has
	# ever carried it.
	if _settings_probe.is_valid():
		var ss: PackedStringArray = _settings_probe.call()
		if ss.size() > 0:
			out.append("")
			out.append("WHAT WAS SWITCHED ON WHEN THIS LOG WAS SAVED")
			for l in ss:
				out.append("  " + l)

	# --- the timeline -------------------------------------------------------
	if _timeline.size() > 2:
		out.append("")
		out.append("MEMORY OVER THE SESSION  (one row per %d s, thinned when long)"
			% TIMELINE_SECS)
		out.append("  %-9s %10s %10s %10s  %s"
			% ["at", "heap MB", "video MB", "sys free", "doing"])
		for r in _timeline:
			out.append("  %-9s %10.0f %10.0f %10.0f  %s"
				% [HighpolyLog.human_ms(int(r["sec"]) * 1000),
				   float(r["static_mb"]), float(r["vram_mb"]),
				   float(r["sys_free_mb"]), str(r["crumb"])])
	return "\n".join(out)
