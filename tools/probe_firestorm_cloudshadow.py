"""Task #54 — cloud-shadow mask parameters, mined from MP_FireStorm's lighting.

The cloud-shadow mask lives on the OutdoorLightComponentData inside the level's
`lighting/ve_<level>_base.ebx` VisualEnvironment. This decodes the whole
component through BF6_Frostbite_Research's ve_dump (exe type layouts), then
re-keys every field hash through the research field-name tables so the
CloudShadow* values are printed BY NAME, and resolves the two texture imports
to asset paths.

Usage:  probe_firestorm_cloudshadow.py [path-to-ve.ebx]
        (default: mp_firestorm's ve_mp_firestorm_base.ebx)
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import ve_dump                       # noqa: E402  (via the pipeline sys.path)
import typesdk                       # noqa: E402


def main():
    default = os.path.join(C.LEVELS, "mp_firestorm", "lighting",
                           "ve_mp_firestorm_base.ebx")
    path = sys.argv[1] if len(sys.argv) > 1 else default
    pe = typesdk.PE(typesdk.EXE)
    d, f, payload = ve_dump.load(path, pe)
    fn = C.field_names()

    # guid -> asset path, for the texture imports
    gi = {}
    try:
        import probe_tung_guidscan as G
        cp = os.path.join(G.CACHE, "..json")
        if os.path.isfile(cp):
            gi = json.load(open(cp, encoding="utf-8"))
    except Exception:
        pass

    print(os.path.basename(path))
    for i, off in enumerate(f.instance_offsets):
        rec = ve_dump.dump_instance(pe, d, f, payload, off)
        names = rec.get("names") or []
        if "CloudShadowEnable" not in names:
            continue
        print("instance %d  type %s  (%d fields)"
              % (i, C.tname(rec["type_guid"]), len(rec["fields"])))
        for e in rec["fields"]:
            h = int(e["hash"], 16)
            nm = fn.get(h, "0x%08X" % h)
            if "import" in e:
                imp = e.get("import")
                part = None
                if e.get("import_idx") is not None:
                    part = f.imports[e["import_idx"]][2]
                res = gi.get(str(part).lower()) if part else None
                val = "-> %s (partition %s)" % (res or imp, part)
            elif "value" in e:
                val = e["value"]
            else:
                val = "(ptr/array @%s)" % e.get("ptr_target")
            flag = "  <== cloud" if "CloudShadow" in nm or "CloudRadiosity" in nm \
                else ""
            print("   +0x%03X %-38s %s%s" % (e["off"], nm, val, flag))


if __name__ == "__main__":
    main()
