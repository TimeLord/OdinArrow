// Streaming RFC 4180 CSV reader.
// Fields are appended into a caller-supplied arena [dynamic]u8.
// Pre-reserve the arena to cap before reading a chunk to keep string
// pointers stable (no reallocation = no pointer invalidation).
package csv_to_parquet_odin

import "core:os"

CSV_Stream :: struct {
	file:      ^os.File,
	buf:       []u8,      // raw read buffer (owned)
	buf_len:   int,       // valid bytes in buf
	buf_pos:   int,       // parse cursor in buf
	eof:       bool,
	col_names: []string,  // column headers (heap-allocated, freed on destroy)
	n_cols:    int,
}

// csv_stream_open opens path, reads the header row, and returns a ready reader.
csv_stream_open :: proc(path: string, buf_size: int) -> (cs: CSV_Stream, ok: bool) {
	f, err := os.open(path)
	if err != nil { return }
	cs.file    = f
	cs.buf     = make([]u8, buf_size)

	csv_refill(&cs)

	// Parse header row into a temp arena so we own the bytes.
	hdr_arena := make([dynamic]u8, 0, 4096)
	defer {
		// col_names slice will be kept; hdr_arena backing buf must outlive it.
		// Transfer ownership by not deleting hdr_arena here — we keep it in the
		// returned CSV_Stream.  Instead store arena backing in col_names backing.
		// Actually: header names are short so just allocate each separately.
		delete(hdr_arena)
	}

	names: [dynamic]string
	field_tmp := make([dynamic]u8, 0, 256)
	defer delete(field_tmp)
	for {
		clear(&field_tmp)
		eor, eof := csv_read_field_into(&cs, &field_tmp)
		if eof && len(field_tmp) == 0 { break }
		// Make a stable heap copy of the name.
		name_buf := make([]u8, len(field_tmp))
		copy(name_buf, field_tmp[:])
		append(&names, string(name_buf))
		if eor { break }
	}

	if len(names) == 0 { os.close(f); return }
	cs.col_names = names[:]
	cs.n_cols    = len(names)
	ok = true
	return
}

csv_stream_destroy :: proc(cs: ^CSV_Stream) {
	if cs.file != nil { os.close(cs.file) }
	delete(cs.buf)
	for s in cs.col_names { delete(transmute([]u8)s) }
	delete(cs.col_names)
}

csv_stream_at_eof :: proc(cs: ^CSV_Stream) -> bool {
	return cs.eof && cs.buf_pos >= cs.buf_len
}

// csv_refill compacts unprocessed bytes to the front of the buffer and reads more.
csv_refill :: proc(cs: ^CSV_Stream) {
	remaining := cs.buf_len - cs.buf_pos
	if remaining > 0 {
		copy(cs.buf[:remaining], cs.buf[cs.buf_pos:cs.buf_len])
	}
	cs.buf_len = remaining
	cs.buf_pos = 0
	n, _ := os.read(cs.file, cs.buf[cs.buf_len:])
	cs.buf_len += n
	if n == 0 { cs.eof = true }
}

// csv_read_field_into reads the next CSV field, appending its unescaped bytes
// into dst.  Returns (end_of_row, end_of_file).
// At EOF with no bytes written this is the end of input.
csv_read_field_into :: proc(cs: ^CSV_Stream, dst: ^[dynamic]u8) -> (eor: bool, eof: bool) {
	// Ensure some data is available.
	if cs.buf_pos >= cs.buf_len {
		if cs.eof { return true, true }
		csv_refill(cs)
		if cs.buf_pos >= cs.buf_len { return true, true }
	}

	if cs.buf[cs.buf_pos] == '"' {
		// ── Quoted field ──────────────────────────────────────────────────────
		cs.buf_pos += 1 // skip opening quote
		qloop: for {
			for cs.buf_pos < cs.buf_len {
				ch := cs.buf[cs.buf_pos]
				if ch == '"' {
					cs.buf_pos += 1
					if cs.buf_pos < cs.buf_len && cs.buf[cs.buf_pos] == '"' {
						// Escaped double-quote
						append(dst, '"')
						cs.buf_pos += 1
					} else {
						// Closing quote
						break qloop
					}
				} else {
					append(dst, ch)
					cs.buf_pos += 1
				}
			}
			// May have hit end of buffer mid-field; refill and continue.
			if cs.buf_pos >= cs.buf_len {
				if cs.eof { break qloop }
				csv_refill(cs)
			}
		}
		eor = csv_consume_sep(cs)
		return eor, false
	}

	// ── Unquoted field ────────────────────────────────────────────────────────
	uloop: for {
		start := cs.buf_pos
		for cs.buf_pos < cs.buf_len {
			ch := cs.buf[cs.buf_pos]
			if ch == ',' || ch == '\n' || ch == '\r' { break }
			cs.buf_pos += 1
		}
		append(dst, ..cs.buf[start:cs.buf_pos])

		if cs.buf_pos < cs.buf_len {
			// Hit separator — field is complete.
			break uloop
		}
		// End of buffer; refill and continue scanning.
		if cs.eof { return true, len(dst^) == 0 }
		csv_refill(cs)
	}
	eor = csv_consume_sep(cs)
	return eor, false
}

// csv_consume_sep advances past a comma or newline.  Returns true if row ended.
csv_consume_sep :: proc(cs: ^CSV_Stream) -> (eor: bool) {
	if cs.buf_pos >= cs.buf_len {
		if cs.eof { return true }
		csv_refill(cs)
	}
	if cs.buf_pos >= cs.buf_len { return true }

	ch := cs.buf[cs.buf_pos]
	if ch == ',' {
		cs.buf_pos += 1
		return false
	}
	if ch == '\r' {
		cs.buf_pos += 1
		if cs.buf_pos < cs.buf_len && cs.buf[cs.buf_pos] == '\n' {
			cs.buf_pos += 1
		}
		return true
	}
	if ch == '\n' {
		cs.buf_pos += 1
		return true
	}
	return true // fallback
}

// csv_stream_read_chunk reads rows into col_data (pre-allocated [n_cols][max_rows]string).
// Field bytes are appended into arena; returned strings point into arena.
// The caller MUST pre-reserve arena to cap before calling to ensure no reallocation
// (which would invalidate the returned string pointers).
// Stops when max_rows is reached OR when arena is more than 90% full.
// Returns number of rows actually written into col_data.
csv_stream_read_chunk :: proc(
	cs:         ^CSV_Stream,
	col_data:   [][]string,
	max_rows:   int,
	arena:      ^[dynamic]u8,
	per_row_est: int, // conservative bytes-per-row estimate for overflow guard
) -> int {
	n := 0
	field_tmp := make([dynamic]u8, 0, 4096)
	defer delete(field_tmp)

	for n < max_rows && !csv_stream_at_eof(cs) {
		// Stop if we'd fill the arena with the next row.
		if len(arena^) + per_row_est > cap(arena^) { break }

		ok := true
		for ci in 0..<cs.n_cols {
			clear(&field_tmp)
			eor, eof := csv_read_field_into(cs, &field_tmp)

			if eof && ci == 0 && len(field_tmp) == 0 {
				ok = false
				break
			}

			field_start := len(arena^)
			// This append must not reallocate — we checked cap above.
			// If a single field is unexpectedly huge, arena may reallocate
			// and existing string pointers become invalid.  Callers should
			// use a conservatively large capacity to avoid this.
			append(arena, ..field_tmp[:])
			col_data[ci][n] = string(arena^[field_start : len(arena^)])

			_ = eor
		}
		if !ok { break }
		n += 1
	}
	return n
}
