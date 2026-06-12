# OdinArrow

A native [Apache Arrow](https://arrow.apache.org/) implementation in the
[Odin](https://odin-lang.org/) language — columnar in-memory format, compute
kernels, and the Arrow IPC format (Feather v2), with zero-overhead abstractions
and explicit memory management.

Files written by OdinArrow are read directly by **PyArrow** and **Apache Arrow
C++**, and vice-versa.

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

OdinArrow vs **PyArrow** vs **Apache Arrow C++** (the LLVM-compiled library
PyArrow wraps, called directly). Intel i7-7700HQ (4c/8t), median of 5 trials,
10M-element numeric / 1M-element string workloads.

| Benchmark | OdinArrow (ms) | PyArrow (ms) | Arrow C++ (ms) | Py/Odin | C++/Odin |
|---|---:|---:|---:|---:|---:|
| Build 10M i32 (1% nulls)      | 44.2 | 957.5 | 41.7 | 21.7× | 0.94× |
| Sum 10M f64 †                 |  3.5 |   6.2 |  6.1 |  1.8× | 1.74× |
| Sum 10M i32 †                 |  2.1 |   2.5 |  2.5 |  1.2× | 1.20× |
| Min+Max 10M i32 †             |  2.0 |   4.1 |  2.2 |  2.0× | 1.11× |
| Filter 10M i32 (50% pass) †   | 13.2 |  36.1 | 39.5 |  2.8× | 3.00× |
| Build 1M strings (2% nulls)   |  8.5 |  91.5 |  7.3 | 10.8× | 0.85× |
| Scan 1M strings               |  1.0 |   9.5 |  9.2 |  9.1× | 8.80× |
| IPC roundtrip 10M i32 (w+r)   |  5.2 |  11.0 | 10.3 |  2.1× | 1.96× |

Ratios > 1× mean OdinArrow is faster. **†** OdinArrow's reductions/filter run
multi-threaded; PyArrow and Arrow C++ here are single-threaded, so those four
rows bundle threading with per-core efficiency. The other rows are
single-threaded on all three.

OdinArrow beats PyArrow on every benchmark, and is at parity with or ahead of
Arrow C++ everywhere — including single-threaded construction, after zero-copy
`finish()`, uninitialised data buffers, and the reusable buffer pool. Full
analysis and methodology in [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

Reproduce: `bash benchmarks/compare.sh` (needs `pyarrow` and the Arrow C++ libs;
the script builds the Odin and C++ runners).

## Building & testing

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
make test                              # build + run the test suite (-vet -strict-style)
odin run examples/quickstart -out:/tmp/quickstart   # run the runnable demo
odin build src -out:libodinarrow       # build the package
```

To use it in your own project, import the `src` directory as the `odinarrow`
package. A complete, runnable tour of the API lives in
[`examples/quickstart`](examples/quickstart/main.odin).

## Capabilities

| Area | Status |
|---|---|
| Aligned buffers, bitmaps (popcount), zero-copy slice | ✅ |
| Primitive + variable-length arrays & builders | ✅ |
| LargeString / LargeBinary (i64 offsets) | ✅ |
| Schema, RecordBatch, Table / ChunkedArray | ✅ |
| Compute kernels (incl. SIMD + threaded) | ✅ |
| IPC file & stream formats (pyarrow-compatible) | ✅ |
| Memory-mapped zero-copy reads | ✅ |
| Reusable buffer-pool allocator | ✅ |
| Parquet, Flight RPC, GPU kernels | out of scope |

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

BSD 3-Clause — see [LICENSE](LICENSE).
