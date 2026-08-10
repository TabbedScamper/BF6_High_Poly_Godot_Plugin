"""MP_Eastwood's TerrainDecals -- census by property scan.

probe_tung_decals.py parses 0 of eastwood's 2,340 records: eastwood's record
framing differs from tungsten's (records open with a magic u64
0xAEF8B6DE64DD8673 followed by a variable-length geometry header -- tiling
floats, a world AABB around +0x40 -- and THEN the property stream; tungsten's
records open with the property stream and the geometry is found by anchor
scan). The full framing is not decoded here.

What IS identical is the property-entry encoding (TERRAIN.md 10.3):
[u64 nameHash][u32 typeId 0xCC84D53D][u16][u16][u8 cnt][16B pad][16B GUID].
This probe scans the whole resource for the four texture slot hashes followed
by the texture typeId and extracts every texture binding, giving the per-slot
census and the texture-name table without solving the framing.

READ-ONLY.  Usage:  probe_eastwood_decals.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402

SLOTS = {
    0x399AC0336ACFE03C: "_cv",
    0x567A9BC35CCBB1B2: "_nhs",
    0x3A411B3E209FC9E2: "_ao",
    0x3810287D4CE70B49: "_op",
}
TEX_TYPE = 0xCC84D53D
MAGIC = 0xAEF8B6DE64DD8673            # leads every eastwood decal record


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_eastwood"
    td = T.terr_dir(level)
    dec = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
    d = C.read(dec)
    print("%s  %s  %d bytes" % (level, os.path.basename(dec), len(d)))
    sc = struct.unpack_from("<I", d, 0x10)[0]
    o = 0x14 + 16 * sc
    rc = struct.unpack_from("<I", d, o)[0]
    print("   slotCount %d   recordCount %d" % (sc, rc))

    # record framing: count the magic u64
    pat = struct.pack("<Q", MAGIC)
    starts = []
    i = d.find(pat)
    while i >= 0:
        starts.append(i)
        i = d.find(pat, i + 1)
    print("   records opening with magic 0x%016X: %d (directory says %d)"
          % (MAGIC, len(starts), rc))

    # property scan
    per_slot = collections.Counter()
    tex = collections.Counter()
    for nh, sname in SLOTS.items():
        pat = struct.pack("<QI", nh, TEX_TYPE)
        i = d.find(pat)
        while i >= 0:
            per_slot[sname] += 1
            guid = d[i + 16 + 17:i + 16 + 33]
            tex[(sname, guid.hex())] += 1
            i = d.find(pat, i + 1)
    print("   texture bindings by slot: %s" % dict(per_slot))
    print("   distinct textures: %d" % len(tex))
    # resolve GUIDs through the cached whole-dump partition index when present
    gi = {}
    try:
        import json as _j
        import probe_tung_guidscan as G
        cp = os.path.join(G.CACHE, "..json")
        if os.path.isfile(cp):
            gi = _j.load(open(cp, encoding="utf-8"))
    except Exception:
        pass
    print("   top bindings (paths from the cached dump index):")
    for (sname, gh), cnt in tex.most_common(30):
        b = bytes.fromhex(gh)
        g = "%08x-%04x-%04x-%s-%s" % (struct.unpack_from("<IHH", b, 0)
                                      + (b[8:10].hex(), b[10:16].hex()))
        n = gi.get(g) or ", ".join(C.af_leaf(g)) or g
        if isinstance(n, str) and n.endswith(".ebx"):
            n = n[:-4]
        print("   x%-5d %-4s %s" % (cnt, sname, n))

    # world AABBs at magic+0x40 (holds for record 0; verify how often the
    # floats there look like a plausible min<max box inside the world)
    ok = 0
    ys = []
    xz = []
    for r in starts:
        try:
            mn = struct.unpack_from("<3f", d, r + 0x40)
            mx = struct.unpack_from("<3f", d, r + 0x50)
        except struct.error:
            continue
        if all(-2100 <= v <= 2100 for v in mn + mx) \
                and all(mn[j] <= mx[j] for j in range(3)) \
                and (mx[0] - mn[0]) < 1500 and (mx[2] - mn[2]) < 1500:
            ok += 1
            ys.append((mn[1], mx[1]))
            xz.append((mn[0], mn[2], mx[0], mx[2]))
    print("   plausible AABB at magic+0x40: %d / %d records" % (ok, len(starts)))
    if ys:
        print("   decal Y span %.1f .. %.1f ; X %.0f..%.0f  Z %.0f..%.0f"
              % (min(a for a, _b in ys), max(b for _a, b in ys),
                 min(a for a, _z, _c, _d in xz), max(c for _a, _z, c, _d in xz),
                 min(z for _a, z, _c, _d in xz), max(dd for _a, _z, _c, dd in xz)))


if __name__ == "__main__":
    main()
