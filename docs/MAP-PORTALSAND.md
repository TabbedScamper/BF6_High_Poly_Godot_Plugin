# MP_Portal_Sand, end to end

The Portal sandbox level, read from the shipped data. Studied deliberately as
the **minimum viable level**: what a level can lack entirely and still load,
so that on every other map the plugin can tell a normal absence from an error.

**Every claim is tagged MEASURED or HYPOTHESIS.** Probes live in
`tools/probe_portalsand_*.py`; they re-point the Tungsten plumbing
(`probe_tung_*`) at this level's root and are read-only against the extracted
2026-08-01 pull.

```
tools/probe_portalsand_common.py       path plumbing (glacierportal root)
tools/probe_portalsand_decomp.py       THE decomposition table + colour codec
tools/probe_portalsand_layers.py       layer table -> depot -> textures
tools/probe_portalsand_structure.py    full EBX census: layers, water, ECS
tools/probe_portalsand_colorrender.py  BC1 colour map -> PNG
```

Cross-checks: every Tungsten parser walks this map byte-exact (block 0 slack 0,
block 1 slack 0, block 7 node stream ends exactly 16 bytes — its 2-pair footer —
before block end, chunk directory consumes 990,936 of 990,936 bytes), and
`probe_tung_decals` parses the decal stub with zero chain breaks.

---

## 0. The map in one paragraph

**MEASURED.** MP_Portal_Sand is an **8,192 x 8,192 m** world (block 0 root AABB
`x,z ∈ [-4096, 4096]` — twice Tungsten's span, the largest studied), ground from
y = 0.109 to 330.185, `WorldSizeY = 512.0`, 213 streaming nodes (88 persistent).
It lives at **`game/glacierportal/levels/mp_portal_sand`** — NOT under
`game/glaciermp/levels` like every other studied map — and its terrain directory
is **`mp_portal_desert_terrain`**, matching neither known naming pattern. The
whole level is **96 EBX partitions** (Tungsten: 1,405) totalling ~97 MB, over a
third of which is Enlighten lighting. It has **8 terrain layers, no water
entity, no terrain decals, no ECS prefabs, no `_layers_world`, no backdrop, no
FX layer, and no props** beyond a 13-object gameplay layer. Geography: an
eroded mountain ring around a flat central build platform (visible as a square
in the colour map).

---

## A. Water — there is none, and that is the finding

**MEASURED — zero water entities in the entire level.**
`probe_portalsand_structure.py` opens all 96 partitions (0 failures) and finds
**no `WaterSurfaceEntityData`, no `WaterEntityData`, no `WaterAsset`, no
`WaterOceanSimulationEntityData` anywhere**. The only water-adjacent types are:

| where | type |
|---|---|
| `_layers_content/water.ebx` (424 B) | one `LayerData` named `.../_Layers_Content/Water` with `Objects = []` |
| `lighting/ve_mp_portal_sand_01.ebx`, `ve_mp_portal_night_05.ebx` | `OceanComponentData` (part of the standard VE preset) |
| `mp_portal_sand/description.ebx` | `WaterLevelDescriptionComponent` (platform budgets: MaxVisibleWaterSurfaceCount 2, RenderGridWidth 256 — capacity config, not geometry) |
| `default.ebx` `TerrainEntityData` | `WaterMaterial.Packed = 128` (the 0x…80 sentinel), `LakeProbeTargetDensity = RiverProbeTargetDensity = RoadProbeTargetDensity = 0` |

**This falsifies the standing assumption.** MAP-TUNGSTEN.md G6 quotes
`highpoly_gamesource.gd::_water_partition()`'s comment "the entity is always
somewhere; only its partition varies". MEASURED: on MP_Portal_Sand it is
nowhere. An empty `Water` layer + no entity is a legal shipped state; the
plugin's water path must treat "type not found" as *this level has no water*,
not as a reader failure.

The water-Y-vs-terrain-floor diagnostic (MAP-TUNGSTEN A3) is trivially moot
here — there is no Y to compare. It remains the right diagnostic for maps that
do carry the entity.

---

## B. Terrain and ground layers

### B1. THE DECOMPOSITION TABLE (verification row for detect_layout)

**MEASURED** (`probe_portalsand_decomp.py`). 213 primary + 96 paired chunks,
all present on disk, zero size mismatches vs the directory:

```
page size 2592  (sizes step by exactly 2592; BC4 72x72 weight pages, 2592 family)

primary   10368 x 5   =      0 height + 4 x 2592 +    0     (the 5 packed-height nodes)
primary  158009 x 64  = 149297 height + 0 x 2592 + 8712
primary  160601 x 21  = 149297 height + 1 x 2592 + 8712
primary  163193 x 17  = 149297 height + 2 x 2592 + 8712
primary  165785 x 14  = 149297 height + 3 x 2592 + 8712
primary  168377 x 92  = 149297 height + 4 x 2592 + 8712
paired   34848 x 96  = 4 x 8712  (four colour tiles, ZERO pages)

height prefix 149297 = the block-0 inline size for xs = 265 (same as Tungsten)
trailer = k x tile with k = 1, tile_bytes = 8712
```

**MEASURED — the colour tile is BC1, a codec no other studied map uses.**
8712 is not divisible by 16, so it cannot be BC7/BC2/BC3 at any dimension.
8712 / 8 = 1089 = 33² → **one 132 x 132 BC1 tile** (33 x 33 blocks of 8 B) —
the same 132-texel raster as Tungsten's 17,424-B BC7 tile at half the bytes.
Evidence beyond arithmetic:

- BC7 mode test on the tile bytes: **36.5% modes 4-7** (mixed modes 0/1/4) —
  decisively fails the ~98% criterion for real BC7 (MAP-TUNGSTEN C2).
- Decoded as BC1: 92.6% of 226,512 blocks are `c0 > c1` (4-colour mode), the
  endpoint pairs are valid RGB565, and the decoded image is spatially coherent
  (C below). Full-decode mean RGB **(0.484, 0.484, 0.484)**.

**MEASURED — the plugin's `detect_layout` scoring on this map:** all six
(page, tile) candidates score 213 or 208; the winner (2592, 4624) is a
**pure tie-order accident**. The page size happens to be right; `color_tiles()`
then takes the last 4,624 bytes — the bottom 53% of the BC1 tile, cut
mid-block-row — and decodes it as `FORMAT_BPTC_RGBA`. Both the tile size and
the codec are wrong even when the page size is right, so the exact-decomposition
fix (MAP-TUNGSTEN G1) must ALSO carry a codec decision: **tile 8712 → BC1
(`FORMAT_DXT1`), tiles 4624/17424 → BC7.**

### B2. Blocks: what a minimal streaming tree carries

**MEASURED.** Five typed blocks:

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 213, PersistentNodeCount 88
block 0  heights    14,134 B  xs=265, WorldSizeY=512.0, 213 nodes (5 Packed, 208 External)
block 1  splat     155,334 B  LayerSlotCount=62, 185 nodes, 4,657 records
block 4  mask        2,445 B
block 7  material  811,945 B  dim=256, levelMax=5, 147 data nodes, 2 pairs
block 8  mask          199 B  dim=265, 53 nodes declared, levelMax=4
```

Blocks **2 (density) and 5 (second mask) are absent**, like dumbo/aftermath and
unlike Tungsten — confirming they are optional. Block 8 is present but nearly
empty (199 B), so *presence with trivial payload* is also a legal state.
`LayerSlotCount = 62` here despite an 8-layer palette — further proof it is not
the layer count (Tungsten: 6 with 33 layers).

### B3. The 8-layer palette — and it contradicts the base-side law

**MEASURED** (`probe_portalsand_layers.py`; record table found at offset 60 with
8/8 keys resolving — the weak "distinct keys" rule again fires earlier, at 24,
on garbage, re-confirming the 100%-resolve rule). Splat side: L01 painted x485;
L00, L02–L07 base x596 each.

| L | side | textures bound | tiling 0x5707A992 |
|---|---|---|---|
| 00 | BASE | none — 11 constants only | 0.05 |
| **01** | **painted x485** | **7 textures**: `t_wuc_cliffsloperocks_01_{cv,nhs,ao}` (two slot sets) + `t_gen_breakupmask_02_rgba` | 0.05 |
| 02 | BASE | `hfd_debug` at slot `0xAE16A5C0` — **the crater layer**; L03–L07 all link to it | — |
| 03 | BASE | 9 tex: `t_wum_ls_gravel_02_a` + `wum_concreteedge_01`/`wum_asphaltedge_01` + `t_wum_crackedconcrete_03` | 0.135 |
| 04 | BASE | 9 tex: `t_wum_ls_gravel_02_a` + `_02_b` + `t_wum_crackedconcrete_03` | 0.25 |
| 05 | BASE | 4 tex: `t_wum_ls_gravel_01_a` + `t_wum_td_sand_01_ncs` | 0.075 |
| 06 | BASE | 4 tex: `t_wum_dryrockygravel` + `t_wum_td_sand_01_ncs` | 0.055 |
| 07 | BASE | 6 tex: `t_wum_concretedebris_01` + `_02` | — |

- **CONTRADICTION of the tendency, not the mechanism: the single painted layer
  binds textures.** Tungsten's split (all painted textureless / all textured
  base) is absolute there and 11-of-16 on dumbo; here the *only* painted layer
  is fully textured (cliff rocks — the mountain slopes). "Materials live on the
  base side" must stay implemented as *base layers can bind textures too*,
  never as *painted layers cannot*. 7 of 8 layers bind textures — the honest
  albedo ceiling on this map is the whole ground except L00.
- **The crater-layer law holds exactly**: one layer with `hfd_debug` at
  `0xAE16A5C0` (L02), all linked layers (L03–L07) pointing at it — Tungsten
  L28/L29–32, dumbo L41/L42–45, same structure at 8-layer scale. The linked
  family is the shared `wum_*` material set seen on Tungsten's crater layers.
- Constants: `0xCF3F97E0` again integer-typed, value 4 everywhere it appears;
  `0xCBB9A946` again (0,0); `0x4C200FE0` = 0.0 on all layers here (no new
  discrimination). New value pairs for the unidentified floats:
  `0x2F9990B7` ∈ {0.328, 45.0, 105.0, 105.37, 105.39, 234.19} and
  `0xF7652FB3` ∈ {4.0, 14.25, 15.56, 35.0, 45.0}.
- **MEASURED oddity**: `mp_portal_desert_terrain.ebx`'s `TerrainData` declares
  **9** `TerrainLayers` entries (all pointing at `SingleTerrainLayerData`)
  against a `VisualTerrain`/layer-graph count of **8**. Off-by-one between the
  authoring list and the compiled palette; consumers should trust the compiled
  side.

### B4. Block 7 — two pairs, and the dominant one CANNOT resolve

**MEASURED** (`probe_tung_basefield` run on this level; 147 data nodes, 0 bad
RLE rows, footer byte-exact). `pairCount = 2`,
`BackgroundMaterialIndex = 0x00000080` (the "no background" sentinel):

```
pair 0  0x0660FA80  X lo=10 hi=15  -> list 0 has 8 entries: UNRESOLVABLE   84.7% of texels
pair 1  0x0670E280  X lo=2         -> L02 (crater layer family)            15.3% of texels
```

Pair 1's texels trace the mountain slopes around the flat basin — spatially
coherent, so the decode is right. But pair 0 — **84.7% of all block-7 texels**
— indexes entry 10 of an 8-entry list. Both pair dwords are *byte-identical to
Tungsten pair values* (`0x0660FA80` = Tungsten's background/river pair,
`0x0670E280` = Tungsten's pair 3).

**HYPOTHESIS** (two candidates, unresolved):
(a) the desert terrain was copied from another map's authoring project and
pair 0 is a dangling reference to a layer that no longer exists — plausible for
a sandbox level with a reused-looking terrain named `mp_portal_desert_terrain`;
(b) TERRAIN.md §8's per-map list resolution is incomplete and pair dwords have
some cross-map meaning. (a) is favoured: §8 produced spatially-correct results
on tungsten and dumbo. Either way the plugin needs a rule: **an unresolvable
pair must fall back to no-layer (colour map / background), not crash or clamp.**

---

## C. The colour map — BC1, achromatic, and the paired-chunk law refined

**MEASURED — rendered** (`probe_portalsand_colorrender.py`, full BC1 decode,
coarse-first blit) to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Portal_Sand.png`.
**It reads as a fully coherent aerial image** — eroded ridge-and-drainage
mountains east and west, alluvial fans south, and the flat central build
platform visible as a literal square — **but it is greyscale**: full-decode mean
(0.484, 0.484, 0.484), R=G=B to three decimals at every tree depth. The colour
map of the sandbox is an unpainted luminance/shading raster sitting at the
0.5-neutral of the modulation law (GROUND-LAYERS corpus): applying it as a
modulator tints nothing and shades everything, which is exactly right for this
map.

**MEASURED — the paired-chunk reversed order [3,2,1,0] holds, with a
refinement.** All 96 paired chunks are `4 x 8712` and sit on **leaf** nodes at
depths 3–4 (no child nodes exist in the directory). Matching each 8712-B slice
against the leaf's own tile quadrants (traversal-order (x,z) of TERRAIN.md
§2.4): 54 of 71 decisive nodes vote slice→quadrant **(3, 2, 1, 0)**; the
non-decisive votes are near-ties in flat regions. So Tungsten's "colour tiles
grouped in reversed child order" generalises, and on this map the "children"
are *virtual*: a leaf's paired chunk carries its own four next-LOD quadrant
tiles. Zero weight pages in any paired chunk here.

---

## D. Decals and roads — a 160-byte stub

**MEASURED** (`probe_tung_decals` on this level). `decals.TerrainDecals` is
**160 bytes**: `slotCount = 8` — again exactly the terrain layerCount, the
slot-table law holding even at zero content — with 1 slot carrying a GUID and
**`recordCount = 0`**. No decal geometry, no materials, no roads. The resource
ships as a header-only stub rather than being absent, and it sits at the doubly
nested path
`mp_portal_desert_terrain/mp_portal_desert_terrain_game/glacierportal/levels/mp_portal_sand/mp_portal_sand/decals.TerrainDecals`
(a build artifact echoing the level path inside the terrain directory — a
placement walk that globs `**/decals.TerrainDecals` finds it; one that builds
the Tungsten-style path does not).

---

## E. Everything else notable

- **MEASURED — zero `EcsRuntimePrefabAsset` partitions.** Not even the empty
  `ent=1 arch=1 seg=1 comps=[26]` stub. The stub is boilerplate *when a layer
  is built from a prefab*, not a required level component.
- **MEASURED — 29 `LayerData`, only 7 with zero Objects, and the busiest layer
  in the level has 13 objects** (`MP_SquadDM0`). Total placed objects across
  all layers: ~70. There is no `_layers_world` directory at all — no area
  subworlds, no `staticmodelgroup.physics`, no backdrop partition, no
  `fx_global`, no crater_backdrop, no loot/BR content.
- **MEASURED — gamemode/layout naming is Portal-specific**: `_layers_gameplay`
  contains `customportal*`, `customportallayout0`, `modbuildercustom0`,
  `portal_gameplay`, `mp_squaddm0`, `squaddm*` — and the level description's
  GameMode category lists `MP_SquadDM0, ModBuilderCustom0..3`. A gamemode walk
  keyed on conquest/breakthrough names finds nothing here and that is correct.
- **MEASURED — `_layers_autotests`** (unique among studied maps): an
  `autotests` layer group with its own networkregistry, shaderdepot (819 KB)
  and meshvariationdb (103 KB) — `autotest_performance.ebx` etc. Another
  confusable for a placement walk.
- **MEASURED — two full VE presets**: `ve_mp_portal_sand_01` (day) and
  `ve_mp_portal_night_05` (night), each the standard component set (OutdoorLight,
  Sky, Fog, Ocean, Tonemap, ColorCorrection…). The sandbox's night mode is a
  whole second preset, not a parameter tweak. No dedicated cloud-shadow
  component appears in the preset's type census.
- **MEASURED — one `PbrDistantReflectionVolumeEntityData`** in
  `lighting_layer.ebx` (`0xD123B2AA = 20000.0`, CaptureSky false,
  CaptureFog true) — a level needs exactly one distant reflection volume to be
  viable; there are no local reflection volumes.
- **MEASURED — scatter: catalogue without placement.**
  `meshscatteringdatabaseasset.MeshScatteringDatabase` ships (2,964 B, real
  content — e.g. `ms_wuu_asphaltchunklarge_01`) while **all 9
  `SingleTerrainLayerData` have `MeshScatteringTypes = []`**. The Identifier
  join (fleet brief open task) is NOT validatable here — zero join rows — but
  the asymmetry proves the catalogue RES is emitted unconditionally; an empty
  `MeshScatteringTypes` is the real "no scatter" signal.
- **MEASURED — the biggest files are lighting and material physics, not
  geometry**: 2 x 19.95 MB EnlightenDatabase (highend and lowend byte-identical
  in size), `materialgrid_win32.ebx` 15.0 MB, `mp_portal_sand_unlocks_win32`
  872 KB. The census's dominant types are material-relation data
  (17,768 `MeshMaterialVariation`, 2,285 `MaterialRelationEffectData`) — the
  physics/damage material web ships in full even for an empty sandbox.
- **Reader note**: `description.ebx` instance 10 (`LevelDescription`) fails to
  decode in the pipeline deserialiser (wants offset 66,343 in a 9,660-B buffer
  — an external-blob field the reader does not handle). Every other instance in
  the level decodes.

### E1. What the minimum viable level lacks — the absence table

The point of this map. **A level still loads with ALL of the following absent**,
so their absence on any map is NORMAL, never an error:

| can be entirely absent (MEASURED here) | but note |
|---|---|
| `WaterSurfaceEntityData` / any water entity | water layer may still exist, empty |
| Terrain decal records | the `decals.TerrainDecals` RES still ships as a header stub with slotCount = layerCount |
| ECS runtime prefabs (even the empty stub) | stub ≠ required boilerplate |
| `_layers_world`, backdrop meshes, area subworlds | skyline can be terrain-only |
| FX layer (`fx_global`), per-map FX | |
| Props / StaticModelGroups | busiest layer here: 13 objects |
| Streaming-tree blocks 2 and 5 | block 8 may ship nearly empty (199 B) |
| Per-layer scatter (`MeshScatteringTypes`) | the scatter catalogue RES still ships |
| Painted-layer weight pages beyond one layer | |
| Block-7 background material | sentinel `0x00000080` |

**What even the minimum level always ships**: streaming tree with blocks
0/1/4/7/8, colour trailer on every external-height chunk, layer graph + depot
(all keys resolving), VisualTerrain, a crater layer bound to `hfd_debug`,
`decals.TerrainDecals` (possibly stub), MeshScatteringDatabase, meshvariationdb,
materialgrid, Enlighten databases, one distant reflection volume, at least one
VE preset, description, navmesh (`dbt/`), and the gameplay/network registries.
A reader may treat *these* as invariants; everything in the absence table it
must not.

---

## F. What generalises, what contradicts

| finding | scope | notes |
|---|---|---|
| **Colour tile can be BC1** (8712 = 132² BC1), not just BC7 | at least this map; any map whose trailer residual is not 16-divisible | Contradicts the implicit "colour tiles are BC7" in TERRAIN.md §5.3 / MAP-TUNGSTEN C. The BC7-mode test correctly REJECTS these tiles; it needs a BC1 branch, not a lower threshold. |
| **A painted layer can bind textures** (L01, 7 textures) | breaks the absolute form of the base-side law | Tungsten's "split is total" is Tungsten-specific. Keep base-side support mandatory; never assume painted ⇒ textureless. |
| **A level can have zero water entities** | falsifies `_water_partition()`'s "always somewhere" comment | Absence is a legal state, to be logged as such. |
| **Block-7 pairs can be unresolvable** (84.7% of texels here) and pair dwords repeat byte-identically across maps | unknown scope | Needs a defensive fallback in `bf6_materialtree.gd`. |
| Paired-chunk reversed order [3,2,1,0] | holds; refined | On leaves the four tiles are the leaf's own next-LOD quadrants ("virtual children"). |
| Crater layer law (`0xAE16A5C0`, one layer, linked family) | holds at 8-layer scale | L02 here. |
| 100%-resolve rule for the layer-graph table | holds | Weak rule fires at offset 24 on garbage; true table at 60. |
| decals slotCount == terrain layerCount | holds at zero content | slotCount 8, recordCount 0. |
| Blocks 2/5 optional; page size 2592 family | holds | Consistent with dumbo/aftermath. |
| Terrain dir naming has ≥3 patterns | worse than known | `mp_portal_desert_terrain` matches neither `terrain_<level>` nor `<level>_terrain`; only "contains 'terrain' + has streaming tree" works. |
| Levels root is not unique | new | `game/glacierportal/levels` exists beside `game/glaciermp/levels`. `_level_dir()` derives from the walk's resolved root, so the plugin is safe — but any tool that hardcodes `glaciermp` (several `tools/probe_*.gd` do) silently misses this level. |

## G. Next actions for the plugin, in priority order

1. **Extend the detect_layout fix with a codec decision** —
   `addons/highpoly_toggle/bf6_splat.gd`. The exact-decomposition fix
   (MAP-TUNGSTEN G1) must accept tile_bytes 8712 and mark it BC1: decode with
   `Image.FORMAT_DXT1`, not `FORMAT_BPTC_RGBA`. Acceptance: trailer residual
   8712 on this map, k=1, and the assembled colour map averaging (0.48, 0.48,
   0.48) with visible mountains — not BC7 noise. Verification row: page 2592,
   prefix 149297, trailer 1 x 8712.
2. **Make the water path absence-tolerant** —
   `addons/highpoly_toggle/highpoly_gamesource.gd::_water_partition()` /
   `water()`. When no partition contains `WaterSurfaceEntityData`, log
   "level ships no water surface" and return cleanly; fix the "always
   somewhere" comment. This map is the regression test.
3. **Defensive pair resolution** — `addons/highpoly_toggle/bf6_materialtree.gd`.
   A pair whose nibbles exceed the target list length must resolve to
   no-layer (background/colour-map fallback), with one log line naming the pair
   dword. 84.7% of this map's texels hit that path.
4. **Treat the absence table (E1) as the plugin's normal/error oracle** — when
   the toggle logs "no decals / no water / no backdrop / no ECS content" on any
   map, phrase it as a normal state, and only flag as errors the invariants in
   E1's second list. Touches the log lines in `highpoly_gamesource.gd` and
   `highpoly_mapcontext.gd`.
5. **Do not path-derive the terrain directory or the levels root** — anything
   that builds `terrain_<level>` / `<level>_terrain` or hardcodes
   `game/glaciermp/levels` (several `tools/probe_*.gd`; verify
   `highpoly_gamesource.gd` has no such construction) must instead search for
   the `.TerrainStreamingTree` sibling, as `probe_tung_terrain.terr_dir` does.
6. **Push upstream to `BF6_Frostbite_Research`**: TERRAIN.md §5.3 — colour
   tiles exist in BC1 (8712 = 132² BC1) and the tile-position law's "children"
   can be virtual (leaf next-LOD quadrants); §8 — pairs can dangle
   (`0x0660FA80` with lo=10 on an 8-layer map) and identical pair dwords recur
   across maps, meaning either dangling authoring references or an incomplete
   resolution rule.
