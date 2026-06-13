# Endeavor — surpassing the reference implementation

A review of OdinArrow with two goals: (1) harden the parts that parse untrusted
input, and (2) lay out performance work — both Arrow-compatible and
compatibility-breaking — that could make OdinArrow faster than Apache Arrow's
own C++ kernels on the operations that matter.

Each item notes **impact**, **effort**, and whether it **breaks Arrow
compatibility**. File/function references point at the code as it stands today.

---

## A. Security — the IPC reader is an untrusted-input parser

`ipc_read_file` / `ipc_read_stream` (`src/ipc.odin`) decode attacker-controllable
bytes: FlatBuffer table/vtable offsets, vector counts, and Arrow buffer
offsets/lengths. The decoder currently **trusts** almost all of them. Odin's
default bounds checks turn most of these into a panic (a denial-of-service)
rather than memory corruption — but the moment the package is built with
`-no-bounds-check` (tempting for a numeric library), several become genuine
out-of-bounds reads. The string-offset case is unsafe even **with** bounds
checks.

### A1. Unvalidated FlatBuffer offsets → OOB read / panic — *high*
`_rd_i32/_rd_i16/_rd_i64/_rd_u32` index `data[pos..]` with no check that `pos`
is in range. Inputs flow straight from the file: `root_off := _rd_u32(meta, 0)`
then `_rd_i32(meta, tbl)`; `vt := tbl - int(soff)` can go **negative**
(`_ipc_decode_record_batch`, `_ipc_read_field`, footer parsing). A crafted
root/soffset reads out of bounds.
*Fix:* a checked reader (`_rd_i32_safe(data, pos) -> (v, ok)`) that verifies
`0 <= pos && pos+size <= len(data)`, threaded through every decode path; treat
any failure as "malformed file → return ok=false".

### A2. Unvalidated vector counts → resource exhaustion / OOB — *high*
`n_nodes`, `n_bufs`, the fields-vector count, and footer `n_blocks` are read as
`int(_rd_u32(...))` and used directly as loop bounds and `make([dynamic], n)`
hints. A count of `0xFFFFFFFF` either allocates aggressively or walks off the
buffer.
*Fix:* reject counts that can't fit in the remaining bytes
(`n * stride <= remaining`) before looping.

### A3. Integer overflow bypasses the body bounds check — *high*
Buffer extents are computed with unchecked arithmetic — `(col_len + 1) *
size_of(i32)`, `nv + 4 + i*16`, `body_start + blk_body` — where `col_len`/offsets
come from the file as `i64`. A large value overflows `int`, producing a small or
negative length that **passes** the `off+length > len(body)` guard in
`_ipc_view_buffer`, after which a column views memory outside the body.
*Fix:* use width-checked multiply/add (saturating to "invalid") for every
size/offset derived from file data.

### A4. Offset buffers are never validated → memory disclosure — *high, subtle*
For variable-length columns the decoder hands the file's offset buffer to the
Array verbatim. `array_get_string` then does
`arr.buffers[2].data[start:end]` where `start/end` are read from that offset
buffer. `buffers[2].data` is a **multi-pointer** (`[^]u8`), and slicing a
multi-pointer is **not bounds-checked** — so non-monotonic or out-of-range
offsets read (and return as a string) arbitrary adjacent memory. This is
exploitable even in a normal bounds-checked build.
*Fix:* an opt-in `ipc_validate` pass (mirroring Arrow's `ValidateFull`):
offsets are monotonically non-decreasing, `offsets[0] == 0`, and
`offsets[length] == data_buffer_len`. Make the safe path the default for files
from untrusted sources.

### A5. mmap lifetime / concurrent truncation → SIGBUS — *low*
A memory-mapped file truncated by another process faults (SIGBUS) on access of
the vanished pages. Document that mmap'd reads assume a stable file, and offer a
"copy" read mode for hostile environments.

> **Suggested shape:** add a `IPC_Read_Options{ trusted: bool }`. `trusted`
> (default for self-produced files) keeps today's fast path; untrusted runs the
> checked readers (A1–A3) and `ipc_validate` (A4). None of this changes the wire
> format, so it's purely additive.

---

## B. Performance — compatible (keep full Arrow interop)

### B1. Build with an actual SIMD target — *investigated: no win here (memory-bound)*
Builds use `-o:speed` only (no `-microarch:`), so codegen targets the baseline
x86-64 (SSE2, 128-bit); the 256-bit `#simd[4]f64` and the AVX2 min/max patterns
in `compute_simd.odin` are split to 128-bit. The hypothesis was that
`-microarch:native` would widen these for free.

**Measured (i7-7700HQ, interleaved median-of-5, threaded kernels):**

| kernel | baseline (SSE2) | `-microarch:native` (AVX2) |
|---|---:|---:|
| sum 10M f64   | ~3.13 ms | ~3.15 ms (flat) |
| sum 10M i32   | ~2.0 ms  | **~4.9 ms (2.5× slower)** |
| min+max 10M i32 | ~1.95 ms | ~1.93 ms (flat) |
| filter 10M i32  | ~11.5 ms | ~11.5 ms (flat) |

So at 10M elements the threaded reductions are **memory-bandwidth-bound**, not
compute-bound — eight cores already saturate DRAM, so a wider vector adds
nothing. Worse, AVX2 codegen for the i32→i64 widening sum is a regression
(likely the sign-extend/accumulate sequence and/or AVX frequency licensing on
this µarch). Enabling `-microarch:native` was therefore **reverted** — it
regresses the suite and helps nothing measurable.

**Revised conclusion:** SIMD width is not the lever for large-array aggregation;
**reducing memory traffic is.** That redirects the effort to B2 (don't make extra
passes for null handling), C3 (fuse pipelines so the data is read once), and C4
(operate on compressed/encoded data so there are fewer bytes to move). A
narrower, still-real B1 remains for the *compute-bound, in-cache* regime
(small/medium arrays, or fused kernels that are no longer DRAM-limited): there,
per-element SIMD width does matter, and **runtime CPU dispatch** (detect AVX2/
AVX-512 once, pick the widest kernel) is worth it — but only after a kernel is
demonstrably not bandwidth-limited. The i32-sum AVX2 regression should be fixed
(rewrite `_sum_i32_simd` with explicit `#simd` widening) before any dispatch so
the wide path is never slower than the narrow one.

### B2. Null-aware bulk aggregation — ✅ *done*
~~The null path of `_sum_typed`/`_min_typed`/`_max_typed` is a per-element
`array_is_valid` branch.~~ Implemented: the null path now walks the validity
bitmap a **byte at a time** — an all-valid byte (`0xFF`) is coalesced into a run
and reduced with the SIMD kernel; all-null bytes are skipped; only mixed bytes
fall back to bit testing (`_sum_run`/`_min_run`/`_max_run`/`_min_max_run` in
`compute.odin`). Parallel chunk boundaries are rounded to multiples of 8 so the
bulk path (which needs `offset % 8 == 0`) stays active inside every worker.

**Measured (i7-7700HQ):**
- Null overhead on the 10M f64 sum dropped to **+9%** (3.18 → 3.48 ms) vs Arrow
  C++'s **+42%** (6.01 → 8.54 ms) and PyArrow's +21% — so the threaded null-sum
  is ~2.4× faster than both.
- **Cache-resident** null-sum (1.6 MB, tight loop): **245 µs → 75 µs/call (3.3×)**.

The end-to-end gain at 10M is "only" ~13% because that case is DRAM-bound (the
B1 lesson); the 3.3× shows up once the data fits in cache and the per-element
branch is no longer hidden behind memory latency. **Next:** extend the same
byte-coalescing to `compute_mean` is automatic (it calls sum), but the *mask*
kernels (filter/take) still branch per element — see B4. A future refinement is
moving from byte (8-wide) to `u64` word (64-wide) coalescing for even longer
all-valid runs.

### B3. Widen SIMD coverage — *medium*
Only `f64` and `i32` have hand-written SIMD; `f32`, `i64`, `i16`, and the
unsigned types fall back to scalar loops that may or may not auto-vectorise.
`f32` sum in particular wants an 8-wide `#simd[8]f32`. Generic-over-`T` SIMD
helpers would cover the lot.

### B4. SIMD filter / take — *high*
`_filter_typed` is byte-at-a-time bit testing (`compute.odin`). Replace with a
vectorised compress: AVX-512 `vpcompressd`, or on AVX2 a per-mask-byte shuffle
table (256-entry LUT) to pack matching lanes. `compute_take` likewise wants a
SIMD gather (`vpgatherdd`). These are the kernels where vectorised engines pull
furthest ahead of scalar code.

### B5. Reuse a persistent thread pool — ✅ *done*
~~`compute_*_parallel` spawns + joins + destroys threads every invocation.~~
Implemented (`thread_pool.odin`): a process-lifetime pool of parked workers
woken by a condition-variable broadcast (one partition per worker, barrier on
completion); a submit mutex serialises whole jobs so concurrent callers (the
multi-threaded test runner) take the pool in turn; pool allocations use the raw
heap so the singleton never trips a tracking allocator.

**Measured:** per-call parallel overhead **95 µs → 60 µs (~36%)** on a 300 K
sum loop. But a second measurement reset expectations: parallel only beats
serial **above ~256 K** (256 K → 1.45×, 512 K → 1.95×; 32–128 K parallel is
*slower*). So at the margin the cost is **thread wakeup + barrier latency**
(~15–25 µs to fan out to 8 cores and rejoin), not spawn — which means
`PARALLEL_MIN_LENGTH` (262 144) is already well-placed and was **kept**. The pool
still wins for workloads that make many parallel calls (the spawn churn is gone)
and is the right foundation, but it does *not* let the cutoff drop. Headline 10M
numbers are unchanged (work ≫ overhead there). Same recurring lesson as B1/B2:
the bottleneck is rarely the thing you'd guess — measure it.

### B6. Inlining + prefetch in scans — *low/medium*
`builder_append` is a normal (non-`#force_inline`) proc on the hot construction
path; mark it (and the string append) `#force_inline`. For large sequential
scans (`string_scan`, gather) a software prefetch of the offset/value stream a
few iterations ahead hides memory latency.

---

## C. Performance — at the expense of compatibility (the path to "superior")

These break the Arrow in-memory/wire contract, so they'd live behind a
conversion boundary (convert to/from Arrow at IPC edges) — but they're how
DuckDB / Velox / Umbra beat textbook Arrow kernels.

### C1. German-style ("Umbra") short-string inlining — ✅ *done*
Implemented (`umbra.odin`): a 16-byte slot `{ length:u32, data:[12]u8 }` —
inline for length ≤ 12, 4-byte prefix + side-buffer offset otherwise — with a
builder, zero-copy accessor, a prefix-fast-path `umbra_compare`, `umbra_count_eq`,
and `umbra_sort_indices`. The prefix lives in the slot, so comparisons resolve in
registers without chasing into the data buffer.

**Measured:** sorting 1M ~20-char strings — Umbra **272 ms** vs OdinArrow's
Arrow-layout sort **518 ms (1.9×)** and PyArrow's `pc.sort_indices` **415 ms
(1.5×)**, identical ordering. Cost: ~30% more memory (fixed 16-byte slots). A
smaller-but-real win than C4 because the data access during a sort, while
random, still hits a warm-ish buffer; the prefix mainly saves the compare itself.

*Still open under C1:* SIMD/bulk equality + range filters over the prefix
column, join-key hashing on the inline bytes, and a transcoder to/from Arrow Utf8
at the IPC boundary.

### C2. Selection vectors instead of materialising filter/take — ✅ *done*
Implemented (`selection.odin`): `Selection` (surviving row indices),
`compute_select(mask)`, `compute_sum_selection` (aggregate through a selection),
`selection_take` (materialise one column lazily), and `record_batch_take` (the
eager batch materialisation, for comparison).

**Measured:** filtering a 4-column batch (10% pass) and summing 2 columns —
**13.2 ms** keeping a selection and gathering only those 2 columns, vs **43.7 ms**
materialising the whole filtered batch first (**3.3×**). As predicted, the win is
multi-column: the selection never copies the 2 unused columns or allocates a
batch. (A single filter→aggregate is a wash — that case is better served by C3.)

**Chained predicates — ✅ done** (`compare.odin`): `compute_compare`,
`compute_select_compare` (first predicate → selection, single pass) and
`selection_refine_compare` (AND another predicate, evaluated only at the
surviving rows). `WHERE c0..c3 > 50 SUM(pay)` on 10M: **2.24×** (89.5 vs
200.8 ms) at 4 predicates — but a *2-predicate* query is a wash (first 10M scan
dominates, and PyArrow's SIMD compares are faster there). The win **grows with
the number of conjuncts**, since materialise-between re-copies every carried
column per predicate while the selection just shrinks an index list.

**Vectorisable compares — ✅ done.** The comparison is now monomorphised on the
operator (comptime `$OP`), so the inner loop is a single branchless vectorisable
compare instead of a runtime `op` switch. The 2-predicate chained query went
33 → **21 ms, now faster than PyArrow** (25.1 ms) where it had been losing.
(`-microarch:native` regresses it — B1 again — so baseline stands.)

*Still open:* a SIMD compress for `compute_select` (the index collection is still
scalar), and selection-aware take for all types.

### C3. Operator fusion — ✅ *hand-fused kernels done* (general codegen still open)
Implemented (`compute_fused.odin`): `compute_sum_where(values, mask)` and
`compute_count_where` — filter+aggregate in a single pass with no intermediate
array. **Measured:** `sum_where` **7.6 ms** vs `filter` then `sum` **34.2 ms
(4.5×)**, and **5.5×** faster than PyArrow's `sum(filter(...))` (41.6 ms) — the
intermediate array's allocation, dense copy, and re-read are all eliminated.

**General fusion — ✅ done** (`fusion.odin`): `compute_agg_where_compare`
computes sum/count/min/max in one pass under a predicate, no mask or filtered
array. The "codegen" is Odin's **monomorphisation** — one generic driver
parameterised on the value type and a comptime `$OP` is specialised by the
compiler into a tight fused kernel per combination, which is the compile-time
equivalent of a query engine generating the loop at runtime.
`SELECT sum,count,min,max WHERE pred>50` on 10M: fused **16.8 ms** vs unfused
27.6 ms (1.64×) and PyArrow 70.2 ms (**4.2×**).

*Still open:* fusing multi-predicate conjunctions and predicate-on-a-different-
type-than-values into the same driver (currently same-type), and a small
expression layer that builds these fused plans from a query description.

### C4. Encoding-aware kernels (dictionary / RLE) — ✅ *run-end encoding done*
Run aggregates over the **encoded** form instead of decoding first. Implemented
(`rle.odin`): `RLE_Array(T)` (run_ends + per-run values), a coalescing builder,
`rle_encode`/`rle_decode`, and `rle_sum`/`rle_min_max` that run in **O(runs)**.

**Measured (10M f64, 10K runs, single-thread):** `rle_sum` 11.8 µs vs OdinArrow's
plain sum 4541 µs (**385×**) and PyArrow's `pc.sum` 6045 µs (**510×**), on
**667× less memory** (117 KB vs 78 MB). PyArrow has **no** REE sum kernel at all
(`pc.sum` rejects `run_end_encoded`), so this is something the reference cannot
do — the clearest "superior to the original" win so far, and a direct payoff of
the move-fewer-bytes thesis.

**Dictionary encoding — ✅ done** (`dict.odin`): `Str_Dict_Array` (a string
dictionary + i32 codes), `str_dict_value_counts` (an integer histogram over the
codes) and `str_dict_group_sum` (grouped aggregation). `value_counts` on 10M
strings / 100 distinct: **6.6 ms** vs PyArrow **190 ms** plain (29×) and **62.6
ms** even on a dictionary array (9.5×) — the codes are the group ids, so there is
no string hashing. Encode is a one-time 196 ms, amortised when the column arrives
encoded from storage.

**Generic numeric dictionary — ✅ done** (`Dict_Array(T)` in `dict.odin`):
`dict_value_counts`, `dict_min_max`, `dict_sum`, encode/decode. `dict_min_max`
is **~126,000×** (O(n_dict): the column min/max is the tiny dictionary's). Honest
counter: `dict_sum` is 0.80× — the histogram increment is compute-bound and loses
to SIMD sum despite the narrower codes.

*Still open under C4:* REE with nulls (run-level validity) and multi-key group-by.

### C5. Drop the optional validity bitmap for declared non-null columns — *medium*
Arrow always allows a validity buffer. A type-system flag for "non-nullable"
columns lets every kernel skip null handling entirely (no B2 needed there) and
lets the builder skip bitmap bookkeeping. Minor layout divergence, broad small
wins.

### C6. Native, FlatBuffer-free container format — *medium*
The hand-rolled FlatBuffer encode/decode has real per-message cost and is the
A-section attack surface. A bespoke, directly-mmappable layout (fixed-offset
header, no offset-chasing metadata) would read/write faster and validate
trivially — at the price of needing a converter for Arrow interop. Keep Arrow
IPC as the interchange format; use the native one for OdinArrow-to-OdinArrow.

---

## Suggested ordering

Updated after the B1 and B2 measurements. B1 showed large-array aggregation is
bandwidth-bound (SIMD width is not the lever); B2 confirmed the flip side —
removing per-element work is a 3.3× win once a kernel is cache-resident rather
than DRAM-bound:

- ✅ **B2** (null-aware aggregation) — done; +9% null overhead, 3.3× in-cache.
- ✅ **B5** (persistent thread pool) — done; ~36% less per-call overhead (the
  cutoff stays — wakeup latency, not spawn, sets the margin).
1. **A1–A4** (reader hardening behind a `trusted` flag) — correctness/safety
   before any of this is pointed at real files.
2. **B4** (SIMD filter/take), **B3** (wider SIMD coverage) — filter/take are not
   purely bandwidth-bound (branchy / scatter-gather), so vectorising them should
   pay off where the reductions didn't.
3. **C-items** — the structural changes that cut memory traffic and move
   OdinArrow from "matches Arrow C++" to "beats it."
   - ✅ **C4 (run-end encoding)** — 385–510× on runny data; PyArrow can't do it.
   - ✅ **C4 (dictionary)** — value_counts 29× / 9.5× vs PyArrow (integer histogram).
   - ✅ **C1 (Umbra strings)** — 1.9× on string sort vs the Arrow layout.
   - ✅ **C3 (fusion)** — sum_where 4.5× over filter+sum, 5.5× over PyArrow.
   - ✅ **C2 (selection vectors)** — 3.3× on multi-column filter+aggregate.
   The structural C-items are in. What remains are *extensions* (generic numeric
   dictionary, REE/selection for all types, and the hard one — **general operator
   fusion via codegen** rather than hand-written `*_where` kernels).
   These attacked the bottleneck every experiment surfaced: bytes moved, not width.
4. **B1, narrowed** — runtime CPU dispatch only for kernels proven to be
   compute-bound (small/in-cache or post-fusion), and only after fixing the
   `_sum_i32_simd` AVX2 regression so a wide path never loses to the narrow one.

> Recurring theme across B1/B2/B5: the headline 10M kernels are **memory-bound**,
> so micro-optimisations (vector width, branch removal, spawn cost) only show up
> once the data is cache-resident or the call is small. The durable wins are the
> ones that **move fewer bytes** (C2/C3/C4), not the ones that compute faster.
