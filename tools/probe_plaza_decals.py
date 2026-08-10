"""MP_Plaza's TerrainDecals — which ship a DIFFERENT record layout.

probe_tung_decals.py (the dumbo-verified TERRAIN.md §10.2 layout,
`[u32 propSize][props][pad][0x90 tail]`) parses 0 of plaza's 485 records: its
anchor scan never fires. Plaza's records are GUID-headed and tail-FIRST:

    +0x00  16 B  decal-asset GUID (joins the slot table by VALUE, not index)
    +0x10  0x10  zeros
    +0x20  u32   FirstIndex      chain: FirstIndex == prev + prevTri*3 (kept!)
    +0x24  u32   TriCount
    +0x28  f32   (~0.0476 on every record — unknown)
    +0x2C  f32   Tiling0
    +0x30  f32   Tiling1
    +0x40  f32x3 AabbMin
    +0x50  f32x3 AabbMax
    +0x60  f32x4 node-aligned min (multiples of the streaming-node size)
    +0x70  f32x4 node-aligned max
    +0x80  f32x4 (minX minZ maxX maxZ repeat)
    +0x90  ...   render params (leading f32 1.0, 01 01 01 01, vb fields)
    +0xB0  u32   propSize
    +0xB4  props (nameHash/typeId entries; same hash values as §10.3)
    next record at +0xB4 + propSize

Usage:  probe_plaza_decals.py [level] [--box x0 z0 x1 z1]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402

SLOT_NAMES = {
    0x399AC0336ACFE03C: "_cv",
    0x567A9BC35CCBB1B2: "_nhs",
    0x3A411B3E209FC9E2: "_ao",
    0x3810287D4CE70B49: "_op",
}


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def parse(d):
    slot_count = u32(d, 0x10)
    o = 0x14
    slots = [d[o + i * 16:o + i * 16 + 16] for i in range(slot_count)]
    o += slot_count * 16
    rec_count = u32(d, o)
    o += 4
    recs = []
    prev_first = prev_tri = 0
    breaks = 0
    for i in range(rec_count):
        g = d[o:o + 16]
        first = u32(d, o + 0x20)
        tri = u32(d, o + 0x24)
        t0 = struct.unpack_from("<f", d, o + 0x2C)[0]
        t1 = struct.unpack_from("<f", d, o + 0x30)[0]
        amin = struct.unpack_from("<3f", d, o + 0x40)
        amax = struct.unpack_from("<3f", d, o + 0x50)
        psize = u32(d, o + 0xB0)
        # texture refs: scan the prop bytes for the known u64 slot hashes.
        # Entry = [u64 hash][u32 typeId][u16][u16] then payload
        # u8 count + 16 B pair + 16 B GUID at payload+17 (TERRAIN.md 10.3),
        # so the GUID sits at entry+16+17 = entry+33.
        props = {}
        pb = d[o + 0xB4:o + 0xB4 + psize]
        for nh, nm in SLOT_NAMES.items():
            hx = struct.pack("<Q", nh)
            j = pb.find(hx)
            if j >= 0 and j + 49 <= len(pb):
                ty = struct.unpack_from("<I", pb, j + 8)[0]
                if ty == 0xCC84D53D:
                    props[nm] = pb[j + 33:j + 49].hex()
        chain_ok = (first == prev_first + prev_tri * 3)
        if not chain_ok:
            breaks += 1
        recs.append(dict(i=i, guid=g, first=first, tri=tri, t0=t0, t1=t1,
                         amin=amin, amax=amax, psize=psize, props=props,
                         chain=chain_ok))
        prev_first, prev_tri = first, tri
        o += 0xB4 + psize
    return slots, rec_count, recs, breaks, o


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_plaza"
    td = T.terr_dir(level)
    dec = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
    d = C.read(dec)
    slots, rec_count, recs, breaks, end = parse(d)
    print("%s  %d bytes, slotCount %d, recordCount %d, parsed %d, chain breaks %d"
          % (level, len(d), len(slots), rec_count, len(recs), breaks))
    print("   record stream ends at 0x%X of 0x%X" % (end, len(d)))

    slot_ix = {s.hex(): i for i, s in enumerate(slots) if s != b"\0" * 16}
    per_guid = collections.Counter()
    tris = collections.Counter()
    box = {}
    for r in recs:
        g = r["guid"].hex()
        per_guid[g] += 1
        tris[g] += r["tri"]
        b = box.setdefault(g, [1e9, 1e9, -1e9, -1e9])
        b[0] = min(b[0], r["amin"][0]); b[1] = min(b[1], r["amin"][2])
        b[2] = max(b[2], r["amax"][0]); b[3] = max(b[3], r["amax"][2])
    print("   %d distinct record GUIDs; slot-table join:" % len(per_guid))
    for g, c in per_guid.most_common():
        b = box[g]
        j = slot_ix.get(g, None)
        print("   %-9s recs %-4d tris %-7d  [%6.0f %6.0f .. %6.0f %6.0f]  %s"
              % ("slot %s" % j if j is not None else "NO-SLOT", c, tris[g],
                 b[0], b[1], b[2], b[3], g[:16]))

    groups = collections.Counter()
    for r in recs:
        groups[tuple(sorted(r["props"].items()))] += 1
    print("   %d distinct texture-set groups:" % len(groups))
    gi = {}
    try:
        import json as _j
        import probe_tung_guidscan as G
        cp = os.path.join(G.CACHE, "..json")
        if os.path.isfile(cp):
            gi = _j.load(open(cp, encoding="utf-8"))
    except Exception:
        pass

    def gname(hexg):
        b = bytes.fromhex(hexg)
        g = "%08x-%04x-%04x-%s-%s" % (struct.unpack_from("<IHH", b, 0)
                                      + (b[8:10].hex(), b[10:16].hex()))
        n = gi.get(g)
        return (n[:-4] if n and n.endswith(".ebx") else n) or g

    for key, c in groups.most_common(25):
        print("   x%-4d %s" % (c, ", ".join("%s=%s" % (s_, gname(h))
                                            for s_, h in key) or "(no textures)"))

    if "--box" in sys.argv:
        i = sys.argv.index("--box")
        x0, z0, x1, z1 = [float(v) for v in sys.argv[i + 1:i + 5]]
        hits = collections.Counter()
        for r in recs:
            if (r["amax"][0] >= x0 and r["amin"][0] <= x1
                    and r["amax"][2] >= z0 and r["amin"][2] <= z1):
                hits[r["guid"].hex()[:8]] += 1
        print("   decals overlapping [%g %g .. %g %g]: %s"
              % (x0, z0, x1, z1, hits.most_common()))


if __name__ == "__main__":
    main()
