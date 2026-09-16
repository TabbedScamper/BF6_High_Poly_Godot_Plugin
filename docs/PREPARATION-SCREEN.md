# Up-front cache

High Poly caches everything once, up front, so any map opens with High Poly
straight away. Caching starts as soon as a verified Battlefield 6 installation is
selected. While it runs, a screen covers the editor window, and the High Poly
panel stays locked until every stage has finished. There are no manual
"Prepare maps" or "Build object previews" buttons.

The supervisor (`highpoly_preparation.gd`) runs three stages in order:

1. **Game cache** - the shared C++ cache from BF6_High_Poly_Core
   (`bf6_precache_*`, exposed on `BF6Core` as `precache_open`, `precache_start`,
   `precache_status`, `precache_cancel`, `precache_map_ready` and
   `precache_sweep`). For every map it stores placements, mesh and texture
   references, and terrain and water heightfield references. Textures and
   geometry are referenced in the game's archives rather than copied, so a
   whole install is about 1 GB. It runs on a native thread, and status is
   polled every 250 ms (about 0.3 ms per poll).
2. **Map index** - each map's mount index, partition index and placement walk,
   plus the order in which the map asks for its textures. The work runs in
   headless worker processes (`highpoly_prepare_worker.gd`, index-only jobs),
   up to three at a time depending on memory. The mount and partition index are
   written by the core from its stored mount (`BF6Core.write_reader_index`), so
   the script only walks the placements. The walk's decoder plans structs made
   only of scalars once per type, selects each type's wanted fields once, and
   resolves each field type once (`bf6_ebx.gd`), with output identical to the
   generic decode. A cold job takes 7.1 s on mp_outskirts and 11.1 s on
   mp_aftermath (38,226 placements), and a cold mp_dumbo open 9.0 s against
   27.9 s before those decoder changes. Each job uses about 180 MB. A map that
   fails is recorded and skipped; it indexes itself when first opened.
3. **Object previews** - library icons, rendered by the editor through the
   plugin's `previews_run` hook.

The game cache lives in `%LOCALAPPDATA%/BF6HighPoly`, shared with the Unreal
plugin. Map indexes live in the project's `user://`.

## How a map opens from the cache

- **Geometry.** Every placed mesh's surfaces are decoded and merged in C++
  (`bf6_precache_mesh_surfaces`), a few hundred meshes at a time across all
  cores. The merge follows the add-on's reader rules: shadow and depth sections
  dropped, the TexCoord4 unwrap, winding, hidden destruction parts, palette
  splits and the car paint wrap channel. The add-on keeps its depot decisions and
  only builds the finished surfaces. No mesh files are written, and the old
  `user://bf6_geom` folder is removed.
- **Textures.** The recorded texture order drives a read-ahead on its own
  thread. It locates the next 64 textures through the add-on's own source, then
  reads and decompresses their first-choice chunks in parallel
  (`bf6_cas_read_batch`), within a 1.5 GB budget. The build thread only picks
  up finished entries, so the decoder receives exactly the bytes it would have
  fetched without waiting for them. A request the producer has not reached is
  read live and moves the producer to that point.

Measured on MP_Dumbo (6,588 mesh groups, 4,001 textures), with the placement walk
already indexed:

| Build of every placed mesh and material | Time |
| --- | --- |
| GDScript reader, no geometry cache | 37.8 s |
| Old per-map mesh files (warm) | 17.2 s to 33.5 s |
| Native decode and merge, textures live | 22.3 s |
| Native geometry, texture read-ahead on the build thread | 18.3 s |
| Native geometry, texture read-ahead on its own thread | 13.0 s |

## Invalidation

- The game cache key is the installation identity plus the core recipe and format
  versions. A game patch or a core change produces a new key. When the cache is
  opened, older keys of the **same installation folder** are removed; a second
  storefront copy keeps its own cache. Every map records its layer versions in
  `complete.json`, so bumping one layer rebuilds only that layer's maps.
- Map indexes are keyed by the installation identity plus the reader scripts
  (`Cache.reader_recipe`: `bf6_source`, `bf6_walk`, `bf6_ebx`, `bf6_types`,
  `bf6_cas`, `bf6_bundle`, `bf6_toc`, `bf6_container` and the install cache). An
  add-on update that leaves those scripts alone keeps every index. Their stored
  formats still carry explicit version constants. After a map is indexed, its
  index files with any other signature are deleted.
- Previews and the recorded texture order follow the whole add-on recipe. An
  add-on update keeps every map index but records each map's texture order
  again. The worker's walk is then a cache hit, so this costs only the
  recording. A stale order only lowers the read-ahead hit rate; it never changes
  what is drawn.
- High Poly unlocks when the game cache and map indexes are ready. Object
  previews render afterwards, on the screen or behind it after Return to editor,
  and do not hold the lock.
- On a normal start everything is verified, not rebuilt. A complete 28-map game
  cache verifies in under 10 ms without mounting the game. The screen is shown
  only when a stage has real work to do.

## Progress

Overall progress is weighted by stage (game cache 0.35, map index 0.50, previews
0.15) and never runs backwards within a run. The screen shows:

- one bar per stage;
- a live activity line. For the game cache it gives the current map, layer and
  item, and while a long step such as opening a level reports nothing it adds
  "working, N s" instead of looking frozen. For the map index it lists each
  running map with its stage and elapsed time;
- one row per map, showing game-cache progress with the current layer, and the
  index state. A running map's index bar moves with elapsed time against the
  measured duration of maps already indexed.

## Control

- **Pause** stops after the current step. The game cache keeps completed maps,
  and index workers stop cooperatively.
- **Resume** continues from what is already complete.
- **Return to editor** hides the screen. Caching continues, and the panel shows
  "Show caching progress".

While the screen is up, the editor's 3D viewports are suspended and restored
afterwards. A failure stays on screen with its error, and High Poly remains
locked until a retry succeeds.

## Service API (version 2)

```gdscript
var preparation = get_tree().get_first_node_in_group("bf6_highpoly_preparation_v1")
if preparation != null and preparation.API_VERSION >= 2:
    if preparation.cache_ready: pass
    preparation.ready_changed.connect(func(is_ready): pass)
```

`prepare_levels(levels)` remains for map selectors. Every map is cached up
front, so it returns true when the named maps are valid and the cache is either
ready or working towards it.

## Validation

- `tools/test_preparation_supervisor.gd` drives the real supervisor and screen
  with a scripted core. It covers stage order, locking until ready, progress that
  never runs backwards, verify-only restarts, reader-only and add-on-only update
  invalidation, index-file sweeping, pause and resume, failure and 28-map layout.
- `tools/test_meshset_native.gd` compares the native section decode with the
  GDScript reader, field by field, over every mesh of a map, in every mode. It
  passes on MP_Dumbo and MP_Aftermath (51,725 sections).
- `tools/test_mesh_assembly.gd` compares native assembly with the script merge
  for every placed group. It passes on MP_Dumbo (6,588 groups, 228 palette
  splits) and MP_Aftermath (9,098 groups, 313 splits); with `precache` it passes
  through the cache, with the cache's hidden parts.
- `tools/test_native_reader_index.gd` compares the core-written reader index with
  the script-built one: every key, sizes, types and the whole partition index.
  The only differences allowed are which copy of a same-size duplicate asset
  wins, because the core mounts its shared archives in the order Unreal reads.
- `tools/test_ebx_plans.gd` decodes every instance of every partition under a
  level with the planned decoder and the generic one, in full and through the
  walk's two field filters, and compares them with `var_to_str`. It passes on
  mp_limestone (249,252 decodes).
- `tools/test_map_props_digest.gd` digests every placed row, the mesh group
  table and each built mesh's texture bindings. It is identical with either
  index on mp_battery and mp_dumbo.
- `tools/test_cas_read_batch.gd` compares the batch reader with
  `BF6Source.get_chunk` for every texture chunk a map names. It passes on
  MP_Dumbo (6,924 chunks, 20.3 GB).
- `tools/test_texture_prefetch.gd` decodes textures from cached headers and
  chunks against live reads.
- `tools/bench_mesh_build.gd` times a map's complete mesh and material build,
  with a breakdown.
- The core's store tests live in BF6_High_Poly_Core (`precache_test`, 45
  checks).
