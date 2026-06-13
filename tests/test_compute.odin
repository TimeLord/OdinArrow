package odinarrow_tests

import "core:testing"
import oa "../src"

// ── helpers ───────────────────────────────────────────────────────────────────

build_bool_mask :: proc(pass: []bool) -> oa.Array {
	b := oa.builder_make(bool)
	defer oa.builder_destroy(&b)
	for v in pass {
		oa.builder_append(&b, v)
	}
	arr, _ := oa.builder_finish(&b)
	return arr
}

approx_eq :: proc(a, b, eps: f64) -> bool {
	d := a - b
	return d >= -eps && d <= eps
}

// ── sum ───────────────────────────────────────────────────────────────────────

@(test)
test_compute_sum_i32 :: proc(t: ^testing.T) {
	arr := build_array([]i32{1, 2, 3, 4, 5})
	defer oa.array_free(&arr)
	sum, n := oa.compute_sum(&arr)
	testing.expect_value(t, sum, f64(15))
	testing.expect_value(t, n, 5)
}

@(test)
test_compute_sum_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(10))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(20))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, n := oa.compute_sum(&arr)
	testing.expect_value(t, sum, f64(30))
	testing.expect_value(t, n, 2)
}

@(test)
test_compute_sum_f64 :: proc(t: ^testing.T) {
	arr := build_array([]f64{1.5, 2.5, 3.0})
	defer oa.array_free(&arr)
	sum, _ := oa.compute_sum(&arr)
	testing.expect(t, approx_eq(sum, 7.0, 1e-12))
}

@(test)
test_compute_sum_empty :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)
	sum, n := oa.compute_sum(&arr)
	testing.expect_value(t, sum, f64(0))
	testing.expect_value(t, n, 0)
}

// ── min / max ─────────────────────────────────────────────────────────────────

@(test)
test_compute_min_max_i32 :: proc(t: ^testing.T) {
	arr := build_array([]i32{5, 1, 8, 3, 2})
	defer oa.array_free(&arr)
	mn, mn_n := oa.compute_min(&arr)
	mx, mx_n := oa.compute_max(&arr)
	testing.expect_value(t, mn, f64(1))
	testing.expect_value(t, mn_n, 5)
	testing.expect_value(t, mx, f64(8))
	testing.expect_value(t, mx_n, 5)
}

@(test)
test_compute_min_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(7))
	oa.builder_append_null(&b)
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mn, n := oa.compute_min(&arr)
	testing.expect_value(t, mn, f64(7))
	testing.expect_value(t, n, 1)
}

@(test)
test_compute_min_all_null :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append_null(&b)
	oa.builder_append_null(&b)
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	_, n := oa.compute_min(&arr)
	testing.expect_value(t, n, 0)
}

// ── mean ──────────────────────────────────────────────────────────────────────

@(test)
test_compute_mean :: proc(t: ^testing.T) {
	arr := build_array([]f64{1.0, 2.0, 3.0, 4.0, 5.0})
	defer oa.array_free(&arr)
	mean, n := oa.compute_mean(&arr)
	testing.expect(t, approx_eq(mean, 3.0, 1e-12))
	testing.expect_value(t, n, 5)
}

@(test)
test_compute_mean_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(f64)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, f64(10.0))
	oa.builder_append_null(&b)
	oa.builder_append(&b, f64(20.0))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mean, n := oa.compute_mean(&arr)
	testing.expect(t, approx_eq(mean, 15.0, 1e-12))
	testing.expect_value(t, n, 2)
}

// ── count ─────────────────────────────────────────────────────────────────────

@(test)
test_compute_count :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	total, valid := oa.compute_count(&arr)
	testing.expect_value(t, total, 3)
	testing.expect_value(t, valid, 2)
}

// ── filter ────────────────────────────────────────────────────────────────────

@(test)
test_filter_basic :: proc(t: ^testing.T) {
	arr  := build_array([]i32{10, 20, 30, 40, 50})
	mask := build_bool_mask([]bool{true, false, true, false, true})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, err := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect(t, err == nil)
	testing.expect_value(t, result.length, 3)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(10))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(30))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(50))
}

@(test)
test_filter_null_in_source :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	src, _ := oa.builder_finish(&b)
	defer oa.array_free(&src)

	mask := build_bool_mask([]bool{true, true, true})
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&src, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	testing.expect(t, oa.array_is_valid(&result, 0))
	testing.expect(t, oa.array_is_null(&result, 1))
	testing.expect(t, oa.array_is_valid(&result, 2))
}

@(test)
test_filter_null_in_mask :: proc(t: ^testing.T) {
	// Null mask entries → exclude element (treated as false)
	src := build_array([]i32{1, 2, 3})
	defer oa.array_free(&src)

	bm := oa.builder_make(bool)
	defer oa.builder_destroy(&bm)
	oa.builder_append(&bm, true)
	oa.builder_append_null(&bm) // null mask → exclude
	oa.builder_append(&bm, true)
	mask, _ := oa.builder_finish(&bm)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&src, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 2)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(1))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(3))
}

@(test)
test_filter_all_false :: proc(t: ^testing.T) {
	arr  := build_array([]i32{1, 2, 3})
	mask := build_bool_mask([]bool{false, false, false})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 0)
}

@(test)
test_filter_all_true :: proc(t: ^testing.T) {
	vals := []i32{7, 8, 9}
	arr  := build_array(vals)
	mask := build_bool_mask([]bool{true, true, true})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	check_values(t, &result, vals)
}

@(test)
test_filter_float64 :: proc(t: ^testing.T) {
	arr  := build_array([]f64{1.1, 2.2, 3.3, 4.4})
	mask := build_bool_mask([]bool{false, true, false, true})
	defer oa.array_free(&arr)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 2)
	testing.expect(t, approx_eq(oa.array_get(&result, 0, f64), 2.2, 1e-12))
	testing.expect(t, approx_eq(oa.array_get(&result, 1, f64), 4.4, 1e-12))
}

@(test)
test_filter_string :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "keep")
	oa.string_builder_append(&b, "drop")
	oa.string_builder_append(&b, "keep2")
	src, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&src)

	mask := build_bool_mask([]bool{true, false, true})
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&src, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 2)
	testing.expect_value(t, oa.array_get_string(&result, 0), "keep")
	testing.expect_value(t, oa.array_get_string(&result, 1), "keep2")
}

// ── large array compute ───────────────────────────────────────────────────────

@(test)
test_compute_sum_large :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n {
		oa.builder_append(&b, i32(i))
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, valid := oa.compute_sum(&arr)
	expected := f64(n) * f64(n - 1) / 2.0
	testing.expect(t, approx_eq(sum, expected, 1.0), "sum must match arithmetic series formula")
	testing.expect_value(t, valid, n)
}

@(test)
test_compute_min_max_large :: proc(t: ^testing.T) {
	n :: 100_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n {
		oa.builder_append(&b, i32(n - i)) // n, n-1, ..., 1
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mn, _ := oa.compute_min(&arr)
	mx, _ := oa.compute_max(&arr)
	testing.expect_value(t, mn, f64(1))
	testing.expect_value(t, mx, f64(n))
}

@(test)
test_compute_filter_large :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	for i in 0..<n { oa.builder_append(&b, i32(i)) }
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	mb := oa.builder_make(bool, n)
	defer oa.builder_destroy(&mb)
	for i in 0..<n { oa.builder_append(&mb, i % 2 == 0) } // even elements pass
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	result, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, n / 2)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(0))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(2))
}

// ── min_max (single pass) ─────────────────────────────────────────────────────

@(test)
test_compute_min_max :: proc(t: ^testing.T) {
	arr := build_array([]i32{5, 1, 9, 3, 7})
	defer oa.array_free(&arr)
	lo, hi, n := oa.compute_min_max(&arr)
	testing.expect_value(t, lo, f64(1))
	testing.expect_value(t, hi, f64(9))
	testing.expect_value(t, n, 5)
}

@(test)
test_compute_min_max_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(10))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	oa.builder_append(&b, i32(8))
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	lo, hi, n := oa.compute_min_max(&arr)
	testing.expect_value(t, lo, f64(3))
	testing.expect_value(t, hi, f64(10))
	testing.expect_value(t, n, 3)
}

// ── take ──────────────────────────────────────────────────────────────────────

@(test)
test_compute_take :: proc(t: ^testing.T) {
	src := build_array([]i32{10, 20, 30, 40, 50})
	defer oa.array_free(&src)

	ib := oa.builder_make(i64)
	defer oa.builder_destroy(&ib)
	oa.builder_append(&ib, i64(4))
	oa.builder_append(&ib, i64(1))
	oa.builder_append(&ib, i64(3))
	idx, _ := oa.builder_finish(&ib)
	defer oa.array_free(&idx)

	result, _ := oa.compute_take(&src, &idx)
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(50))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(20))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(40))
}

// ── cast ──────────────────────────────────────────────────────────────────────

@(test)
test_compute_cast_i32_to_f64 :: proc(t: ^testing.T) {
	src := build_array([]i32{1, 2, 3})
	defer oa.array_free(&src)

	result, _ := oa.compute_cast(&src, oa.Float64_Type{})
	defer oa.array_free(&result)
	testing.expect_value(t, result.length, 3)
	testing.expect(t, approx_eq(oa.array_get(&result, 0, f64), 1.0, 1e-10))
	testing.expect(t, approx_eq(oa.array_get(&result, 2, f64), 3.0, 1e-10))
}

// ── arithmetic ────────────────────────────────────────────────────────────────

@(test)
test_compute_add :: proc(t: ^testing.T) {
	a := build_array([]i32{1, 2, 3})
	b := build_array([]i32{10, 20, 30})
	defer oa.array_free(&a); defer oa.array_free(&b)

	result, _ := oa.compute_add(&a, &b)
	defer oa.array_free(&result)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(11))
	testing.expect_value(t, oa.array_get(&result, 1, i32), i32(22))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(33))
}

@(test)
test_compute_arithmetic_null_propagation :: proc(t: ^testing.T) {
	ab := oa.builder_make(i32)
	defer oa.builder_destroy(&ab)
	oa.builder_append(&ab, i32(5))
	oa.builder_append_null(&ab)
	oa.builder_append(&ab, i32(7))
	a, _ := oa.builder_finish(&ab)
	defer oa.array_free(&a)

	b := build_array([]i32{1, 2, 3})
	defer oa.array_free(&b)

	result, _ := oa.compute_add(&a, &b)
	defer oa.array_free(&result)
	testing.expect_value(t, oa.array_get(&result, 0, i32), i32(6))
	testing.expect(t, oa.array_is_null(&result, 1))
	testing.expect_value(t, oa.array_get(&result, 2, i32), i32(10))
}

// ── sort_indices ──────────────────────────────────────────────────────────────

@(test)
test_sort_indices_i32 :: proc(t: ^testing.T) {
	a := build_array([]i32{30, 10, 20, 10, 40})
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	// Ascending order; ties (two 10s at positions 1 and 3) stay in input order.
	testing.expect_value(t, idx.length, 5)
	testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 1, i64), i64(3))
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(2))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(0))
	testing.expect_value(t, oa.array_get(&idx, 4, i64), i64(4))

	// Feeding the indices into take yields a sorted array.
	sorted, _ := oa.compute_take(&a, &idx)
	defer oa.array_free(&sorted)
	testing.expect_value(t, oa.array_get(&sorted, 0, i32), i32(10))
	testing.expect_value(t, oa.array_get(&sorted, 1, i32), i32(10))
	testing.expect_value(t, oa.array_get(&sorted, 2, i32), i32(20))
	testing.expect_value(t, oa.array_get(&sorted, 3, i32), i32(30))
	testing.expect_value(t, oa.array_get(&sorted, 4, i32), i32(40))
}

@(test)
test_sort_indices_nulls_last :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(5))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	a, _ := oa.builder_finish(&b)
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	// Non-null ascending first: 1(@2), 3(@4), 5(@0); then nulls in order: @1, @3.
	testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(2))
	testing.expect_value(t, oa.array_get(&idx, 1, i64), i64(4))
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(0))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 4, i64), i64(3))
}

@(test)
test_sort_indices_string :: proc(t: ^testing.T) {
	sb := oa.string_builder_make()
	defer oa.string_builder_destroy(&sb)
	oa.string_builder_append(&sb, "pear")
	oa.string_builder_append(&sb, "apple")
	oa.string_builder_append(&sb, "cherry")
	oa.string_builder_append(&sb, "apple")
	a, _ := oa.string_builder_finish(&sb)
	defer oa.array_free(&a)

	idx, _ := oa.compute_sort_indices(&a)
	defer oa.array_free(&idx)

	// apple(@1), apple(@3) stable, cherry(@2), pear(@0)
	testing.expect_value(t, oa.array_get(&idx, 0, i64), i64(1))
	testing.expect_value(t, oa.array_get(&idx, 1, i64), i64(3))
	testing.expect_value(t, oa.array_get(&idx, 2, i64), i64(2))
	testing.expect_value(t, oa.array_get(&idx, 3, i64), i64(0))
}

// ── null-aware aggregation (B2) ─────────────────────────────────────────────────

// Build an f64 array with a deterministic sparse-null pattern and check the
// bulk null-aware kernels against a scalar reference. N is not a multiple of 8,
// so the run/mixed-byte/tail paths are all exercised.
@(test)
test_agg_with_nulls_matches_scalar :: proc(t: ^testing.T) {
	N :: 1003
	b := oa.builder_make(f64, N)
	defer oa.builder_destroy(&b)

	ref_sum:   f64 = 0.0
	ref_min:   f64 = 1e18
	ref_max:   f64 = -1e18
	ref_valid: int = 0
	for i in 0..<N {
		if (i * 7 + 3) % 13 == 0 {
			oa.builder_append_null(&b)
		} else {
			v := f64((i * 131) % 997) - 500.0
			oa.builder_append(&b, v)
			ref_sum += v
			if v < ref_min { ref_min = v }
			if v > ref_max { ref_max = v }
			ref_valid += 1
		}
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, vc := oa.compute_sum(&arr)
	testing.expect_value(t, vc, ref_valid)
	testing.expect(t, approx_eq(sum, ref_sum, 1e-6))

	lo, hi, vc2 := oa.compute_min_max(&arr)
	testing.expect_value(t, vc2, ref_valid)
	testing.expect(t, approx_eq(lo, ref_min, 1e-9))
	testing.expect(t, approx_eq(hi, ref_max, 1e-9))

	mn, _ := oa.compute_min(&arr)
	mx, _ := oa.compute_max(&arr)
	testing.expect(t, approx_eq(mn, ref_min, 1e-9))
	testing.expect(t, approx_eq(mx, ref_max, 1e-9))
}

// Same idea for i32 (exercises the SIMD run reducers) plus an all-null array.
@(test)
test_agg_with_nulls_i32_and_empty :: proc(t: ^testing.T) {
	N :: 512
	b := oa.builder_make(i32, N)
	defer oa.builder_destroy(&b)
	ref_sum := 0.0; ref_lo := 1 << 30; ref_hi := -(1 << 30); ref_valid := 0
	for i in 0..<N {
		if i % 5 == 0 {
			oa.builder_append_null(&b)
		} else {
			v := (i * 37) % 251 - 120
			oa.builder_append(&b, i32(v))
			ref_sum += f64(v)
			if v < ref_lo { ref_lo = v }
			if v > ref_hi { ref_hi = v }
			ref_valid += 1
		}
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	sum, vc := oa.compute_sum(&arr)
	testing.expect_value(t, vc, ref_valid)
	testing.expect(t, approx_eq(sum, ref_sum, 1e-9))
	lo, hi, _ := oa.compute_min_max(&arr)
	testing.expect(t, approx_eq(lo, f64(ref_lo), 1e-9))
	testing.expect(t, approx_eq(hi, f64(ref_hi), 1e-9))

	// All-null array: valid_count 0, no crash.
	nb := oa.builder_make(i32, 20)
	defer oa.builder_destroy(&nb)
	for _ in 0..<20 { oa.builder_append_null(&nb) }
	na, _ := oa.builder_finish(&nb)
	defer oa.array_free(&na)
	s2, v2 := oa.compute_sum(&na)
	testing.expect_value(t, v2, 0)
	testing.expect(t, approx_eq(s2, 0.0, 1e-12))
}

// A sliced array exercises both the byte-aligned (offset 8) bulk path and the
// unaligned (offset 3) fallback path.
@(test)
test_agg_with_nulls_sliced :: proc(t: ^testing.T) {
	N :: 200
	b := oa.builder_make(f64, N)
	defer oa.builder_destroy(&b)
	for i in 0..<N {
		if i % 11 == 0 { oa.builder_append_null(&b) }
		else           { oa.builder_append(&b, f64(i)) }
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	check :: proc(t: ^testing.T, a: ^oa.Array) {
		ref_sum := 0.0; ref_valid := 0
		for i in 0..<a.length {
			if !oa.array_is_null(a, i) { ref_sum += oa.array_get(a, i, f64); ref_valid += 1 }
		}
		sum, vc := oa.compute_sum(a)
		testing.expect_value(t, vc, ref_valid)
		testing.expect(t, approx_eq(sum, ref_sum, 1e-6))
	}

	s_aligned := oa.array_slice(arr, 8, 180)   // offset 8  → bulk path
	check(t, &s_aligned)
	s_unaligned := oa.array_slice(arr, 3, 175)  // offset 3  → fallback path
	check(t, &s_unaligned)
}
