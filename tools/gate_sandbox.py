"""Run the whole-set gate on the REPO copy, in a sandbox, editor or no editor.

THE HOLE THIS FILLS. check_all.gd scans res://addons/highpoly_toggle/ - the
DEPLOYED copy - and the repo lives behind a .gdignore where Godot cannot see it.
So the gate could only ever run after deploying, and deploying is exactly what
is forbidden while the user's editor is open. Every change staged during a
session therefore went out unchecked, and two of them cost a rebuild to
discover: a shader that could not compile, and a stale shader cache.

This copies the repo addon into a throwaway project and runs the same gate
there. It never touches the user's project, so it is safe with the editor open,
and it checks the code that is about to be STAGED rather than the code already
deployed.

WHAT IT STILL CANNOT SEE. The scripts are checked as a set, which catches parse
errors and callers drifting from callees. It cannot catch a runtime fault, and
it cannot tell you the picture is right.

WHY THIS FILE LIVES IN THE REPO NOW. It used to exist only as a copy in an agent
scratchpad with `C:\\PortalSDK` hardcoded in it - a path that no longer exists on
any machine here - so the one gate the project's own rules require before a
deploy could not be run at all. Paths are resolved from this file's location and
overridable by environment variable, so moving the repo or the SDK does not
strand it again.

    python tools/gate_sandbox.py
    python tools/gate_sandbox.py --godot <godot.exe> --addon <addon dir>

Environment: GODOT_BIN, BF6_SDK_ROOT.
"""

from __future__ import annotations

import argparse
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
ADDON = REPO / "addons" / "highpoly_toggle"
GATE = HERE / "checkproj" / "check_all.gd"

PROJECT_GODOT = """config_version=5

[application]
config/name="gateproj"

[rendering]
renderer/rendering_method="mobile"
"""

# Engine chatter that is not about the addon. Filtered so a pass reads as a
# pass instead of as five lines of warning about the render thread.
NOISE = ("separate rendering thread", "bear in mind", "unless you want",
         "at: setup2", "Godot Engine v")


def find_godot() -> str:
    """The editor binary: the flag, then the environment, then the newest SDK."""
    env = os.environ.get("GODOT_BIN")
    if env and Path(env).is_file():
        return env
    root = Path(os.environ.get("BF6_SDK_ROOT", r"C:\BF6_SDK\SDKs"))
    if root.is_dir():
        found = sorted(root.glob("PortalSDK-*/Godot_v*_win64.exe"))
        if found:
            return str(found[-1])
    raise SystemExit(
        "Could not find a Godot binary. Pass --godot, or set GODOT_BIN, or keep "
        "an SDK under %s" % root)


def find_extra_engines() -> list:
    """Every OTHER engine to gate against, newest-first.

    THE HOLE THIS FILLS. The gate ran on whatever Godot the SDK ships, so "SET
    OK" only ever meant "OK on that one build". On 2026-08-09 a user's crash log
    reported Godot 4.7.1 against an SDK that ships 4.6.3, and a second addon in
    the same log died on a 4.7 typed-container tightening - a whole class of
    breakage the gate was structurally unable to see.

    Engines here are ADDITIONAL, not a replacement: a release has to pass on the
    version the SDK ships AND on the versions users actually run. Drop an
    editor build in the directory and it joins the gate; there is no list to
    keep in sync.
    """
    root = Path(os.environ.get("BF6_GODOT_ENGINES", r"C:\BF6_Dev\_godot_engines"))
    if not root.is_dir():
        return []
    out = []
    for p in sorted(root.glob("Godot_v*_win64.exe"), reverse=True):
        # The console wrapper is the same engine; gating it twice proves nothing.
        if "_console" in p.name:
            continue
        out.append(str(p))
    return out


def engine_label(path: str) -> str:
    name = Path(path).name
    return name[len("Godot_v"):] if name.startswith("Godot_v") else name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", default="")
    ap.add_argument("--addon", type=Path, default=ADDON)
    ap.add_argument("--keep", action="store_true",
                    help="leave the sandbox project on disk for inspection")
    ap.add_argument("--timeout", type=float, default=900.0)
    ap.add_argument("--all-engines", action="store_true",
                    help="also gate against every editor in BF6_GODOT_ENGINES "
                         "(default C:\\BF6_Dev\\_godot_engines). A release must "
                         "pass on all of them, not just the SDK's own build.")
    a = ap.parse_args()
    if not a.addon.is_dir():
        raise SystemExit("No addon at %s" % a.addon)
    if not GATE.is_file():
        raise SystemExit("Missing gate payload: %s" % GATE)

    if a.godot:
        engines = [a.godot]
    else:
        engines = [find_godot()]
        if a.all_engines:
            for e in find_extra_engines():
                if e not in engines:
                    engines.append(e)

    results = []
    for godot in engines:
        if len(engines) > 1:
            print("\n=== %s ===" % engine_label(godot))
        results.append((godot, run_one(godot, a)))

    if len(engines) > 1:
        print("\n---- gate summary ----")
        for godot, ok in results:
            print("  %-34s %s" % (engine_label(godot), "PASS" if ok else "FAIL"))
    return 0 if all(ok for _, ok in results) else 1


def run_one(godot: str, a) -> bool:
    work = Path(tempfile.mkdtemp(prefix="bf6-gate-"))
    proj = work / "gateproj"
    dst = proj / "addons" / "highpoly_toggle"
    dst.mkdir(parents=True)
    io.open(proj / "project.godot", "w", encoding="utf-8",
            newline="\n").write(PROJECT_GODOT)
    n = 0
    for src in sorted(a.addon.iterdir()):
        if src.is_file():
            shutil.copy2(src, dst / src.name)
            n += 1
    shutil.copy2(GATE, proj / "check_all.gd")
    print("gating %d repo file(s) in a sandbox" % n)
    print("  godot:  %s" % godot)
    print("  addon:  %s" % a.addon)

    try:
        # SCAN FIRST. A fresh project has no global class cache, so every
        # class_name in the addon reads as an undeclared identifier and the gate
        # reports dozens of failures that exist only in the sandbox. The import
        # pass is what registers them.
        subprocess.run([godot, "--headless", "--path", str(proj), "--import"],
                       capture_output=True, text=True, timeout=a.timeout)
        r = subprocess.run([godot, "--headless", "--path", str(proj),
                            "--script", "res://check_all.gd"],
                           capture_output=True, text=True, timeout=a.timeout)
    except subprocess.TimeoutExpired:
        print("GATE TIMED OUT after %.0f s" % a.timeout)
        return False
    finally:
        if a.keep:
            print("  sandbox kept at %s" % proj)
        else:
            shutil.rmtree(work, ignore_errors=True)

    out = (r.stdout or "") + (r.stderr or "")
    for line in out.splitlines():
        if any(s in line for s in NOISE) or line.startswith("However"):
            continue
        if line.strip():
            print("  " + line)
    if "SET OK" in out:
        print("\nGATE PASSED on the repo copy")
        return True
    print("\nGATE FAILED")
    return False


if __name__ == "__main__":
    raise SystemExit(main())
