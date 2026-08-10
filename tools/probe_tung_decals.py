"""The level's TerrainDecals resource: how many records, what they bind, and
where they sit -- specifically, what is drawn over the river bed.

TERRAIN.md 10. The record tail is located by the documented anchor scan; every
record's `FirstIndex == prevFirstIndex + prevTriCount*3` chain is validated, so
a slipped frame shows up as a broken chain rather than as plausible garbage.

Usage:  probe_tung_decals.py [level] [--slot N] [--box x0 z0 x1 z1]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def f32(d, o):
    return struct.unpack_from("<f", d, o)[0]


SLOT_NAMES = {
    0x399AC0336ACFE03C: "_cv",
    0x567A9BC35CCBB1B2: "_nhs",
    0x3A411B3E209FC9E2: "_ao",
    0x3810287D4CE70B49: "_op",
}


def props_of(d, o, prop_size):
    """TERRAIN.md 10.3. Entries start at PropOffset+8 and run to
    PropOffset+4+propSize; each is [u64 nameHash][u32 typeId][u16][u16] then a
    type-dependent payload. Returns {nameHash: value}."""
    out = {}
    p = o + 8
    end = o + 4 + prop_size
    while p + 16 <= end:
        nh = struct.unpack_from("<Q", d, p)[0]
        ty = u32(d, p + 8)
        p += 16
        if ty == 0xCC84D53D:
            cnt = d[p]
            guid = d[p + 17:p + 33]
            out[nh] = ("tex", guid.hex(), cnt)
            p += 33
        elif ty == 0x14A0B1C1:
            n = u32(d, p)
            out[nh] = ("f32", struct.unpack_from("<%df" % n, d, p + 4))
            p += 4 + 4 * n
        elif ty == 0x25F81AF1:
            n = u32(d, p)
            out[nh] = ("vec3", struct.unpack_from("<%df" % (3 * n), d, p + 4))
            p += 4 + 12 * n
        else:
            out["_unknown_type_%08X" % ty] = True
            break
    return out


def parse(d):
    slot_count = u32(d, 0x10)
    assert 0 < slot_count <= 4096, "bad slotCount %d" % slot_count
    o = 0x14
    slots = []
    for i in range(slot_count):
        slots.append(d[o:o + 16])
        o += 16
    rec_count = u32(d, o)
    o += 4
    recs = []
    prev_first = prev_tri = 0
    broken = 0
    for i in range(rec_count):
        prop_size = u32(d, o)
        prop_end = o + 4 + prop_size
        m = None
        p = prop_end
        limit = min(len(d) - 0x24, prop_end + 0x400)
        while p < limit:
            if (abs(f32(d, p) - 1.0) < 1e-6 and abs(f32(d, p + 0x14) - 1.0) < 1e-6
                    and struct.unpack_from("<Q", d, p + 0x18)[0] == 0):
                m = p
                break
            p += 4
        if m is None:
            broken += 1
            break
        t = m - 0x70
        first = u32(d, t)
        tri = u32(d, t + 4)
        til0 = f32(d, t + 0x0C)
        til1 = f32(d, t + 0x10)
        amin = struct.unpack_from("<3f", d, t + 0x20)
        amax = struct.unpack_from("<3f", d, t + 0x30)
        slot = u32(d, m + 8)
        vbo = u32(d, m + 12)
        vbs = u32(d, m + 16)
        ok = (first == prev_first + prev_tri * 3)
        props = props_of(d, o, prop_size)
        recs.append(dict(props=props, i=i, first=first, tri=tri, t0=til0, t1=til1,
                         amin=amin, amax=amax, slot=slot, vbo=vbo, vbs=vbs,
                         chain=ok, prop_size=prop_size))
        prev_first, prev_tri = first, tri
        o = m + 0x20
    return slots, rec_count, recs, broken


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
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
    slots, rec_count, recs, broken = parse(d)
    empty = sum(1 for s in slots if s == b"\0" * 16)
    print("%s  %s  %d bytes" % (level, os.path.basename(dec), len(d)))
    print("   slotCount %d (%d empty, %d with a GUID)   recordCount %d, parsed %d, "
          "chain breaks %d" % (len(slots), empty, len(slots) - empty, rec_count,
                               len(recs), sum(1 for r in recs if not r["chain"])))
    per = collections.Counter(r["slot"] for r in recs)
    tri = collections.Counter()
    box = {}
    for r in recs:
        tri[r["slot"]] += r["tri"]
        b = box.setdefault(r["slot"], [1e9, 1e9, -1e9, -1e9, 1e9, -1e9])
        b[0] = min(b[0], r["amin"][0]); b[1] = min(b[1], r["amin"][2])
        b[2] = max(b[2], r["amax"][0]); b[3] = max(b[3], r["amax"][2])
        b[4] = min(b[4], r["amin"][1]); b[5] = max(b[5], r["amax"][1])
    print("   %d distinct asset slots used" % len(per))
    print("   %-5s %-6s %-9s %-8s %s" % ("slot", "recs", "tris", "guid?", "world AABB  x0 z0 x1 z1 | y0 y1"))
    for s, c in per.most_common():
        g = slots[s] if s < len(slots) else b""
        has = "GUID" if g and g != b"\0" * 16 else "empty->L%02d" % s
        b = box[s]
        print("   %-5d %-6d %-9d %-11s %7.0f %7.0f %7.0f %7.0f | %6.1f %6.1f"
              % (s, c, tri[s], has, b[0], b[1], b[2], b[3], b[4], b[5]))

    groups = collections.Counter()
    texnames = collections.Counter()
    for r in recs:
        key = tuple(sorted((SLOT_NAMES.get(k, "%016X" % k), v[1])
                           for k, v in r["props"].items()
                           if isinstance(k, int) and isinstance(v, tuple) and v[0] == "tex"))
        groups[key] += 1
        for k, v in r["props"].items():
            if isinstance(v, tuple) and v[0] == "tex":
                texnames[(SLOT_NAMES.get(k, "%016X" % k), v[1])] += 1
    print("   %d distinct texture-set groups over %d records" % (len(groups), len(recs)))
    gi = {}
    try:
        import probe_tung_guidscan as G
        import json as _j
        cp = os.path.join(G.CACHE, "..json")
        if os.path.isfile(cp):
            gi = _j.load(open(cp, encoding="utf-8"))
    except Exception:
        pass
    def gname(hexg):
        b = bytes.fromhex(hexg)
        g = "%08x-%04x-%04x-%s-%s" % (struct.unpack_from("<IHH", b, 0) +
                                      (b[8:10].hex(), b[10:16].hex()))
        n = gi.get(g)
        return (n[:-4] if n and n.endswith(".ebx") else n) or g
    for key, c in groups.most_common(25):
        print("   x%-5d %s" % (c, ", ".join("%s=%s" % (s_, gname(h)) for s_, h in key)))

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
