# RESEARCH: painted layers — tint 0x4FDCF6B1 and cross-map depot sharing

Task #94 follow-up. Two questions the painted-layer compositor needs answered
before it grows: can the per-layer float3 `0x4FDCF6B1` colour the textureless
fallback, and can decoded layer slices be cached globally instead of per map.
Every claim below is MEASURED unless marked HYPOTHESIS.

Probes (all READ-ONLY on game data; caches under `%TEMP%/bf6_painted`):

    probe_painted_common.py     shared plumbing; per-level JSON cache
    probe_painted_table.py      per-map textured-layer table          (banked)
    probe_painted_coverage.py   per-layer texel coverage + dominance  (banked)
    probe_painted_tint.py       Q4: tint vs decoded colour map        (this doc, B)
    probe_painted_dedupe.py     Q5: cross-map depot content sharing   (this doc, C)

## A. Banked context (probe_painted_table / probe_painted_coverage)

Per-level layer tables (slots, consts, splat pages) and the dominance canvases
(`<level>_dom.npy`, 2112², raw-weight argmax) are cached for all 17 levels plus
the 7 Granite Portal slices. Slice budget — colour-bearing (`_cv`) layers with
splat presence, and how much covered ground lands on a cv layer:

| level | layers | textured rows | cv slices w/ splat | cv-ground % |
|---|---|---|---|---|
| mp_abbasid | 42 | 16 | 0 | 0.0 |
| mp_aftermath | 40 | 16 | 2 | 0.0 |
| mp_badlands | 46 | 33 | 14 | 87.1 |
| mp_battery | 42 | 19 | 1 | 0.0 |
| mp_capstone | 31 | 15 | 0 | 0.0 |
| mp_contaminated | 50 | 42 | 23 | 95.3 |
| mp_dumbo | 47 | 17 | 2 | 1.7 |
| mp_eastwood | 59 | 39 | 19 | 98.4 |
| mp_firestorm | 34 | 14 | 1 | 11.9 |
| mp_golmudrailway | 53 | 35 | 13 | 62.4 |
| mp_limestone | 40 | 19 | 1 | 0.0 |
| mp_outskirts | 45 | 16 | 0 | 0.0 |
| mp_plaza | 43 | 24 | 0 | 0.0 |
| mp_subsurface | 28 | 15 | 0 | 0.0 |
| mp_tungsten | 33 | 8 | 0 | 0.0 |
| mp_portal_sand | 8 | 7 | 1 | 100.0 |
| mp_granite | 63 | 53 | 35 | 55.3 |

Only Granite (35) exceeds a 32-slice Texture2DArray budget. The albedo-slot
preference (near `_cv` 0x0929399A, else distance 0x2E5ACDA8, else set-3
0x2E5B5189) is encoded in `probe_painted_common.albedo_of`.

## B. Q4 — the per-layer tint 0x4FDCF6B1

### B1. Existence — MEASURED

The float3 exists on **all 17 levels** (1–20 tinted layers each; 185 tinted
rows total). Values run 0.05 – 2.163. Patterns:

* textured BASE layers almost always carry the identity (1.0, 1.0, 1.0);
* a recurring **(0.05, 0.05, 0.05) near-black textureless base layer** appears
  on 8 maps (aftermath L33, badlands L20, contaminated L28, dumbo L40,
  eastwood L32, golmud L28, subsurface L17, granite L36) — a dark-veil layer,
  not a ground colour;
* textureless PAINTED layers carry non-trivial values, including many > 1
  (up to golmud L52 = 2.163), so the value is a **linear multiplier, not an
  sRGB albedo**.

### B2. The correlation experiment — MEASURED

`probe_painted_tint.py` renders each map's colour map with the map's own
audited decoder (`probe_*_colorrender.py`; page size and tile codec per
`docs/MAP-*.md`; mp_tungsten decoded inline — its colour tile is the FIRST
17,424-byte BC7 tile of the 2×17,424 trailer, which no fleet probe rendered
corrected), then samples the mean over each textureless tinted layer's
dominant texels (`_dom.npy`, ≥150 dominant texels, ≥60 valid colour texels)
and computes Pearson r over (layer × channel) points per map. Canvases are
joined through world coordinates (splat root vs block-0 root AABB agreed on
every map).

| map | layers used | r_srgb | r_linear |
|---|---|---|---|
| mp_outskirts | 12 | **-0.746** | -0.686 |
| mp_tungsten | 8 | 0.356 | 0.341 |
| mp_plaza | 4 | 0.143 | 0.155 |
| mp_eastwood | 4 | **-0.862** | -0.860 |
| mp_golmudrailway | 4 | -0.448 | -0.477 |
| mp_firestorm | 3 | 0.063 | 0.123 |
| mp_capstone | 2 | -0.933 | -0.931 |
| mp_battery | 2 | -0.998 | -0.998 |
| mp_dumbo | 2 | -0.996 | -0.997 |
| mp_limestone | 2 | -0.998 | -0.998 |
| mp_subsurface | 8 | undefined | (colour map is authored-neutral 0.502 grey — zero variance) |
| mp_badlands | 1 | n/a | (single usable layer) |

Pooled over 52 layers / 12 maps: raw r = **-0.193**; layer-brightness r =
-0.218; per-channel hue deviation r = +0.288 (all layers) and **+0.650**
restricted to the 22 layers with a chromatic (non-grey) tint. Best per-map hue
r: outskirts 0.843 (7 chromatic layers), tungsten 0.909 (2).

### B3. Verdict — MEASURED

**The hypothesis "tint predicts the colour map's colour over the layer's
texels (r > 0.7 on 2+ maps)" is REFUTED: 0 of 12 measurable maps reach it,**
and the only strong relations are *negative* (five maps at r ≤ -0.86 —
brighter tints sit on darker colour-map ground). The plugin must NOT paint a
textureless layer with the raw tint and call it ground colour.

What the data does support:

* **Tint chroma is real information.** The hue component (per-channel
  deviation from the layer's mean) correlates positively wherever the tint is
  chromatic (pooled r 0.650; outskirts 0.843). The tint points in the right
  colour direction even though its magnitude does not track the colour map.
* **The colour map is a modulator, not the final colour.** Subsurface ships an
  authored-neutral uniform 0.502 colour map (MAP-SUBSURFACE.md C3), i.e.
  0.5 = identity in a `albedo × 2·colourmap` composite. Against that law the
  measured anti-correlation reads naturally: layers whose intended albedo the
  colour map darkens get tints > 1, and vice versa.
* The strict inverse-compensation form (tint × 2·colourmap ≈ const per layer)
  is NOT proven: coefficient of variation of the product (0.442) is no flatter
  than of the tint alone (0.452).

**Recommendation for the plugin — HYPOTHESIS, the last piece short of task
#86:** where a textureless layer wins the splat, composite
`tint × (2 × colourmap texel)` instead of `grey × colourmap`. That is exactly
what a flat-albedo layer would do in the game's own modulation convention, it
uses the measured per-layer float, and it degrades to today's behaviour when
tint = 1. Validation of the absolute result needs the in-game PhotoMatch rig
(task #86); the numbers above only prove that tint-as-ground-colour (without
the colour-map product) is wrong.

Per-layer means and r values are banked in each level cache under `"tint"`
(`%TEMP%/bf6_painted/<level>.json`); rendered colour canvases as
`<level>_tintcolor2112.png`.

## C. Q5 — cross-map depot content sharing

`probe_painted_dedupe.py` over all 17 levels: 704 layer-table rows resolve in
their depots (388 textured, 316 textureless).

### C1. The census — MEASURED

| partition | textured rows | textureless rows |
|---|---|---|
| rows | 388 | 316 |
| distinct ShaderBlockKey | 298 | 298 (coincidence; the two key sets are disjoint) |
| distinct record content_hash | 222 | 152 |
| distinct texture-set | 119 | 1 |
| distinct textures+consts | 222 | 152 |

* **A ShaderBlockKey never maps to two different contents** — 0 violations in
  all 704 rows, across maps. Key equality ⇒ content equality (this is the
  firestorm-L15 == tungsten-L10 observation, now universal).
* **content_hash is exactly the resolved content**: no content_hash resolves
  to two different texture+const sets, and 46 contents are reached by more
  than one key (keys over-split content).
* **Byte identity is exhaustive, not sampled:** all 50 content_hashes that
  appear in 2+ levels' depots have BYTE-IDENTICAL record payloads in every
  depot that carries them (0 mismatches). The Limestone-L37/38 ==
  Tungsten-L30/31 byte-match generalises to the whole fleet.
* Sharing profile: 50 of 222 textured contents appear on 2+ levels; one
  (`30A34EB71467C69F`) on all 17; the wum family is fleet-wide
  (t_wum_concretedebris_02 on 13 levels, t_wum_dryrockygravel on 12,
  t_wum_ls_gravel_01/02 on 11/10).
* **Texture-set alone UNDER-KEYS:** 39 texture-sets are built with more than
  one distinct const block (e.g. t_larger_rocks_01_op with 6 different
  tiling/const variants). Two layers can bind the same textures with
  different tiling — a texture-set-keyed slice cache would alias them.

### C2. Dedupe ratio and cache key — MEASURED + recommendation

* Layer-record level: **388 textured rows → 222 distinct contents = 1.75×
  (43% of rows are re-binds of existing content).**
* Single-texture level (the unit the decoder actually pays for): **1,481
  texture bindings → 299 distinct texture paths = 4.95×.**

**Recommended cache keys:**

1. **Decoded-texture cache: the texture path (GUID)** — global, 4.95× reuse;
   one decoded `t_wum_ls_gravel_01_a_cv` serves every map that binds it.
2. **Layer-slice / material-record cache: the depot record's 64-bit
   `content_hash`** — byte-proven global identity, captures textures AND
   consts (tiling), and dedupes harder than ShaderBlockKey (222 vs 298).
   ShaderBlockKey is *safe* (never ambiguous) but leaves 25% of the reuse on
   the table; the texture-path set is *unsafe* (39 aliasing cases).

So yes: the plugin can cache decoded layer slices GLOBALLY. Key the slice by
record content_hash, key the underlying decoded textures by texture path.

## D. Limitations

* Correlation samples are thin on maps with 2 layers (r trivially near ±1);
  the load-bearing negatives are outskirts (n=12) and eastwood (n=4).
* Dominance uses the raw-weight argmax rule (the plugin's slice-choosing
  rule), not the over-composite; colour means are sampled at 2112² canvases.
* Q4's ground truth is the *colour map*, which C3-subsurface proves is a
  modulator — absolute ground colour needs task #86 (PhotoMatch).
* The dedupe census covers rows bound by the 17 fleet layer tables; Granite's
  Portal slices share mp_granite's depots and would only raise the ratio.
