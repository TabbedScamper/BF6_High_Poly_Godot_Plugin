"""Dump one EBX partition in full: every instance, every field, names resolved.

Usage:  probe_tung_ebx.py <path-relative-to-bundles-or-absolute> [--raw] [--wide]

  --raw   also print the field HASHES beside the names (needed whenever a name
          table lookup could be ambiguous)
  --wide  do not truncate long values
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402


def main():
    arg = sys.argv[1]
    p = arg if os.path.isabs(arg) else os.path.join(C.BUNDLES, arg.replace("/", os.sep))
    wide = "--wide" in sys.argv
    raw = "--raw" in sys.argv
    D, f = C.open_ebx(p)
    print(p.replace(C.BUNDLES, "<bundles>"), "%d bytes" % os.path.getsize(p))
    print("partition %s   instances %d   exported %d   imports %d"
          % (f.partition_guid_str, len(f.instance_offsets),
             f.exported_instance_count, len(f.imports)))
    only = None
    if "--type" in sys.argv:
        import re as _re
        only = _re.compile(sys.argv[sys.argv.index("--type") + 1], _re.I)
    for i, gs, tn in C.instances(D):
        if only is not None and not only.search(tn):
            continue
        print("[%d] %s  (%s)  @+0x%X" % (i, tn, gs, f.instance_offsets[i]))
        rec = D.read_instance(i)
        if not rec:
            continue
        for k, v in rec.items():
            if k == "__type":
                continue
            label = C.fname(k) if isinstance(k, int) else str(k)
            if raw and isinstance(k, int):
                label = "%s [0x%08X]" % (label, k)
            s = json.dumps(C.named(v) if isinstance(v, (dict, list)) else v, default=str)
            if not wide and len(s) > 300:
                s = s[:300] + "..."
            print("      %-40s %s" % (label, s))
    if f.imports:
        print("imports (%d):" % len(f.imports))
        for pgs, igs, leaves in C.imports_of(f):
            print("   part %s  inst %s  %s" % (pgs, igs, ", ".join(leaves)))


if __name__ == "__main__":
    main()
