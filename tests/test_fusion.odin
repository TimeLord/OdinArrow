package odinarrow_tests

import "core:testing"
import oa "../src"

@(test)
test_agg_where_compare_fused :: proc(t: ^testing.T) {
	vb := oa.builder_make(f64, 8); defer oa.builder_destroy(&vb)
	pb := oa.builder_make(f64, 8); defer oa.builder_destroy(&pb)
	vvals := []f64{10, 20, 30, 40, 50, 60, 70, 80}
	pvals := []f64{ 1,  9,  9,  1,  9,  9,  1,  9}
	for v in vvals { oa.builder_append(&vb, v) }
	for v in pvals { oa.builder_append(&pb, v) }
	values, _ := oa.builder_finish(&vb); defer oa.array_free(&values)
	pred, _   := oa.builder_finish(&pb); defer oa.array_free(&pred)

	// WHERE pred > 5 → rows 1,2,4,5,7 → values 20,30,50,60,80
	a := oa.compute_agg_where_compare(&values, &pred, .Gt, 5)
	testing.expect(t, a.valid)
	testing.expect_value(t, a.count, 5)
	testing.expect(t, approx_eq(a.sum, 20+30+50+60+80, 1e-9))
	testing.expect(t, approx_eq(a.min_val, 20, 1e-9))
	testing.expect(t, approx_eq(a.max_val, 80, 1e-9))

	// must agree with the unfused kernels
	mask, _ := oa.compute_compare(&pred, .Gt, 5); defer oa.array_free(&mask)
	s, _ := oa.compute_sum_where(&values, &mask)
	lo, hi, vc := oa.compute_min_max_where(&values, &mask)
	testing.expect(t, approx_eq(a.sum, s, 1e-9))
	testing.expect(t, approx_eq(a.min_val, lo, 1e-9))
	testing.expect(t, approx_eq(a.max_val, hi, 1e-9))
	testing.expect_value(t, a.count, vc)

	// empty result (no match)
	none := oa.compute_agg_where_compare(&values, &pred, .Gt, 1000)
	testing.expect(t, !none.valid)
	testing.expect_value(t, none.count, 0)
}
