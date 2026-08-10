"""MP_GolmudRailway TerrainDecals: the NEW record format, documented as far as
it is decoded.

MEASURED facts this probe reproduces:
  * slotCount 53 == layerCount; GUID-bearing slots are 24-28, 41, 46 (the
    map-global special base layers), vs Tungsten's 9/10;
  * recordCount 1,746, and the TERRAIN.md #10 grammar (property stream first,
    anchor scan) parses ZERO records -- the layout changed;
  * records lead with a fixed header: u64 hash (NOT a key of the paired
    depot), u32 3, scale floats, two world corner vec4s + a 2D x0,z0,x1,z1
    box in map coordinates, flags 01 01 01 01, counts, THEN the property
    stream (the _cv slot hash 0x399AC0336ACFE03C appears there);
  * a decals.shaderblockdepot ships beside the resource (Tungsten has none):
    20 keys / 19 records, every one binding a crater texture (hfd_*) at slot
    0xAE16A5C0.

Usage: probe_golmud_decals.py [level]
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_guidscan as G      # noqa: E402
import shaderblock                   # noqa: E402


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_golmudrailway"
    td = T.terr_dir(level)
    dec = dep = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
            if fn.endswith("decals.shaderblockdepot.ShaderBlockDepotResource"):
                dep = os.path.join(dirpath, fn)
    d = C.read(dec)
    u32 = lambda o: struct.unpack_from("<I", d, o)[0]
    u64 = lambda o: struct.unpack_from("<Q", d, o)[0]
    sc = u32(0x10)
    print("%s  %s  %d bytes  slotCount %d" % (level, os.path.basename(dec),
                                              len(d), sc))
    o = 0x14
    used = []
    for i in range(sc):
        g = d[o:o + 16]
        o += 16
        if g != b"\0" * 16:
            used.append(i)
    rc = u32(o)
    o += 4
    print("   GUID-bearing slots: %s   recordCount %d" % (used, rc))
    print("   record 0 @ 0x%X leads with u64 0x%016X" % (o, u64(o)))
    print(C.hexdump(d, o, 0xB0))

    if dep:
        gi = {}
        cp = os.path.join(G.CACHE, "..json")
        if os.path.isfile(cp):
            gi = json.load(open(cp, encoding="utf-8"))
            gi = {k: (v[:-4] if v.endswith(".ebx") else v) for k, v in gi.items()}
        D = shaderblock.parse_depot(dep)
        print("paired depot: %s" % D.stats())
        for ri, rec in enumerate(D.records):
            r = shaderblock.resolve_record(rec, gi)
            if r:
                for lbl, path in sorted(r["textures"].items()):
                    print("   rec %2d  %-14s %s" % (ri, lbl, path))


if __name__ == "__main__":
    main()
