# GRANITE — one world, eight levels, end to end

The Granite world (the BF6 battle-royale coastline) ships as **eight complete
levels**: the BR host `game/glaciergranite/levels/mp_granite` and the seven
Portal slices under `game/glacierportal/levels/`:

```
mp_granite_clubhouse_portal      mp_granite_militarystorage_portal
mp_granite_mainstreet_portal     mp_granite_techcampus_portal
mp_granite_marina_portal         mp_granite_underground_portal
mp_granite_militaryrnd_portal
```

**None of these live under `game/glaciermp/levels/`** — anything that roots its
level walk there finds no Granite level at all. (The `granitebr*` partitions
inside `mp_tungsten` noted in MAP-TUNGSTEN.md are Tungsten-hosted BR content and
are unrelated to this world.)

Every claim below is tagged MEASURED or HYPOTHESIS. Probes live in
`tools/probe_granite_*.py` (they reuse the `probe_tung_*` plumbing and redirect
its level roots):

```
probe_granite_common.py       slug -> level root / terrain dir for all eight
probe_granite_terrain.py      probe_tung_terrain on a Granite level
probe_granite_layers.py       probe_tung_layers on a Granite level
probe_granite_types.py        probe_tung_types on a Granite level
probe_granite_layout.py       EXACT per-node chunk decomposition (block-1
                              storedPageCount join) + trailer BC7-mode test
probe_granite_decomp.py       chunk-GUID overlap between the eight levels
probe_granite_colorrender.py  colour-map renderer: BC1 and BC7 families,
                              writes the FIXED_*.png evidence set
```

## 0. The world in one paragraph

**MEASURED.** Granite is an **8,192 x 8,192 m** world (block-0 root AABB
`x,z ∈ [-4096, 4096]`, twice Tungsten's span), ground y 0.117..743.411,
`WorldSizeY = 850.0`, xs = 265 (height payload 149,297 B — same as Tungsten),
density tree xs = 137 (payload 39,919 B). All eight levels share this exact
root AABB and Y range: they are eight bakes of one authored world. The terrain
directory is named after the **source world**, not the level:
`terrain_mp_granite_8k_512tile_01` on base + underground,
`terrain_mp_granite_8k_512tile_01_copy` on the other six.

---

## THE DECOMPOSITION TABLE

**MEASURED — the eight levels split into two bake families with different page
sizes and different colour-map codecs.** Per-node exact decomposition
(`probe_granite_layout.py`, joining block-1 `storedPageCount` per node, so
nothing is guessed): `primary = heightPrefix + storedPages x pageSize +
residual`, prefixes exactly {0, 39919, 149297, 189216} as everywhere else.

| level | tree B | dir nodes | page | residuals (count) |
|---|---|---|---|---|
| mp_granite (base) | 8,502,004 | 1,397 | **2592** | 26136 (1095), 8712 (224), 17424 (64), 0 (5), odd 27203..27214 (8, keys 0x3133*) |
| underground | 8,590,748 | 1,397 | **2592** | identical shape to base |
| clubhouse | 6,071,908 | 1,561 | **2592** | 26136 (1062), 17424 (267), 8712 (174), 0 (6) |
| mainstreet | 5,809,984 | 1,561 | **2592** | 26136 (1062), 17424 (267), 8712 (174), 0 (6) |
| techcampus | 6,207,876 | 1,601 | **2592** | 26136 (1076), 17424 (282), 8712 (172), 0 (6) |
| marina | 12,628,510 | 1,749 | **5184** | 17424 (982), 85024 (474), 67600 (198), 0 (80) |
| militaryrnd | 12,576,643 | 1,749 | **5184** | same as marina |
| militarystorage | 12,564,969 | 1,749 | **5184** | same as marina |

Zero negative residuals and <= 4 residual classes at the stated page size on
every level (the wrong page sizes give 17–78 classes or hundreds of negatives).
**The expected "2592 per the derived table" holds for five of the eight; the
marina family is 5184** — a page size previously seen only on plaza.

### The colour tile is BC1 on the 2592 family — a new codec, and the mode test lies here

**MEASURED.** On base/underground/clubhouse/mainstreet/techcampus the residual
decomposes as:

```
26136 = [ 8,712 B  BC1 132x132 colour tile ]            <- colour is FIRST
        [ 17,424 B BC7 mode-3 CONSTANT-block tile ]     <- degenerate second raster
17424 = [ 8,712 BC1 colour ][ 8,712 second raster ]
 8712 = [ 8,712 BC1 colour ]
```

8,712 B = 33x33 8-byte blocks = one 132x132 **BC1** tile. Decoding the first
8,712 trailer bytes as BC1 and mosaicking coarse-first produces a seamless
aerial photo of the Granite coastline (`FIXED_MP_Granite.png`); the same bytes
decoded as raw planes, BC4, or BC7 are noise — all three were tried and ruled
out (`probe_granite_colorrender.py` docstring records the eliminations).

**MEASURED — the BC7 mode-histogram law is NOT a safe discriminator here.**
Two failure directions on one map:

- Real BC1 colour tiles read as mode-3-dominated "not colour" under the BC7
  mode test (BC1 byte 0 is a colour-endpoint byte).
- 48 pure-ocean tiles (17,424-byte primary chunks, depth 6) read as **"100%
  BC7 mode 6"** under the mode test — they are actually uniform navy **BC1**
  tiles whose endpoint bytes happen to have bit 6 set. A codec detector must
  decode-and-look (or check block diversity), not just histogram the mode bits.

### The marina family is classic BC7 — plaza/survey tile sizes

**MEASURED.** marina/militaryrnd/militarystorage trailers:

```
85024 = [ 67,600 B BC7 260x260 colour tile ][ 17,424 B 132 mip ]   <- colour FIRST
67600 = [ 67,600 B BC7 260x260 colour tile ]
17424 = one BC7 tile, 100% mode-3 constant blocks -> NO colour (ocean/edge nodes)
```

Their 67,600-byte tiles are 97% mode 6 / 2% mode 7 — the classic image
signature — and render into the same aerial photo
(`FIXED_MP_Granite_Marina_Portal.png`, mean RGB (0.364, 0.367, 0.335)).
67,600 = the plaza tile, 85,024 = the survey mip pair from TERRAIN.md §5.3.

### Rendered colour maps (deliverable #2)

All eight written to `%APPDATA%/Godot/app_userdata/Battlefield™ Portal
Project/_cmapprobe/FIXED_MP_Granite*.png` by
`probe_granite_colorrender.py --all`. One sentence each: **base and underground
read as a complete, seamless aerial photo of a southern-California coastline
(city, harbor, mountain chaparral, dark-teal ocean with an offshore island);
the six slice levels read as the same photo with their own playable slice
replaced by constant-colour filler tiles** (see below). Means: base/underground
(0.304, 0.351, 0.326), clubhouse (0.348, 0.342, 0.317), marina family
(0.364, 0.367, 0.335).

**MEASURED — the colour map is authored-absent over each slice's playable
area.** Clubhouse's 267 trailer-17424 nodes (the contiguous block over its play
space) hold constant blocks in BOTH halves — mean (0.192, 0.047, 0.129), 1–43
distinct 16-byte blocks per tile — and their paired chunks are 8 x 8,712 of the
same constant. There is no colour data to find for those nodes. **Consequence
for the plugin: a constant-filler tile must be detected (block-diversity or
variance test) and skipped, or the play area gets painted uniform dark maroon;**
the vista ring is where the colour map carries real signal on slice levels. On
base/underground the colour map covers everything including the ocean.

---

## A. Water

**MEASURED** (`water_global.ebx` per level — note the name; there is no
`_layers_content/water.ebx` on any Granite level, and no `_layers_*` convention
at all):

| level | water y | plane | terrain floor | notes |
|---|---|---|---|---|
| base | 0.000 | 8192 x 8192, QBHE (4096, 0.5, 4096) | 0.117 | + 28 `AABBData` + `FBPhysicsComponentData` in the same partition |
| underground | 0.000 | same | 0.117 | same 28 AABBs |
| clubhouse, mainstreet, marina, militaryrnd, militarystorage, techcampus | **99.873** | same | 0.117 | no AABBs |

- One `WaterSurfaceEntityData` per level (32 instances in base's partition are
  1 surface + 28 AABBData + components). `QueryBoxHalfExtent` = (4096, 0.5,
  4096) with `TileOffset` absent from the readable rows — consistent with
  MAP-TUNGSTEN §A4.
- **The six slice levels raise the ocean plane ~100 m** to the city plateau's
  elevation; base/underground keep it at sea level y = 0, which is 12 cm below
  the terrain floor (0.117) — the ocean floor is barely above the plane.
  HYPOTHESIS: the 28 AABBs on base/underground are water inclusion/interaction
  boxes (they sit over the city at y ~ -58..397 with 60–2000 m extents); their
  exact semantic was not decoded.
- Water y above terrain floor on ALL eight → the water-vs-floor diagnostic
  (MAP-TUNGSTEN §A3) says water is drawable everywhere here, unlike
  tungsten/eastwood.

## B. Terrain and ground layers

**MEASURED — per-level compiled palettes, all keys resolving 100% in their
depot** (`probe_granite_layers.py`; table located by the all-keys-resolve rule,
which fired at offsets 280/260/252 — the weaker "distinct keys" rule again finds
wrong-but-plausible tables earlier in the file):

| level | layers | LayerSlotCount | block-7 pairs | bg index | distinct layer textures |
|---|---|---|---|---|---|
| base | 63 | 62 | 16 | 0x00000080 (none) | **151** |
| underground | 63 | 62 | 16 | 0x00000080 | (base twin) |
| clubhouse | 58 | 62 | 13 | 0x00000080 | 130 |
| mainstreet | 57 | 62 | 13 | 0x00000080 | — |
| techcampus | 56 | 62 | 13 | 0x00000080 | — |
| marina family | 56 | **6** | 13 | 0x00000080 | 95 |

- **CONTRADICTS the "painted layers are textureless" absolute:** on Granite the
  PAINTED layers bind full `_cv/_nhs/_ao` texture sets (wum_ westusmountain
  library: gravelgrass, sand, driedgrass, redsoil, oakshrub, dirtroads,
  distance-series...). 151 distinct layer textures on base vs Tungsten's 8.
  Tungsten's split is a per-map authoring choice, not an engine law. The
  honest-ceiling logic of MAP-TUNGSTEN §B4 does not transfer: Granite's ground
  is texture-rich on both sides of the painted/base split.
- Many layers bind a **second, `distance` texture set** in slots
  `0x2E5ACDA8/_cv 0x2E5ACDF3/_ao 0xF9B44F08/_nhs` (near/far texture pairs), a
  breakup mask at `0x0B725504`, scatter noise at `0xEB1B291C`. These slots are
  not in the four-slot table of TERRAIN.md §10.3 and are worth adding to the
  terrain-layer slot table.
- **`0xAE16A5C0` crater slot confirmed** — exactly one layer binds `hfd_debug`
  (base: the layer L57–L61 link to, i.e. L56), reproducing the
  tungsten/dumbo structure.
- Unidentified constants, Granite's evidence: `0xCBB9A946` = (0,0) on all 48
  carriers (again never used); `0x4C200FE0` mostly 0.0 here; `0xCF3F97E0`
  integer values {0, 4} (again NOT float); `0x2F9990B7` ∈ {50, 100} (vs
  0.33..1333 on tungsten — scale-like, still unidentified); `0xF7652FB3`
  ∈ {2, 20}.
- `LayerSlotCount` is 62 on the 2592 family and **6** on the 5184 family — the
  same still-unexplained 6-vs-62 split as tungsten(6)/dumbo(62); it correlates
  with bake generation, not with layer count.
- Splat totals: base 107,103 records / 1,217 nodes; marina 309,165 records /
  3,509 nodes (the 5184 family re-splats the world at ~3x the node count).

## C. Decals and roads

**MEASURED.** `decals.TerrainDecals` sits nested inside the terrain dir's
`_game/<branch>/levels/<level>/<level>/` mirror:

| level | size | slotCount (used) | records |
|---|---|---|---|
| base | 81,448,508 | 62 (8) | **13,390** |
| underground | 81,385,932 | 62 (8) | 13,380 |
| mainstreet | 77,609,028 | 57 (9) | 12,865 |
| techcampus | 74,923,056 | 56 (9) | 12,173 |
| marina | 63,886,404 | 56 (7) | 10,569 |
| clubhouse | 62,439,316 | 58 (9) | 9,663 |
| militaryrnd | — | — | **none** |
| militarystorage | — | — | **none** |

- 13,390 records ≈ 22x Tungsten's 613 — the whole city's road network is
  terrain decals; slotCount equals layerCount-ish per level as on Tungsten.
- **Two levels ship NO TerrainDecals resource at all** (militaryrnd,
  militarystorage). A decal reader must treat absence as a legal state, and
  those two levels will legitimately have no decal roads. (Their splat/block-7
  and 10.2 MB block-1 are the same as marina's, so their ground is not
  otherwise degraded.)

## D. Everything else notable

**MEASURED — structure.** No `_layers_world` / `_layers_content` convention:
the base level is a FLAT directory with 987 subdirectories (POI-organised:
`oceanpark_*`, `duel_*`, `granitebr*`, `granitegauntlet32*`, `graniteloot`,
...). The seven Portal levels each carry a **3x3 subworld grid
`area_00..area_22`** at the level root, each area with its own
`staticmodelgroup.physics.PhysicsResource`,
`staticmodelgroup_doordamagetrigger_physics`, and `meshvariationdb_win32.ebx`;
plus `world/`, `gameplay/`, `portal/`, `customportal/`, `freeroam0/`,
`roads/`, `vista_lg/`, `vista_med/`, `vistas/`, `reflectionvolumetexture/`.
Base has **no** area grid.

**MEASURED — vista/backdrop meshes exist, per level, pre-baked.**
`<level>/vistas/` holds 315–408 MeshSets per level named
`zsa_large_granite_s_vista_*_portal_<slice>` with their textures beside them —
the skyline/backdrop meshes the open task list asks about, already sliced per
level.

**MEASURED — the Underground level.** Its terrain is the SAME surface terrain
as base: blocks 4, 5, 7 are byte-identical to base's; block 0 differs by 158
bytes (0.43%), block 2 by 10%, block 1 by 231 B, and block 8 (mask raster) is
+88,975 B larger. The underground facility itself is ordinary prop placement:
underground-only layers `area_01..area_05` with `_base / _cover / _decals /
_emergencylighting / _lighting / _lightingvolumes / _setdressing / _vfx`
sub-layers per room (mainroom, flowandchemtesting, labandserverroom,
shippingandtunnels), and the level's `area_11.ebx` is the fleet's largest
(2.49 MB). Its lighting dir carries `ve_*_area04_tunnel_1/2/3` presets.
HYPOTHESIS: the tunnel entrances are cut with terrain holes carried by the
enlarged block 8 (each VisualTerrain names a `holesterrainsurfaceshader`);
the hole mechanism itself was not decoded. **Levels without these room layers
have no interiors to place — "hollow" builds of other slices are missing
content, not missing decode.**

**MEASURED — ECS prefabs.** ~300 `*_ecsprefab_ecsprefab.ebx` per level; all
but ~8 are the 1 KB empty stub. The populated ones are volume/spline content:
`golfgreen_volumes` (123 KB), `vineyard_volumes` (27 KB),
`oceanpark_sidewalks`, `mout_roads`, `watertreatment_fillsplines`,
`rift_splines` — present in every level. Confirms the stub-is-boilerplate law
and gives this fleet's populated set.

**MEASURED — MeshScatteringDatabase (brief correction).** The "57,603
entries" in the fleet brief is 57,603 **bytes**; record counts and dedup:

```
base 57,603 B / 88 records = underground (byte-identical, md5 ddd41806)
clubhouse 58,272 / 94  (the actual largest known)      mainstreet 56,928 / 93
marina = militaryrnd = militarystorage 46,943 / 68 (byte-identical, 5acbf815)
techcampus 40,551 / 76
```

The `SingleTerrainLayerData.MeshScatteringTypes -> Identifier` join could
**not** be validated here: `MeshScatteringTypes` is empty on all 82/80/74
SingleTerrainLayerData instances checked (base/clubhouse/marina terrain EBX).
The catalogue side parses per `findings/meshscatteringdatabase-layout.md`.

**Unknown.** The 8 odd base/underground residuals (27,203–27,214 B, all in the
0x3133* subtree) — a BC7-like region floats mid-trailer at a non-tile-aligned
offset; not decoded. Also unknown: the exact content of the degenerate second
rasters, block 8 semantics, and the 28 water AABBs' role.

---

## E. Generalisation — what this confirms, and what it contradicts

| finding | scope | notes |
|---|---|---|
| **The eight Granite levels share NOTHING the plugin can reuse at the level tier.** All 8 streaming trees are distinct files; chunk-GUID overlap between any pair is 0 (or 1 degenerate chunk among the six city slices); every partition GUID is re-minted per level even when the file is byte-similar; even underground-vs-base — whose terrain blocks are nearly byte-identical — share zero chunk GUIDs. | Granite fleet | Seven full terrain caches are unavoidable if caches are keyed by chunk/partition GUID. Asset-tier caches (mesh/texture by NAME under common/) DO transfer: 56% of marina's subworld imports are shared with clubhouse. A content-addressed cache would recover the duplication (underground/base terrain is ~99.5% identical bytes under different GUIDs). |
| **Colour tiles are BC1 on five of the eight levels** — a codec TERRAIN.md §5.3 does not list; tile 8,712 B = 132² BC1. | at least the Granite 2592-family | Contradicts "the colour map is BC7" as a universal. §5.3 needs a BC1 row. |
| **The BC7 mode-histogram test misidentifies BC1 tiles in both directions** (real colour reads mode-3 "degenerate"; uniform ocean BC1 reads "100% mode 6"). | everywhere | The detect step must decode-and-validate (photo statistics / block diversity), not trust mode bits. Weakens MAP-TUNGSTEN's mode-test law from "identifies the colour raster" to "identifies it only among known-BC7 candidates". |
| Colour tile is FIRST in the trailer; the second raster is degenerate mode-3 constants. | both Granite families + tungsten | Confirms MAP-TUNGSTEN §C2 ordering on 8 more levels. |
| Page size is per LEVEL, not per world: one world baked at 2592 (five levels) and 5184 (three levels). | Granite fleet | The detect_layout fix must run per level; a per-"map" table keyed by world name would be wrong here. Also extends the 5184 set beyond plaza. |
| **Painted layers can be fully textured** — 151 distinct layer textures on base, both painted and base sides. | Granite (vs tungsten's absolute split) | Contradicts generalising "materials live on the base side" beyond a tendency. `bf6_materialtree.gd`'s base-side handling stays necessary but must not be treated as the only texture source. |
| Second `distance` texture-set slots `0x2E5ACDA8 / 0x2E5ACDF3 / 0xF9B44F08`, breakup `0x0B725504`, scatter-noise `0xEB1B291C`. | new slot hashes | Adding them gains dozens of textures per Granite level. |
| `0xAE16A5C0` = crater slot, one layer per level, linked-to by 4–5 followers. | every map checked so far | Third independent confirmation. |
| Slice levels ship constant-filler colour tiles over their own playable area. | Granite portal levels | New failure mode for `colormap_enabled`: must skip constant tiles or the play area goes uniform dark. |
| Terrain dir named after the SOURCE world + `_copy`, not the level; levels live under glacierportal/glaciergranite; water lives in `water_global.ebx`; decals live inside the terrain `_game` mirror; no `_layers_*` dirs. | Granite fleet | Every path convention from the glaciermp maps breaks here; only the "search for a dir containing 'terrain' with a .TerrainStreamingTree" heuristic survives. |
| Water y is above the terrain floor on all eight (0.0 vs 0.117 base; 99.87 on slices). | Granite | The buried-water diagnostic passes; slice levels author the ocean 100 m up at plateau height. |

## Prioritised next actions for the plugin

1. **`addons/highpoly_toggle/bf6_splat.gd` — add BC1 to the colour-tile codec
   set and stop assuming BC7.** Detect per level: try BC1-8712-first and
   BC7-tile-first against the trailer residual set; validate by decoded-image
   statistics (block diversity / non-constant), not BC7 mode bits. Verification:
   clubhouse mean ≈ (0.35, 0.34, 0.32) warm coastline, not noise.
2. **`bf6_splat.gd::detect_layout` — per-level exact decomposition** (the
   MAP-TUNGSTEN fix) with Granite's verification row: page 2592 for
   base/underground/clubhouse/mainstreet/techcampus, **5184 for
   marina/militaryrnd/militarystorage**; residual sets as tabled above.
3. **`highpoly_mapcontext.gd` — when compositing the colour map, drop
   constant-filler tiles** (<= a few distinct blocks) so slice play areas keep
   splat colour instead of turning maroon; on slice levels expect real colour
   only on the vista ring.
4. **`bf6_terrainlayers.gd` — add slots `0x2E5ACDA8/0x2E5ACDF3/0xF9B44F08`
   (distance set), `0x0B725504`, `0xEB1B291C`, and `0xAE16A5C0`** to the layer
   slot table; on Granite this is worth ~100+ real textures per level.
5. **`highpoly_gamesource.gd` — level-root discovery must include
   `game/glacierportal/levels` and `game/glaciergranite/levels`,** find water
   in `water_global.ebx`, and tolerate a missing `decals.TerrainDecals`
   (militaryrnd/militarystorage) without treating it as an error.
6. **Cache design: key shared prop/texture caches by asset NAME, and consider
   content-hash keying for terrain chunks** — underground would then reuse
   base's decoded terrain almost entirely; GUID-keyed caches must simply
   accept 7 full rebuilds.
7. **Backdrop/skyline task: consume `<level>/vistas/`** — 315–408 pre-sliced
   vista MeshSets per level with textures adjacent; no synthesis needed.
8. **Upstream `BF6_Frostbite_Research/formats/TERRAIN.md`**: §5.3 add the BC1
   132² (8,712 B) colour tile and the mode-test caveat; §5.2 add the 5184-page
   + 67,600/85,024 trailer combination on non-plaza levels; note the
   `water_global.ebx` naming and the glacierportal/glaciergranite roots.
