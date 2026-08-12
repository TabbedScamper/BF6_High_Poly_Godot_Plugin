#!/usr/bin/env python
"""Stage plugin changes for "Check for updates", without closing the editor.

THE POINT: nothing may write into res:// while the editor is open. The editor
hot-reloads changed scripts underneath running code, which is a "Bad address
index" crash mid-build rather than a feature. But waiting for a closed editor
to deliver every fix costs the whole iteration loop.

So changes land in user://highpoly/staged instead - per project, outside the
resource scan, and never read by the editor on its own. Pressing "Check for
updates" is what moves them into the addon and hot-reloads, at a moment the
USER chose, and the button refuses while anything is building.

    python tools/stage.py                # stage every changed file
    python tools/stage.py --dry-run      # say what would move, touch nothing
    python tools/stage.py bf6_source.gd  # stage just these

WHAT THIS DELIBERATELY WILL NOT DO, because HighpolyReload says so:

  * The stage is FLAT and holds .gd and .gdshader only. Subdirectories and
    binaries (bin/, the .gdextension, the fx_*.json data) are not
    hot-reloadable and do not belong here - they need a closed editor.
  * Geometry changes do not re-dress from a reload. A change to how a mesh is
    BUILT needs the on-disk geometry cache invalidated with a cache epoch, and
    costs a rebuild whatever this script does.

For the editor-closed path, use deploy_gated.py, which copies straight into the
addon and then gates the DEPLOYED set - the gate reads res://, so it can only
check what has actually been installed.
"""

import argparse
import hashlib
import io
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_PLUGIN = os.path.join(os.path.dirname(HERE), "addons", "highpoly_toggle")
LIVE_PLUGIN = r"C:\PortalSDK\GodotProject\addons\highpoly_toggle"
STAGED = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "app_userdata",
    "Battlefield\u2122 Portal Project", "highpoly", "staged")

STAGEABLE = (".gd", ".gdshader")


def md5(path):
    with io.open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def editor_running():
    out = subprocess.run(["tasklist"], capture_output=True, text=True).stdout
    return "Godot_v4" in out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*",
                    help="specific file names; default is everything changed")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if not os.path.isdir(REPO_PLUGIN):
        raise SystemExit("no repo plugin at %s" % REPO_PLUGIN)

    wanted = set(a.names)
    changed, skipped = [], []
    for name in sorted(os.listdir(REPO_PLUGIN)):
        src = os.path.join(REPO_PLUGIN, name)
        if not os.path.isfile(src):
            continue
        if wanted and name not in wanted:
            continue
        if not name.endswith(STAGEABLE):
            # Only worth mentioning if it genuinely differs, otherwise every
            # run would list the whole data set as "skipped".
            live = os.path.join(LIVE_PLUGIN, name)
            if os.path.isfile(live) and md5(src) != md5(live):
                skipped.append(name)
            continue
        live = os.path.join(LIVE_PLUGIN, name)
        if not os.path.isfile(live) or md5(src) != md5(live):
            changed.append(name)

    missing = wanted - {n for n in os.listdir(REPO_PLUGIN)}
    if missing:
        raise SystemExit("not in the plugin: %s" % ", ".join(sorted(missing)))

    if not changed and not skipped:
        print("nothing to stage: the addon already matches the repo")
        return

    if changed:
        print("%s %d file(s) to user://highpoly/staged:"
              % ("would stage" if a.dry_run else "staging", len(changed)))
        for n in changed:
            print("    %s" % n)
    if skipped:
        # Said loudly rather than silently dropped: a staged run that leaves
        # these behind is a PARTIAL update, and the difference shows up later
        # as behaviour that half-matches the code.
        print("\nNOT STAGEABLE, so these still need a closed editor and "
              "deploy_gated.py:")
        for n in skipped:
            print("    %s" % n)

    if a.dry_run:
        return

    os.makedirs(STAGED, exist_ok=True)
    for n in changed:
        shutil.copy2(os.path.join(REPO_PLUGIN, n), os.path.join(STAGED, n))
        if md5(os.path.join(REPO_PLUGIN, n)) != md5(os.path.join(STAGED, n)):
            raise SystemExit("staged copy of %s does not match" % n)

    print("\nStaged. In the editor press \"Check for updates\" to apply and "
          "reload.")
    if not editor_running():
        print("(No editor is running at the moment, so this will apply "
              "whenever one is next opened and the button is pressed.)")


main()
