#!/usr/bin/env python
"""COLD COST PER DOCK BUTTON, measured in the real editor.

Every other bench answers "how long does a map take". This answers the question
a user actually asks, which is "which switch costs me the five minutes". It
runs perfrun once per toggle, wipes every cache before each run so each one is
a genuine first read, and prints what each button cost and where it went.

Why the wipe matters: the caches are shared. Whichever button runs first pays
for the mount, the partition index and the walk, and every button after it
looks nearly free. Clearing between runs is the only way the numbers mean
anything on their own - and it is why this is slow and deliberate rather than
something to run casually.

Why the real editor: the read is the same code headless, but a button is a
control in a dock, and what a user waits on includes the panel, the yields and
the scene work that only exist there. bench_cold.gd measures the reader;
this measures the button.

    python tools/bench_buttons.py --map MP_Aftermath
    python tools/bench_buttons.py --buttons terrain,objects --gpu-validation

Each run's artefacts land in native/perfrun/btn_<button>-<stamp>/, including
the build journal, so a slow button can be opened up phase by phase afterwards.
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import perfrun  # noqa: E402  - for BUTTONS and the run directory layout


# The order is the order a user meets them, not alphabetical: terrain first
# because it is the container, then the layers that read more of the install.
DEFAULT_ORDER = ["terrain", "objects", "roads", "water", "backdrop",
                 "maplights", "proplights", "grass"]


def dirs_for(root, tag):
    if not os.path.isdir(root):
        return set()
    return {d for d in os.listdir(root) if d.startswith(tag + "-")}


def new_run(root, tag, before):
    """The run directory THIS invocation created, or "" if it created none.

    Deliberately not "the newest one with this tag": when a run failed to
    start, that returned the directory from a PREVIOUS sweep and the bench
    reported its numbers as this run's. One sweep reported an "objects: crash,
    69.6 s" that was an hour old and belonged to a different build of the
    plugin. A run that produced nothing has to say so."""
    made = dirs_for(root, tag) - before
    if not made:
        return ""
    return os.path.join(root, sorted(made)[-1])


def read_run(run_dir):
    out = {"outcome": "?", "build_s": 0.0, "open_s": 0.0, "wall_s": 0.0,
           "phases": []}
    j = os.path.join(run_dir, "perfrun.json")
    if os.path.isfile(j):
        try:
            with open(j, encoding="utf-8") as f:
                r = json.load(f).get("run", {})
            out["outcome"] = r.get("outcome", "?")
            out["build_s"] = float(r.get("build_s", 0.0) or 0.0)
            out["open_s"] = float(r.get("open_s", 0.0) or 0.0)
            out["wall_s"] = float(r.get("wall_s", 0.0) or 0.0)
        except (ValueError, OSError):
            pass
    out["phases"] = perfrun.load_breakdown(run_dir, top=6)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default="MP_Aftermath")
    ap.add_argument("--buttons", default=",".join(DEFAULT_ORDER),
                    help="comma separated, from: %s"
                         % ", ".join(sorted(perfrun.BUTTONS)))
    ap.add_argument("--gpu-validation", action="store_true",
                    help="pass through to perfrun; slower but survives the "
                         "render-thread fault in task 107")
    ap.add_argument("--warm", action="store_true",
                    help="do NOT wipe between runs. Measures what a second "
                         "visit costs, which is a different question")
    ap.add_argument("--timeout", type=float, default=2400.0)
    a = ap.parse_args()

    wanted = [b.strip() for b in a.buttons.split(",") if b.strip()]
    for b in wanted:
        if b not in perfrun.BUTTONS:
            raise SystemExit("unknown button %r. Known: %s"
                             % (b, ", ".join(sorted(perfrun.BUTTONS))))

    root = os.path.join(os.path.dirname(HERE), "native", "perfrun")
    print("BUTTON BENCH  map=%s  %s" % (a.map,
          "WARM (nothing wiped)" if a.warm else "COLD (every cache wiped "
          "before each button)"))
    print("buttons: %s" % ", ".join(wanted))
    print("")

    results = []
    for i, b in enumerate(wanted, 1):
        tag = "btn_" + b
        cmd = [sys.executable, os.path.join(HERE, "perfrun.py"),
               "--map", a.map, "--tag", tag, "--only", b,
               "--timeout", str(a.timeout)]
        if not a.warm:
            cmd += ["--cold", "--yes-delete-caches"]
        if a.gpu_validation:
            cmd += ["--gpu-validation"]
        print("=" * 72)
        print("[%d/%d] %s" % (i, len(wanted), b))
        print("=" * 72)
        t0 = time.time()
        before = dirs_for(root, tag)
        rc = subprocess.run(cmd).returncode
        run_dir = new_run(root, tag, before)
        r = read_run(run_dir) if run_dir else {
            "outcome": "no run (perfrun exit %s)" % rc,
            "build_s": 0.0, "open_s": 0.0, "wall_s": 0.0, "phases": []}
        r["button"] = b
        r["elapsed_s"] = time.time() - t0
        r["dir"] = run_dir
        results.append(r)

    print("")
    print("=" * 78)
    print("COLD COST PER BUTTON  (%s)" % a.map)
    print("=" * 78)
    print("  %-12s %9s %9s %9s  %s" % ("button", "open", "build", "wall",
                                       "outcome"))
    for r in results:
        print("  %-12s %8.1fs %8.1fs %8.1fs  %s"
              % (r["button"], r["open_s"], r["build_s"], r["wall_s"],
                 r["outcome"]))

    # The phase table per button is the actionable half: "objects cost 300 s"
    # is a complaint, "objects cost 300 s and 155 of them were the splat
    # composite" is a task.
    for r in results:
        if not r["phases"]:
            continue
        print("")
        print("  %s - where it went:" % r["button"])
        for dur, items, res_kb, chunk_kb, reads, label in r["phases"]:
            print("      %7.1fs  %-52s" % (dur / 1000.0, label[:52]))

    bad = [r for r in results if r["outcome"] != "done"]
    if bad:
        print("")
        print("  NOT CLEAN: %s" % ", ".join(
            "%s (%s)" % (r["button"], r["outcome"]) for r in bad))
    return 0


if __name__ == "__main__":
    sys.exit(main())
