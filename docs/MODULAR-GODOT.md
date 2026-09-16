# Optional Godot tools and the integrated Unreal SDK

The Godot tools are independently selectable add-ons. Unreal continues to offer
these functions in the integrated SDK. An absent optional Godot editor must not
prevent High Poly or another installed editor from opening.

## Repository responsibilities

| Repository | User-facing responsibility |
| --- | --- |
| BF6_High_Poly_Godot_Plugin | Game assets, material/environment previews, standalone resource preparation, and future actual game collision previews. |
| BF6_Godot_Map_Selection | Friendly map names, safe base-map opening and resuming creator scenes. Optional entry into high-poly preparation. |
| BF6_Godot_Extended_Workspace | Slide-out editor panels, pinning, and extra viewport space. It hosts panels when present; it is not required by their editing logic. |
| BF6_Godot_Blockly_Editor | Offline block workspaces, editing aids and Portal-compatible script export. |
| BF6_Godot_Portal_Connect | Opt-in authenticated Portal profile access, experiences and upload. Offline editing must work without it. |
| BF6_Godot_Prop_Categorizer | Customizable prop-library organization. Categories are library metadata, not destructive moves of game resources or scene nodes. |
| BF6_Godot_Player_Controller | Local walkthrough for scale and placement checks. Preview-only state must be removed on exit. |
| BF6_Godot_SImple_Collisions | Lightweight projected collisions based on prop X scale. This remains distinct from authored game physics. |

These names and responsibilities follow the repository descriptions inspected
on September 12, 2026. The standalone TypeScript editor is also planned; its
repository was not yet present in that listing. This is a responsibility map,
not a claim that those new repositories already contain completed plugins.

The current development baseline implements Map Selection, Extended Workspace,
Prop Categorizer, Player Controller and Simple Collisions. Their authoritative
sources and validation records live in the Unreal SDK's `Shared/Godot` registry;
standalone repositories are mirrors produced by its distribution tool. They are
development builds pending final interactive acceptance. An additional initial
Blockly package now supports local native-workspace Open/Edit/Save through the
unchanged parent editor and a shared native host. It remains development-only:
explicit Save is required before shutdown, and extended projects are refused
to protect their extra data. Portal Connect and the standalone TypeScript host
remain pending.

The High Poly menu definitions now originate in Unreal High Poly `Shared/menu`.
Run this product's menu sync with `--unreal-plugin` to update both adapters from
that parent. `shared/menu` here is a distributed snapshot, not another authoring
source. Asset decoding stays in the engine-neutral core (the `core/` submodule);
no decoder directory move is required to establish feature ownership.

## Integration boundaries

Keep project identity, object identity, coordinates, block/script documents,
UI bindings and artifact generations in versioned data contracts. Engine
widgets and window ownership remain adapters. Do not make one optional panel
the owner of documents another panel needs to read. An upload consumes a single
bundled Portal script artifact; it must not rely on a web service to make offline
blocks usable.

High Poly owns its preparation supervisor, worker and screen. Godot already
exposes supervisor.open_preparation(); a map selector can call it when present.
Unreal exposes BF6.HighPoly.Prepare and shows a home-screen entry only while the
module is available. These are actual implemented entry points. A general
cross-plugin capability registry remains design work; do not assume it exists.

When Extended Workspace is disabled, editors must fall back to their own docks
or windows. Removing Portal Connect must remove session access without deleting
local projects. Removing previews must remove only preview-owned nodes, restore
owned editor state and preserve original scene transforms and grouping.

## Actual collision work

High Poly is intended to visualize authored game collision; Simple Collisions
continues to offer the scale-based approximation. The current high-poly menu
only exposes existing projected overlays and must describe them accurately.

Start from the current bfreader Physics/PhysicsResource.cs and
Physics/LevelPhysicsExtractor.cs, and the research repository's
formats/PHYSICS_COLLISION.md. The shared core now contains physics_ext.inc,
physics_test.cpp and bf6_physics_read in bf6_core.h. The older research finding
collision-spec-is-complete-and-unconsumed.md predates that reader and must not
be treated as current proof of a missing implementation.

Before connecting either renderer, verify level-to-resource ownership, instance
transforms, shape types, filters/presets and runtime terrain collision against
the current game. Preserve authored collision as a separate preview resource;
render-mesh triangles and bounds are not substitutes for missing collision data.
Read from the user's install at runtime. Research exports are verification
references, never a shipped runtime dependency. Reader changes remain shared;
Godot and Unreal should consume the same decoded result.
