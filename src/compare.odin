package odinarrow

import "core:mem"

// Comparison predicates and selection refinement. The point is conjunctive
// (AND) queries: with selections, each successive predicate is evaluated only on
// the rows that survived the previous one — so a selective first predicate makes
// every later predicate (and the final gather) touch far fewer rows. The
// materialise-everything path instead evaluates every predicate over all N rows.

Compare_Op :: enum { Gt, Ge, Lt, Le, Eq, Ne }

_cmp_passes :: #force_inline proc "contextless" (v: f64, op: Compare_Op, s: f64) -> bool {
	switch op {
	case .Gt: return v >  s
	case .Ge: return v >= s
	case .Lt: return v <  s
	case .Le: return v <= s
	case .Eq: return v == s
	case .Ne: return v != s
	}
	return false
}

// Element-wise compare against a scalar → Bool mask (null elements → false).
compute_compare :: proc(arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> (mask: Array, err: mem.Allocator_Error) {
	switch _ in arr.type {
	case Int8_Type:    return _compare_typed(arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _compare_typed(arr, op, scalar, i16, allocator)
	case Int32_Type:   return _compare_typed(arr, op, scalar, i32, allocator)
	case Int64_Type:   return _compare_typed(arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _compare_typed(arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _compare_typed(arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _compare_typed(arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _compare_typed(arr, op, scalar, u64, allocator)
	case Float32_Type: return _compare_typed(arr, op, scalar, f32, allocator)
	case Float64_Type: return _compare_typed(arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_compare: type does not support ordering")
	}
	return
}

_compare_typed :: proc(arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> (mask: Array, err: mem.Allocator_Error) {
	n    := arr.length
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	buf  := buffer_make(bitmap_byte_count(n), allocator) or_return   // zeroed
	if arr.buffers[0].data == nil {
		for i in 0..<n {
			if _cmp_passes(f64(data[off + i]), op, scalar) { buf.data[i >> 3] |= 1 << u8(i & 7) }
		}
	} else {
		for i in 0..<n {
			if array_is_valid(arr, i) && _cmp_passes(f64(data[off + i]), op, scalar) { buf.data[i >> 3] |= 1 << u8(i & 7) }
		}
	}
	mask = Array{ type = Bool_Type{}, length = n, buffers = {{}, buf, {}} }
	return
}

// First predicate: scan the whole column, collect surviving row indices.
compute_select_compare :: proc(arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> Selection {
	switch _ in arr.type {
	case Int8_Type:    return _select_compare_typed(arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _select_compare_typed(arr, op, scalar, i16, allocator)
	case Int32_Type:   return _select_compare_typed(arr, op, scalar, i32, allocator)
	case Int64_Type:   return _select_compare_typed(arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _select_compare_typed(arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _select_compare_typed(arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _select_compare_typed(arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _select_compare_typed(arr, op, scalar, u64, allocator)
	case Float32_Type: return _select_compare_typed(arr, op, scalar, f32, allocator)
	case Float64_Type: return _select_compare_typed(arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_select_compare: type does not support ordering")
	}
	return {}
}

_select_compare_typed :: proc(arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> Selection {
	n    := arr.length
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	has_nulls := arr.buffers[0].data != nil

	// Single pass: collect into an amortised-growth buffer (the predicate is the
	// cost, so we evaluate each element exactly once).
	idx := make([dynamic]i32, 0, max(n / 16, 16), allocator)
	if has_nulls {
		for i in 0..<n {
			if array_is_valid(arr, i) && _cmp_passes(f64(data[off + i]), op, scalar) { append(&idx, i32(i)) }
		}
	} else {
		for i in 0..<n {
			if _cmp_passes(f64(data[off + i]), op, scalar) { append(&idx, i32(i)) }
		}
	}
	return Selection{ indices = idx[:], length = len(idx), allocator = allocator }
}

// Refine an existing selection by another predicate, evaluating the column ONLY
// at the already-selected rows. This is the short-circuit that makes conjunctive
// queries cheap: the work shrinks with each predicate instead of staying O(N).
selection_refine_compare :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, allocator := context.allocator) -> Selection {
	switch _ in arr.type {
	case Int8_Type:    return _refine_compare_typed(sel, arr, op, scalar, i8,  allocator)
	case Int16_Type:   return _refine_compare_typed(sel, arr, op, scalar, i16, allocator)
	case Int32_Type:   return _refine_compare_typed(sel, arr, op, scalar, i32, allocator)
	case Int64_Type:   return _refine_compare_typed(sel, arr, op, scalar, i64, allocator)
	case UInt8_Type:   return _refine_compare_typed(sel, arr, op, scalar, u8,  allocator)
	case UInt16_Type:  return _refine_compare_typed(sel, arr, op, scalar, u16, allocator)
	case UInt32_Type:  return _refine_compare_typed(sel, arr, op, scalar, u32, allocator)
	case UInt64_Type:  return _refine_compare_typed(sel, arr, op, scalar, u64, allocator)
	case Float32_Type: return _refine_compare_typed(sel, arr, op, scalar, f32, allocator)
	case Float64_Type: return _refine_compare_typed(sel, arr, op, scalar, f64, allocator)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("selection_refine_compare: type does not support ordering")
	}
	return {}
}

_refine_compare_typed :: proc(sel: ^Selection, arr: ^Array, op: Compare_Op, scalar: f64, $T: typeid, allocator: mem.Allocator) -> Selection {
	data := cast([^]T)arr.buffers[1].data
	off  := arr.offset
	has_nulls := arr.buffers[0].data != nil
	out := make([]i32, sel.length, allocator)   // upper bound
	k := 0
	for j in 0..<sel.length {
		i := int(sel.indices[j])
		if has_nulls && !array_is_valid(arr, i) { continue }
		if _cmp_passes(f64(data[off + i]), op, scalar) { out[k] = sel.indices[j]; k += 1 }
	}
	return Selection{ indices = out[:k], length = k, allocator = allocator }
}
