# Pipeline performance — three cached indexes, 12.6x

Written 2026-08-01, during the full model rebuild against the fresh pull.

Three separate stages were each re-deriving the same loop-invariant data. All
three are now cached. The rebuild went from **~22 hours to under an hour**, and
the box finally saturates (30% CPU -> 92%).

**None of this changed what gets built** — every fix was verified to produce the
identical result before being kept.

---

## 0. The rule these all break

> Anything derived from the dump, the guid index, or the type DB is a **loop
> invariant**. If it is computed inside a per-file or per-mesh loop, it is a bug,
> and the cost is invisible because the code looks correct.

Symptom to watch for: **a process pegged at 100% CPU with almost no disk I/O**,
or the opposite — many workers, low total CPU, more time in the kernel than in
user code. Both mean "not doing the work you think it is doing".

Diagnose with `py-spy dump --pid <pid> --nonblocking`. It attaches to a running
process without stopping it and prints the Python stack — it found all three of
these in minutes, after 8.5 hours of guessing. **Reach for it first.**

---

## 1. `mvdb_v2.resolve_variations` — 2.03 s/file of pure waste

`build_variation_db.py` sat at 100% CPU for **8.5 hours** having produced no
output. `py-spy` showed it inside `os.path.basename`, called from
`_ov_hash_table`, called from `resolve_variations`.

```python
ovmap = _ov_hash_table(gi)     # walks the ENTIRE 449,738-entry guid index
ti = _TexIndex(gi)             # walks it again
```

Both are called **once per MeshVariationDatabase**, and `gi` never changes.

| | cost |
|---|---|
| `_ov_hash_table(gi)` | 0.94 s |
| `_TexIndex(gi)` | 1.09 s |
| **per MVDB** | **2.03 s** |
| x 17,079 MVDBs | **9.6 hours** |
| actual parse work per MVDB | ~0.00 s |

So ~100% of the runtime was rebuilding identical tables. Memoized on the
identity+length of the index that produced them (`_OV_CACHE` / `_TEX_CACHE` in
`mvdb_v2.py`); warm lookup is 0.0000 s. Verified `cached == freshly computed`
for both before keeping it. Stage now completes in about two minutes.

## 2. `Assembler.__init__` — the blueprint index, per worker

Every assembly worker independently ran six recursive globs over
`dump/bundles` to build the same 23,053-entry blueprint map.

Cached to **`data/pf_blueprint_index.json`** (35.9 s to build once). Workers now
print `blueprints indexed: 23053 (cached)` and start immediately.

## 3. `build_multimat.find_meshset` — the real wall

This was the expensive one, and it hid behind the other two.

```python
def find_meshset(name):
    for m in glob.glob(os.path.join(DUMP, "bundles", "**", name + "_mesh.MeshSet"),
                       recursive=True):
        return m
    ...                                    # a MISS costs two full tree walks
```

A full recursive walk of the bundles tree **per mesh, per proxy**. Measured
directly: **~6.0–7.1 seconds per lookup.**

That is why throwing cores at it did nothing — the workers were never
CPU-starved, they were all enumerating the same directory tree:

| configuration | rate | CPU |
|---|---|---|
| 1 worker | 11.9/min | — |
| 14 workers | 29.1/min | 33% |
| 24 workers | 27.2/min | 30% |
| **24 workers + MeshSet index** | **342.4/min** | **92%** |

Cached to **`data/meshset_index.json`** — 34,599 MeshSets in **5.3 s**.

Correctness was checked rather than assumed: the index walks with `dirs.sort()`
/ `files.sort()` and `setdefault`, matching the old glob's "first match wins"
ordering, and a random sample was re-resolved through the **original glob** and
compared. **8/8 identical paths.**

---

## 4. Cache invalidation — READ THIS AFTER A FRESH PULL

All three caches key off the dump. A stale cache will silently assemble from
**paths in the old dump** — no error, wrong geometry.

| cache | invalidate with |
|---|---|
| `data/pf_blueprint_index.json` | delete, or `BF6_PFIDX=0` |
| `data/meshset_index.json` | delete, or `BF6_MSIDX=0` |
| `mvdb_v2` in-process memo | per-process, nothing to do |

Rebuild both explicitly with `python tools/build_pfidx.py` and
`python tools/build_msidx.py` (the latter also re-verifies against the glob).

**Add this to the post-pull checklist**, next to regenerating `guid_index.tsv`.

---

## 5. Sharding the assembly

`assemble_parallel.ps1` splits `godot_proxy_names.txt` across N workers.

- **Shard the REMAINING work, not the original list.** `--skip-existing` alone
  is not enough: on a relaunch one worker gets a shard that is entirely built
  and exits in seconds while another does a full share, so the run is as slow as
  the unluckiest shard. The script filters already-built proxies out first.
- **Contiguous chunks, not round-robin.** The `Assembler` keeps a `mesh_cache`
  across proxies within a process and neighbouring proxies share meshes.
- Every proxy writes its own `<Proxy>/<Proxy>.glb`, so there is no shared output
  to contend on, and `--skip-existing` makes the whole thing resumable.

Worker count is not the lever it appears to be — fix the per-item cost first.
With the indexes in place 24 workers saturate the machine at 92%.

## 6. Watching a long run

`A:\bf6pull\progress_server.py` serves a live page on **http://localhost:8790**.

Counting metric, after two wrong attempts:

- Counting **GLBs on disk** undercounts — a rejected proxy never writes a file,
  so the bar creeps to ~98% and freezes with nothing wrong.
- Counting **log "attempts"** breaks across relaunches, because pre-filtering
  means already-built proxies never appear in any log again.
- What works: **GLBs on disk + rejected**, which reaches the total and survives
  a restart of either the server or the workers.

Two harness traps worth remembering, both of which cost real time here:

- `& $py script.py | Select-Object -Last 5` **buffers the entire stream** until
  the process exits. A stage printing progress every 100 items looked dead for
  8.5 hours. Stream to the log instead.
- Piping a launcher script through `Select-Object -First N` terminates the
  upstream pipeline — it killed the launcher after spawning 4 of 24 workers.
