"""Self-driving performance run in the REAL editor: one command, nobody at the keyboard.

    python perfrun.py                     the worst case: everything on except FX,
                                          the range slider at its maximum
    python perfrun.py --sdk-only          the baseline: dock loaded, every layer off
    python perfrun.py --map MP_Dumbo      a different map (default: MP_Aftermath)
    python perfrun.py --baseline          record this run as the number to beat
    python perfrun.py --history           what has happened so far
    python perfrun.py --dry-run           print the command and the session, launch nothing
    python perfrun.py --install-hook      wire the plugin up to run this (once, see below)

THIS IS THE EDITOR-SIDE COMPLEMENT TO bench.py, NOT A REPLACEMENT.

    ../../bf6-highpoly-pipeline/tools/bench.py measures the READER in a bare
    project with no addon in it, which is the only way to time the game-bytes to
    assets path without the editor in the way. It cannot see the dock, because
    there is no dock in that project.

    This measures the other half: the real editor, the real scene, the dock
    applied, the recorded flight path flown. What it reports is what a user
    feels. Where the two overlap they agree on conventions on purpose, so the
    numbers can sit in one story: the same history and baseline shape, the same
    cold/warm flag, the same compare-against-baseline behaviour, and the same
    3% noise floor before a change is called a change.

WHY IT HAS TO DRIVE ITSELF. Measuring the dock's overhead means running inside
the editor, so this cannot be a headless scene run. The plugin's EditorPlugin
already loads on editor start, so it checks BF6_PERFRUN and, when it is set,
waits for the scene, applies the configuration, flies the path, writes the json
and quits. This script sets that variable, watches the heartbeat, and reads the
result.

THE TWO HARD RULES, restated here because this is where they are enforced:

  1. DISTANCE CULLING STAYS OFF. The range slider goes to its maximum, the worst
     case, on purpose. The harness only ever moves that control upwards and
     asserts it afterwards; a run whose slider read back lower is aborted rather
     than reported.

  2. THE HEADLINE IS FRAMES UNDER 60 AND THE 1% LOW. A run averaging 90 fps that
     stalls to 12 has failed. The mean is printed last and in small type,
     because it is the statistic that hides exactly that.

SAFETY, NON-NEGOTIABLE. This closes only editors it launched and tracks by PID,
and refuses to start at all if a Godot is already running, because it cannot
tell that one from its own. It NEVER kills by image name. Killing by image name
has taken the user's own editor down before, and no measurement is worth that.

FOUR DETECTIONS, and what each of them means:

  HANG      no heartbeat for --hang-s. The plugin writes a heartbeat file every
            half second in every phase, so silence means the main thread is
            blocked. Killed by PID, and the last heartbeat says where it stopped.
  CRASH     the process exits without writing its report. The stderr tail and
            the last 50 log lines go into the artefact, so the cause is in the
            file rather than only on somebody's screen.
  STUTTER   reported twice, and the two are not the same claim. While MOVING,
            variance is partly the map changing. While STATIONARY it is not: the
            renderer is doing identical work, so any spread is work arriving
            from somewhere else. That number is the damning one and a mean over
            the whole flight hides it completely.
  LONG LOAD launch, scan, scene open, build and first drawn frame are timed as
            separate spans with separate budgets, and any of them blowing its
            budget ends the run early rather than burning ten minutes.

EVERYTHING PRINTED IS ALSO CAPTURED AND CLASSIFIED. Godot is launched with
--log-file, the plugin tails that file while it runs, and every line is stamped
with the phase and frame it happened in. Repeats are counted, because an error
thrown once is a bug and the same error thrown every frame is a bug AND a frame
cost - there is direct precedent for that being worth thousands of exceptions a
match in a sibling project.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                      # bf6-portal-highpoly-preview
NATIVE = os.path.join(REPO, "native")
RUNS = os.path.join(NATIVE, "perfrun")
HISTORY = os.path.join(NATIVE, "perfrun_history.json")
BASELINE = os.path.join(NATIVE, "perfrun_baseline.json")
PLUGIN_DIR = os.path.join(REPO, "addons", "highpoly_toggle")
TOGGLE = os.path.join(PLUGIN_DIR, "highpoly_toggle.gd")

PROJECT = os.environ.get("BF6_PROJECT", r"C:\PortalSDK\GodotProject")
GODOT = os.environ.get("GODOT_BIN", r"C:\PortalSDK\Godot_v4.6.3-stable_win64.exe")

# bench.py lives one repo across. Imported rather than copied where the concern
# is genuinely shared, so the two harnesses cannot drift apart on the things
# they agree about.
_PIPE = os.path.join(os.path.dirname(REPO), "bf6-highpoly-pipeline", "tools")
try:
    sys.path.insert(0, _PIPE)
    import bench as _bench            # noqa: E402
except Exception:                     # pragma: no cover - it is optional
    _bench = None

NOISE_PCT = 3.0        # bench.py's convention: under 3% is drift, not a result


# ---------------------------------------------------------------------------
# safety
# ---------------------------------------------------------------------------

def _ps(cmd):
    """Run a PowerShell one-liner and return its stdout, or ""."""
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                            "-Command", cmd],
                           capture_output=True, text=True, timeout=60)
        return r.stdout or ""
    except Exception:
        return ""


def godot_processes():
    """Every running Godot, as [(pid, exe, cmdline)].

    Enumerated rather than assumed. The whole safety story rests on being able
    to tell the user's editor from ours, and the only thing that can tell them
    apart is the PID.
    """
    out = _ps("Get-CimInstance Win32_Process | Where-Object { $_.Name -like "
              "'*odot*' -or $_.ExecutablePath -like '*odot*' } | ForEach-Object "
              "{ \"$($_.ProcessId)`t$($_.ExecutablePath)`t$($_.CommandLine)\" }")
    found = []
    for ln in out.splitlines():
        parts = ln.split("\t")
        if len(parts) >= 2 and parts[0].strip().isdigit():
            found.append((int(parts[0]), parts[1].strip(),
                          parts[2].strip() if len(parts) > 2 else ""))
    return found


def pid_exe(pid):
    out = _ps("(Get-CimInstance Win32_Process -Filter 'ProcessId=%d')"
              ".ExecutablePath" % pid)
    return out.strip()


def kill_ours(pid, why):
    """Kill ONE process tree, by PID, after checking it is still ours.

    NEVER by image name. taskkill /IM cannot tell our editor from the user's,
    and has taken the user's editor down before. The PID is re-resolved to an
    executable path first, because a PID can be recycled while we were waiting
    and the recycled one could be anything at all.
    """
    exe = pid_exe(pid)
    if not exe:
        print("  the process (pid %d) is already gone, nothing to kill" % pid)
        return False
    if os.path.normcase(os.path.abspath(exe)) != os.path.normcase(
            os.path.abspath(GODOT)):
        print("  REFUSING to kill pid %d: it is %s, not the editor we launched"
              % (pid, exe))
        return False
    print("  killing pid %d (%s)" % (pid, why))
    # /T so the whole tree goes: Godot leaves children, and a wedged parent
    # holding the project open makes every later run fail for a reason that has
    # nothing to do with the code. This is bench.py's kill_tree, PID-checked.
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


# ---------------------------------------------------------------------------
# the project, its userdata, and the recorded paths
# ---------------------------------------------------------------------------

def project_name(project):
    """config/name out of project.godot.

    Read rather than constructed: the name carries a trademark character, and a
    guessed path does not fail loudly, it simply does not exist. bench.py learnt
    this the same way.
    """
    cfg = os.path.join(project, "project.godot")
    if not os.path.isfile(cfg):
        return ""
    with open(cfg, encoding="utf-8", errors="replace") as f:
        for ln in f:
            m = re.match(r'\s*config/name\s*=\s*"(.*)"\s*$', ln)
            if m:
                return m.group(1)
    return ""


def userdata(project):
    n = project_name(project)
    if not n:
        return ""
    d = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata", n)
    return d if os.path.isdir(d) else ""


def find_flight(project, map_name):
    """The recorded path for this map, or "".

    KEYED BY BASE MAP, NOT BY SCENE. A flight recorded on
    MP_Aftermath_CapitalSupremacy is stored as bf6_flightpath_MP_Aftermath.json,
    so the lookup is a longest-prefix match rather than an exact one, and a run
    on a variant finds the path recorded on its base.
    """
    d = userdata(project)
    if not d:
        return ""
    best, best_len = "", -1
    for f in os.listdir(d):
        m = re.match(r"bf6_flightpath_(.+)\.json$", f)
        if not m:
            continue
        key = m.group(1)
        if map_name.lower().startswith(key.lower()) and len(key) > best_len:
            best, best_len = os.path.join(d, f), len(key)
    return best


def geom_epoch():
    """The geometry cache epoch the plugin is compiled with.

    Recorded on every run because it invalidates comparisons: bumping it makes
    every map cold on first open, so a warm number from before a bump does not
    mean what a warm number after it means.
    """
    src = os.path.join(PLUGIN_DIR, "highpoly_gamesource.gd")
    try:
        with open(src, encoding="utf-8", errors="replace") as f:
            for ln in f:
                m = re.match(r"const GEOM_EPOCH\s*:=\s*(\d+)", ln)
                if m:
                    return int(m.group(1))
    except Exception:
        pass
    return -1


# ---------------------------------------------------------------------------
# the hook
# ---------------------------------------------------------------------------

HOOK_MARK = "HighpolyFlightRun.requested()"
HOOK_ANCHOR = """	if HighpolyAutorun.requested():
		HighpolyAutorun.run(self, dock, mapctx)
		return
"""
HOOK_TEXT = """	# UNATTENDED PERFORMANCE RUN, when the environment asks for one
	# (tools/perfrun.py). Checked before the autorun hook below because the two
	# configure the dock differently and a stale BF6_AUTORUN must not shadow a
	# perf run that was explicitly asked for.
	if HighpolyFlightRun.requested():
		HighpolyFlightRun.run(self, dock, mapctx)
		return
"""


def hook_installed():
    try:
        with open(TOGGLE, encoding="utf-8", errors="replace") as f:
            return HOOK_MARK in f.read()
    except Exception:
        return False


def install_hook():
    with open(TOGGLE, encoding="utf-8") as f:
        src = f.read()
    if HOOK_MARK in src:
        print("the hook is already installed")
        return 0
    if HOOK_ANCHOR not in src:
        print("could not find the autorun hook in %s to sit beside." % TOGGLE)
        print("add these lines at the top of _startup() by hand:\n")
        print(HOOK_TEXT)
        return 1
    shutil.copy2(TOGGLE, TOGGLE + ".bak")
    with open(TOGGLE, "w", encoding="utf-8", newline="") as f:
        f.write(src.replace(HOOK_ANCHOR, HOOK_TEXT + HOOK_ANCHOR, 1))
    print("installed the hook in %s (previous copy kept as .bak)" % TOGGLE)
    return 0


# ---------------------------------------------------------------------------
# classifying what the editor printed
# ---------------------------------------------------------------------------

# ORDER MATTERS: the first match wins, and the specific categories are listed
# before the generic ones. A leaked instance is a leak whether or not the line
# also says ERROR.
CATEGORIES = [
    ("leak", re.compile(
        r"Leaked instance|instances leaked|ObjectDB instances|"
        r"resources still in use|Orphan StringName|did not call "
        r"instance_notify_deleted", re.I)),
    ("shader", re.compile(
        r"Shader compilation failed|SHADER ERROR|shader.{0,20}compil", re.I)),
    ("resource", re.compile(
        r"Failed loading resource|No loader found|Cannot open file|"
        r"Error while loading|resource file not found|Failed to load|"
        r"doesn't seem to exist|Can't open", re.I)),
    ("gdscript", re.compile(
        r"SCRIPT ERROR|GDScript backtrace|Nonexistent function|"
        r"Invalid call|Cannot call method|previously freed|"
        r"Invalid (get|set) index|Trying to (assign|call)|"
        r"res://[^\s]+\.gd:\d+", re.I)),
    # Bare "vulkan" and bare "RenderingDevice" used to be enough here, which
    # made the Vulkan DEVICE BANNER every editor prints on boot the top-ranked
    # rendering "diagnostic" of every run. A renderer name is not a finding, so
    # these now need an actual failure word next to them.
    ("rendering", re.compile(
        r"VK_ERROR|device lost|out of (video )?memory|"
        r"(RenderingDevice|vulkan|rendering_device|servers/rendering)"
        r"[^\n]{0,60}(error|fail|invalid|cannot|unable)", re.I)),
    ("error", re.compile(r"^(USER )?ERROR:")),
    ("warning", re.compile(r"^(USER )?WARNING:")),
]

# Categories that are findings in their own right rather than background noise.
DIAGNOSTIC = {"leak", "shader", "resource", "gdscript", "rendering", "error",
              "warning"}


def classify(text):
    for name, rx in CATEGORIES:
        if rx.search(text):
            return name
    return "output"


def digest_log_file(path):
    """Classify the log FILE, as a fallback for the in-process capture.

    THE IN-PROCESS TAILER CAN COME BACK EMPTY AND SAY NOTHING ABOUT IT. It
    opens the file Godot is itself writing, and on a failed open it returns
    quietly, so "lines_seen: 0" reads identically whether the run was clean or
    the capture never worked. The first real run hit exactly that: the report
    said 0 lines while the log held a SCRIPT ERROR and 13 warnings.

    This reads the finished file instead, so a run always gets an error census
    even when the live capture fails. What it CANNOT do is stamp a line with
    the phase and frame it happened in, because that context only exists while
    the run is happening - which is why the tailer exists and this does not
    replace it.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            raw = f.read().splitlines()
    except Exception:
        return []
    # Fold GDScript backtraces into the message above them: "at:" and the
    # numbered frames are continuations, not separate findings.
    msgs = []
    for ln in raw:
        s = ln.rstrip()
        if not s.strip():
            continue
        cont = (s.lstrip().startswith("at:")
                or re.match(r"^\s*\[\d+\]\s", s)
                or s.lstrip().startswith("GDScript backtrace"))
        if cont and msgs:
            msgs[-1][1].append(s.strip())
        else:
            msgs.append([s.strip(), []])
    # Group by signature with digits dropped, so five numbered copies of one
    # message count as one finding with n=5 rather than five findings.
    groups = {}
    for text, trail in msgs:
        sig = re.sub(r"\d+", "N", text)
        g = groups.get(sig)
        if g is None:
            groups[sig] = {"text": text, "at": trail, "n": 1}
        else:
            g["n"] += 1
    return list(groups.values())


def digest_log(report, frames, log_path=None):
    """Rank what was printed, and say which of it is a per-frame cost.

    AN ERROR THROWN ONCE IS A BUG. THE SAME ERROR THROWN EVERY FRAME IS A BUG
    AND A FRAME COST, and the second is invisible in any report that lists
    distinct messages instead of counting them.
    """
    log = report.get("log", {}) if isinstance(report, dict) else {}
    source = "in-process (stamped with phase and frame)"
    entries = log.get("ranked", [])
    if not entries and log_path:
        # The live capture produced nothing. Fall back to the file rather than
        # reporting a clean run that was never actually inspected.
        entries = digest_log_file(log_path)
        if entries:
            source = ("the log FILE after exit - the in-process capture "
                      "returned nothing, so these lines carry no phase or "
                      "frame")
    log = dict(log)
    log["ranked"] = entries
    ranked = []
    counts = {}
    for e in log.get("ranked", []):
        text = str(e.get("text", ""))
        trail = e.get("at", [])
        if isinstance(trail, list):
            joined = text + " " + " ".join(str(x) for x in trail)
        else:
            joined = text + " " + str(trail)
        cat = classify(joined)
        n = int(e.get("n", 0))
        counts[cat] = counts.get(cat, 0) + n
        ranked.append({
            "category": cat,
            "n": n,
            "per_frame": round(n / float(frames), 3) if frames else None,
            "text": text,
            "at": trail,
            "first_phase": e.get("first_phase", ""),
            "first_frame": e.get("first_frame", -1),
            "last_frame": e.get("last_frame", -1),
            "phases": e.get("phases", {}),
        })
    ranked.sort(key=lambda r: -r["n"])
    diag = [r for r in ranked if r["category"] in DIAGNOSTIC]
    hot = [r for r in diag if frames and r["n"] > frames]
    return {
        "lines_seen": log.get("lines_seen", 0) or sum(e["n"] for e in entries),
        "distinct": log.get("distinct", 0) or len(entries),
        "source": source,
        "by_category": counts,
        "ranked": ranked[:80],
        "diagnostics": diag[:40],
        # More than one per frame. Flagged separately because it is the shape
        # that costs real time rather than merely being wrong.
        "more_than_once_per_frame": hot,
        "head": log.get("head", []),
        "tail": log.get("tail", []),
    }


def tail_file(path, n=50):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [ln.rstrip() for ln in f.readlines()[-n:]]
    except Exception:
        return []


# ---------------------------------------------------------------------------
# history and comparison, following bench.py's conventions
# ---------------------------------------------------------------------------

def load(path):
    if _bench is not None:
        return _bench.load(path)
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return None
    return None


# Which way is better. Without this a table happily prints "12% SLOWER" about a
# 1% low that went up, which is the one number in the report that must never be
# read backwards.
HIGHER_BETTER = {"fps_1pct_low", "fps_mean", "frames"}
METRICS = ["frames", "frames_under_60", "pct_under_60", "fps_1pct_low",
           "median_ms", "p99_ms", "worst_ms", "still_spread_ms",
           "still_spread_worst_ms", "stationary_jitter_ms", "stationary_spikes",
           "moving_jitter_ms", "draws_mean", "build_s", "errors_total"]


def compare(now, ref, label):
    if not ref:
        print("\n(no %s to compare against yet)" % label)
        return
    if ref.get("geom_epoch", -1) != now.get("geom_epoch", -1):
        print("\nNOTE: the %s was recorded at geometry epoch %s and this run is "
              "at %s. Bumping the epoch makes every map cold on first open, so "
              "load spans are not comparable across it."
              % (label, ref.get("geom_epoch"), now.get("geom_epoch")))
    if bool(ref.get("cold")) != bool(now.get("cold")):
        print("\nNOTE: this run was %s and the %s was %s, so the load spans "
              "are not comparable."
              % ("cold" if now.get("cold") else "warm", label,
                 "cold" if ref.get("cold") else "warm"))
    print("\n%-24s %12s %12s %10s" % ("metric", "now", label, "delta"))
    print("-" * 62)
    for k in METRICS:
        cur, prev = now.get(k), ref.get(k)
        if cur is None or prev is None:
            continue
        if not prev:
            print("%-24s %12.2f %12.2f %10s" % (k, cur, prev, "-"))
            continue
        pct = 100.0 * (cur - prev) / abs(prev)
        better = pct > 0 if k in HIGHER_BETTER else pct < 0
        mark = ""
        if abs(pct) >= NOISE_PCT:
            mark = "BETTER" if better else "WORSE"
        print("%-24s %12.2f %12.2f %9.1f%% %s" % (k, cur, prev, pct, mark))


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------

def build_session(a, run_dir):
    flight = a.flight or find_flight(a.project, a.map)
    session = {
        "map": a.map,
        "scene": a.scene,
        "tag": a.tag,
        "mode": a.mode,
        "flight": flight,
        "out": os.path.join(run_dir, "report.json"),
        "heartbeat": os.path.join(run_dir, "heartbeat.json"),
        "log": os.path.join(run_dir, "godot.log"),
        "settle_frames": a.settle_frames,
        "hold_ms": a.hold_ms,
        "max_scan_s": a.max_scan_s,
        "max_open_s": a.max_open_s,
        "max_build_s": a.max_build_s,
        "stall_s": a.stall_s,
        # RULE 1. Written into the session so it is visible in the artefact, and
        # asserted on the other side so a run cannot quietly disagree with it.
        "min_radius": 1.0e8,
    }
    if a.sdk_only:
        # THE CLOSEST BASELINE THIS CAN SELF-DRIVE. A truly plugin-disabled
        # baseline cannot drive itself, because the thing that would drive it is
        # the plugin. So the baseline is the plugin LOADED with every layer off,
        # which is the more useful comparison anyway: the difference between it
        # and a full run is what the overlay costs, dock included.
        session.update({"mode": 0, "map_context": False, "objects": False,
                        "backdrop": False, "water": False, "lighting": False,
                        "gi": False, "shadows": False, "map_lights": False,
                        "fx": False, "expect_build": False, "min_draws": 1})
    else:
        session["fx"] = bool(a.fx)
        if a.no_shadows:
            session["shadows"] = False
    if a.no_panel_video:
        session["panel_video"] = False
    return session


def go_cold(project, yes):
    """Clear the caches so the next run measures a FIRST open.

    GUARDED HARD, and warm is the default here where bench.py can afford cold to
    be. bench.py clears a throwaway project it made itself; this one runs
    against the REAL project, where the same directories hold hours of reading
    from the game. Deleting them to make a measurement tidier is not a trade
    worth making silently.
    """
    d = userdata(project)
    if not d:
        print("could not resolve the project's user folder, so nothing was cleared")
        return False
    targets = [os.path.join(d, s) for s in
               ("mapcontext", "bf6cache", "fxsheets", "bf6_geom")]
    targets = [t for t in targets if os.path.isdir(t)]
    print("a cold run deletes, from %s:" % d)
    for t in targets:
        print("   %s" % os.path.basename(t))
    if not yes:
        print("that is hours of reading from the game. Pass --yes-delete-caches "
              "as well if that is really what you want.")
        return False
    for t in targets:
        shutil.rmtree(t, ignore_errors=True)
    return True


def monitor(proc, session, a, t_launch):
    """Watch the run. Return (outcome, detail).

    Outcome is one of: done, hang, crash, timeout.
    """
    hb_path = session["heartbeat"]
    last_hb, last_change = None, time.time()
    last_phase, phase_started = None, time.time()
    phase_wall = {}
    first_beat = None
    printed = set()
    while True:
        code = proc.poll()
        now = time.time()
        hb = None
        try:
            if os.path.isfile(hb_path):
                with open(hb_path, encoding="utf-8") as f:
                    hb = json.load(f)
        except Exception:
            hb = last_hb          # a half written heartbeat is not a hang
        if hb != last_hb and hb is not None:
            last_hb, last_change = hb, now
            if first_beat is None:
                first_beat = now - t_launch
            ph = hb.get("phase")
            if ph != last_phase:
                if last_phase is not None:
                    phase_wall[last_phase] = round(now - phase_started, 1)
                last_phase, phase_started = ph, now
            key = (ph, hb.get("sample", -1) // 100)
            if key not in printed:
                printed.add(key)
                print("  %6.1fs  %-10s frame %-7d sample %s/%s"
                      % (now - t_launch, ph, hb.get("frame", 0),
                         hb.get("sample", -1), hb.get("of", 0)))
        if code is not None:
            if last_phase is not None:
                phase_wall[last_phase] = round(now - phase_started, 1)
            got_report = os.path.isfile(session["out"])
            return (("done" if got_report else "crash"),
                    {"exit_code": code, "last_heartbeat": last_hb,
                     "phase_wall_s": phase_wall,
                     "first_heartbeat_s": first_beat})

        # HANG. The plugin writes a heartbeat every half second in every phase,
        # so silence is the main thread being blocked and nothing else. Until
        # the first heartbeat arrives the budget is the load budget instead,
        # because the editor genuinely takes a while to boot and scan.
        quiet = now - last_change
        if first_beat is None:
            if now - t_launch > a.first_beat_s:
                return "hang", {"where": "before the plugin ever reported in",
                                "quiet_s": round(now - t_launch, 1),
                                "last_heartbeat": None,
                                "phase_wall_s": phase_wall}
        elif quiet > a.hang_s:
            return "hang", {"where": (last_hb or {}).get("phase", "?"),
                            "quiet_s": round(quiet, 1),
                            "last_heartbeat": last_hb,
                            "phase_wall_s": phase_wall}
        # LONG LOAD, aborted early. A configuration that cannot get as far as
        # flying should cost a minute, not the ten a full run takes.
        if (last_phase in (None, "boot", "scan", "open", "dock_sync")
                and now - t_launch > a.max_load_s):
            return "timeout", {"where": last_phase or "boot",
                               "why": "still loading after %.0f s" % (now - t_launch),
                               "last_heartbeat": last_hb,
                               "phase_wall_s": phase_wall}
        if now - t_launch > a.timeout:
            return "timeout", {"where": last_phase or "?",
                               "why": "the whole run passed %.0f s" % a.timeout,
                               "last_heartbeat": last_hb,
                               "phase_wall_s": phase_wall}
        time.sleep(0.5)


def summarise(report, digest, outcome, detail, wall, a, session):
    """One flat record: what goes in the history, and what gets printed."""
    fl = report or {}
    st = (fl.get("stutter") or {})
    stat = st.get("stationary") or {}
    mov = st.get("moving") or {}
    intra = st.get("within_one_sample") or {}
    spans = fl.get("spans_ms") or {}
    rec = {
        "when": time.strftime("%Y-%m-%d %H:%M:%S"),
        "map": a.map,
        "tag": a.tag,
        "note": "baseline" if a.baseline else ("sdk-only" if a.sdk_only else ""),
        "cold": bool(a.cold),
        "geom_epoch": geom_epoch(),
        "outcome": outcome,
        "valid": bool(fl.get("valid")) and outcome == "done",
        "wall_s": round(wall, 1),
        "fx": bool(a.fx) and not a.sdk_only,
        "range_slider": (fl.get("config") or {}).get("range_value", -1),
        "radius": (fl.get("config") or {}).get("radius", -1),
        # loads, as distinct spans
        "boot_s": round(fl.get("boot_ms", 0) / 1000.0, 1),
        "scan_s": round(spans.get("scan", 0) / 1000.0, 1),
        "open_s": round(spans.get("open", 0) / 1000.0, 1),
        "build_s": round(fl.get("build_ms", 0) / 1000.0, 1),
        "first_drawn_s": round(fl.get("first_drawn_ms", 0) / 1000.0, 1),
        # the headline
        "frames": fl.get("frames", 0),
        "frames_under_60": fl.get("frames_under_60", 0),
        "pct_under_60": fl.get("pct_under_60", 0.0),
        "fps_1pct_low": fl.get("fps_1pct_low", 0.0),
        # stutter, split
        "stationary_frames": stat.get("frames", 0),
        "stationary_jitter_ms": stat.get("jitter_ms", 0.0),
        "stationary_spikes": stat.get("spikes", 0),
        "moving_jitter_ms": mov.get("jitter_ms", 0.0),
        "moving_spikes": mov.get("spikes", 0),
        # THE REAL STATIONARY NUMBER on most recordings: the spread of frame
        # times inside a single held sample, where the camera provably did not
        # move at all. Tracked in the history because driving it to zero is the
        # whole point of looking at stationary variance.
        "still_spread_ms": intra.get("median_spread_ms", 0.0),
        "still_spread_worst_ms": (intra.get("worst") or {}).get("spread_ms", 0.0),
        "still_samples": intra.get("samples", 0),
        # the rest
        "median_ms": fl.get("median_ms", 0.0),
        "p99_ms": fl.get("p99_ms", 0.0),
        "worst_ms": fl.get("worst_ms", 0.0),
        "fps_mean": fl.get("fps_mean", 0.0),
        "draws_mean": fl.get("draws_mean", 0),
        "errors_total": sum(v for k, v in
                            (digest.get("by_category") or {}).items()
                            if k in DIAGNOSTIC),
        "leaks": (digest.get("by_category") or {}).get("leak", 0),
        "session": session,
        "detail": detail,
    }
    return rec


def report_run(rec, report, digest, a):
    fl = report or {}
    print("\n" + "=" * 66)
    print("%s  %s  tag=%s  %s" % (rec["map"], "COLD" if rec["cold"] else "warm",
                                  rec["tag"], rec["outcome"].upper()))
    print("=" * 66)

    print("\nLOADS (each budgeted on its own, so a slow one names itself)")
    print("  launch to plugin ready   %8.1f s" % rec["boot_s"])
    print("  import scan              %8.1f s" % rec["scan_s"])
    print("  scene open               %8.1f s" % rec["open_s"])
    print("  build                    %8.1f s  (%s of %s props)"
          % (rec["build_s"], fl.get("build_done", "?"), fl.get("build_total", "?")))
    print("  to the first drawn map   %8.1f s  (from launch)" % rec["first_drawn_s"])

    cfg = fl.get("config") or {}
    print("\nCONFIGURATION (rule 1: the range slider is at its maximum)")
    print("  range slider %s   map context radius %s"
          % (cfg.get("range_value", "?"), cfg.get("radius", "?")))
    panel = cfg.get("panel") or {}
    if panel:
        print("  " + "  ".join("%s=%s" % (k, v) for k, v in panel.items()
                               if k not in ("scene", "map")))
    if cfg.get("layers_wrong"):
        print("  LAYERS DID NOT HOLD: " + "; ".join(cfg["layers_wrong"]))

    if not rec["valid"]:
        print("\nTHIS RUN PRODUCED NO USABLE FRAME NUMBERS.")
        if fl.get("aborted"):
            ab = fl["aborted"]
            print("  aborted in %s after %.1f s: %s"
                  % (ab.get("phase"), ab.get("after_s", 0), ab.get("why")))
        if fl.get("error"):
            print("  %s" % fl["error"])
        if rec["detail"].get("where"):
            print("  stopped at: %s" % rec["detail"]["where"])
    else:
        print("\nTHE HEADLINE (a run that averages 90 and stalls to 12 has failed)")
        print("  frames under 60 fps      %8d of %d  (%.2f%%)"
              % (rec["frames_under_60"], rec["frames"], rec["pct_under_60"]))
        print("  1%% low                   %8.1f fps" % rec["fps_1pct_low"])
        print("  worst frame              %8.2f ms  at sample %s %s"
              % (rec["worst_ms"], fl.get("worst_at_sample", "?"),
                 fl.get("worst_at_pos", "")))
        print("\nSTUTTER, split by whether the camera was moving")
        print("  %-10s %7s %10s %10s %8s %8s"
              % ("", "frames", "median ms", "jitter ms", "spikes", "max ms"))
        for nm, d in (("stationary", (fl.get("stutter") or {}).get("stationary", {})),
                      ("moving", (fl.get("stutter") or {}).get("moving", {}))):
            print("  %-10s %7s %10s %10s %8s %8s"
                  % (nm, d.get("frames", 0), d.get("median_ms", "-"),
                     d.get("jitter_ms", "-"), d.get("spikes", 0),
                     d.get("max_ms", "-")))
        intra = (fl.get("stutter") or {}).get("within_one_sample", {})
        if intra.get("samples"):
            w = intra.get("worst", {})
            print("  spread while the camera was provably still: median %s ms, "
                  "worst %s ms at sample %s"
                  % (intra.get("median_spread_ms"), w.get("spread_ms"),
                     w.get("sample")))
        elif intra.get("note"):
            print("  %s" % intra["note"])
        # THE STATIONARY ROW IS OFTEN NEARLY EMPTY, and that is a property of
        # the recording rather than of the run. The recorder drops samples the
        # camera did not move between, so a minute of standing still is stored
        # as ONE sample: on the Aftermath path only 2 of 950 samples have a
        # near-identical neighbour. The line above is then the real stationary
        # measurement, since every frame inside one held sample was drawn from
        # exactly the same camera.
        if rec["stationary_frames"] * 20 < rec["frames"]:
            print("  (few consecutive samples repeat a position, so read the "
                  "spread line above as the stationary result: the recorder "
                  "collapses a pause into a single sample)")
        print("\n  (for reference only, never the headline: mean %.1f fps, "
              "median %.2f ms, p99 %.2f ms)"
              % (rec["fps_mean"], rec["median_ms"], rec["p99_ms"]))
        print("  draws %d mean, %d peak; shadow draws %d mean"
              % (rec["draws_mean"], fl.get("draws_peak", 0),
                 fl.get("shadow_draws_mean", 0)))

    cats = digest.get("by_category") or {}
    print("\nWHAT THE EDITOR PRINTED  (%d lines, %d distinct)"
          % (digest.get("lines_seen", 0), digest.get("distinct", 0)))
    if cats:
        print("  " + "  ".join("%s=%d" % (k, v) for k, v in
                               sorted(cats.items(), key=lambda kv: -kv[1])))
    hot = digest.get("more_than_once_per_frame") or []
    if hot:
        print("\n  FIRING MORE THAN ONCE PER FRAME. This is a frame cost, not "
              "only a bug:")
        for r in hot[:5]:
            print("   %8d  (%.1f per frame)  [%s, first in %s]  %s"
                  % (r["n"], r["per_frame"], r["category"], r["first_phase"],
                     r["text"][:90]))
    diag = digest.get("diagnostics") or []
    if diag:
        print("\n  ranked by how often it happened:")
        for r in diag[:12]:
            print("   %8d  [%-9s first in %-9s frame %s]  %s"
                  % (r["n"], r["category"], r["first_phase"], r["first_frame"],
                     r["text"][:80]))
            for line in (r["at"] or [])[:2]:
                if "res://" in str(line):
                    print("            %s" % str(line)[:88])
    if cats.get("leak"):
        print("\n  LEAKS ARE BOTH A CORRECTNESS BUG AND A GROWING PER FRAME "
              "COST. %d leak line(s) above." % cats["leak"])
    eng = fl.get("engine") or {}
    if eng:
        print("\n  at the end: %s orphan nodes, %s resources, %.0f MB vram"
              % (eng.get("orphan_nodes"), eng.get("resources"),
                 eng.get("vram_mb", 0)))


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", default="MP_Aftermath")
    ap.add_argument("--scene", default="",
                    help="an explicit res:// scene, when the map has variants "
                         "and the wrong one would be found by name")
    ap.add_argument("--tag", default="",
                    help="names the run and its files (default: worstcase, or "
                         "sdkonly with --sdk-only)")
    ap.add_argument("--mode", type=int, default=2,
                    help="detail mode id: 0 SDK, 3 light, 1 grey, 2 textured. "
                         "2 is the full one; the ids are historical, not ordered")
    ap.add_argument("--fx", action="store_true",
                    help="include the FX layer. OFF by default because the 60 "
                         "fps target is stated for everything EXCEPT FX")
    ap.add_argument("--sdk-only", action="store_true",
                    help="every layer off: the closest baseline a self-driving "
                         "run can produce (see the note in build_session)")
    # NOT a way to make a number look better - rule 1 still stands and culling
    # stays off. This exists to ATTRIBUTE cost: the census says the biggest
    # layer is 73% shadow passes, but the census is structural and counts every
    # caster whether or not shadow-distance culling actually renders it (43,075
    # estimated against 18,766 measured). Running the identical worst case with
    # and without shadows turns that upper bound into a measured share.
    # The panel's looping backdrop video decodes 24 Theora frames a second on
    # the main thread for as long as the panel is open, and keyframes cost far
    # more than the frames between them. The frame profiler cannot see any of
    # it, because the decode is engine C++ rather than GDScript we instrumented.
    ap.add_argument("--no-panel-video", action="store_true",
                    help="pause the panel's backdrop video for the run, to "
                         "measure what it costs. Diagnostic: a result from "
                         "this is not a target result")
    ap.add_argument("--no-shadows", action="store_true",
                    help="worst case but with sun shadows off, to measure what "
                         "the shadow passes actually cost. Diagnostic only: a "
                         "result from this is never a target result")
    ap.add_argument("--flight", default="",
                    help="a recorded path (default: the one for this map)")
    ap.add_argument("--project", default=PROJECT)
    ap.add_argument("--godot", default=GODOT)
    ap.add_argument("--resolution", default="1920x1080",
                    help="fixed so runs are comparable: the frame rate depends "
                         "on how big the viewport is")
    ap.add_argument("--settle-frames", type=int, default=30)
    ap.add_argument("--hold-ms", type=int, default=50,
                    help="how long each recorded sample is held. 50 ms is the "
                         "rate it was recorded at; changing it changes the "
                         "camera SPEED and with it anything time based")
    ap.add_argument("--hang-s", type=float, default=90.0,
                    help="no heartbeat for this long is a hang")
    ap.add_argument("--first-beat-s", type=float, default=240.0,
                    help="the editor gets this long to boot and report in once")
    ap.add_argument("--max-load-s", type=float, default=600.0,
                    help="abort if it is still loading after this")
    ap.add_argument("--timeout", type=float, default=2400.0)
    ap.add_argument("--max-scan-s", type=int, default=300)
    ap.add_argument("--max-open-s", type=int, default=180)
    ap.add_argument("--max-build-s", type=int, default=900)
    ap.add_argument("--stall-s", type=int, default=60)
    ap.add_argument("--max-under-60", type=float, default=1.0,
                    help="the perf gate: more than this percentage of frames "
                         "under 60 fps fails the run")
    ap.add_argument("--cold", action="store_true",
                    help="clear the plugin's caches first (see --yes-delete-caches)")
    ap.add_argument("--yes-delete-caches", action="store_true")
    ap.add_argument("--baseline", action="store_true",
                    help="record this run as the number to beat")
    ap.add_argument("--history", action="store_true")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the command and the session and launch nothing")
    ap.add_argument("--install-hook", action="store_true",
                    help="add the three lines to highpoly_toggle.gd that let "
                         "the plugin start a run when BF6_PERFRUN is set")
    a = ap.parse_args()
    if not a.tag:
        a.tag = "sdkonly" if a.sdk_only else ("worstcase_fx" if a.fx else "worstcase")

    if a.install_hook:
        return install_hook()

    hist = load(HISTORY) or {"runs": []}
    if a.history:
        if not hist["runs"]:
            print("no runs recorded yet")
            return 0
        print("%-20s %-14s %-11s %6s %7s %8s %8s  %s"
              % ("when", "map", "tag", "cold", "frames", "under60", "1% low", "note"))
        for h in hist["runs"][-25:]:
            print("%-20s %-14s %-11s %6s %7s %7.2f%% %8.1f  %s"
                  % (h.get("when", ""), h.get("map", ""), h.get("tag", ""),
                     "yes" if h.get("cold") else "no", h.get("frames", 0),
                     h.get("pct_under_60", 0.0), h.get("fps_1pct_low", 0.0),
                     h.get("note", "") or h.get("outcome", "")))
        return 0

    stamp = time.strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(RUNS, "%s-%s" % (a.tag, stamp))
    session = build_session(a, run_dir)

    if a.dry_run:
        print("would run:")
        print("  %s --editor --path %s --resolution %s --log-file %s"
              % (a.godot, a.project, a.resolution, session["log"]))
        print("  with BF6_PERFRUN=%s" % os.path.join(run_dir, "session.json"))
        print("\nsession:\n%s" % json.dumps(session, indent=1))
        print("\nhook installed in highpoly_toggle.gd: %s" % hook_installed())
        print("flight path: %s" % (session["flight"] or "NOT FOUND"))
        print("geometry epoch: %d" % geom_epoch())
        return 0

    # ---- refuse rather than risk the user's editor -----------------------
    running = godot_processes()
    if running:
        print("A GODOT IS ALREADY RUNNING, so this will not start.")
        print("This harness closes only editors it launched and tracks by PID, "
              "and it cannot tell an editor it did not launch from one it did.")
        for pid, exe, cmd in running:
            print("   pid %-7d %s" % (pid, exe or "(path unavailable)"))
        print("Close them (or let them finish) and run this again.")
        return 2

    if not os.path.isfile(a.godot):
        print("no Godot at %s" % a.godot)
        return 2
    if not os.path.isfile(os.path.join(a.project, "project.godot")):
        print("no project at %s" % a.project)
        return 2
    if not hook_installed():
        print("the plugin has no perfrun hook, so setting BF6_PERFRUN would do "
              "nothing and the editor would just sit there.")
        print("run:  python perfrun.py --install-hook")
        return 2
    if not session["flight"]:
        print("no recorded flight path for %s under %s"
              % (a.map, userdata(a.project) or "(user folder not found)"))
        print("record one from the dock first, then run this again.")
        return 2

    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "session.json"), "w", encoding="utf-8") as f:
        json.dump(session, f, indent=1)

    if a.cold and not go_cold(a.project, a.yes_delete_caches):
        return 2

    env = dict(os.environ)
    env["BF6_PERFRUN"] = os.path.join(run_dir, "session.json")
    # EXPLICITLY REMOVED. The other unattended harness lives on BF6_AUTORUN and
    # a stale one in the environment would run a different session against the
    # same editor.
    env.pop("BF6_AUTORUN", None)
    args = [a.godot, "--editor", "--path", a.project,
            "--resolution", a.resolution,
            # --log-file rather than the project's own logging setting: it needs
            # no change to the user's project, it gives this run a log of its
            # own, and the plugin tails exactly this file.
            "--log-file", session["log"]]
    print("launching %s" % " ".join(args))
    t_launch = time.time()
    with open(os.path.join(run_dir, "stdout.txt"), "wb") as out, \
            open(os.path.join(run_dir, "stderr.txt"), "wb") as err:
        proc = subprocess.Popen(args, stdout=out, stderr=err, env=env)
        print("  pid %d, and this is the ONLY process this run will ever kill"
              % proc.pid)
        outcome, detail = monitor(proc, session, a, t_launch)
        if outcome in ("hang", "timeout"):
            print("\n%s: %s" % (outcome.upper(), detail.get("why")
                                or "no progress for %.0f s" % detail.get("quiet_s", 0)))
            print("  it stopped in phase: %s" % detail.get("where"))
            if detail.get("last_heartbeat"):
                print("  last heartbeat: %s" % json.dumps(detail["last_heartbeat"]))
            kill_ours(proc.pid, outcome)
            try:
                proc.wait(timeout=20)
            except Exception:
                pass
    wall = time.time() - t_launch

    report = load(session["out"])
    if outcome == "done" and report is None:
        outcome = "crash"
    if outcome == "crash":
        print("\nCRASH: the editor exited (code %s) without writing a report."
              % detail.get("exit_code"))
    digest = digest_log(report, (report or {}).get("frames", 0),
                        session.get("log"))
    # THE LAST FIFTY LINES GO IN THE ARTEFACT whatever happened, because on a
    # crash they are the only account of it, and a cause that exists only on
    # somebody's screen has to be reproduced to be read twice.
    digest["log_file_tail"] = tail_file(session["log"], 50)
    digest["stderr_tail"] = tail_file(os.path.join(run_dir, "stderr.txt"), 50)

    rec = summarise(report, digest, outcome, detail, wall, a, session)
    with open(os.path.join(run_dir, "perfrun.json"), "w", encoding="utf-8") as f:
        json.dump({"run": rec, "log": digest, "report": report}, f, indent=1)

    report_run(rec, report, digest, a)
    if outcome != "done":
        print("\n  the last of the log:")
        for ln in digest["log_file_tail"][-15:]:
            print("   | %s" % ln)

    base = load(BASELINE)
    if a.baseline:
        with open(BASELINE, "w", encoding="utf-8") as f:
            json.dump(rec, f, indent=1)
        print("\nrecorded as the baseline")
    elif base:
        compare(rec, base, "baseline")
    prev = None
    for h in reversed(hist["runs"]):
        if h.get("tag") == rec["tag"] and h.get("map") == rec["map"] and h.get("valid"):
            prev = h
            break
    if prev:
        compare(rec, prev, "last run")

    hist["runs"].append(rec)
    hist["runs"] = hist["runs"][-200:]
    with open(HISTORY, "w", encoding="utf-8") as f:
        json.dump(hist, f, indent=1)
    print("\nwrote %s" % os.path.join(run_dir, "perfrun.json"))
    print("wall %.1f s" % wall)

    # THREE OUTCOMES, KEPT APART. A harness that failed and a target that was
    # missed are different problems and an iteration loop needs to tell them
    # apart without reading the text.
    if outcome != "done" or not rec["valid"]:
        return 2
    if rec["pct_under_60"] > a.max_under_60 or rec["fps_1pct_low"] < 60.0:
        print("\nTARGET MISSED: %.2f%% of frames under 60 fps and a 1%% low of "
              "%.1f fps. The target is a steady 60 or better with everything on "
              "except FX." % (rec["pct_under_60"], rec["fps_1pct_low"]))
        return 3
    print("\nTARGET MET: %.2f%% under 60, 1%% low %.1f fps"
          % (rec["pct_under_60"], rec["fps_1pct_low"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
