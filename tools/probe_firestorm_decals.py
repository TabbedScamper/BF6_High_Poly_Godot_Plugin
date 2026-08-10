"""MP_FireStorm's TerrainDecals — the Tungsten/dumbo parser fails here; this one
locates each record tail by the FirstIndex chain invariant instead of the
1.0/1.0/0 matrix anchor.

WHY: probe_tung_decals.py parses 0 of MP_FireStorm's 505 records.
Two MEASURED differences from TERRAIN.md §10.2 on this map:

  * record 0 does NOT start with [u32 propSize]; its head is
    [u64 0xAEF8B6DE64DD8673][u32 0xEEFD3D7A][24 zero bytes] (32 bytes total),
    which reinterpreted as a propSize is ~1.7 GB and aborts the documented walk;
  * records are NOT 4-byte aligned here: propSize can be odd (record 208 has
    propSize 0x149), which puts every later record tail on an odd byte offset.
    probe_tung_decals.py's anchor scan steps 4 bytes at a time and can never
    land on an unaligned anchor. Scans must step 1 byte.

The chain invariant `FirstIndex == prevFirstIndex + prevTriCount*3` (§10.2) is
map-independent, so the tail is found by byte-stepped scanning for the EXPECTED
FirstIndex with AABB sanity checks, and the property stream is then parsed
forward from the record start when it has the documented
[u32 propSize][u32 hdr][entries] shape. Tail layout itself (offsets
+0x00/+0x04/+0x20/+0x30, slot at M+8, next record at M+0x20) verifies
unchanged.

Usage:  probe_firestorm_decals.py [level] [--box x0 z0 x1 z1]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
from probe_tung_decals import SLOT_NAMES, props_of   # noqa: E402


def parse(d, world=4096.0, ymax=2048.0):
    u32 = lambda o: struct.unpack_from("<I", d, o)[0]
    f32 = lambda o: struct.unpack_from("<f", d, o)[0]
    sc = u32(0x10)
    assert 0 < sc <= 4096
    slots = [d[0x14 + i * 16:0x14 + i * 16 + 16] for i in range(sc)]
    o = 0x14 + sc * 16
    rc = u32(o)
    o += 4
    recs, fails = [], 0
    exp_first = 0
    while len(recs) < rc:
        t = None
        p = o + 4
        limit = min(len(d) - 0x90, o + 0x4000)
        while p < limit:
            if u32(p) == exp_first:
                tri = u32(p + 4)
                if 0 < tri < 2_000_000:
                    mn = struct.unpack_from("<3f", d, p + 0x20)
                    mx = struct.unpack_from("<3f", d, p + 0x30)
                    if (all(abs(v) <= world * 1.01 for v in (mn[0], mn[2], mx[0], mx[2]))
                            and -ymax <= mn[1] <= mx[1] <= ymax
                            and mn[0] <= mx[0] and mn[2] <= mx[2]):
                        t = p
                        break
            p += 1
        if t is None:
            fails += 1
            print("   tail scan FAILED at record %d offset 0x%X (expected FirstIndex %d)"
                  % (len(recs), o, exp_first))
            break
        m = t + 0x70
        tri = u32(t + 4)
        props = {}
        ps = u32(o)
        # standard head?  [u32 propSize][u32 hdr][16B-aligned entries]
        if 0 < ps < 0x4000 and o + 4 + ps <= t:
            props = props_of(d, o, ps)
        recs.append(dict(i=len(recs), first=exp_first, tri=tri,
                         amin=struct.unpack_from("<3f", d, t + 0x20),
                         amax=struct.unpack_from("<3f", d, t + 0x30),
                         t0=f32(t + 0x0C), t1=f32(t + 0x10),
                         slot=u32(m + 8), vbo=u32(m + 12), vbs=u32(m + 16),
                         anchor1=(abs(f32(m) - 1.0) < 1e-6
                                  and abs(f32(m + 0x14) - 1.0) < 1e-6),
                         head=t - o, props=props))
        exp_first += tri * 3
        o = m + 0x20
    return slots, rc, recs, fails, o


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_firestorm"
    td = T.terr_dir(level)
    dec = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
    if dec is None:
        print("no TerrainDecals under", td)
        return
    d = C.read(dec)
    slots, rc, recs, fails, end = parse(d)
    empty = sum(1 for s in slots if s == b"\0" * 16)
    print("%s  %d bytes  slotCount %d (%d with GUID)" % (
        os.path.basename(dec), len(d), len(slots), len(slots) - empty))
    print("   recordCount %d, parsed %d, tail-scan fails %d, records w/o 1.0-anchor %d"
          % (rc, len(recs), fails, sum(1 for r in recs if not r["anchor1"])))
    vb = (end + 0xFFF) & ~0xFFF
    vbs_sum = sum(r["vbs"] for r in recs)
    print("   record stream ends 0x%X; VB @ 0x%X + 0x%X -> 0x%X of 0x%X file"
          % (end, vb, vbs_sum, vb + vbs_sum, len(d)))

    per = collections.Counter(r["slot"] for r in recs)
    tri = collections.Counter()
    box = {}
    for r in recs:
        tri[r["slot"]] += r["tri"]
        b = box.setdefault(r["slot"], [1e9, 1e9, -1e9, -1e9, 1e9, -1e9])
        b[0] = min(b[0], r["amin"][0]); b[1] = min(b[1], r["amin"][2])
        b[2] = max(b[2], r["amax"][0]); b[3] = max(b[3], r["amax"][2])
        b[4] = min(b[4], r["amin"][1]); b[5] = max(b[5], r["amax"][1])
    print("   %-5s %-6s %-9s %-11s %s" % ("slot", "recs", "tris", "guid?",
                                          "world AABB  x0 z0 x1 z1 | y0 y1"))
    for s, c in per.most_common():
        g = slots[s] if s < len(slots) else b""
        has = "GUID" if g and g != b"\0" * 16 else \
            ("empty->L%02d" % s if s < len(slots) else "OOB")
        b = box[s]
        print("   %-5d %-6d %-9d %-11s %7.0f %7.0f %7.0f %7.0f | %6.1f %6.1f"
              % (s, c, tri[s], has, b[0], b[1], b[2], b[3], b[4], b[5]))

    groups = collections.Counter()
    for r in recs:
        key = tuple(sorted((SLOT_NAMES.get(k, "%016X" % k), v[1])
                           for k, v in r["props"].items()
                           if isinstance(k, int) and isinstance(v, tuple)
                           and v[0] == "tex"))
        groups[key] += 1

    gi = {}
    try:
        import json as _j
        import probe_tung_guidscan as G
        cp = os.path.join(G.CACHE, "..json")   # cache of a full-dump scan
        if os.path.isfile(cp):
            gi = _j.load(open(cp, encoding="utf-8"))
    except Exception:
        pass

    def gname(hexg):
        b = bytes.fromhex(hexg)
        g = "%08x-%04x-%04x-%s-%s" % (struct.unpack_from("<IHH", b, 0)
                                      + (b[8:10].hex(), b[10:16].hex()))
        n = gi.get(g)
        if n:
            return n[:-4] if n.endswith(".ebx") else n
        leafs = C.af_leaf(g)
        return leafs[0] if leafs else g
    print("   %d distinct texture-set groups" % len(groups))
    for key, c in groups.most_common(25):
        print("   x%-5d %s" % (c, ", ".join("%s=%s" % (s_, gname(h))
                                            for s_, h in key) or "(prop-less)"))

    if "--box" in sys.argv:
        i = sys.argv.index("--box")
        x0, z0, x1, z1 = [float(v) for v in sys.argv[i + 1:i + 5]]
        hits = collections.Counter()
        for r in recs:
            if (r["amax"][0] >= x0 and r["amin"][0] <= x1
                    and r["amax"][2] >= z0 and r["amin"][2] <= z1):
                hits[r["slot"]] += 1
        print("   decals overlapping [%g %g .. %g %g]: %s"
              % (x0, z0, x1, z1, hits.most_common()))


if __name__ == "__main__":
    main()
