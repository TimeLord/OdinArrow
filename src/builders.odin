package odinarrow

import "core:mem"

// Primitive_Builder accumulates values of type T and produces an owned Array
// on finish(). T must be one of: bool, i8, i16, i32, i64, u8, u16, u32, u64, f32, f64.
//
// bitmap tracks validity (null markers) for ALL types.
// For Bool, values stores the actual true/false — packed to bits on finish.
// For all other types, values is a contiguous typed buffer copied on finish.
Primitive_Builder :: struct($T: typeid) {
	values:     [dynamic]T,
	bitmap:     [dynamic]u8, // validity, packed bits; only used when null_count > 0
	null_count: int,
	length:     int,
}

// Allocate a new builder with preallocated capacity.
builder_make :: proc($T: typeid, initial_cap := 64, allocator := context.allocator) -> Primitive_Builder(T) {
	return Primitive_Builder(T){
		values = make([dynamic]T, 0, initial_cap, allocator),
		bitmap = make([dynamic]u8, 0, (initial_cap + 7) / 8, allocator),
	}
}

// Append a non-null value.
builder_append :: proc(b: ^Primitive_Builder($T), val: T) {
	i       := b.length
	byte_i  := i >> 3
	if byte_i >= len(b.bitmap) {
		append(&b.bitmap, u8(0))
	}
	b.bitmap[byte_i] |= 1 << u8(i & 7) // mark valid
	append(&b.values, val)
	b.length += 1
}

// Append a null value. The stored data value is the zero value of T (don't-care).
builder_append_null :: proc(b: ^Primitive_Builder($T)) {
	i      := b.length
	byte_i := i >> 3
	if byte_i >= len(b.bitmap) {
		append(&b.bitmap, u8(0)) // new byte starts 0 → bit stays null
	}
	zero: T
	append(&b.values, zero)
	b.null_count += 1
	b.length += 1
}

// Produce an immutable Array from the builder's accumulated values.
// The builder is NOT reset; call builder_reset or builder_destroy after finish.
// Allocates two buffers (validity + data); caller owns the returned Array.
builder_finish :: proc(
	b:         ^Primitive_Builder($T),
	allocator := context.allocator,
) -> (arr: Array, err: mem.Allocator_Error) {
	// --- validity bitmap (only materialised when there are nulls) ---
	bitmap_buf: Buffer
	if b.null_count > 0 {
		n_bm_bytes := bitmap_byte_count(b.length)
		bitmap_buf  = buffer_make(n_bm_bytes, allocator) or_return
		src_n       := (b.length + 7) / 8
		if src_n > 0 && len(b.bitmap) > 0 {
			mem.copy(rawptr(bitmap_buf.data), rawptr(raw_data(b.bitmap[:])), src_n)
		}
	}

	// --- data buffer ---
	data_buf: Buffer
	when T == bool {
		// Bool data is bit-packed (same layout as a bitmap)
		n_data_bytes := bitmap_byte_count(b.length)
		buf, buf_err := buffer_make(n_data_bytes, allocator)
		if buf_err != nil {
			buffer_free(&bitmap_buf)
			err = buf_err
			return
		}
		for i in 0..<b.length {
			if b.values[i] {
				buf.data[i >> 3] |= 1 << u8(i & 7)
			}
		}
		data_buf = buf
	} else {
		n_data_bytes := b.length * size_of(T)
		buf, buf_err := buffer_make(n_data_bytes, allocator)
		if buf_err != nil {
			buffer_free(&bitmap_buf)
			err = buf_err
			return
		}
		if b.length > 0 {
			mem.copy(rawptr(buf.data), rawptr(raw_data(b.values[:])), n_data_bytes)
		}
		data_buf = buf
	}

	arr = Array{
		type       = _data_type_for(T),
		length     = b.length,
		null_count = b.null_count,
		offset     = 0,
		buffers    = {bitmap_buf, data_buf, {}},
	}
	return
}

// Reset builder to empty without freeing underlying dynamic array memory (reuse).
builder_reset :: proc(b: ^Primitive_Builder($T)) {
	clear(&b.values)
	clear(&b.bitmap)
	b.null_count = 0
	b.length     = 0
}

// Free all memory held by the builder. The builder must not be used after this.
builder_destroy :: proc(b: ^Primitive_Builder($T)) {
	delete(b.values)
	delete(b.bitmap)
	b^ = {}
}

// --- internal helpers -----------------------------------------------------

_data_type_for :: proc($T: typeid) -> DataType {
	when T == bool { return Bool_Type{} }
	else when T == i8  { return Int8_Type{} }
	else when T == i16 { return Int16_Type{} }
	else when T == i32 { return Int32_Type{} }
	else when T == i64 { return Int64_Type{} }
	else when T == u8  { return UInt8_Type{} }
	else when T == u16 { return UInt16_Type{} }
	else when T == u32 { return UInt32_Type{} }
	else when T == u64 { return UInt64_Type{} }
	else when T == f32 { return Float32_Type{} }
	else when T == f64 { return Float64_Type{} }
	else {
		#assert(false, "Primitive_Builder: unsupported type T")
		return {}
	}
}
