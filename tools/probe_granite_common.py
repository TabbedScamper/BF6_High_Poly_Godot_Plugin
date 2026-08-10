"""Shared plumbing for the GRANITE probes (probe_granite_*.py).

READ-ONLY. Granite is ONE authored world shipped as EIGHT levels:

    game/glaciergranite/levels/mp_granite                      the BR host world
    game/glacierportal/levels/mp_granite_<slice>_portal        seven Portal slices

The seven Portal levels do NOT live under glaciermp/levels, so
probe_tung_common.LEVELS / probe_tung_terrain.terr_dir cannot find them.
This module maps slugs to roots and re-exports the tungsten plumbing.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C           # noqa: E402  (re-exported)

PORTAL_LEVELS = os.path.join(C.BUNDLES, "game", "glacierportal", "levels")
GRANITE_BASE = os.path.join(C.BUNDLES, "game", "glaciergranite", "levels",
                            "mp_granite")

SLUGS = ["clubhouse", "mainstreet", "marina", "militaryrnd",
         "militarystorage", "techcampus", "underground"]

ROOTS = {s: os.path.join(PORTAL_LEVELS, "mp_granite_%s_portal" % s)
         for s in SLUGS}
ROOTS["base"] = GRANITE_BASE

LEVEL_NAMES = {s: "mp_granite_%s_portal" % s for s in SLUGS}
LEVEL_NAMES["base"] = "mp_granite"


def root(slug):
    return ROOTS[slug]


def terr_dir(slug):
    r = ROOTS[slug]
    for d in sorted(os.listdir(r)):
        p = os.path.join(r, d)
        if os.path.isdir(p) and "terrain" in d.lower():
            if any(f.endswith(".TerrainStreamingTree") for f in os.listdir(p)):
                return p
    raise SystemExit("no terrain dir under %s" % r)


if __name__ == "__main__":
    for s, r in ROOTS.items():
        print("%-16s %s  %s" % (s, "OK " if os.path.isdir(r) else "MISSING",
                                terr_dir(s)))
