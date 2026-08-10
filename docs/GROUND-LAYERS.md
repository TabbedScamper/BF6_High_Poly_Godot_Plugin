# Why the ground does not look like the game

The painted grass, rock and gravel are mostly absent. This is what is actually
happening, measured on MP_Aftermath, and it is **not** a parsing failure — every
stage of the chain works and the answer is at the end of it.

## The one line that says it

Forcing a ground composite (`tools/probe_splat.gd`) prints:

    terrain splat — 3785 pages over 28 layers, 5 textured slices,
                    100% of ground on a shader-computed layer

The map paints **28** distinct ground layers. **5** end up with a texture.
Essentially all of the ground falls back to the flat colour map.

The five that do work are real and correct:

| layer | texture | texels |
|---|---|---|
| 19 | `t_wum_m_sand_02_cv` | 69,025 |
| 2 | `t_euu_cobblestone_01_cv` | 4,263 |
| 16 | `t_wuu_grass_fairway_01_cv` | 3,429 |
| 36 | `t_wum_ls_gravel_01_a_cv` | 184 |
| 3 | `t_ter_defaulttexture_cv` | 59 |

76,960 texels of a 2048² surface: about 1.8%.

## What was ruled out, in order

**The 32-slice cap is not it.** Only 5 layers are offered to it.

**The palette is not truncated.** It declares **40** entries for this map, and
the layer indices the splat uses (up to 36) are all inside it.

**The depot is not the wrong one, and nothing is missing from it.** There is
exactly one layergraph shaderblockdepot for this level, the reader picks it, and
**all 28** of the textureless layers have their shader state key in it
(`tools/probe_layerdepot.gd`). The records are found.

**The records are not failing to parse.** Their `tiling` and `smoothness`
constants read back as sensible numbers — 50.0, 14.286, 33.333 metres per
repeat — so the parameter walk reaches them.

**The `link` field is not a fallback.** Only layers 35–38 set one, all pointing
at layer 34, which is itself textureless. It is a blend relationship, not
"inherit this layer's textures".

**The slot table is not the gap.** Over every textureless layer there are six
texture parameters in total, and exactly one uses a slot hash we do not know
(`0xAE16A5C0`). Adding it would gain one texture.

## What it is

**Those 28 layers bind no colour texture at all.** A typical one
(`tools/probe_layerslots.gd`):

    layer 0, key 0x1E152EB7A7727F22, 6 parameter(s)
       const  0x4C200FE0   4 bytes  [0.0000]
       const  0xE68B2B10   4 bytes  [0.5000]
       const  0xCF3F97E0   4 bytes  [0.0000]
       const  0xCBB9A946   8 bytes  [0.0000, 0.0000]
       const  0x5707A992   4 bytes  [0.0200]   <- tiling
       const  0xFA13C5B0   4 bytes  [0.3800]   <- smoothness

Numbers only. The unidentified constants were checked for being a colour and
they are not: across layers they read 0.0, 0.5, 2.0, 40.0, 100.0 — no RGB
triple anywhere. There is nothing in the depot that says what these layers look
like.

That is what "shader-computed layer" in the log line means, and the splat
remapper already treats it deliberately:

> A texel whose layer has no texture is left pointing past the end of the array
> on purpose: the shader's `id < splat_slices` test then falls back for it,
> which is the right answer for a shader-computed layer we cannot reproduce.

So the ground is behaving exactly as designed. The design is just short of what
the game does, on a map where 98% of the ground is painted with layers of this
kind.

## Where the answer would have to come from

Not the depot — it holds bound resources and scalars, and for these layers it
holds no colour. It has to be the **layer graph itself**: the compiled shader
graph in `<level>_terrain.layergraphslayergraphs`, which is what computes these
layers from the constants above. We currently read that resource only far
enough to find each layer's record offset and state key.

That is a research task of its own, not a fix. Until then, the honest summary
for a user is: the ground carries its real colour map and the handful of layers
that ship a texture, and the rest of the detail is computed by a shader that is
not reproduced.

## Tools

    tools/probe_splat.gd       force a composite; prints the slice table
    tools/probe_palette.gd     every palette entry: albedo, slots, tiling, link
    tools/probe_layerdepot.gd  which depot holds each layer's key
    tools/probe_layerslots.gd  every parameter of the textureless layers

---

# MP_Tungsten: the same fault, harder, and where the river went

Tungsten reads worse than MP_Aftermath:

    terrain splat — 11968 pages over 27 layers, 3 textured slices,
                    99% of ground on a shader-computed layer

| layer | texture | texels |
|---|---|---|
| 30 | `t_wum_ls_gravel_01_a_cv` | 216,310 |
| 9 | `t_cas_asphaltedge_01_cv` | 172,882 |
| 11 | `t_cas_grasstuftspline_01_tungsten_cv` | 8,159 |

Three textures for a whole map. "The terrain is all one colour" is literally
true: 99% of it is the flat colour map with no detail layer at all.

## The river is not missing — it was never geometry

Three separate things were checked, and all three say the same thing.

**The decals carry no water.** All 613 terrain-decal records group into 20
materials and not one of them names a water texture
(`tools/probe_decalmats.gd`):

    149 recs  t_cas_road_graveldirt_tungsten_01
     99 recs  t_cas_erosiongravel_02
     95 recs  t_cas_roadmud_01_tungsten        <- the "mud where the river is"
     50 recs  t_cas_tiretracks_01

That mud is a genuine road decal, correctly drawn. A problem marker dropped on
the river reported `on _MAP_CONTEXT/Roads`, which confirms it from the other
direction: the surface being looked at IS the decal layer. (It selects the whole
thing because Roads is one mesh with one surface per material group.)

**The water plane is a puddle with no material.**
`com_tungsten_simplewaterplane_01` is placed once, at y 85.9, inside the terrain
range - and it builds as a 1 m unit quad, so its placement scale of 4.27 x 8.66
makes it about 4 x 9 m. Its one surface resolves **no material at all**, the
same class of miss as `com_billboard_sign`'s bare face.

**The river itself is an ECS runtime prefab.** The map carries
`_layers_world/river` and `_layers_world/riversplines_backdrop`, and what is
inside them is:

    river                        1  LayerData
    river_ecsprefab_ecsprefab    1  EcsRuntimePrefabAsset
                                 1  EcsComponentSegment

No geometry, no placements, no textures. The river is assembled at runtime by
the same ECS system that holds conquest's objective logic (see
GAMEMODE-MINER.md) - which is why nothing arrives with Original map objects and
nothing can: there is nothing in the level data to place.

The ocean surface `water()` does find - one plane, 4096 x 4096 m at **y = 0** -
sits at least 65 m below the lowest ground on this map, so even that is built
and buried. Whether y = 0 is authored or a misread of the other water shader
variant's field offsets is still open.

## Tools

    tools/probe_decalmats.gd   every terrain-decal group with its textures
    tools/probe_water.gd       what water() finds, and every watery partition
