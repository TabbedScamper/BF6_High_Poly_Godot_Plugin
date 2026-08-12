#!/usr/bin/env python
"""What a cold build WAITS on, as opposed to what it spends.

THE MISTAKE THIS EXISTS TO PREVENT. The phase table sorts by duration and its
top line for a cold terrain build is "catalogue mount, 85 s". Optimising that
buys nothing: the journal timestamps show it running t+27.8 s to t+112.9 s, on
a worker, underneath everything else, and the only readers of catalogue_ready
are a diagnostics report and the near-camera sharpening gate. Neither blocks
the build. The giveaway is arithmetic - terrain's phases sum to ~185 s inside a
122 s build, so the biggest number cannot be the longest wait.

THE METRIC IS EXCLUSIVE TIME: how long a phase was the ONLY thing running.
That is what disappears from the wall clock if the phase becomes free. A phase
with 25 s of duration but 2 s exclusive is 2 s of opportunity, not 25.

Two kinds of row are held out of that calculation:
  * WRAPPERS - a phase whose children account for most of its own duration
    ("terrain surface" is the ground sub-phases added up). Counting it would
    mask every child as "shared".
  * Everything is still shown, so a wrapper being large is visible; it is just
    not credited with exclusive time of its own.

GAPS are wall time when NO phase was recording. That is unmeasured work, and
it is the one category that cannot be optimised until it is instrumented.

Usage:
    python tools/critpath.py                    # newest run with a journal
    python tools/critpath.py <run_dir>
    python tools/critpath.py --all              # newest run of every button
"""

import argparse
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
PERFRUN = os.path.join(os.path.dirname(HERE), "native", "perfrun")

ROW = re.compile(r"^\s*(\d+)\s+(\w+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"
                 r"(\d+)\s+(.*)$")
# save() writes the whole report twice - time order, then "slowest first". Only
# the first copy is a timeline; the second would double every interval.
STOP = "-- slowest first --"


def parse(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if STOP in line:
                break
            m = ROW.match(line.rstrip("\n"))
            if not m or m.group(2) != "phase":
                continue
            end, dur = int(m.group(1)), int(m.group(3))
            out.append([max(0, end - dur), end, dur, m.group(9).strip()])
    out.sort()
    return out


def wrappers(rows):
    """Indices of rows whose children explain most of their own duration."""
    out = set()
    for i, (s, e, d, _l) in enumerate(rows):
        if d < 1000:
            continue
        inner = 0
        for j, (s2, e2, d2, _l2) in enumerate(rows):
            if i == j:
                continue
            if s2 >= s and e2 <= e and d2 < d:
                inner += d2
        if inner >= 0.8 * d:
            out.add(i)
    return out


def report(run_dir):
    j = os.path.join(run_dir, "build_journal.txt")
    if not os.path.isfile(j):
        return False
    rows = parse(j)
    if not rows:
        return False
    span = max(r[1] for r in rows)
    wrap = wrappers(rows)
    # BACKGROUND: a phase covering most of the timeline is not a serial step,
    # it is something running underneath. Left in the contention set it makes
    # every other phase look "shared" and the exclusive column reads 0.0 s
    # across the board - which is how the first version of this tool reported
    # the heightfield, the splat and the apply as free. The catalogue mount is
    # the known case: 85 s of a 113 s timeline, on its own worker, and the only
    # readers of catalogue_ready are a diagnostics report and the near-camera
    # sharpening gate.
    bg = {i for i, r in enumerate(rows) if r[2] > 0.4 * span}
    real = [i for i in range(len(rows)) if i not in wrap and i not in bg]

    # Sweep line at 100 ms resolution: fine enough to be honest about a phase
    # that only briefly stands alone, coarse enough to stay instant.
    STEP = 100
    excl = {i: 0 for i in real}
    gap = 0
    t = 0
    while t < span:
        active = [i for i in real if rows[i][0] <= t < rows[i][1]]
        if not active:
            gap += STEP
        elif len(active) == 1:
            excl[active[0]] += STEP
        t += STEP

    name = os.path.basename(run_dir)
    print("=" * 78)
    print("%s   %.1f s of timeline" % (name, span / 1000.0))
    print("=" * 78)
    print("\n  %7s %8s   %s" % ("exclusive", "duration", "phase"))
    print("  %s" % ("-" * 72))
    ranked = sorted(real, key=lambda i: -excl[i])
    shown = 0
    for i in ranked:
        if excl[i] < 500:
            continue
        s, e, d, label = rows[i]
        print("  %8.1fs %8.1fs   %s" % (excl[i] / 1000.0, d / 1000.0, label[:50]))
        shown += 1
    if not shown:
        print("  (nothing held the build alone for more than 0.5 s)")
    tot = sum(excl.values())
    print("  %s" % ("-" * 72))
    print("  %8.1fs            EXCLUSIVE TOTAL - the time worth attacking"
          % (tot / 1000.0))
    print("  %8.1fs            unattributed (no phase recording)"
          % (gap / 1000.0))
    print("  %8.1fs            overlapped (already running concurrently)"
          % ((span - tot - gap) / 1000.0))

    if bg:
        print("\n  BACKGROUND (runs underneath; held out of the figures above)")
        for i in sorted(bg, key=lambda k: -rows[k][2]):
            s, e, d, label = rows[i]
            print("    %6.1fs  t+%.1fs to t+%.1fs   %s"
                  % (d / 1000.0, s / 1000.0, e / 1000.0, label[:44]))

    big_bg = [i for i in real
              if rows[i][2] > 5000 and excl[i] < 0.25 * rows[i][2]]
    if big_bg:
        print("\n  ALREADY OVERLAPPED - long phases that are mostly free, so "
              "speeding\n  them up would not shorten the build:")
        for i in sorted(big_bg, key=lambda k: -rows[k][2])[:6]:
            s, e, d, label = rows[i]
            print("    %6.1fs dur, only %5.1fs exclusive   %s"
                  % (d / 1000.0, excl[i] / 1000.0, label[:44]))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run", nargs="?")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    if a.run:
        if not report(a.run):
            print("%s: no usable build journal" % a.run)
        return
    dirs = [d for d in glob.glob(os.path.join(PERFRUN, "*")) if os.path.isdir(d)]
    dirs.sort(key=os.path.getmtime, reverse=True)
    if a.all:
        seen = set()
        for d in dirs:
            tag = os.path.basename(d).rsplit("-", 2)[0]
            if tag in seen:
                continue
            if report(d):
                seen.add(tag)
        return
    for d in dirs:
        if report(d):
            return
    print("no run with a build journal found")


main()
