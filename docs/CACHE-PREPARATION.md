# Preparing local map resources

The add-on download contains the reader and editor tools. Prepared game assets
are created locally from the selected Battlefield 6 installation and are not
included in the download. Selecting a verified installation with no preparation
record starts a queue, with the open map first. Each worker mounts one map.
Discovered multiplayer folders can include unsupported variants; failures are
recorded while later maps continue.

Pending work is reordered before each map starts: the open map first, then
saved or recently used maps, then the remaining maps. Opening another map moves
it to the next available slot; the active worker finishes its map first. Godot
reads saved scene headers and editor history without opening creator scenes.
The panel shows the active map, stage and remaining queue, including when work
is waiting or paused. A short startup grace period lets the editor restore its
scene before choosing the first map.

The installation panel provides progress, pause/resume, a game-update check,
and a current-map rebuild. A saved queue retains interrupted work. Godot waits
for Resume after an interrupted session; Unreal restores an unpaused queue.
Workers run separately from the editor, preserve completed cache files when
stopped and never open or save creator scenes. A worker lease prevents two
editors from preparing the same cache simultaneously. The second waits for
the user to resume after the first finishes.

Preparation requires at least 4 GB available memory to start and preserves
8 GB free disk space. These are resource guards, not a guarantee of performance
on a 16 GB computer. Derived files are additional disk usage. Old generations
are retained; automatic size limits and eviction are not implemented yet.

## Game updates and ongoing fixes

Both hosts use the same source-identity algorithm. It inventories game archive
paths, sizes and timestamps, hashes TOC contents and includes executable
metadata. A background check runs every five minutes and can be requested
manually. Missing or unreadable inputs cannot produce a valid identity.
Normal game updates therefore select a new cache generation and show a rebuild
notice. A deliberately edited archive with identical size and timestamp is
outside this fast detector's guarantee.

The cache identity also includes actual reader, engine and add-on recipe
inputs. Shader or decoding fixes therefore invalidate derived resources even
when the game version is unchanged. Each engine retains its own reader ABI
and output format. Never substitute Unreal's native DLL for Godot's.

Caches are disposable, not authoring data. Continue editing props, materials,
terrain and maps in source. Use **Rebuild current map cache** in Godot or
**Prepare current map** in Unreal to decode that map again. Use development
cache bypass to test changes without serving disk entries, then rebuild the
scene. Unreal's console switch is `BF6.HighPoly.CacheBypass 1`. Live Coding
does not rewrite every loaded recipe DLL: use bypass during that workflow,
then a normal rebuild and editor restart for a persisted generation.

Restart Unreal after a detected in-session game/add-on change before reading
new assets. Godot drops source and derived in-memory state on the next map
open when its source/recipe key changes. Restart after installing native DLL
updates. Existing scenes, authored scripts, blocks and UI files are not cache
artifacts and are never removed by preparation.

Recipe invalidation is conservative: a code change can invalidate resources
for every map. Dependency-specific automatic rebuilds and cross-engine prepared
GPU resources are future work. A current-map rebuild targets one map, not only
the individual props whose source changed.

## What this prepares

Godot prepares existing undressed geometry resources. Palette-specific meshes
that cannot safely share that format continue to decode at map open. Unreal
prepares its existing packed placed-object geometry and texture blobs.
Prepared files are validated at use; missing or malformed entries fall back
to live decoding. A partial or crashed worker is never reported as a completed
map. Preparation reports remain local alongside the cache.

This does not yet prepare a complete engine-ready map. Terrain, water, scene
construction, material work and GPU mesh builds remain in the load path.
Neither instant map loads nor the 10-second full-map target have been measured
or achieved by this preparation stage.

On the development installation, Tsuru preparation produced 1,335 unique
Godot geometry resources with 103 groups still requiring live decode. All
1,335 loaded meshes matched the previous path's geometry and surface data;
serialized file bytes differed. Unreal produced 3,031 mesh blobs and 1,462
texture blobs with no reported failures. A second worker reused every one.
These are preparation checks, not whole-map load benchmarks or EA-install
hardware validation.
