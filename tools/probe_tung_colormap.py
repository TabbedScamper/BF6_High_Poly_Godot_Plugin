"""What codec a level's terrain colour-map tiles are actually in.

The plugin decodes them as BC7 (`FORMAT_BPTC_RGBA`) on TERRAIN.md 5.3's word and
gets a cyan map for MP_Tungsten whose mean is (0.119, 0.735, 0.676) where the
SDK's own overhead image of the same map averages a warm (0.520, 0.473, 0.356).
4,624 bytes is 16 bytes per 4x4 block over 68x68, which BC2/BC3/BC5/BC6H/BC7 all
share, so the byte count cannot name the codec.

The BC7 block header can. A BC7 block's mode is unary in the low bits of byte 0:
mode m has bit m as the lowest set bit. TERRAIN.md 5.3's proof for mp_dumbo is
that 100% of blocks fall in modes 4-7 (byte0 & 0x0F == 0, byte0 != 0).

A colour tile is the LAST thing in its chunk (TERRAIN.md 5.2), so 16-byte block
boundaries are aligned to the chunk's END regardless of how the rest of the
chunk decomposes -- which means the histogram can be taken without solving the
page-count decomposition at all.

**mp_dumbo is the control.** Run it first; if dumbo does not come out 100%
modes 4-7 the probe is wrong, not the map.

Usage:  probe_tung_colormap.py [level] [--tail N] [--chunks N]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import bf6_paths as P                # noqa: E402

CHUNKS = P.CHUNKS


def chunk_dir(d, off):
    """TERRAIN.md 3: recursive pre-order node walk from root key 3."""
    nodes = []

    def node(o, key, depth):
        size0 = struct.unpack_from("<I", d, o)[0]
        g0 = d[o + 4:o + 20]
        o += 20
        has_pair = d[o]
        o += 1
        size1, g1 = 0, None
        if has_pair:
            size1 = struct.unpack_from("<I", d, o)[0]
            g1 = d[o + 4:o + 20]
            o += 20
        o += 1                        # persistentDedicatedServer
        has_children = d[o]
        o += 1
        nodes.append(dict(key=key, depth=depth, size0=size0, g0=g0,
                          size1=size1, g1=g1, leaf=not has_children))
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i, depth + 1)
        return o

    end = node(off, 3, 0)
    return nodes, end


def chunk_path(g):
    return os.path.join(CHUNKS, g.hex().upper() + ".chunk")


def bc7_modes(buf):
    h = collections.Counter()
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        if b == 0:
            h["invalid(0)"] += 1
            continue
        m = 0
        while not (b >> m) & 1:
            m += 1
        h[m] += 1
    return h


def report(tag, buf):
    h = bc7_modes(buf)
    tot = sum(h.values())
    hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
    print("   %-26s %5d blocks  modes4-7 %5.1f%%  %s"
          % (tag, tot, 100.0 * hi / tot if tot else 0,
             ", ".join("m%s:%d" % (m, c) for m, c in
                       sorted(h.items(), key=lambda kv: -kv[1])[:5])))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    tail = int(sys.argv[sys.argv.index("--tail") + 1]) if "--tail" in sys.argv else 4624
    want = int(sys.argv[sys.argv.index("--chunks") + 1]) if "--chunks" in sys.argv else 10
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = chunk_dir(d, after)
    print("%s: chunk directory %d nodes (header %d), consumed %d of %d bytes"
          % (level, len(nodes), hdr["NodeCount"], end, len(d)))

    seen = 0
    sizes = collections.Counter()
    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = chunk_path(g)
            if not os.path.isfile(p):
                continue
            real = os.path.getsize(p)
            sizes[(which, real == declared)] += 1
            if seen >= want:
                continue
            buf = C.read(p)
            report("node 0x%X %s tail%d" % (n["key"], which, tail), buf[-tail:])
            seen += 1
    print("   chunks found: %s   (True == on-disk size equals the directory's)"
          % dict(sizes))


if __name__ == "__main__":
    main()
