# Reading a map from the player's own Battlefield 6 install

Everything the map context draws used to arrive as a download: a per-map
`placements.json` plus roughly 6.6 GB of extracted geometry and textures under
`user://mapcontext`. That is redistribution of EA's assets, and replacing it is
the point of the reader.

It now reads the player's own installed game instead. Nothing is downloaded,
nothing extracted is shipped, and the only files written are derived from the
install and live in `user://`.

## What comes from where

| layer | source in the install |
|---|---|
| prop placements | the level walk (`bf6_walk.gd`) over the mounted SuperBundle |
| prop geometry | MeshSet resources (`bf6_meshset.gd`) |
| prop materials | ShaderBlockDepot state keys → textures (`bf6_depot.gd`, `bf6_texture.gd`) |
| skyline | the same walk — StaticModelGroups emitted from the level root |
| terrain | the terrain streaming tree, block 0 (`bf6_terrain.gd`) |
| water | `WaterSurfaceEntityData` in the level's default world part |
| roads and street markings | the level's TerrainDecals resource (`bf6_decals.gd`) |
| lights | `*LightEntityData` collected on the placement walk |
| FX spawn points | the walk's own `fx_*` rows, graphs from partition imports |

Still Python-only, and still the reason the download path has not been deleted:
prop layer attribution, gamemode layers, and the vegetation scatter kits.

## What it costs

Measured on MP_Dumbo, in the real editor through the real dock.

**First open of a map, ever** — 85 s of reading before the build starts:
mounting the install ~16 s, indexing 223k partition GUIDs ~19 s, walking the
level ~50 s. All three cache under the mounted TOCs' signature, so a game patch
invalidates them together and nothing else does.

**Every open after that** — 1.4 s to that same point.

**The build**, which is the part a user actually sits through:

| | build | what changed |
|---|---|---|
| first working version | 203.5 s | |
| repeated work removed | 87.2 s | map_data memoized, one open not six, no download |
| one mesh per look, not per scope | 50.9 s | 59% of the parses go away |
| geometry cache being written | 61.8 s | one time, +11.7 s of saving |
| **geometry cache warm** | **26.2 s** | 665 props/s against 79 at the start |

Reproducible within about 2% across three runs.

**Against the packaged download path it replaces** — which builds 2,761 props
where this builds 5,498:

| | packaged | from the install |
|---|---|---|
| build | 37.5 s | **26.2 s** |
| frame mean | 32.1 ms | **12.3 ms** |
| frame median | 23.4 ms | **6.9 ms** |
| 95th percentile | 53.3 ms | **30.3 ms** |
| 1% low | 65.9 ms | **48.1 ms** |
| draw calls | 6,114 | **3,490** |
| video memory | 15,511 MB | **6,179 MB** |
| texture memory | 14,511 MB | **5,312 MB** |
| props built | 2,761 | **5,498** |

Twice the props, a third of the build, half the frame time, 43% fewer draw
calls and 60% less video memory. The one metric that is worse is the worst
single frame, by 5%.

## The caches it writes

All under `user://`, all derived from the player's install, all keyed on the
mounted TOCs' signature so a game patch orphans them together:

| path | what | size on Dumbo |
|---|---|---|
| `bf6_index_<level>_<sig>.idx` | the mount: every catalogued EBX and RES | 91 MB |
| `bf6_pidx_<level>_<sig>.idx` | partition GUID → asset name | 30 MB |
| `bf6_walk_<level>_v3_<sig>.idx` | the placements and the collected lights | 23 MB |
| `bf6_geom/<level>_<sig>/` | one merged ArrayMesh per (MeshSet, LOD) | 339 MB |
| `mapcontext/<MAP>/height_game.r16` | the composited heightfield | 34 MB |
| `mapcontext/<MAP>/lights.json`, `fx.json` | what the light and FX layers read | small |

About 520 MB per map, against the 6.6 GB download it replaces. `Reset` removes
all of it.

## Three things worth knowing before changing any of this

**The walk is the expensive thing and it is cached; the build is what repeats.**
Optimising the reader means optimising `mesh_for`, not the walk. The phase table
in a session report splits the build into the CAS read, the parse, the materials
and the frame waits, and those want completely different fixes — parse was 89%
of it and the other three together were not worth touching first.

**A placement's depot scope is a graph ancestor, not a path ancestor.** A
prop's placement lives in a prefab partition under `game/.../props/`, and its
ShaderBlockDepot belongs to the subworld that *mounted* that prefab. There is no
path relationship between them. Matching by directory resolves 54.7% of
sections; inheriting the scope down the walk resolves 99.5%.

**Materials are keyed on content, and that is what makes the mesh sharing
possible.** Two subworlds that place the same prop resolve it through two
different depots and two different state keys, and 93% of the time the textures
come out identical. Key the material on (scope, key) and those are two objects;
key it on what it looks like and they are one — which is what lets a mesh built
for one scope serve another, and that is 59% of the parses on Dumbo.

## Running the harnesses

Everything under `native/` runs headless against a real install:

```
godot --headless --path native/_testproj --script test_walk.gd      -- mp_dumbo
godot --headless --path native/_testproj --script test_decals.gd    -- mp_dumbo [ref.json]
godot --headless --path native/_testproj --script test_scenery.gd   -- mp_dumbo
godot --headless --path native/_testproj --script test_meshshare.gd -- mp_dumbo
godot --headless --path native/_testproj --script test_geomcache.gd -- mp_dumbo 0
godot          --path native/_testproj --script vis_roads.gd      -- out.png mp_dumbo
```

and the end-to-end session, which boots the real editor, builds the map through
the real dock, flies the recorded path and writes the numbers down:

```
python tools/session.py --runs 1            # windowed: frame times are real
python tools/session.py --headless --runs 1 # boot and build only, ~2x faster
```

A new `class_name` under `addons/` needs one editor scan before other scripts
can see it; `--check-only` will report it as undeclared until then.
