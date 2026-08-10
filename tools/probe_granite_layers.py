"""probe_tung_layers for the Granite levels (redirects terr_dir).

Usage:  probe_granite_layers.py <slug> [--index <subtree>]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G     # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_layers as PL       # noqa: E402


def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else "base"
    T.terr_dir = lambda lvl: G.terr_dir(slug)
    sys.argv = [sys.argv[0], G.LEVEL_NAMES[slug]] + sys.argv[2:]
    PL.main()


if __name__ == "__main__":
    main()
