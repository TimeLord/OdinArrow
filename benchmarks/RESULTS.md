# OdinArrow Benchmark Analysis

Head-to-head comparison of **OdinArrow** against **PyArrow** (Python) and
**Apache Arrow C++** (the same LLVM-compiled library PyArrow wraps, called
directly through its C/C++ API — the "FFI" reference).

## Environment

| | |
|---|---|
| CPU | Intel Core i7-7700HQ @ 2.80 GHz (4 cores / 8 threads) |
| Arrow / PyArrow | bundled libarrow 24.00 |
| Odin | nightly, `-o:speed` |
| Timing | `time.tick_now` / `perf_counter_ns` / `steady_clock`, **median of 5 trials** |
| Workload | 10M elements (numeric), 1M elements (strings) |

Reproduce with `bash benchmarks/compare.sh`.

## Methodology note (read this before the table)

OdinArrow's `sum`, `min/max`, and `filter` run **multi-threaded across all 8
hardware threads**; PyArrow and Arrow C++ here are **single-threaded**. So those
four ratios reflect *OdinArrow's threading + per-core efficiency together*, not
pure per-core speed. The other four rows — array build, string build, string
scan, IPC roundtrip — are **single-threaded on all three**, so they are
apples-to-apples.

## Results

| Benchmark | Threading | OdinArrow (ms) | PyArrow (ms) | Arrow C++ (ms) | Py/Odin | C++/Odin |
|---|---|---:|---:|---:|---:|---:|
| Build 10M i32 (1% nulls) | all single | 83.15 | 1005.55 | 40.06 | 12.09× | 0.48× |
| Sum 10M f64 | Odin MT | 3.05 | 5.84 | 6.55 | 1.92× | 2.15× |
| Sum 10M i32 | Odin MT | 1.79 | 2.91 | 2.52 | 1.62× | 1.40× |
| Min+Max 10M i32 | Odin MT | 1.87 | 4.33 | 2.58 | 2.32× | 1.38× |
| Filter 10M i32 (50% pass) | Odin MT | 10.08 | 39.39 | 37.55 | 3.91× | 3.73× |
| Build 1M strings (2% nulls) | all single | 21.48 | 95.92 | 8.01 | 4.47× | 0.37× |
| Scan 1M strings | all single | 0.78 | 9.21 | 9.15 | 11.74× | 11.67× |
| IPC roundtrip 10M i32 (w+r) | all single | 20.78 | 10.66 | 10.85 | 0.51× | 0.52× |

Ratios > 1× mean OdinArrow is faster; < 1× mean it is slower.

## Per-benchmark analysis

### Array build — 10M i32 (Odin 0.48× C++, 12× Python)
OdinArrow's raw-buffer builder (direct indexed writes, lazy validity bitmap)
beats PyArrow by ~12×, but that gap is mostly **Python-side overhead**: PyArrow's
1005 ms is dominated by materialising a 10M-element Python list before Arrow ever
sees it, not by Arrow itself. Against Arrow C++ — the honest comparison —
OdinArrow is **~2× slower**. Arrow C++'s `Int32Builder` does bulk capacity
reservation and branch-light appends that still edge out the per-element path.
This is the clearest remaining single-threaded optimization target.

### Sum f64 / i32 (Odin 1.9–2.2× C++, threaded)
Multi-accumulator SIMD kernels fanned across 8 threads. On a 4-core machine the
realistic threading ceiling is ~4× before memory bandwidth saturates; sum is
memory-bound, so the observed ~2× over single-threaded C++ is bandwidth-limited
rather than compute-limited. Per-core, OdinArrow's SIMD sum is roughly on par
with Arrow C++.

### Min+Max — 10M i32 (Odin 1.4× C++, threaded)
Single-pass combined min+max, SIMD + threaded. The smaller margin over C++ vs
`sum` reflects that Arrow's `MinMax` is already well tuned and the kernel is
even more bandwidth-bound.

### Filter — 10M i32, 50% pass (Odin 3.7× C++, threaded)
The largest threaded win. OdinArrow's filter exact-sizes the output via bitmap
popcount, then runs a byte-at-a-time mask loop, parallelised. Filtering writes a
full output array, so it scales better with threads than the reductions do.
Even discounting threading (~4× headroom), the per-core path is competitive.

### String build — 1M strings (Odin 0.37× C++, 4.5× Python)
Same story as numeric build: ~4.5× faster than PyArrow (Python list + object
overhead), but **~2.7× slower than Arrow C++**, whose `StringBuilder` has highly
tuned bulk offset/byte appends. Second-clearest optimization target.

### String scan — 1M strings (Odin ~11.7× both)
OdinArrow walks the offsets buffer in a tight loop summing lengths. PyArrow and
Arrow C++ both pay **compute-kernel dispatch overhead** (`utf8_length` →
`sum`) for what is a trivial pointer walk, which is why both land near 9 ms.
This is partly an artifact of comparing a hand loop against a generic kernel
pipeline — but it does show OdinArrow's zero-dispatch model paying off.

### IPC roundtrip — write+read 10M i32 (Odin 0.51× both)
**The one area OdinArrow trails both.** Write is competitive (~5 ms); the gap is
on **read**. OdinArrow reads the whole 40 MB file eagerly (`os.read_entire_file`)
and then exposes columns as zero-copy views into it. PyArrow and Arrow C++
**memory-map** the file, so the 40 MB never actually streams through a read
syscall — pages fault in lazily and this benchmark only touches one element.
Closing this needs an mmap-backed reader (see "future work").

## Takeaways

- **vs PyArrow:** OdinArrow is faster on every benchmark except IPC roundtrip,
  by 1.6×–12×. Much of the large wins (build, string build) is Python interpreter
  overhead rather than Arrow itself, but the systems-language model removes that
  overhead by construction.
- **vs Arrow C++ (the real bar):**
  - **Wins** on the threaded reductions/filter (1.4×–3.7×) — largely from using
    all cores; per-core it is competitive, not dominant.
  - **Wins big** on string scan (~12×), mostly because the C++ side goes through
    a generic compute kernel for a trivial operation.
  - **Trails** on single-threaded *construction* (array build ~2×, string build
    ~2.7×) and on **IPC read** (~2×, eager read vs mmap).
- The honest summary matches the plan's stated goal: a zero-overhead systems
  language **matches or beats a Python-wrapped C++ library**, with much simpler,
  more auditable code — while Arrow C++ still leads on its most tuned hot paths
  (builders, mmap'd IO).

## Future work surfaced by these numbers

1. **Builder construction parity** — bulk/branch-light append paths to close the
   ~2× gap to Arrow C++ on array and string build.
2. **mmap-backed IPC reader** — to remove the eager 40 MB read and reach C++/
   PyArrow IPC read latency.
3. **End-to-end Large\* support** — make the IPC layer i64-offset-aware so
   LargeString/LargeBinary columns round-trip (tracked separately).
