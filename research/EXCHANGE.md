# Research exchange

This folder is a two-way drop for BF6 reverse-engineering findings, so the same
things don't get re-derived independently.

## How to consume it

Scrape **`findings.json`**, not the prose. One entry per finding:

```json
{"id": "...", "title": "...", "date": "...", "status": "verified|probable|retracted",
 "tags": [...], "file": "research/....md", "summary": "...", "data": "optional/path.json"}
```

`status` is the field that matters. **`retracted` means we published it and it
turned out to be WRONG** — those entries stay so nobody rebuilds on them. Diff
`findings.json` between commits to see what is new or has changed status.

`summary` is written to stand alone: it should be enough to know whether the
finding affects you without opening the file.

## How to contribute

Two workflows, either is fine:

- **Push directly** — say the word and you get write access. Put your notes in
  `research/from-<your-handle>/` and add your entries to `findings.json`. That
  folder is yours; we won't edit it.
- **Fork and PR** — same layout, no access needed.

Only rule: **if you add a doc, add its `findings.json` entry**, otherwise it is
invisible to anyone scraping.

## What belongs here, and what does not

**Yes:** format specs, field/type hashes, layout tables, decode methods,
parameter name tables, negative results.

**A negative result is worth as much as a positive one here.** Two of the
entries in `findings.json` exist purely to stop someone spending a day the way
we did.

**No:** extracted game assets, textures, meshes, or bulk dumps of game content —
notes and derived tables only. Also no machine-local index files: our
`meshset_index.json` and `pf_blueprint_index.json` are just absolute paths into
one person's dump and are useless (and leaky) elsewhere.

## Attribution

Findings that came from someone else's work say so in the doc. **Third-party
documents are linked and credited, not re-hosted here** unless their author has
said they want them mirrored. If you'd rather your notes lived in this repo
directly, that's your call to make, not ours.

## Method conventions

Two habits that have repeatedly caught bad findings, and which the entries here
follow:

1. **Control runs.** When naming hashes from a dictionary, run the same search
   against the same number of *fake* ids. A method that names 76% of real keys
   and 72% of fake ones has found nothing. Report both numbers.
2. **Shuffled pairings.** When claiming two datasets agree, re-score with the
   pairing shuffled. If random pairings score as well, the agreement is an
   artifact of the metric. This killed a result of ours that looked convincing.
