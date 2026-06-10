// Thrift Compact Protocol decoder — just enough for Parquet footer metadata.
//
// Compact field header: 1 byte
//   bits 7-4: field-id delta  (0 = explicit 2-byte signed field id follows)
//   bits 3-0: field type
// Integers: ZigZag + varint
// Strings:  varint length + bytes
// Lists:    1-byte header (high nibble = size 0-14, else 0xF → varint size)
//           followed by element type in low nibble; then size elements

package parquet_to_csv_odin

// Field types (Compact Protocol)
THRIFT_BOOL_TRUE  :: u8(1)
THRIFT_BOOL_FALSE :: u8(2)
THRIFT_BYTE       :: u8(3)
THRIFT_I16        :: u8(4)
THRIFT_I32        :: u8(5)
THRIFT_I64        :: u8(6)
THRIFT_DOUBLE     :: u8(7)
THRIFT_BINARY     :: u8(8)
THRIFT_LIST       :: u8(9)
THRIFT_SET        :: u8(10)
THRIFT_MAP        :: u8(11)
THRIFT_STRUCT     :: u8(12)
THRIFT_STOP       :: u8(0)

Thrift :: struct {
    data: []u8,
    pos:  int,
}

thrift_make :: proc(data: []u8) -> Thrift {
    return Thrift{data = data, pos = 0}
}

thrift_ok :: #force_inline proc "contextless" (t: ^Thrift) -> bool {
    return t.pos < len(t.data)
}

thrift_read_byte :: #force_inline proc "contextless" (t: ^Thrift) -> u8 {
    b := t.data[t.pos]
    t.pos += 1
    return b
}

thrift_read_varint :: proc "contextless" (t: ^Thrift) -> u64 {
    result: u64
    shift: uint
    for {
        b := thrift_read_byte(t)
        result |= u64(b & 0x7F) << shift
        shift += 7
        if b & 0x80 == 0 { break }
    }
    return result
}

thrift_read_i32 :: proc "contextless" (t: ^Thrift) -> i32 {
    v := thrift_read_varint(t)
    return i32((v >> 1) ~ -(v & 1))
}

thrift_read_i64 :: proc "contextless" (t: ^Thrift) -> i64 {
    v := thrift_read_varint(t)
    return i64((v >> 1) ~ -(v & 1))
}

thrift_read_binary :: proc "contextless" (t: ^Thrift) -> []u8 {
    n := int(thrift_read_varint(t))
    b := t.data[t.pos : t.pos + n]
    t.pos += n
    return b
}

// Read a field header. Returns (field_id, field_type, stop=true when struct ends).
thrift_read_field :: proc "contextless" (t: ^Thrift, prev_field_id: ^i32) -> (field_id: i32, ftype: u8, stop: bool) {
    b := thrift_read_byte(t)
    if b == THRIFT_STOP { return 0, 0, true }
    delta := i32((b >> 4) & 0x0F)
    ftype  = b & 0x0F
    if delta == 0 {
        // Explicit field id: zigzag i16 encoded as varint
        v := thrift_read_varint(t)
        field_id = i32(i16((v >> 1) ~ -(v & 1)))
    } else {
        field_id = prev_field_id^ + delta
    }
    prev_field_id^ = field_id
    return field_id, ftype, false
}

// Read list header. Returns (element_type, count).
thrift_read_list_header :: proc "contextless" (t: ^Thrift) -> (elem_type: u8, count: int) {
    b := thrift_read_byte(t)
    elem_type = b & 0x0F
    high      := int(b >> 4)
    if high == 0x0F {
        count = int(thrift_read_varint(t))
    } else {
        count = high
    }
    return
}

// Skip a value of the given Compact field type.
thrift_skip :: proc (t: ^Thrift, ftype: u8) {
    switch ftype {
    case THRIFT_BOOL_TRUE, THRIFT_BOOL_FALSE:
        // Bool value is encoded in the field-type nibble — no additional bytes.
    case THRIFT_BYTE:
        t.pos += 1
    case THRIFT_I16, THRIFT_I32, THRIFT_I64:
        thrift_read_varint(t)
    case THRIFT_DOUBLE:
        t.pos += 8
    case THRIFT_BINARY:
        n := int(thrift_read_varint(t))
        t.pos += n
    case THRIFT_STRUCT:
        prev: i32
        for {
            _, ft, stop := thrift_read_field(t, &prev)
            if stop { break }
            thrift_skip(t, ft)
        }
    case THRIFT_LIST, THRIFT_SET:
        et, cnt := thrift_read_list_header(t)
        for _ in 0..<cnt { thrift_skip(t, et) }
    case THRIFT_MAP:
        b := thrift_read_byte(t)
        kt := (b >> 4) & 0x0F
        vt := b & 0x0F
        cnt := int(thrift_read_varint(t))
        for _ in 0..<cnt {
            thrift_skip(t, kt)
            thrift_skip(t, vt)
        }
    }
}
