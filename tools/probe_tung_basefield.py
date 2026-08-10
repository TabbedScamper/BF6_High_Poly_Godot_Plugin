"""Block 7: the per-texel material-pair raster, decoded and rasterised.

TERRAIN.md 7.2 (node grammar), 7.3 (nibble-RLE row codec), 7.4 (pair footer) and
8 (pair -> layer resolution). This is where a map's ground materials actually
live: on MP_Tungsten every layer that binds a texture is a BASE layer with no
weight page, so block 1 alone cannot say what the ground is made of.

Writes a PNG coloured by resolved layer index and prints per-layer coverage, so
"which layer is the river bed" is answered by looking rather than by inference.

Usage:  probe_tung_basefield.py [level] [--size 1024] [--out path]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colorrender as R     # noqa: E402

PALETTE = [
    (30, 30, 30), (220, 40, 40), (40, 200, 60), (60, 90, 240), (240, 200, 40),
    (220, 100, 220), (60, 220, 220), (250, 140, 40), (150, 90, 200), (0, 130, 90),
    (200, 200, 200), (120, 70, 30), (90, 160, 220), (170, 220, 90), (240, 120, 150),
    (110, 110, 40), (20, 90, 160), (180, 60, 20), (70, 200, 150), (200, 160, 110),
    (140, 0, 90), (0, 200, 200), (255, 255, 120), (100, 60, 140), (60, 140, 60),
    (210, 210, 90), (150, 30, 60), (30, 180, 110), (250, 250, 250), (255, 0, 255),
    (0, 255, 0), (0, 128, 255), (128, 0, 0),
]


def decode_row(rle, dim):
    """TERRAIN.md 7.3 nibble-RLE. Returns (texels, clean)."""
    out = bytearray(dim)
    src = 0
    if not rle:
        return out, False
    cur = rle[src]
    src += 1
    groups = 0
    x = 0
    while x < dim:
        # TERRAIN.md 7.3: `while (groupAccum * 2 < x)`. Writing `<=` here eats one
        # extra byte on the very first group and no row ever consumes cleanly.
        while groups * 2 < x:
            if src >= len(rle):
                return out, False
            b = rle[src]
            src += 1
            if b == cur:
                if src >= len(rle):
                    return out, False
                run = rle[src]
                src += 1
            else:
                run = 1
            cur = b
            groups += run
        out[x] = cur & 0xF
        if x + 1 < dim:
            out[x + 1] = cur >> 4
        x += 2
    return out, src == len(rle)


def walk(d, base, size, dim):
    """Pre-order quadtree; returns {key: (rows, ok)}."""
    end = base + size
    out = {}
    bad = [0]

    def node(o, key):
        has_data = d[o]
        has_pers = d[o + 1]
        o += 2
        if has_data and has_pers:
            sz = struct.unpack_from("<i", d, o)[0]
            o += 4
            payload = d[o:o + sz]
            o += sz
            rowsz = struct.unpack_from("<%dH" % dim, d, o)
            o += dim * 2
            rows = []
            p = 0
            for rs in rowsz:
                r, ok = decode_row(payload[p:p + rs], dim)
                if not ok:
                    bad[0] += 1
                rows.append(r)
                p += rs
            out[key] = rows
        hc = d[o]
        o += 1
        if hc:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    e = node(base + 0x24, 3)
    return out, e - end, bad[0]


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    out_png = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "%s_base.png" % level)

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    b7 = [(o, s) for t, o, s in blocks if t == 7][0]
    off, bsz = b7
    dim = struct.unpack_from("<I", d, off)[0]
    lo = struct.unpack_from("<4f", d, off + 8)
    n, entries, bg = T.raster_footer(d, off, bsz)
    nodes, slack, bad = walk(d, off, bsz, dim)
    print("%s block 7: dim=%d nodes=%d slack=%d badrows=%d pairs=%d bg=0x%08X"
          % (level, dim, len(nodes), slack, bad, n, bg))
    print("   coverage %s" % (lo,))

    # --- lists for pair resolution (TERRAIN.md 8) --------------------------
    painted = basec = None
    for t, o, s in blocks:
        if t == 1:
            _sh, painted, basec, _a, _b, _c = T.splat_walk(d, o, s)
    full_list = sorted(set(painted) | set(basec))
    base_list = sorted(basec)
    # linked children from the VisualTerrain record
    v = C.read(T._res(td, ".VisualTerrain"))
    i = 0
    strs_end = None
    while i < len(v):
        if 32 <= v[i] < 127:
            j = i
            while j < len(v) and 32 <= v[j] < 127:
                j += 1
            if j - i >= 16 and b"/" in v[i:j]:
                p = i
                while True:
                    e = v.find(b"\0", p)
                    if e < 0:
                        break
                    t2 = v[p:e]
                    if not t2 or not all(32 <= c < 127 for c in t2):
                        break
                    p = e + 1
                strs_end = p
                break
            i = j
        else:
            i += 1
    cnt = struct.unpack_from("<I", v, strs_end + 8)[0]
    linked = []
    p = strs_end + 12
    for k in range(cnt):
        lt = struct.unpack_from("<I", v, p + 1)[0]
        if lt != 0xFFFFFFFF:
            linked.append(k)
        p += 5
    lists = {0: full_list, 1: base_list, 2: sorted(linked)}
    print("   list0 (all layers) %s" % full_list)
    print("   list1 (base/no-page) %s" % base_list)
    print("   list2 (linked)      %s" % lists[2])

    def resolve(e):
        if e == 0:
            return None
        X = (e >> 8) & 0xFF
        Y = (e >> 16) & 0xFF
        lst = lists.get(Y & 0xF, full_list)
        for nib in (X & 0xF, X >> 4):
            if nib != 15 and nib < len(lst):
                return lst[nib]
        return None

    table = [resolve(e) for e in entries]
    print("   pair -> layer: %s" % {i: table[i] for i in range(len(table))})
    print("   background -> L%s" % resolve(bg))

    # --- rasterise ---------------------------------------------------------
    img = bytearray(size * size * 3)
    bgl = resolve(bg)
    if bgl is not None:
        c = PALETTE[bgl % len(PALETTE)]
        for i in range(size * size):
            img[i * 3:i * 3 + 3] = bytes(c)
    counts = collections.Counter()
    for key in sorted(nodes, key=lambda k: len(hex(k))):
        rows = nodes[key]
        x0w, z0w, x1w, z1w = R.bounds_of(key, (lo[0], lo[1]), (lo[2], lo[3]))
        px0 = int((x0w - lo[0]) / (lo[2] - lo[0]) * size)
        pz0 = int((z0w - lo[1]) / (lo[3] - lo[1]) * size)
        pw = max(1, int((x1w - x0w) / (lo[2] - lo[0]) * size))
        ph = max(1, int((z1w - z0w) / (lo[3] - lo[1]) * size))
        for dz in range(ph):
            sr = rows[int(dz / ph * dim)]
            for dx in range(pw):
                val = sr[int(dx / pw * dim)]
                lay = table[val] if val < len(table) else None
                if lay is None:
                    continue
                px, pz = px0 + dx, pz0 + dz
                if 0 <= px < size and 0 <= pz < size:
                    di = (pz * size + px) * 3
                    img[di:di + 3] = bytes(PALETTE[lay % len(PALETTE)])
        for r in rows:
            for vv in r:
                counts[table[vv] if vv < len(table) else None] += 1
    R.write_png(out_png, size, size, img)
    tot = sum(counts.values())
    print("   texel share by resolved layer (all levels pooled):")
    for lay, c in counts.most_common():
        print("      L%-4s %8d  %5.1f%%  colour %s"
              % (lay, c, 100.0 * c / tot,
                 PALETTE[lay % len(PALETTE)] if lay is not None else "-"))
    print("   wrote %s" % out_png)


if __name__ == "__main__":
    main()
