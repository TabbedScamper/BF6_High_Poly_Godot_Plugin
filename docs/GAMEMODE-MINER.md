# The gamemode miner: rebuilding a mode out of real Portal objects

Picking a mode in the Variant dropdown puts that mode's actual layout into the
scene as SDK objects — `CapturePoint`, `SpawnPoint`, `PolygonVolume`,
`CombatArea`, `OBBVolume` — under a node named for the mode, at the positions
and with the shapes the game ships. Not a preview of one: nodes you can drag,
edit, keep and deploy.

    highpoly_gmmine.gd     install  -> user://mapcontext/<MAP>/gamemode_markers.json
    highpoly_gamemode.gd   that file -> instanced SDK scenes in the edited scene

## What had to be established, and what it overturned

**1. The default walk never visits the mode subworlds.** Walking the level
reaches 38,226 placements and not one gameplay entity of any mode. Walking
`_layers_gameplay/<mode>` **as a root** reaches 2,701.

**2. `CapturePointEntityData` is not what conquest places.** Its type GUID
collects exactly zero, from the level walk and from the mode roots alike.
Dumping every instance type in the 25 conquest partitions and naming them
through the research tables gives what is really there:

    AlternateSpawnEntityData          137   the spawns
    VolumeVectorShapeData               8   objective volumes
    OBBData                             2   oriented bounding boxes
    SpatialPrefabReferenceObjectData   60   the mode's own props

A capture point in this data is a **volume**, not a point entity. Looking for a
point was never going to find one.

**3. Field names cannot be looked up, so fields are read by shape.** Three
tables were tried and none is in the hash space `bf6_ebx.gd` keys fields by:

| source | field names | matches our hashes |
|---|---|---|
| `data/ebx_typehashes.tsv` | no — type names only | — |
| `research/frosty-bf6-mining/.../DumpedTypes_*.cs` | yes, `NameHashAttribute` | none of Members / Transform / Blueprint / Objects |
| `bf6-weapon-previewer/data/fieldname_dict.json` | yes | none |

The **type GUIDs** in those dumps do match, which is how the types above were
identified, and the C# dump gives each type's own declared fields. That is
enough, because within one type's own fields every value we want has a distinct
shape:

    the array of Vec3   -> Points        (VectorShapeData)
    the lone Vec3       -> HalfExtents   (OBBData; its Transform became the xf)
    the lone int        -> Team          (Priority is a float, Enabled a bool)

The **offsets** in those dumps are not usable: the two C# dumps disagree with
each other (`Points` at 32 in one, 40 in the other), so they are different
engine versions and neither can be assumed to be this one.

`Height` is the one value shape cannot separate — `VolumeVectorShapeData`
declares it and the `VectorShapeData` it inherits from declares `Tension`, both
floats. A float of exactly 0.5 is Tension's untouched default and is discarded;
a single survivor is the height. Otherwise 0, which is `PolygonVolume`'s own
value for infinite height and the right answer for a capture zone anyway.

## What gets built

| mined kind | scene | notes |
|---|---|---|
| capture | `conquest/CapturePoint.tscn` | + `PolygonVolume` child wired to `CaptureArea` |
| combat | `common/CombatArea.tscn` | + volume wired to `CombatVolume` |
| zone | `PolygonVolume.tscn` | the polygon *is* the node — no wrapper invented |
| spawn | `entities/SpawnPoint.tscn` | added to its flag's `InfantrySpawnPoints_TeamN` |
| obb | `OBBVolume.tscn` | `size` = 2 × HalfExtents |

Measured on MP_Aftermath conquest: 5 CapturePoints, 3 PolygonVolume zones, 2
OBBVolumes, 137 SpawnPoints. Capture areas 268–562 m². Five flags is what the
map has.

**The spawns are `SpawnPoint`, not `AI_Spawner`,** and the obvious reading is
the wrong one. The game type is `AlternateSpawnEntityData` and `AI_Spawner.tscn`
is the scene whose export is literally `AlternateSpawns` — but in Portal that
export is an `Array[SpawnPoint]`, so the thing the game holds **one** of is a
`SpawnPoint`, and `AI_Spawner` is a container for a list of them. These entities
cluster around capture points and carry a `Team`, which is exactly what
`CapturePoint.InfantrySpawnPoints_TeamN` is for.

## 4. What a volume *is* is not in the data at all

`VolumeVectorShapeData` is the same type for a capture zone, a sector and a
boundary. Four ways of telling them apart were tried and three are **disproven**:

| approach | result on MP_Aftermath |
|---|---|
| the partition name | all 8 conquest volumes come out of one partition, `conquest0`. Nothing to read. |
| a `CombatAreaEntityData` beside it | 4 on the whole map, **all in strikepoint**. Conquest has none. |
| containment ("the boundary holds the rest") | **false** — conquest's largest volume holds 5 of its 7 others and 125 of 137 spawns; rush has no dominant volume at all. They overlap; they are sectors. |
| an owning entity | every type in the 25 conquest partitions, named through the corpus GUID table: 137 `AlternateSpawnEntityData`, 8 `VolumeVectorShapeData`, 2 `OBBData`, 60 `SpatialPrefabReferenceObjectData` — and **all 60 prefabs are `pf_heatzone`**, an FX volume. No `CapturePointEntityData`, no `ObjectiveData`, no name. |

The mode layers ship spawns, polygons and boxes. Conquest's objective logic is
not in them — the same partitions carry `NetworkRegistryAsset` and
`EcsRuntimePrefabAsset`, so it lives server-side.

So **size** decides, and is called a heuristic rather than dressed up as a
reading: conquest's five capture zones are 268–562 m² and the next volume up is
3,604 — a clean order-of-magnitude gap. At or under `CAPTURE_MAX_AREA` (1,500 m²)
a volume becomes a `CapturePoint`; larger stays a bare `PolygonVolume`, which is
exactly what it is and can be promoted by hand. Where a real
`CombatAreaEntityData` exists it outranks size — evidence beats heuristic.

**Names.** Flags are lettered by position, west to east, so "Flag A" is the same
flag on every run and every machine. A spawn takes a flag's letter only if it is
within `SPAWN_CLAIM_RADIUS` (30 m) of it: nearest-wins with no limit gave one
conquest flag **36 of the map's 137 spawns**, which would have written every
deploy spawn in the level into that flag's `InfantrySpawnPoints`. Bounded, the
five flags hold 18/11/13/18/21 and 56 spawns stand alone. The floating `Label3D`
reads "Domination: Flag A" / "Domination: Flag A Spawn".

**Not every subworld is a mode.** `gameplay` is the union of all of them (36
partitions, all 129 capture volumes and 579 spawns at once — picking it would
draw every mode on top of itself); `*_global` is shared setup; `gmpf_*`/`pf_*`
are cinematic prefabs carrying only lights. Filtered out, 18 "modes" become 12.

## Ownership, deliberately split

The gameplay objects are **owned** by the edited scene: they save with your
level, because rebuilding a mode into Portal is the point. Everything else this
plugin adds is `owner = null`.

The labels are **not** owned. A `Label3D` is not a Portal type and baking one
into the level file would put a node the deploy validator has never seen into
every save. They are rebuilt whenever a mode is shown.

Switching modes **hides** the previous one rather than destroying it, so
switching back is instant and your edits survive. Delete the node and the panel
rebuilds it from the mined file on the next tick; delete the mined file too and
the next map open re-mines it from the install.

## Tested

    tools/test_gmmine.gd    shape reading, lettering, spawn-to-flag, volume
                            geometry. No install, no SDK - runs anywhere.
    tools/test_gmbuild.gd   the whole chain, in the Portal project: mine, write,
                            build, read back node types and wiring, then switch
                            away, switch back and delete-and-rebuild.
                            NEEDS THE EDITOR CLOSED (it holds the project).

## Probes

    tools/probe_gameplay.gd   what the walk drops, by name/kind/scope
    tools/probe_gmlayer.gd    partitions under _layers_gameplay
    tools/probe_gm4.gd        instances and fields of one partition
    tools/probe_gm5.gd        run the walk with extra want_types
    tools/probe_gm8.gd        every field of every gameplay entity, by shape
    tools/probe_gmjson.gd     what the MINED FILE holds, by partition, with
                              areas and containment. Reads JSON only - instant.
    tools/probe_gmtypes.gd    every instance type in a mode's partitions, NAMED
                              through the corpus GUID table. This is what
                              settled the classification question.
    tools/probe_gmprefab.gd   the prefab references those partitions make

All take the level mount only (`catalogue_mount = false`), which is the
difference between a 40-second probe and one that times out. A probe run while
the editor is open competes with it for the install and can take many times
longer than it should — one was killed at 50 minutes having read 1.1 MB.
