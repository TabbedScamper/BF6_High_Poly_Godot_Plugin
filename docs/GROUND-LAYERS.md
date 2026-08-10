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
