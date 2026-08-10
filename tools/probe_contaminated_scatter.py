"""MP_Contaminated's MeshScatteringDatabase and the per-layer scatter join.

Three questions:
  1. What is in the level's MeshScatteringDatabase (RES 0x2AB067B5)?
     (Parsed with the corpus's exact-parse layout, findings/
     meshscatteringdatabase-layout.md / impl/pipeline/msdb.py.)
  2. Are the 66 SingleTerrainLayerData.MeshScatteringTypes arrays in
     terrain_mp_contaminated.ebx really empty, or is the generic deserializer
     dropping them?  (Exe layout + raw-byte check of the array section.)
  3. Can the per-layer Identifier -> catalogue join be validated on any map?
     Scans every level's TerrainData partition for a non-empty
     MeshScatteringTypes and, where found, joins against that level's MSDB.

READ-ONLY.  Usage:  probe_contaminated_scatter.py [level]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import typesdk                          # noqa: E402
import msdb                             # noqa: E402

STLD_GUID = struct.pack("<IHH", 0x5841a888, 0x52f2, 0x94ae) + \
    bytes.fromhex("e3762ed9ae92e046")


def guid_bytes(s):
    a, b, c, rest1, rest2 = s.split("-")
    return struct.pack("<IHH", int(a, 16), int(b, 16), int(c, 16)) + \
        bytes.fromhex(rest1 + rest2)


def show_layout():
    pe = C.pe()
    lay = typesdk.get_type_layout_full(pe, STLD_GUID)
    print("SingleTerrainLayerData  size 0x%X  fields %d" % (lay["size"], lay["fieldCount"]))
    elem = None
    for f in sorted(lay["fields"], key=lambda f: f["offset"]):
        nm = C.fname(f["nameHash"])
        print("   +0x%03X  %-28s ftype_enum=%d" % (f["offset"], nm, f["ftype_enum"]))
        if nm == "MeshScatteringTypes":
            # resolve the array's element type
            tva = f["typeVA"]
            tg = typesdk._guid_at_typeinfostruct(pe, tva)
            if tg:
                al = typesdk.get_type_layout(pe, tg)
                print("      array type: %s size 0x%X enum %d"
                      % (typesdk.guid_str(tg), al["size"] if al else -1,
                         al["type_enum"] if al else -1))
                # element type: arrayInfo u64 at guid+24 points at element TypeInfo
                d = pe.d
                fo = d.find(tg, 0)
                eva = struct.unpack_from("<Q", d, fo + 24)[0]
                eg = typesdk._guid_at_typeinfostruct(pe, eva)
                if eg:
                    el = typesdk.get_type_layout_full(pe, eg)
                    print("      element type %s size 0x%X fields:"
                          % (typesdk.guid_str(eg), el["size"]))
                    for ef in sorted(el["fields"], key=lambda f: f["offset"]):
                        print("         +0x%03X  %s" % (ef["offset"], C.fname(ef["nameHash"])))
                    elem = el
    return elem


def msdb_path(level):
    root = os.path.join(C.LEVELS, level)
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            if f in ("meshscatteringdatabaseasset.2AB067B5",
                     "meshscatteringdatabaseasset.MeshScatteringDatabase"):
                return os.path.join(dp, f)
    return None


def terraindata_ebx(level):
    root = os.path.join(C.LEVELS, level)
    cands = []
    for dp, _dn, fn in os.walk(root):
        if "terrain" not in os.path.basename(dp).lower():
            continue
        for f in fn:
            if f.endswith(".ebx") and f[:-4] == os.path.basename(dp):
                cands.append(os.path.join(dp, f))
    return cands


def scan_scattertypes(path):
    """Deserialise and pull every SingleTerrainLayerData's MeshScatteringTypes."""
    D, f = C.open_ebx(path)
    out = []
    for i in range(len(f.instance_offsets)):
        g = D.inst_type[i]
        if g is None:
            continue
        import ebx as ebxmod
        if C.tname(ebxmod._guid_str(g)) != "SingleTerrainLayerData":
            continue
        rec = C.named(D.read_instance(i))
        out.append(rec.get("MeshScatteringTypes", None))
    return out


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_contaminated"

    print("== exe layout ==")
    show_layout()

    print("\n== MSDB catalogue for %s ==" % level)
    mp = msdb_path(level)
    hdr, es = msdb.parse(mp)
    print("%s\n   header %s" % (mp, hdr))
    print("   %d entries, %d with kit points, %d with wind shader"
          % (len(es), sum(1 for e in es if e["n"]), sum(1 for e in es if e["windShader"])))
    for e in es:
        print("   vd=%6.0f par=%4.2f n=%-3d grp=%08x kit=%016x  %s"
              % (e["viewDistance"], e["param"], e["n"], e["groupHash"] & 0xFFFFFFFF,
                 e["kitHash"], e["name"].split("/")[-1]))

    print("\n== raw array section of the TerrainData partition ==")
    for p in terraindata_ebx(level):
        d = C.read(p)
        print("%s  %d bytes" % (os.path.basename(p), len(d)))
        sts = scan_scattertypes(p)
        n_nonempty = sum(1 for s in sts if s)
        print("   SingleTerrainLayerData instances: %d, non-empty MeshScatteringTypes: %d"
              % (len(sts), n_nonempty))
        for s in sts:
            if s:
                print("   ", s)

    print("\n== fleet scan: which maps have a non-empty MeshScatteringTypes ==")
    for lvl in sorted(os.listdir(C.LEVELS)):
        if not os.path.isdir(os.path.join(C.LEVELS, lvl)):
            continue
        for p in terraindata_ebx(lvl):
            try:
                sts = scan_scattertypes(p)
            except Exception as e:
                print("   %-20s ERROR %s" % (lvl, e))
                continue
            ne = [s for s in sts if s]
            print("   %-20s %s  layers=%d nonempty=%d"
                  % (lvl, os.path.basename(p), len(sts), len(ne)))
            for s in ne[:6]:
                print("        ", s)


if __name__ == "__main__":
    main()
