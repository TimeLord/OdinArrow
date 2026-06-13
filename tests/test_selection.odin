package odinarrow_tests

import "core:testing"
import oa "../src"

// build an f64 array
sel_f64 :: proc(vals: []f64) -> oa.Array {
	b := oa.builder_make(f64, len(vals))
	defer oa.builder_destroy(&b)
	for v in vals { oa.builder_append(&b, v) }
	a, _ := oa.builder_finish(&b)
	return a
}

@(test)
test_selection_select_and_sum :: proc(t: ^testing.T) {
	vals := sel_f64([]f64{10, 20, 30, 40, 50, 60, 70})
	defer oa.array_free(&vals)
	// keep evens-by-index: 0,2,4,6  → 10,30,50,70
	mvals := []bool{true, false, true, false, true, false, true}
	mask := build_bool_mask(mvals)
	defer oa.array_free(&mask)

	sel := oa.compute_select(&mask)
	defer oa.selection_free(&sel)
	testing.expect_value(t, sel.length, 4)
	testing.expect_value(t, sel.indices[0], i32(0))
	testing.expect_value(t, sel.indices[3], i32(6))

	// aggregate through the selection (no materialisation)
	sum, vc := oa.compute_sum_selection(&vals, &sel)
	testing.expect_value(t, vc, 4)
	testing.expect(t, approx_eq(sum, 10+30+50+70, 1e-9))

	// materialise the selected column and check
	taken, _ := oa.selection_take(&vals, &sel)
	defer oa.array_free(&taken)
	testing.expect_value(t, taken.length, 4)
	testing.expect(t, approx_eq(oa.array_get(&taken, 0, f64), 10, 1e-9))
	testing.expect(t, approx_eq(oa.array_get(&taken, 3, f64), 70, 1e-9))
}

@(test)
test_record_batch_take :: proc(t: ^testing.T) {
	fields := []oa.Field{oa.field_make("a", oa.Int32_Type{}), oa.field_make("b", oa.Float64_Type{})}
	schema, _ := oa.schema_make(fields)
	defer oa.schema_free(&schema)

	ab := oa.builder_make(i32, 4); defer oa.builder_destroy(&ab)
	for v in ([]i32{1, 2, 3, 4}) { oa.builder_append(&ab, v) }
	acol, _ := oa.builder_finish(&ab)
	bcol := sel_f64([]f64{1.5, 2.5, 3.5, 4.5})
	cols := []oa.Array{acol, bcol}
	batch, _ := oa.record_batch_make(&schema, cols)
	defer oa.record_batch_free(&batch)

	mask := build_bool_mask([]bool{false, true, false, true})  // rows 1,3
	defer oa.array_free(&mask)
	sel := oa.compute_select(&mask)
	defer oa.selection_free(&sel)

	out, ok := oa.record_batch_take(&batch, &sel)
	testing.expect(t, ok)
	defer oa.record_batch_free(&out)
	testing.expect_value(t, out.length, 2)
	ca := oa.record_batch_column_at(&out, 0)
	cb := oa.record_batch_column_at(&out, 1)
	testing.expect_value(t, oa.array_get(ca, 0, i32), i32(2))
	testing.expect_value(t, oa.array_get(ca, 1, i32), i32(4))
	testing.expect(t, approx_eq(oa.array_get(cb, 1, f64), 4.5, 1e-9))
}

@(test)
test_sum_where_fused :: proc(t: ^testing.T) {
	vals := sel_f64([]f64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10})
	defer oa.array_free(&vals)
	mvals := []bool{true, false, true, false, true, false, true, false, true, false}  // 1,3,5,7,9
	mask := build_bool_mask(mvals)
	defer oa.array_free(&mask)

	sum, vc := oa.compute_sum_where(&vals, &mask)
	testing.expect_value(t, vc, 5)
	testing.expect(t, approx_eq(sum, 1+3+5+7+9, 1e-9))

	testing.expect_value(t, oa.compute_count_where(&mask), 5)

	// fused result must equal filter-then-sum
	filtered, _ := oa.compute_filter(&vals, &mask)
	defer oa.array_free(&filtered)
	fsum, _ := oa.compute_sum(&filtered)
	testing.expect(t, approx_eq(sum, fsum, 1e-9))
}

@(test)
test_fused_min_max_mean_where :: proc(t: ^testing.T) {
	vals := sel_f64([]f64{5, 1, 8, 3, 9, 2, 7, 4})
	defer oa.array_free(&vals)
	// keep idx 0,2,4,6 → 5,8,9,7
	mvals := []bool{true, false, true, false, true, false, true, false}
	mask := build_bool_mask(mvals)
	defer oa.array_free(&mask)

	lo, hi, vc := oa.compute_min_max_where(&vals, &mask)
	testing.expect_value(t, vc, 4)
	testing.expect(t, approx_eq(lo, 5, 1e-9))
	testing.expect(t, approx_eq(hi, 9, 1e-9))

	mn, _ := oa.compute_min_where(&vals, &mask)
	mx, _ := oa.compute_max_where(&vals, &mask)
	testing.expect(t, approx_eq(mn, 5, 1e-9))
	testing.expect(t, approx_eq(mx, 9, 1e-9))

	mean, _ := oa.compute_mean_where(&vals, &mask)
	testing.expect(t, approx_eq(mean, (5.0+8+9+7)/4, 1e-9))

	// selection-aware min/max must agree with the fused version
	sel := oa.compute_select(&mask)
	defer oa.selection_free(&sel)
	slo, shi, svc := oa.compute_min_max_selection(&vals, &sel)
	testing.expect_value(t, svc, 4)
	testing.expect(t, approx_eq(slo, 5, 1e-9))
	testing.expect(t, approx_eq(shi, 9, 1e-9))
	testing.expect_value(t, oa.compute_count_selection(&sel), 4)
}
