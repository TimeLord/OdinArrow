package odinarrow

import "core:mem"

// ── String_Builder ────────────────────────────────────────────────────────────
//
// Produces Arrow UTF-8 (i32-offset) arrays.
// Buffer layout: [validity_bitmap, i32_offsets, utf8_bytes]
//
// offsets always contains length+1 values; it is pre-seeded with [0].

String_Builder :: struct {
	offsets:    [dynamic]i32,
	data:       [dynamic]u8,
	bitmap:     [dynamic]u8,
	null_count: int,
	length:     int,
}

string_builder_make :: proc(initial_cap := 64, allocator := context.allocator) -> String_Builder {
	bm_bytes := bitmap_byte_count(max(initial_cap, 1))
	b := String_Builder{
		offsets = make([dynamic]i32, 0, initial_cap + 1, allocator),
		data    = make([dynamic]u8,  0, initial_cap * 8, allocator),
		bitmap  = make([dynamic]u8,  bm_bytes, bm_bytes, allocator),
	}
	append(&b.offsets, i32(0))
	return b
}

string_builder_append :: proc(b: ^String_Builder, s: string) {
	i := b.length
	if b.null_count > 0 {
		byte_i := i >> 3
		if byte_i >= len(b.bitmap) { resize(&b.bitmap, byte_i + 1) }
		b.bitmap[byte_i] |= 1 << u8(i & 7)
	}
	append(&b.data, ..transmute([]u8)s)
	append(&b.offsets, i32(len(b.data)))
	b.length += 1
}

string_builder_append_null :: proc(b: ^String_Builder) {
	i      := b.length
	byte_i := i >> 3
	if byte_i >= len(b.bitmap) { resize(&b.bitmap, byte_i + 1) }
	if b.null_count == 0 { bitmap_set_all(raw_data(b.bitmap[:]), i) }
	// Null bit stays 0 (pre-zeroed).
	append(&b.offsets, b.offsets[len(b.offsets) - 1])
	b.null_count += 1
	b.length += 1
}

string_builder_finish :: proc(b: ^String_Builder, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	return _var_finish(b.offsets[:], b.data[:], b.bitmap[:], b.null_count, b.length, String_Type{}, allocator)
}

string_builder_reset :: proc(b: ^String_Builder) {
	clear(&b.offsets)
	clear(&b.data)
	clear(&b.bitmap)
	append(&b.offsets, i32(0))
	b.null_count = 0
	b.length     = 0
}

string_builder_destroy :: proc(b: ^String_Builder) {
	delete(b.offsets)
	delete(b.data)
	delete(b.bitmap)
	b^ = {}
}

// ── Binary_Builder ────────────────────────────────────────────────────────────
// Identical to String_Builder except produces Binary_Type arrays (no UTF-8 assertion).

Binary_Builder :: struct {
	offsets:    [dynamic]i32,
	data:       [dynamic]u8,
	bitmap:     [dynamic]u8,
	null_count: int,
	length:     int,
}

binary_builder_make :: proc(initial_cap := 64, allocator := context.allocator) -> Binary_Builder {
	b := Binary_Builder{
		offsets = make([dynamic]i32, 0, initial_cap + 1, allocator),
		data    = make([dynamic]u8,  0, initial_cap * 8, allocator),
		bitmap  = make([dynamic]u8,  0, (initial_cap + 7) / 8, allocator),
	}
	append(&b.offsets, i32(0))
	return b
}

binary_builder_append :: proc(b: ^Binary_Builder, bytes: []u8) {
	i      := b.length
	byte_i := i >> 3
	if byte_i >= len(b.bitmap) {
		append(&b.bitmap, u8(0))
	}
	b.bitmap[byte_i] |= 1 << u8(i & 7)
	append(&b.data, ..bytes)
	append(&b.offsets, i32(len(b.data)))
	b.length += 1
}

binary_builder_append_null :: proc(b: ^Binary_Builder) {
	i      := b.length
	byte_i := i >> 3
	if byte_i >= len(b.bitmap) {
		append(&b.bitmap, u8(0))
	}
	append(&b.offsets, b.offsets[len(b.offsets) - 1])
	b.null_count += 1
	b.length += 1
}

binary_builder_finish :: proc(b: ^Binary_Builder, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	return _var_finish(b.offsets[:], b.data[:], b.bitmap[:], b.null_count, b.length, Binary_Type{}, allocator)
}

binary_builder_destroy :: proc(b: ^Binary_Builder) {
	delete(b.offsets)
	delete(b.data)
	delete(b.bitmap)
	b^ = {}
}

// ── Array accessors ───────────────────────────────────────────────────────────

// Zero-copy string view. Valid only while the Array is alive. Does NOT copy.
array_get_string :: proc(arr: ^Array, i: int) -> string {
	assert(i >= 0 && i < arr.length, "array_get_string: out of bounds")
	offsets := cast([^]i32)arr.buffers[1].data
	idx     := arr.offset + i
	start   := int(offsets[idx])
	end     := int(offsets[idx + 1])
	if start == end do return ""
	return transmute(string)arr.buffers[2].data[start:end]
}

// Zero-copy binary slice. Valid only while the Array is alive. Does NOT copy.
array_get_binary :: proc(arr: ^Array, i: int) -> []u8 {
	assert(i >= 0 && i < arr.length, "array_get_binary: out of bounds")
	offsets := cast([^]i32)arr.buffers[1].data
	idx     := arr.offset + i
	start   := int(offsets[idx])
	end     := int(offsets[idx + 1])
	return arr.buffers[2].data[start:end]
}

// ── shared finish impl ────────────────────────────────────────────────────────

_var_finish :: proc(
	offsets:    []i32,
	data_bytes: []u8,
	bitmap:     []u8,
	null_count: int,
	length:     int,
	data_type:  DataType,
	allocator:  mem.Allocator,
) -> (arr: Array, err: mem.Allocator_Error) {
	// Validity bitmap
	bitmap_buf: Buffer
	if null_count > 0 {
		n_bm := bitmap_byte_count(length)
		bitmap_buf = buffer_make(n_bm, allocator) or_return
		src_n := (length + 7) / 8
		if src_n > 0 && len(bitmap) > 0 {
			copy_n := min(src_n, len(bitmap))
			mem.copy(rawptr(bitmap_buf.data), rawptr(raw_data(bitmap)), copy_n)
		}
	}

	// Offsets buffer: (length + 1) i32 values
	off_bytes := (length + 1) * size_of(i32)
	off_buf, err2 := buffer_make(off_bytes, allocator)
	if err2 != nil {
		buffer_free(&bitmap_buf)
		err = err2
		return
	}
	if len(offsets) > 0 {
		mem.copy(rawptr(off_buf.data), rawptr(raw_data(offsets)), len(offsets) * size_of(i32))
	}

	// Data buffer
	data_buf, err3 := buffer_make(len(data_bytes), allocator)
	if err3 != nil {
		buffer_free(&bitmap_buf)
		buffer_free(&off_buf)
		err = err3
		return
	}
	if len(data_bytes) > 0 {
		mem.copy(rawptr(data_buf.data), rawptr(raw_data(data_bytes)), len(data_bytes))
	}

	arr = Array{
		type       = data_type,
		length     = length,
		null_count = null_count,
		offset     = 0,
		buffers    = {bitmap_buf, off_buf, data_buf},
	}
	return
}
