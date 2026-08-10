# Environment decal volumes: the measured chain (task #52)

How an `EnvironmentDecalVolumeData` finds its texture, measured on retail
MP_Capstone and MP_Subsurface rather than taken from the fleet's write-up.
The fleet claimed the template partition "carries the projected texture";
it does not - a template partition has ZERO imports and an empty Shader
struct. The real chain runs through the ShaderBlockDepot, the same road the
mesh sections take.

## The chain

```
volume instance (collected on the placement walk, tag "edv")
  Transform 0xD6351EDE      composed world matrix; basis rows carry the box's
                            FULL extents as scale (unit cube, not half-extents)
  Template  0xA9AC5095      import PointerRef -> guid index -> template EBX
  Enable    0x48C97D5E      authored-off stays off
  Alpha     0x40B21230      per-instance opacity
  Cull      0xC3B610EC      OverrideTemplateCullingDistance, metres (10-50)

template EBX (decalvol_* / edv_*, EnvironmentDecalVolumeTemplateData
              d084b894-08af-902e-d29a-460fecbea4fb / byte-swapped twin)
  0x4A98C1F8  u64           = a ShaderBlockDepot STATE KEY. Verified by key-
                            table membership: sootnoisy_c's key sits in
                            area_01's depot, gobolight's in area_04/05/06's -
                            always the depot of the SUBWORLD SCOPE that
                            mounted the volume, which is exactly the `scope`
                            the walk records on every collected entity.

depot record -> textures_for(key) -> slots, by family:
  graffiti / checkpoint / dirt   decal_ca + decal_nrm      real colour sheet
  ashdust                        the *_ca sheet arrives in the WRAP slot
  gobolight                      the fixture's *_e emissive plane (the light
                                 pattern) + a colour swatch, unnamed slots
  soot/plaster/dust "noisy"      ONLY t_3dperlinnoise - the smudge is shader-
                                 computed; colour lives in the constants
```

Unnamed slots are classified by the bound texture's NAME suffix (`_ca`
colour, `_e` emissive, `_nms` normal, `noise`), which holds install-wide and
survives new maps without new hashes.

## Authored conventions, measured

- **Projection axis is the volume's UP row.** Wall graffiti volumes are
  0.01-0.05 m thin along `up`, with `up` pointing OUT of the wall; gobo
  splashes are 0.19 m thin along `up` pointing vertically. Godot's Decal
  projects along local -Y, so the walk basis maps identity.
- **Unit cube, not half-extents.** The schoolhouse graffiti reads 1.2-4.5 m
  wide as full extents - mural-sized; the half-extent reading would put a
  9 m piece on a schoolhouse wall.
- The paper-thin projection axis needs a floor in Godot (we use 0.6 m) or
  the box reaches nothing.

## Resolution rates

| map | collected | placeable | notes |
|---|---|---|---|
| MP_Capstone | 300 | 300 (100%) | 256 smudge, 34 albedo, 10 emit |
| MP_Subsurface | 1,204 | 1,176 (97.7%) | matches the dump probe exactly; 28 bind no readable sheet |

The dump probe's "88 on capstone" counted level-owned partitions only; the
walk also expands prefab-embedded volumes (the `_wedv` lamp fixtures and
friends), which is where the other 212 live.

## Where it lands in the plugin

`highpoly_gamesource.gd` collects on the walk (`EDV_TYPES`, tag "edv"),
resolves in `_edv_records()`, and serves records through `map_data`'s "edv"
section. `highpoly_mapcontext.gd` builds Godot Decal nodes under
`Props/EnvDecals` - they ride "Original map objects", because a graffiti
without its wall floats and a wall without its graffiti is merely plainer.
Smudge families draw as a flat family colour under the noise sheet's
coverage; gobo sheets draw as emission (as albedo they would print a dark
lamp-shaped patch). Tests: `tools/test_edv.gd`, `tools/test_edv2.gd`,
`tools/test_edvslots.gd`.
