package odinarrow_tests

import "core:testing"
import oa "../src"

mk_str_arr :: proc(vals: []string) -> oa.Array {
	b := oa.string_builder_make(len(vals))
	defer oa.string_builder_destroy(&b)
	for v in vals { oa.string_builder_append(&b, v) }
	arr, _ := oa.string_builder_finish(&b)
	return arr
}

@(test)
test_dict_encode_decode :: proc(t: ^testing.T) {
	vals := []string{"red", "green", "red", "blue", "green", "red"}
	src := mk_str_arr(vals)
	defer oa.array_free(&src)

	d := oa.str_dict_encode(&src)
	defer oa.str_dict_free(&d)

	testing.expect_value(t, d.length, len(vals))
	testing.expect_value(t, oa.n_dict(&d), 3)   // red, green, blue

	for v, i in vals {
		testing.expect_value(t, oa.str_dict_get(&d, i), v)
	}

	dec, _ := oa.str_dict_decode(&d)
	defer oa.array_free(&dec)
	testing.expect_value(t, dec.length, len(vals))
	for v, i in vals {
		testing.expect_value(t, oa.array_get_string(&dec, i), v)
	}
}

@(test)
test_dict_value_counts :: proc(t: ^testing.T) {
	vals := []string{"red", "green", "red", "blue", "green", "red"}
	src := mk_str_arr(vals)
	defer oa.array_free(&src)
	d := oa.str_dict_encode(&src)
	defer oa.str_dict_free(&d)

	counts := oa.str_dict_value_counts(&d)
	defer delete(counts)

	// total must equal length, and per-value counts must match
	total := i64(0)
	for c in counts { total += c }
	testing.expect_value(t, total, i64(len(vals)))

	// look up each value's code via the dictionary and check its count
	want := make(map[string]i64)
	defer delete(want)
	want["red"] = 3; want["green"] = 2; want["blue"] = 1
	for ci in 0..<oa.n_dict(&d) {
		name := oa.array_get_string(&d.dict, ci)
		testing.expect_value(t, counts[ci], want[name])
	}
}

@(test)
test_dict_group_sum :: proc(t: ^testing.T) {
	keys := mk_str_arr([]string{"a", "b", "a", "a", "b"})
	defer oa.array_free(&keys)
	d := oa.str_dict_encode(&keys)
	defer oa.str_dict_free(&d)

	wb := oa.builder_make(f64, 5)
	defer oa.builder_destroy(&wb)
	wvals := []f64{1, 2, 3, 4, 5}
	for v in wvals { oa.builder_append(&wb, v) }
	w, _ := oa.builder_finish(&wb)
	defer oa.array_free(&w)

	sums := oa.str_dict_group_sum(&d, &w)
	defer delete(sums)

	for ci in 0..<oa.n_dict(&d) {
		name := oa.array_get_string(&d.dict, ci)
		if name == "a" { testing.expect(t, approx_eq(sums[ci], 1+3+4, 1e-9)) }  // 8
		if name == "b" { testing.expect(t, approx_eq(sums[ci], 2+5, 1e-9)) }    // 7
	}
}

@(test)
test_dict_numeric :: proc(t: ^testing.T) {
	// logical: 5,2,5,9,2,5,9  → dict {5,2,9}, codes by first-seen
	vb := oa.builder_make(f64, 7)
	defer oa.builder_destroy(&vb)
	vals := []f64{5, 2, 5, 9, 2, 5, 9}
	for v in vals { oa.builder_append(&vb, v) }
	src, _ := oa.builder_finish(&vb)
	defer oa.array_free(&src)

	d := oa.dict_encode(&src, f64)
	defer oa.dict_free(&d)
	testing.expect_value(t, d.length, 7)
	testing.expect_value(t, oa.dict_size(&d), 3)

	for v, i in vals { testing.expect(t, approx_eq(oa.dict_get(&d, i), v, 1e-9)) }

	// sum / min_max via the encoded kernels
	testing.expect(t, approx_eq(oa.dict_sum(&d), 5+2+5+9+2+5+9, 1e-9))
	lo, hi, ok := oa.dict_min_max(&d)
	testing.expect(t, ok)
	testing.expect(t, approx_eq(lo, 2, 1e-9))
	testing.expect(t, approx_eq(hi, 9, 1e-9))

	// value_counts: 5×3, 2×2, 9×2
	counts := oa.dict_value_counts(&d)
	defer delete(counts)
	total := i64(0)
	for c in counts { total += c }
	testing.expect_value(t, total, i64(7))

	// decode round-trip
	dec, _ := oa.dict_decode(&d)
	defer oa.array_free(&dec)
	for v, i in vals { testing.expect(t, approx_eq(oa.array_get(&dec, i, f64), v, 1e-9)) }
}
