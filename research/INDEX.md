# BF6 research notes

Reverse-engineering findings about Battlefield 6's asset formats, published so
they can be shared and built on instead of independently re-derived.

**Scrape [`findings.json`](findings.json)** — it is the machine-readable index
(id, date, status, tags, file, standalone summary). See
[`EXCHANGE.md`](EXCHANGE.md) for how to contribute and what belongs here.

`status: retracted` marks things we published that turned out to be **wrong**.
They stay listed on purpose.

## Documents

| file | covers |
|---|---|
| [`fx-emitter-params.md`](fx-emitter-params.md) | `EmitterGraphParams` field + element layout, PropertyId namespace and 68 recovered names, the `fx_*` → `eg_*` layer model, why FX colour is **not** in the tint parameters, and a null result on video-based colour validation |
| [`pipeline-performance.md`](pipeline-performance.md) | Three loop-invariant rebuilds that cost a 12.6× slowdown — including a MeshSet lookup that walked the entire bundles tree once per mesh (~6s each) |
| [`data/fx_property_ids.json`](data/fx_property_ids.json) | The 68 named FX PropertyIds (0 false positives against a control run) |

## Two findings worth reading even if you skip the rest

**FX colour lives in the texture, not the tint.** 79% of all tint parameters
across 471 effects are near-grey; 85% of dominant-layer tints are pure white.
Previews that colour effects from `color0` / `randomcolormin` cannot match the
game.

**Run controls before believing an agreement number.** A hue-agreement result of
15.3° median error looked strong until a shuffled pairing scored 15.2° and beat
it 338 times out of 400. Separately, a hash-naming method that named 76.2% of
real ids also named 71.9% of fake ones. Both look like signal; neither is.
