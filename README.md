# OdinArrow

A native [Apache Arrow](https://arrow.apache.org/) implementation in the
[Odin](https://odin-lang.org/) language — columnar in-memory format, compute
kernels, and the Arrow IPC format (Feather v2), with zero-overhead abstractions
and explicit memory management.

Files written by OdinArrow are readable directly by **PyArrow** and **Apache Arrow
C++**, and vice-versa.

We aim to be faster than the original - with our appreciation of what the Apache
Arrow project has accomplished.

## Highlights

- **Columnar memory** — 64-byte-aligned buffers, packed validity bitmaps,
  zero-copy slicing, the Arrow C Data Interface buffer layout.
- **Type system** — a tagged union of Arrow types (no vtables): Bool, Int8…64,
  UInt8…64, Float32/64, Utf8/Binary (i32 offsets), LargeUtf8/LargeBinary
  (i64 offsets), Null.
- **Builders** — raw-buffer, zero-copy `finish()`, lazy validity bitmaps, plus a
  reusable [`Buffer_Pool`](src/buffer_pool.odin) that recycles freed blocks.
- **Compute kernels** — `sum`, `min`/`max`, `mean`, `count`, `filter`, `take`,
  `cast`, element-wise arithmetic, and `sort_indices` (stable, nulls-last).
  SIMD paths for the numeric hot loops; multi-threaded `*_parallel` variants.
- **Arrow IPC** — file (random batch access) and stream (sequential) formats,
  **memory-mapped zero-copy reads**, hand-rolled FlatBuffers encoder/decoder,
  bidirectional PyArrow interop.

## Quick example

```odin
package main

import oa "odinarrow"
import "core:fmt"

main :: proc() {
    // Build a Float64 array (with one null).
    b := oa.builder_make(f64, 1024)
    for i in 0..<1000 { oa.builder_append(&b, f64(i)) }
    oa.builder_append_null(&b)
    arr, _ := oa.builder_finish(&b)      // zero-copy: buffers move into the Array
    oa.builder_destroy(&b)

    // Compute over it.
    total, valid := oa.compute_sum(&arr)
    fmt.printfln("sum=%.0f over %d non-null values", total, valid)

    // Wrap it in a schema + record batch and write a (pyarrow-readable) IPC file.
    schema, _ := oa.schema_make([]oa.Field{ oa.field_make("v", oa.Float64_Type{}) })
    defer oa.schema_free(&schema)
    batch, _ := oa.record_batch_make(&schema, []oa.Array{arr})  // batch now owns arr's buffers
    defer oa.record_batch_free(&batch)
    oa.ipc_write_file("data.arrow", &schema, []oa.Record_Batch{batch})

    // Read it back (zero-copy: columns are views into the mmap'd file).
    sc, batches, ok := oa.ipc_read_file("data.arrow")
    fmt.println("read ok:", ok, "batches:", len(batches))
    oa.schema_free(sc); free(sc)
    for bx in batches { bc := bx; oa.record_batch_free(&bc) }
    delete(batches)
}
```

Reading the same file in Python:

```python
import pyarrow.ipc as ipc
table = ipc.open_file("data.arrow").read_all()
```

## Benchmarks

OdinArrow vs **Apache Arrow C++** (the LLVM-compiled library PyArrow wraps,
called directly) — **both single-threaded**, so this is a true apples-to-apples
per-core comparison of OdinArrow's serial kernels against Arrow's. Median of 5
trials, 10M-element numeric / 1M-element string workloads, recycling memory pools
on both sides. `C++/Odin` is Arrow C++ time ÷ OdinArrow time; **> 1× means
OdinArrow is faster**.

| Benchmark                           | OdinArrow (ms) | Arrow C++ (ms) |  C++/Odin |
| ----------------------------------- | -------------: | -------------: | --------: |
| Build 10M i32 (1% nulls)            |          17.89 |          32.94 | **1.84×** |
| Build 1M strings (2% nulls)         |           5.10 |           6.41 | **1.26×** |
| Sum 10M f64                         |           4.12 |           6.14 | **1.49×** |
| Sum 10M f64 (1% nulls)              |           5.81 |           7.48 | **1.29×** |
| Min+Max 10M i32                     |           2.06 |           2.06 | **1.00×** |
| Mean 10M f64                        |           4.33 |           5.64 | **1.30×** |
| Filter 10M i32 (50% pass)           |           7.65 |          36.43 | **4.76×** |
| Filter 10M i32 (1% pass)            |           0.83 |           1.92 | **2.30×** |
| Take 10M i32 (1M indices)           |           8.97 |           9.30 | **1.04×** |
| Sort indices 1M i32                 |          32.42 |         124.36 | **3.84×** |
| Cast 10M i32 → f64                  |           4.48 |           7.85 | **1.75×** |
| Add 10M i32                         |           4.49 |           6.30 | **1.40×** |
| Compare 10M f64 > k                 |           4.45 |           6.95 | **1.56×** |
| Scan 1M strings                     |           1.15 |           9.35 | **8.14×** |
| Sum-where 10M f64 (50%)             |           7.40 |          42.31 | **5.72×** |
| Value counts 10M str (100 distinct) |           7.94 |          59.54 | **7.50×** |
| IPC roundtrip 10M i32 (w+r)         |           5.12 |           9.75 | **1.90×** |

**All 17 kernels are at parity or faster than Arrow C++.** The big margins come
from fused kernels (`filter`, `sum-where`), dictionary group-by (`value counts`),
and an LSD radix sort; SIMD compares and a per-proc-AVX2 `min/max` remove ALU
overhead; element-wise kernels (`cast`/`add`/`take`) reach or beat parity via the
recycling buffer pool plus non-temporal stores that skip the output buffer's
read-for-ownership traffic. `min/max` and `take` sit at the memory-bandwidth floor,
where both libraries are limited by RAM, not code.

OdinArrow also beats **PyArrow** on every benchmark — typically several× up to
~20× on construction (Python overhead removal). The 3-way OdinArrow / PyArrow /
Arrow C++ comparison (with OdinArrow's multi-threaded `*_parallel` kernels) and
full methodology are in [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

Reproduce: `bash benchmarks/bench_odin_c.sh` (single-threaded, vs Arrow C++) or
`bash benchmarks/compare.sh` (3-way, also needs `pyarrow`). Both build the runners.

## Building & testing

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
make test                              # build + run the test suite (-vet -strict-style)
odin run examples/quickstart -out:/tmp/quickstart   # run the runnable demo
odin build src -out:libodinarrow       # build the package
```

To use it in your own project, import the `src` directory as the `odinarrow`
package. A complete, runnable tour of the API lives in
[`examples/quickstart`](examples/quickstart/main.odin); running it prints:

```
== OdinArrow quickstart ==

-- primitives + compute --
  length=10  null_count=1
  sum=42 (over 9 non-null)  min=0  max=9  mean=4.67
  even values: [0, 2, 4, 6, 8]

-- strings --
  4 strings, 17 total bytes; arr[1]="arrow"

-- sort_indices + take --
  sorted: [10, 20, 30, 40, 50]

-- Arrow IPC file round-trip --
  wrote /tmp/odinarrow_quickstart.arrow (readable by pyarrow.ipc.open_file)
  read back 3 row(s):
    id=1 name="ada"
    id=2 name="alan"
    id=3 name="grace"
```

## Capabilities

| Area                                                 | Status       |
| ---------------------------------------------------- | ------------ |
| Aligned buffers, bitmaps (popcount), zero-copy slice | ✅           |
| Primitive + variable-length arrays & builders        | ✅           |
| LargeString / LargeBinary (i64 offsets)              | ✅           |
| Schema, RecordBatch, Table / ChunkedArray            | ✅           |
| Compute kernels (incl. SIMD + threaded)              | ✅           |
| IPC file & stream formats (pyarrow-compatible)       | ✅           |
| Memory-mapped zero-copy reads                        | ✅           |
| Reusable buffer-pool allocator                       | ✅           |
| Parquet, Flight RPC, GPU kernels                     | out of scope |

See [`PLAN.md`](PLAN.md) for the full design and phase breakdown.

## Project layout

```
src/                 the odinarrow package (buffers, types, arrays, builders,
                     compute, ipc, buffer_pool, ...)
tests/               the test suite (run with `make test`)
examples/quickstart/ a runnable tour of the API
benchmarks/          odin / python / cpp runners + compare.sh + RESULTS.md
programs/            CSV<->Parquet example programs (OdinArrow and Arrow-FFI)
```

## License

Zlib License — see [LICENSE](LICENSE).
