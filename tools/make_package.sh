#!/usr/bin/env bash
# HAND-OFF PACKAGE: a zip to send someone directly, without cutting a release.
#
#   tools/make_package.sh [version] [outdir]
#
# Defaults to one patch above plugin.cfg and the Desktop. The zip is the same
# shape the in-editor updater installs (rooted at addons/highpoly_toggle/), so
# the recipient can either extract it over their PortalSDK GodotProject folder
# or let the updater do it later.
#
# WHY THE VERSION MATTERS. The updater offers a download only when the release
# is strictly NEWER than what is installed (semantic tuple compare). Stamp a
# hand-off build ABOVE the current release and the updater will leave it alone
# until a genuinely newer release exists; stamp it below and the recipient gets
# pulled back to the release, losing the fix you sent them.
#
# Built from the WORKING TREE, not from git, so unreleased and uncommitted
# fixes can be handed over. BUILD-INFO.txt records the commit it sat on and
# whether the tree was dirty, so a package can always be traced back.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$REPO/addons/highpoly_toggle"
SEVENZIP="C:/Program Files/7-Zip/7z.exe"

# sed, not grep -P: Git Bash here runs a grep whose -P refuses non-UTF-8
# locales, and the packaging script must not depend on the shell's locale
CUR="$(sed -n 's/^version="\([^"]*\)".*/\1/p' "$ADDON/plugin.cfg")"
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
  VER="$1"
else
  VER="$(echo "$CUR" | awk -F. '{printf "%d.%d.%d", $1, $2, $3 + 1}')"
fi
OUT="${2:-$HOME/Desktop}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/addons"
cp -r "$ADDON" "$STAGE/addons/"
# .godot and editor leftovers never belong in a package
rm -rf "$STAGE/addons/highpoly_toggle/.godot"

# stamp the version INSIDE the package only; the repo keeps its own
sed -i "s/^version=\"$CUR\"/version=\"$VER\"/" "$STAGE/addons/highpoly_toggle/plugin.cfg"

COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
if ! git -C "$REPO" diff --quiet 2>/dev/null; then DIRTY=" (working tree had uncommitted changes)"; fi
cat > "$STAGE/addons/highpoly_toggle/BUILD-INFO.txt" <<EOF
BF6 High-Poly Preview, hand-off build
version   $VER
built     $(date -u +%Y-%m-%dT%H:%M:%SZ)
commit    $COMMIT$DIRTY
based on  repo version $CUR
EOF

cat > "$STAGE/READ-ME-FIRST.txt" <<'EOF'
BF6 High-Poly Preview - how to install this build
=================================================

This zip contains one folder: addons\highpoly_toggle

1. Close the Godot editor.
2. Open your Portal SDK folder, the one that contains "GodotProject".
3. Go into GodotProject. You should already see an "addons" folder there.
4. Copy the "addons" folder from this zip into GodotProject and choose
   "replace the files in the destination". Nothing else is touched.
5. Start the editor again.

To check it worked: open the High-Poly panel. The version is written at the
top of any log you save with "Save log file".

If the panel says "Battlefield 6 not detected", or it says detected but the
switches do nothing:

  Press "Locate..." at the top of the panel and choose the folder that
  CONTAINS "Data". For a normal Steam install that is:

      C:\Program Files (x86)\Steam\steamapps\common\Battlefield 6

  Choose the "Battlefield 6" folder itself, not the "Data" folder inside it.

If it still does not work, press "Save log file" and send that file. The log
now records whether your game was found, where it looked, and which levels
your install contains.
EOF

mkdir -p "$OUT"
ZIP="$OUT/highpoly_toggle-v$VER.zip"
rm -f "$ZIP"
( cd "$STAGE" && "$SEVENZIP" a -tzip -mx=9 "$ZIP" addons READ-ME-FIRST.txt >/dev/null )
echo "packaged v$VER from $COMMIT$DIRTY"
echo "$ZIP"
