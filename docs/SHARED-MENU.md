# Shared high-poly menu

The visual reference is the Godot high-poly panel. The Unreal High-Poly parent
repository now owns the definitions under `Shared/menu/`. Its `menu.json` owns
section names/descriptions/default opening state, section/group/control order,
control labels/help, engine applicability, and common sizing. `theme.json` in
the same directory owns the existing Godot palette. Both packages receive
identical copies. Edit the Unreal parent's files; this Godot repository's
`shared/menu/` is a distribution snapshot, not a second editable authority.

The Godot adapter in `highpoly_menu.gd` composes the existing live controls.
Signals, state, disabled controls, conditional rows, and dynamic selection
labels stay with the original implementation. Section state now uses stable
IDs; saved title-based preferences from previous releases remain readable.
Font scale, control/status/section sizes, chip spacing and panel padding read
the shared style. Existing values preserve the established Godot appearance.

## Update and check

Run with the Python installed on the development machine:

```text
python tools/sync_shared_menu.py --check --unreal-plugin <BF6HighPoly-directory>
python tools/sync_shared_menu.py --write --unreal-plugin <BF6HighPoly-directory>
```

The equivalent command from the Unreal High-Poly plugin root is
`python Tools/sync_shared_menu.py --godot-product <Godot-product-checkout> --write`.
Paths are supplied explicitly; no development-machine paths are persisted.
Parent edits flow to Unreal `Resources/theme`, Godot `shared/menu` (including
the capability contract), and the shipped Godot addon. A stale Godot snapshot
never wins over a supplied Unreal parent.

Without `--unreal-plugin`, the default/`--check` only validates the standalone
Godot snapshot and shipped addon. The result explicitly reports that snapshot
freshness is unverified. `--write` without the Unreal parent is refused.
`--promote-snapshot --write --unreal-plugin ...` is a one-time migration for an
empty parent directory only; it refuses to replace existing parent definitions.
The current parent was promoted byte for byte from the reviewed Godot snapshot.

`--installed-addon <highpoly_toggle-directory>` optionally includes a local
Godot installation. Its custom theme is untouched unless that option is supplied.
`--write` explicitly copies menu, theme, preparation and capability data. It does
not deploy new adapter scripts, compile Unreal, change game data, or restart
editors. A fresh install of these adapters is required before the data can be
consumed. Restart the editors after syncing menu data; both adapters cache the
parsed definition for the editor session.

Default operation is read-only. Invalid schemas, duplicate JSON keys/IDs,
duplicate or missing control references, invalid kinds/styles/engines, and
drift between the canonical and requested shipped copies fail the check.
The Godot packaging script runs this check before staging. Set `BF6_PYTHON`
to an interpreter path if Python is not on PATH. Nested add-on installations
configure menu, palette and font paths from their actual script directory.

## Engine boundaries

This is shared presentation, not a promise that both engines implement every
feature. `engines` states where a control applies; an advertised local control
without a binding must be reported as an adapter gap. `engine_tips` allows
honest help for a narrower engine implementation without changing the common
label or arrangement. Never bind a similarly named but different action just
to fill a hole in the menu.
Binding kind is checked before shared labels/help are applied. Godot's native
color picker is explicitly a `choice` control alongside enumerated dropdowns.

The Unreal parent's `Shared/menu/adapters.json` records the reviewed implemented control IDs and
kinds. Sync checks compare menu applicability against that contract and actual
source binding IDs in Godot and, when supplied, the Unreal plugin. Runtime
adapters additionally verify widget kinds. Add a feature to this contract only
after implementing its handler. `tools/test_shared_menu_capabilities.py` rejects
unsupported engine claims and the previous incorrect wind/performance kinds.

Unreal now exposes the base SDK collision overlay, native color picker and
alpha control through the shared Collision section. These are projected
previews, not the planned game-authored collision integration. Isolation,
independent backdrop and FX switches, contact shading/shadow/interior-light/
ground-photo controls, and reversible environment-lighting remain Godot-only
in the current registry. Unreal wind is a toggle; its performance setting is a
choice. These omissions remain implementation work rather than inert buttons.

Godot's layout wrappers preserve its native compound slider rows and animated
sections. Group order and control order are data-driven. Changing a group's
layout family or adding a new interaction can still require adapter work.
The dynamic Storage and Log contents are explicit `native` groups. Their
section position/copy is shared; their individual diagnostic/storage controls
remain native and are not yet driven by the common control registry.

The single Godot fixture-light toggle and Unreal's combined map/prop-light
toggle remain separate IDs. Godot lighting cannot safely be mapped to Unreal's
existing environment mutations until a reversible lighting adapter exists.
Common layout does not mean matching water, decals, atmospheric rendering or
cache behavior; those are separate rendering and resource contracts.

The Unreal adapter is `BF6HighPolyMenu.cpp`, with engine bindings registered in
`MakeControlPanel` in `BF6HighPoly.cpp`. `BF6.HighPoly.Menu` opens it directly.
It renders shared groups as compact chips, inline controls or stacked rows;
uses shared typography/padding; and remembers section states in editor settings.
Game-mode choices are read again when their dropdown opens, so newly discovered
modes do not require recreating the panel. Unreal rejects mismatched control
kinds and logs missing or unused bindings. Its native Log section opens the
current editor log; it does not yet provide Godot's diagnostic bundle controls.

## Verification

`tools/test_shared_menu.gd`, run inside an isolated Godot project containing the
add-on, loads the real editor adapter and exercises shared ordering/labels/
tips. It confirms that applying presentation keeps toggle state, does not fire
handlers, and does not unhide conditional controls. An unbound fake control
must produce an explicit adapter gap. This test does not establish rendered
pixel parity or correct behavior of every editor action.

## Preview and preparation flow

Choosing Clay or Textured starts the Unreal scenery build when no complete
build exists. Selecting an omitted layer starts its preparation; a layer already
built toggles immediately. The normal panel has no separate scenery Build
button. A missing Unreal layer currently uses a full scenery rebuild.

Install path and Locate sit at the top. Scenery build, library-picture work and
resource preparation report their progress above the detail controls. Prepare
maps opens a dedicated themed modal screen with overall, current-map and prop
resource progress. Unreal also exposes this entry on the map selection home
screen when the high-poly module is loaded. See PREPARATION-SCREEN.md for the
resource scope and cooperative pause/cancel behavior.
