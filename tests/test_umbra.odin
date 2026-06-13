package odinarrow_tests

import "core:testing"
import "core:slice"
import oa "../src"

@(test)
test_umbra_inline_and_long :: proc(t: ^testing.T) {
	b := oa.umbra_builder_make()
	defer oa.umbra_builder_destroy(&b)
	vals := []string{
		"",                       // empty
		"hi",                     // short inline
		"twelve_bytes",           // exactly 12 (inline boundary)
		"this is a long string",  // > 12 (uses prefix + data buffer)
		"αβγ",                    // multibyte, short
	}
	for v in vals { oa.umbra_append(&b, v) }
	a := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&a)

	testing.expect_value(t, a.length, len(vals))
	for v, i in vals {
		testing.expect_value(t, oa.umbra_get(&a, i), v)
		testing.expect_value(t, oa.umbra_length(&a, i), len(v))
	}
}

@(test)
test_umbra_compare_and_count :: proc(t: ^testing.T) {
	b := oa.umbra_builder_make()
	defer oa.umbra_builder_destroy(&b)
	vals := []string{"banana", "apple", "apricot", "banana", "cherry"}
	for v in vals { oa.umbra_append(&b, v) }
	a := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&a)

	// compare returns sign of lexicographic order
	testing.expect(t, oa.umbra_compare(&a, 1, 0) < 0)  // apple < banana
	testing.expect(t, oa.umbra_compare(&a, 1, 2) < 0)  // apple < apricot (prefix tie on "app")
	testing.expect(t, oa.umbra_compare(&a, 0, 3) == 0) // banana == banana
	testing.expect(t, oa.umbra_compare(&a, 4, 0) > 0)  // cherry > banana

	testing.expect_value(t, oa.umbra_count_eq(&a, "banana"), 2)
	testing.expect_value(t, oa.umbra_count_eq(&a, "apple"), 1)
	testing.expect_value(t, oa.umbra_count_eq(&a, "missing"), 0)
}

// Sort a deterministic pseudo-random set of long strings and verify the result
// is fully sorted and matches a reference sort of the same strings.
@(test)
test_umbra_sort :: proc(t: ^testing.T) {
	N :: 500
	raw := make([]string, N)
	defer { for s in raw { delete(s) }; delete(raw) }
	b := oa.umbra_builder_make()
	defer oa.umbra_builder_destroy(&b)
	for i in 0..<N {
		// 16-char strings (all "long") with varied prefixes
		buf := make([]u8, 16)
		x := u32(i*2654435761) // knuth hash for spread
		for k in 0..<16 { buf[k] = u8('a' + (x >> uint(k)) % 26) }
		raw[i] = string(buf)
		oa.umbra_append(&b, raw[i])
	}
	a := oa.umbra_builder_finish(&b)
	defer oa.umbra_free(&a)

	idx := oa.umbra_sort_indices(&a)
	defer oa.array_free(&idx)
	testing.expect_value(t, idx.length, N)

	// result is non-decreasing
	for k in 1..<N {
		prev := oa.umbra_get(&a, int(oa.array_get(&idx, k-1, i64)))
		cur  := oa.umbra_get(&a, int(oa.array_get(&idx, k,   i64)))
		testing.expect(t, prev <= cur, "umbra sort not ordered")
	}

	// matches a reference sort of the same strings
	ref := make([]string, N); defer delete(ref)
	copy(ref, raw)
	slice.sort(ref)
	for k in 0..<N {
		got := oa.umbra_get(&a, int(oa.array_get(&idx, k, i64)))
		testing.expect_value(t, got, ref[k])
	}
}
