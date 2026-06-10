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
