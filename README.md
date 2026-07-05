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

1. Download this repository (Code → Download ZIP, or `git clone`).
2. Copy the `addons/highpoly_toggle/` folder into your Portal SDK Godot
   project's `addons/` folder (create `addons/` if it doesn't exist).
3. In the SDK editor: **Project → Project Settings → Plugins** → enable
   **BF6 High-Poly Preview**.
4. A **High-Poly** dock appears (right side, top). Done — no configuration
   needed; the plugin talks to the public model registry out of the box.

> Optional: to point at a different registry host, set the project setting
> `highpoly/manifest_url` to your `plugin-manifest.json` URL.

## Staying up to date

- **Plugin updates itself.** On editor start the dock checks the registry;
  when a newer plugin exists an **"Update Plugin → vX.Y.Z"** button appears.
  One click installs it — restart the editor to finish. (New game patches that
  change map data need no plugin update at all: map data is re-published
  server-side and **Reload map data** picks it up.)
- **Update Models** re-downloads any prop models whose community-fixed version
  changed (content-hash compare; only fetches what changed, only for props you
  have locally).
- **Reload map data** re-downloads the current map's terrain/objects package.

---

## The High-Poly dock

### Detail Mode
Swaps every placed prop between the SDK proxy and the real game model:

| Control | What it does |
|---|---|
| **Low/Medium/High-Poly** | Scene-wide detail tier. Newly placed pieces auto-overlay while a tier is active. |
| **Textured** | Off = flat-grey geometry study mode. |
| **Re-apply Scene** | Re-runs the overlay pass on the whole scene. |
| **Selected → …** | Change tier for just the selected node(s). |
| **Update Models** | Pull community-fixed models (delta download). |
| **Download Full Library** | One-time multi-GB bulk install of every model; afterwards updates are deltas. |

The first time you pick Medium/High for a scene with models you don't have
locally, the plugin offers to download exactly what that scene needs.

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
| **Reload map data** | Force re-download of this map's package (after a game patch or a bad download). |

Map data downloads on demand per map (you'll be prompted; ~25 MB terrain +
a few hundred MB of shared prop meshes that are reused across all maps).
All 23 launch maps are published.

### Turbo
Editor performance helpers — never saved into the scene:

- **Cull dist** — hide geometry beyond N metres.
- **Cull behind camera** — aggressively hides static map geometry outside the
  view (skips shadow passes too).
- **Static map shadows** — disable shadow casting from static scenery (big FPS win).
- **Purge Local Models** — delete all downloaded models from `res://highpoly`;
  your scene is untouched.

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
