# Architecture

A map for anyone jumping into the code: what each file does, how data flows,
and how releases/updates work.

## Design contract (applies to everything)

1. **The SDK's low-poly proxies are the source of truth.** They are what the
   `.tscn` saves and what the Portal exporter ships. No code path may modify,
   reparent, or replace them.
2. **Every visual the plugin adds is an `owner = null` overlay node.** Godot
   only serializes nodes whose `owner` is the scene root, so overlays can never
   leak into a saved scene or an export. Reloading a scene silently drops all
   overlays; the dock rebuilds them on demand.
3. **Fail towards the proxy.** If a model is missing, mis-shaped, or a download
   fails, the user sees the normal SDK proxy — never a broken or distorted
   overlay.

## Files (addons/highpoly_toggle/)

| File | Responsibility |
|---|---|
| `plugin.cfg` | Plugin metadata. `version` here is the source of truth for self-update checks. |
| `highpoly_toggle.gd` | The `EditorPlugin` + the entire dock UI. Owns the 0.5 s timer that drives object streaming and scene-tab-switch detection (switching tabs tears down overlays on the scene being left and resets the dock, so tab swaps stay fast). |
| `highpoly_lib.gd` | Static helpers for the **Detail Mode** overlay: discovers downloaded models under `res://highpoly/<Name>/`, matches placed nodes to model keys (scene filename first, then name with trailing digits stripped), attaches/hides `_HIPOLY_PREVIEW` children, and runs the conservative auto-fitter (identity-first; wrong-shaped assets are rejected rather than shown distorted — see HIGHPOLY-PREVIEW.md §fitter). |
| `highpoly_mapcontext.gd` | The **Map Context** overlay: downloads per-map packages, rebuilds the full terrain from a raw 16-bit heightmap, injects the maptile decal + detail-terrain shader, the exact water plane, the distant backdrop, and the original object placements as distance-streamed MultiMeshes (mirrored instances get a winding-flipped mesh copy). |
| `highpoly_previews.gd` | Swaps the SDK Object Library thumbnails to renders of the active tier's models, remembering stock icons for restore. |
| `highpoly_turbo.gd` | Editor performance tools: distance cull, behind-camera cull for static map geometry, static-shadow toggle. Pure runtime property tweaks. |
| `highpoly_updater.gd` | Everything network: registry manifest fetch, per-model delta updates (content-hash sidecars), per-scene downloads, the full-library bundle, and **plugin self-update** (version check + zip-over-install). |
| `terrain_layers/*.png` | Tiling ground/cliff albedo+normal used by the detail terrain shader. |

## Data flow

```
registry host (Cloudflare R2, default baked into highpoly_updater.gd)
│
├─ plugin-manifest.json      prop name -> {glb, hash, med_glb, med_hash}
├─ godot/<mesh>.glb …        model renditions (full quality, Godot-loadable)
├─ bundles/…                 one-shot full-library zip
├─ maps/<MP_Map>/
│   ├─ mapdata.json          package metadata (sizes)
│   ├─ mapdata.zip           placements.json + height.r16 + backdrop glbs
│   └─ props.zip             that map's prop meshes (extracted into the SHARED cache)
└─ plugin/
    ├─ plugin-version.json   {"version", "zip", "notes"}
    └─ highpoly_toggle.zip   the plugin itself (self-update payload)
```

Local caches:

- `res://highpoly/<Name>/` — downloaded Detail Mode models + `<Name>.json`
  hash sidecars (what "Update Models" diffs against).
- `user://mapcontext/<MP_Map>/` — per-map terrain + manifest
  (+ `terrain_s<N>.res`, the locally-built terrain mesh cache per density).
- `user://mapcontext/_props/` — **shared** prop-mesh store, deduplicated across
  maps: a mesh used by five maps is downloaded and stored once.

### Map package format (`placements.json`)

```jsonc
{
  "map": "MP_Aftermath",
  "world":     {"min": -4096, "max": 4096, "cell": 64},   // streaming grid
  "heightmap": {"file": "height.r16", "res": 4097,        // raw uint16, row-major
                "world_min": -4096, "world_max": 4096,
                "base": 0.105, "scale": 110.566},          // h = base + raw/65535*scale
  "water":     {"height": 49.7, "center": [-35.7, 1.6],   // optional; exact plane
                "size": [5000, 5000]},
  "backdrop":  [{"name": "...", "glb": "backdrop/x.glb", "xf": [/*12 floats*/]}],
  "props":     [{"mesh": "<game mesh name>", "xf": [/*n*12 floats*/]}]
}
```

`xf` packs one 3×4 transform per instance: 9 basis floats (row-major) + origin.
Heights ship as raw `.r16` because Godot downsamples 16-bit PNGs to 8-bit.

## Updates

| What changed | What the user does | What happens |
|---|---|---|
| A prop model was fixed | **Update Models** | hash-diff against sidecars, download only changed files |
| A game patch changed a map | **Reload map data** | force re-download of that map's package |
| The plugin itself changed | click **Update Plugin → vX.Y.Z** (auto-appears) | zip extracted over `addons/highpoly_toggle/`, restart editor |

Publishing a plugin release (maintainer side): bump `version` in `plugin.cfg`,
commit, then upload `plugin/highpoly_toggle.zip` + `plugin/plugin-version.json`
to the registry host (the zip is the addon folder rooted at
`addons/highpoly_toggle/`). Installed copies pick it up on next editor start.

## Overlay node names (reserved)

- `_HIPOLY_PREVIEW` — a prop's Detail Mode overlay child.
- `_MAP_CONTEXT` — the whole Map Context subtree (terrain/backdrop/props/water).
- `_MAPTILE_DECAL` — the satellite maptile decal.

Any traversal that walks the scene must skip these (Detail Mode scans,
updater scene scans, etc.) — the map context alone is tens of thousands of
nodes.
