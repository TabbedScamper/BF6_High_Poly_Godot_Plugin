# BF6 High-Poly Preview (Portal SDK plugin)

Build Battlefield 6 Portal maps in the SDK's Godot editor while seeing the
**real game** — fully-textured high-poly models, the full map terrain, the
original object layouts, and water — instead of grey proxy boxes on a floating
green island.

Everything the plugin adds is an **editor-only overlay**:

- The SDK's low-poly proxies stay the **source of truth** — they are what your
  `.tscn` saves and what the Portal exporter ships. The plugin never modifies
  them.
- Overlays are `owner = null` nodes (`_HIPOLY_PREVIEW`, `_MAP_CONTEXT`) that
  Godot never serializes. Your level file stays byte-identical whether the
  plugin is on or off.

## What changed in 2.0, and why

**Everything you see is read from your own Battlefield 6 installation, live.
Nothing is downloaded, and nothing is hosted.**

Versions up to 1.27 worked the other way round: models, terrain and map data
were extracted ahead of time, published to a server, and downloaded to each
user. That worked, but it meant a third party was hosting and redistributing
Electronic Arts' art to anyone who installed a plugin — which is not ours to
hand out, however small the files were or however convenient it was.

2.0 removes that entirely. The plugin now contains a full Frostbite reader
written in GDScript: it mounts the game's own containers, decompresses them
with the copy of Oodle already sitting in your game folder, and builds meshes,
textures, terrain and effects on your machine from bytes you already own.

The practical consequences are worth knowing, because they are not all upside:

- **You must own and have installed Battlefield 6.** The plugin cannot show
  you anything without it, and says so before it does anything else.
- Nothing to download, no library to sync, no disk quota to manage, and it
  cannot be out of date after a game patch — it reads whatever is installed.
- The first read of a map is slower than a download used to be (measured 85 s
  cold), because it is parsing the real game data. It is cached afterwards
  (1.3 s), and a full rebuild of a map's scenery went from 33.4 s to 10.7 s
  once the built geometry started being cached.

Companion project: **[BF6 Model Viewer](https://github.com/TabbedScamper/BF6_Model_Viewer)** —
browse every prop in 3D in your browser.

---

## Install

**You need Battlefield 6 installed on the same machine.** The plugin reads it
directly and can show you nothing without it.

1. Grab **`highpoly_toggle.zip`** from the
   [latest release](https://github.com/TabbedScamper/BF6_High_Poly_Godot_Plugin/releases/latest)
   and extract it into your Portal SDK Godot **project folder** — it merges
   into `addons/highpoly_toggle/`.
   *(Downloading the repository ZIP instead also works: copy or extract it
   anywhere under the project's `addons/` folder — the plugin finds its own
   files regardless of the folder it lands in.)*
2. In the SDK editor: **Project → Project Settings → Plugins** → enable
   **BF6 High-Poly Preview**.
3. A **High-Poly** dock appears (right side, top). At the top of it is the
   game folder. If your install was found automatically it already reads
   **"Battlefield 6 detected"** and you are done; otherwise press
   **Locate…** and pick the folder that *contains* `Data` — typically
   `…/steamapps/common/Battlefield 6`, not the `Data` folder itself.

Nothing else to configure. There is no account, no registry and no first-run
download choice.

## Staying up to date

- **The plugin updates itself.** When a newer version exists an
  **"Update Plugin → vX.Y.Z"** button appears; one click installs it.
  **Check for updates** forces that check immediately, and since 2.0 it
  applies the new code live in most cases rather than making you restart the
  editor. When a change genuinely cannot be hot-applied it says so and offers
  the button that can.
- **Game data never goes stale.** There is nothing to re-sync after a
  Battlefield patch: the plugin reads whatever is installed at the moment you
  open a map. The build cache versions itself and is rebuilt when the reader
  changes.

This is the only thing that still talks to the network, and it only ever asks
for a version number and a plugin zip.

---

## New in 2.0

**The reader.** A complete Frostbite reader in GDScript, verified byte-for-byte
against the Python implementation it replaces at every stage: Oodle
decompression, the CAS store, type layouts read out of the game executable,
MeshSet geometry, textures, and the placement walk that recovers a map's
original object layout.

**Materials that come from the game, not from guesses.** ShaderBlockDepot
resolution says which textures a section actually binds (54.7% of surfaces
resolved correctly before the scope rule was fixed to follow *graph* ancestry
rather than directory ancestry; 99.5% after). Props take their colour from the
game's own per-vertex palettes, per-texel masks and tile paint, their
smoothness from the material rather than drawing flat matte, and glass, road
tangents and variation swaps all resolve.

**Layers that used to be downloaded, now read live:** full-map terrain from
the streaming tree, roads and terrain decals, lights, water, the distant
skyline, the vegetation scatter from the game's own clutter catalogue, and the
sky from the level's own VisualEnvironment.

**Effects.** FX flipbooks decode out of the install through a new AtlasTexture
decoder, with the grid read from EBX rather than assumed. Emitters get the
spawn rate, size, spread and lifetime the game actually authors, sprite
emitters get billboards and volume decals get real `Decal` nodes.

**Gameplay markers show what they spawn.** Vehicle spawners render the
drivable vehicle. Player and AI spawners render a real soldier, correct per
faction, assembled and dressed from the character bundles. The loot spawner
renders its weapon, assembled part by part.

**Interaction.** Pick mode clicks the original map objects and Tabs into their
parts. High-poly objects can be selected and grabbed like anything else, with
the proxy staying pickable but drawing nothing. Doors swing on their real
hinges.

**Live reload.** *Check for updates* applies new plugin code without an editor
restart in most cases, and says so plainly when a change cannot be hot-applied.

**Speed.** Container mount 21.5 s to 0.81 s. Texture sharing across props took
a build from 40.7 s to 30.4 s and VRAM from 15.5 GB to 7.8 GB. Building one
mesh per look instead of one per scope removed 59% of the parses. Caching the
built geometry took a rebuilt map from 33.4 s to 10.7 s. A cold read of a whole
map is 26.2 s at 12.3 ms frame times, which beats what the download path
managed on every measure.

Performance work continues in 2.0.1 — see the issue tracker.

---

## The High-Poly dock

### Detail Mode
Four rungs, ordered by what they cost you. Each answers two separate questions:
what **your own placed pieces** look like, and what the **borrowed level around
them** looks like.

| Setting | Your placed pieces | The level around them | What it costs |
|---|---|---|---|
| **Low-Poly (what you export)** | SDK proxies | nothing | nothing is read at all |
| **Low-Poly + the real level around it** | SDK proxies | the real level, untextured | map geometry |
| **High-Poly (no textures)** | real models, clay | the real level, untextured | the above + models for your own pieces |
| **High-Poly (full textures)** | real models, textured | the real level, textured | the above + textures |

The only difference between the second and third rungs is whether the pieces
**you** placed get swapped for real models. The surroundings are identical —
that is the point of the light rung: build inside the real level without
reading a high-poly model for every object in your own map.

Newly placed pieces auto-overlay while a High-Poly mode is active. The first
read of a map takes a while and shows a progress bar with the stage it is on;
after that it comes from cache.

| Control | What it does |
|---|---|
| **Preview selected in High-Poly** | Per-object override that follows your selection live. On a Low-Poly rung the selected objects show high-poly (work light, inspect in detail); on a High-Poly rung they drop to their proxies (reclaim FPS in heavy areas). Uncheck to restore the scene mode everywhere. |

High-poly mode covers more than static props:

- **Interactable doors swing.** Left **double-click** a door (DoorRural,
  BorderFenceDoor, ChickenWire, interior doors…) to animate it open/closed on
  its real hinge — check a doorway's clearance without leaving the editor.
- **Gameplay spawners show what they spawn.** Vehicle spawners render the
  actual drivable vehicle (wheels, tracks, mounted guns, livery), SpawnPoint /
  AI Spawner show a real soldier, and the Loot Spawner shows its weapon —
  instead of anonymous placeholder boxes.

### Collision
See what the game will actually collide with:

| Control | What it does |
|---|---|
| **Show collisions** | Draws each object's **actual in-game collision** as a transparent overlay. BF6 scales collision uniformly from the X axis — an object visually scaled (10, 20, 20) still collides as (10, 10, 10) — and the overlay reproduces exactly that, so stretched walls/floors reveal their true walkable shape. |
| **Isolate selected collision** | Selected object(s) show *only* their collision while everything else keeps its model; follows the selection live. Enabled while "Show collisions" is on. |
| **Color / Alpha** | Overlay color picker + transparency slider (default transparent red). |

Like everything else, the overlay is editor-only and never saved.

### Map Context
Rebuilds the real surroundings of the playable area, straight from data
extracted out of the game:

| Control | What it does |
|---|---|
| **Extended Terrain** | The real ground and water surrounding the play area, at the exact in-game height — the whole map, not just the SDK bowl. The ground is built from the level's own terrain materials rather than a projected aerial photo. |
| **Backdrops** | The distant skyline and out-of-bounds scenery: bridges, city facades, hills a kilometre or more out. Off by default because it is heavy and sits well outside the area you build in. Draws whether or not the extended terrain is on. |
| **Water** | The level's rivers, harbours and sea at the real height. Ripple speed follows the water setting in Configure Shaders, where zero holds it still. |
| **Original map objects** | The game's original per-object placements — buildings, vehicles, props — instead of the single merged mesh the SDK ships. The merged one is hidden while this is on and returns exactly as you left it. Appearance follows Detail Mode; distance follows Range. |
| **Prop Lighting** | The lights a placed prop carries in the game, plus the glow on its bulbs, screens and lit signs. Both come from the level's own data. |
| **Grass** | Vegetation scatter from the game's own clutter catalogue, placed procedurally around the editor camera, with a density slider (1.0 = the catalogue's budget). |
| **Range** | The one distance that governs everything: how far the borrowed scenery, its effects and its lights keep drawing, and how far your own placed pieces keep drawing. At zero the borrowed scenery switches off entirely, leaving just your map. |
| **Terrain** | Terrain mesh density (Full 1 m / High 2 m / Medium 4 m). Built once per level, then cached. |

Trees and bushes render with proper leaf transparency, honouring the game's
own opacity masks.

There is nothing to press after a game patch. The plugin reads the installed
game, so a patched map is simply the map it reads next time you open it.

### Lighting
The level's own lighting, plus the one control that is deliberately not
faithful:

| Control | What it does |
|---|---|
| **Lighting** | Sun angle, exposure, sky, fog and cloud shadows read from the level's own VisualEnvironment, so the light matches the real map rather than Godot's default. |
| **Shadows** | Sun shadows. Bounded by a radius around the camera and a minimum caster size, so buildings and vehicles cast while small props do not. Costs frame rate; switch it off if the view gets choppy. |
| **Interior light** | Lifts the darkest areas — inside buildings, under bridges, the shadowed side of a wall — so you can see what you are working on. At zero the lighting is strictly what the sky reaches, which is the calibrated match to the real game and leaves interiors black. |

### Storage and Log
**Storage** reports what the read cache is using on disk and can open the
folder. **Log** is the reporting path when something looks wrong:

- **Pick mode** — click any original map object and Tab through its parts to
  find out exactly which mesh you are looking at.
- **Mark a problem** — type what is wrong and drop a marker on the spot. The
  saved log records which object the note was pinned to, so a report says
  "this prop, this mesh" instead of "somewhere near the bridge".
- **Record performance** — records frame timings while you fly, so a
  "this area is slow" report carries numbers.
- **Save log file** — writes everything above to one file.

---

## How it works / contributing

Each document owns one thing, so there is a single place to correct when
something changes:

| document | what it owns | status |
| --- | --- | --- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | the design contract, what each source file does, the data flow | current |
| [`docs/HIGHPOLY-PREVIEW.md`](docs/HIGHPOLY-PREVIEW.md) | the matcher, the matching database, the texture extraction, the auto-fitter | current |
| [`docs/AUDIT-2026-08.md`](docs/AUDIT-2026-08.md) | a whole-system read with the evidence behind each optimisation path | partly superseded, see its header |
| [`docs/V15-DESIGN.md`](docs/V15-DESIGN.md) | why the model-management buttons were removed | historical |
| [`docs/V20-DESIGN.md`](docs/V20-DESIGN.md) | read the player's own game install instead of downloading, so nothing is hosted or redistributed | **shipped in 2.0** |
| [`tools/menuaudit/`](tools/menuaudit) | extracts what each dock control actually does and flags the ones that would frustrate somebody | current |

Something looking wrong? There is no model library to submit a fix to any
more — what you see is built from your own install, so a wrong model is a
wrong *read*. Use **Pick mode** and **Mark a problem** in the dock's Log
section to identify the exact mesh, then **Save log file** and open an issue
with it attached. That names the object, the mesh and the stage that produced
it, which is what makes it fixable.

## What is in this addon, and where it came from

**No Battlefield content ships with this plugin.** Everything in
`addons/highpoly_toggle/` is our own work: the GDScript, the shaders, the
launch animation (`waves.ogv`), the water styling, the logo, the UI font.

Game art is never bundled. It is read from the player's own installed copy of
Battlefield 6 — see [`docs/V20-DESIGN.md`](docs/V20-DESIGN.md).

This has not always been true, and it is written down because it was not
obvious: until 2026-08-06 the addon carried 24 MB of extracted game textures
(a panoramic sky, fire and smoke sheets, ground and cliff layers). They were
small next to the downloaded models and nobody noticed they were being handed
to every installer. They have been removed from the tree and from every commit
of the history.

## Research notes

[`research/`](research/) publishes what we've worked out about BF6's asset
formats — field hashes, layout tables, decode methods, and the negative results
worth not repeating — so it can be shared rather than independently re-derived.

[`research/findings.json`](research/findings.json) is a machine-readable index
(id, date, status, tags, summary) meant to be scraped and diffed;
[`research/EXCHANGE.md`](research/EXCHANGE.md) explains how to contribute.
Findings marked `retracted` are ones we published and later disproved — they
stay listed deliberately.

## Requirements & notes

- Battlefield 6 Portal SDK (Godot 4.6.x based).
- **Battlefield 6 installed on the same machine.** The plugin reads it
  directly and shows nothing without it.
- Windows. The Oodle shim that decompresses the game's containers loads the
  `oo2core_9_win64.dll` already present in your game folder.
- The plugin **reads** your game install and never writes to it.
- Nothing it does affects exported or published Portal experiences. Overlays
  are `owner = null` and are never saved into your `.tscn`.
- No Battlefield content is redistributed by this project. See *What is in
  this addon, and where it came from* above.
