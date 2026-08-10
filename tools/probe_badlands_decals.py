"""MP_Badlands' TerrainDecals -- which parses with a DIFFERENT record framing
than the tungsten probe assumed.

MEASURED on mp_badlands: each record is

    +0x00  u64  material-group hash   (nonzero here; zero on tungsten's rec 0)
    +0x08  u32  (constant per file)
    +0x0C  20 bytes zero
    +0x20  the block probe_tung_decals.py calls `t`:
           u32 FirstIndex, u32 TriCount, pad, f32 til0, f32 til1, ...
    +0x40  vec4 AabbMin   +0x50 vec4 AabbMax   (+0x60/+0x70 wider boxes)
    +0x80  f32 x0 z0 x1 z1 (2D box)
    +0x90  the anchor row (f32 1.0 ... +0x14 f32 1.0, +0x18 u64 0)
    +0x98  u32 slot   +0x9C u32 vbo   +0xA0 u32 vbs
    +0xB0  u32 propSize, u32 nProps, then the SAME property grammar as
           TERRAIN.md 10.3 (tex type 0xCC84D53D etc.), record ends at
           +0xB0+4+propSize.

probe_tung_decals.py enters this stream expecting [props][geometry] and dies on
record 0 because the leading u64 hash is read as a propSize.

Usage:  probe_badlands_decals.py [level] [--box x0 z0 x1 z1]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_decals as D        # noqa: E402

GEO = 0xB0


def parse(d):
    slot_count = D.u32(d, 0x10)
    o = 0x14
    slots = [d[o + 16 * i:o + 16 * i + 16] for i in range(slot_count)]
    o += 16 * slot_count
    rec_count = D.u32(d, o)
    o += 4
    recs = []
    prev_first = prev_tri = 0
    broken = 0
    for i in range(rec_count):
        if o + GEO + 8 > len(d):
            break
        # sanity: the anchor row must be where the framing says it is
        anchor_ok = (abs(D.f32(d, o + 0x90) - 1.0) < 1e-5
                     and abs(D.f32(d, o + 0x90 + 0x14) - 1.0) < 1e-5
                     and struct.unpack_from("<Q", d, o + 0x90 + 0x18)[0] == 0)
        first = D.u32(d, o + 0x20)
        tri = D.u32(d, o + 0x24)
        til0 = D.f32(d, o + 0x2C)
        til1 = D.f32(d, o + 0x30)
        amin = struct.unpack_from("<3f", d, o + 0x40)
        amax = struct.unpack_from("<3f", d, o + 0x50)
        slot = D.u32(d, o + 0x98)
        mat = struct.unpack_from("<Q", d, o)[0]
        prop_size = D.u32(d, o + 0xB0)
        props = D.props_of(d, o + 0xB0, prop_size + 4)
        chain = (first == prev_first + prev_tri * 3)
        recs.append(dict(i=i, mat=mat, first=first, tri=tri, t0=til0, t1=til1,
                         amin=amin, amax=amax, slot=slot, props=props,
                         anchor=anchor_ok, chain=chain))
        prev_first, prev_tri = first, tri
        o = o + GEO + 4 + prop_size
    return slots, rec_count, recs, o, broken


def guid_str(b):
    return "%08x-%04x-%04x-%s-%s" % (struct.unpack_from("<IHH", b, 0)
                                     + (b[8:10].hex(), b[10:16].hex()))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_badlands"
    td = T.terr_dir(level)
    dec = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
    d = C.read(dec)
    slots, rec_count, recs, end, broken = parse(d)
    print("%s  %d bytes  slotCount %d  recordCount %d" %
          (level, len(d), len(slots), rec_count))
    print("   parsed %d   anchor-ok %d   chain-ok %d   stream end 0x%X of 0x%X"
          % (len(recs), sum(r["anchor"] for r in recs),
             sum(r["chain"] for r in recs), end, len(d)))

    print("   slots with a GUID:")
    for i, s in enumerate(slots):
        if s != b"\0" * 16:
            print("      slot %2d  %s  -> %s" % (i, guid_str(s),
                  ", ".join(C.af_leaf(guid_str(s))) or "<not in _af>"))

    per = collections.Counter(r["slot"] for r in recs)
    tri = collections.Counter()
    box = {}
    for r in recs:
        tri[r["slot"]] += r["tri"]
        b = box.setdefault(r["slot"], [1e9, 1e9, -1e9, -1e9, 1e9, -1e9])
        b[0] = min(b[0], r["amin"][0]); b[1] = min(b[1], r["amin"][2])
        b[2] = max(b[2], r["amax"][0]); b[3] = max(b[3], r["amax"][2])
        b[4] = min(b[4], r["amin"][1]); b[5] = max(b[5], r["amax"][1])
    print("   %-5s %-6s %-9s %s" % ("slot", "recs", "tris", "world AABB x0 z0 x1 z1 | y0 y1"))
    for s, c in per.most_common():
        b = box[s]
        print("   %-5d %-6d %-9d %7.0f %7.0f %7.0f %7.0f | %6.1f %6.1f"
              % (s, c, tri[s], b[0], b[1], b[2], b[3], b[4], b[5]))

    groups = collections.Counter()
    for r in recs:
        key = tuple(sorted((D.SLOT_NAMES.get(k, "%016X" % k), v[1])
                           for k, v in r["props"].items()
                           if isinstance(k, int) and isinstance(v, tuple)
                           and v[0] == "tex"))
        groups[key] += 1
    print("   %d distinct texture-set groups" % len(groups))

    def gname(hexg):
        b = bytes.fromhex(hexg)
        g = guid_str(b)
        leaves = C.af_leaf(g)
        return leaves[0] if leaves else g
    for key, c in groups.most_common(25):
        print("   x%-5d %s" % (c, ", ".join("%s=%s" % (s_, gname(h))
                                            for s_, h in key)))

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

    zmax = max(r["amax"][2] for r in recs)
    zmin = min(r["amin"][2] for r in recs)
    xmax = max(r["amax"][0] for r in recs)
    xmin = min(r["amin"][0] for r in recs)
    print("   all-record extent  x %.0f..%.0f   z %.0f..%.0f"
          % (xmin, xmax, zmin, zmax))


if __name__ == "__main__":
    main()
