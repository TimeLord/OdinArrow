package odinarrow_tests

import "core:mem"
import "core:testing"
import oa "../src"

// ── String: basic roundtrip ───────────────────────────────────────────────────

@(test)
test_string_roundtrip_no_nulls :: proc(t: ^testing.T) {
	words := []string{"hello", "world", "odin", "arrow"}
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	for w in words {
		oa.string_builder_append(&b, w)
	}
	arr, err := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect(t, err == nil)
	_, is_str := arr.type.(oa.String_Type)
	testing.expect(t, is_str, "type must be String_Type")
	testing.expect_value(t, arr.length, 4)
	testing.expect_value(t, arr.null_count, 0)
	testing.expect(t, arr.buffers[0].data == nil, "no validity bitmap when no nulls")

	for w, i in words {
		testing.expect_value(t, oa.array_get_string(&arr, i), w)
	}
}

// ── String: nulls ─────────────────────────────────────────────────────────────

@(test)
test_string_with_nulls :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "first")
	oa.string_builder_append_null(&b)
	oa.string_builder_append(&b, "third")
	oa.string_builder_append_null(&b)

	arr, err := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)

	testing.expect_value(t, arr.length, 4)
	testing.expect_value(t, arr.null_count, 2)
	testing.expect(t, arr.buffers[0].data != nil, "validity bitmap must exist")

	testing.expect(t, oa.array_is_valid(&arr, 0))
	testing.expect(t, oa.array_is_null(&arr, 1))
	testing.expect(t, oa.array_is_valid(&arr, 2))
	testing.expect(t, oa.array_is_null(&arr, 3))

	testing.expect_value(t, oa.array_get_string(&arr, 0), "first")
	testing.expect_value(t, oa.array_get_string(&arr, 2), "third")
}

// ── String: empty string element ─────────────────────────────────────────────

@(test)
test_string_empty_element :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "")
	oa.string_builder_append(&b, "x")
	oa.string_builder_append(&b, "")

	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect_value(t, oa.array_get_string(&arr, 0), "")
	testing.expect_value(t, oa.array_get_string(&arr, 1), "x")
	testing.expect_value(t, oa.array_get_string(&arr, 2), "")
}

// ── String: zero-copy view into buffer ───────────────────────────────────────

@(test)
test_string_is_zero_copy :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	oa.string_builder_append(&b, "hello")

	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	s := oa.array_get_string(&arr, 0)
	// The string data pointer must lie inside buffers[2]
	s_start := uintptr(raw_data(transmute([]u8)s))
	buf_start := uintptr(arr.buffers[2].data)
	buf_end   := buf_start + uintptr(arr.buffers[2].size)
	testing.expect(t, s_start >= buf_start && s_start < buf_end, "string must point into data buffer")
}

// ── String: slice (zero-copy) ─────────────────────────────────────────────────

@(test)
test_string_slice :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)
	strs := []string{"a", "bb", "ccc", "dddd", "eeeee"}
	for s in strs {
		oa.string_builder_append(&b, s)
	}
	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	sl := oa.array_slice(arr, 1, 4) // ["bb", "ccc", "dddd"]
	testing.expect_value(t, sl.length, 3)
	testing.expect_value(t, oa.array_get_string(&sl, 0), "bb")
	testing.expect_value(t, oa.array_get_string(&sl, 1), "ccc")
	testing.expect_value(t, oa.array_get_string(&sl, 2), "dddd")
}

// ── String: reset and reuse ───────────────────────────────────────────────────

@(test)
test_string_builder_reset :: proc(t: ^testing.T) {
	b := oa.string_builder_make()
	defer oa.string_builder_destroy(&b)

	oa.string_builder_append(&b, "round1")
	arr1, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr1)

	oa.string_builder_reset(&b)
	oa.string_builder_append(&b, "round2")
	arr2, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr2)

	testing.expect_value(t, oa.array_get_string(&arr2, 0), "round2")
}

// ── String: no memory leaks ───────────────────────────────────────────────────

@(test)
test_string_no_leak :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	b := oa.string_builder_make()
	oa.string_builder_append(&b, "hello")
	oa.string_builder_append_null(&b)
	oa.string_builder_append(&b, "world")
	arr, _ := oa.string_builder_finish(&b)
	oa.string_builder_destroy(&b)
	oa.array_free(&arr)
}

// ── Binary ────────────────────────────────────────────────────────────────────

@(test)
test_binary_roundtrip :: proc(t: ^testing.T) {
	b := oa.binary_builder_make()
	defer oa.binary_builder_destroy(&b)
	oa.binary_builder_append(&b, []u8{0xDE, 0xAD})
	oa.binary_builder_append_null(&b)
	oa.binary_builder_append(&b, []u8{0xBE, 0xEF, 0xFF})

	arr, err := oa.binary_builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)

	_, is_bin := arr.type.(oa.Binary_Type)
	testing.expect(t, is_bin, "type must be Binary_Type")
	testing.expect_value(t, arr.length, 3)
	testing.expect_value(t, arr.null_count, 1)

	got0 := oa.array_get_binary(&arr, 0)
	testing.expect_value(t, len(got0), 2)
	testing.expect_value(t, got0[0], u8(0xDE))
	testing.expect_value(t, got0[1], u8(0xAD))

	testing.expect(t, oa.array_is_null(&arr, 1))

	got2 := oa.array_get_binary(&arr, 2)
	testing.expect_value(t, len(got2), 3)
	testing.expect_value(t, got2[2], u8(0xFF))
}

// ── Large string array (1M entries) ──────────────────────────────────────────

@(test)
test_string_large :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.string_builder_make(n)
	defer oa.string_builder_destroy(&b)
	for i in 0..<n {
		if i % 50 == 0 {
			oa.string_builder_append_null(&b)
		} else {
			oa.string_builder_append(&b, "hello")
		}
	}
	arr, err := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)
	testing.expect_value(t, arr.length, n)
	testing.expect_value(t, arr.null_count, n / 50)
	testing.expect(t, oa.array_is_null(&arr, 0))
	testing.expect_value(t, oa.array_get_string(&arr, 1), "hello")
}
