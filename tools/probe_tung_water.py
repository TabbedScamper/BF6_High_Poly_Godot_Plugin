"""What represents water on MP_Tungsten: the ocean surface, the river layer,
and every partition in the level whose name suggests water.

Usage:  probe_tung_water.py [level-dir-name]     (default mp_tungsten)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402


def dump_partition(path, max_inst=40):
    print("=" * 78)
    print(path.replace(C.BUNDLES, "<bundles>"), " %d bytes" % os.path.getsize(path))
    D, f = C.open_ebx(path)
    print("  partition %s" % f.partition_guid_str)
    print("  instances %d   exported %d   imports %d"
          % (len(f.instance_offsets), f.exported_instance_count, len(f.imports)))
    for i, gs, tn in C.instances(D)[:max_inst]:
        rec = D.read_instance(i)
        print("  [%d] %s  (%s)" % (i, tn, gs))
        if rec:
            for k, v in C.named(rec).items():
                if k == "__type":
                    continue
                s = json.dumps(v, default=str)
                if len(s) > 220:
                    s = s[:220] + "..."
                print("        %-34s %s" % (k, s))
    if f.imports:
        print("  imports:")
        seen = set()
        for pgs, igs, leaves in C.imports_of(f):
            if pgs in seen:
                continue
            seen.add(pgs)
            print("      %s  ->  %s" % (pgs, ", ".join(leaves) or "<not in _af>"))


def water_geometry(root):
    """The ocean surface's own numbers, plus the field OFFSETS they came from.

    TERRAIN.md 11 reads +0x90 as `TileOffset`. The exe's own layout says +0x90 is
    `QueryBoxHalfExtent` and `TileOffset` is at +0xB0 -- and on MP_Tungsten the two
    hold different values, so the two readings are separable here where they were
    not on mp_dumbo.
    """
    import struct
    import typesdk
    p = os.path.join(root, "_layers_content", "water.ebx")
    if not os.path.isfile(p):
        print("no water.ebx")
        return
    D, f = C.open_ebx(p)
    g = "ae0b69fc-2207-d874-8230-fcd467a592cf"
    h = g.replace("-", "")
    raw = (struct.pack("<IHH", int(h[0:8], 16), int(h[8:12], 16), int(h[12:16], 16))
           + bytes.fromhex(h[16:]))
    lay = typesdk.get_type_layout_full(C.pe(), raw)
    print("=" * 78)
    print("WaterSurfaceEntityData layout: size 0x%X, %d fields" % (lay["size"], len(lay["fields"])))
    for fl in sorted(lay["fields"], key=lambda x: x["offset"]):
        n = C.fname(fl["nameHash"])
        if n in ("Transform", "TileOffset", "QueryBoxHalfExtent", "MaterialPair",
                 "AdditionalWaterDepth", "ShoreDepth", "ProjectorElevation"):
            print("   +0x%03X  %s" % (fl["offset"], n))
    for i, gs, tn in C.instances(D):
        if tn != "WaterSurfaceEntityData":
            continue
        rec = C.named(D.read_instance(i))
        t = rec["Transform"]
        rows = [k for k in t if k != "__type"]
        print("  Transform rows:")
        for k in rows:
            v = t[k]
            print("     %-14s (%.3f, %.3f, %.3f)" % (k, v["X"], v["Y"], v["Z"]))
        for k in ("QueryBoxHalfExtent", "TileOffset"):
            v = rec[k]
            print("  %-20s (%.3f, %.3f, %.3f)" % (k, v["X"], v["Y"], v["Z"]))
        mp = rec.get("MaterialPair")
        if mp:
            print("  MaterialPair.Packed  %d = 0x%08X" % (mp["Packed"], mp["Packed"]))
        print("  StateKey (0x2E15621F) 0x%016X" % rec.get(0x2E15621F, rec.get("0x2E15621F", 0)))


def main():
    lvl = sys.argv[1] if len(sys.argv) > 1 else "mp_tungsten"
    root = os.path.join(C.LEVELS, lvl)
    wanted = [
        os.path.join(root, "_layers_content", "water.ebx"),
        os.path.join(root, "_layers_content", "water_shared_schematic.ebx"),
        os.path.join(root, "_layers_world", "river.ebx"),
        os.path.join(root, "_layers_world", "river_ecsprefab_ecsprefab.ebx"),
        os.path.join(root, "_layers_world", "riversplines_backdrop.ebx"),
        os.path.join(root, "_layers_world",
                     "riversplines_backdrop_ecsprefab_ecsprefab.ebx"),
        os.path.join(root, "_layers_world", "creeks_backdrop.ebx"),
        os.path.join(root, "_layers_world",
                     "creeks_backdrop_ecsprefab_ecsprefab.ebx"),
    ]
    if "--geom" not in sys.argv:
        for p in wanted:
            if os.path.isfile(p):
                dump_partition(p)
            else:
                print("=" * 78)
                print("MISSING", p.replace(C.BUNDLES, "<bundles>"))
    water_geometry(root)


if __name__ == "__main__":
    main()
