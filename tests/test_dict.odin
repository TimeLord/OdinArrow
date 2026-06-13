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
