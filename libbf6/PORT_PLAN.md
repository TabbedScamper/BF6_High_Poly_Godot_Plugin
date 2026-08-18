# libbf6 — porting the decode into a shared core

The Godot plugin's decode is GDScript. This moves it, one module at a time, into
an engine-neutral C++ library (`libbf6`) that both a Godot binding and a future
Unreal binding link against. The research is done; this is translation of
known-correct code, validated by comparing each module's output to the working
plugin.

## Scope for now: Steam only

The Steam executable is plain on disk, so the schema module just reads it. The
EA path (in-memory decrypt of a DRM-wrapped executable) is DEFERRED and revisited
later; the ABI already has a `bf6_was_lifted()` flag reserved for it, which stays
0 until then. Nothing in the core needs the lift to reach a working Steam build.

## Three layers

```
        libbf6 (C++, this dir)          <- reads + decodes the game. No engine.
       /                      \
  Godot binding            Unreal binding
  (GDExtension, thin)      (editor module, thin)
```

The contract is `include/bf6_core.h`. Nothing engine-specific crosses it;
nothing Frostbite-specific leaks past it.

## Module map (GDScript -> core), in dependency order

| # | Core module          | Ported from (GDScript)          | Job |
|---|----------------------|---------------------------------|-----|
| 1 | `oodle`              | `native/src/bf6_oodle.cpp`      | ALREADY C++. Loads the game's oo2core, decompresses. Reuse. |
| 2 | `container` / `cas`  | `bf6_container.gd`, `bf6_cas.gd`| Find install, mount TOC/superbundle, read + decompress a chunk by id. |
| 3 | `source`             | `bf6_source.gd`, `bf6_bundle.gd`| The res/ebx/chunk tables and name -> bytes. |
| 4 | `types`              | `bf6_types.gd` (Steam path only)| Read the plain type schema from the exe. |
| 5 | `ebx`                | `bf6_ebx.gd`                    | Decode an EBX partition to fields. |
| 6 | `meshset`            | `bf6_meshset.gd`                | Geometry: sections, verts, normals, uvs, indices. |
| 7 | `texture`            | `bf6_texture.gd`                | BCn passthrough + header decode. |
| 8 | `material`           | resolution parts of `highpoly_gamesource.gd`, `bf6_atlas.gd` | depot + variation -> concrete texture set. |
| 9 | `walk`               | `bf6_walk.gd`                   | The placement walk -> instances + lights. |
| 10| `terrain`            | `bf6_splat.gd` + terrain parts  | Heightfield, splat, colour map. |

The orchestration in `highpoly_gamesource.gd` (mesh_for, object_rows) becomes the
API entry points, not a module — most of it is caching and engine glue that stays
in the binding.

## The vertical slice — build this FIRST

Prove the whole spine with one asset, no browser, no map loader:

1. `bf6_open()` — modules 1-4: mount and read the schema.
2. `bf6_read_mesh(res_name, 0)` — modules 5-7: one asset's geometry + textures.
3. A tiny Godot binding turns that into an `ArrayMesh` and drops it in a scene.

When one BF6 mesh appears in Godot *through the C core*, every hard seam is
proven: mount, Oodle, schema, the ABI, the coordinate handoff. Only then is the
full port worth committing to — and the same slice re-bound in Unreal is the
Unreal proof-of-concept.

## Validation — never "looks right", always byte-equal

Each ported module is checked against the GDScript reference: dump the module's
output for a fixed asset from both, compare. Meshes compare by vertex/index hash,
textures by block hash, the walk by the placement fingerprint the plugin already
computes. A module isn't done until it matches.

## Already done

- `oodle` (module 1) — exists in C++, reused.
- Build path: MSVC + CMake -> `bf6_core.dll` (Godot) and `bf6_core_static.lib`
  (Unreal), both compiling from the stub.

## Build

```
cmake -S libbf6 -B libbf6/build -G "Visual Studio 18 2026" -A x64
cmake --build libbf6/build --config Release
```
