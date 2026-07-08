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
| `highpoly_toggle.gd` | The `EditorPlugin` + the entire dock UI. Runs the startup sequence (migration wizard → sync-scope prompt → background sync), the auto swap-in debounce, and the 0.5 s timer that drives object streaming and scene-tab-switch detection (switching tabs tears down overlays on the scene being left and resets the dock, so tab swaps stay fast). |
| `highpoly_store.gd` | The v1.5 model store: `user://highpoly/` (index `store.json`, `models/*.glb`, `thumbs/*.png`). Runtime GLB → renderable `PackedScene` conversion (ImporterMesh → Mesh) with a session cache. On load, textures are recompressed to GPU-native S3TC (runtime GLTF parsing otherwise keeps them uncompressed — 4-8× the RAM/VRAM) and missing tangents are generated for normal-mapped surfaces (kills a per-draw renderer warning). Nothing lives in `res://`, so the editor never imports or scans anything. |
| `highpoly_sync.gd` | The background sync: manifest diff on startup + hourly, priority queue (open scene first, then just-placed props, then — in "full" scope — the rest of the library), 2 concurrent workers, full-library zip bootstrap, `model_ready`/`progress_changed` signals. |
| `highpoly_migrate.gd` | One-time reorganization of pre-1.5 installs: scans `res://highpoly`, shows real numbers in the wizard, moves GLBs + hashes into the store, deletes retired `_med`/`.obj`/import files, then triggers the plugin's final `EditorFileSystem.scan()`. |
| `highpoly_lib.gd` | Static helpers for the **Detail Mode** overlay: matches placed nodes to model keys (scene filename first, then name with trailing digits stripped), attaches/hides `_HIPOLY_PREVIEW` children, records not-yet-local props in `wanted` for the sync queue, and runs the conservative auto-fitter (identity-first; wrong-shaped assets are rejected rather than shown distorted — see HIGHPOLY-PREVIEW.md §fitter). |
| `highpoly_mapcontext.gd` | The **Map Context** overlay: downloads per-map packages (self-healing via ETag checks once per session), rebuilds the full terrain from a raw 16-bit heightmap, injects the maptile decal + detail-terrain shader, the exact water plane, the distant backdrop, and the original object placements as distance-streamed MultiMeshes (mirrored instances get a winding-flipped mesh copy). |
| `highpoly_collision.gd` | The **Collision** overlay: per-object `_COLLISION_VIS` duplicates of the proxy geometry rendered with a shared unshaded transparent material (color/alpha user-settable). Reproduces the game's collision-scaling rule — the collision shape uses the object's own geometry scaled **uniformly from the X axis** (visual scale (10, 20, 20) collides as (10, 10, 10)) — by composing `parent_inverse * (rotation * uniform_x_scale)` so the overlay stays correct under any parent transform. Also owns isolate-selection (selected objects show only collision; restore respects the active detail mode). |
| `highpoly_doors.gd` | Interactable-door swing: left double-click in the 3D viewport (via `EditorPlugin._forward_3d_gui_input`) ray-picks a known door proxy by local AABB and tweens its high-poly overlay leaf around the real hinge (hinge transform + swing angle per door in the plugin manifest's door specs, mined from the game's `interactabledoorcontrol` data). Open state is remembered on the node so mode switches rebuild it. |
| `highpoly_previews.gd` | Swaps the SDK Object Library thumbnails to locally-rendered previews of the high-poly models (off-screen SubViewport, cached to `user://highpoly/thumbs/`), remembering stock icons for restore. |
| `highpoly_turbo.gd` | Editor performance tools: distance cull, behind-camera cull for static map geometry, static-shadow toggle. Pure runtime property tweaks. |
| `highpoly_updater.gd` | Registry plumbing (manifest URL, throttling-aware fetch, ETag HEAD) and **plugin self-update** (version check + zip-over-install). Model downloading itself lives in `highpoly_sync.gd`. |
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

- `user://highpoly/` — the model store: `store.json` (schema + per-model
  content hashes; the single source of local truth), `models/<Name>.glb`,
  `thumbs/<Name>.png`. Hash-diffed against the manifest on startup + hourly;
  never touched by the editor's import pipeline.
- `user://mapcontext/<MP_Map>/` — per-map terrain + manifest
  (+ `terrain_s<N>.res`, the locally-built terrain mesh cache per density,
  + `etags.json`, the package ETags recorded at download for freshness checks).
- `user://mapcontext/_props/` — **shared** prop-mesh store, deduplicated across
  maps: a mesh used by five maps is downloaded and stored once. A republished
  `props.zip` (detected by ETag once per session per map) overwrites every
  mesh it carries — "file exists" alone never counts as current.

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

## Updates (all automatic since 1.5)

| What changed | What the user does | What happens |
|---|---|---|
| A prop model was fixed | nothing | startup/hourly manifest diff re-queues it; it swaps into open scenes as it lands |
| A game patch changed a map | nothing | per-session ETag check on the map's packages triggers a re-download (incl. overwriting shared prop meshes + rebuilding cached terrain) |
| The plugin itself changed | click **Update Plugin → vX.Y.Z** (auto-appears) | zip extracted over `addons/highpoly_toggle/`, restart editor |

Publishing a plugin release (maintainer side): bump `version` in `plugin.cfg`,
commit, then upload `plugin/highpoly_toggle.zip` + `plugin/plugin-version.json`
to the registry host (the zip is the addon folder rooted at
`addons/highpoly_toggle/`). Installed copies pick it up on next editor start.
The model-library site reads the same `plugin-version.json` for its version
badge, so a plugin release bumps the site version automatically — one version
number across the whole system.

## Overlay node names (reserved)

- `_HIPOLY_PREVIEW` — a prop's Detail Mode overlay child.
- `_COLLISION_VIS` — a prop's Collision overlay child.
- `_MAP_CONTEXT` — the whole Map Context subtree (terrain/backdrop/props/water).
- `_MAPTILE_DECAL` — the satellite maptile decal.

Any traversal that walks the scene must skip these (Detail Mode scans,
updater scene scans, etc.) — the map context alone is tens of thousands of
nodes.
