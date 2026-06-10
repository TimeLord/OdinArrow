package parquet_to_csv_odin

import "core:os"
import oa "../../src"

// Physical types
PTYPE_BOOLEAN    :: i32(0)
PTYPE_INT32      :: i32(1)
PTYPE_INT64      :: i32(2)
PTYPE_FLOAT      :: i32(4)
PTYPE_DOUBLE     :: i32(5)
PTYPE_BYTE_ARRAY :: i32(6)

// Page types
PPAGE_DATA :: i32(0)
PPAGE_DICT :: i32(2)

// Repetition types
REP_REQUIRED :: i32(0)
REP_OPTIONAL :: i32(1)

Column_Chunk_Meta :: struct {
	name:          string,
	ptype:         i32,
	num_values:    i64,
	uncomp_size:   i64, // total_uncompressed_size from ColumnMetaData field 6
	data_offset:   i64,
	dict_offset:   i64,
	has_dict:      bool,
	max_def_level: i32, // 0=REQUIRED, 1=OPTIONAL
	// Extra row-group page offsets and value counts (row groups 1..N).
	// Populated by parse_footer_struct for multi-row-group files.
	extra_rg_data_offsets: []i64,
	extra_rg_num_values:   []i64,
}

Page_Header :: struct {
	page_type:  i32,
	uncomp:     i32,
	comp:       i32,
	num_values: i32,
	encoding:   i32,
}

read_i32_le :: #force_inline proc "contextless" (data: []u8, pos: int) -> i32 {
	return i32(data[pos]) | i32(data[pos+1])<<8 | i32(data[pos+2])<<16 | i32(data[pos+3])<<24
}

// ── footer parsing ────────────────────────────────────────────────────────────

// parse_footer_struct parses the raw FileMetaData Thrift bytes (no magic check).
parse_footer_struct :: proc(data: []u8) -> (num_rows: i64, metas: []Column_Chunk_Meta, ok: bool) {
	t := thrift_make(data)

	col_names:  [dynamic]string; defer delete(col_names)
	col_ptypes: [dynamic]i32;    defer delete(col_ptypes)
	col_dls:    [dynamic]i32;    defer delete(col_dls)
	rg_metas:   [dynamic]Column_Chunk_Meta; defer delete(rg_metas)

	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(&t, &prev)
		if stop { break }
		switch fid {
		case 1: thrift_read_i32(&t)
		case 2:
			_, cnt := thrift_read_list_header(&t)
			for i in 0..<cnt {
				parse_schema_element(&t, i == 0, &col_names, &col_ptypes, &col_dls)
			}
		case 3: num_rows = thrift_read_i64(&t)
		case 4:
			_, rg_cnt := thrift_read_list_header(&t)
			for _ in 0..<rg_cnt {
				parse_row_group(&t, &rg_metas)
			}
		case: thrift_skip(&t, ftype)
		}
	}

	n_cols := len(col_names)
	n_rg   := len(rg_metas) / n_cols if n_cols > 0 else 0
	result := make([]Column_Chunk_Meta, n_cols)
	for col in 0..<n_cols {
		result[col]               = rg_metas[col]   // first row group
		// Clone the name: col_names[col] is a view into footer_buf which is
		// freed by the caller after parse_footer_struct returns.
		name_bytes := make([]u8, len(col_names[col]))
		copy(name_bytes, col_names[col])
		result[col].name          = string(name_bytes)
		result[col].ptype         = col_ptypes[col]
		result[col].max_def_level = col_dls[col]
		if n_rg > 1 {
			extra := n_rg - 1
			offs := make([]i64, extra)
			vals := make([]i64, extra)
			for rg in 1..<n_rg {
				offs[rg-1] = rg_metas[rg * n_cols + col].data_offset
				vals[rg-1] = rg_metas[rg * n_cols + col].num_values
			}
			result[col].extra_rg_data_offsets = offs
			result[col].extra_rg_num_values   = vals
		}
	}
	metas = result
	ok = true
	return
}

// parse_footer reads from a full in-memory file slice (legacy path).
parse_footer :: proc(data: []u8) -> (num_rows: i64, metas: []Column_Chunk_Meta, ok: bool) {
	n := len(data)
	if n < 12 { return }
	if string(data[:4]) != "PAR1" || string(data[n-4:]) != "PAR1" { return }
	footer_len := int(read_i32_le(data, n-8))
	if footer_len >= n-8 { return }
	return parse_footer_struct(data[n-8-footer_len : n-8])
}

// parse_footer_from_file reads only the footer bytes from an open file handle.
parse_footer_from_file :: proc(file: ^os.File) -> (num_rows: i64, metas: []Column_Chunk_Meta, ok: bool) {
	file_size, size_err := os.file_size(file)
	if size_err != nil || file_size < 12 { return }

	head: [4]u8
	os.seek(file, 0, .Start)
	n_head, _ := os.read(file, head[:])
	if n_head < 4 || string(head[:]) != "PAR1" { return }

	tail: [8]u8
	os.seek(file, file_size - 8, .Start)
	n_tail, _ := os.read(file, tail[:])
	if n_tail < 8 || string(tail[4:]) != "PAR1" { return }

	footer_len := int(read_i32_le(tail[:], 0))
	if footer_len <= 0 || i64(footer_len) >= file_size - 8 { return }

	footer_buf := make([]u8, footer_len)
	defer delete(footer_buf)
	os.seek(file, file_size - 8 - i64(footer_len), .Start)
	n_footer, _ := os.read(file, footer_buf)
	if n_footer < footer_len { return }

	return parse_footer_struct(footer_buf)
}

parse_schema_element :: proc(t: ^Thrift, is_root: bool,
	names: ^[dynamic]string, ptypes: ^[dynamic]i32, dls: ^[dynamic]i32) {

	ptype:    i32 = -1
	rep_type: i32 = 0
	name:     string

	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop { break }
		switch fid {
		case 1: ptype    = thrift_read_i32(t)
		case 3: rep_type = thrift_read_i32(t)
		case 4: name     = string(thrift_read_binary(t))
		case:   thrift_skip(t, ftype)
		}
	}
	if !is_root && ptype >= 0 {
		dl := i32(0)
		if rep_type == REP_OPTIONAL { dl = 1 }
		append(names, name)
		append(ptypes, ptype)
		append(dls, dl)
	}
}

parse_row_group :: proc(t: ^Thrift, metas: ^[dynamic]Column_Chunk_Meta) {
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop { break }
		switch fid {
		case 1:
			_, cnt := thrift_read_list_header(t)
			for _ in 0..<cnt {
				m := parse_column_chunk(t)
				append(metas, m)
			}
		case: thrift_skip(t, ftype)
		}
	}
}

parse_column_chunk :: proc(t: ^Thrift) -> Column_Chunk_Meta {
	meta: Column_Chunk_Meta
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop { break }
		switch fid {
		case 3: parse_column_metadata(t, &meta)
		case:   thrift_skip(t, ftype)
		}
	}
	return meta
}

parse_column_metadata :: proc(t: ^Thrift, meta: ^Column_Chunk_Meta) {
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(t, &prev)
		if stop { break }
		switch fid {
		case 5:  meta.num_values  = thrift_read_i64(t)
		case 6:  meta.uncomp_size = thrift_read_i64(t)
		case 9:  meta.data_offset = thrift_read_i64(t)
		case 11:
			meta.dict_offset = thrift_read_i64(t)
			meta.has_dict    = true
		case: thrift_skip(t, ftype)
		}
	}
}

// ── page header ───────────────────────────────────────────────────────────────

parse_page_header :: proc(data: []u8, pos: ^int) -> (ph: Page_Header, ok: bool) {
	t := thrift_make(data[pos^:])
	prev: i32
	for {
		fid, ftype, stop := thrift_read_field(&t, &prev)
		if stop { break }
		switch fid {
		case 1: ph.page_type = thrift_read_i32(&t)
		case 2: ph.uncomp    = thrift_read_i32(&t)
		case 3: ph.comp      = thrift_read_i32(&t)
		case 4: thrift_read_i32(&t)
		case 5:
			p2: i32
			for {
				fid2, ftype2, stop2 := thrift_read_field(&t, &p2)
				if stop2 { break }
				switch fid2 {
				case 1: ph.num_values = thrift_read_i32(&t)
				case 2: ph.encoding   = thrift_read_i32(&t)
				case:   thrift_skip(&t, ftype2)
				}
			}
		case 7:
			p2: i32
			for {
				fid2, ftype2, stop2 := thrift_read_field(&t, &p2)
				if stop2 { break }
				switch fid2 {
				case 1: ph.num_values = thrift_read_i32(&t)
				case 2: ph.encoding   = thrift_read_i32(&t)
				case:   thrift_skip(&t, ftype2)
				}
			}
		case: thrift_skip(&t, ftype)
		}
	}
	pos^ += t.pos
	ok = true
	return
}

// ── varint for RLE ───────────────────────────────────────────────────────────

rle_read_varint :: proc "contextless" (data: []u8, pos: ^int) -> u64 {
	result: u64
	shift:  uint
	for {
		b := data[pos^]; pos^ += 1
		result |= u64(b & 0x7F) << shift
		shift += 7
		if b & 0x80 == 0 { break }
	}
	return result
}

// decode_rle_into decodes RLE/bit-packed values into a pre-allocated slice.
decode_rle_into :: proc(data: []u8, bit_width: int, num_values: int, out: []int) {
	if bit_width == 0 {
		for i in 0..<num_values { out[i] = 0 }
		return
	}
	pos := 0
	idx := 0
	for idx < num_values && pos < len(data) {
		hdr := rle_read_varint(data, &pos)
		if hdr & 1 == 0 {
			run_count := int(hdr >> 1)
			val_bytes := (bit_width + 7) / 8
			val := 0
			for b in 0..<val_bytes {
				val |= int(data[pos]) << uint(b * 8)
				pos += 1
			}
			n := min(run_count, num_values - idx)
			for _ in 0..<n { out[idx] = val; idx += 1 }
		} else {
			groups := int(hdr >> 1)
			for g in 0..<groups {
				for v in 0..<8 {
					if idx >= num_values { break }
					bit_pos := (g * 8 + v) * bit_width
					byte_off := pos + bit_pos / 8
					bit_off  := uint(bit_pos % 8)
					val := int(data[byte_off]) >> bit_off
					if bit_off + uint(bit_width) > 8 && byte_off + 1 < len(data) {
						val |= int(data[byte_off+1]) << (8 - bit_off)
					}
					out[idx] = val & ((1 << uint(bit_width)) - 1)
					idx += 1
				}
				pos += bit_width
			}
		}
	}
}

// decode_rle_indices allocates and decodes (kept for callers that own the slice).
decode_rle_indices :: proc(data: []u8, bit_width: int, num_values: int) -> []int {
	result := make([]int, num_values)
	decode_rle_into(data, bit_width, num_values, result)
	return result
}

skip_def_levels :: proc "contextless" (data: []u8, pos: ^int, max_def_level: i32) {
	if max_def_level == 0 { return }
	def_len := int(read_i32_le(data, pos^))
	pos^ += 4 + def_len
}

// ── Col_Stream: streaming page-by-page column reader ─────────────────────────
//
// Each Col_Stream owns its own file descriptor so concurrent column reads
// don't interfere via shared file-pointer state.

Col_Stream :: struct {
	file:          ^os.File,
	ptype:         i32,
	max_def:       i32,
	has_dict:      bool,
	total_rows:    int,   // total across ALL row groups
	rows_done:     int,   // total rows consumed across all row groups
	// Row-group advancement
	rg_total:      int,   // rows in current row group
	rg_rows_done:  int,   // rows consumed from current row group
	extra_rg_offsets: []i64, // data_offset for row groups 1..N
	extra_rg_values:  []i64, // num_values  for row groups 1..N
	extra_rg_idx:     int,
	// Dictionary (loaded once at init, kept for lifetime)
	dict_strs:     []string,   // for string dict (zero-copy from dict_buf)
	dict_i32s:     []i32,      // for INT32 dict
	dict_buf:      []u8,       // backing storage for dict string bytes
	// Page cursor
	page_off:      i64,        // file offset of next page header
	page_buf:      []u8,       // reusable data buffer
	// Current page decoder state
	page_rows_left: int,
	plain_data:    []u8,       // view into page_buf (PLAIN values)
	plain_pos:     int,
	rle_idx_buf:   []int,      // decoded indices for current dict page
	rle_idx_pos:   int,
}

// col_stream_init opens a new file handle to the given path and loads the
// dictionary page (if any).  The caller must call col_stream_destroy when done.
col_stream_init :: proc(path: string, meta: Column_Chunk_Meta) -> (cs: Col_Stream, ok: bool) {
	f, err := os.open(path)
	if err != nil { return }

	cs.file         = f
	cs.ptype        = meta.ptype
	cs.max_def      = meta.max_def_level
	cs.has_dict     = meta.has_dict
	cs.rg_total     = int(meta.num_values)
	cs.rg_rows_done = 0
	// Accumulate total rows across all row groups.
	total := meta.num_values
	for v in meta.extra_rg_num_values { total += v }
	cs.total_rows = int(total)
	// Copy extra row-group data so the stream owns its own lifetime.
	if len(meta.extra_rg_data_offsets) > 0 {
		cs.extra_rg_offsets = make([]i64, len(meta.extra_rg_data_offsets))
		copy(cs.extra_rg_offsets, meta.extra_rg_data_offsets)
		cs.extra_rg_values = make([]i64, len(meta.extra_rg_num_values))
		copy(cs.extra_rg_values, meta.extra_rg_num_values)
	}
	cs.page_buf = make([]u8, 1 << 20) // 1 MB starting size

	if meta.has_dict {
		probe: [512]u8
		os.seek(f, meta.dict_offset, .Start)
		n_p, _ := os.read(f, probe[:])
		if n_p < 4 { os.close(f); return }

		hdr_pos := 0
		ph, ph_ok := parse_page_header(probe[:n_p], &hdr_pos)
		if !ph_ok { os.close(f); return }

		dict_data_size := int(ph.comp)
		cs.dict_buf = make([]u8, dict_data_size)
		already := min(n_p - hdr_pos, dict_data_size)
		copy(cs.dict_buf[:already], probe[hdr_pos : hdr_pos + already])
		if already < dict_data_size {
			os.seek(f, meta.dict_offset + i64(hdr_pos) + i64(already), .Start)
			os.read(f, cs.dict_buf[already:])
		}

		if meta.ptype == PTYPE_INT32 {
			cs.dict_i32s = make([]i32, ph.num_values)
			for i in 0..<int(ph.num_values) {
				cs.dict_i32s[i] = read_i32_le(cs.dict_buf, i*4)
			}
		} else {
			cs.dict_strs = make([]string, ph.num_values)
			pos := 0
			for i in 0..<int(ph.num_values) {
				slen := int(read_i32_le(cs.dict_buf, pos))
				pos += 4
				cs.dict_strs[i] = string(cs.dict_buf[pos : pos + slen])
				pos += slen
			}
		}
	}

	cs.page_off = meta.data_offset
	ok = true
	return
}

col_stream_destroy :: proc(cs: ^Col_Stream) {
	if cs.file != nil { os.close(cs.file) }
	delete(cs.page_buf)
	delete(cs.rle_idx_buf)
	delete(cs.dict_strs)
	delete(cs.dict_i32s)
	delete(cs.dict_buf)
	delete(cs.extra_rg_offsets)
	delete(cs.extra_rg_values)
}

// col_stream_load_page reads and decodes the next data page from the file.
col_stream_load_page :: proc(cs: ^Col_Stream) -> bool {
	if cs.rows_done >= cs.total_rows { return false }
	// Advance to the next row group when the current one is fully consumed.
	if cs.rg_rows_done >= cs.rg_total {
		if cs.extra_rg_idx >= len(cs.extra_rg_offsets) { return false }
		cs.page_off      = cs.extra_rg_offsets[cs.extra_rg_idx]
		cs.rg_total      = int(cs.extra_rg_values[cs.extra_rg_idx])
		cs.rg_rows_done  = 0
		cs.extra_rg_idx += 1
	}

	probe: [512]u8
	os.seek(cs.file, cs.page_off, .Start)
	n_p, _ := os.read(cs.file, probe[:])
	if n_p < 4 { return false }

	hdr_pos := 0
	ph, ph_ok := parse_page_header(probe[:n_p], &hdr_pos)
	if !ph_ok { return false }

	// Skip any dictionary page encountered (already loaded at init)
	if ph.page_type == PPAGE_DICT {
		cs.page_off += i64(hdr_pos + int(ph.comp))
		return col_stream_load_page(cs)
	}

	total_data := int(ph.comp)
	if len(cs.page_buf) < total_data {
		delete(cs.page_buf)
		cs.page_buf = make([]u8, total_data)
	}

	already := min(n_p - hdr_pos, total_data)
	copy(cs.page_buf[:already], probe[hdr_pos : hdr_pos + already])
	if already < total_data {
		os.seek(cs.file, cs.page_off + i64(hdr_pos) + i64(already), .Start)
		n_rem, _ := os.read(cs.file, cs.page_buf[already:total_data])
		if n_rem < total_data - already { return false }
	}

	cs.page_off += i64(hdr_pos + total_data)

	data := cs.page_buf[:total_data]
	pos  := 0
	skip_def_levels(data, &pos, cs.max_def)

	n := int(ph.num_values)
	if cs.has_dict {
		bw := int(data[pos])
		pos += 1
		if len(cs.rle_idx_buf) < n {
			delete(cs.rle_idx_buf)
			cs.rle_idx_buf = make([]int, n)
		}
		decode_rle_into(data[pos:], bw, n, cs.rle_idx_buf[:n])
		cs.rle_idx_pos = 0
	} else {
		cs.plain_data = data[pos:]
		cs.plain_pos  = 0
	}
	cs.page_rows_left = n
	return true
}

// col_stream_to_string_array reads up to n string values into an OdinArrow Array.
// The caller owns the returned Array and must call oa.array_free when done.
col_stream_to_string_array :: proc(cs: ^Col_Stream, n: int) -> oa.Array {
	b := oa.string_builder_make(n)
	defer oa.string_builder_destroy(&b)
	count := 0
	for count < n && cs.rows_done < cs.total_rows {
		if cs.page_rows_left == 0 {
			if !col_stream_load_page(cs) { break }
		}
		if cs.has_dict {
			idx := cs.rle_idx_buf[cs.rle_idx_pos]
			cs.rle_idx_pos += 1
			if idx < len(cs.dict_strs) {
				oa.string_builder_append(&b, cs.dict_strs[idx])
			} else {
				oa.string_builder_append_null(&b)
			}
		} else {
			slen := int(read_i32_le(cs.plain_data, cs.plain_pos))
			cs.plain_pos += 4
			oa.string_builder_append(&b, string(cs.plain_data[cs.plain_pos : cs.plain_pos + slen]))
			cs.plain_pos += slen
		}
		cs.page_rows_left -= 1
		cs.rows_done      += 1
		cs.rg_rows_done   += 1
		count += 1
	}
	arr, _ := oa.string_builder_finish(&b)
	return arr
}

// col_stream_to_i32_array reads up to n INT32 values into an OdinArrow Array.
// The caller owns the returned Array and must call oa.array_free when done.
col_stream_to_i32_array :: proc(cs: ^Col_Stream, n: int) -> oa.Array {
	b := oa.builder_make(i32, n)
	defer oa.builder_destroy(&b)
	count := 0
	for count < n && cs.rows_done < cs.total_rows {
		if cs.page_rows_left == 0 {
			if !col_stream_load_page(cs) { break }
		}
		if cs.has_dict {
			idx := cs.rle_idx_buf[cs.rle_idx_pos]
			cs.rle_idx_pos += 1
			if idx < len(cs.dict_i32s) {
				oa.builder_append(&b, cs.dict_i32s[idx])
			} else {
				oa.builder_append_null(&b)
			}
		} else {
			oa.builder_append(&b, read_i32_le(cs.plain_data, cs.plain_pos))
			cs.plain_pos += 4
		}
		cs.page_rows_left -= 1
		cs.rows_done      += 1
		cs.rg_rows_done   += 1
		count += 1
	}
	arr, _ := oa.builder_finish(&b)
	return arr
}
