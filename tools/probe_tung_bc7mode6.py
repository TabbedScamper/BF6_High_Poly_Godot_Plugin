"""Average colour of a level's terrain colour-map tiles, from BC7 mode-6 endpoints.

Not a full BC7 decoder -- it does not need to be. Mode 6 is one subset with two
RGBA endpoints and per-texel interpolation weights that average near the
midpoint, so the mean of the two endpoints is a good estimate of a block's mean
colour, and mode 6 is ~90% of the blocks in these tiles. That is enough to ask
the only question that matters here: is the tile warm like the SDK's own
overhead image of the map, or is it the cyan the plugin currently produces?

Mode 6 bit layout, LSB-first over the 16 bytes:
    7 bits mode (six 0s then a 1)
    R0 R1 G0 G1 B0 B1 A0 A1   7 bits each
    P0 P1                     1 bit each  (endpoint low bit)
    63 index bits
Endpoint channel = (v << 1) | p.

Usage:  probe_tung_bc7mode6.py [level] [--tile first|second]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

TILE = 17424


class Bits(object):
    def __init__(self, b):
        self.v = int.from_bytes(b, "little")
        self.p = 0

    def get(self, n):
        x = (self.v >> self.p) & ((1 << n) - 1)
        self.p += n
        return x


def mode6_endpoints(block):
    b = Bits(block)
    if b.get(7) != 0x40:
        return None
    r0 = b.get(7); r1 = b.get(7)
    g0 = b.get(7); g1 = b.get(7)
    bl0 = b.get(7); bl1 = b.get(7)
    a0 = b.get(7); a1 = b.get(7)
    p0 = b.get(1); p1 = b.get(1)
    e0 = ((r0 << 1) | p0, (g0 << 1) | p0, (bl0 << 1) | p0, (a0 << 1) | p0)
    e1 = ((r1 << 1) | p1, (g1 << 1) | p1, (bl1 << 1) | p1, (a1 << 1) | p1)
    return e0, e1


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    which = sys.argv[sys.argv.index("--tile") + 1] if "--tile" in sys.argv else "first"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)

    acc = [0.0, 0.0, 0.0, 0.0]
    n_blocks = 0
    per_depth = collections.defaultdict(lambda: [0.0, 0.0, 0.0, 0.0, 0])
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < 2 * TILE:
            continue
        tail = buf[-2 * TILE:]
        seg = tail[:TILE] if which == "first" else tail[TILE:]
        for i in range(0, TILE, 16):
            ep = mode6_endpoints(seg[i:i + 16])
            if ep is None:
                continue
            for c in range(4):
                v = (ep[0][c] + ep[1][c]) / 2.0
                acc[c] += v
                per_depth[n["depth"]][c] += v
            per_depth[n["depth"]][4] += 1
            n_blocks += 1
    if not n_blocks:
        print("no mode-6 blocks")
        return
    print("%s %s tile: %d mode-6 blocks" % (level, which, n_blocks))
    print("   mean RGBA  (%.3f, %.3f, %.3f, %.3f)"
          % tuple(a / n_blocks / 255.0 for a in acc))
    for dep in sorted(per_depth):
        v = per_depth[dep]
        if v[4] < 100:
            continue
        print("   depth %d  n=%-7d (%.3f, %.3f, %.3f, %.3f)"
              % (dep, v[4], v[0] / v[4] / 255, v[1] / v[4] / 255,
                 v[2] / v[4] / 255, v[3] / v[4] / 255))


if __name__ == "__main__":
    main()
