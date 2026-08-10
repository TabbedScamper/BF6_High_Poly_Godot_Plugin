"""How the level string "MP_FireStorm" is actually cased in the shipped data.

The SDK names the map "MP_FireStorm" (capital F, capital S). The plugin finds
the streaming tree and every other level resource with a lowercase contains()
match (highpoly_gamesource.gd:804 lowers the incoming map name once, and every
matcher lowers the resource-name side), so any casing works — but only as long
as BOTH sides are lowered. This probe counts every casing variant of the level
name in the raw bytes of all the level's EBX partitions, so the risk is a
number rather than an anecdote.

Usage:  probe_firestorm_casing.py [level-dir] [needle]
"""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_firestorm"
    needle = sys.argv[2] if len(sys.argv) > 2 else "mp_firestorm"
    root = os.path.join(C.LEVELS, level)
    rx = re.compile(re.escape(needle).encode(), re.IGNORECASE)
    counts = collections.Counter()
    files = 0
    examples = {}
    for dirpath, _dirs, fns in os.walk(root):
        for fn in fns:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            files += 1
            data = C.read(p)
            for m in rx.finditer(data):
                v = m.group().decode("ascii", "replace")
                counts[v] += 1
                examples.setdefault(v, os.path.relpath(p, root))
    print("%d partitions under %s, needle %r (case-insensitive):" %
          (files, level, needle))
    for v, c in counts.most_common():
        print("   %-16s x%-7d e.g. %s" % (v, c, examples[v]))
    print("on-disk directory name: %s" % os.path.basename(root))


if __name__ == "__main__":
    main()
