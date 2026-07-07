# v1.5.0 — Seamless model sync (design)

The goal of 1.5: **no model-management buttons**. Models arrive on their own,
the scene you're looking at always comes first, stale data heals itself, and
the one-time reorganization of existing installs is explained before it runs.

Removed from the dock: **Update Models**, **Download Full Library**,
**Re-apply Scene**, **Reload map data**. Their jobs are automated. Kept:
detail mode selector, Selected → tier, Map Context toggles/sliders, Turbo,
Purge — plus a new progress bar with a pause toggle.

---

## 1. Why (the problems this fixes)

### 1.1 Launch + bulk-update slowness
Models used to live under `res://highpoly/<Name>/<Name>.glb` with
`importer="scene"`. Every download ended with an `EditorFileSystem.scan()`,
so the editor re-imported every GLB (844+ props × high tier ≈ thousands of
`.godot/imported/*.scn`), and re-validated the tree on every launch. The SDK
itself avoids this for its 9.5k raw GLBs by marking them `importer="skip"`.

Per-prop downloads were also N sequential GETs against a host that throttles
bursts (r2.dev).

### 1.2 Wrong props on specific maps
Map-context prop meshes (`user://mapcontext/_props/<mesh>.glb`) were keyed by
name only and validated by *file existence* only. Once cached, a mesh was
never re-fetched — so when the registry republished a mesh under the same
name (fix-train, prefab assemblies, game patches), every user who already had
it kept the stale one, on every map, forever. **Reload map data** didn't help:
it only deleted `placements.json`, leaving props and built terrain caches in
place. The website reads the registry live, hence "Godot disagrees with the
site".

---

## 2. Storage: the model store (`user://highpoly/`)

```
user://highpoly/
  store.json           index: schema version + per-model {hash, nofit, bytes}
  models/<Name>.glb    one file per SDK proxy name (godot rendition)
  thumbs/<Name>.png    object-library thumbnails rendered locally (§7)
```

- Nothing under `res://` → the editor never scans, imports, or re-validates
  anything. Launch cost is zero regardless of library size.
- GLBs are parsed at runtime via `GLTFDocument` (the same proven path map
  context already uses), converted once per session to a renderable
  `PackedScene` (ImporterMesh → Mesh), and cached in RAM.
- `store.json` is the single source of local truth (replaces the per-prop
  sidecar `<Name>.json` files). It carries a `schema` int so any future
  reorganization is just another numbered migration.
- Currency = content hash from the registry manifest, same as 1.4's updater —
  but now enforced everywhere, including map context (§5).

## 3. Sync manager (`highpoly_sync.gd`)

A background, signal-driven downloader owned by the dock. No UI beyond the
progress bar; never blocks the editor.

**Startup (each editor session):**
1. Fetch `plugin-manifest.json` (one small GET, fail-quiet with retry).
2. Diff every manifest entry against `store.json` hashes → stale/missing set.
3. Queue work by priority (below) and start 2 workers (2 concurrent
   `HTTPRequest`s; more trips r2.dev throttling; per-request retry/backoff).

**Priority queue (front to back):**
1. Props in the edited scene (re-prioritized on scene tab switch).
2. Props just placed by the user (jump the queue; swap-in within seconds).
3. Everything else — only in *full-library* scope (§6).

**Signals:** `model_ready(name)`, `progress(done, total, phase)`,
`state_changed(paused/idle/syncing)`.

**Swap-in:** the dock batches `model_ready` events on a 0.5 s debounce, then
runs one scene walk applying overlays for any node whose key just became
available (only while a detail mode is active). The proxy is the placeholder;
nothing ever looks broken while waiting. This removes both **Re-apply Scene**
(auto after downloads; mode changes still apply immediately) and the
"download for this scene?" prompt (scene props are simply queued first).

**Bootstrap:** with an empty store and *full-library* scope, sync first pulls
the existing `bundles/highpoly-library.zip` (one multi-GB GET, resumable to
the extent HTTPRequest allows; on failure it falls back to per-file sync),
extracts straight into the store (skipping retired `_med` files), records
hashes from the bundled sidecars, then hash-diffs to top up. After bootstrap,
everything is deltas.

**Index writes:** `store.json` is flushed every 25 ingests and on idle/exit,
not per file.

## 4. What replaces the buttons

| 1.4 button | 1.5 behavior |
|---|---|
| Update Models | startup manifest diff + hourly re-check re-queues changed models automatically |
| Download Full Library | *full-library* scope (§6) syncs in the background via the bundle |
| Re-apply Scene | auto swap-in on `model_ready`; mode changes apply immediately |
| Reload map data | per-map freshness check on every map load (§5) |

## 5. Map-context self-healing

On the first load of a map each session, before building:

1. `HEAD` `maps/<Map>/mapdata.zip` and `maps/<Map>/props.zip`; compare ETags
   against the ones recorded in `user://mapcontext/<Map>/etags.json`.
2. `mapdata.zip` ETag changed (or never recorded) → re-download it, re-extract,
   and delete that map's `terrain_s*.res` caches so terrain rebuilds.
3. `props.zip` ETag changed (or never recorded) → re-download and extract
   **overwriting every mesh the zip contains** in the shared `_props` cache
   (no more "exists = current").

Because no existing install has recorded ETags, the first 1.5 session
re-pulls each map's packages once as it's opened — retroactively healing every
currently-stale install without a button or a server change. ETags come free
from R2; no publishing pipeline changes required.

(The known-but-separate data issues — pre-patch `portal_maps.json`/Granite
renames and unfiltered low-tier rows in `matches.tsv` → `plugin-manifest.json`
— are pipeline/registry fixes, out of scope for the plugin. This mechanism
makes the plugin pick the fixes up automatically once republished.)

## 6. First-run scope choice (the only question we ever ask)

One dialog, once, after migration / on fresh install:

> **How should models download?**
> • **Full library** — everything syncs in the background (~X GB once,
>   deltas afterwards). Best if you build a lot.
> • **As needed** — only models your open scenes use.

Stored in `store.json`; changeable later via the project setting
`highpoly/sync_scope`. Map packages keep their existing one-time per-map
download prompt (they're per-map sized and obvious in context).

## 7. Object-library thumbnails

`EditorResourcePreview` only works for imported `res://` resources, so 1.5
renders its own: instantiate the store scene into an off-screen
`SubViewport`, frame the AABB, grab one frame, cache to
`user://highpoly/thumbs/<Name>.png`. Rendered lazily (one at a time, only for
items visible in the object library) and invalidated by hash on model update.

## 8. Migration wizard (existing installs)

Triggered in `_enter_tree` when `store.json` is absent but legacy data exists
(`res://highpoly/*` and/or `user://mapcontext/_props/*`). One dialog, real
numbers computed from a scan, nothing touched until confirmed:

> **High-Poly Preview 1.5 reorganizes its storage**
> • Move N models (X GB) into the new cache — no re-download
> • Delete N editor import files and N retired medium-tier models (frees X GB)
> • Re-download N models whose fixed versions you don't have
> • Map data re-checks itself automatically from now on
> Your scenes, the SDK proxies, and the Portal exporter are unaffected.
> [ Reorganize now ]   [ Not yet ]

- **Move:** `<Name>.glb` → `models/`, hash carried over from the old sidecar
  (rename first, byte-copy fallback across volumes). `_med.glb`, `.obj`, and
  sidecars are deleted (`_med` retired in 1.4; `.obj` predates GLB and simply
  re-syncs as GLB if the registry has it).
- **Then:** delete the `res://highpoly` tree and run one final
  `EditorFileSystem.scan()` — the last scan the plugin ever triggers.
- **"Not yet"** is safe: plugin runs read-only legacy mode (overlays still
  work from `res://highpoly`, no sync), a banner shows "Reorganization
  pending", and the wizard re-offers next launch.
- Idempotent: `store.json` is written only on completion; a crash mid-move
  just re-runs the wizard (already-moved files are skipped).
- `user://mapcontext/_props` is left in place; §5 heals it per map on load.

## 9. Compatibility

- The self-update contract (`plugin/plugin-version.json` +
  `plugin/highpoly_toggle.zip`, extracted over the install dir) is unchanged —
  1.4.x installs update into 1.5 through the existing button.
- No server/publishing changes are required. Optional later: sharded delta
  bundles (`bundles/shards/*.zip` + hash manifest) to reduce per-file GETs for
  large updates; the client falls back to per-file sync when absent.
- Saved scenes are byte-identical, as always: overlays stay `owner = null`.

## 10. File map

| File | Role in 1.5 |
|---|---|
| `highpoly_store.gd` *(new)* | store paths, `store.json` index, runtime GLB → PackedScene loading + cache |
| `highpoly_sync.gd` *(new)* | manifest diff, priority queue, workers, bundle bootstrap, signals |
| `highpoly_migrate.gd` *(new)* | legacy scan (counts/sizes) + migration execution |
| `highpoly_lib.gd` | overlay logic reads the store (not `res://highpoly`); legacy fallback until migrated |
| `highpoly_updater.gd` | slimmed: manifest fetch + plugin self-update only |
| `highpoly_mapcontext.gd` | ETag freshness pass, overwrite-on-refresh props, terrain cache invalidation |
| `highpoly_previews.gd` | local SubViewport thumbnail renderer |
| `highpoly_toggle.gd` | simplified dock, progress bar + pause, wizard + scope prompts, swap-in debounce |
