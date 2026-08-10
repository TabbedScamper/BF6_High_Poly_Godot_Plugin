"""Shared plumbing for the MP_Portal_Sand probes (probe_portalsand_*.py).

READ-ONLY against the extracted 2026-08-01 pull.

MP_Portal_Sand is the Portal sandbox level. It does NOT live where every other
studied map lives: the levels root is `game/glacierportal/levels`, not
`game/glaciermp/levels`. This module re-points the Tungsten plumbing's LEVELS
at the glacierportal root and re-exports everything, so every probe_tung_*
parser (which all read C.LEVELS at call time) works unchanged.

Second naming trap on this map: the terrain directory is
`mp_portal_desert_terrain` -- it contains neither the level name prefix pattern
(`terrain_mp_portal_sand`) nor the dumbo pattern (`mp_portal_sand_terrain`).
probe_tung_terrain.terr_dir already searches for any dir containing "terrain"
with a .TerrainStreamingTree inside, which is the only rule that survives here.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C            # noqa: E402

# Re-point the level root BEFORE anything resolves a level path.
LEVELS_PORTAL = os.path.join(C.BUNDLES, "game", "glacierportal", "levels")
C.LEVELS = LEVELS_PORTAL

SAND = os.path.join(LEVELS_PORTAL, "mp_portal_sand")
LEVEL = "mp_portal_sand"

# convenience re-exports so probes can `import probe_portalsand_common as PC`
read = C.read
u8, u16, u32, u64, f32 = C.u8, C.u16, C.u32, C.u64, C.f32
hexdump = C.hexdump
open_ebx = C.open_ebx
instances = C.instances
named = C.named
tname = C.tname
fname = C.fname
af_leaf = C.af_leaf

if __name__ == "__main__":
    print("levels root", LEVELS_PORTAL, "exists" if os.path.isdir(LEVELS_PORTAL) else "MISSING")
    print("level      ", SAND, "exists" if os.path.isdir(SAND) else "MISSING")
