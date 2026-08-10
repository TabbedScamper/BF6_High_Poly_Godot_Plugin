"""Per-block mean RGBA of MP_Plaza's colour tiles — modes 4, 5 and 6, rotation-aware.

Why this exists: the corpus claims plaza's colour-tile ALPHA carries baked
overhead AO/shadow, and the plugin currently ignores colour-map alpha entirely.
Tungsten's tile is ~90% mode 6 (RGBA endpoints share index bits — alpha there
is a flat ~0.002). Plaza's tile is ~57% mode 4 / ~18% mode 5, the two BC7 modes
with an INDEPENDENT alpha plane (own endpoints, own index bits), which is what
an encoder emits when alpha carries a real, colour-uncorrelated signal.

This is not a full BC7 decoder. For each block it reads the endpoints and
returns their midpoint per channel — a good estimate of the block's mean —
honouring the rotation bits of modes 4/5 (rotation r>0 swaps the alpha plane
with colour channel r-1, so ignoring it would corrupt both).

Layouts (LSB-first):
  mode 4: 5b mode, 2b rot, 1b idxMode, R0 R1 G0 G1 B0 B1 x5b, A0 A1 x6b, 31+47b idx
  mode 5: 6b mode, 2b rot,             R0 R1 G0 G1 B0 B1 x7b, A0 A1 x8b, 31+31b idx
  mode 6: 7b mode, RGBA0/1 x7b, P0 P1, 63b idx

Usage:  probe_plaza_bc7mean.py [level]      (stats only; rendering is
        probe_plaza_colorrender.py, which imports block_mean from here)
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

TILE = 67600                          # 65x65 blocks = 260x260 texels
BSIDE = 65


class Bits(object):
    def __init__(self, b):
        self.v = int.from_bytes(b, "little")
        self.p = 0

    def get(self, n):
        x = (self.v >> self.p) & ((1 << n) - 1)
        self.p += n
        return x


def _x5(v):
    return (v << 3) | (v >> 2)


def _x6(v):
    return (v << 2) | (v >> 4)


def _x7(v):
    return (v << 1) | (v >> 6)


def block_mean(block):
    """(r, g, b, a, mode) with channels 0..255, or None for modes 0-3/invalid.
    Midpoint of the two endpoints per channel; rotation applied."""
    b0 = block[0]
    if b0 == 0:
        return None
    m = 0
    while not (b0 >> m) & 1:
        m += 1
    bits = Bits(block)
    if m == 4:
        bits.get(5)
        rot = bits.get(2)
        bits.get(1)                                   # idxMode
        r0 = _x5(bits.get(5)); r1 = _x5(bits.get(5))
        g0 = _x5(bits.get(5)); g1 = _x5(bits.get(5))
        bl0 = _x5(bits.get(5)); bl1 = _x5(bits.get(5))
        a0 = _x6(bits.get(6)); a1 = _x6(bits.get(6))
    elif m == 5:
        bits.get(6)
        rot = bits.get(2)
        r0 = _x7(bits.get(7)); r1 = _x7(bits.get(7))
        g0 = _x7(bits.get(7)); g1 = _x7(bits.get(7))
        bl0 = _x7(bits.get(7)); bl1 = _x7(bits.get(7))
        a0 = bits.get(8); a1 = bits.get(8)
    elif m == 6:
        bits.get(7)
        rot = 0
        r0 = bits.get(7); r1 = bits.get(7)
        g0 = bits.get(7); g1 = bits.get(7)
        bl0 = bits.get(7); bl1 = bits.get(7)
        a0 = bits.get(7); a1 = bits.get(7)
        p0 = bits.get(1); p1 = bits.get(1)
        r0 = (r0 << 1) | p0; g0 = (g0 << 1) | p0
        bl0 = (bl0 << 1) | p0; a0 = (a0 << 1) | p0
        r1 = (r1 << 1) | p1; g1 = (g1 << 1) | p1
        bl1 = (bl1 << 1) | p1; a1 = (a1 << 1) | p1
    elif m == 7:
        bits.get(8)
        bits.get(6)                                   # 6b partition
        rot = 0
        # 2 subsets, 4 endpoints x 5 bits per channel; midpoint of subset 0
        r = [bits.get(5) for _ in range(4)]
        g = [bits.get(5) for _ in range(4)]
        bch = [bits.get(5) for _ in range(4)]
        a = [bits.get(5) for _ in range(4)]
        r0, r1 = _x5(r[0]) & 0xFF, _x5(r[1]) & 0xFF
        g0, g1 = _x5(g[0]) & 0xFF, _x5(g[1]) & 0xFF
        bl0, bl1 = _x5(bch[0]) & 0xFF, _x5(bch[1]) & 0xFF
        a0, a1 = _x5(a[0]) & 0xFF, _x5(a[1]) & 0xFF
    else:
        return None
    ch = [(r0 + r1) / 2.0, (g0 + g1) / 2.0, (bl0 + bl1) / 2.0, (a0 + a1) / 2.0]
    if rot:
        ch[rot - 1], ch[3] = ch[3], ch[rot - 1]
    return ch[0], ch[1], ch[2], ch[3], m


def tiles(level):
    """Yield (node, tile_bytes) for every primary chunk that has a trailer."""
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        s = os.path.getsize(p)
        if s % PSIZE == 0:
            continue                  # pages-only chunk, no colour tile
        buf = C.read(p)
        yield n, buf[-TILE:]


PSIZE = 5184


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_plaza"
    acc = [0.0] * 4
    n_all = 0
    hist_a = collections.Counter()            # alpha in 16 bins
    rot_used = collections.Counter()
    by_mode_a = collections.defaultdict(lambda: [0.0, 0])
    var_acc = []
    for n, tile in tiles(level):
        for i in range(0, TILE, 16):
            r = block_mean(tile[i:i + 16])
            if r is None:
                continue
            cr, cg, cb, ca, m = r
            for c, v in enumerate((cr, cg, cb, ca)):
                acc[c] += v
            n_all += 1
            hist_a[int(ca) // 16] += 1
            by_mode_a[m][0] += ca
            by_mode_a[m][1] += 1
            var_acc.append(ca)
    mean = [a / n_all / 255.0 for a in acc]
    print("%s: %d blocks decoded (modes 4/5/6/7)" % (level, n_all))
    print("   mean RGBA (%.3f, %.3f, %.3f, %.3f)" % tuple(mean))
    ma = acc[3] / n_all
    var = sum((v - ma) ** 2 for v in var_acc) / n_all
    print("   alpha mean %.3f  std %.3f  (0..1)" % (ma / 255.0, var ** 0.5 / 255.0))
    print("   alpha histogram (16 bins of 16):")
    tot = sum(hist_a.values())
    for b in range(16):
        c = hist_a.get(b, 0)
        print("      %3d-%3d  %6.2f%%  %s"
              % (b * 16, b * 16 + 15, 100.0 * c / tot, "#" * int(60.0 * c / tot)))
    print("   per-mode alpha mean:")
    for m in sorted(by_mode_a):
        s, c = by_mode_a[m]
        print("      mode %d  n=%-8d alpha %.3f" % (m, c, s / c / 255.0))


if __name__ == "__main__":
    main()
