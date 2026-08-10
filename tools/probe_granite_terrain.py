"""Run probe_tung_terrain's full analysis on a Granite level.

The Granite levels live under glacierportal/ and glaciergranite/, which
probe_tung_terrain.terr_dir cannot see; this wrapper redirects it.

Usage:  probe_granite_terrain.py [slug]        slug in probe_granite_common
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G     # noqa: E402
import probe_tung_terrain as T       # noqa: E402


def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else "base"
    T.terr_dir = lambda lvl: G.terr_dir(slug)
    sys.argv = [sys.argv[0], G.LEVEL_NAMES[slug]]
    T.main()


if __name__ == "__main__":
    main()
