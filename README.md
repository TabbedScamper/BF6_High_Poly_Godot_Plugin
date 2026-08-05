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

Companion project: **[BF6 Model Viewer](https://github.com/TabbedScamper/BF6_Model_Viewer)** —
browse every prop in 3D in your browser and submit model fixes; approved fixes
ship to every plugin user automatically.

---

## Install

1. Grab **`highpoly_toggle.zip`** from the
   [latest release](https://github.com/TabbedScamper/BF6_High_Poly_Godot_Plugin/releases/latest)
   and extract it into your Portal SDK Godot **project folder** — it merges
   into `addons/highpoly_toggle/`.
   *(Downloading the repository ZIP instead also works: copy or extract it
   anywhere under the project's `addons/` folder — the plugin finds its own
   files regardless of the folder it lands in.)*
2. In the SDK editor: **Project → Project Settings → Plugins** → enable
   **BF6 High-Poly Preview**.
3. A **High-Poly** dock appears (right side, top). Done — no configuration
   needed; the plugin talks to the public model registry out of the box.

> Optional: to point at a different registry host, set the project setting
> `highpoly/manifest_url` to your `plugin-manifest.json` URL.

## Staying up to date — you don't do anything

Since v1.5 everything model-related is automatic:

- **Models sync in the background.** On editor start (and hourly) the plugin
  hash-diffs the registry: community-fixed models re-download by themselves
  and swap into your open scene as they arrive. The props of the scene you're
  editing always download first; pieces you just placed jump the queue.
- **Map data heals itself.** Once per session the plugin checks whether a
  map's published package changed (game patch, fixed placements, corrected
  prop meshes) and refreshes it automatically.
- **The plugin updates itself.** When a newer version exists an
  **"Update Plugin → vX.Y.Z"** button appears; one click installs it —
  restart the editor to finish.

On first run you make the only choice there is: sync the **full library** in
the background (one large download, small deltas forever after) or download
**as needed** (only what your scenes use). A progress bar in the dock shows
what's happening; a pause button covers metered connections.

Both knobs stay in your hands afterwards:

- **Check for Updates** — force a registry check right now instead of waiting
  for the hourly diff. Handy right after a model fix is published.
- **Download scope** — switch any time between **current scene only** (keeps
  just the models your open scene uses; switching frees the rest from disk,
  and they re-download on demand) and **all models** (the whole library syncs
  in the background). Both directions confirm before doing anything — the
  full-library download is large and can be declined.

> Upgrading from 1.4 or older? On first start the plugin offers a one-time
> reorganization: it shows exactly what will be moved (your downloaded models
> — no re-download), what will be deleted (retired medium-tier files + editor
> import leftovers), and what will be re-fetched, and only proceeds when you
> confirm. Your scenes are untouched either way, and the editor stops
> re-importing thousands of GLBs on every launch afterwards.

---

## The High-Poly dock

### Detail Mode
Four rungs, ordered by what they cost you. Each answers two separate questions:
what **your own placed pieces** look like, and what the **borrowed level around
them** looks like.

| Setting | Your placed pieces | The level around them | Downloads |
|---|---|---|---|
| **Low-Poly — what you export** | SDK proxies | nothing | none at all |
| **Low-Poly + Minimal Downloads** | SDK proxies | the real level, untextured | map data + web-quality prop geometry |
| **High-Poly (no textures)** | real models, clay | the real level, untextured | the above + models for your own pieces |
| **High-Poly (full textures)** | real models, textured | the real level, textured | the above at full texture quality |

The only difference between the second and third rungs is whether the pieces
**you** placed get swapped for real models. The surroundings are identical —
that is the point of the light rung: build inside the real level without pulling
a high-poly model for every object in your own map.

On the first rung every control that would fetch something is greyed out, and
clicking one tells you which rung to move to. Nothing you have already
downloaded is deleted — climbing back up rebuilds from the same cache.

Newly placed pieces auto-overlay while a High-Poly mode is active; models still
downloading swap in automatically as they land.

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
| **Show whole map** | Full-accuracy terrain heightfield at the exact in-game height (the whole map, not just the SDK bowl), distant backdrop, and the game's exact water — animated, depth-tinted planes on maps that have them. |
| **Original map objects** | The game's original object placements — buildings, vehicles, props — drawn as MultiMeshes and streamed by camera distance. Multi-part models render complete (every mesh node merged, not just the largest piece). Works with or without the terrain layer. |
| **Textures** | On = maptile satellite + tiling ground detail + real prop textures. Off = SDK study colours (green terrain / orange objects) that match the shipped look. |
| **Grass** | Vegetation scatter — grass/shrub kits from the game's own scatter database, placed procedurally around the editor camera — with a density slider (1.0 = the database budget). |
| **Range** | Object streaming distance from the editor camera. |
| **Terrain** | Terrain mesh density (Full 1 m / High 2 m / Medium 4 m). Built once per level, then cached. |

Trees and bushes render with proper leaf transparency both here and in the
prop library (v1.7 rebuilt the whole vegetation set — no more flat black or
white foliage).

After a game patch there's nothing to press — the plugin notices a
republished map package on its own and refreshes it.

Map data downloads on demand per map (you'll be prompted; ~25 MB terrain +
a few hundred MB of shared prop meshes that are reused across all maps).
All 23 launch maps are published.

### Turbo
Editor performance helpers — never saved into the scene:

- **Cull dist** — hide geometry beyond N metres.
- **Cull behind camera** — aggressively hides static map geometry outside the
  view (skips shadow passes too).
- **Static map shadows** — disable shadow casting from static scenery (big FPS win).

(Need to reclaim disk space? Switch the download scope to **current scene
only** — everything your scenes don't use is freed and re-downloads on
demand.)

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
| [`tools/menuaudit/`](tools/menuaudit) | extracts what each dock control actually does and flags the ones that would frustrate somebody | current |

Found a broken model? Submit a fix through the
[BF6 Model Viewer](https://github.com/TabbedScamper/BF6_Model_Viewer). Once
approved it arrives on its own: the plugin diffs the manifest at startup and
hourly, and there is nothing to press. (This used to say "your next **Update
Models** click" — that button was removed in 1.5.0.)

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
- The plugin only reads published preview data; it never touches your game
  install and nothing it does affects exported/published Portal experiences.
