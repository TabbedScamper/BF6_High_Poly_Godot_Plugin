# What a 1:1 map actually contains, and what we build

Written because the work had drifted into fixing what got reported rather than
asking what a level is made of. This is the second question, answered from the
shipped data instead of from memory.

Source: `data/level_type_census.tsv` in BF6_Frostbite_Research - every EBX
instance in 28 level directories, 67,048 partitions, **3,306,950 instances**,
counted by type. Names for the unnamed types come from the SDK type dump keyed
by type guid, exactly as the material relation work did; where a type has no
leaf name anywhere, its `runtimeNamespace` still says which subsystem owns it.

## The biggest thing we do not build at all: AUDIO

Nothing in either editor reads a sound emitter. Grepping both codebases for
audio emitters, sound emitters or ambient sound returns **nothing**.

Fleet-wide, the unnamed types owned by audio subsystems:

| namespace | instances | share of every instance |
|---|---:|---:|
| DiceAudioShared | 208,418 | 6.3% |
| AudioLegacyGameplay | 21,881 | 0.7% |

That is **230,299 instances, 7.0% of everything in every level**.

## CORRECTION: most of that is a grid, not sound sources

Written after probing the actual instances, which is the check that should have
come before the claim above.

On mp_isolated the two largest audio types - 9,900 and 6,675 instances - both
live in `mp_isolated_soundshapegrid`, and neither carries a transform or a sound
reference. One holds two uints and a bool, the other a one-element array and a
uint. They are CELLS OF AN ACOUSTICS GRID, not 16,575 emitters. Counting them as
absent content overstated the gap badly, and nothing should be built for them.

The placeable audio is much smaller, and it is the part worth having:

| instances | levels | type | busiest levels |
|---:|---:|---|---|
| 2,408 | 4 | EmitterGraphEntityData | mp_subsurface 1303, mp_contaminated 565 |
| **918** | **25** | **DiceSoundSpatialEntityData** | mp_aftermath 102, mp_abbasid 93 |
| 64 | 14 | DiceSoundEntityData | mp_abbasid 17 |

So the honest figure is about 100 placed emitters on a busy level, not
thousands - comparable in scale to the 2,930 reflection volumes, which were
worth a day. The lesson is the one this whole document is about: a raw instance
count is not a measure of content until you have looked at what the instances
are.

This agrees with a finding from the material relation grid on the same day: of
the 49,356 authored surface-pair relations on mp_subsurface, **20,001 are the
AudioLegacyGameplay relation** - more than effects, decals and everything else
combined. The game's world is dense with authored sound, and our recreations are
silent.

A 1:1 map is not only geometry. This is the gap nobody had measured.

**Where to start on it**, because 230,299 instances is not an entry point. The
NAMED audio types are a much smaller, tractable set:

| instances | levels | type |
|---:|---:|---|
| 2,408 | 4 | EmitterGraphEntityData |
| **918** | **25** | **DiceSoundSpatialEntityData** |
| 64 | 14 | DiceSoundEntityData |

`DiceSoundSpatialEntityData` is the one to take first: named, so the schema
reads it, and present on 25 of 28 levels, so it is the general case rather than
one map's special. 918 placed spatial emitters is a level's ambient bed - the
sea, the wind, the fires, the machinery - and it is a normal placement read of
the kind the walk already does for every other entity.

The unnamed 230,299 are the dense per-object audio the game attaches to
everything, and they can wait behind the placed emitters that carry the
atmosphere.

## Ranked: what a level is made of

Named types, fleet-wide, with what we do about each.

| instances | type | status |
|---:|---|---|
| 1,911,403 | MeshMaterialVariation | consumed (variation system) |
| 353,770 | PartData + PartState | partial (destruction) |
| 147,457 | MaterialRelation* (all kinds) | **decoded, not applied** |
| 105,093 | TerrainQuadDecalData + TerrainFillDecalData | consumed |
| 135,160 | ObjectReference + SpatialPrefabReference + StaticModel | consumed (the walk) |
| 23,744 | EffectReferenceObjectData | consumed PER LAYER as of 2026-09-16 |
| 13,411 | AlternateSpawnEntityData | consumed (gameplay markers) |
| **12,983** | **LightProbeVolumeData** | **not consumed** |
| **9,357** | **EnvironmentDecalVolumeData** | **Godot only, absent in Unreal** |
| 8,633 | PbrSphereLightEntityData | consumed (map lights) |
| 7,040 | VolumeVectorShapeData | partial |
| **6,295** | **FootprintEntityData** | **not consumed** (4 levels) |
| 5,623 | HealthTransitionData | partial (destruction) |
| 4,230 | OccluderPlaneEntityData | not consumed (a performance system) |
| 2,930 | PbrBoxReflectionVolumeEntityData | consumed as of 2026-09-16 |

## The gaps worth taking, in order

1. **Audio, 230,299 instances.** Nothing exists: no core reader, no builder in
   either engine. The largest single step toward a level that feels like the
   game rather than looking like it.
2. **The material relation grid, 147,457 instances.** Decoded and queryable
   today, and shown in a panel, but nothing is PLACED from it: no impact decal,
   no impact effect, no footprint. The data is ready and the consumer is not.
3. **EnvironmentDecalVolume, 9,357 instances over 25 levels.** Godot builds
   these, Unreal does not. A straight 1:1 divergence between our own two
   editors, and the cheapest item on this list.
4. **LightProbeVolumeData, 12,983 instances.** The indirect-lighting cage.
   Blocked upstream: BF6 ships no baked RGB irradiance, and the one baked term
   it does ship cannot be tied to an object
   (`enlighten-instance-key-is-not-in-shipped-ebx`, five routes closed).
5. **FootprintEntityData, 6,295 instances**, on only four levels, so it is
   narrow but cheap.

## What this changes about how to work

The census is the map of the territory. Before adding a feature, look up what it
is worth here: 2,930 reflection volumes was a real gap and worth the day it
took, while a system with 40 instances is not, however interesting it looks.

And the unnamed 11.7% is where the unknown lives. Nobody had grouped it by
namespace before; doing so is what turned "222 types the SDK does not name" into
"audio is 6.3% of every level and we build none of it".


## FX, 2026-09-16

The FX overlay was rebuilt off the core's per-LAYER data. What it draws now, on
MP_Isolated (1,200 spawn points):

| | |
|---|---|
| emitters | 1,954 particle systems + 302 volume decals |
| join coverage | 99.8% of spawn points find their layers (the 2 misses are `*_schematic` editor placeholders) |
| distinct looks | 263 distinct materials, 74 distinct quad sizes |
| mesh FX | 484 emitters drawing real geometry, 10 distinct meshes |
| motion | 104 distinct force vectors, 45 speed ranges, 913 turbulent, 2 spawn shapes |
| six-way lit | 577 emitters, through `fx_sixway.gdshader` |
| authored fades | 1,291 emitters carry the layer's own over-life cubic |
| velocity-aligned | 807 emitters (Directional / ScreenStretch) |

Before this, every spawn point drew one emitter from one of ~40 hand-curated
graph archetypes, with the six-way lighting averaged to a single grey scalar.

**Retired**: `fx_params.json`, `fx_sizes.json`, `fx_spawn.json`,
`fx_motion.json`, `fx_sheets.json`, `fx_effect_sheets.json` - 1.5 MB of
per-graph aggregates, all now answered exactly by the layer row.

**Mesh FX now draw too.** The core reads the graph template's `EmitterMesh`
import (field `0x68E09280`), so missiles, UAVs, aircraft vapour, birds and
debris draw geometry instead of nothing. On MP_Isolated that took the emitter
count from 1,514 to **1,954** and emitters drawing real geometry from 25 to
**484** (10 distinct meshes, 186,744 triangles).

**Still not drawn**, counted in the status line rather than faked:

| | |
|---|---|
| 86 | `distortion` - a screen-space pass with no texture to draw |
| 1 | one `creature` layer whose mesh does not resolve |

Plus the debris graphs whose template mesh is the 3-vertex PLACEHOLDER the game
expects each effect to substitute. The substitution itself is undecoded - the
only candidate is layer field `0xF56940D2`, an array of plain u32 ids that is
populated only on mesh graphs. Drawing the placeholder would put a triangle
where a wood shard belongs, so those are skipped and counted. See
findings/fx-mesh-particle-template-mesh-and-substitution.

**Unverified assumption in the shader**: which of the six directional terms is
which axis. The packing finding proves `L.rgb` and `R.rgb` are three directions
and their opposites but deliberately does not settle the assignment. It is the
`axis_order` and `flip_halves` uniforms, correctable without a rebuild.


## How much of an FX do we actually read?

Measured against `fx_property_ids_v2.tsv` - 2,525 parameters recovered from the
game - weighted by SHIPPED OVERRIDE COUNT, so a property patched 30,000 times
counts for more than one patched twice.

| | before 2026-09-16 | after |
|---|---:|---:|
| all properties | 19.4% | **37.3%** |
| NAMED properties | 19.4% | **96.4%** |

The gap between the two is the ~1.0M overrides on parameters whose NAME has not
been recovered. Those are not resolvable responsibly: without a name there is no
way to know what a value means, and guessing is how a plausible wrong answer
gets rendered confidently.

The resolver is generated from one table (`tools/gen_fxlook.py` in the core), so
the struct, the `has` enum, the pid list, the field names and the generic value
accessor cannot drift from each other. Two bugs in this session came from
exactly that drift and both were caught by the build test:

1. The Godot product carried its own 31-name copy of the enum order; the enum
   grew to 82 and every over-life curve silently stopped resolving.
2. The product NAMED about thirty fields while the core FILLED eighty, so the
   `has` mask said RandomForce and SpawnScale were authored while their values
   were absent from the payload - they read as an authored ZERO, and every
   emitter came out with no turbulence and an identical spawn volume.

Both are now impossible: the product asks the core for the names and walks every
field rather than listing any.

## FX animations and paths

There are none to find. Every import reachable from every emitter graph on three
levels is one of **25 distinct assets**, and not one is an animation, skeleton,
spline, curve or path - searched for `anim`, `ant`, `ska`, `skel`, `pose`,
`clip`, `spline`, `path`, `curve`, `track`, `rig`, `bone`. A missile's arc and a
bird's circle are the integral of the authored forces, which we now read in
full. See findings/fx-reference-no-animation-or-path-assets.

Two real chains are NOT walked yet: the child emitter graph that governs
flocking (`eg_flocking_child`, birds and butterflies) and the child effect three
graphs spawn on impact.
