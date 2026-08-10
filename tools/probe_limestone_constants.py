"""The six unidentified layer-graph constants, run against a level's layer set.

For each of the constants MAP-TUNGSTEN.md B2 leaves open --

    0x4C200FE0  float      0xCBB9A946  float2     0xCF3F97E0  int (0x34791132)
    0xF7652FB3  float      0x2F9990B7  float      0xE68B2B10  float

-- this prints the per-layer value alongside the layer's character (painted /
base, textured / not, tiling rate 0x5707A992, smoothness 0xFA13C5B0), then a
distribution summary. Run on two levels and diff to see what is per-map and
what is universal.

READ-ONLY. Usage: probe_limestone_constants.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_layers as L        # noqa: E402
import shaderblock                   # noqa: E402

SIX = [0x4C200FE0, 0xCBB9A946, 0xCF3F97E0, 0xF7652FB3, 0x2F9990B7, 0xE68B2B10]
AUX = {0x5707A992: "tiling", 0xFA13C5B0: "smooth"}


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_limestone"
    td = T.terr_dir(level)
    dep_path = T._res(td, "layergraphs_shaderblockdepot.ShaderBlockDepotResource")
    if dep_path is None:
        dep_path = T._res(td, ".ShaderBlockDepotResource")
    dep = shaderblock.parse_depot(dep_path)
    n, keys, hashes, extra = L.layer_table(td, dep)

    d = C.read(T._res(td, ".TerrainStreamingTree"))
    _h, blocks, _a = T.container(d)
    painted = basec = None
    for t, off, size in blocks:
        if t == 1:
            _sh, painted, basec, _nn, _nr, _sl = T.splat_walk(d, off, size)

    dist = {h: collections.Counter() for h in SIX}
    rows = []
    for i in range(n):
        ri = dep.key_to_record.get(keys[i])
        side = []
        if painted and painted.get(i):
            side.append("painted")
        if basec and basec.get(i):
            side.append("BASE")
        params, texn, has_cv = {}, 0, False
        if ri is not None:
            rec = dep.records[ri]
            r = shaderblock.resolve_record(rec, {})
            if r:
                texn = len(r["textures"])
                has_cv = any("_cv" in str(v) for v in r["textures"].values())
                for lbl, (ty, val) in r["params"].items():
                    try:
                        h = int(lbl.replace("nh_", ""), 16)
                    except ValueError:
                        continue
                    params[h] = (ty, val)
        row = ["L%02d" % i, "/".join(side) or "unused",
               "tex%d%s" % (texn, "+cv" if has_cv else "")]
        for h in SIX:
            if h in params:
                ty, val = params[h]
                if isinstance(val, float):
                    s = "%.4g" % val
                elif isinstance(val, (list, tuple)):
                    s = "(" + ",".join("%.3g" % v for v in val) + ")"
                else:
                    s = str(val)
                dist[h][s] += 1
            else:
                s = "-"
            row.append(s)
        for h in AUX:
            if h in params:
                row.append("%.4g" % params[h][1])
            else:
                row.append("-")
        rows.append(row)

    hdr = ["layer", "side", "tex", "4C200FE0", "CBB9A946", "CF3F97E0",
           "F7652FB3", "2F9990B7", "E68B2B10", "tiling", "smooth"]
    w = [max(len(hdr[c]), max(len(r[c]) for r in rows)) for c in range(len(hdr))]
    print("%s: %d layers" % (level, n))
    print("  ".join(h.ljust(w[c]) for c, h in enumerate(hdr)))
    for r in rows:
        print("  ".join(r[c].ljust(w[c]) for c in range(len(hdr))))
    print("=" * 70)
    for h in SIX:
        cnt = dist[h]
        present = sum(cnt.values())
        print("0x%08X  on %d/%d layers  values: %s"
              % (h, present, n, ", ".join("%s x%d" % kv for kv in
                                          sorted(cnt.items(), key=lambda kv: -kv[1]))))


if __name__ == "__main__":
    main()
