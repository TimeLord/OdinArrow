package opyarrow_tests

import "core:math"
import "core:mem"
import "core:testing"
import oa "../src"

// ── generic helpers ───────────────────────────────────────────────────────────

// Build an array from a plain slice, no nulls.
build_array :: proc(vals: []$T, allocator := context.allocator) -> oa.Array {
	b := oa.builder_make(T, len(vals), allocator)
	defer oa.builder_destroy(&b)
	for v in vals {
		oa.builder_append(&b, v)
	}
	arr, _ := oa.builder_finish(&b, allocator)
	return arr
}

// Verify every element of arr matches vals and is non-null.
check_values :: proc(t: ^testing.T, arr: ^oa.Array, vals: []$T) {
	testing.expect_value(t, arr.length, len(vals))
	for i in 0..<len(vals) {
		testing.expect(t, oa.array_is_valid(arr, i), "element must be valid")
		testing.expect_value(t, oa.array_get(arr, i, T), vals[i])
	}
}

// ── type metadata ─────────────────────────────────────────────────────────────

@(test)
test_type_names :: proc(t: ^testing.T) {
	cases := [][2]string{
		{oa.type_name(oa.Int32_Type{}),   "int32"},
		{oa.type_name(oa.Float64_Type{}), "float64"},
		{oa.type_name(oa.Bool_Type{}),    "bool"},
		{oa.type_name(oa.UInt8_Type{}),   "uint8"},
	}
	for c in cases {
		testing.expect_value(t, c[0], c[1])
	}
}

@(test)
test_type_byte_width :: proc(t: ^testing.T) {
	testing.expect_value(t, oa.type_byte_width(oa.Int8_Type{}),    1)
	testing.expect_value(t, oa.type_byte_width(oa.Int16_Type{}),   2)
	testing.expect_value(t, oa.type_byte_width(oa.Int32_Type{}),   4)
	testing.expect_value(t, oa.type_byte_width(oa.Int64_Type{}),   8)
	testing.expect_value(t, oa.type_byte_width(oa.Float32_Type{}), 4)
	testing.expect_value(t, oa.type_byte_width(oa.Float64_Type{}), 8)
	testing.expect_value(t, oa.type_byte_width(oa.Bool_Type{}),    0)
}

@(test)
test_type_predicates :: proc(t: ^testing.T) {
	testing.expect(t, oa.type_is_integer(oa.Int32_Type{}))
	testing.expect(t, oa.type_is_integer(oa.UInt64_Type{}))
	testing.expect(t, !oa.type_is_integer(oa.Float32_Type{}))
	testing.expect(t, oa.type_is_signed(oa.Int64_Type{}))
	testing.expect(t, !oa.type_is_signed(oa.UInt32_Type{}))
	testing.expect(t, oa.type_is_floating(oa.Float64_Type{}))
	testing.expect(t, !oa.type_is_floating(oa.Int32_Type{}))
	testing.expect(t, oa.type_is_bit_packed(oa.Bool_Type{}))
	testing.expect(t, !oa.type_is_bit_packed(oa.Int32_Type{}))
}

// ── i32 roundtrip (no nulls) ──────────────────────────────────────────────────

@(test)
test_i32_roundtrip_no_nulls :: proc(t: ^testing.T) {
	vals := []i32{0, 1, -1, 100, max(i32), min(i32)}
	arr := build_array(vals)
	defer oa.array_free(&arr)

	_, is_int32 := arr.type.(oa.Int32_Type)
	testing.expect(t, is_int32, "type must be Int32_Type")
	testing.expect_value(t, arr.null_count, 0)
	testing.expect(t, arr.buffers[0].data == nil, "no validity bitmap when null_count == 0")
	check_values(t, &arr, vals)
}

// ── i32 with nulls ────────────────────────────────────────────────────────────

@(test)
test_i32_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)

	oa.builder_append(&b, i32(10))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(30))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(50))

	arr, err := oa.builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)

	testing.expect_value(t, arr.length, 5)
	testing.expect_value(t, arr.null_count, 2)
	testing.expect(t, arr.buffers[0].data != nil, "validity bitmap must exist when there are nulls")

	testing.expect(t, oa.array_is_valid(&arr, 0))
	testing.expect(t, oa.array_is_null(&arr, 1))
	testing.expect(t, oa.array_is_valid(&arr, 2))
	testing.expect(t, oa.array_is_null(&arr, 3))
	testing.expect(t, oa.array_is_valid(&arr, 4))

	testing.expect_value(t, oa.array_get(&arr, 0, i32), i32(10))
	testing.expect_value(t, oa.array_get(&arr, 2, i32), i32(30))
	testing.expect_value(t, oa.array_get(&arr, 4, i32), i32(50))
}

// ── try_get ───────────────────────────────────────────────────────────────────

@(test)
test_try_get_null :: proc(t: ^testing.T) {
	b := oa.builder_make(f64)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, f64(3.14))
	oa.builder_append_null(&b)

	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	v0, ok0 := oa.array_try_get(&arr, 0, f64)
	testing.expect(t, ok0, "element 0 must be valid")
	testing.expect_value(t, v0, f64(3.14))

	_, ok1 := oa.array_try_get(&arr, 1, f64)
	testing.expect(t, !ok1, "element 1 must be null")
}

// ── null_count recomputation ──────────────────────────────────────────────────

@(test)
test_null_count_recompute :: proc(t: ^testing.T) {
	b := oa.builder_make(i64)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i64(1))
	oa.builder_append_null(&b)
	oa.builder_append_null(&b)
	oa.builder_append(&b, i64(4))

	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	// Force recount by setting null_count to -1
	arr.null_count = -1
	got := oa.array_null_count(&arr)
	testing.expect_value(t, got, 2)
	testing.expect_value(t, arr.null_count, 2) // cached after recount
}

// ── zero-copy slice ───────────────────────────────────────────────────────────

@(test)
test_slice_shares_memory :: proc(t: ^testing.T) {
	vals := []i32{10, 20, 30, 40, 50}
	arr := build_array(vals)
	defer oa.array_free(&arr)

	sl := oa.array_slice(arr, 1, 4) // [20, 30, 40]
	testing.expect_value(t, sl.length, 3)
	testing.expect_value(t, sl.offset, 1)

	// Same data pointer — no copy
	testing.expect(
		t,
		sl.buffers[1].data == arr.buffers[1].data,
		"slice must point into parent data buffer",
	)

	testing.expect_value(t, oa.array_get(&sl, 0, i32), i32(20))
	testing.expect_value(t, oa.array_get(&sl, 1, i32), i32(30))
	testing.expect_value(t, oa.array_get(&sl, 2, i32), i32(40))
}

@(test)
test_slice_null_count_unknown :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, i32(1))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(3))
	oa.builder_append_null(&b)
	oa.builder_append(&b, i32(5))

	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	// Slice [null, 3, null] — elements 1,2,3
	sl := oa.array_slice(arr, 1, 4)
	testing.expect_value(t, sl.null_count, -1) // unknown until recounted

	got := oa.array_null_count(&sl)
	testing.expect_value(t, got, 2)
}

@(test)
test_slice_free_does_not_affect_parent :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	vals := []i32{1, 2, 3, 4, 5}
	arr := build_array(vals)

	sl := oa.array_slice(arr, 0, 3)
	oa.array_free(&sl) // must NOT free parent's buffers

	// Parent still valid
	testing.expect_value(t, oa.array_get(&arr, 0, i32), i32(1))
	oa.array_free(&arr) // single free — no double-free
}

// ── empty array ───────────────────────────────────────────────────────────────

@(test)
test_empty_array :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	arr, err := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect(t, err == nil)
	testing.expect_value(t, arr.length, 0)
	testing.expect_value(t, arr.null_count, 0)
}

// ── all numeric types ─────────────────────────────────────────────────────────

roundtrip :: proc(t: ^testing.T, vals: []$T) {
	b := oa.builder_make(T)
	defer oa.builder_destroy(&b)
	for v in vals {
		oa.builder_append(&b, v)
	}
	arr, err := oa.builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)
	check_values(t, &arr, vals)
}

@(test) test_i8_roundtrip  :: proc(t: ^testing.T) { roundtrip(t, []i8{-128, 0, 127}) }
@(test) test_i16_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []i16{min(i16), 0, max(i16)}) }
@(test) test_i32_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []i32{-1, 0, 1, 1_000_000}) }
@(test) test_i64_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []i64{min(i64), -1, 0, max(i64)}) }
@(test) test_u8_roundtrip  :: proc(t: ^testing.T) { roundtrip(t, []u8{0, 128, 255}) }
@(test) test_u16_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []u16{0, max(u16)}) }
@(test) test_u32_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []u32{0, max(u32)}) }
@(test) test_u64_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []u64{0, max(u64)}) }
@(test) test_f32_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []f32{0, -1.5, 3.14, math.F32_MAX}) }
@(test) test_f64_roundtrip :: proc(t: ^testing.T) { roundtrip(t, []f64{0, -1.5, 3.14, math.F64_MAX}) }

// ── bool array ────────────────────────────────────────────────────────────────

@(test)
test_bool_roundtrip_no_nulls :: proc(t: ^testing.T) {
	vals := []bool{true, false, true, true, false}
	b := oa.builder_make(bool)
	defer oa.builder_destroy(&b)
	for v in vals {
		oa.builder_append(&b, v)
	}
	arr, err := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect(t, err == nil)
	_, is_bool := arr.type.(oa.Bool_Type)
	testing.expect(t, is_bool, "type must be Bool_Type")
	testing.expect_value(t, arr.length, 5)
	testing.expect_value(t, arr.null_count, 0)

	for v, i in vals {
		testing.expect_value(t, oa.array_get(&arr, i, bool), v)
	}
}

@(test)
test_bool_with_nulls :: proc(t: ^testing.T) {
	b := oa.builder_make(bool)
	defer oa.builder_destroy(&b)
	oa.builder_append(&b, true)
	oa.builder_append_null(&b)
	oa.builder_append(&b, false)

	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect_value(t, arr.null_count, 1)
	testing.expect(t, oa.array_is_valid(&arr, 0))
	testing.expect(t, oa.array_is_null(&arr, 1))
	testing.expect(t, oa.array_is_valid(&arr, 2))
	testing.expect_value(t, oa.array_get(&arr, 0, bool), true)
	testing.expect_value(t, oa.array_get(&arr, 2, bool), false)
}

@(test)
test_bool_bit_packing_boundary :: proc(t: ^testing.T) {
	// Exactly 9 elements: crosses the 8-bit boundary
	vals := []bool{true, false, true, false, true, false, true, false, true}
	arr := build_array(vals)
	defer oa.array_free(&arr)

	for v, i in vals {
		testing.expect_value(t, oa.array_get(&arr, i, bool), v)
	}
}

// ── builder reset and reuse ───────────────────────────────────────────────────

@(test)
test_builder_reset_reuse :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)

	// First build
	oa.builder_append(&b, i32(1))
	oa.builder_append(&b, i32(2))
	arr1, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr1)
	testing.expect_value(t, arr1.length, 2)

	// Reset and build again
	oa.builder_reset(&b)
	oa.builder_append(&b, i32(99))
	arr2, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr2)

	testing.expect_value(t, arr2.length, 1)
	testing.expect_value(t, oa.array_get(&arr2, 0, i32), i32(99))
}

// ── all-null array ────────────────────────────────────────────────────────────

@(test)
test_all_null :: proc(t: ^testing.T) {
	b := oa.builder_make(i32)
	defer oa.builder_destroy(&b)
	oa.builder_append_null(&b)
	oa.builder_append_null(&b)
	oa.builder_append_null(&b)

	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	testing.expect_value(t, arr.length, 3)
	testing.expect_value(t, arr.null_count, 3)
	for i in 0..<3 {
		testing.expect(t, oa.array_is_null(&arr, i))
	}
}

// ── data alignment ────────────────────────────────────────────────────────────

@(test)
test_array_data_buffer_aligned :: proc(t: ^testing.T) {
	vals := []i64{1, 2, 3}
	arr := build_array(vals)
	defer oa.array_free(&arr)

	testing.expect(
		t,
		uintptr(arr.buffers[1].data) % oa.ARROW_ALIGNMENT == 0,
		"data buffer must be 64-byte aligned",
	)
}

// ── array_copy (deep copy) ────────────────────────────────────────────────────

@(test)
test_array_copy_is_independent :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	vals := []i32{7, 8, 9}
	orig := build_array(vals)

	cpy, err := oa.array_copy(&orig)
	testing.expect(t, err == nil)

	// Corrupt source data buffer — copy must be unaffected
	orig.buffers[1].data[0] = 0xFF
	orig.buffers[1].data[1] = 0xFF
	orig.buffers[1].data[2] = 0xFF
	orig.buffers[1].data[3] = 0xFF
	testing.expect_value(t, oa.array_get(&cpy, 0, i32), i32(7))

	oa.array_free(&orig)
	oa.array_free(&cpy)
}

// ── large array (exercises aligned realloc path) ──────────────────────────────

@(test)
test_large_array_1m :: proc(t: ^testing.T) {
	n :: 1_000_000
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)

	for i in 0..<n {
		if i % 100 == 0 {
			oa.builder_append_null(&b)
		} else {
			oa.builder_append(&b, i32(i))
		}
	}

	arr, err := oa.builder_finish(&b)
	defer oa.array_free(&arr)
	testing.expect(t, err == nil)
	testing.expect_value(t, arr.length, n)
	testing.expect_value(t, arr.null_count, n / 100)

	// Spot check
	testing.expect(t, oa.array_is_null(&arr, 0))
	testing.expect(t, oa.array_is_valid(&arr, 1))
	testing.expect_value(t, oa.array_get(&arr, 1, i32), i32(1))
}
