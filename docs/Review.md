# OdinArrow vs Apache Arrow — Capability Gap Review

> Generated: 2026-06-12  
> Reference: [Apache Arrow](https://arrow.apache.org/) (format spec, C++ / PyArrow libraries, v24.x)  
> Subject: **OdinArrow** (`src/`, package `odinarrow`) as it exists in this repository

This document compares OdinArrow against the **Apache Arrow project** as a whole — the columnar format specification, the reference C++ libraries, and the ecosystem built around them (PyArrow, Parquet integration, Flight, Dataset, etc.). It is not a performance review; see [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) for that.

### Status legend

| Symbol | Meaning |
|---|---|
| ✅ | Implemented in OdinArrow core library (`src/`) |
| 🔶 | Partial / subset / application code only (`programs/`, FFI) |
| ❌ | Not implemented |

---

## 1. Executive summary

OdinArrow is a **focused, high-quality implementation of Arrow’s core in-memory columnar model** for flat (non-nested) data: aligned buffers, validity bitmaps, primitive and variable-length types, builders, schema/record-batch/table abstractions, a small set of compute kernels (with SIMD and threading), and Arrow IPC file + stream I/O with memory-mapped reads.

It **does not** replicate the breadth of the Apache Arrow **software ecosystem**. Measured against PyArrow / Arrow C++, the largest gaps are:

1. **Data types** — no nested, temporal, decimal, dictionary, union, map, or run-end-encoded types  
2. **Compute** — ~15 hand-written kernels vs **100+ registered functions**, no expression engine, no grouped aggregations or joins  
3. **I/O** — no library-level CSV/JSON/Parquet; experimental Parquet lives in `programs/` only  
4. **Infrastructure** — no Dataset API, filesystem abstraction, Flight/ADBC, Acero query engine, Gandiva, or GPU support  
5. **Interop** — IPC-compatible with PyArrow, but no formal C Data Interface export/import layer

Where OdinArrow **does** compete (and often wins on benchmarks) is the **narrow core**: building flat columns, scanning them, and IPC round-trips — the foundation Arrow was designed for, not the full analytics platform built on top.

---

## 2. Columnar format & type system

Apache Arrow defines a rich logical and physical type system ([Columnar format spec](https://arrow.apache.org/docs/format/Columnar.html)). OdinArrow implements a **flat subset**.

### 2.1 Logical / physical types

| Arrow type | OdinArrow | Notes |
|---|---|---|
| Null | ✅ | |
| Boolean | ✅ | Bit-packed values buffer |
| Int8 / Int16 / Int32 / Int64 | ✅ | |
| UInt8 / UInt16 / UInt32 / UInt64 | ✅ | |
| Float16 | ❌ | Not in `DataType` union |
| Float32 / Float64 | ✅ | |
| Decimal128 / Decimal256 | ❌ | No fixed-precision decimal |
| Date32 / Date64 | ❌ | |
| Time32 / Time64 | ❌ | |
| Timestamp (with timezone) | ❌ | |
| Duration / Interval | ❌ | |
| Binary / String (Utf8) | ✅ | i32 offsets |
| LargeBinary / LargeString | ✅ | i64 offsets; builders + IPC |
| FixedSizeBinary | ❌ | |
| List / LargeList | ❌ | `Array.children` field exists but unused |
| FixedSizeList | ❌ | |
| ListView / LargeListView | ❌ | Newer spec layouts |
| Struct | ❌ | |
| Union (sparse / dense) | ❌ | |
| Map | ❌ | |
| Dictionary (encoded) | ❌ | Parquet reader handles dict *pages*; no Arrow dictionary arrays |
| RunEndEncoded | ❌ | Arrow 12+ layout |
| Extension types | ❌ | User-defined logical types with storage type + metadata |

### 2.2 Layout & invariants

| Capability | OdinArrow | Apache Arrow |
|---|---|---|
| 64-byte buffer alignment | ✅ | ✅ |
| Validity bitmaps (optional when no nulls) | ✅ | ✅ |
| Zero-copy slice (offset + length) | ✅ | ✅ |
| Lazy / cached null count | ✅ | ✅ |
| Variadic buffer counts (nested / REE) | ❌ | ✅ |
| Endianness conversion | ❌ (LE assumed) | ✅ |
| Buffer compression in-memory | ❌ | 🔶 (optional in some paths) |

---

## 3. Memory management

| Capability | OdinArrow | Apache Arrow (C++) |
|---|---|---|
| Explicit aligned allocation (`buffer_make`) | ✅ | ✅ (`arrow::Buffer`) |
| Zero-copy buffer views (`buffer_slice`) | ✅ | ✅ |
| Reusable allocation pool | ✅ `Buffer_Pool` | ✅ `arrow::MemoryPool` (default, jemalloc, etc.) |
| Reference-counted shared buffers | ❌ | ✅ `shared_ptr<Buffer>` |
| Memory accounting / statistics | ❌ | ✅ pool stats, debugger hooks |
| Memory-mapped file backing | ✅ IPC read (Unix `mmap`) | ✅ |
| GPU / device memory | ❌ | ✅ (CUDA, etc.) |
| Thread-safe pool | ❌ (documented single-thread) | ✅ |

OdinArrow’s ownership model is **explicit and manual** (track `allocator`, never double-free sliced arrays). Arrow C++ uses reference counting for shared buffer lifetime across tables, IPC, and foreign runtimes.

---

## 4. Core data structures

| Structure | OdinArrow | Apache Arrow |
|---|---|---|
| `Array` | ✅ | ✅ `arrow::Array` |
| `ChunkedArray` | 🔶 basic (`Table` only) | ✅ full API, compute on chunks |
| `RecordBatch` | ✅ | ✅ |
| `Table` | 🔶 stacks batches, borrows data | ✅ owns schema, column chunks, metadata |
| `Schema` / `Field` | ✅ | ✅ + field metadata, dictionaries |
| `Scalar` | ❌ | ✅ typed single values for compute |
| `Datum` (Array \| Scalar \| Chunked \| …) | ❌ | ✅ unified compute input |
| `Tensor` | ❌ | ✅ |
| `SparseTensor` | ❌ | ✅ |

**OdinArrow gaps in tabular API:**

- No field or schema **custom metadata** (key/value)
- No **dictionary** on fields
- `table_from_record_batches` checks column count only, not type compatibility
- No `Table` → `RecordBatch` iterator, slice, filter, or join
- `Chunked_Array` has get/is_null only — no slice, concat, or compute

---

## 5. Builders & array construction

| Builder | OdinArrow | Apache Arrow |
|---|---|---|
| Primitive (all int/float/bool) | ✅ zero-copy `finish()` | ✅ `NumericBuilder`, etc. |
| String / Binary | ✅ raw-buffer builder | ✅ |
| Large String / Binary | ✅ | ✅ |
| Null builder | ❌ | ✅ |
| FixedSizeBinary | ❌ | ✅ |
| List / Struct / Union | ❌ | ✅ nested builders |
| Dictionary | ❌ | ✅ |
| Decimal | ❌ | ✅ |
| Temporal | ❌ | ✅ |
| Typed `ArrayBuilder` hierarchy | ❌ (generic `Primitive_Builder($T)`) | ✅ per-type classes |
| `Buffer_Pool` integration | ✅ | ✅ default pool |

OdinArrow builders are **fast for flat data** (see benchmarks) but cover only the types in `types.odin`.

---

## 6. Compute engine

Apache Arrow Compute ([C++ docs](https://arrow.apache.org/docs/cpp/compute.html)) exposes a **function registry** with 100+ kernels invokable via `CallFunction(name, args)`, options structs, implicit casts, and support for Scalars, Arrays, ChunkedArrays, RecordBatches, and Tables.

### 6.1 What OdinArrow implements

| Kernel | Serial | SIMD | Parallel |
|---|---|---|---|
| `sum` | ✅ | ✅ i32/f64 | ✅ |
| `min` / `max` / `min_max` | ✅ | ✅ i32 | ✅ |
| `mean` | ✅ | via sum | ✅ |
| `count` | ✅ | — | ❌ |
| `filter` | ✅ | — | ✅ (not strings in parallel) |
| `take` | ✅ | — | ❌ |
| `cast` (numeric) | ✅ | — | ❌ |
| `add` / `sub` / `mul` / `div` | ✅ | — | ❌ |
| `sort_indices` (stable, nulls-last) | ✅ | — | ❌ |

**~15 functions**, hard-coded procs with `(T, Error)` returns — no registry, no options, no scalar/array broadcasting.

### 6.2 Major compute categories missing in OdinArrow

#### Aggregations (scalar reduce)

| Arrow function (examples) | OdinArrow |
|---|---|
| `all`, `any` | ❌ |
| `count_distinct`, `count_all` | ❌ |
| `first`, `last`, `first_last` | ❌ |
| `product` | ❌ |
| `stddev`, `variance`, `skew`, `kurtosis` | ❌ |
| `quantile`, `tdigest`, `approximate_median` | ❌ |
| `mode`, `pivot_wider` | ❌ |
| Grouped / hash aggregations | ❌ |

#### Element-wise & logical

| Category | Examples | OdinArrow |
|---|---|---|
| Comparisons | `equal`, `less`, `not_equal`, … | ❌ |
| Boolean logic | `and`, `or`, `not`, `xor`, Kleene | ❌ |
| Null predicates | `is_null`, `is_valid`, `fill_null` | ❌ (manual via bitmap) |
| Bitwise | `bit_wise_and`, `shift_left`, … | ❌ |
| Math | `sin`, `cos`, `log`, `power`, `abs`, … | ❌ |
| Rounding | `round`, `floor`, `ceil` | ❌ |

#### Selection & ordering

| Arrow function | OdinArrow |
|---|---|
| `sort_indices` | ✅ |
| `array_sort` (materialised sorted array) | ❌ (compose via take) |
| `partition_nth`, `select_k_unstable` | ❌ |
| `indices_nonzero` | ❌ |

#### String & binary

| Arrow function | OdinArrow |
|---|---|
| `utf8_length` | ❌ (hand loop in benchmarks only) |
| `binary_length` | ❌ |
| `utf8_trim`, `replace`, `match`, `split`, `join` | ❌ |
| `binary_concat`, `binary_slice` | ❌ |

#### Temporal

All temporal extract, cast, and arithmetic functions | ❌ (no temporal types)

#### Hash & set

| Arrow function | OdinArrow |
|---|---|
| `hash`, `hash_aggregate` | ❌ |
| `unique`, `value_counts`, `is_in` | ❌ |
| `filter` with inverted mask | manual |

#### Structural / nested

| Arrow function | OdinArrow |
|---|---|
| `make_struct`, `struct_field` | ❌ |
| `list_flatten`, `list_parent_indices` | ❌ |
| `run_end_decode`, `run_end_encode` | ❌ |

#### Joins, windows, and query engine

| Component | OdinArrow |
|---|---|
| Hash join / asof join | ❌ |
| Window functions (rank, lead/lag) | ❌ |
| **Acero** declarative exec plans | ❌ |
| **Substrait** integration | ❌ |

#### Compute infrastructure

| Feature | OdinArrow | Apache Arrow |
|---|---|---|
| Function registry + `CallFunction` | ❌ | ✅ |
| Kernel dispatch by exact type | ✅ manual switch | ✅ auto |
| Implicit numeric promotion | ❌ | ✅ |
| Options (`ScalarAggregateOptions`, …) | ❌ | ✅ |
| Compute on `ChunkedArray` | ❌ | ✅ |
| Compute on `RecordBatch` / `Table` | ❌ | ✅ |
| User-defined functions (UDF) | ❌ | ✅ |
| **Gandiva** (LLVM JIT expressions) | ❌ | ✅ (C++) |

---

## 7. IPC & serialization

| Capability | OdinArrow | Apache Arrow |
|---|---|---|
| IPC **file** format (Feather v2) | ✅ read + write | ✅ |
| IPC **stream** format | ✅ read + write | ✅ |
| Encapsulated message framing | ✅ | ✅ |
| Self-contained FlatBuffers encoder | ✅ (no FlatBuffers dep) | ✅ |
| Zero-copy read (mmap) | ✅ Unix; fallback read | ✅ |
| Zero-copy read into `RecordBatch._owned_backing` | ✅ | ✅ |
| Supported IPC types (flat) | ✅ primitives + utf8/binary + large variants | ✅ |
| Nested types in IPC | ❌ | ✅ |
| Dictionary batches / delta dict | ❌ (stream reader stops on unknown) | ✅ |
| IPC body **compression** (LZ4, ZSTD) | ❌ | ✅ |
| Custom schema / field metadata | ❌ | ✅ |
| Extension type metadata | ❌ | ✅ |
| Alignment / continuation tokens | ✅ | ✅ |
| Random batch access (file footer index) | ✅ | ✅ |
| Tensor IPC | ❌ | ✅ |
| Sparse tensor IPC | ❌ | ✅ |
| C **stream** interface (`ArrowArrayStream`) | ❌ | ✅ |
| C **device** interface (CUDA) | ❌ | ✅ |

**Interop status:** Files produced by OdinArrow for supported flat types are readable by PyArrow and Arrow C++, and vice versa (verified in tests and README). Unsupported IPC features (dictionaries, nested columns, compression) will fail or be skipped.

---

## 8. File format I/O (beyond IPC)

Apache Arrow libraries ship readers/writers and integration for many on-disk formats. OdinArrow separates **library** from **example programs**.

| Format | OdinArrow library | OdinArrow `programs/` | Apache Arrow |
|---|---|---|---|
| Arrow IPC / Feather | ✅ | — | ✅ |
| **Parquet** read | ❌ | 🔶 native subset (`parquet_to_csv_odin`) | ✅ full |
| **Parquet** write | ❌ | 🔶 native subset (`csv_to_parquet_odin`) | ✅ full |
| Parquet via FFI | — | 🔶 Arrow C++ shim | ✅ |
| **CSV** read/write | ❌ | 🔶 streaming CSV in converter | ✅ `arrow::csv` |
| **JSON** | ❌ | ❌ | ✅ |
| **ORC** | ❌ | ❌ | ✅ (Java primary; C++ limited) |
| **Avro** | ❌ | ❌ | 🔶 |
| **NDJSON** | ❌ | ❌ | 🔶 (via parsers) |

### 8.1 Native Odin Parquet subset (programs only)

What the experimental native reader/writer supports vs full Parquet:

| Parquet feature | Native Odin | Apache Arrow Parquet |
|---|---|---|
| PLAIN encoding | ✅ | ✅ |
| Dictionary pages | 🔶 read only | ✅ |
| RLE, DELTA, BIT_PACKED encodings | ❌ | ✅ |
| Page compression (SNAPPY, ZSTD, GZIP, …) | ❌ | ✅ |
| Statistics / column indexes | ❌ | ✅ |
| Bloom filters | ❌ | ✅ (Arrow 24+) |
| Nested / repeated fields | ❌ | ✅ |
| All physical types | 🔶 INT32 + BYTE_ARRAY write; broader read | ✅ |
| Schema evolution | ❌ | ✅ |
| Encryption | ❌ | ✅ |
| Multi-threaded decode | ❌ | ✅ |

---

## 9. Dataset & scanning layer

PyArrow’s **`Dataset` API** and Arrow C++ **`arrow::dataset`** provide partitioned, multi-file analytics:

| Capability | OdinArrow | Apache Arrow |
|---|---|---|
| `Dataset` over Parquet/IPC/CSV | ❌ | ✅ |
| Hive / directory partitioning | ❌ | ✅ |
| File discovery & fragment scan | ❌ | ✅ |
| Projection / filter pushdown | ❌ | ✅ |
| `Scanner` → stream of RecordBatches | ❌ | ✅ |
| Write `Dataset` (partitioned output) | ❌ | ✅ |
| Acero integration (exec plans over datasets) | ❌ | ✅ |

OdinArrow has **`Table` / `Chunked_Array`** as a minimal in-memory analogue but no filesystem-aware scanning.

---

## 10. Filesystem & remote I/O

| Capability | OdinArrow | Apache Arrow |
|---|---|---|
| Local file read/write | ✅ (`core:os`) | ✅ `arrow::fs::LocalFileSystem` |
| Unified `FileSystem` abstraction | ❌ | ✅ |
| S3 / GCS / Azure / HDFS | ❌ | ✅ |
| Memory filesystem (testing) | ❌ | ✅ |
| IO interface for IPC/Parquet | direct paths only | ✅ abstract streams |

---

## 11. Network protocols & database connectivity

| Component | Purpose | OdinArrow |
|---|---|---|
| **Arrow Flight** | gRPC RPC for streaming Arrow batches | ❌ |
| **Flight SQL** | JDBC/ODBC-style wire protocol over Flight | ❌ |
| **ADBC** | Standard database API returning Arrow batches | ❌ |
| REST / custom RPC | — | ❌ (Arrow had experimental REST) |

These are **separate sub-projects** in the Arrow ecosystem but are commonly grouped under “Apache Arrow capabilities” in production stacks (Dremio, InfluxDB 3, etc.).

---

## 12. Query engine & advanced analytics

| Component | OdinArrow | Apache Arrow |
|---|---|---|
| **Acero** (C++ exec engine) | ❌ | ✅ filter, project, aggregate, join, order |
| **Gandiva** (LLVM JIT) | ❌ | ✅ expression compilation to native code |
| **Substrait** consumer/producer | ❌ | 🔶 |
| SQL parsing | ❌ | ❌ (delegated to engines) |
| GPU compute (cuDF / libarrow CUDA) | ❌ | ✅ |

---

## 13. Interoperability & language ecosystem

| Interface | OdinArrow | Apache Arrow |
|---|---|---|
| **C Data Interface** (`ArrowArray` / `ArrowSchema`) | 🔶 layout-compatible buffers; no export/import procs | ✅ spec + helpers |
| **C Stream Interface** | ❌ | ✅ |
| PyArrow / Python | ✅ via IPC files | ✅ native binding |
| R, Java, Go, Rust, JS, … | ❌ | ✅ official libraries |
| **nanoarrow** (minimal C) | ❌ | ✅ separate project |
| Cross-language integration test suite | 🔶 IPC + C++ FFI tests | ✅ extensive |

OdinArrow proves **binary layout compatibility** with Arrow C++ for sum/min/max/filter on raw pointers (`tests_cpp/`), but does not expose a stable C ABI for foreign callers.

---

## 14. Metadata, extension types & schema evolution

| Feature | OdinArrow | Apache Arrow |
|---|---|---|
| Field nullable flag | ✅ | ✅ |
| Field / schema custom metadata (KV) | ❌ | ✅ |
| Dictionary type on field | ❌ | ✅ |
| Extension types (uuid, json, geo, …) | ❌ | ✅ |
| Schema evolution (add/rename columns) | ❌ | 🔶 (format + library support) |
| Canonical extension type registry | ❌ | ✅ (Arrow docs) |

---

## 15. Tooling, testing & packaging

| Area | OdinArrow | Apache Arrow |
|---|---|---|
| Unit tests | ✅ 122 tests (`make test`) | ✅ extensive |
| C++ interop tests | ✅ `make test-cpp` | — |
| Benchmark suite vs PyArrow/C++ | ✅ | ✅ (conbench) |
| Integration / cross-lang golden tests | 🔶 IPC + roundtrip script | ✅ |
| CI (GitHub Actions) | ❌ | ✅ |
| Package manager (`odin pkg`, pip, conda) | ❌ / ad hoc `import "../../src"` | ✅ |
| Documentation site | 🔶 README, PLAN, RESULTS | ✅ arrow.apache.org |
| Feature status matrix | — | ✅ per language |

---

## 16. Side-by-side scope map

```
Apache Arrow ecosystem                          OdinArrow coverage
─────────────────────────────────────────────────────────────────────
Columnar format (full type system)              ████░░░░░░  ~35%
In-memory Array / Batch / Table (flat)          ████████░░  ~80%
Builders (flat)                                 ████████░░  ~85%
Compute (function registry)                     ██░░░░░░░░  ~10%
IPC file + stream (flat, uncompressed)          ███████░░░  ~70%
Parquet (full)                                  █░░░░░░░░░  ~5%  (programs only)
CSV / JSON / ORC I/O                            ░░░░░░░░░░   0%  (CSV in programs)
Dataset / Scanner                               ░░░░░░░░░░   0%
Filesystem (local + cloud)                      ░░░░░░░░░░   0%
Flight / Flight SQL / ADBC                      ░░░░░░░░░░   0%
Acero / Gandiva / GPU                           ░░░░░░░░░░   0%
Multi-language bindings                         ░░░░░░░░░░   0%  (Odin only)
```

---

## 17. What OdinArrow covers well (parity or better for flat analytics)

These areas are **not missing** relative to Arrow’s core value proposition for flat data:

- Columnar memory layout and Arrow buffer conventions  
- Zero-copy slice, mmap IPC read, zero-copy builder `finish()`  
- Primitive + string/binary/large-string/large-binary types  
- Schema, RecordBatch, basic Table/ChunkedArray  
- Essential compute: sum, min/max, mean, filter, take, cast, arithmetic, sort_indices  
- SIMD + multi-threaded reductions/filter  
- IPC file and stream with PyArrow interoperability  
- Buffer pool for repeated construction  
- Validated against Arrow C++ on raw buffer layout (`tests_cpp/`)

For **“load flat columns → compute → exchange via IPC”**, OdinArrow is a credible subset. For **“drop-in PyArrow replacement”**, it is not.

---

## 18. Prioritised gap closure (if aiming at Arrow parity)

Grouped by dependency order. Effort: **S** / **M** / **L**.

### Tier 1 — Format completeness (unblocks interop)

| Priority | Gap | Effort |
|---|---|---|
| P1 | Temporal types (Date32, Timestamp) + IPC + cast | M |
| P1 | Dictionary-encoded arrays + IPC dictionary messages | L |
| P2 | Struct + List types (arrays, builders, IPC, compute) | L |
| P2 | IPC body compression (ZSTD/LZ4) | M |
| P3 | Field/schema custom metadata | S |
| P3 | Extension types | M |

### Tier 2 — Compute breadth (unblocks analytics)

| Priority | Gap | Effort |
|---|---|---|
| P1 | Comparisons + boolean kernels (`equal`, `is_null`, …) | M |
| P2 | `value_counts`, `unique`, `is_in` | M |
| P2 | String kernels (`utf8_length`, `binary_concat`, …) | M |
| P3 | Function registry pattern (even if small initial set) | M |
| P3 | ChunkedArray / RecordBatch-level compute wrappers | M |
| P4 | Grouped aggregations | L |
| P5 | Joins / Acero-style plans | L |

### Tier 3 — I/O & ecosystem (unblocks production pipelines)

| Priority | Gap | Effort |
|---|---|---|
| P1 | Parquet as library module (decode compression + common encodings) | L |
| P2 | CSV reader/writer in `src/` | M |
| P3 | C Data Interface export/import | M |
| P4 | Dataset + filesystem abstraction | L |
| P5 | Flight server/client | L |

### Explicit non-goals (match README / PLAN)

Unless requirements change, these remain **out of scope** for OdinArrow as documented:

- GPU / CUDA kernels  
- Gandiva LLVM JIT  
- Full Acero / SQL engine  
- Multi-language bindings beyond Odin  
- Complete Parquet specification in native code (FFI path exists for full fidelity)

---

## 19. References

- [Apache Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html)  
- [Arrow IPC format](https://arrow.apache.org/docs/format/Columnar.html#ipc-streaming-format)  
- [Arrow C++ compute functions](https://arrow.apache.org/docs/cpp/compute.html)  
- [Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html)  
- [Arrow Flight](https://arrow.apache.org/docs/format/Flight.html)  
- [PyArrow Dataset](https://arrow.apache.org/docs/python/dataset.html)  
- OdinArrow: [`README.md`](README.md), [`PLAN.md`](PLAN.md), [`Cursor.md`](Cursor.md), [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)

---

*This review reflects the repository state at generation time (122 passing tests). Update when major types, compute kernels, or I/O modules land.*
