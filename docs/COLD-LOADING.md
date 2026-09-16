# Loading directly from the installed game

Optional installation-time [cache preparation](CACHE-PREPARATION.md) builds
local map resources with game-update and add-on recipe checks. It complements
the direct-read improvements below; it is not a measured cold-load improvement.

Both readers now resolve archive locations once per opened install, read only
the compressed blocks needed for partition GUIDs, and composite compact height
textures directly. Godot's native environment mounts the selected level and
loads its schema without repeating the scene placement walk. Ground preparation
shares repeated sheets within that request. These improvements do not require
a saved asset cache or exported game data.

Selected-level and material/depot boundaries remain intact. Indexes retain
their original deterministic order and duplicate resolution. Windows TOC paths
are normalized so slash and dot-segment aliases no longer parse them twice.

## Measurements, September 12, 2026

Fresh-process comparisons on the development workstation, using the installed
Steam game. Windows filesystem cache was not purged. These are stage timings,
not complete storage-cold map loads or minimum-spec FPS measurements.

| Work | Previous | Updated | Validation |
| --- | ---: | ---: | --- |
| Tsuru partition index | about 7.0 s | 0.69–1.02 s | Same 236,233 mappings |
| Tsuru environment products | 32.76 s | 18.40 s | Identical metadata and payload hashes |
| Granite environment products | 33.55 s | 15.95 s | Identical metadata and payload hashes |
| Granite ground composition only | 1,686 ms, 512.1 MiB output | 11.1 ms, 2 MiB output | 1,048,576 exact samples |
| Granite water composition only | 420 ms, 128 MiB output | 27.3 ms, 8 MiB output | 4,194,304 exact samples |

The environment comparison requests water, compact water/ground heights,
64-pixel ground/far-ground products and one ocean frame. Production coverage
and sheets cost more and are tested separately. Composition-only measurements
exclude mounting and parsing. The complete Unreal ABI 5 compact ground API
measured 295 ms versus 1,975 ms for the full grid in a separate check.

Disabling archive path reuse in the same binary restored a roughly 7-second
Tsuru index. Full/bounded index hashes match on Tsuru, Granite and the armory;
per-record samples agree 4,009/4,009, 4,056/4,056 and 4,011/4,011. Shifted-byte
and shuffled-neighbour controls produce zero matches. Bounded reads reduce
decoded bytes but do not consistently beat full reads after lookup overhead
is removed. Experimental memory mapping was slower and is disabled by default.

The compact compositor also matches all pixels at sizes 1000 and 1500 on
Tsuru. Shifted/transposed controls differ; invalid sizes and levels reject.
A repeated TOC alias adds 43,890 duplicate listings with literal identity and
zero with normalization, while the actual resource set stays identical.

## Build and verification

Godot uses ABI 4; Unreal uses ABI 5. Build each against its own complete header
and package manifest. The additive `bf6_prepare_level` and
`bf6_read_terrain_preview` exports do not make the DLLs interchangeable.
The preview uses the existing terrain structure and `bf6_free` ownership.
Full terrain APIs remain available for geometry.

Native CMake targets:

- `bcn_decoder_equivalence_test`: 83 checks covering all BC7 modes, cross-word
  fields, independent known pixels, bit-flip controls, malformed input and
  unchanged BC1/3/4/5 output. The optimized reader extracts fields from two
  64-bit words instead of visiting every individual bit.
- `cas_range_test`: ranges, truncation, malformed data and controls. Its optional
  directory is a parent; it creates a unique child and never deletes that parent.
- `partition_stream_test <game_dir> <level> [--armory] [--rounds N] [--sample N]`:
  full/bounded comparison with saved index caching disabled.
- `mount_identity_test <game_dir> <level>`: repeated-path and missing-file controls.
- `terrain_sampled_test <game_dir> <level> [ground_N] [water_N]`: exact lattice
  comparison and perturbation controls.

Godot `tools/test_loading_products.gd` emits metadata/content hashes.
`tools/run_native_environment_test.py` runs the GPU harness, including production
coverage/sheets and hidden-ground, hidden-water, frozen and amplified-ocean
controls. Both Tsuru and Granite pass all 23 GPU checks. Vertex/ocean CTests
also pass. Unreal's host module builds; its ABI 5 preview output agrees with
full-grid subsampling for all 5,242,880 checked pixels.

Diagnostic comparison switches:

- `BF6_CAS_UNCACHED_PATHS=1`: resolve archive filenames on every read.
- `BF6_PARTITION_INDEX_FULL_READ=1`: read full records for GUID indexing.
- `BF6_MOUNT_LITERAL_PATH=1`: unnormalized TOC identities.
- `BF6_ENVIRONMENT_FULL_WALK=1`: restore the Godot environment placement walk.
- `BF6_CAS_MAPPED_READ=1`: experimental mapped reads, disabled by default.
- `BF6_BCN_REFERENCE_BITS=1`: original per-bit BC7 decoder for pixel comparisons.

Archive contents are immutable for the open reader session. Restart after a
game update. Bounded GUID lookup validates the ranges it needs, not unused
trailing compressed data; later full asset reads still report that corruption.

## Remaining work

Ground texture decoding and CPU baking still dominate this environment path.
An installed Unreal Tsuru smoke run completed normally: 51,951 of 55,331
placements, 3,801 meshes, 576 non-geometry entries, about 46 seconds of scene
preparation. Existing derived assets were used, so this is a compatibility
check, not a cold benchmark. Its phase log reports 10.61 s terrain and 27.19 s
objects, including 12.77 s materials/textures and 8.63 s mesh commit. These are
the next measured engine-side bottlenecks; the phase numbers overlap only where
explicitly described as subphases and should not all be added together.
Godot still has a separate script scene reader, and the exact terrain evaluator
still uses per-request processes. Source-backed texture streaming, budgeted
scene uploads, and complete level-open-to-ready measurements remain necessary.
These changes do not establish a 10-second complete cold start, sustained 60 FPS,
or performance on 16 GB / 6 GB machines.

Local evidence: `C:/PortalSDK_1.4.2.0/out/asset-streaming-2026-09-12/`.
