package bench_odinarrow

import "core:fmt"
import "core:slice"
import "core:time"
import oa "../../src"

N_LARGE  :: 10_000_000
N_STRING :: 1_000_000
TRIALS   :: 5

// Prevent the optimizer from eliminating benchmark computations.
_sink: f64

// ── harness ───────────────────────────────────────────────────────────────────

report :: proc(key: string, ns: u64) {
	fmt.printf("%s=%d\n", key, ns)
}

median :: proc(times: []u64) -> u64 {
	slice.sort(times)
	return times[len(times) / 2]
}

bench :: proc(f: proc() -> u64) -> u64 {
	times := make([]u64, TRIALS)
	defer delete(times)
	for i in 0..<TRIALS { times[i] = f() }
	return median(times)
}

// ── array build ───────────────────────────────────────────────────────────────

bench_array_build :: proc() -> u64 {
	t0 := time.tick_now()
	b := oa.builder_make(i32, N_LARGE)
	for i in 0..<N_LARGE {
		if i % 100 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i32(i))
		}
	}
	arr, _ := oa.builder_finish(&b)
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	oa.array_free(&arr)
	oa.builder_destroy(&b)
	return ns
}

// ── sum ───────────────────────────────────────────────────────────────────────

bench_sum_f64_mt :: proc() -> u64 {
	b := oa.builder_make(f64, N_LARGE)
	for i in 0..<N_LARGE { oa.builder_append(&b, f64(i) * 0.001) }
	arr, _ := oa.builder_finish(&b)
	oa.builder_destroy(&b)

	t0 := time.tick_now()
	s, _ := oa.compute_sum_parallel(&arr)
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	_sink += s
	oa.array_free(&arr)
	return ns
}

bench_sum_i32_mt :: proc() -> u64 {
	b := oa.builder_make(i32, N_LARGE)
	for i in 0..<N_LARGE { oa.builder_append(&b, i32(i)) }
	arr, _ := oa.builder_finish(&b)
	oa.builder_destroy(&b)

	t0 := time.tick_now()
	s, _ := oa.compute_sum_parallel(&arr)
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	_sink += s
	oa.array_free(&arr)
	return ns
}

// ── min / max ─────────────────────────────────────────────────────────────────

bench_min_max_i32_mt :: proc() -> u64 {
	b := oa.builder_make(i32, N_LARGE)
	for i in 0..<N_LARGE { oa.builder_append(&b, i32(N_LARGE - i)) }
	arr, _ := oa.builder_finish(&b)
	oa.builder_destroy(&b)

	t0 := time.tick_now()
	mn, _ := oa.compute_min_parallel(&arr)
	mx, _ := oa.compute_max_parallel(&arr)
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	_sink += mn + mx
	oa.array_free(&arr)
	return ns
}

// ── filter ────────────────────────────────────────────────────────────────────

bench_filter_i32_mt :: proc() -> u64 {
	b := oa.builder_make(i32, N_LARGE)
	for i in 0..<N_LARGE { oa.builder_append(&b, i32(i)) }
	arr, _ := oa.builder_finish(&b)
	oa.builder_destroy(&b)

	mb := oa.builder_make(bool, N_LARGE)
	for i in 0..<N_LARGE { oa.builder_append(&mb, i % 2 == 0) }
	mask, _ := oa.builder_finish(&mb)
	oa.builder_destroy(&mb)

	t0 := time.tick_now()
	result, _ := oa.compute_filter_parallel(&arr, &mask)
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	oa.array_free(&result)
	oa.array_free(&arr)
	oa.array_free(&mask)
	return ns
}

// ── string build ──────────────────────────────────────────────────────────────

bench_string_build :: proc() -> u64 {
	t0 := time.tick_now()
	b := oa.string_builder_make(N_STRING)
	for i in 0..<N_STRING {
		if i % 50 == 0 {
			oa.string_builder_append_null(&b)
		} else {
			oa.string_builder_append(&b, "hello_world")
		}
	}
	arr, _ := oa.string_builder_finish(&b)
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	oa.array_free(&arr)
	oa.string_builder_destroy(&b)
	return ns
}

// ── string scan ───────────────────────────────────────────────────────────────

bench_string_scan :: proc() -> u64 {
	b := oa.string_builder_make(N_STRING)
	for i in 0..<N_STRING { oa.string_builder_append(&b, "hello_world") }
	arr, _ := oa.string_builder_finish(&b)
	oa.string_builder_destroy(&b)

	t0 := time.tick_now()
	total_len := 0
	for i in 0..<arr.length {
		s := oa.array_get_string(&arr, i)
		total_len += len(s)
	}
	ns := u64(time.duration_nanoseconds(time.tick_diff(t0, time.tick_now())))
	_sink += f64(total_len)
	oa.array_free(&arr)
	return ns
}

// ── main ──────────────────────────────────────────────────────────────────────

main :: proc() {
	report("array_build_10m_i32", bench(bench_array_build))
	report("sum_10m_f64_mt",      bench(bench_sum_f64_mt))
	report("sum_10m_i32_mt",      bench(bench_sum_i32_mt))
	report("min_max_10m_i32_mt",  bench(bench_min_max_i32_mt))
	report("filter_10m_i32_mt",   bench(bench_filter_i32_mt))
	report("string_build_1m",     bench(bench_string_build))
	report("string_scan_1m",      bench(bench_string_scan))
}
