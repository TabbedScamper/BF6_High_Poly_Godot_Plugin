"""MP_Portal_Sand ground layers: layer-graph table -> depot -> textures/constants.

Thin driver over the Tungsten join (probe_tung_layers) with the level root
re-pointed at game/glacierportal/levels. The 100%-resolve rule for locating the
record table (MAP-TUNGSTEN.md B1) is applied by probe_tung_layers.layer_table.

Usage:  probe_portalsand_layers.py [--index <subtree>]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_portalsand_common as PC     # noqa: E402  (re-points C.LEVELS)
import probe_tung_layers as L            # noqa: E402

if __name__ == "__main__":
    sys.argv = [sys.argv[0], PC.LEVEL] + sys.argv[1:]
    L.main()
