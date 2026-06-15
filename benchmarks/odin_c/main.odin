// Comprehensive single-threaded OdinArrow benchmark, paired 1:1 with the Arrow
// C++ benchmark in benchmarks/cpp/bench_odin_c.cpp. Output: `key=nanoseconds`
// per line (median of TRIALS), parsed by benchmarks/bench_odin_c.sh.
//
// Single-threaded throughout (the serial compute_* kernels, not the
// compute_*_parallel variants) so it measures per-core efficiency against Arrow
// C++ — see the 3-way compare.sh for the threaded story.
package main

import "core:fmt"
import "core:slice"
import "core:time"
import "core:math/rand"
import oa "../../src"

N      :: 10_000_000
NS     :: 1_000_000
NSORT  :: 1_000_000
NIDX   :: 1_000_000
NVC    :: 10_000_000
NVCD   :: 100
TRIALS :: 5

_sink: f64

report :: proc(key: string, ns: u64) { fmt.printf("%s=%d\n", key, ns) }
median :: proc(t: []u64) -> u64 { slice.sort(t); return t[len(t)/2] }
bench  :: proc(f: proc() -> u64) -> u64 {
	t := make([]u64, TRIALS); defer delete(t)
	for i in 0..<TRIALS { t[i] = f() }
	return median(t)
}
elapsed :: proc(t0: time.Tick) -> u64 { return u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))) }

// ── shared inputs (built once, untimed) ─────────────────────────────────────
g_f64, g_f64n, g_i32, g_i32b, g_mask50, g_mask1, g_strs, g_sort, g_idx: oa.Array
g_dict: oa.Str_Dict_Array
g_ipc_schema: oa.Schema
g_ipc_batch:  oa.Record_Batch

build_inputs :: proc() {
	{ b := oa.builder_make(f64, N); for i in 0..<N { oa.builder_append(&b, f64(i)*0.001) }; g_f64,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.builder_make(f64, N); for i in 0..<N { if i%100==0 { oa.builder_append_null(&b) } else { oa.builder_append(&b, f64(i)*0.001) } }; g_f64n,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.builder_make(i32, N); for i in 0..<N { oa.builder_append(&b, i32(i)) }; g_i32,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.builder_make(i32, N); for i in 0..<N { oa.builder_append(&b, i32(i%1000)) }; g_i32b,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.builder_make(bool, N); for i in 0..<N { oa.builder_append(&b, i%2==0) }; g_mask50,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.builder_make(bool, N); for i in 0..<N { oa.builder_append(&b, i%100==0) }; g_mask1,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.string_builder_make(NS); for _ in 0..<NS { oa.string_builder_append(&b, "hello_world") }; g_strs,_ = oa.string_builder_finish(&b); oa.string_builder_destroy(&b) }
	{ b := oa.builder_make(i32, NSORT); rand.reset(u64(7)); for _ in 0..<NSORT { oa.builder_append(&b, i32(rand.uint32())) }; g_sort,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	{ b := oa.builder_make(i64, NIDX); rand.reset(u64(42)); for _ in 0..<NIDX { oa.builder_append(&b, i64(rand.uint64() % u64(N))) }; g_idx,_ = oa.builder_finish(&b); oa.builder_destroy(&b) }
	// value_counts: low-cardinality string column, dictionary-encoded (encode untimed)
	{
		b := oa.string_builder_make(NVC); buf: [16]u8
		for i in 0..<NVC {
			k := i % NVCD
			n := copy(buf[:], "category_"); buf[n]=u8('0'+(k/10)); buf[n+1]=u8('0'+(k%10))
			oa.string_builder_append(&b, string(buf[:n+2]))
		}
		plain,_ := oa.string_builder_finish(&b); oa.string_builder_destroy(&b)
		g_dict = oa.str_dict_encode(&plain)
		oa.array_free(&plain)
	}
	// IPC: a 10M-i32 record batch (dedicated array so it owns its buffers)
	{
		fields := []oa.Field{oa.field_make("v", oa.Int32_Type{})}
		g_ipc_schema,_ = oa.schema_make(fields)
		b := oa.builder_make(i32, N); for i in 0..<N { oa.builder_append(&b, i32(i)) }
		col,_ := oa.builder_finish(&b); oa.builder_destroy(&b)
		g_ipc_batch,_ = oa.record_batch_make(&g_ipc_schema, []oa.Array{col})
	}
}

// ── benchmark procs ─────────────────────────────────────────────────────────

b_build_i32 :: proc() -> u64 {
	t0 := time.tick_now()
	b := oa.builder_make(i32, N)
	for i in 0..<N { if i%100==0 { oa.builder_append_null(&b) } else { oa.builder_append(&b, i32(i)) } }
	a,_ := oa.builder_finish(&b)
	ns := elapsed(t0); _sink += f64(a.length); oa.array_free(&a); oa.builder_destroy(&b); return ns
}
b_build_str :: proc() -> u64 {
	t0 := time.tick_now()
	b := oa.string_builder_make(NS)
	for i in 0..<NS { if i%50==0 { oa.string_builder_append_null(&b) } else { oa.string_builder_append(&b, "hello_world") } }
	a,_ := oa.string_builder_finish(&b)
	ns := elapsed(t0); _sink += f64(a.length); oa.array_free(&a); oa.string_builder_destroy(&b); return ns
}
b_sum         :: proc() -> u64 { t0:=time.tick_now(); s,_:=oa.compute_sum(&g_f64);  ns:=elapsed(t0); _sink+=s;       return ns }
b_sum_nulls   :: proc() -> u64 { t0:=time.tick_now(); s,_:=oa.compute_sum(&g_f64n); ns:=elapsed(t0); _sink+=s;       return ns }
b_minmax      :: proc() -> u64 { t0:=time.tick_now(); lo,hi,_:=oa.compute_min_max(&g_i32); ns:=elapsed(t0); _sink+=lo+hi; return ns }
b_mean        :: proc() -> u64 { t0:=time.tick_now(); m,_:=oa.compute_mean(&g_f64); ns:=elapsed(t0); _sink+=m;       return ns }
b_filter_50   :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_filter(&g_i32,&g_mask50); ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_filter_1    :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_filter(&g_i32,&g_mask1);  ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_take        :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_take(&g_i32,&g_idx); ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_sort        :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_sort_indices(&g_sort); ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_cast        :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_cast(&g_i32, oa.Float64_Type{}); ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_add         :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_add(&g_i32,&g_i32b); ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_compare     :: proc() -> u64 { t0:=time.tick_now(); r,_:=oa.compute_compare(&g_f64, .Gt, 5000.0); ns:=elapsed(t0); _sink+=f64(r.length); oa.array_free(&r); return ns }
b_scan_str    :: proc() -> u64 { t0:=time.tick_now(); total:=0; for i in 0..<g_strs.length { total += len(oa.array_get_string(&g_strs,i)) }; ns:=elapsed(t0); _sink+=f64(total); return ns }
b_sumwhere    :: proc() -> u64 { t0:=time.tick_now(); s,_:=oa.compute_sum_where(&g_f64,&g_mask50); ns:=elapsed(t0); _sink+=s; return ns }
b_valuecounts :: proc() -> u64 { t0:=time.tick_now(); c:=oa.str_dict_value_counts(&g_dict); ns:=elapsed(t0); _sink+=f64(len(c)); delete(c); return ns }
b_ipc :: proc() -> u64 {
	path := "/tmp/odc_odin_ipc.arrow"
	t0 := time.tick_now()
	oa.ipc_write_file(path, &g_ipc_schema, []oa.Record_Batch{g_ipc_batch})
	sc, batches, _ := oa.ipc_read_file(path)
	ns := elapsed(t0)
	if len(batches) > 0 { _sink += f64(batches[0].length) }
	oa.schema_free(sc); free(sc)
	for bx in batches { bc := bx; oa.record_batch_free(&bc) }
	delete(batches)
	return ns
}

main :: proc() {
	build_inputs() // inputs allocated on the default heap (untimed)

	// Route all timed allocations through a recycling buffer pool — the
	// OdinArrow analogue of arrow::MemoryPool, which Arrow C++ uses by default.
	// Without this, each kernel call mmap/munmaps its large output buffer and
	// re-faults fresh pages, an allocator artefact rather than kernel cost.
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	context.allocator = oa.buffer_pool_allocator(&pool)

	report("build_i32_10m",        bench(b_build_i32))
	report("build_str_1m",         bench(b_build_str))
	report("sum_f64_10m",          bench(b_sum))
	report("sum_f64_nulls_10m",    bench(b_sum_nulls))
	report("minmax_i32_10m",       bench(b_minmax))
	report("mean_f64_10m",         bench(b_mean))
	report("filter_i32_10m_50",    bench(b_filter_50))
	report("filter_i32_10m_1",     bench(b_filter_1))
	report("take_i32_10m",         bench(b_take))
	report("sort_i32_1m",          bench(b_sort))
	report("cast_i32_f64_10m",     bench(b_cast))
	report("add_i32_10m",          bench(b_add))
	report("compare_f64_10m",      bench(b_compare))
	report("scan_str_1m",          bench(b_scan_str))
	report("sumwhere_f64_10m",     bench(b_sumwhere))
	report("valuecounts_str_10m",  bench(b_valuecounts))
	report("ipc_roundtrip_i32_10m",bench(b_ipc))
	if _sink == -1 { fmt.println(_sink) }
}
