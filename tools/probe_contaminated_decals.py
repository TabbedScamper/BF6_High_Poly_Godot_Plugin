"""MP_Contaminated's TerrainDecals -- with a chain-anchored record walk.

probe_tung_decals.py locates each record's tail by scanning for an
identity-transform anchor (two 1.0 floats).  On mp_contaminated that walk
STOPS at record 335 of 1053: from there on the records' transform region is
not identity-shaped and the anchor never matches (verified: record 336's tail
is 0x10F8 past its property block, far beyond the 0x400 scan window, and its
transform area holds non-1.0 values).

This probe anchors on the FirstIndex chain instead:
    record[i].FirstIndex == record[i-1].FirstIndex + record[i-1].TriCount * 3
and requires the u32 pair (expected_first, small tri) followed 8 bytes later
by two plausible f32 tilings.  That locates the tail t directly (t holds
FirstIndex, TriCount, tilings, AABB per TERRAIN.md 10) with no transform
assumption.  m = t + 0x70 as before.

READ-ONLY.  Usage:  probe_contaminated_decals.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
from probe_tung_decals import props_of, SLOT_NAMES   # noqa: E402


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def f32(d, o):
    return struct.unpack_from("<f", d, o)[0]


def parse(d):
    slot_count = u32(d, 0x10)
    o = 0x14
    slots = [d[o + i * 16:o + i * 16 + 16] for i in range(slot_count)]
    o += slot_count * 16
    rec_count = u32(d, o)
    o += 4
    recs = []
    expected_first = 0
    stop = None
    for i in range(rec_count):
        prop_size = u32(d, o)
        prop_end = o + 4 + prop_size
        # chain-anchored tail scan
        t = None
        p = prop_end
        limit = min(len(d) - 0x40, prop_end + 0x4000)
        while p < limit:
            if u32(d, p) == expected_first:
                tri = u32(d, p + 4)
                t0, t1 = f32(d, p + 0x0C), f32(d, p + 0x10)
                if 0 < tri < 100000 and 0.001 < abs(t0) < 10000 \
                        and 0.001 < abs(t1) < 10000:
                    t = p
                    break
            p += 4
        if t is None:
            stop = (i, o)
            break
        first, tri = u32(d, t), u32(d, t + 4)
        amin = struct.unpack_from("<3f", d, t + 0x20)
        amax = struct.unpack_from("<3f", d, t + 0x30)
        m = t + 0x70
        slot = u32(d, m + 8)
        props = props_of(d, o, prop_size)
        recs.append(dict(i=i, first=first, tri=tri, amin=amin, amax=amax,
                         slot=slot, props=props))
        expected_first = first + tri * 3
        o = m + 0x20
    return slots, rec_count, recs, stop


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_contaminated"
    td = T.terr_dir(level)
    dec = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
    d = C.read(dec)
    slots, rec_count, recs, stop = parse(d)
    empty = sum(1 for s in slots if s == b"\0" * 16)
    print("%s  %d bytes  slotCount %d (%d empty)  recordCount %d  parsed %d  stop %s"
          % (level, len(d), len(slots), empty, rec_count, len(recs),
             stop and ("record %d @0x%X" % stop)))
    per = collections.Counter(r["slot"] for r in recs)
    tri = collections.Counter()
    box = {}
    for r in recs:
        tri[r["slot"]] += r["tri"]
        b = box.setdefault(r["slot"], [1e9, 1e9, -1e9, -1e9])
        b[0] = min(b[0], r["amin"][0]); b[1] = min(b[1], r["amin"][2])
        b[2] = max(b[2], r["amax"][0]); b[3] = max(b[3], r["amax"][2])
    print("   slots used: %d" % len(per))
    for s, c in per.most_common():
        b = box[s]
        print("   slot %-3d recs %-5d tris %-8d  xz [%7.0f %7.0f .. %7.0f %7.0f]"
              % (s, c, tri[s], *b))
    # global decal extent
    ax0 = min(r["amin"][0] for r in recs); az0 = min(r["amin"][2] for r in recs)
    ax1 = max(r["amax"][0] for r in recs); az1 = max(r["amax"][2] for r in recs)
    ay0 = min(r["amin"][1] for r in recs); ay1 = max(r["amax"][1] for r in recs)
    print("   all-record AABB  x %7.0f..%7.0f  z %7.0f..%7.0f  y %6.1f..%6.1f"
          % (ax0, ax1, az0, az1, ay0, ay1))
    groups = collections.Counter()
    for r in recs:
        key = tuple(sorted((SLOT_NAMES.get(k, "%016X" % k), v[1])
                           for k, v in r["props"].items()
                           if isinstance(k, int) and isinstance(v, tuple) and v[0] == "tex"))
        groups[key] += 1
    print("   %d texture-set groups" % len(groups))
    for key, c in groups.most_common(12):
        names = [h for _s, h in key]
        print("   x%-4d %d textures" % (c, len(names)))


if __name__ == "__main__":
    main()
