package odinarrow_tests

import "core:testing"
import oa "../src"

@(test)
test_compute_compare_mask :: proc(t: ^testing.T) {
	a := build_array([]i32{1, 5, 3, 8, 2, 9})
	defer oa.array_free(&a)
	mask, _ := oa.compute_compare(&a, .Gt, 4)   // > 4 → 5,8,9 at idx 1,3,5
	defer oa.array_free(&mask)
	testing.expect_value(t, oa.compute_count_where(&mask), 3)
	testing.expect(t, !oa.array_is_null(&mask, 0))
	testing.expect(t, oa.array_get(&mask, 1, bool))
	testing.expect(t, !oa.array_get(&mask, 2, bool))
	testing.expect(t, oa.array_get(&mask, 3, bool))
}

@(test)
test_select_and_refine_compare :: proc(t: ^testing.T) {
	a := build_array([]i32{10, 2, 30, 4, 50, 6, 70, 8})
	defer oa.array_free(&a)
	b := build_array([]i32{ 1, 1,  1, 9,  9, 9,  1, 9})
	defer oa.array_free(&b)

	// a > 9  → idx 0,2,4,6  (values 10,30,50,70)
	sel := oa.compute_select_compare(&a, .Gt, 9)
	defer oa.selection_free(&sel)
	testing.expect_value(t, sel.length, 4)

	// refine: AND b > 5 → among {0,2,4,6}, b is {1,1,9,1} → only idx 4 survives
	sel2 := oa.selection_refine_compare(&sel, &b, .Gt, 5)
	defer oa.selection_free(&sel2)
	testing.expect_value(t, sel2.length, 1)
	testing.expect_value(t, sel2.indices[0], i32(4))

	// sum a through the refined selection → a[4] == 50
	s, vc := oa.compute_sum_selection(&a, &sel2)
	testing.expect_value(t, vc, 1)
	testing.expect(t, approx_eq(s, 50, 1e-9))
}

// The chained-selection result must equal the materialised AND-of-masks result.
@(test)
test_chained_selection_matches_materialised :: proc(t: ^testing.T) {
	N :: 1000
	ab := oa.builder_make(f64, N); defer oa.builder_destroy(&ab)
	bb := oa.builder_make(f64, N); defer oa.builder_destroy(&bb)
	cb := oa.builder_make(f64, N); defer oa.builder_destroy(&cb)
	for i in 0..<N {
		oa.builder_append(&ab, f64((i * 37) % 100))
		oa.builder_append(&bb, f64((i * 53) % 100))
		oa.builder_append(&cb, f64(i))
	}
	a, _ := oa.builder_finish(&ab); defer oa.array_free(&a)
	b, _ := oa.builder_finish(&bb); defer oa.array_free(&b)
	c, _ := oa.builder_finish(&cb); defer oa.array_free(&c)

	// chained selection: a > 50 AND b > 30, sum c
	sel := oa.compute_select_compare(&a, .Gt, 50)
	defer oa.selection_free(&sel)
	sel2 := oa.selection_refine_compare(&sel, &b, .Gt, 30)
	defer oa.selection_free(&sel2)
	chained, _ := oa.compute_sum_selection(&c, &sel2)

	// reference: scalar loop
	ref := 0.0
	for i in 0..<N {
		if oa.array_get(&a, i, f64) > 50 && oa.array_get(&b, i, f64) > 30 { ref += oa.array_get(&c, i, f64) }
	}
	testing.expect(t, approx_eq(chained, ref, 1e-6))
}
