"""MP_Dumbo chunk decomposition — the verification row for the detect_layout fix.

For every streaming chunk (primary and paired), decompose

    size = heightPrefix + storedPages x PAGE + k x TILE

with PAGE = 2592 (dumbo's true page size, BC4 72x72 by the plugin's codec
table), TILE = 4624 (68^2 BC7) and heightPrefix in sums drawn from
{39919, 149297} (the established prefix set; 189216 = 39919 + 149297).

The page count is NOT free: it is predicted independently from block 1 — a
node's stored pages are its painted (weight-page) records — so each chunk has
ONE predicted decomposition and the probe checks it to the byte. The colour
tile candidates are then BC7-mode-tested (a real colour tile is ~100% modes
4-7; TERRAIN.md 5.3 / MAP-TUNGSTEN.md C2).

Usage:  probe_dumbo_decompose.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PAGE = 2592
TILE = 4624
HEIGHT = 149297          # dumbo xs=265 external height payload (= T.hf inline)
PREFIXES = [0, 39919, HEIGHT, 39919 + HEIGHT, 2 * HEIGHT]


def splat_per_node(d, base, size):
    """block 1 walked per node: key -> (painted records, base records)."""
    end = base + size
    per = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        painted = basec = 0
        for _ in range(rc):
            flags = struct.unpack_from("<H", d, o + 20)[0]
            if flags & 0x0100:
                basec += 1
            else:
                painted += 1
            o += 33
        per[key] = (painted, basec)
        if rc == 0:
            return o + 1
        o += 1
        has_children = d[o]
        o += 1
        if o < end:
            o += 1
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    node(base + 0x3D, 3)
    return per


def mode47(buf):
    h = M.bc7_modes(buf)
    tot = sum(h.values())
    hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
    return (100.0 * hi / tot) if tot else 0.0, h


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_dumbo"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)

    hkind = {}
    per_node = {}
    for t, off, sz in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            hn, _k, _s, _z = T.hf_walk(d, off, sz, h)
            hkind = {n[0]: n[4] for n in hn}
        elif t == 1:
            per_node = splat_per_node(d, off, sz)

    # A paired chunk holds its CHILDREN's data. Children are derived
    # arithmetically ((key<<4)|i): 16 of dumbo's paired chunks belong to
    # chunk-directory LEAF nodes whose children exist only in block 1
    # (341 block-1 nodes vs 277 chunk nodes = 64 = 16 x 4).
    kids = {n["key"]: [(n["key"] << 4) | i for i in range(4)] for n in nodes}

    classes = collections.Counter()
    fails = []
    histo_first = collections.Counter()
    histo_last = collections.Counter()
    n_first = n_last = 0

    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                continue
            size = os.path.getsize(p)
            if which == "primary":
                pages = per_node.get(n["key"], (0, 0))[0]
                hp = HEIGHT if hkind.get(n["key"]) == "External" else 0
            else:
                ck = kids.get(n["key"], [])
                pages = sum(per_node.get(k, (0, 0))[0] for k in ck)
                hp = sum(HEIGHT for k in ck if hkind.get(k) == "External")
            rest = size - hp - pages * PAGE
            k, r = divmod(rest, TILE) if rest >= 0 else (-1, rest)
            tag = (which, n["depth"], hkind.get(n["key"], "-"), hp, k,
                   "OK" if r == 0 and k >= 0 else "FAIL r=%d" % r)
            classes[tag] += 1
            if r != 0 or k < 0:
                fails.append((n["key"], which, size, hp, pages, rest))
                continue
            if k >= 1:
                buf = C.read(p)
                toff = hp + pages * PAGE
                f_pct, fh = mode47(buf[toff:toff + TILE])
                l_pct, lh = mode47(buf[size - TILE:])
                histo_first.update(fh)
                histo_last.update(lh)
                n_first += 1
                n_last += 1
                if f_pct < 90.0:
                    print("   LOW first-tile mode4-7 %.1f%% node 0x%X %s "
                          "(size %d hp %d pages %d k %d)"
                          % (f_pct, n["key"], which, size, hp, pages, k))

    print("%s: %d chunk-dir nodes, PAGE=%d TILE=%d HEIGHT=%d" %
          (level, len(nodes), PAGE, TILE, HEIGHT))
    print("decomposition classes (which, depth, hfKind, heightPrefix, kTiles, status):")
    for tag, c in sorted(classes.items()):
        print("   x%-4d %s" % (c, tag))
    print("%d chunks FAIL exact decomposition" % len(fails))
    for key, which, size, hp, pages, rest in fails[:20]:
        print("   0x%-8X %-7s size=%-9d hp=%-7d pages=%-3d rest=%d"
              % (key, which, size, hp, pages, rest))

    def show(tag, h, n):
        tot = sum(h.values())
        hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        print("%s tiles: %d tiles, %d blocks, modes4-7 %.2f%%  %s"
              % (tag, n, tot, 100.0 * hi / tot if tot else 0,
                 ", ".join("m%s:%d" % (m, c) for m, c in
                           sorted(h.items(), key=lambda kv: -kv[1])[:6])))
    show("FIRST", histo_first, n_first)
    show("LAST ", histo_last, n_last)


if __name__ == "__main__":
    main()
