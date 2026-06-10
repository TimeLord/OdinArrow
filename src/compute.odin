package opyarrow

import "core:mem"

// ── sum ───────────────────────────────────────────────────────────────────────

// Sum of all non-null numeric elements, returned as f64.
// valid_count is the number of non-null elements that contributed.
compute_sum :: proc(arr: ^Array) -> (sum: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _sum_typed(arr, i8)
	case Int16_Type:   return _sum_typed(arr, i16)
	case Int32_Type:   return _sum_typed(arr, i32)
	case Int64_Type:   return _sum_typed(arr, i64)
	case UInt8_Type:   return _sum_typed(arr, u8)
	case UInt16_Type:  return _sum_typed(arr, u16)
	case UInt32_Type:  return _sum_typed(arr, u32)
	case UInt64_Type:  return _sum_typed(arr, u64)
	case Float32_Type: return _sum_typed(arr, f32)
	case Float64_Type: return _sum_typed(arr, f64)
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_sum: type does not support numeric summation")
	}
	return
}

_sum_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (sum: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if arr.buffers[0].data == nil {
		// No-null fast path: tight loop; LLVM auto-vectorises at -o:speed
		for i in 0..<n {
			sum += f64(data[off + i])
		}
		valid_count = n
	} else {
		for i in 0..<n {
			if array_is_valid(arr, i) {
				sum += f64(data[off + i])
				valid_count += 1
			}
		}
	}
	return
}

// ── min / max ─────────────────────────────────────────────────────────────────

// Minimum of all non-null elements. Returns (0, 0) when all elements are null.
compute_min :: proc(arr: ^Array) -> (min_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _min_typed(arr, i8)
	case Int16_Type:   return _min_typed(arr, i16)
	case Int32_Type:   return _min_typed(arr, i32)
	case Int64_Type:   return _min_typed(arr, i64)
	case UInt8_Type:   return _min_typed(arr, u8)
	case UInt16_Type:  return _min_typed(arr, u16)
	case UInt32_Type:  return _min_typed(arr, u32)
	case UInt64_Type:  return _min_typed(arr, u64)
	case Float32_Type: return _min_typed(arr, f32)
	case Float64_Type: return _min_typed(arr, f64)
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_min: type does not support ordering")
	}
	return
}

// Maximum of all non-null elements.
compute_max :: proc(arr: ^Array) -> (max_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _max_typed(arr, i8)
	case Int16_Type:   return _max_typed(arr, i16)
	case Int32_Type:   return _max_typed(arr, i32)
	case Int64_Type:   return _max_typed(arr, i64)
	case UInt8_Type:   return _max_typed(arr, u8)
	case UInt16_Type:  return _max_typed(arr, u16)
	case UInt32_Type:  return _max_typed(arr, u32)
	case UInt64_Type:  return _max_typed(arr, u64)
	case Float32_Type: return _max_typed(arr, f32)
	case Float64_Type: return _max_typed(arr, f64)
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_max: type does not support ordering")
	}
	return
}

_min_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (min_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	for i in 0..<arr.length {
		if array_is_valid(arr, i) {
			v := f64(data[off + i])
			if valid_count == 0 || v < min_val {
				min_val = v
			}
			valid_count += 1
		}
	}
	return
}

_max_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (max_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	for i in 0..<arr.length {
		if array_is_valid(arr, i) {
			v := f64(data[off + i])
			if valid_count == 0 || v > max_val {
				max_val = v
			}
			valid_count += 1
		}
	}
	return
}

// ── mean ──────────────────────────────────────────────────────────────────────

// Mean of all non-null numeric elements. Returns (0, 0) when all null.
compute_mean :: proc(arr: ^Array) -> (mean: f64, valid_count: int) {
	sum: f64
	sum, valid_count = compute_sum(arr)
	if valid_count > 0 {
		mean = sum / f64(valid_count)
	}
	return
}

// ── count ─────────────────────────────────────────────────────────────────────

// Count total elements and non-null (valid) elements.
compute_count :: proc(arr: ^Array) -> (total: int, valid: int) {
	total = arr.length
	nc    := array_null_count(arr)
	valid  = total - nc
	return
}

// ── filter ────────────────────────────────────────────────────────────────────

// Apply a Bool mask to arr, returning a new Array with only the passing rows.
// mask must be Bool_Type and have the same length as arr.
// Null mask entries are treated as false (element excluded).
compute_filter :: proc(arr, mask: ^Array, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	assert(arr.length == mask.length, "compute_filter: length mismatch")
	_, is_bool := mask.type.(Bool_Type)
	assert(is_bool, "compute_filter: mask must be Bool type")

	switch _ in arr.type {
	case Int8_Type:    return _filter_typed(arr, mask, i8,  allocator)
	case Int16_Type:   return _filter_typed(arr, mask, i16, allocator)
	case Int32_Type:   return _filter_typed(arr, mask, i32, allocator)
	case Int64_Type:   return _filter_typed(arr, mask, i64, allocator)
	case UInt8_Type:   return _filter_typed(arr, mask, u8,  allocator)
	case UInt16_Type:  return _filter_typed(arr, mask, u16, allocator)
	case UInt32_Type:  return _filter_typed(arr, mask, u32, allocator)
	case UInt64_Type:  return _filter_typed(arr, mask, u64, allocator)
	case Float32_Type: return _filter_typed(arr, mask, f32, allocator)
	case Float64_Type: return _filter_typed(arr, mask, f64, allocator)
	case Bool_Type:    return _filter_bool(arr, mask, allocator)
	case String_Type:  return _filter_string(arr, mask, allocator)
	case Binary_Type:  return _filter_binary(arr, mask, allocator)
	case Null_Type, Large_String_Type, Large_Binary_Type:
		panic("compute_filter: unsupported source type")
	}
	return
}

_mask_passes :: #force_inline proc "contextless" (mask: ^Array, i: int) -> bool {
	return array_is_valid(mask, i) && bitmap_get(mask.buffers[1].data, mask.offset + i)
}

_filter_typed :: proc(arr, mask: ^Array, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := builder_make(T, 0, allocator)
	defer builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				builder_append_null(&b)
			} else {
				builder_append(&b, array_get(arr, i, T))
			}
		}
	}
	return builder_finish(&b, allocator)
}

_filter_bool :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := builder_make(bool, 0, allocator)
	defer builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				builder_append_null(&b)
			} else {
				builder_append(&b, array_get(arr, i, bool))
			}
		}
	}
	return builder_finish(&b, allocator)
}

_filter_string :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := string_builder_make(0, allocator)
	defer string_builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				string_builder_append_null(&b)
			} else {
				string_builder_append(&b, array_get_string(arr, i))
			}
		}
	}
	return string_builder_finish(&b, allocator)
}

_filter_binary :: proc(arr, mask: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := binary_builder_make(0, allocator)
	defer binary_builder_destroy(&b)
	for i in 0..<arr.length {
		if _mask_passes(mask, i) {
			if array_is_null(arr, i) {
				binary_builder_append_null(&b)
			} else {
				binary_builder_append(&b, array_get_binary(arr, i))
			}
		}
	}
	return binary_builder_finish(&b, allocator)
}
