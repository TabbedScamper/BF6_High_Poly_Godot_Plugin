# v2.0 — read the player's own game, distribute nothing (design)

On 2026-08-05 Battlefield Studios asked for the Model Viewer to be taken down,
because it "hosts and distributes Battlefield game content on a third-party
website". That is a statement about **distribution**, not about builders having
the assets: the SDK's own config carries
`"downloadUrl": "https://download.portal.battlefield.com/"`, and its
"Download Texture" button already fetches Battlefield art onto the same
machines.

So v2.0 removes the part that was objected to. Every asset comes from the
user's own installed copy of the game. Nothing is hosted, nothing is
redistributed, and the R2 bucket goes away.

> **Not built yet, and should not be, until EA have been asked.** They named
> TabbedScamper as someone they are already talking to and said they
> want to bring these capabilities into their supported ecosystem. "We rebuilt
> it to read each user's own copy, does that work for you?" is a far better
> conversation than them finding out afterwards — and if they would rather
> serve it from `download.portal.battlefield.com`, that is a better outcome
> than this document and most of it becomes unnecessary.

---

## 1. What we already have

Almost all of it. The pipeline is already ours, in Python, and it already
implements the hard formats.

| already ours | what it reads |
| --- | --- |
| `ebx.py`, `ebx_deser.py`, `ebx_read.py` | RIFF-EBX object partitions |
| `typesdk.py` | the reflection type SDK |
| `meshset_read.py` | MeshSet geometry, vertex/index decode |
| `mvdb_v2.py` | MeshVariationDatabase |
| `msdb.py` | MeshScatteringDatabase |
| `depot_tex.py` | material to texture association |
| `bf6_splat.py` | terrain splat masks |
| `shaderblock.py` | ShaderBlockDepotResource |
| `walk_level.py` | level to subworld to placement traversal |

And the specification to build the rest from: the
`bf6-highpoly-pipeline/docs/frostbite-reference`, 512 KB across 14 documents,
written to be "sufficient to reimplement the described formats and pipelines
from scratch, with no other material beyond the game's own files and
executable". It is empirically grounded — the codec table comes from a scan of
all 8.1M BF6 asset segments — and it marks its own open questions.

## 2. What is missing, exactly

One layer. Everything above consumes **loose extracted files**:
`walk_level.py` walks a directory of `.ebx`, and `meshset_read.parse()` takes a
path. The closed-source `.exe` tools do exactly one job — turn the game's
containers into those loose files — and that is the whole gap.

    game install                  <- 143 GB, 145 tocs, 157 cas
      |
      |   THE GAP: toc_bf6.exe, fb_maps_bf6.exe, fb_terrain_bf6.exe
      v
    loose .ebx / .res / chunks    <- what the pipeline reads today
      |
      |   already ours, in Python
      v
    props / terrain / textures

## 3. Verified against a retail install

Checked against `steamapps/common/Battlefield 6`:

- **Oodle is in the install** (`oo2core_9_win64.dll`, 654,184 bytes, also under
  `SP/`). The spec says BF6 uses **only OodleKraken and raw copy-through**, so
  this is the single native dependency, and it is loaded from the user's own
  game folder rather than shipped. Note the copy in `bf6-extractor` is a
  *different, older* build (597,504 bytes) — we have been redistributing a
  proprietary RAD/Epic DLL unnecessarily, and this removes that too.
- **The containers are all present**: `Data/layout.toc`, `Data/initfs_Win32`,
  `Data/chunkmanifest`, and 157 CAS files.
- **Every level is present — 29 of them.** All 24 we publish, plus
  `mp_isolated`, `mp_golmudrailway` and `mp_aftermath_portal`, which are on our
  own backlog as never built. 54 of the level TOCs live under `Update/`, 4
  under `Data/`.
- **Per-map superbundles** at `Data/Win32/game/glaciermp/levels/mp_<map>/`.
  That granularity is what makes on-demand work: a user extracts the map they
  are editing, not 143 GB.

A first pass at this scan looked only at `Data/` and concluded a retail install
carried four maps. It carries all of them; `Update/` is 97 GB of the 143.

## 4. Build order

Each phase is independently verifiable against the dump we already have, which
is the reference answer: the new reader must produce what the `.exe` produced.

### Phase 1 — the container layer (this is the gap)

1. **Oodle binding.** Locate the game, load `oo2core_9_win64.dll` from it,
   bind `OodleLZ_Decompress`. Validate every output against the header's
   `decompressedSize`; the spec is explicit that a mismatch is an error.
2. **`layout.toc` + `initfs_Win32`.** DbObject binary format (CONTAINERS §2),
   the manifest (§3), the encryption envelope (§4). Yields the install-chunk
   table and CAS path resolution.
3. **SuperBundle TOC.** `SbTocHeader`, the Huffman name block, bundle map,
   loose-chunk map (CONTAINERS §5).
4. **Bundle + CAS reader.** Produces the one API everything else needs:
   `get_resource(guid) -> bytes` and `get_chunk(id) -> bytes`.

Phase 1 alone replaces `toc_bf6.exe`. Test: extract a known map and diff
against `A:\bf6pull\dump` byte-for-byte.

### Phase 2 — the readers not yet in Python

5. **Texture RES to pixels** (TEXTURES.md) — replaces
   `Batch_texture_Converter_BF6.exe`. `bf6-srgb-dds-decode` already covers the
   sRGB trap.
6. **Terrain streaming tree** (TERRAIN.md §2-7) — replaces
   `fb_terrain_bf6.exe`. Heightfield trees, splat coverage, raster trees.
   `bf6_splat.py` already covers block 1.
7. **Mesh**: `meshset_read.py` exists; it needs to accept bytes instead of a
   path so it can read straight from the container layer.

### Phase 3 — wire it to the pipeline

8. A resource provider behind the existing entry points. Two options, and the
   first is the safe one: **(a)** write the same loose-file layout the dump has,
   so nothing downstream changes at all; **(b)** pass bytes directly and skip
   the intermediate. Start at (a), move to (b) once (a) is proven, because (b)
   is what makes per-map extraction cheap enough to run on a user's machine.

### Phase 4 — the plugin

9. **Find the game.** Steam path, EA app, registry, plus a manual picker.
   Handle "that map is not in your installation" as an ordinary message.
10. **Per-map, on-demand, in the background**, with the progress lanes the
    plugin already has.
11. **Delete the download path.** No manifest, no R2, no self-update-over-CDN
    for content. The plugin becomes a reader, not a client.

## 5. What this costs the user

Extraction replaces downloading. Measured on the existing pipeline, per map:
**~10 minutes for a 1,000-prop map, ~56 for Aftermath's 6,445** — against
today's 15-second download. It is once per map, cached afterwards, and can run
in the background, but it is a real regression and should be stated plainly in
the UI rather than hidden behind a spinner.

The pre-baked work from v1.37 still applies: what gets cached locally after
extraction is the same `glb` + `bctex` + `geom.res` set, so the *second* load
of a map is unchanged.

## 6. What we are not doing

- **No DRM circumvention.** `rse-ooa-decrypt` and anything like it is out. It
  targets Origin activation on executables, it would not help with assets
  anyway, and it is a separate and worse exposure than the one being fixed.
- **No third-party source.** `id-daemon`'s C# is genuinely the source behind
  the `.exe` tools, but it ships with **no licence file** — all rights reserved
  by default — and depends on `APPLIB` and `DMF`, which are not in the archive.
  We have a specification written for clean reimplementation; use that. Consult
  id-daemon only to sanity-check a field, never to copy.
- **No redistribution of Oodle.** Load the user's copy.
