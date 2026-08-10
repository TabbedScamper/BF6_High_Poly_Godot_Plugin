"""MP_Abbasid subworld / depot scope census, against layer_of_scope().

The walk assigns every placement the scope of the depot-owning subworld above
it, and `highpoly_gamesource.gd::layer_of_scope` turns that scope into a
switchable-layer key ("" = always visible; anything else is hidden unless its
layer is picked, with only "default_event" on by default).  Those rules were
derived on MP_Aftermath (sub_art_* / default_event / winter_event /
_layers_gameplay).  MP_Abbasid names NONE of its subworlds that way, so this
probe lists every depot-owning subworld in the level and what the CURRENT rules
would do with it — the mechanical explanation for task #77's marked faults.

Read-only. Reimplements layer_of_scope 1:1 (do not import plugin code from
Python); if the plugin's rules change, re-check this copy against
highpoly_gamesource.gd.

Usage:  probe_abbasid_scopes.py [level]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402


def layer_of_scope(scope, level):
    """1:1 port of highpoly_gamesource.gd::layer_of_scope (2026-08-10)."""
    if scope == "":
        return ""
    leaf = scope.rsplit("/", 1)[-1]
    d = scope.rsplit("/", 1)[0] if "/" in scope else ""
    if leaf == level or leaf == d.rsplit("/", 1)[-1]:
        return ""
    if leaf.startswith("sub_art_"):
        return ""
    if d.endswith("_layers_world") or d.endswith("_layers_content"):
        return ""
    return leaf


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_abbasid"
    root = os.path.join(C.LEVELS, level)
    # depot-owning subworlds: every directory that has a sibling
    # <name>_win32_shaderstate directory (the per-subworld ShaderBlockDepot)
    scopes = []
    for dp, dn, fn in os.walk(root):
        for n in dn:
            if n.endswith("_win32_shaderstate"):
                owner = n[:-len("_win32_shaderstate")]
                rel = os.path.relpath(os.path.join(dp, owner), root)
                scopes.append("game/glaciermp/levels/%s/%s"
                              % (level, rel.replace(os.sep, "/")))
    scopes.sort()
    print("%s: %d depot-owning subworld scopes" % (level, len(scopes)))
    always, hidden = [], []
    for s in scopes:
        k = layer_of_scope(s, level)
        (always if k == "" else hidden).append((s, k))
    print("\n-- layer_of_scope == \"\"  (ALWAYS VISIBLE, %d)" % len(always))
    for s, _k in always:
        flag = ""
        base = s.split("/%s/" % level, 1)[1]
        if base.count("/") == 0 and base != level:
            flag = "   <-- ROOT-LEVEL SUBWORLD"
        leaf = s.rsplit("/", 1)[-1]
        par = s.rsplit("/", 2)[-2]
        if leaf == par and leaf != level:
            flag = "   <-- x/x DIR COLLISION with the level-root rule"
        if "_subworld" in leaf and not leaf.startswith("area_") \
                and not leaf == "world":
            flag += "   <-- GAMEMODE subworld, shown in every mode"
        print("   %-70s%s" % (base, flag))
    print("\n-- layer_of_scope != \"\"  (HIDDEN unless its layer is picked, %d)"
          % len(hidden))
    for s, k in hidden:
        base = s.split("/%s/" % level, 1)[1]
        flag = ""
        if base.count("/") == 0:
            flag = "   <-- ROOT-LEVEL SUBWORLD (world content?)"
        print("   %-55s -> %-24s%s" % (base, k, flag))


if __name__ == "__main__":
    main()
