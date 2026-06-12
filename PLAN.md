# OdinArrow — Design & Development Plan

## What We Are Building

A native Odin implementation of the Apache Arrow columnar in-memory format,
with feature parity to the core of PyArrow, plus a benchmarking harness that
compares Odin and Python performance head-to-head.

---

## Arrow Fundamentals (what the spec actually requires)

Apache Arrow defines a **columnar memory layout** where every column is a set
of contiguous, SIMD-aligned buffers:

```
Int32 column [1, 2, null, 4]:
  buffer[0] = validity bitmap  →  bits: 1 1 0 1  (packed, 64-byte padded)
  buffer[1] = values           →  i32: 1 2 X 4   (X = don't care)

String column ["hi", "world", null, "!"]:
  buffer[0] = validity bitmap  →  bits: 1 1 0 1
  buffer[1] = offsets (i32)    →  [0, 2, 7, 7, 8]   (n+1 values)
  buffer[2] = values (u8)      →  "hiworld!"
```

Key invariants the spec guarantees:
- All buffers are 64-byte aligned (AVX-512 SIMD width)
- Bitmaps are padded to 64 bytes
- Null values in numeric arrays have no defined value — treat as garbage
- Slicing is zero-copy: only offset + length change

---

## Architecture

### Memory Layer

```
Buffer
  data:      [^]u8      -- raw pointer, 64-byte aligned
  size:      int        -- bytes used
  capacity:  int        -- bytes allocated
  allocator: Allocator  -- tracked for explicit free
```

Alignment: use `mem.alloc_aligned(size, 64, allocator)`.
Bitmap padding: always round capacity up to next multiple of 64 bytes.

### Type System

Arrow's type system maps cleanly to an Odin tagged union — no vtables, no
heap allocation for type metadata:

```
DataType :: union {
    // Null
    Null_Type,
    // Boolean
    Bool_Type,
    // Signed integers
    Int8_Type, Int16_Type, Int32_Type, Int64_Type,
    // Unsigned integers
    UInt8_Type, UInt16_Type, UInt32_Type, UInt64_Type,
    // Floating point
    Float32_Type, Float64_Type,
    // Variable-length
    String_Type,       // UTF-8, i32 offsets
    Large_String_Type, // UTF-8, i64 offsets
    Binary_Type,       // raw bytes, i32 offsets
    Large_Binary_Type, // raw bytes, i64 offsets
    // Temporal
    Date32_Type,    // days since UNIX epoch
    Date64_Type,    // ms since UNIX epoch
    Timestamp_Type, // us since UNIX epoch + optional timezone
    // Nested (children stored in Array.children)
    List_Type,
    Large_List_Type,
    Fixed_Size_List_Type,
    Struct_Type,
    // Dictionary encoding
    Dictionary_Type,
}
```

### Array (the central type)

Mirrors the Arrow C Data Interface layout — enables zero-copy bridge to C/Python:

```
Array :: struct {
    type:        DataType,
    length:      int,
    null_count:   int,       // -1 = unknown (force recount)
    offset:      int,        // non-zero after slice (zero-copy)
    buffers:     [3]^Buffer, // [validity, data-or-offsets, values]
    children:    []^Array,   // nested types
    dictionary:  ^Array,     // dictionary encoding
}
```

Slice is O(1): `{..arr, offset: arr.offset + from, length: to - from}`.

### Builders

One builder per logical type family. Builders own dynamic arrays and produce
an `Array` on `finish()`. The finished Array owns its buffers; the builder
can be reset and reused:

```
Int32_Builder :: struct {
    values:     [dynamic]i32,
    bitmap:     [dynamic]u8,   // packed bits
    null_count:  int,
    allocator:  Allocator,
}
```

Append path is branchless for non-null values: set the bitmap bit, append
value. Null path: clear the bitmap bit, append 0, increment null_count.

### Schema / Field / RecordBatch / Table

```
Field :: struct { name: string, type: DataType, nullable: bool }
Schema :: struct { fields: []Field }

RecordBatch :: struct {    // all columns same length
    schema:  ^Schema,
    columns: []^Array,
    length:  int,
}

Table :: struct {           // chunked: columns may span multiple batches
    schema:  ^Schema,
    columns: []Chunked_Array,
    length:  int,
}

Chunked_Array :: struct {
    type:   DataType,
    chunks: []^Array,
    length: int,
}
```

### Compute Layer

Each kernel is a typed proc over `^Array` → `^Array` (or scalar).
Dispatch is a type switch, not virtual. SIMD paths live in separate procs
called from within each case:

```
compute_sum_i32 :: proc(arr: ^Array) -> (i64, bool)
compute_filter  :: proc(arr: ^Array, mask: ^Array) -> (^Array, Error)
compute_cast    :: proc(arr: ^Array, to: DataType) -> (^Array, Error)
```

SIMD strategy: use `intrinsics.simd_*` for numeric aggregations. The scalar
fallback handles the tail (length % lane_width remaining elements).

---

## Development Phases

### Phase 1 — Core Memory (start here)
Files: `buffer.odin`, `bitmap.odin`

- [x] Aligned buffer alloc/free (64-byte)
- [x] Buffer: resize, copy, slice (view, no copy)
- [x] Bitmap: set/clear/get bit, popcount (null_count recount)
- [x] Bitmap: word-at-a-time popcount via `intrinsics.count_ones`

**Tests**: buffer alignment, bitmap correctness, popcount vs naive

### Phase 2 — Type System & Primitive Arrays
Files: `types.odin`, `array.odin`, `builders.odin`

- [x] DataType union + bit_width / is_variable_length helpers
- [x] Array struct + slice (zero-copy), is_null, value accessors
- [x] Builders for: Bool, Int8/16/32/64, UInt8/16/32/64, Float32/64
- [x] `finish()` → Array (builder → immutable Arrow array)

**Tests**: roundtrip build → read for every primitive type, null counts, slice correctness

### Phase 3 — Variable-Length Arrays
Files: `array.odin` (extended), `builders.odin` (extended)

- [x] String / Binary arrays (i32 offsets buffer)
- [x] LargeString / LargeBinary (i64 offsets) — builders + zero-copy accessors
      (NB: the IPC writer still encodes variable-length columns with i32-offset
      width, so Large* columns should not yet be round-tripped through IPC)
- [x] String_Builder: append_string, append_null, finish

**Tests**: offset invariants, null strings, unicode content

### Phase 4 — Schema, RecordBatch, Table
Files: `schema.odin`, `record_batch.odin`, `table.odin`

- [x] Field + Schema validation
- [x] RecordBatch: construct, validate column lengths match
- [x] Chunked_Array: logical length, chunk iteration
- [x] Table: from_record_batches, column_by_name

**Tests**: schema mismatch errors, multi-chunk column access

### Phase 5 — Compute Kernels
Files: `compute.odin`, `compute_simd.odin`

Priority order (by PyArrow benchmark value):
- [x] `sum`, `min`, `max`, `mean` for all numeric types
- [x] `count` (total + non-null)
- [x] `filter` (boolean mask → new array)
- [x] `take` (index array → new array)
- [x] `cast` (safe numeric casts)
- [x] `sort_indices` (stable, nulls-last; matches PyArrow ordering)
- [x] Arithmetic: `add`, `subtract`, `multiply`, `divide` (element-wise)

SIMD targets: sum_i32, sum_f64, filter_i32 (these are PyArrow hot paths) — done,
plus min/max. Threaded variants (compute_*_parallel) fan out across all cores.

**Tests**: correctness vs hand-computed values, null propagation rules

### Phase 6 — IPC Format
Files: `ipc.odin` (self-contained back-to-front FlatBuffers builder)

- [x] Arrow IPC stream writer/reader (footerless, sequential messages + EOS)
- [x] Arrow IPC file writer/reader (Feather v2, seekable, random batch access)
- [x] Cross-validated with PyArrow in both directions (int8/16/32/64,
      uint, float32/64, utf8, nulls, multiple record batches)
- [x] Zero-copy reads: columns are views into the file block (no per-buffer copy)

**Tests**: roundtrip write → read for all array types (tests/test_ipc.odin),
plus a PyArrow interop harness.

### Phase 7 — Benchmarking Harness
Files: `benchmarks/bench_*.odin`, `benchmarks/bench_*.py`, `benchmarks/compare.sh`

Python benchmarks use `pyarrow` + `time.perf_counter_ns`.
Odin benchmarks use a simple `time.tick_now()` harness.
The compare script runs both and emits a markdown table.

Benchmark scenarios:
1. **Array construction**: build 10M int32 with 1% nulls
2. **Sequential scan**: sum 10M float64
3. **SIMD aggregation**: min/max over 10M int32
4. **Filter**: boolean mask on 10M int32 (50% pass rate)
5. **String construction**: build 1M short strings
6. **String scan**: compute byte length of each string in 1M column
7. **IPC roundtrip**: write + read 10M int32 column to disk ✅ (all three runners)

---

## File Structure

```
OdinArrow/
├── PLAN.md                      ← this file
├── src/
│   ├── buffer.odin
│   ├── bitmap.odin
│   ├── types.odin
│   ├── array.odin
│   ├── builders.odin
│   ├── schema.odin
│   ├── record_batch.odin
│   ├── table.odin
│   ├── compute.odin
│   ├── compute_simd.odin
│   ├── ipc.odin
│   └── odinarrow.odin            ← package entry, re-exports public API
├── tests/
│   ├── test_buffer.odin
│   ├── test_bitmap.odin
│   ├── test_array.odin
│   ├── test_compute.odin
│   └── test_ipc.odin
├── benchmarks/
│   ├── odin/
│   │   ├── bench_array.odin
│   │   ├── bench_compute.odin
│   │   └── bench_ipc.odin
│   ├── python/
│   │   ├── bench_array.py
│   │   ├── bench_compute.py
│   │   └── bench_ipc.py
│   └── compare.sh               ← runs both, outputs markdown table
└── examples/
    └── quickstart.odin
```

---

## Key Design Decisions & Tradeoffs

| Decision | Choice | Reason |
|---|---|---|
| Type dispatch | Tagged union + type switch | Zero cost, no vtable, inlineable |
| Buffer ownership | Explicit, tracked per-buffer | Odin's manual memory model; avoids GC |
| Builder storage | `[dynamic]T` | Amortized O(1) append; converted to flat on finish |
| SIMD | `intrinsics.simd_*` with scalar tail | No external deps; auto-vectorization fallback |
| Null bitmap | Arrow spec (packed bits) | Wire-compatible with Arrow C Data Interface |
| Error handling | `(T, Error)` return pairs | Odin convention; no exception overhead |
| Slice semantics | Offset + length into parent buffer | Matches Arrow zero-copy contract exactly |

---

## What We Are NOT Building (initially)

- Parquet read/write (complex, separate project)
- Flight RPC (network transport layer)
- CUDA / GPU compute kernels
- Full Arrow Compute Expression Language
- Dataset API (partitioned, multi-file)

These can be Phase 8+ once the core is stable.

---

## Performance Expectations

PyArrow wraps highly optimized C++ (LLVM-compiled, SIMD-tuned, multi-threaded).
The Odin implementation will initially be single-threaded.

Realistic targets:
- **Construction**: 1.5–3× faster than PyArrow (Python overhead removal)
- **Aggregations (SIMD)**: competitive or faster (no C FFI overhead per call)
- **Filter**: comparable to PyArrow with SIMD bitmap operations
- **IPC write**: comparable (same binary format, similar buffer flush strategy)
- **String ops**: likely slower initially (C++ std::string_view is highly tuned)

The benchmarks will show the honest picture. The story is less "beat C++" and
more "demonstrate that a systems language with zero overhead abstractions can
match a Python-wrapped C++ library, with much simpler and more auditable code."
