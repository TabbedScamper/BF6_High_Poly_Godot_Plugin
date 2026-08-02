# FX emitter parameters — where the data is, and what it does not tell you

Findings from 2026-08-01, against a full fresh pull of the retail game.
Index entries: `fx-emittergraphparams-*`, `fx-composition-model`,
`fx-tints-are-white`, `fx-video-not-a-colour-oracle`, `glyph-ocr-no-engine`.

## 1. The field

Per-effect FX parameters live in **`EmitterGraphParams`**, RFL2 field hash
**`0x4832AD52`**, on the emitter EBX. Verified on the fresh pull: 60/60 sampled
`fx_*` EBX carry it, populated 4–60 entries each.

Worth stating because we confused ourselves for a while: an earlier note
described "a second unnamed `GpuExposedParameterInput` table (`f_512_4832ad52`)"
and, separately, "an `EmitterGraphParams` array that is empty on real effects".
Those are **the same field**. The minted `f_512_...` name existed only because
the real name would not resolve at the time.

## 2. Element layout

```
+0x00   float4   value
+0x20   u32      PropertyId
stride  64
```

This was settled by a **uniqueness test**, and that detail matters more than the
answer, because the wrong answer is quietly plausible:

| stride | pid offset | non-zero | distinct |
|---|---|---|---|
| 48 | +32 | 3/9 | 4 |
| 32 | +16 | 0/9 | 1 |
| **64** | **+32** | **9/9, 10/10, 12/12** | **all** |

At stride 48 the "ids" decode as floats-read-as-ints (`0x3F800000` is `1.0f`) and
values come out around −9.2e19. Reading raw bytes *suggested* 48. Only the
uniqueness test disproved it.

> Rule: a candidate id slot must be **non-zero AND distinct** across elements.

## 3. PropertyIds are a different namespace

FX `PropertyId`s are **GPU-exposed parameter ids, not RFL2 field hashes**. Field
name tables cannot resolve them — verified by confirming `Color0` / `Color1` are
absent from all of them.

68 names recovered by dictionary lookup **with a control run against the same
number of fake ids**:

| tier | real named | fake named (control) |
|---|---|---|
| dictionary (77,934 strings) | 42 | **0** |
| + family variants of confirmed names only | **68** | **0** |

Two structural corroborations that chance collisions would not produce:

- `SizeX`/`SizeY`/`SizeZ` = `0x0DCF4958`/`59`/`5A` — **consecutive**, which is
  exactly what djb2 does for names differing only in the last character.
  Likewise `Color0`/`Color1` = `0xA1C184C8`/`C9`.
- `Color0`/`Color1` had already been found by an independent djb2 hunt.

Table: **`research/data/fx_property_ids.json`** (8 colour, 14 size, 20 motion,
6 spawn, 10 render, 10 other). 518 of 586 ids remain unnamed.

**Caveat on any larger name set.** An earlier hunt of ours produced 322 names
using *generated compounds*. Run against a control, that method named 76.2% of
real keys and 71.9% of fake ones — zero signal. Treat the 68 as the trusted set.

## 4. How an effect is actually composed

```
fx_*  EFFECT = N LAYERS
        each layer -> an eg_* EMITTER TEMPLATE   (sprite + default params)
                   -> its OWN parameter overrides (the authored look)
                   -> optionally its own texture override
eg_*  EMITTER TEMPLATE = one instance; its values are DEFAULTS
```

Evidence:

- `eg_gs_basicsmoke_01` and `eg_gs_basicfire_01` have **identical** named
  parameters — `Color0=[1,1,1]`, `BaseSize=[1,1,1]`, `RotationSpeed=10`. Across
  38 templates `Color0` takes only **2 distinct values**. What makes one read as
  fire and the other as smoke is the **sprite**.
- `fx_ambwar_aadefensesystem_aerial_explosion` has 4 instances and all 19 named
  parameters differ between them (`BaseSize` 100/200/35, `Drag` 0.5/0.0/0.7/0.01).
- Of 288 sampled `fx_*`, **247 are multi-layer**, up to 10 layers.

**Consequence:** an instance in an `fx_*` partition is a *layer*. Merging
instances — which a naive first pass does — destroys exactly the authored
variation. Read parameters **per instance**.

## 5. The colour is in the texture, not the tint

This is the finding that changed our plans, and it is easy to miss because the
tint parameters *exist* and look meaningful.

Across 471 effects / 2,494 emitters:

- **4,921 of 6,218** `color0` / `color1` / `randomcolormin` / `randomcolormax`
  values are near-grey (saturation < 0.10) — **79%**.
- For each effect's **visually dominant layer** (heaviest particle count),
  **85% are at saturation < 0.02** — pure white.

So the tint channel is mostly neutral, and the colour you see in game comes from
the emitter's **texture** (plus blend mode and lighting). Any preview that
derives effect colour from tint parameters cannot match the game, no matter
which tint pair it prefers. Resolving each `eg_*` graph's texture and sampling
it is the actual lever.

## 6. Negative result: an in-game video is not a colour oracle

We tried validating colours against a video that plays every effect with its
name burned in. **It does not work, and we only know that because of a control.**

Comparing measured in-game hue to the manifest's hue gave a **median error of
15.3°** — 93% within 30°. Convincing. Then:

```
true median      15.3 deg
shuffled median  15.2 deg   (338 of 400 random pairings BEAT the true pairing)
```

The cause: after excluding sky, **98% of measured hues land in a 10–50° band**
(IQR 14–20°), so the measurement is effectively a constant. Correlation with
manifest hue is **0.020**. Restricting to the dominant layer did not help
(331/400 shuffles still won).

Three measurement traps found on the way, each of which produced a confident
wrong number:

1. A **global backdrop** measures the *rig*, not the effect — the grey plate and
   camera move between effects, so every effect read as sky (~200°).
2. **Per-segment temporal medians** are degenerate when segments are as short as
   two frames.
3. What actually isolates the effect: identify the backdrop **by colour** — the
   frame's left/right 12% margins are clean, so their median hue is the sky's,
   measured per frame; drop coloured pixels sharing it, keep achromatic ones
   (grey smoke and dust are real effects).

Even done correctly, the result is a null. Reported here so nobody repeats it.

## 7. Method: reading burned-in text without an OCR engine

Generally reusable. The video renders each effect's name in a fixed,
evenly-pitched font.

1. Threshold the name band — the text is the brightest thing in it.
2. Reject fire/sparks that also cross the threshold by **fitting the type's
   pitch lattice** and keeping only boxes that land on it. (Keeping a contiguous
   *run* fails: underscores sit below the row band and open double gaps.)
3. Then — the part that makes it work — **score every known candidate name
   against the glyph bitmaps**, rather than decoding to text and fuzzy-matching.
   Free decoding confuses F/E, p/c, n/m and w/v at 960px and the errors compound
   into an unmatchable string. Scoring hypotheses asks the only question that
   matters: does this glyph look more like the `F` this candidate needs, or the
   `E` that one does? Every hypothesis is a real name, so the output can never
   be invented.
4. Alignment DP (insertions/deletions) absorbs a stray spark adding a glyph.

Result: 241/533 segments resolved to 122 distinct effects, with **238 of 240
adjacent pairs in correct case-insensitive alphabetical order** — an independent
consistency check, since the video is alphabetical.
