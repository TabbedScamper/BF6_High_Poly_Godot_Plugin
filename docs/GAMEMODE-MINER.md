# The gamemode miner: what is established, and what is left

`highpoly_gamemode.gd` renders capture rings, objective boxes, spawn spheres,
zone areas, labels and mode-gated props. It is complete and costs nothing. It
reads `gamemode_markers.json`, produced by a miner that no longer exists
(task #37). This is the state of rebuilding that miner against the install.

## Established, by measurement

**1. The data is not in the placement walk's leftovers.**

The walk drops 1,991 rows on MP_Aftermath as "no geometry", and the log calls
them gameplay objects. They are not: they are FX heatzones (119 + 119), damage
volumes, `dwc_debridpile_spawncontroller`, `ve_disable_setup`, audio prefabs and
destruction markers. Not one capture point among them. Filtering rows we already
have was the cheap hope and it is dead.

**2. Gameplay entities are reachable, and the mechanism is proven.**

They derive from `SpatialEntityData` with no `ReferenceObjectData` - the same
reason Portal vehicle spawners are invisible to a placement walk - so they are
reached as ENTITIES, which `BF6Walk` already supports. `want_types` maps a type
GUID to a name and `_collect` composes the world transform; that is exactly how
the level's 3,874 lights arrive.

Adding `CombatAreaEntityData`'s GUID to `want_types` and running the walk
collected **2 CombatArea entities** with composed transforms. The route works.

**3. Type GUIDs come from joining two research tables.**

Neither file alone is enough, and this is the non-obvious part:

    data/ebx_typehashes.tsv        name_hash -> NAME
    data/ebx_type_identities.tsv   name_hash -> EBX type GUID

Join on the hash:

    CapturePointEntityData  0x20A56C13  8cba5d25-59fe-fa86-1c2a-8140e224d7da
    ObjectiveData           0x43C5B076  e529dbe3-1ef0-5632-37a6-82f9a3ac003f
    CombatAreaEntityData    0x8214E119  e36c4110-716c-d05f-7615-8f7b8a5d620b

`LIGHT_TYPES` carries TWO GUIDs per name, so the tables likely also hold a
second encoding per type; the rotated form tried in probe_gm5.gd collected
nothing, so that guess is unconfirmed.

## Not established

**CapturePoint and Objective collected ZERO on MP_Aftermath.** Two readings, and
they need different work:

  a) the walk traverses the level's default graph and the per-mode subworlds
     (`_layers_gameplay/conquest/...`) are not referenced from it, so the
     entities are never visited; or
  b) conquest capture points are a different type from `CapturePointEntityData`.

Distinguishing them is the next step. (a) is testable by walking a mode
partition as a root; (b) by dumping every distinct type GUID the mode partitions
contain and joining those back through the tables above.

`conquest_captureareavisualisation` is the only capture-named partition on the
map and its single instance is a container of references, not the areas
themselves - consistent with (a).

## Tools

    tools/probe_gameplay.gd   what the walk drops, by name/kind/scope
    tools/probe_gmlayer.gd    partitions under _layers_gameplay
    tools/probe_gm3.gd        level partitions matching gameplay words
    tools/probe_gm4.gd        instances and fields of one partition
    tools/probe_gm5.gd        run the walk with extra want_types  <- the live one

All take the level mount only (`catalogue_mount = false`), which is the
difference between a 40-second probe and one that times out.
