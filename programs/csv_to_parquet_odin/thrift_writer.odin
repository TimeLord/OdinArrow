// Thrift Compact Protocol encoder — enough to write Parquet footer metadata.
package csv_to_parquet_odin

// Field types (same values as the decoder side)
TW_BOOL_TRUE :: u8(1)
TW_BOOL_FALSE :: u8(2)
TW_BYTE      :: u8(3)
TW_I16       :: u8(4)
TW_I32       :: u8(5)
TW_I64       :: u8(6)
TW_DOUBLE    :: u8(7)
TW_BINARY    :: u8(8)
TW_LIST      :: u8(9)
TW_STRUCT    :: u8(12)

TW :: struct {
	buf: [dynamic]u8,
}

tw_make :: proc() -> TW {
	return TW{buf = make([dynamic]u8, 0, 1024)}
}

tw_destroy :: proc(tw: ^TW) {
	delete(tw.buf)
}

tw_reset :: proc(tw: ^TW) {
	clear(&tw.buf)
}

tw_bytes :: proc(tw: ^TW) -> []u8 {
	return tw.buf[:]
}

tw_varint :: proc(tw: ^TW, v: u64) {
	n := v
	for n >= 0x80 {
		append(&tw.buf, u8(n & 0x7F) | 0x80)
		n >>= 7
	}
	append(&tw.buf, u8(n))
}

tw_i32 :: proc(tw: ^TW, v: i32) {
	uv := u32(v)
	tw_varint(tw, u64((uv << 1) ~ (u32(v >> 31))))
}

tw_i64 :: proc(tw: ^TW, v: i64) {
	uv := u64(v)
	tw_varint(tw, (uv << 1) ~ u64(v >> 63))
}

// tw_field writes a compact field header.
// prev is updated to field_id after the call.
tw_field :: proc(tw: ^TW, field_id: i32, ftype: u8, prev: ^i32) {
	delta := field_id - prev^
	if delta > 0 && delta < 16 {
		append(&tw.buf, u8(delta)<<4 | ftype)
	} else {
		// Explicit field id: type byte with delta=0, then zigzag i16 varint
		append(&tw.buf, ftype) // high nibble = 0
		n := i16(field_id)
		zz := u16(n << 1) ~ u16(n >> 15)
		tw_varint(tw, u64(zz))
	}
	prev^ = field_id
}

tw_field_i32 :: proc(tw: ^TW, field_id: i32, v: i32, prev: ^i32) {
	tw_field(tw, field_id, TW_I32, prev)
	tw_i32(tw, v)
}

tw_field_i64 :: proc(tw: ^TW, field_id: i32, v: i64, prev: ^i32) {
	tw_field(tw, field_id, TW_I64, prev)
	tw_i64(tw, v)
}

tw_field_binary :: proc(tw: ^TW, field_id: i32, data: []u8, prev: ^i32) {
	tw_field(tw, field_id, TW_BINARY, prev)
	tw_varint(tw, u64(len(data)))
	append(&tw.buf, ..data)
}

tw_field_string :: proc(tw: ^TW, field_id: i32, s: string, prev: ^i32) {
	tw_field_binary(tw, field_id, transmute([]u8)s, prev)
}

// tw_field_list_begin writes a field header + list header.
// Call this before writing the list elements.
tw_field_list_begin :: proc(tw: ^TW, field_id: i32, elem_type: u8, count: int, prev: ^i32) {
	tw_field(tw, field_id, TW_LIST, prev)
	if count < 15 {
		append(&tw.buf, u8(count)<<4 | elem_type)
	} else {
		append(&tw.buf, 0xF0 | elem_type)
		tw_varint(tw, u64(count))
	}
}

// tw_list_begin writes a bare list header (not preceded by a field header).
tw_list_begin :: proc(tw: ^TW, elem_type: u8, count: int) {
	if count < 15 {
		append(&tw.buf, u8(count)<<4 | elem_type)
	} else {
		append(&tw.buf, 0xF0 | elem_type)
		tw_varint(tw, u64(count))
	}
}

tw_stop :: proc(tw: ^TW) {
	append(&tw.buf, u8(0))
}
