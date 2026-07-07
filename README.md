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

> Upgrading from 1.4 or older? On first start the plugin offers a one-time
> reorganization: it shows exactly what will be moved (your downloaded models
> — no re-download), what will be deleted (retired medium-tier files + editor
> import leftovers), and what will be re-fetched, and only proceeds when you
> confirm. Your scenes are untouched either way, and the editor stops
> re-importing thousands of GLBs on every launch afterwards.

---

## The High-Poly dock

### Detail Mode
Swaps every placed prop between the SDK proxy and the real game model:

| Control | What it does |
|---|---|
| **Low-Poly / High-Poly (no textures) / High-Poly (textured)** | Scene-wide detail mode. Newly placed pieces auto-overlay while a mode is active; models still downloading swap in automatically as they land. |
| **Selected → …** | Change mode for just the selected node(s). |

### Map Context
Rebuilds the real surroundings of the playable area, straight from data
extracted out of the game:

| Control | What it does |
|---|---|
| **Show map context** | Full-accuracy terrain heightfield (the whole map, not just the SDK bowl), distant backdrop, and the exact water plane on maps that have one. |
| **Original map objects** | The game's original object placements — buildings, vehicles, props — drawn as MultiMeshes and streamed by camera distance. Works with or without the terrain layer. |
| **Textures** | On = maptile satellite + tiling ground detail + real prop textures. Off = SDK study colours (green terrain / orange objects) that match the shipped look. |
| **Range** | Object streaming distance from the editor camera. |
| **Terrain** | Terrain mesh density (Full 1 m / High 2 m / Medium 4 m). Built once per level, then cached. |

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
- **Purge Local Models** — delete all downloaded models; your scene is
  untouched and the sync re-downloads what your scenes need.

---

## How it works / contributing

See [`docs/HIGHPOLY-PREVIEW.md`](docs/HIGHPOLY-PREVIEW.md) for the overlay
design, the conservative auto-fitter, and the fix-a-mismatch playbook, and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for what each script does and
how the data + release pipelines fit together.

Found a broken model? Submit a fix through the
[BF6 Model Viewer](https://github.com/TabbedScamper/BF6_Model_Viewer) — once
approved it reaches every user's next **Update Models** click.

## Requirements & notes

- Battlefield 6 Portal SDK (Godot 4.6.x based).
- The plugin only reads published preview data; it never touches your game
  install and nothing it does affects exported/published Portal experiences.
