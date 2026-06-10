package odinarrow_tests

import "core:testing"
import oa "../src"

// Parallel kernels must agree with the serial kernels for any input size,
// including lengths above PARALLEL_MIN_LENGTH (so the threaded path runs)
// and lengths that don't divide evenly across threads.

PAR_N :: oa.PARALLEL_MIN_LENGTH + 12_345 // odd size: uneven chunks

build_large_i32 :: proc(with_nulls: bool) -> oa.Array {
	b := oa.builder_make(i32, PAR_N)
	defer oa.builder_destroy(&b)
	for i in 0..<PAR_N {
		if with_nulls && i % 97 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i32(i % 1000) - 500)
		}
	}
	arr, _ := oa.builder_finish(&b)
	return arr
}

@(test)
test_parallel_sum_matches_serial :: proc(t: ^testing.T) {
	arr := build_large_i32(false)
	defer oa.array_free(&arr)

	s_sum, s_n := oa.compute_sum(&arr)
	p_sum, p_n := oa.compute_sum_parallel(&arr, 4)
	testing.expect_value(t, p_sum, s_sum)
	testing.expect_value(t, p_n, s_n)
}

@(test)
test_parallel_sum_with_nulls :: proc(t: ^testing.T) {
	arr := build_large_i32(true)
	defer oa.array_free(&arr)

	s_sum, s_n := oa.compute_sum(&arr)
	p_sum, p_n := oa.compute_sum_parallel(&arr, 3)
	testing.expect_value(t, p_sum, s_sum)
	testing.expect_value(t, p_n, s_n)
}

@(test)
test_parallel_min_max :: proc(t: ^testing.T) {
	arr := build_large_i32(true)
	defer oa.array_free(&arr)

	s_min, s_minn := oa.compute_min(&arr)
	p_min, p_minn := oa.compute_min_parallel(&arr, 4)
	testing.expect_value(t, p_min, s_min)
	testing.expect_value(t, p_minn, s_minn)

	s_max, s_maxn := oa.compute_max(&arr)
	p_max, p_maxn := oa.compute_max_parallel(&arr, 4)
	testing.expect_value(t, p_max, s_max)
	testing.expect_value(t, p_maxn, s_maxn)
}

@(test)
test_parallel_small_falls_back :: proc(t: ^testing.T) {
	arr := build_array([]i32{1, 2, 3, 4, 5})
	defer oa.array_free(&arr)
	sum, n := oa.compute_sum_parallel(&arr, 4)
	testing.expect_value(t, sum, f64(15))
	testing.expect_value(t, n, 5)
}

@(test)
test_parallel_filter_matches_serial :: proc(t: ^testing.T) {
	arr := build_large_i32(true)
	defer oa.array_free(&arr)

	mb := oa.builder_make(bool, PAR_N)
	defer oa.builder_destroy(&mb)
	for i in 0..<PAR_N {
		oa.builder_append(&mb, i % 3 == 0)
	}
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	s, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&s)
	p, _ := oa.compute_filter_parallel(&arr, &mask, 4)
	defer oa.array_free(&p)

	testing.expect_value(t, p.length, s.length)
	testing.expect_value(t, oa.array_null_count(&p), oa.array_null_count(&s))
	for i in 0..<s.length {
		sv, s_ok := oa.array_try_get(&s, i, i32)
		pv, p_ok := oa.array_try_get(&p, i, i32)
		testing.expect_value(t, p_ok, s_ok)
		if s_ok {
			testing.expect_value(t, pv, sv)
		}
	}
}

@(test)
test_parallel_filter_bool :: proc(t: ^testing.T) {
	b := oa.builder_make(bool, PAR_N)
	defer oa.builder_destroy(&b)
	for i in 0..<PAR_N {
		if i % 53 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i % 2 == 0)
		}
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mb := oa.builder_make(bool, PAR_N)
	defer oa.builder_destroy(&mb)
	for i in 0..<PAR_N {
		oa.builder_append(&mb, i % 7 != 0)
	}
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	s, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&s)
	p, _ := oa.compute_filter_parallel(&arr, &mask, 4)
	defer oa.array_free(&p)

	testing.expect_value(t, p.length, s.length)
	for i in 0..<s.length {
		sv, s_ok := oa.array_try_get(&s, i, bool)
		pv, p_ok := oa.array_try_get(&p, i, bool)
		testing.expect_value(t, p_ok, s_ok)
		if s_ok {
			testing.expect_value(t, pv, sv)
		}
	}
}
