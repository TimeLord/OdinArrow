package odinarrow

// Fused kernels (C3): compute a filter+aggregate in a single pass over the data,
// without materialising the filtered array in between. `compute_sum_where` is
// the canonical example — it replaces `filter(values, mask)` followed by
// `sum(...)`, eliminating the intermediate allocation, the dense copy of the
// surviving values, and a second pass over them.

// Sum of `values` at positions where `mask` is true. Null mask entries and null
// values are skipped. One pass, no allocation.
compute_sum_where :: proc(values, mask: ^Array) -> (sum: f64, valid_count: int) {
	assert(values.length == mask.length, "compute_sum_where: length mismatch")
	_, is_bool := mask.type.(Bool_Type)
	assert(is_bool, "compute_sum_where: mask must be Bool type")

	switch _ in values.type {
	case Int8_Type:    return _sum_where_typed(values, mask, i8)
	case Int16_Type:   return _sum_where_typed(values, mask, i16)
	case Int32_Type:   return _sum_where_typed(values, mask, i32)
	case Int64_Type:   return _sum_where_typed(values, mask, i64)
	case UInt8_Type:   return _sum_where_typed(values, mask, u8)
	case UInt16_Type:  return _sum_where_typed(values, mask, u16)
	case UInt32_Type:  return _sum_where_typed(values, mask, u32)
	case UInt64_Type:  return _sum_where_typed(values, mask, u64)
	case Float32_Type: return _sum_where_typed(values, mask, f32)
	case Float64_Type: return _sum_where_typed(values, mask, f64)
	case Null_Type, Bool_Type, String_Type, Large_String_Type, Binary_Type, Large_Binary_Type:
		panic("compute_sum_where: type does not support numeric summation")
	}
	return
}

_sum_where_typed :: #force_inline proc(values, mask: ^Array, $T: typeid) -> (sum: f64, valid_count: int) {
	n     := values.length
	data  := cast([^]T)values.buffers[1].data
	voff  := values.offset
	mbits := mask.buffers[1].data
	moff  := mask.offset
	v_nulls := values.buffers[0].data != nil
	m_nulls := mask.buffers[0].data != nil

	if !v_nulls && !m_nulls && moff == 0 {
		// Byte-at-a-time over the mask: read 8 bits at once, skip empty bytes.
		n_full := (n / 8) * 8
		for i := 0; i < n_full; i += 8 {
			b := mbits[i >> 3]
			if b == 0 { continue }
			for bit in u8(0)..<8 {
				if (b >> bit) & 1 == 1 { sum += f64(data[voff + i + int(bit)]); valid_count += 1 }
			}
		}
		for i := n_full; i < n; i += 1 {
			if bitmap_get(mbits, i) { sum += f64(data[voff + i]); valid_count += 1 }
		}
		return
	}

	for i in 0..<n {
		if m_nulls && !array_is_valid(mask, i) { continue }
		if !bitmap_get(mbits, moff + i) { continue }
		if v_nulls && !array_is_valid(values, i) { continue }
		sum += f64(data[voff + i]); valid_count += 1
	}
	return
}

// Number of true mask entries (null entries count as false). A fused count that
// needs no array at all — the degenerate case of "filter then count".
compute_count_where :: proc(mask: ^Array) -> int {
	if mask.buffers[0].data == nil {
		return _filter_count_bits(mask.buffers[1].data, mask.offset, mask.length)
	}
	count := 0
	for i in 0..<mask.length { if _mask_passes(mask, i) { count += 1 } }
	return count
}
