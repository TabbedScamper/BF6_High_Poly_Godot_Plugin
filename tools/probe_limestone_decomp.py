"""MP_Limestone chunk decomposition — the detect_layout verification row.

For every streaming chunk (primary and paired) this decomposes

    size = heightPrefix + storedPages x PAGE + trailer

with PAGE = 4356 (raw 66x66 -- the bf6_splat.py per-map table and the
MAP-TUNGSTEN.md exact-decomposition method both put mp_limestone in the 4356
set), heightPrefix a sum drawn from {149297 (xs=265), 39919 (xs=137)}, and the
per-node stored-page count m read DIRECTLY from block 1's node header
(bf6_splat.py: NODE := u16 n; u16 m; u16 0; ...records).

It then reports the distinct trailer values and the BC7 mode histogram of the
trailer's first and last tile (and, for the single-tile case, of the final
4,624 bytes -- the slice the plugin's current color_tiles() would read).

READ-ONLY against the dump. Usage: probe_limestone_decomp.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PAGE = 4356
H265 = 149297
H137 = 39919
TILES = (4624, 17424, 67600)         # 68^2, 132^2, 260^2 BC7


def splat_page_counts(d, base, size):
    """{node_key: m} from block 1, m = the node header's own page count."""
    end = base + size
    out = {}

    def node(o, key):
        n = struct.unpack_from("<H", d, o)[0]
        m = struct.unpack_from("<H", d, o + 2)[0]
        out[key] = m
        o += 6 + n * 33
        if n == 0:
            return o + 1
        o += 1
        hc = d[o]
        o += 1
        if o < end:
            o += 1
        if hc:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    node(base + 0x3D, 3)
    return out


def prefixes():
    """All plausible height prefixes: sums of 0..2 of each LOD payload."""
    out = set()
    for a in range(3):
        for b in range(3):
            out.add(a * H265 + b * H137)
    return sorted(out)


def decompose(sz, m):
    """size -> (prefix, pages_used, trailer) or None. Pages fixed = m."""
    body = m * PAGE
    for pre in prefixes():
        tr = sz - pre - body
        if tr == 0:
            return pre, m, 0
        if tr > 0 and (tr in TILES or any(tr % t == 0 and tr // t <= 8
                                          for t in TILES)):
            return pre, m, tr
    return None


def bc7_hist(buf):
    h = collections.Counter()
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        if b == 0:
            h["inv"] += 1
            continue
        mo = 0
        while not (b >> mo) & 1:
            mo += 1
        h[mo] += 1
    return h


def pct47(h):
    tot = sum(h.values())
    hi = sum(c for k, c in h.items() if isinstance(k, int) and k >= 4)
    return 100.0 * hi / tot if tot else 0.0


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_limestone"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)
    pc = None
    for t, off, size in blocks:
        if t == 1:
            pc = splat_page_counts(d, off, size)
    print("%s: %d directory nodes, %d block-1 nodes" % (level, len(nodes), len(pc)))

    # ---- primary chunks ----------------------------------------------------
    combos = collections.Counter()
    trailers = collections.Counter()
    fails = []
    first_h = collections.Counter()
    last_h = collections.Counter()
    tail4624_h = collections.Counter()
    per_tile_distinct = collections.Counter()
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            fails.append((n["key"], "missing", n["size0"]))
            continue
        sz = os.path.getsize(p)
        m = pc.get(n["key"], 0)
        r = decompose(sz, m)
        if r is None:
            fails.append((n["key"], "no-fit sz=%d m=%d" % (sz, m), sz))
            continue
        pre, mm, tr = r
        combos[(pre, tr)] += 1
        trailers[tr] += 1
        if tr:
            buf = C.read(p)
            trail = buf[len(buf) - tr:]
            # tile size: the largest TILE that divides tr
            tile = max(t for t in TILES if tr % t == 0)
            k = tr // tile
            fh = bc7_hist(trail[:tile])
            lh = bc7_hist(trail[(k - 1) * tile:])
            first_h.update(fh)
            last_h.update(lh)
            tail4624_h.update(bc7_hist(trail[-4624:]))
            blocks16 = set()
            for i in range(0, tile, 16):
                blocks16.add(bytes(trail[i:i + 16]))
            per_tile_distinct[len(blocks16) > tile // 16 // 4] += 1
    print("primary decompositions (heightPrefix, trailer) -> count:")
    for (pre, tr), c in sorted(combos.items()):
        pn = []
        rest = pre
        for lbl, v in (("149297", H265), ("39919", H137)):
            while rest >= v and rest % v in (0, H137 % v if v == H265 else 0) \
                    and rest - v >= 0 and (rest - v) % 1 == 0:
                # simple greedy label
                if rest >= v and (rest - v) in [a * H265 + b * H137
                                                for a in range(3) for b in range(3)]:
                    pn.append(lbl)
                    rest -= v
                else:
                    break
        print("   prefix %7d (%s)  trailer %6d  x%d"
              % (pre, "+".join(pn) or "0", tr, c))
    if fails:
        print("   FAILED to decompose: %s" % fails[:10])
    print("distinct trailers: %s" % dict(trailers))
    print("first-tile  BC7 modes: %s   modes4-7 %.2f%%"
          % (dict(sorted(first_h.items(), key=lambda kv: -kv[1])), pct47(first_h)))
    print("last-tile   BC7 modes: %s   modes4-7 %.2f%%"
          % (dict(sorted(last_h.items(), key=lambda kv: -kv[1])), pct47(last_h)))
    print("tail-4624B  BC7 modes: %s   modes4-7 %.2f%%   (what color_tiles() reads)"
          % (dict(sorted(tail4624_h.items(), key=lambda kv: -kv[1])), pct47(tail4624_h)))
    print("tiles with >25%% distinct 16B blocks: %s" % dict(per_tile_distinct))

    # ---- paired chunks -----------------------------------------------------
    pcombo = collections.Counter()
    pfail = []
    for n in nodes:
        if not n["g1"]:
            continue
        p = M.chunk_path(n["g1"])
        if not os.path.isfile(p):
            pfail.append((n["key"], "missing"))
            continue
        sz = os.path.getsize(p)
        kids = [(n["key"] << 4) | i for i in range(4)]
        mk = sum(pc.get(k, 0) for k in kids)
        # paired chunks: children's pages + one colour tile per child, no heights
        for ntiles in (4, 0, 1, 2, 3, 8):
            for tile in TILES:
                if sz == mk * PAGE + ntiles * tile:
                    pcombo[(mk, ntiles, tile)] += 1
                    break
            else:
                continue
            break
        else:
            pfail.append((n["key"], "no-fit sz=%d mk=%d" % (sz, mk)))
    print("paired decompositions (sum child pages, tiles, tile_size) -> count:")
    for kk, c in sorted(pcombo.items()):
        print("   pages %3d  tiles %d x %d  x%d" % (kk[0], kk[1], kk[2], c))
    if pfail:
        print("   paired FAILED: %s" % pfail[:10])


if __name__ == "__main__":
    main()
