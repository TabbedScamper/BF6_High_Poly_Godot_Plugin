"""probe_tung_types for the Granite levels (they live outside glaciermp).

Usage:  probe_granite_types.py <slug> [--find regex]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G     # noqa: E402
import probe_tung_types as TY        # noqa: E402


def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else "base"
    TY.C.LEVELS = os.path.dirname(G.root(slug))
    sys.argv = [sys.argv[0], os.path.basename(G.root(slug))] + sys.argv[2:]
    TY.main()


if __name__ == "__main__":
    main()
