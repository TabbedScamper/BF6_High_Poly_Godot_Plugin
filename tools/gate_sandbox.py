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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", default="")
    ap.add_argument("--addon", type=Path, default=ADDON)
    ap.add_argument("--keep", action="store_true",
                    help="leave the sandbox project on disk for inspection")
    ap.add_argument("--timeout", type=float, default=900.0)
    a = ap.parse_args()
    godot = a.godot or find_godot()
    if not a.addon.is_dir():
        raise SystemExit("No addon at %s" % a.addon)
    if not GATE.is_file():
        raise SystemExit("Missing gate payload: %s" % GATE)

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
        return 1
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
        return 0
    print("\nGATE FAILED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
