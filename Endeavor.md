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

### B5. Reuse a persistent thread pool — *medium*
`compute_*_parallel` calls `thread.create_and_start_…` + `join` + `destroy`
**every invocation** (`compute_parallel.odin:42-57, 83-103`) — ~50 µs of
spawn/teardown per call. A package-level pool of parked workers fed via a queue
amortises that to ~zero and makes small/medium parallel calls worthwhile (the
current `PARALLEL_MIN_LENGTH` cutoff exists precisely because spawning is
expensive). Compatible; purely an implementation change.

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

### C1. German-style ("Umbra") short-string inlining — *very high*
Replace the `[offsets:i32][bytes:u8]` Utf8 layout with a 16-byte-per-string
struct: `{ len:u32, prefix:[4]u8, ptr_or_inline:… }`. Strings ≤12 bytes live
**entirely inline** (no offset indirection, no second buffer, no pointer chase);
longer ones keep a prefix for fast comparison plus a pointer. This collapses the
two cache misses per element (offset, then bytes) into one sequential stream and
makes equality/`<`/prefix-filter checks branch-light. String-heavy workloads
(scan, filter, sort, join keys) improve dramatically. Cost: not Arrow-layout, so
IPC read/write must transcode.

### C2. Selection vectors instead of materialising filter/take — *very high*
`compute_filter`/`compute_take` currently allocate and copy a new contiguous
array. A vectorised engine instead returns a **selection vector** (a list of
surviving indices, or a retained validity mask) and defers materialisation,
letting later kernels operate through the selection. A filter that keeps 5% of
rows then does almost no copying. Breaks the "kernel returns a dense Array"
contract — needs a `Selection` type and selection-aware kernels.

### C3. Operator fusion / data-centric compilation — *very high, hard*
Today `filter(...)` then `sum(...)` materialises the filtered array in between.
Fusing the pipeline (`sum_where(values, mask)`) — or generating fused code per
query — removes the intermediate buffer and a full extra pass over memory. The
largest available win and the hardest; the natural endpoint once B/C2 exist.

### C4. Encoding-aware kernels (dictionary / RLE) — *high*
Store low-cardinality columns dictionary-encoded and run aggregates/group-bys on
the **codes** (e.g. sum over RLE runs, group-by on dictionary indices) without
decoding. Arrow has dictionary *arrays* but OdinArrow's kernels don't exploit
them; making the kernels first-class encoding-aware is where the speedups are.

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
1. **A1–A4** (reader hardening behind a `trusted` flag) — correctness/safety
   before any of this is pointed at real files.
2. **B5** (persistent thread pool) — compatible; removes ~50 µs/call spawn cost
   and makes small/medium parallel calls worthwhile.
3. **B4** (SIMD filter/take), **B3** (wider SIMD coverage) — filter/take are not
   purely bandwidth-bound (branchy / scatter-gather), so vectorising them should
   pay off where the reductions didn't.
4. **C2 → C4 → C1 → C3** — the structural changes that cut memory traffic and
   move OdinArrow from "matches Arrow C++" to "beats it," in increasing effort.
   These (selection vectors, encoding-aware kernels, fusion) attack the actual
   bottleneck the experiments surfaced: bytes moved, not vector width.
5. **B1, narrowed** — runtime CPU dispatch only for kernels proven to be
   compute-bound (small/in-cache or post-fusion), and only after fixing the
   `_sum_i32_simd` AVX2 regression so a wide path never loses to the narrow one.
