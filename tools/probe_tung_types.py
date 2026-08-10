"""Which EBX types occur in a level, and in which partitions.

Reads only each partition's EFIX type-GUID table (no payload decode), so a whole
level is a few seconds. Two modes:

    probe_tung_types.py <level>                 census: type -> partition count
    probe_tung_types.py <level> --find <regex>  every partition declaring a type
                                                whose NAME matches the regex

The census is the cheapest way to answer "does this level contain any X at all",
which is the question a reader that returns an empty result cannot distinguish
from "X is not here".
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402


def scan(level):
    root = os.path.join(C.LEVELS, level)
    rows = []
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                f = ebxmod.parse(p)
            except Exception:
                continue
            names = [C.tname(ebxmod._guid_str(g)) for g in f.type_guids]
            rows.append((os.path.relpath(p, root).replace(os.sep, "/"), names, f))
    return rows


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_tungsten"
    rows = scan(level)
    if "--find" in sys.argv:
        pat = re.compile(sys.argv[sys.argv.index("--find") + 1], re.I)
        n = 0
        for rel, names, f in rows:
            hit = sorted({t for t in names if pat.search(t)})
            if hit:
                n += 1
                print("%-70s %s" % (rel, ", ".join(hit)))
        print("-- %d partition(s) of %d" % (n, len(rows)))
        return
    cnt = collections.Counter()
    for _rel, names, _f in rows:
        for t in set(names):
            cnt[t] += 1
    print("%s: %d partitions, %d distinct types" % (level, len(rows), len(cnt)))
    for t, c in cnt.most_common():
        print("  %5d  %s" % (c, t))


if __name__ == "__main__":
    main()
