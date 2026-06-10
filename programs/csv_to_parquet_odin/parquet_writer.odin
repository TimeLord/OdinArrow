// Parquet writer: PLAIN encoding, UNCOMPRESSED, all-string (BYTE_ARRAY) columns.
// Supports multiple row groups for memory-bounded streaming writes.
package csv_to_parquet_odin

import "core:os"
import oa "../../src"

// Physical type constants
PW_BYTE_ARRAY :: i32(6)
PW_INT32      :: i32(1)

// Encoding constants
PW_ENC_PLAIN :: i32(0)
PW_ENC_RLE   :: i32(3)

// Compression constants
PW_CODEC_UNCOMPRESSED :: i32(0)

// ── bookkeeping ───────────────────────────────────────────────────────────────

Col_Write_Meta :: struct {
	data_page_off: i64, // byte offset of data page header in the file
	uncomp_size:   i64, // total page bytes (header + data) written
	num_values:    i64,
}

RG_Meta :: struct {
	cols:     []Col_Write_Meta,
	num_rows: i64,
}

Parquet_Writer :: struct {
	file:      ^os.File,
	offset:    i64, // bytes written so far
	n_cols:    int,
	col_names: []string,
	row_groups: [dynamic]RG_Meta,
}

// pw_open writes the PAR1 magic and returns a writer ready for row groups.
pw_open :: proc(file: ^os.File, col_names: []string) -> Parquet_Writer {
	pw: Parquet_Writer
	pw.file      = file
	pw.n_cols    = len(col_names)
	pw.col_names = col_names

	n, _ := os.write(file, transmute([]u8)string("PAR1"))
	pw.offset = i64(n)
	return pw
}

// pw_write_row_group writes one row group from a slice of OdinArrow String_Type arrays.
pw_write_row_group :: proc(pw: ^Parquet_Writer, cols: []oa.Array) {
	rg: RG_Meta
	rg.cols     = make([]Col_Write_Meta, pw.n_cols)
	rg.num_rows = i64(cols[0].length)

	for ci in 0..<pw.n_cols {
		rg.cols[ci] = pw_write_column(pw, &cols[ci])
	}

	append(&pw.row_groups, rg)
}

// pw_write_column writes one OdinArrow String_Type Array as a PLAIN BYTE_ARRAY page.
pw_write_column :: proc(pw: ^Parquet_Writer, arr: ^oa.Array) -> Col_Write_Meta {
	meta: Col_Write_Meta
	meta.data_page_off = pw.offset
	meta.num_values    = i64(arr.length)

	// Build value bytes (PLAIN BYTE_ARRAY: [i32 len][bytes] per value)
	val_buf: [dynamic]u8
	defer delete(val_buf)
	for i in 0..<arr.length {
		s := oa.array_get_string(arr, i)
		n := len(s)
		b4: [4]u8
		b4[0] = u8(n);       b4[1] = u8(n >> 8)
		b4[2] = u8(n >> 16); b4[3] = u8(n >> 24)
		append(&val_buf, ..b4[:])
		append(&val_buf, ..transmute([]u8)s)
	}

	comp_size := len(val_buf)
	num_vals  := arr.length

	// Build DataPageHeader using Thrift compact encoding
	hdr_tw := tw_make()
	defer tw_destroy(&hdr_tw)
	{
		prev: i32
		// PageHeader
		tw_field_i32(&hdr_tw, 1, 0, &prev)              // page_type = DATA_PAGE (0)
		tw_field_i32(&hdr_tw, 2, i32(comp_size), &prev) // uncompressed_page_size
		tw_field_i32(&hdr_tw, 3, i32(comp_size), &prev) // compressed_page_size
		// field 5: DataPageHeader (inline struct)
		tw_field(&hdr_tw, 5, TW_STRUCT, &prev)
		{
			p2: i32
			tw_field_i32(&hdr_tw, 1, i32(num_vals), &p2) // num_values
			tw_field_i32(&hdr_tw, 2, 0, &p2)             // encoding = PLAIN
			tw_field_i32(&hdr_tw, 3, 3, &p2)             // definition_level_encoding = RLE
			tw_field_i32(&hdr_tw, 4, 3, &p2)             // repetition_level_encoding = RLE
			tw_stop(&hdr_tw)
		}
		tw_stop(&hdr_tw)
	}

	hdr_bytes := tw_bytes(&hdr_tw)
	total     := i64(len(hdr_bytes)) + i64(comp_size)

	os.write(pw.file, hdr_bytes)
	os.write(pw.file, val_buf[:])
	pw.offset += total

	meta.uncomp_size = total
	return meta
}

// pw_finish writes the FileMetaData footer and the trailing magic bytes.
pw_finish :: proc(pw: ^Parquet_Writer) {
	total_rows := i64(0)
	for rg in pw.row_groups { total_rows += rg.num_rows }

	footer_tw := tw_make()
	defer tw_destroy(&footer_tw)

	prev: i32

	// version = 2
	tw_field_i32(&footer_tw, 1, 2, &prev)

	// schema list<SchemaElement>: root + one leaf per column
	tw_field_list_begin(&footer_tw, 2, TW_STRUCT, pw.n_cols + 1, &prev)
	{
		// Root element
		p: i32
		tw_field_i32(&footer_tw, 5, i32(pw.n_cols), &p) // num_children
		tw_field_string(&footer_tw, 4, "schema", &p)
		tw_stop(&footer_tw)
	}
	for ci in 0..<pw.n_cols {
		p: i32
		tw_field_i32(&footer_tw, 1, PW_BYTE_ARRAY, &p)  // type = BYTE_ARRAY
		tw_field_i32(&footer_tw, 3, 0, &p)              // repetition_type = REQUIRED
		tw_field_string(&footer_tw, 4, pw.col_names[ci], &p)
		tw_field_i32(&footer_tw, 6, 0, &p)              // converted_type = UTF8
		tw_stop(&footer_tw)
	}

	// num_rows
	tw_field_i64(&footer_tw, 3, total_rows, &prev)

	// row_groups list<RowGroup>
	tw_field_list_begin(&footer_tw, 4, TW_STRUCT, len(pw.row_groups), &prev)
	for rg in pw.row_groups {
		rg_total_bytes := i64(0)
		for cm in rg.cols { rg_total_bytes += cm.uncomp_size }

		rg_prev: i32
		// field 1: columns list<ColumnChunk>
		tw_field_list_begin(&footer_tw, 1, TW_STRUCT, pw.n_cols, &rg_prev)
		for ci in 0..<pw.n_cols {
			cm := rg.cols[ci]
			cc_prev: i32
			// file_offset (field 2)
			tw_field_i64(&footer_tw, 2, cm.data_page_off, &cc_prev)
			// meta_data (field 3): ColumnMetaData struct
			tw_field(&footer_tw, 3, TW_STRUCT, &cc_prev)
			{
				cm_prev: i32
				tw_field_i32(&footer_tw, 1, PW_BYTE_ARRAY, &cm_prev)  // type
				// encodings list<Encoding> = [PLAIN(0)]
				tw_field_list_begin(&footer_tw, 2, TW_I32, 1, &cm_prev)
				tw_i32(&footer_tw, 0)
				// path_in_schema list<string>
				tw_field_list_begin(&footer_tw, 3, TW_BINARY, 1, &cm_prev)
				tw_varint(&footer_tw, u64(len(pw.col_names[ci])))
				append(&footer_tw.buf, ..transmute([]u8)pw.col_names[ci])
				// codec = UNCOMPRESSED (0)
				tw_field_i32(&footer_tw, 4, 0, &cm_prev)
				// num_values
				tw_field_i64(&footer_tw, 5, cm.num_values, &cm_prev)
				// total_uncompressed_size
				tw_field_i64(&footer_tw, 6, cm.uncomp_size, &cm_prev)
				// total_compressed_size
				tw_field_i64(&footer_tw, 7, cm.uncomp_size, &cm_prev)
				// data_page_offset
				tw_field_i64(&footer_tw, 9, cm.data_page_off, &cm_prev)
				tw_stop(&footer_tw)
			}
			tw_stop(&footer_tw) // ColumnChunk
		}
		// total_byte_size (field 2)
		tw_field_i64(&footer_tw, 2, rg_total_bytes, &rg_prev)
		// num_rows (field 3)
		tw_field_i64(&footer_tw, 3, rg.num_rows, &rg_prev)
		tw_stop(&footer_tw) // RowGroup
	}

	tw_stop(&footer_tw) // FileMetaData

	footer_bytes := tw_bytes(&footer_tw)
	footer_len   := i32(len(footer_bytes))

	os.write(pw.file, footer_bytes)

	// Footer length (i32 LE) + trailing PAR1 magic
	len_buf: [4]u8
	len_buf[0] = u8(footer_len)
	len_buf[1] = u8(footer_len >> 8)
	len_buf[2] = u8(footer_len >> 16)
	len_buf[3] = u8(footer_len >> 24)
	os.write(pw.file, len_buf[:])
	os.write(pw.file, transmute([]u8)string("PAR1"))
}

pw_destroy :: proc(pw: ^Parquet_Writer) {
	for rg in pw.row_groups { delete(rg.cols) }
	delete(pw.row_groups)
}
