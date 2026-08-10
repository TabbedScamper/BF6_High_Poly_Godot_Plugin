"""Is MP_Contaminated's colour data BC1?

Round-2 established: paired chunks = pages*2592 [+ 189216-type prefixes]
+ 34848, where 34848 = 4 x 8712 and 8712 = 33x33 BC1 blocks = one 132x132
BC1 tile; primary chunks end with a constant 936-byte blob that hexdumps like
BC1 (c0 > c1 endpoint pairs).

This probe measures, without rendering:
  * the BC1 signature (fraction of 8-byte blocks with c0 > c1) for
    (a) the first 34848 bytes vs (b) the last 34848 bytes of paired chunks,
    and (c) the 936-byte primary trailer;
  * the decoded BC1 endpoint-mean colour of each candidate.

Control: the same c0>c1 statistic over tungsten's known-BC7 tiles should come
out ~50% (random), a real BC1 stream close to 100%.

READ-ONLY.  Usage:  probe_contaminated_bc1.py [level]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as CM       # noqa: E402

PS = 2592
TILE = 8712
GROUP = 4 * TILE


def c565(v):
    r = (v >> 11) & 0x1F
    g = (v >> 5) & 0x3F
    b = v & 0x1F
    return (r / 31.0, g / 63.0, b / 31.0)


def bc1_stats(buf):
    n = gt = 0
    sr = sg = sb = 0.0
    for i in range(0, len(buf) - 7, 8):
        c0 = buf[i] | (buf[i + 1] << 8)
        c1 = buf[i + 2] | (buf[i + 3] << 8)
        n += 1
        if c0 > c1:
            gt += 1
        r0, g0, b0 = c565(c0)
        r1, g1, b1 = c565(c1)
        sr += (r0 + r1) / 2
        sg += (g0 + g1) / 2
        sb += (b0 + b1) / 2
    if not n:
        return 0, 0, (0, 0, 0)
    return n, gt / n, (sr / n, sg / n, sb / n)


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_contaminated"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _ = CM.chunk_dir(d, after)

    first = bytearray()
    last = bytearray()
    trail936 = bytearray()
    pages_mid = bytearray()
    for n in nodes:
        if n["g1"] is not None:
            p = CM.chunk_path(n["g1"])
            if os.path.isfile(p):
                size = os.path.getsize(p)
                rest = size - GROUP
                if rest >= 0 and any((rest - pre) >= 0 and (rest - pre) % PS == 0
                                     for pre in (0, 189216, 378432)):
                    buf = C.read(p)
                    first += buf[:GROUP]
                    last += buf[-GROUP:]
        if n["g0"] is not None:
            p = CM.chunk_path(n["g0"])
            if os.path.isfile(p):
                size = os.path.getsize(p)
                ok = False
                for h in range(3):
                    rest = size - h * 149297 - 936
                    if rest >= 0 and rest % PS == 0:
                        ok = True
                        pg = rest // PS
                        break
                if ok:
                    buf = C.read(p)
                    trail936 += buf[-936:]
                    if pg:
                        # a weight page from the middle, as a control
                        pages_mid += buf[h * 149297:h * 149297 + PS]

    for tag, buf in (("paired FIRST 4x8712", first),
                     ("paired LAST  4x8712", last),
                     ("primary 936 trailer", trail936),
                     ("weight-page control", pages_mid)):
        n, frac, mean = bc1_stats(bytes(buf))
        print("%-22s %9d blocks  c0>c1 %5.1f%%  endpoint mean RGB (%.3f, %.3f, %.3f)"
              % (tag, n, 100 * frac, *mean))


if __name__ == "__main__":
    main()
