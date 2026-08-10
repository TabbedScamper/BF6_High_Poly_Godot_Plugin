"""MP_Contaminated decomposition, round 2.

Hypothesis from round 1: every primary chunk is

    size = h * 149297 + pages * 2592 + 936 (+ rare variable extra)

and the colour tiles are NOT in the primary at all -- they are the k*17424
trailers of the PAIRED chunks (81 paired chunks are exactly 2 x 17424).

This probe: (1) verifies the 936 law over every primary chunk, (2) inspects the
936-byte trailer, (3) runs the BC7 mode census over the paired chunks' 17424
trailers, first vs second tile, and (4) mean-colours the first tile via BC7
mode-6 endpoints (probe_tung_bc7mode6 logic) to compare with the SDK overhead.

READ-ONLY.  Usage:  probe_contaminated_decomp2.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as CM       # noqa: E402

H = 149297
PS = 2592
TILE = 17424


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_contaminated"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = CM.chunk_dir(d, after)

    # ---- (1) the 936 law over primaries ------------------------------------
    exact = collections.Counter()
    irregular = []
    for n in nodes:
        g = n["g0"]
        if g is None:
            continue
        p = CM.chunk_path(g)
        if not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        hit = None
        for h in range(0, 3):
            rest = size - h * H - 936
            if rest >= 0 and rest % PS == 0:
                hit = (h, rest // PS)
                break
        if hit:
            exact[hit[0]] += 1
        else:
            irregular.append((n["key"], n["depth"], size))
    print("primaries: %d exact under size = h*%d + pages*%d + 936  (by h: %s)"
          % (sum(exact.values()), H, PS, dict(exact)))
    print("irregular primaries: %d" % len(irregular))
    for k, dep, size in irregular[:40]:
        # try to explain with h*H + pages*PS + 936 + extra
        best = None
        for h in range(0, 3):
            rest = size - h * H - 936
            if rest < 0:
                continue
            extra = rest % PS
            if best is None or extra < best[2]:
                best = (h, rest // PS, extra)
        print("   key 0x%-10X depth %d  size %8d   h=%d pages<=%d extra=%d"
              % (k, dep, size, best[0], best[1], best[2]))

    # ---- (2) what the 936-byte trailer looks like --------------------------
    print("\n== trailer bytes (last 936) of three regular primaries ==")
    shown = 0
    for n in nodes:
        g = n["g0"]
        if g is None:
            continue
        p = CM.chunk_path(g)
        if not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        ok = any((size - h * H - 936) >= 0 and (size - h * H - 936) % PS == 0
                 for h in range(3))
        if not ok or shown >= 3:
            continue
        buf = C.read(p)
        t = buf[-936:]
        # simple census
        zeros = t.count(0)
        distinct = len(set(t))
        print("node 0x%X depth %d size %d: trailer zeros %d/936, distinct byte values %d"
              % (n["key"], n["depth"], size, zeros, distinct))
        print(C.hexdump(t, 0, 64))
        print("   ...")
        print(C.hexdump(t, 936 - 32, 32))
        shown += 1

    # ---- (3) BC7 census over paired trailers -------------------------------
    print("\n== paired chunks: k*17424 trailer census ==")
    agg = [collections.Counter(), collections.Counter()]
    used = 0
    per_tile_distinct = [collections.Counter(), collections.Counter()]
    for n in nodes:
        g = n["g1"]
        if g is None:
            continue
        p = CM.chunk_path(g)
        if not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        # trailer = 2*17424 when size splits as pages*2592 (+ optional 189216s) + 2*17424
        rest = size - 2 * TILE
        okpre = None
        if rest >= 0:
            for pre in (0, 189216, 378432):
                r2 = rest - pre
                if r2 >= 0 and r2 % PS == 0:
                    okpre = pre
                    break
        if okpre is None:
            continue
        used += 1
        buf = C.read(p)
        tr = buf[-2 * TILE:]
        for i in (0, 1):
            tile = tr[i * TILE:(i + 1) * TILE]
            agg[i].update(CM.bc7_modes(tile))
            blocks16 = {tile[j:j + 16] for j in range(0, TILE, 16)}
            per_tile_distinct[i][min(len(blocks16), 2)] += 1
    def pct47(h):
        tot = sum(h.values())
        hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        return 100.0 * hi / tot if tot else 0.0
    print("paired chunks with a 2x17424 trailer: %d" % used)
    for i in (0, 1):
        print("  tile %d: %7d blocks, modes4-7 %5.1f%%, top %s, single-block-tiles %d"
              % (i, sum(agg[i].values()), pct47(agg[i]),
                 sorted(agg[i].items(), key=lambda kv: -kv[1])[:4],
                 per_tile_distinct[i].get(1, 0)))

    # ---- (4) mean colour of tile 0 via BC7 mode-6 endpoints ----------------
    print("\n== mean colour of tile 0 / tile 1 (BC7 mode-6 endpoint midpoints) ==")
    sums = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
    cnts = [0, 0]
    for n in nodes:
        g = n["g1"]
        if g is None:
            continue
        p = CM.chunk_path(g)
        if not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        rest = size - 2 * TILE
        ok = rest >= 0 and any((rest - pre) >= 0 and (rest - pre) % PS == 0
                               for pre in (0, 189216, 378432))
        if not ok:
            continue
        buf = C.read(p)
        tr = buf[-2 * TILE:]
        for i in (0, 1):
            tile = tr[i * TILE:(i + 1) * TILE]
            for j in range(0, TILE, 16):
                b = tile[j]
                if b & 0x7F == 0x40:      # mode 6: bit 6 lowest set
                    lo = int.from_bytes(tile[j:j + 16], "little")
                    bits = lo >> 7
                    ch = []
                    for c in range(4):
                        e0 = (bits >> (c * 14)) & 0x7F
                        e1 = (bits >> (c * 14 + 7)) & 0x7F
                        ch.append((e0 + e1) / 2.0 / 127.0)
                    for c in range(4):
                        sums[i][c] += ch[c]
                    cnts[i] += 1
    for i in (0, 1):
        if cnts[i]:
            print("  tile %d: %8d mode-6 blocks  mean RGBA (%.3f, %.3f, %.3f, %.3f)"
                  % (i, cnts[i], *(s / cnts[i] for s in sums[i])))


if __name__ == "__main__":
    main()
