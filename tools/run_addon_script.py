#!/usr/bin/env python
"""Run one script against the FULL addon in a throwaway project.

The addon's scripts reach each other through `class_name` globals, and a fresh
project has no global class cache, so a bare `--script` run reports dozens of
undeclared identifiers that exist only in that run. gate_sandbox.py already
solved this: build a sandbox, run `--import` FIRST to register the classes, then
run the script. This is the same trick for an arbitrary test instead of the gate
payload, so a rule inside the addon can be tested without the editor and without
the incomplete copy in native/_testproj.

    python tools/run_addon_script.py native/test_portal_layers.gd
"""

from __future__ import annotations

import argparse
import io
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from gate_sandbox import PROJECT_GODOT, find_godot  # same sandbox shape

REPO = Path(__file__).resolve().parent.parent
ADDON = REPO / "addons" / "highpoly_toggle"


def _user_args(args):
    """OS.get_cmdline_user_args() only sees what follows a bare "--", so the
    separator is added here rather than left to every caller to remember."""
    out = [a for a in args if a != "--"]
    return ["--"] + out if out else []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("script", type=Path)
    ap.add_argument("--timeout", type=float, default=600.0)
    ap.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    a = ap.parse_args()

    script = a.script if a.script.is_absolute() else REPO / a.script
    if not script.is_file():
        raise SystemExit("no such script: %s" % script)
    godot = find_godot()

    work = Path(tempfile.mkdtemp(prefix="bf6-run-"))
    proj = work / "runproj"
    dst = proj / "addons" / "highpoly_toggle"
    dst.mkdir(parents=True)
    io.open(proj / "project.godot", "w", encoding="utf-8", newline="\n").write(PROJECT_GODOT)
    for src in sorted(ADDON.iterdir()):
        if src.is_file():
            shutil.copy2(src, dst / src.name)
    # THE NATIVE BINARIES TOO, unlike the gate.
    #
    # The gate only type-checks, so it never needs the extension to load. A
    # RUN does: without bin/ the .gdextension resolves to nothing, BF6Core is
    # never registered, and the script fails with "BF6Core is not registered" -
    # which reads as a broken binding rather than as a sandbox missing a file.
    if (ADDON / "bin").is_dir():
        shutil.copytree(ADDON / "bin", dst / "bin")
    shutil.copy2(script, proj / "run_me.gd")

    try:
        # The import pass is what registers class_name; without it every
        # cross-script reference reads as undeclared.
        subprocess.run([godot, "--headless", "--path", str(proj), "--import"],
                       capture_output=True, text=True, timeout=a.timeout)
        r = subprocess.run([godot, "--headless", "--path", str(proj),
                            "--script", "res://run_me.gd"] + _user_args(a.args),
                           capture_output=True, text=True, timeout=a.timeout)
    except subprocess.TimeoutExpired:
        print("TIMED OUT after %.0f s" % a.timeout)
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)

    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stdout.write(r.stderr)
    return r.returncode


if __name__ == "__main__":
    raise SystemExit(main())
