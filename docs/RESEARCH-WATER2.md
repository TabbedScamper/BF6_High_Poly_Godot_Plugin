# RESEARCH-WATER2 — block 5, mp_isolated, the game-look "culprit", LakeData, mp_propaganda

Follow-up to MAP-TUNGSTEN.md §U (block 2 = the water-surface heightfield; the
plugin now meshes it). Data: the 2026-08-01 pull (`bf6_paths.py` root),
READ-ONLY. All probes under `tools/`:

```
probe_water2_block5.py       Q1  block 4/5 decode + joins vs block-2 water
probe_water2_isolated.py     Q2  mp_isolated block 2 + block 10
probe_water2_gamelook.py     Q3  depot record -> _apply_game_look, per map
probe_water2_lakedata.py     Q4  eastwood LakeData footprints vs block 2
probe_water2_propaganda.py   Q5  mp_propaganda census
```

Every claim is tagged MEASURED (a probe printed it) or HYPOTHESIS.

---

## 1. Block 5 is NOT a water-coverage mask — the hypothesis is dead

**MEASURED, three ways, two maps** (`probe_water2_block5.py`):

1. **Leaf coverage saturates.** Tungsten block 5: 693 nodes, 520 leaves,
   every leaf `coverage=1`; painting cov=1 leaves fills **100% of the world
   raster**. Precision against the true wet mask (block2 > block0 + 2 cm):
   **0.056** (recall 1.0 only because everything is covered). Same on
   isolated (precision 0.114). Identical under both child-quadrant
   conventions, and block 4 — which ships on every map, water or not —
   scores identically. A mask that covers everything masks nothing.
2. **The only non-default bits are atlas bookkeeping.** On tungsten, isolated
   AND block 4 alike, the exceptional nodes are the same five: root +
   its four depth-1 children with `hasData=1, coverage=0`. That is the
   resident-mip top of an atlas tree, not geometry.
3. **The tree shape does not bound the water either.**
   - tungsten: block 5 == block 4 truncated at depth 5, EXACTLY (693 == 693
     nodes, key-for-key) — its shape is block 4's, i.e. the terrain atlas
     pyramid one level short (block-2 atlas is half block-0's resolution:
     2048 vs 4096 wide in the two headers).
   - isolated: block-2's keys are NOT a subset of block 5's (the 64 depth-6
     water nodes have no block-5 node at all), so block 5 cannot even name
     where the water data lives.
   - The best shape-derived raster anywhere (isolated max-depth leaves vs
     wet) reaches precision 0.603 / IoU 0.598 — on tungsten the same test
     gives 0.058. Not an edge-cutting signal on either map.

**Eastwood's block 5 is a different, undecoded format** (MEASURED: header
`Dim=260, Unknown16=0, N=53`, size 211 != 57+4*53; the 154 payload bytes fit
no 1–4-byte-stride pre-order or BFS quadtree over header lengths 40..80 —
brute-forced). Irrelevant to the verdict; tungsten (canonical format) and
isolated already kill the hypothesis.

**Consequence for the plugin:** block 5 cannot cut water edges. The exact
edge is, and always was, in data the water path already holds: **per-texel
`block2 > block0` in the same chunk** (block 0 sits at offset 0 of the very
chunk the block-2 payload is sliced from). See §6.

## 2. MP_ISOLATED — the fjord at 100.50 m, and why terrain_water() fails twice

`probe_water2_isolated.py`, all MEASURED unless marked.

**Block 2 ships at HALF resolution here: xs=137**, not the fleet's 265
(header: MinMax stack 4, occluder 5, density side 35, `data_size` 39,919 vs
149,297). WorldSizeY 800, world 8,192 m.

**The tree is an LOD mosaic.** External nodes exist at depths 2..6 and the
shallow ones are coarse ancestors of the deep ones; an Empty CHILD of an
External means "no further refinement", not "no water". Composite deepest-
last (exactly the plugin's `composite()`), never sum per-depth areas.

**The water:** one flat body at **exactly 100.50 m** — fill value u16 8233 —
covering **7.45 km²** (water > ground + 2 cm, 2 m/px mosaic), spanning
x −2048..0, z −2048..+2048: a north–south fjord/river filling the west-centre
of the map, ~1 km wide, running the full 4 km. Wet area per 512-m z-band is
0.79..1.03 km² with mean level 100.50 in every band — **no downstream fall**
(tungsten's river falls 76→67 m; this one is a sea-level channel). A single
1.05 km² patch (x −1536..−512, z −512..+512) refines to depth 6 and carries
levels up to **109.12 m** (the root band top; reads as rapids/weir pools
above the main level — HYPOTHESIS on the reading, the numbers are measured).

**The dry fill IS the water level.** 98% of texels hold 100.50 — and so does
the water. Terrain floor 0.12 m (block-0 root band 0.12..730.49): the fill
is far ABOVE the floor, the inverse of tungsten (fill 0.77 m below floor).

**Chunk layout is different too.** The block-2 payload ends **8,712 bytes
(= 2 x 4,356) before chunk end** on depth-6 chunks and **26,136 (= 8,712 +
17,424, one extra colour tile)** on shallower ones — pinned by a 2D-
smoothness scan to the byte, at ODD byte offsets (payload starts are not
even-aligned here). The tungsten tail set {0, 17424, 34848, 85024} never
lands on it.

**Why the plugin's terrain_water() fails on isolated — twice (MEASURED):**

1. `fetch2` tries `chunk_len - tail - data_size` for tails {0, 17424, 34848,
   85024}; the needed tails are **{8712, 26136}**. Every candidate misses,
   the 0.9 in-band gate rejects (best wrong-offset overlap ≈ 0.77), every
   External node drops.
2. Even with the payload, the clip `wet = fill + 0.5 m` selects **0.013 km²
   of a 7.45 km² water body** — the water sits AT the fill, and only the
   109-m rapids patch clears the margin. The mode-based clip has zero
   overlap with this map's authoring.

Ground-relative selection (`block2 > block0 + 2 cm`) gets it right with no
per-map constant.

### Block 10 (isolated only, 10,078,978 bytes)

**MEASURED:** header (40 B): u32 tag **515**, u32 0, float4 bbox
(−4096, −4096, 4096, 4096), u32 counts **93, 38, 4, 1**. Then a **388-byte
preamble** of 0/1 bytes (17 ones, all within the first 54 bytes; fits no
1-byte tree walk tried — encoding open), then **38 tiles of 515×515 u8**:
`40 + 388 + 38·515² = 10,078,978` exactly, and per-tile row stride 515 wins
2D smoothness against 514/516 on every tile. The field is a smooth scalar:
65.7% zeros, 14.5% saturated 255, 19.8% gradient in between.

**HYPOTHESIS:** a ~1 m/px water/wetness coverage or shore-distance field
stored in 512-m tiles over the water region (the 255 fraction matches the
wet footprint's scale, and the block ships only on this, the map with by far
the largest water body). Tile→world placement lives in the undecoded
preamble, so the semantics were not position-tested. Nothing the plugin
needs — block 2 + block 0 already give exact edges.

## 3. The game-look "culprit": measured, the mapping is acquitted of invisibility

`probe_water2_gamelook.py`. Water depot records resolved for all five maps
(state keys via u64-scan of `_layers_content/water.ebx` against every depot
under the level; dumbo's from MAP-DUMBO.md):

| map | key | variant | record |
|---|---|---|---|
| mp_tungsten | 109c22da5f67cf7a | ocean | 4 tex, 1 float3, 24 consts |
| mp_eastwood | 532df991f61dc281 | ocean | 3 tex, 1 float3, 25 consts |
| mp_isolated | 42914acb1555cfd8 | ocean+ | **5 tex, 3 float3, 74 consts** (a third, richer variant: two extra texture slots b4b73136 / 6ac9c660, and scalars that look like world distances — 1907.8, 2775.9, 1091.1…) |
| mp_aftermath | eb5c36f3d86ed23d | foam | 1 tex, 2 float3, 5 consts |
| mp_dumbo | 42f38eeaac4aa54e | foam | 1 tex, 2 float3, 5 consts |

**What _apply_game_look binds, with the measured numbers (linear floats):**

| uniform | tungsten | eastwood | isolated | aftermath (works) | dumbo (works) |
|---|---|---|---|---|---|
| game_shallow | (.309,.495,.498) | (.143,.142,.121) | (.569,.829,.890) | (0,.076,.082) | (.068 grey) |
| game_deep | ×0.28 = (.087,.139,.140) | ×0.28 | ×0.28 | (0,.056,.044) mined | (.022 grey) mined |
| ripple_* | ocean override 34/0.6/0.35 | same | same | — | — |
| foam/detail tex | foam_nsh+detail_nsh (mode 2) | same | same | foam_rgb (mode 1) | foam_rgb (mode 1) |

**The verdict (MEASURED):**

- **Alpha: impossible.** `_apply_game_look` touches no alpha uniform;
  `water.gdshader` computes `ALPHA = clamp(mix(0.45, 0.94, df) + …)` —
  **≥ 0.45 for every reachable uniform state**. "Alpha near zero" is not a
  thing this mapping can do.
- **Colours ~0: false on the failing map, true on the working ones.**
  Tungsten binds a pale glacial teal — shallow luminance 0.455 vs the
  river preset's 0.299 that demonstrably renders (`2e32a5a`); it is
  *brighter* than what works. Dumbo (0.068) and aftermath (0.061 luminance)
  are far darker and rendered on screen. Colour magnitude cannot separate
  the failure from the successes.
- **Texture-to-black: cannot produce invisibility either.** The only
  remaining look-dependent binds are foam_mode=2 + detail_nsh. Worst cases
  in the shader are foam saturation (a BRIGHT sheet: foam_col 0.6..1.2,
  alpha +0.4) or a no-op (texture null → slot never set); no path lowers
  alpha below the 0.45 floor.
- **The conviction came from a confounded experiment.** The "invisible"
  observation predates two water-lifecycle fixes that are *exactly*
  renders-nothing mechanisms and were live during the game-look attempt:
  `330e80f` (water mined EMPTY early in the session and never re-asked —
  the milestone flag made every later path read "this map has no water")
  and `c4f7048` (ensure_layer's early-return kept SHOWING a stale Water
  node through every toggle). The plain-material test that "proved" the
  material was at fault (`5487706`) shipped *after* both fixes and also
  renamed the node out of the auto-rename collision. Three variables
  changed, not one.

**HYPOTHESIS (the actual culprit):** the stale/empty water-answer lifecycle
(330e80f + c4f7048), not any uniform. **The corrected mapping table is the
one above — the mined values as bound are visible-by-construction**, and the
mapping is validated against dumbo/aftermath, which rendered on screen with
identical code and darker colours. The right next step is mechanical, not a
remap: re-enable `_apply_game_look` on the river (put `look` back into the
`HighpolyWater.material` call in `_add_water_plane`'s block-2 branch) now
that the lifecycle is fixed, and verify on screen. If it still fails, the
suspects are the two `gs.water_texture` decodes (detail_nsh / foam_nsh) —
the only binds that differ structurally from the foam variant — and they can
be A/B'd by passing `gs = null`, which keeps the colours and drops only the
textures.

One real open issue in the mapping, unchanged by this study: which of the
foam variant's two float3s is shallow (documented in `highpoly_water.gd`);
and note that eastwood's mined colour is a murky beige-grey
(0.143, 0.142, 0.121) — correct for its canal/pond water, but it will read
"brown" next to the blue presets; that is the game's authoring, not a bug.

## 4. Eastwood: block 2 covers LakeData 100.0% — do NOT build a LakeData reader

`probe_water2_lakedata.py`, MEASURED:

- **42 LakeData instances** found in the level (≈21 unique lakes authored in
  two partitions — the list pairs off by identical y/area).
- For **every one of the 40 polygons big enough to sample at 2 m** (the two
  skipped are < 4 m²): block-2 coverage inside the polygon **100.0%**, and
  block-2 within 0.5 m of the authored lake level **100.0%**. Totals:
  53,472 m² of polygon, 100.0% covered, 100.0% at level.

**A LakeData reader would add nothing on eastwood. Loudly: do NOT build
one.** Block 2 is the shipped, rasterised form of the same authoring, to
the centimetre (§U4) and now to the footprint.

The reverse direction is the real finding: eastwood's **above-fill clip
selects 3.399 km²** of surface while the true water (block2 > block0) is
**0.030 km²** — the wet plateaus extend far past the lake shores, authored
*under the terrain* exactly like tungsten's dry fill. The current fill+0.5
mesh on eastwood is **~113× over-selected** (mostly z-buried underground,
but it is geometry built and drawn edges wrong). Ground-relative selection
collapses it to the true 0.030 km², which agrees with the unique-lake
polygon area (~27k m²) at raster granularity.

## 5. MP_PROPAGANDA census

**MEASURED** (`probe_water2_propaganda.py`): mp_propaganda does not exist as
a level in the 2026-08-01 pull. The name appears in exactly two places:
`game/glaciermp/levels/mp_propaganda/` containing six
`pf_mil_propaganda_*` barricade prefabs and one `tweakables/mut_propaganda.ebx`
mutator, and `test/testranges/mp_propaganda/` with the mutator alone. No
level.ebx, no terrain directory, no streaming tree (so no block 2), no
water-, lake-, river- or ocean-named partition, no LakeData GUID hit. There
is no terrain and no water of any kind; nothing for the plugin to do until a
future pull ships the actual level.

## 6. Actions for the plugin (priority order)

1. **Cut water edges ground-relative, everywhere** (`terrain_water()`):
   mesh where `block2 > block0 + ε` (block 0 is at offset 0 of the same
   chunk), drop the modal-fill + 0.5 m clip. Measured stakes: tungsten
   1.95 → 0.82 km² (over-selection gone), eastwood 3.399 → 0.030 km²
   (113×), isolated 0.013 → 7.45 km² (the clip currently *erases* the
   map's fjord). No block-5 reader — §1.
2. **Per-level tail candidates in `fetch2`**: add {8712, 26136} (or better:
   derive the offset from the in-band scan over a widened candidate set —
   the 0.9 gate already validates). Without this, isolated renders no water
   at all even after fix 1. Note isolated's block-2 payload offsets are
   odd-aligned; slice by byte, no alignment assumption.
3. **Handle xs(block2) != xs(block0)**: isolated ships block 2 at xs=137
   against block 0's 265. `data_size`, the in-band comb, and any same-chunk
   block0/block2 comparison must use each block's own header (the probes'
   `data_size(h)` is the identity `read_block_header` already computes).
4. **Re-test _apply_game_look on the tungsten river** with the lifecycle
   fixes in place before writing any remap — §3: the mapping is acquitted
   by the numbers; A/B `gs = null` isolates the two _nsh textures if it
   still fails.
5. **Do not build a LakeData triangulator** — §4.
6. **Upstream to TERRAIN.md**: blocks 4/5 are atlas bookkeeping trees
   (leaf coverage saturated; the five hasData nodes are the resident mip
   top; tungsten's block 5 == block 4 truncated at depth 5); eastwood's
   block-5 variant format (Dim=260, U16=0) and isolated's block 10
   (515-tile u8 field, preamble open) are documented here.
