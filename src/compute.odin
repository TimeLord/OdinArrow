package odinarrow

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
		when T == f64 {
			sum = off == 0 ? _sum_f64_simd(data, n) : _sum_f64_simd(data[off:], n)
		} else when T == i32 {
			sum = f64(off == 0 ? _sum_i32_simd(data, n) : _sum_i32_simd(data[off:], n))
		} else {
			for i in 0..<n { sum += f64(data[off + i]) }
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

// Comparisons run in the native element type T (not f64): converting per
// element blocks integer SIMD and costs ~7x on large arrays. The single
// f64 conversion happens once, on the final result.
_min_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (min_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if n == 0 do return
	best: T
	if arr.buffers[0].data == nil {
		when T == i32 {
			best = off == 0 ? _min_i32_simd(data, n) : _min_i32_simd(data[off:], n)
		} else {
			best = data[off]
			for i in 1..<n { best = min(best, data[off + i]) }
		}
		valid_count = n
	} else {
		for i in 0..<n {
			if array_is_valid(arr, i) {
				v := data[off + i]
				if valid_count == 0 || v < best { best = v }
				valid_count += 1
			}
		}
	}
	if valid_count > 0 { min_val = f64(best) }
	return
}

_max_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (max_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if n == 0 do return
	best: T
	if arr.buffers[0].data == nil {
		when T == i32 {
			best = off == 0 ? _max_i32_simd(data, n) : _max_i32_simd(data[off:], n)
		} else {
			best = data[off]
			for i in 1..<n { best = max(best, data[off + i]) }
		}
		valid_count = n
	} else {
		for i in 0..<n {
			if array_is_valid(arr, i) {
				v := data[off + i]
				if valid_count == 0 || v > best { best = v }
				valid_count += 1
			}
		}
	}
	if valid_count > 0 { max_val = f64(best) }
	return
}

// ── min_max (single pass) ─────────────────────────────────────────────────────

// Min and max in one pass — ~2× faster than calling compute_min + compute_max.
compute_min_max :: proc(arr: ^Array) -> (min_val: f64, max_val: f64, valid_count: int) {
	switch _ in arr.type {
	case Int8_Type:    return _min_max_typed(arr, i8)
	case Int16_Type:   return _min_max_typed(arr, i16)
	case Int32_Type:   return _min_max_typed(arr, i32)
	case Int64_Type:   return _min_max_typed(arr, i64)
	case UInt8_Type:   return _min_max_typed(arr, u8)
	case UInt16_Type:  return _min_max_typed(arr, u16)
	case UInt32_Type:  return _min_max_typed(arr, u32)
	case UInt64_Type:  return _min_max_typed(arr, u64)
	case Float32_Type: return _min_max_typed(arr, f32)
	case Float64_Type: return _min_max_typed(arr, f64)
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_min_max: type does not support ordering")
	}
	return
}

_min_max_typed :: #force_inline proc(arr: ^Array, $T: typeid) -> (min_val: f64, max_val: f64, valid_count: int) {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	n    := arr.length
	if n == 0 { return }
	lo, hi: T
	if arr.buffers[0].data == nil {
		when T == i32 {
			if off == 0 {
				lo, hi = _min_max_i32_simd(data, n)
			} else {
				lo, hi = _min_max_i32_simd(data[off:], n)
			}
		} else {
			lo = data[off]; hi = data[off]
			for i in 1..<n {
				v := data[off + i]
				if v < lo { lo = v }
				if v > hi { hi = v }
			}
		}
		valid_count = n
	} else {
		for i in 0..<n {
			if array_is_valid(arr, i) {
				v := data[off + i]
				if valid_count == 0 || v < lo { lo = v }
				if valid_count == 0 || v > hi { hi = v }
				valid_count += 1
			}
		}
	}
	if valid_count > 0 { min_val = f64(lo); max_val = f64(hi) }
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
	n         := arr.length
	mask_bits := mask.buffers[1].data
	arr_off   := arr.offset
	mask_off  := mask.offset

	// No-null fast path: skip the builder entirely — allocate exact output size and
	// write values directly. Avoids per-element bitmap maintenance and dynamic-array overhead.
	if arr.buffers[0].data == nil && mask.buffers[0].data == nil {
		out_count := _filter_count_bits(mask_bits, mask_off, n)
		data_buf  := buffer_make(out_count * size_of(T), allocator) or_return
		src  := cast([^]T)arr.buffers[1].data
		dst  := cast([^]T)data_buf.data
		out_i := 0
		if mask_off == 0 {
			// Byte-at-a-time: read 8 mask bits at once to reduce branch mispredictions.
			n_full := (n / 8) * 8
			for i := 0; i < n_full; i += 8 {
				byte := mask_bits[i >> 3]
				if byte == 0 { continue }
				for bit in u8(0)..<8 {
					if (byte >> bit) & 1 == 1 {
						dst[out_i] = src[arr_off + i + int(bit)]
						out_i += 1
					}
				}
			}
			for i := n_full; i < n; i += 1 {
				if bitmap_get(mask_bits, i) {
					dst[out_i] = src[arr_off + i]
					out_i += 1
				}
			}
		} else {
			for i in 0..<n {
				if bitmap_get(mask_bits, mask_off + i) {
					dst[out_i] = src[arr_off + i]
					out_i += 1
				}
			}
		}
		result = Array{
			type    = _data_type_for(T),
			length  = out_count,
			buffers = {{}, data_buf, {}},
		}
		return
	}

	// General path (source or mask has nulls): builder with upper-bound capacity.
	b := builder_make(T, n, allocator)
	defer builder_destroy(&b)
	for i in 0..<n {
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

// Count set bits in mask_bits in the range [off, off+n).
_filter_count_bits :: proc "contextless" (mask_bits: [^]u8, off, n: int) -> int {
	if off == 0 {
		return bitmap_popcount(mask_bits, n)
	}
	count := 0
	for i in 0..<n {
		if bitmap_get(mask_bits, off + i) { count += 1 }
	}
	return count
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

// ── take ──────────────────────────────────────────────────────────────────────

// Return a new array containing arr[indices[i]] for each i.
// indices must be Int64_Type; out-of-range indices panic.
compute_take :: proc(arr, indices: ^Array, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	_, ok := indices.type.(Int64_Type)
	assert(ok, "compute_take: indices must be Int64_Type")
	switch _ in arr.type {
	case Int8_Type:    return _take_typed(arr, indices, i8,  allocator)
	case Int16_Type:   return _take_typed(arr, indices, i16, allocator)
	case Int32_Type:   return _take_typed(arr, indices, i32, allocator)
	case Int64_Type:   return _take_typed(arr, indices, i64, allocator)
	case UInt8_Type:   return _take_typed(arr, indices, u8,  allocator)
	case UInt16_Type:  return _take_typed(arr, indices, u16, allocator)
	case UInt32_Type:  return _take_typed(arr, indices, u32, allocator)
	case UInt64_Type:  return _take_typed(arr, indices, u64, allocator)
	case Float32_Type: return _take_typed(arr, indices, f32, allocator)
	case Float64_Type: return _take_typed(arr, indices, f64, allocator)
	case Bool_Type:    return _take_typed(arr, indices, bool, allocator)
	case String_Type:  return _take_string(arr, indices, allocator)
	case Binary_Type:  return _take_binary(arr, indices, allocator)
	case Null_Type, Large_String_Type, Large_Binary_Type:
		panic("compute_take: unsupported type")
	}
	return
}

_take_typed :: proc(arr, indices: ^Array, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := indices.length
	b := builder_make(T, n, allocator)
	defer builder_destroy(&b)
	for i in 0..<n {
		idx := int(array_get(indices, i, i64))
		if array_is_null(arr, idx) {
			builder_append_null(&b)
		} else {
			builder_append(&b, array_get(arr, idx, T))
		}
	}
	return builder_finish(&b, allocator)
}

_take_string :: proc(arr, indices: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := indices.length
	b := string_builder_make(n, allocator)
	defer string_builder_destroy(&b)
	for i in 0..<n {
		idx := int(array_get(indices, i, i64))
		if array_is_null(arr, idx) {
			string_builder_append_null(&b)
		} else {
			string_builder_append(&b, array_get_string(arr, idx))
		}
	}
	return string_builder_finish(&b, allocator)
}

_take_binary :: proc(arr, indices: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := indices.length
	b := binary_builder_make(n, allocator)
	defer binary_builder_destroy(&b)
	for i in 0..<n {
		idx := int(array_get(indices, i, i64))
		if array_is_null(arr, idx) {
			binary_builder_append_null(&b)
		} else {
			binary_builder_append(&b, array_get_binary(arr, idx))
		}
	}
	return binary_builder_finish(&b, allocator)
}

// ── cast ──────────────────────────────────────────────────────────────────────

// Cast arr to a different numeric type.  Supports all numeric → numeric conversions.
// String and Bool types are not supported.
compute_cast :: proc(arr: ^Array, to: DataType, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in to {
	case Int8_Type:    return _cast_to_typed(arr, i8,  allocator)
	case Int16_Type:   return _cast_to_typed(arr, i16, allocator)
	case Int32_Type:   return _cast_to_typed(arr, i32, allocator)
	case Int64_Type:   return _cast_to_typed(arr, i64, allocator)
	case UInt8_Type:   return _cast_to_typed(arr, u8,  allocator)
	case UInt16_Type:  return _cast_to_typed(arr, u16, allocator)
	case UInt32_Type:  return _cast_to_typed(arr, u32, allocator)
	case UInt64_Type:  return _cast_to_typed(arr, u64, allocator)
	case Float32_Type: return _cast_to_typed(arr, f32, allocator)
	case Float64_Type: return _cast_to_typed(arr, f64, allocator)
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_cast: unsupported target type")
	}
	return
}

_cast_to_typed :: proc(arr: ^Array, $To: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := arr.length
	b := builder_make(To, n, allocator)
	defer builder_destroy(&b)
	for i in 0..<n {
		if array_is_null(arr, i) {
			builder_append_null(&b)
		} else {
			builder_append(&b, To(_element_as_f64(arr, i)))
		}
	}
	return builder_finish(&b, allocator)
}

_element_as_f64 :: #force_inline proc "contextless" (arr: ^Array, i: int) -> f64 {
	idx := arr.offset + i
	switch _ in arr.type {
	case Int8_Type:    return f64((cast([^]i8) arr.buffers[1].data)[idx])
	case Int16_Type:   return f64((cast([^]i16)arr.buffers[1].data)[idx])
	case Int32_Type:   return f64((cast([^]i32)arr.buffers[1].data)[idx])
	case Int64_Type:   return f64((cast([^]i64)arr.buffers[1].data)[idx])
	case UInt8_Type:   return f64(arr.buffers[1].data[idx])
	case UInt16_Type:  return f64((cast([^]u16)arr.buffers[1].data)[idx])
	case UInt32_Type:  return f64((cast([^]u32)arr.buffers[1].data)[idx])
	case UInt64_Type:  return f64((cast([^]u64)arr.buffers[1].data)[idx])
	case Float32_Type: return f64((cast([^]f32)arr.buffers[1].data)[idx])
	case Float64_Type: return (cast([^]f64)arr.buffers[1].data)[idx]
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
	}
	return 0
}

// ── arithmetic (element-wise) ─────────────────────────────────────────────────

Arithmetic_Op :: enum { Add, Sub, Mul, Div }

// Element-wise arithmetic on two numeric arrays of the same type.
// Result type matches the input type.  Null propagates: if either element is
// null the output element is null.
compute_arithmetic :: proc(left, right: ^Array, op: Arithmetic_Op, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	assert(left.length == right.length, "compute_arithmetic: length mismatch")
	switch _ in left.type {
	case Int8_Type:    return _arith_typed(left, right, i8,  op, allocator)
	case Int16_Type:   return _arith_typed(left, right, i16, op, allocator)
	case Int32_Type:   return _arith_typed(left, right, i32, op, allocator)
	case Int64_Type:   return _arith_typed(left, right, i64, op, allocator)
	case UInt8_Type:   return _arith_typed(left, right, u8,  op, allocator)
	case UInt16_Type:  return _arith_typed(left, right, u16, op, allocator)
	case UInt32_Type:  return _arith_typed(left, right, u32, op, allocator)
	case UInt64_Type:  return _arith_typed(left, right, u64, op, allocator)
	case Float32_Type: return _arith_typed(left, right, f32, op, allocator)
	case Float64_Type: return _arith_typed(left, right, f64, op, allocator)
	case Null_Type, Bool_Type,
	     String_Type, Large_String_Type,
	     Binary_Type, Large_Binary_Type:
		panic("compute_arithmetic: unsupported type")
	}
	return
}

_arith_typed :: proc(left, right: ^Array, $T: typeid, op: Arithmetic_Op, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := left.length
	b := builder_make(T, n, allocator)
	defer builder_destroy(&b)
	for i in 0..<n {
		if array_is_null(left, i) || array_is_null(right, i) {
			builder_append_null(&b)
			continue
		}
		l := array_get(left, i, T)
		r := array_get(right, i, T)
		v: T
		switch op {
		case .Add: v = l + r
		case .Sub: v = l - r
		case .Mul: v = l * r
		case .Div: v = l / r
		}
		builder_append(&b, v)
	}
	return builder_finish(&b, allocator)
}

// Convenience wrappers.
compute_add :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Add, allocator)
}
compute_sub :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Sub, allocator)
}
compute_mul :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Mul, allocator)
}
compute_div :: proc(left, right: ^Array, allocator := context.allocator) -> (Array, mem.Allocator_Error) {
	return compute_arithmetic(left, right, .Div, allocator)
}

// ── sort_indices ────────────────────────────────────────────────────────────────

// Return an Int64 array of indices that stably sorts `arr` in ascending order.
// Nulls are ordered last (Arrow's default). The result can be fed directly into
// compute_take to materialise the sorted array.
compute_sort_indices :: proc(arr: ^Array, allocator := context.allocator) -> (result: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _sort_indices_typed(arr, i8,  allocator)
	case Int16_Type:   return _sort_indices_typed(arr, i16, allocator)
	case Int32_Type:   return _sort_indices_typed(arr, i32, allocator)
	case Int64_Type:   return _sort_indices_typed(arr, i64, allocator)
	case UInt8_Type:   return _sort_indices_typed(arr, u8,  allocator)
	case UInt16_Type:  return _sort_indices_typed(arr, u16, allocator)
	case UInt32_Type:  return _sort_indices_typed(arr, u32, allocator)
	case UInt64_Type:  return _sort_indices_typed(arr, u64, allocator)
	case Float32_Type: return _sort_indices_typed(arr, f32, allocator)
	case Float64_Type: return _sort_indices_typed(arr, f64, allocator)
	case String_Type:  return _sort_indices_string(arr, allocator)
	case Bool_Type, Null_Type, Binary_Type,
	     Large_String_Type, Large_Binary_Type:
		panic("compute_sort_indices: unsupported type")
	}
	return
}

// Stable bottom-up merge sort over the index array. `less[i] < less[j]` is
// resolved by the caller-supplied ordering captured in `idx`; ties (including
// null/null) keep the lower original index, giving a stable result.
_sort_finish_indices :: proc(idx: []i64, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	b := builder_make(i64, max(len(idx), 1), allocator)
	defer builder_destroy(&b)
	for v in idx { builder_append(&b, v) }
	return builder_finish(&b, allocator)
}

_sort_indices_typed :: proc(arr: ^Array, $T: typeid, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := arr.length
	idx := make([]i64, n, context.temp_allocator)
	for i in 0..<n { idx[i] = i64(i) }
	if n <= 1 { return _sort_finish_indices(idx, allocator) }

	data      := cast([^]T)arr.buffers[1].data
	off       := arr.offset
	has_nulls := arr.null_count != 0
	vbits     := arr.buffers[0].data

	// a ≤ b under "nulls last, then ascending value, ties keep order".
	le :: #force_inline proc(data: [^]T, off: int, has_nulls: bool, vbits: [^]u8, ai, bi: i64) -> bool {
		if has_nulls && vbits != nil {
			an := !bitmap_get(vbits, off + int(ai))
			bn := !bitmap_get(vbits, off + int(bi))
			if an && bn { return true }   // both null → keep order
			if an       { return false }  // a null → after b
			if bn       { return true }   // b null → a before
		}
		return data[off + int(ai)] <= data[off + int(bi)]
	}

	tmp := make([]i64, n, context.temp_allocator)
	width := 1
	for width < n {
		i := 0
		for i < n {
			lo  := i
			mid := min(i + width, n)
			hi  := min(i + 2*width, n)
			a, b, k := lo, mid, lo
			for a < mid && b < hi {
				if le(data, off, has_nulls, vbits, idx[a], idx[b]) { tmp[k] = idx[a]; a += 1 }
				else                                               { tmp[k] = idx[b]; b += 1 }
				k += 1
			}
			for a < mid { tmp[k] = idx[a]; a += 1; k += 1 }
			for b < hi  { tmp[k] = idx[b]; b += 1; k += 1 }
			i += 2*width
		}
		copy(idx, tmp)
		width *= 2
	}
	return _sort_finish_indices(idx, allocator)
}

_sort_indices_string :: proc(arr: ^Array, allocator: mem.Allocator) -> (result: Array, err: mem.Allocator_Error) {
	n := arr.length
	idx := make([]i64, n, context.temp_allocator)
	for i in 0..<n { idx[i] = i64(i) }
	if n <= 1 { return _sort_finish_indices(idx, allocator) }

	off       := arr.offset
	has_nulls := arr.null_count != 0
	vbits     := arr.buffers[0].data
	offsets   := cast([^]i32)arr.buffers[1].data
	bytes     := arr.buffers[2].data

	get :: #force_inline proc(offsets: [^]i32, bytes: [^]u8, off: int, i: i64) -> string {
		s := int(offsets[off + int(i)])
		e := int(offsets[off + int(i) + 1])
		if s == e { return "" }
		return string(bytes[s:e])
	}
	le :: #force_inline proc(offsets: [^]i32, bytes: [^]u8, off: int, has_nulls: bool, vbits: [^]u8, ai, bi: i64) -> bool {
		if has_nulls && vbits != nil {
			an := !bitmap_get(vbits, off + int(ai))
			bn := !bitmap_get(vbits, off + int(bi))
			if an && bn { return true }
			if an       { return false }
			if bn       { return true }
		}
		return get(offsets, bytes, off, ai) <= get(offsets, bytes, off, bi)
	}

	tmp := make([]i64, n, context.temp_allocator)
	width := 1
	for width < n {
		i := 0
		for i < n {
			lo  := i
			mid := min(i + width, n)
			hi  := min(i + 2*width, n)
			a, b, k := lo, mid, lo
			for a < mid && b < hi {
				if le(offsets, bytes, off, has_nulls, vbits, idx[a], idx[b]) { tmp[k] = idx[a]; a += 1 }
				else                                                         { tmp[k] = idx[b]; b += 1 }
				k += 1
			}
			for a < mid { tmp[k] = idx[a]; a += 1; k += 1 }
			for b < hi  { tmp[k] = idx[b]; b += 1; k += 1 }
			i += 2*width
		}
		copy(idx, tmp)
		width *= 2
	}
	return _sort_finish_indices(idx, allocator)
}
