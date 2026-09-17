# MP_Isolated: the carriers, and why they were invisible

Reported as "the carrier that Portal experiences use does not show up in Godot
or Unreal and is not in the options for the game modes", with the tell that
**Custom Portal outlines the deck with combat volumes while the model is
absent**. That tell is what made it findable: the markers and the geometry are
reached through differently named layers.

## What the level actually ships

`mp_isolated` carries **32,093 carrier mesh placements**, assembled from shared
prefabs under `common/environment/generic/military/architecture/carrier*`
(bridge, elevator and its mirror, hull, tower, doors) plus fire-damage and audio
prefabs borrowed from `mp_granite`'s aircraftcarrier POI.

There are **two hull layouts per faction**, which is the "other carrier layout"
that felt missing:

| prefab | rows |
|---|---:|
| `pf_mil_carriernimitz_01_nato` | 36 |
| `pf_mil_carriernimitz_01_nato_carrierstrike` | 26 |
| `pf_mil_carriernimitz_02_pax` | 36 |
| `pf_mil_carriernimitz_02_pax_carrierstrike` | 26 |

## The layers, which is what visibility keys on

| rows | layer | centre (game x,y,z) |
|---:|---|---|
| 16,272 | `_layers_gameplay/carrierstrike` | -983, 111, 294 |
| 16,270 | `_layers_gameplay/portal_aircraftcarriers_carrierstrike` | -983, 111, 294 |
| 1,857 | `_layers_gameplay/portal_aircraftcarriers_conquest` | -767, 121, 171 |
| 1,866 | `_layers_gameplay/conquest/conquest` | -659, 120, 6 |

**The level ships the carriers TWICE.** `carrierstrike` and
`portal_aircraftcarriers_carrierstrike` are the same ships at the same centre,
to within two placements. Exactly one of the two may ever be visible or the
decks draw on top of each other.

## The bug

`_variant_key_visible` required a layer name to EQUAL an active mode name. The
dropdown offers the mode as the core names it, `carrierstrike`, which never
equals `portal_aircraftcarriers_carrierstrike`. So the Portal copy - the one a
Portal experience stands on - could not be shown by any selection, and with the
Variant Off only `default_event` is active, so it was hidden there too.

Custom Portal's own markers confirm which ships those are: 372 mined markers
cluster on the NATO deck around (-600, 1150) and the PAX deck around
(-1100, -900), sourced from `mil_carrierelevatorplatform_01`,
`mil_carriertowermain_01` and `mil_carrierbridgeradarplatform_01`.

## The rule now

A `portal_` layer belongs to the PORTAL CONTEXT and is never reached through a
mode name:

* Variant Off or Custom Portal -> `portal_aircraftcarriers_carrierstrike` is on,
  the mode copy is off.
* Carrier Strike -> the mode layer is on, the portal twin is off.
* Any other mode -> neither.

Matching the portal layer as a trailing `_<mode>` token would have lit it in
Carrier Strike ALONGSIDE the mode layer, which is two overlapping carriers and
worse than the bug being fixed. `native/test_portal_layers.gd` pins all of that,
including a check that the two copies are never both visible in any mode; run it
with `tools/run_addon_script.py`.

## Which portal variant, and how the first answer was wrong

`PORTAL_DEFAULT_SUFFIX` decides which portal_ variant the Portal context shows.
The first guess was `_carrierstrike`, on the reasoning that it is far bigger
(16,270 placements against 1,857). **That was wrong**, and the user caught it
from the viewport: the ship it drew lay PERPENDICULAR to the deck Custom Portal
outlines.

Size was the wrong evidence. The right evidence is agreement with the markers
Custom Portal itself authors, in POSITION AND HEADING. Matching all 372 mined
customportal markers against every carrier layer, each marker to its nearest
placement in that layer:

| layer | markers matched | median distance | median heading error |
|---|---:|---:|---:|
| `portal_aircraftcarriers_conquest` | **371 of 372** | 1.0 m | **0.0 deg** |
| `portal_aircraftcarriers_carrierstrike` | 9 of 372 | 1.0 m | 18.9 deg |
| `carrierstrike` | 9 of 372 | 1.0 m | 18.9 deg |
| `conquest/conquest` (the MODE layer) | 0 of 372 | - | - |

So a Portal experience stands on the CONQUEST portal deck, and the constant is
`_conquest`.

Note the last row: the conquest MODE layer is not the Portal carrier either.
`portal_aircraftcarriers_conquest` and `conquest/conquest` are different layers
that merely share a word, and only the `portal_` one matches. Selecting Conquest
in the dropdown does not show the Portal deck, which the test asserts.

## Other content that could never be shown

Found by the same audit, on the same level:

* `_layers_gameplay/gauntlet/dallasgauntlet_extraction` - **150 placements**
  whose leaf name matches no selectable mode. Layers filed under a mode FOLDER
  now fold to the folder name, so Gauntlet shows them.
* `_layers_gameplay/mp_sabotage` - 1 placement; the core strips the `mp_`
  prefix when naming modes, so a layer keeping it could never match. Stripped
  now too.
* `_layers_gameplay/portal_aircraftcarriers_conquest` - 1,857 placements,
  deliberately off: it is the alternative Portal deck and showing it with the
  other would double the ships.

## Mode list

The dropdown also read `Carrierstrike` and carried rows the core already skips:
`escalation_telemetry`, `koth_telemetry`, and `mp_koth`/`mp_sabotage`
duplicating modes already listed. `HighpolyGamemode.pickable()` drops those and
the pretty-name table now spells Carrier Strike and Custom (Portal).

## Reproducing the measurements

`carrier_placement_test <game> <level> [substring]` in the core prints, for every
matching placement, the prefab it came from and the LAYER that pulled it in,
with centres and extents. Passing an empty substring audits every layer on the
level. `portal_carrier_test <game> <level>` reports which modes have gameplay
markers standing on each hull.
